#!/usr/bin/env python3
"""Loopback-only, read-only research board: committed results + live event journal.

Git snapshots are read without checkout/pull. The page cannot grant an audit pass,
edit a task, run a tool or expose credentials, agent memory or raw process logs.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path: sys.path.insert(0, str(HERE))
import research_activity as activity

spec = importlib.util.spec_from_file_location('dashboard_board', HERE / 'research_board.py')
rb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rb)
MAX_BYTES = 20 * 1024 * 1024
ASSETS = {'/': 'index.html', '/app.js': 'app.js', '/app.css': 'app.css'}


def git(repo, *args, binary=False, required=True):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, timeout=20)
    if required and result.returncode:
        raise RuntimeError('저장소를 읽지 못했습니다. 서비스·Git 권한을 확인하세요.')
    return result.stdout if binary else result.stdout.decode('utf-8', 'replace').strip()


def output_allowed(path):
    p = PurePosixPath(path)
    return (bool(path) and not p.is_absolute() and '..' not in p.parts and '\\' not in path and ':' not in path
            and not any(x.startswith('.') for x in p.parts)
            and (p.parts[0] in {'paper', 'notes', 'sources', 'reports', 'reviews', 'evidence', 'experiments'}
                 or path in {'REQUEST.md', 'ACCEPTANCE.md', 'claims.md', 'outline.md', 'CLAUDE.md'}))


def audit_input_allowed(path):
    # Empty-directory markers are real audited inputs, but not user downloads.
    # Do not confuse "not exposed by the board" with "audit version invalid".
    p = PurePosixPath(path)
    return output_allowed(path) or (p.name == '.gitkeep' and len(p.parts) > 1
        and output_allowed(str(p.parent) + '/marker'))


class Board:
    def __init__(self, workspace, home):
        self.workspace, self.home = Path(workspace).resolve(), Path(home).resolve()
        self.lock = threading.Lock()
        self.cached, self.cached_at = None, 0
        self.project_cache = {}

    def projects(self):
        if not self.workspace.is_dir(): return {}
        candidates = list(self.workspace.iterdir())
        for folder in list(candidates):
            if folder.name.startswith('_validation-') and folder.is_dir() and not folder.is_symlink():
                candidates.extend(folder.iterdir())
        # Validation projects are nested. Only registered paths below this workspace
        # are added, never arbitrary folders supplied by a URL.
        paper_list = self.home / 'papers'
        if paper_list.is_file():
            for line in paper_list.read_text(encoding='utf-8-sig').splitlines():
                if line.strip(): candidates.append(Path(line.strip()))
        found = {}
        for path in candidates:
            if (not path.is_dir() or path.is_symlink() or not path.resolve().is_relative_to(self.workspace)
                    or not (path / '.git').exists()): continue
            key = hashlib.sha256(str(path.resolve()).encode()).hexdigest()[:20]
            found[key] = path.resolve()
        return found

    def source(self, project):
        remote = git(project, 'remote', 'get-url', 'origin', required=False)
        if remote and '://' not in remote:
            local = Path(remote)
            if not local.is_absolute(): local = project / local
            # Do not turn a project-controlled remote into an arbitrary file reader.
            if (local.resolve().is_relative_to(self.home / 'boards') and local.is_dir()
                    and git(local, 'rev-parse', '--is-bare-repository', required=False) == 'true'):
                return local, git(local, 'rev-parse', 'HEAD'), '공유 Git에 저장된 최신 버전'
        return project, git(project, 'rev-parse', 'HEAD'), '로컬 저장 버전（외부 원격 저장소는 자동 조회하지 않음）'

    def blob(self, repo, commit, path):
        size = git(repo, 'cat-file', '-s', f'{commit}:{path}', required=False)
        if not size.isdigit() or int(size) > MAX_BYTES: raise ValueError('파일 없음 또는 20MB 초과')
        return git(repo, 'show', f'{commit}:{path}', binary=True)

    def project(self, key, project):
        repo, commit, source = self.source(project)
        version = (str(repo), commit)
        cached = self.project_cache.get(key)
        if cached and cached[0] == version:
            return cached[1]
        tree = git(repo, '-c', 'core.quotepath=false', 'ls-tree', '-r', commit).splitlines()
        files = {line.split('\t', 1)[1] for line in tree if line.startswith('100') and '\t' in line}
        raw_cache = {}
        def blob(path):
            if path not in raw_cache: raw_cache[path] = self.blob(repo, commit, path)
            return raw_cache[path]
        ledger_lines = blob(rb.LEDGER).decode('utf-8', 'replace').splitlines() if rb.LEDGER in files else []
        chain_ok = rb.ledger_check(ledger_lines) is None
        ledger = []
        for line in ledger_lines:
            try: ledger.append(json.loads(line))
            except ValueError: pass
        latest = {entry.get('task'): entry for entry in ledger}
        audits = []
        for name in sorted(files):
            if not re.fullmatch(r'\.tasks/audits/[A-Za-z0-9._-]+\.json', name): continue
            try:
                receipt = json.loads(blob(name))
                rb.audit_gate.validate_result(receipt, {k: receipt[k] for k in ('verdict', 'checks', 'findings', 'notes')})
                valid = receipt.get('verdict') == 'pass' and bool(receipt.get('files'))
                versions = receipt.get('target_versions', {})
                valid = valid and set(versions) == set(receipt.get('targets', [])) and bool(versions)
                for path, digest in receipt.get('files', {}).items():
                    if not audit_input_allowed(path) or path not in files or hashlib.sha256(blob(path)).hexdigest() != digest:
                        valid = False
                for tid, digest in versions.items():
                    path = f'.tasks/{tid}.md'
                    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', tid) or path not in files or hashlib.sha256(blob(path)).hexdigest() != digest:
                        valid = False
                audits.append({'task': PurePosixPath(name).stem.rsplit('-', 1)[0],
                               'scope': receipt.get('scope'), 'verdict': receipt.get('verdict'),
                               'targets': receipt.get('targets', []), 'current': bool(valid),
                               'findings': receipt.get('findings', []), 'notes': receipt.get('notes', '')})
            except (ValueError, TypeError, KeyError):
                audits.append({'verdict': 'invalid', 'current': False, 'targets': []})
        tasks = []
        for name in sorted(files):
            if not re.fullmatch(r'\.tasks/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.md', name): continue
            match = re.match(r'---\n(.*?)\n---\n?(.*)', blob(name).decode('utf-8', 'replace').replace('\r\n', '\n'), re.S)
            if not match: continue
            meta = dict((k.strip(), v.strip()) for k, sep, v in (line.partition(':') for line in match[1].splitlines()) if sep)
            tid = meta.get('id', PurePosixPath(name).stem)
            entry = latest.get(tid, {})
            names = list(dict.fromkeys(rb.csv(meta.get('expects')) + list(entry.get('outputs', {}))))
            review = [a for a in audits if tid in a['targets']]
            own_review = [a for a in audits if a.get('task') == tid]
            status = meta.get('status', 'unknown')
            approval = ('사용자 결정 필요' if status in ('done', 'blocked') and meta.get('gate') == 'human' else '')
            tasks.append({'id': tid, 'assignee': meta.get('assignee'), 'status': status,
                          'after': rb.csv(meta.get('after')), 'updated': meta.get('updated'),
                          'attempt': meta.get('attempt', '0'), 'max_attempts': meta.get('max_attempts'),
                          'claimed_by': meta.get('claimed_by', ''), 'stop_reason': meta.get('stop_reason', ''),
                          'report': activity.redact(match[2][-30000:]), 'thread': meta.get('thread', ''), 'approval': approval,
                          'audit': ('판정 통과（현재 버전）' if any(a['current'] for a in own_review) else
                                    '판정 ' + {'pass': '통과 기록 · 입력 버전 변경', 'reject': '반려',
                                              'unverifiable': '검증 불가'}.get(own_review[-1]['verdict'], '기록 오류')) if own_review else
                                   '통과（현재 버전）' if any(a['current'] for a in review) else
                                   '반려·검증불가·버전 변경' if review else '미감사',
                          'outputs': [{'path': n, 'available': n in files} for n in names if output_allowed(n)]})
        result = {'id': key, 'name': project.name, 'path': str(project), 'commit': commit, 'source': source,
                'test': any(p.startswith(('_validation-', '_selftest-')) for p in project.parts),
                'tasks': tasks, 'audits': audits, 'ledger_intact': chain_ok, 'error': None}
        self.project_cache[key] = (version, result)
        return result

    def snapshot(self):
        with self.lock:
            if self.cached is not None and time.monotonic() - self.cached_at < 2: return self.cached
            projects = []
            for key, path in self.projects().items():
                try: projects.append(self.project(key, path))
                except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
                    projects.append({'id': key, 'name': path.name, 'tasks': [], 'error': activity.clean(exc), 'test': False})
            service, validation = {}, {'passed': False, 'state': '미검증'}
            try:
                raw = json.loads((self.home / 'service-status.json').read_text(encoding='utf-8-sig'))
                service = {'updated': raw.get('updated'), 'stopped': raw.get('stopped', False),
                           'children': [{k: child.get(k) for k in ('name', 'state', 'restarts')} for child in raw.get('children', [])]}
            except (OSError, ValueError): pass
            try:
                raw = json.loads((self.home / 'live-test.json').read_text(encoding='utf-8-sig'))
                validation = {k: raw.get(k) for k in ('passed', 'state', 'error')}
                from team_selftest import binding_for
                from installation_evidence import suite_ready
                # A fork's small probes, mocks, or stale payload cannot become our
                # S1/S2/S3 installation pass merely by writing passed=true.
                validation['passed'] = suite_ready(raw, binding_for(self.home))
                validation['scenarios'] = {k: {'passed': v.get('ready_for_delivery') is True and v.get('delivered') is True,
                                               'lead': v.get('lead_state')} for k, v in raw.get('scenarios', {}).items()}
            except (OSError, ValueError, TypeError, KeyError):
                validation['passed'] = False
            self.cached = {'projects': projects, 'service': service, 'validation': validation,
                           'updated': rb.now(), 'workspace': str(self.workspace)}
            self.cached_at = time.monotonic()
            return self.cached

    def output(self, key, path, commit):
        if not output_allowed(path) or not re.fullmatch(r'[a-f0-9]{40,64}', commit): raise ValueError('파일 경로 거부')
        project = self.projects().get(key)
        if project is None: raise ValueError('프로젝트 없음')
        repo, current, _ = self.source(project)
        if current != commit: raise ValueError('버전 변경: 새로 고침 필요')
        mode = git(repo, 'ls-tree', commit, '--', path)
        if not mode.startswith('100'): raise ValueError('일반 파일만 제공')
        return self.blob(repo, commit, path)


def handler(board):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def reply(self, code, data, mime, filename=None):
            self.send_response(code)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'")
            if filename:
                self.send_header('Content-Disposition', "attachment; filename*=UTF-8''" + urllib.parse.quote(filename))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            port = self.server.server_port
            if (self.headers.get('Host') not in (f'127.0.0.1:{port}', f'localhost:{port}') or
                    self.headers.get('Sec-Fetch-Site') == 'cross-site' or
                    self.headers.get('Origin') not in (None, f'http://127.0.0.1:{port}', f'http://localhost:{port}')):
                return self.reply(403, b'Local access only', 'text/plain')
            url = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(url.query)
            try:
                if url.path in ASSETS:
                    file = HERE / 'board-ui' / ASSETS[url.path]
                    mime = {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[file.suffix]
                    return self.reply(200, file.read_bytes(), mime + '; charset=utf-8')
                if url.path == '/api/projects':
                    data = board.snapshot()
                elif url.path == '/api/activity':
                    data = {'events': activity.read_events(board.home, q.get('project', [None])[0]), 'updated': rb.now()}
                elif url.path == '/api/output':
                    path = q['path'][0]
                    raw = board.output(q['project'][0], path, q['commit'][0])
                    if q.get('preview') == ['1']:
                        if PurePosixPath(path).suffix.lower() not in ('.md', '.txt', '.json', '.jsonl', '.csv', '.py', '.html', '.log', '.tex'):
                            raise ValueError('이 파일은 다운로드로 확인하세요')
                        return self.reply(200, raw[:200000], 'text/plain; charset=utf-8')
                    return self.reply(200, raw, 'application/octet-stream', PurePosixPath(path).name)
                elif url.path == '/api/log':
                    rows = activity.read_events(board.home, q.get('project', [None])[0])
                    text = '\n'.join(f"{r['time']} | {r['agent']} | {r['project']}/{r['task']} | {r['action']} | {r['detail']} | {r['result']}" for r in rows)
                    return self.reply(200, text.encode(), 'text/plain; charset=utf-8', 'research-activity.txt')
                else: return self.reply(404, b'Not found', 'text/plain')
                return self.reply(200, json.dumps(data, ensure_ascii=False).encode(), 'application/json; charset=utf-8')
            except (KeyError, ValueError, OSError, TypeError, RuntimeError, subprocess.TimeoutExpired):
                return self.reply(409, '정보 없음 또는 버전 변경. 새로 고침 후 다시 확인하세요.'.encode(), 'text/plain; charset=utf-8')
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--home', required=True)
    parser.add_argument('--port', type=int, default=0, help='loopback port; 0 chooses a free port')
    args = parser.parse_args()
    board = Board(args.workspace, args.home)
    if not 0 <= args.port <= 65535: parser.error('port must be 0..65535')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), handler(board))
    url = f'http://127.0.0.1:{server.server_port}/'
    rb.write_state(board.home / 'dashboard.json', {'url': url, 'pid': os.getpid(), 'parent': os.getppid(),
                   'instance': os.environ.get('RESEARCH_PROCESS_INSTANCE', ''), 'started': rb.now()})
    (board.workspace / 'Research Board.url').write_text('[InternetShortcut]\nURL=' + url + '\n', encoding='utf-8')
    print('Research board: ' + url, flush=True)
    try: server.serve_forever()
    finally: server.server_close()


if __name__ == '__main__': main()

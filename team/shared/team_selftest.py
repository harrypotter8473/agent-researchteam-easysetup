#!/usr/bin/env python3
"""Real installed-profile S1/S2/S3 harness. Never run during offline tests.
Persists pending states, uses independent installed workers, no synthetic pass flag.
Only requests outcomes from the lead. The lead chooses its task graph.
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
import subprocess as sp
import sys
import threading
import time
import urllib.request
from pathlib import Path
# Same curated environment as the actual installer; do not re-enable cwd imports.
_SHARED = Path(__file__).resolve().parent
if str(_SHARED) not in sys.path:
    sys.path.insert(0, str(_SHARED))
import research_board as rb
from installation_evidence import SCENARIOS, ROLES, scenario_evidence, suite_ready

def board(*args, cwd, check=True):
    r = sp.run([sys.executable, str(Path(__file__).with_name('research_board.py')), *args],
               cwd=cwd, capture_output=True, encoding='utf-8', errors='replace', timeout=180)
    if check and r.returncode:
        raise RuntimeError((r.stderr or r.stdout)[-600:])
    return r

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    temp.replace(path)

def binding_for(home):
    h = hashlib.sha256()
    for rel in ('team.json', 'service.json', 'team/manifest.json', 'team/shared/profile-manifest.json'):
        value = json.loads((home / rel).read_text(encoding='utf-8-sig'))
        # Installation timestamp alone does not restart an unfinished test.
        value.pop('UpdatedAt', None)
        h.update(json.dumps(value, sort_keys=True).encode())
    return h.hexdigest()


def write_project_marker(folder, name):
    # `init` registers an existing Git repo; a board may have no tasks yet.
    # Do not assume a runner or lead has already created this directory.
    target = Path(folder) / '.tasks/project.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({'schema': 1, 'validation': name}), encoding='utf-8')

def local_html_check(folder):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
        functools.partial(Quiet, directory=str(folder / 'reports')))
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        with urllib.request.urlopen('http://127.0.0.1:%d/result.html' % server.server_port, timeout=10) as response:
            return response.status == 200 and hashlib.sha256(response.read()).hexdigest() == rb.sha256_file(folder / 'reports/result.html')
    finally:
        server.shutdown(); server.server_close(); thread.join()


def verify_lead_attachment(folder, output, thread):
    """Observe actual lead delivery; the test must never send a second copy.

    Require current-version audit, the lead's own post in this request/channel,
    exact filename/size and independently downloaded bytes. A local Word file or
    an unposted upload alone cannot make an installation ready.
    """
    waiting = {'verified': False, 'reason': 'awaiting_lead_delivery'}
    try:
        folder = Path(folder)
        if not rb.audit_gate.delivery_allowed(folder, rb.delivery_inputs([output])):
            return {'verified': False, 'reason': 'awaiting_current_final_audit'}
        rel, _, kind = output.partition(':')
        target = folder / rel
        if kind == 'docx': target = target.with_suffix('.docx')
        data = target.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        note = rb.Notifier(folder, 'research-lead')
        if not note.creds or not note.channel:
            return {'verified': False, 'reason': 'missing_delivery_connection'}
        lead = rb.mm_api(note.creds, 'GET', '/users/me')['id']
        posts = rb.mm_api(note.creds, 'GET', '/posts/' + thread + '/thread').get('posts', {})
        for post in posts.values():
            if (post.get('user_id') != lead or post.get('channel_id') != note.channel or
                    post.get('delete_at') or not (post.get('root_id') == thread or post.get('id') == thread)):
                continue
            for file_id in post.get('file_ids', []):
                info = rb.mm_api(note.creds, 'GET', '/files/' + file_id + '/info')
                if info.get('name') != target.name or info.get('size') != len(data):
                    continue
                downloaded = rb.mm_download(note.creds, file_id)
                if hashlib.sha256(downloaded).hexdigest() == digest:
                    return {'verified': True, 'reason': 'download_hash_matches',
                            'actor': 'research-lead', 'post': post['id'], 'file': file_id,
                            'name': target.name, 'sha256': digest}
                waiting['reason'] = 'attachment_hash_mismatch'
        return waiting
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {'verified': False, 'reason': 'delivery_check_unavailable',
                'detail': rb.activity.clean(str(error))}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--workspace', required=True); ap.add_argument('--channel', required=True)
    ap.add_argument('--hermes', required=True); ap.add_argument('--mention', default='')
    ap.add_argument('--timeout', type=int, default=10800)
    a = ap.parse_args()
    ws, home = Path(a.workspace), rb.TEAM_HOME
    path = home / 'live-test.json'
    result = {'passed': False, 'live': True, 'roles': {}, 'lead': None, 'audit_passed': False,
              'delivered': False, 'ledger_intact': False, 'scenarios': {}, 'error': '', 'state': 'running'}
    try:
        binding = binding_for(home)
        if path.exists():
            previous = json.loads(path.read_text(encoding='utf-8-sig'))
            if previous.get('binding') == binding:
                result = previous
            else:
                history = home / 'validation-history'
                history.mkdir(exist_ok=True)
                (history / ('suite-' + str(time.time_ns()) + '.json')).write_bytes(path.read_bytes())
        result['binding'] = binding
        result.setdefault('folder', str(ws / ('_validation-' + binding[:12])))
        root = Path(result['folder']); root.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + a.timeout
        for name, (objective, output) in SCENARIOS.items():
            record = result['scenarios'].setdefault(name, {})
            folder = root / (binding[:12] + '-' + name.lower())
            if not record.get('created'):
                for d in ('notes', 'sources', 'reports', 'evidence', 'experiments'):
                    (folder / d).mkdir(parents=True, exist_ok=True)
                    (folder / d / '.gitkeep').write_text('', encoding='utf-8')
                (folder / 'CLAUDE.md').write_text('# Installation validation\n**Sensitivity:** public\n', encoding='utf-8')
                (folder / 'REQUEST.md').write_text(objective, encoding='utf-8')
                required = ('Use all four roles and intermediate/final independent audits. Preserve sources and record uncertainty. Output: '
                            + output + '. After final approval the lead must deliver the requested final file in this same thread '
                            'using installed research_board.py deliver. The validation harness only observes the post and '
                            'independently downloads and verifies it; it never delivers for the lead.')
                if name == 'S2':
                    (folder / 'sources/measurements.csv').write_text('id,condition,value\na,A,1\nb,A,3\nc,B,4\nd,B,8\n', encoding='utf-8')
                    (folder / 'sources/dictionary.txt').write_text('SYNTHETIC installation data. id independent sample, condition A/B, value mg/L. Descriptive only; no significance/causality claims.', encoding='utf-8')
                    required += ' Also save evidence/statistics.json: A and B, each n,mean,sample_std; experiments/*.py, evidence/*.svg or *.png, reproduction instructions.'
                if name == 'S3':
                    s2 = root / (binding[:12] + '-s2')
                    (folder / 'sources/verified-reference.json').write_bytes((s2 / 'evidence/statistics.json').read_bytes())
                    required += ' HTML must reference verified-reference and identify synthetic data, methods, limitations, units and provenance.'
                (folder / 'ACCEPTANCE.md').write_text(required, encoding='utf-8')
                board('init', str(folder), cwd=ws)
                # Coordinator must process first event even if it appears before its first scan.
                write_project_marker(folder, name)
                board('publish', str(folder), '.tasks/project.json', '-m', 'installation request', cwd=ws)
                board('setup', str(folder), '--channel', a.channel, *(['--mention', a.mention] if a.mention else []), cwd=ws)
                record['thread'] = board('thread', str(folder), '설치 후 범용 3+1 대표 검증 ' + name + ' — ' + objective, cwd=ws).stdout.strip().split()[0]
                record['created'] = True; save(path, result)
            if not record.get('dispatched'):
                # Write the dispatch intent before launching: no automatic duplicate after crash.
                record['dispatched'] = True; record['lead_state'] = 'running'; save(path, result)
                query = root / (name + '-lead.md')
                query.write_text('Handle the user request in REQUEST.md using research-orchestrate. Project: ' +
                    str(folder) + '. Read ACCEPTANCE.md for deliverable acceptance criteria. Thread: ' + record['thread'] +
                    '. Make and dispatch your plan; independent workers and coordinator continue after this turn.', encoding='utf-8')
                env, sens, gateway = rb.child_env(folder, 'research-lead')
                command = [a.hermes, '-p', 'research-lead', 'chat', '-Q', '--query-file', str(query),
                           '--max-turns', str(rb.TEAM_MAX_TURNS), '-s', 'research-orchestrate']
                journal = rb.activity.Journal(home, folder.name, name + '-plan', 'research-lead')
                journal.emit('요청 접수·계획', '설치 후 실제 ' + name + ' 검증 계획 수립', 'running')
                proc = rb.popen_group(rb.activity.stream_command(command), cwd=folder, env=env, stdout=sp.PIPE, stderr=sp.PIPE, encoding='utf-8', errors='replace')
                out, err, code = rb.activity.capture(proc, journal, max(1, deadline - time.monotonic()), rb.kill_tree)
                if code == 124:
                    record['lead_state'] = 'interrupted'; save(path, result)
                    raise RuntimeError('Lead dispatch deadline; inspect saved board before explicit resume')
                record['lead_state'] = 'done' if proc.returncode == 0 else 'failed'
                (root / (name + '-lead.log')).write_text((out + '\n' + err)[-10000:], encoding='utf-8')
                save(path, result)
                if proc.returncode:
                    raise RuntimeError('Lead dispatch failed; saved records retained')
            while True:
                board('list', str(folder), cwd=ws)
                ledger_ok = board('ledger', str(folder), '--verify', cwd=ws, check=False).returncode == 0
                evidence = scenario_evidence(folder, name, record.get('lead_state') == 'done', ledger_ok)
                record.update(evidence); save(path, result)
                if evidence['ready_for_delivery']:
                    if name == 'S3':
                        record['checks']['local_http'] = local_html_check(folder)
                        if not record['checks']['local_http']:
                            raise RuntimeError('S3 local HTTP access mismatch')
                    if not record.get('delivered'):
                        record['delivery_receipt'] = verify_lead_attachment(folder, output, record['thread'])
                        record['delivered'] = record['delivery_receipt']['verified']
                    save(path, result)
                    if record.get('delivered'):
                        break
                if time.monotonic() >= deadline:
                    result['state'] = 'pending'
                    raise RuntimeError(name + ' remains incomplete; same saved request will be inspected on retry, not duplicated')
                time.sleep(min(10, max(0.1, deadline - time.monotonic())))
            if not record.get('delivered'):
                raise RuntimeError(name + ' attachment verification failed')
        result['passed'] = suite_ready(result, binding)
        result.update(lead='done', roles={r: 'done' for r in ROLES if r != 'research-lead'},
                      audit_passed=result['passed'], delivered=result['passed'], ledger_intact=result['passed'],
                      state='ready' if result['passed'] else 'pending', error='')
    except Exception as e:
        result['passed'] = False
        result['error'] = str(e)[:1000]
        result['state'] = 'pending'
    save(path, result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['passed'] else 2

if __name__ == '__main__':
    sys.exit(main())

"""Sanitized, append-only live events. This is observability, never an approval source.

One journal per producer process avoids cross-runner append races. Raw prompts,
tool outputs, environment variables and model reasoning are never published.
"""
import collections
import datetime as dt
import json
import os
from pathlib import Path
import queue
import re
import threading
import time
import urllib.parse
import uuid

ROLES = {'research-lead', 'research-scout', 'research-worker', 'research-reviewer'}
LABELS = {'research-lead': '총괄', 'research-scout': '조사', 'research-worker': '분석', 'research-reviewer': '감사'}


def redact(value):
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    value = re.sub(r'''(?i)(bearer\s+|(?:api[_-]?key|token|password|secret)["']?\s*[:=]\s*["']?)[^\s"',;]+''', r'\1[비공개]', value)
    value = re.sub(r'\b(?:sk-[\w-]+|eyJ[\w-]+\.[\w-]+\.[\w-]+|rgw\.[\w.-]+)\b', '[비공개]', value)
    return value


def clean(value, limit=240):
    value = re.sub(r'[\x00-\x1f\x7f]', ' ', redact(value))
    return value[:limit]


def target(args):
    """Only approved display fields; never commands, HTTP headers or full tool input."""
    if not isinstance(args, dict):
        return ''
    if isinstance(args.get('urls'), list):
        urls = [target({'url': item}) for item in args['urls'][:3] if isinstance(item, str)]
        return clean(' · '.join(item for item in urls if item))
    for key in ('url', 'query', 'search_query', 'path', 'file_path', 'filename'):
        value = args.get(key)
        if not isinstance(value, str):
            continue
        if key == 'url':
            try:
                p = urllib.parse.urlsplit(value)
                if p.scheme not in ('http', 'https') or not p.hostname:
                    return ''
                return clean(urllib.parse.urlunsplit((p.scheme, p.hostname, p.path, '', '')))
            except ValueError:
                return ''
        return clean(value)
    return ''


def tool_action(name):
    if 'search' in name: return '검색'
    if any(x in name for x in ('fetch', 'browse', 'read_web', 'web_extract')): return '원문 읽기'
    if any(x in name for x in ('write', 'patch', 'edit_file')): return '문서 작성·수정'
    if any(x in name for x in ('read', 'file')): return '자료 읽기'
    if any(x in name for x in ('terminal', 'python', 'execute', 'shell')): return '도구 실행'
    return '도구 사용'


def failure_reason(output):
    """Human-readable known causes, without copying raw tool results/secrets."""
    text = str(output).lower()
    for pattern, message in (
        (r'\b401\b|unauthorized|authentication', '인증 거부: 연결된 계정·인증을 확인해야 함'),
        (r'\b403\b|forbidden|permission denied|access denied', '접근 권한 거부: 자료·도구 권한 확인 필요'),
        (r'\b404\b|not found', '원문·파일 없음: 대체 자료 또는 경로 확인 필요'),
        (r'\b429\b|rate.?limit', '서비스 호출 제한: 대기·재시도 판단 필요'),
        (r'timed? ?out|timeout', '응답 시간 초과: 저장 근거를 유지하고 재시도 판단 필요'),
        (r'budget|turn limit|token limit', '실행 한도 도달: 소진 항목과 저장 결과 확인 필요'),
        (r'blocked|not allowed|denied', '허용 범위에 막힘: 대체 도구·자료 또는 사용자 결정 검토 필요')):
        if re.search(pattern, text): return message
    return '도구 실패: 총괄이 저장된 실행 기록으로 원인을 확인해야 함'


class Journal:
    def __init__(self, home, project, task, role):
        self.project, self.task, self.role = clean(project, 128), clean(task, 128), role
        if role not in ROLES:
            raise ValueError('Unknown research role')
        folder = Path(home) / 'activity'
        folder.mkdir(parents=True, exist_ok=True)
        self.path = folder / (str(os.getpid()) + '-' + uuid.uuid4().hex + '.jsonl')
        self.lock = threading.Lock()
        self.sequence = 0

    def emit(self, action, result='', state='info', tool='', detail='', metrics=None):
        with self.lock:
            self.sequence += 1
            record = {'schema': 1, 'id': self.path.stem + ':' + str(self.sequence),
                      'time': dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds'),
                      'project': self.project, 'task': self.task, 'role': self.role,
                      'agent': LABELS[self.role], 'action': clean(action, 80), 'result': clean(result),
                      'state': state if state in ('info', 'running', 'done', 'failed', 'waiting') else 'info',
                      'tool': clean(tool, 80), 'detail': clean(detail)}
            if metrics:
                record['metrics'] = {k: max(0, int(v)) for k, v in metrics.items()
                                     if k in ('input', 'output', 'total', 'cache_read', 'cache_write', 'duration_ms')
                                     and isinstance(v, (int, float))}
            # The page reads only these bounded projections, not private process logs.
            with self.path.open('a', encoding='utf-8') as stream:
                stream.write(json.dumps(record, ensure_ascii=False) + '\n')
            return record


def supports_stream(command):
    """Static feature check, no model call and no import of a user's project modules."""
    exe = Path(command).resolve()
    for root in (exe.parent, exe.parent.parent, exe.parent.parent.parent):
        parser = root / 'hermes_cli' / '_parser.py'
        emitter = root / 'hermes_cli' / 'stream_json.py'
        if parser.is_file() and emitter.is_file():
            text = parser.read_text(encoding='utf-8')
            return 'stream-json' in text and '"--format"' in text
    return False


def stream_command(command):
    if '--format' not in command and supports_stream(command[0]):
        return list(command) + ['--format', 'stream-json']
    return list(command)


def capture(proc, journal, timeout, kill, heartbeat=60):
    """Drain BOTH pipes concurrently; preserve final text / STATUS, not JSON envelopes.

    Older Hermes versions remain usable. Their board explicitly reports that live
    per-tool events are unavailable instead of inventing tool activity.
    """
    incoming = queue.Queue(maxsize=128)
    def read(pipe, which):
        try:
            while True:
                line = pipe.readline(1024 * 1024)
                if not line: break
                incoming.put((which, line))
        finally:
            incoming.put((which, None))
            pipe.close()
    for which, pipe in (('out', proc.stdout), ('err', proc.stderr)):
        threading.Thread(target=read, args=(pipe, which), daemon=True).start()
    start = last = time.monotonic()
    ended, out, err = set(), collections.deque(maxlen=200), collections.deque(maxlen=100)
    final, saw_stream, expired = None, False, False
    pending, ambiguous = {}, set()
    while len(ended) < 2:
        if not expired and time.monotonic() - start >= timeout:
            kill(proc); expired = True
            journal.emit('실행 시간 한도', '프로세스 트리 종료, 저장된 파일 보존', 'failed')
        try:
            which, line = incoming.get(timeout=0.2)
        except queue.Empty:
            if time.monotonic() - last >= heartbeat:
                journal.emit('응답 대기', '프로세스 실행 중; 새로운 도구 이벤트는 아직 없음', 'running')
                last = time.monotonic()
            continue
        if line is None:
            ended.add(which); continue
        if which == 'err':
            err.append(line[-10000:]); continue
        try: event = json.loads(line)
        except (ValueError, TypeError):
            out.append(line[-20000:]); continue
        if not isinstance(event, dict) or event.get('type') not in ('system', 'text', 'tool_use', 'tool_result', 'result'):
            out.append(line[-20000:]); continue
        saw_stream = True
        kind, name = event['type'], str(event.get('name', ''))
        # Some Hermes versions omit call IDs even for parallel same-tool calls.
        # Never attach the last URL/file to a different completion by guessing.
        call = ('id', str(event['tool_call_id'])) if event.get('tool_call_id') else ('name', name)
        if kind == 'tool_use':
            detail = target(event.get('input'))
            group = pending.setdefault(call, [])
            group.append(detail)
            if len(group) > 1: ambiguous.add(call)
            journal.emit(tool_action(name), '시작', 'running', name, detail)
        elif kind == 'tool_result':
            failed = event.get('is_error') is True
            group = pending.get(call, [])
            uncertain = call in ambiguous
            detail = group[0] if len(group) == 1 and not uncertain else ''
            if group: group.pop(0)
            if not group:
                pending.pop(call, None); ambiguous.discard(call)
            message = failure_reason(event.get('output', '')) if failed else '완료'
            if uncertain: message += '（동시 호출: 개별 대상 연결 정보 없음）'
            journal.emit(tool_action(name), message, 'failed' if failed else 'done',
                         name, detail, {'duration_ms': event.get('duration_ms', 0)})
        elif kind == 'result':
            final = str(event.get('text') or '')
            journal.emit('모델 응답', '실패' if event.get('exit_code') else '응답 수신（작업·감사 완료 판정과 별개）',
                         'failed' if event.get('exit_code') else 'done', metrics=event.get('tokens'))
        # Deliberately discard text deltas: may contain reasoning or credentials.
        last = time.monotonic()
    proc.wait(timeout=20)
    if not saw_stream:
        journal.emit('관측 범위', '이 Hermes 버전은 도구별 실시간 이벤트를 제공하지 않음; 작업·파일 기록은 유지')
    return final if final is not None else ''.join(out), ''.join(err), 124 if expired else proc.returncode


def read_events(home, project=None, limit=500):
    """Read bounded tails; a partial write is ignored until the next poll."""
    rows = []
    folder = Path(home) / 'activity'
    if not folder.is_dir(): return []
    for path in sorted(folder.glob('*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)[:100]:
        if path.is_symlink(): continue
        try:
            with path.open('rb') as stream:
                stream.seek(max(0, path.stat().st_size - 256 * 1024))
                raw = stream.read(256 * 1024)
            for line in raw.splitlines():
                try: item = json.loads(line)
                except ValueError: continue
                if item.get('schema') != 1 or item.get('role') not in ROLES: continue
                if project and item.get('project') != project: continue
                # Never pass through unrecognized fields from tampered files.
                rows.append({k: item.get(k) for k in ('id', 'time', 'project', 'task', 'role', 'agent',
                                                     'action', 'result', 'state', 'tool', 'detail', 'metrics')})
        except OSError: continue
    return sorted(rows, key=lambda x: (x.get('time') or '', x.get('id') or ''))[-limit:]

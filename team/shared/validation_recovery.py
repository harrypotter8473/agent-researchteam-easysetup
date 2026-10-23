"""Read-only completion diagnosis. Findings request work; they never grant approval."""
import hashlib
import json
from pathlib import Path

import audit_gate


def split(value):
    return [x.strip() for x in (value or '').split(',') if x.strip()]


def output_files(items):
    names = set()
    for item in items:
        name, _, kind = item.partition(':')
        if not name or kind not in ('', 'docx'):
            raise ValueError('Invalid completion output')
        names.add(name)
        if kind == 'docx':
            if not name.endswith('.md'):
                raise ValueError('Word output requires Markdown source')
            names.add(str(Path(name).with_suffix('.docx')).replace('\\', '/'))
    return sorted(names)


def audit_findings(root, targets):
    """Explain stale/rejected receipts without changing receipt acceptance rules."""
    rows = []
    for path in sorted((Path(root) / '.tasks/audits').glob('*.json')):
        try:
            if path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
                continue
            value = json.loads(path.read_text(encoding='utf-8'))
            if not set(value.get('targets', ())).intersection(targets):
                continue
            changed = []
            for name, expected in value.get('files', {}).items():
                try:
                    actual = audit_gate.digest(audit_gate.safe_file(root, name))
                except (ValueError, OSError):
                    actual = 'missing_or_unsafe'
                if actual != expected:
                    changed.append({'path': name, 'expected': expected, 'actual': actual})
            task_changes = []
            for tid, expected in value.get('target_versions', {}).items():
                try:
                    actual = audit_gate.digest(audit_gate.safe_file(root, '.tasks/' + tid + '.md'))
                except (ValueError, OSError):
                    actual = 'missing_or_unsafe'
                if actual != expected:
                    task_changes.append(tid)
            rows.append({'receipt': path.name, 'scope': value.get('scope'),
                         'verdict': value.get('verdict'), 'changed_files': changed[:40],
                         'changed_tasks': task_changes[:40],
                         'findings': value.get('findings', [])[:20]})
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            continue
    return rows[-20:]


def completion_status(root, board, items=(), *, require_intermediate=False, observed=None):
    """Current gates for ONE request/thread, not all history in a shared report repo."""
    root = Path(root)
    producers = {tid: m for tid, (_, m, _) in board.items()
                 if m.get('assignee') in ('research-scout', 'research-worker')}
    deliver = list(items)
    if not deliver:
        deliver = [item for m in producers.values() for item in split(m.get('deliver'))]
    roots = {tid for tid, m in producers.items()
             if set(output_files(split(m.get('deliver')))).intersection(output_files(deliver))}
    relevant = set()

    def visit(tid):
        if tid in relevant or tid not in board:
            return
        relevant.add(tid)
        meta = board[tid][1]
        for other in split(meta.get('after')) + split(meta.get('audit_of')):
            visit(other)

    for tid in roots or producers:
        visit(tid)
    mids = set()
    for _, meta, _ in board.values():
        if meta.get('assignee') == 'research-reviewer' and meta.get('audit_scope', 'intermediate') == 'intermediate':
            mids.update(t for t in split(meta.get('audit_of')) if t in relevant and t in producers)
    if require_intermediate and not mids:
        candidates = {tid for tid in relevant if tid in producers and producers[tid].get('assignee') == 'research-scout'}
        mids = candidates or {tid for tid in relevant if tid in producers}
    receipts = list(audit_gate.receipts(root))
    current_mid = {t for r in receipts if r['scope'] == 'intermediate' for t in r['targets']}
    # An author may publish a replacement task rather than edit historical cards.
    # Accept it only for the SAME role and concrete output paths, with a genuine
    # current intermediate receipt binding every required byte. Old receipts and
    # rejected cards remain intact; merely naming a replacement is never a pass.
    for target in mids - current_mid:
        required = set(split(producers[target].get('expects')))
        for candidate, meta in producers.items():
            if (not required or meta.get('assignee') != producers[target].get('assignee') or
                    not required.issubset(split(meta.get('expects')))):
                continue
            if any(r['scope'] == 'intermediate' and candidate in r['targets'] and
                   required.issubset(r['files']) for r in receipts):
                current_mid.add(target)
    gaps = []
    missing_mids = sorted(mids - current_mid)
    mid_ok = not missing_mids and (not require_intermediate or bool(mids))
    if not mid_ok:
        gaps.append({'check': 'intermediate_audit', 'targets': missing_mids,
                     'reason': '현재 버전의 필수 중간감사 통과 기록이 없습니다.',
                     'evidence': audit_findings(root, missing_mids or relevant)})
    names = output_files(deliver)
    if names and not audit_gate.delivery_allowed(root, names):
        gaps.append({'check': 'audit', 'targets': sorted(roots),
                     'reason': '현재 최종 파일·근거 버전의 최종감사가 필요합니다.',
                     'evidence': audit_findings(root, relevant)})
    missing_files = []
    for name in names:
        try:
            audit_gate.safe_file(root, name)
        except (ValueError, OSError):
            missing_files.append(name)
    if missing_files:
        gaps.append({'check': 'output', 'paths': missing_files, 'reason': '필수 결과 파일이 없거나 안전하게 읽을 수 없습니다.'})
    known = {g['check'] for g in gaps}
    for check, passed in sorted((observed or {}).items()):
        if passed is False and check not in known:
            # Negative validator observations only request repairs. They can NEVER open a gate.
            if check == 'intermediate_audit' and mid_ok:
                continue
            if check == 'audit' and names and audit_gate.delivery_allowed(root, names):
                continue
            if check == 'output' and names and not missing_files:
                continue
            gaps.append({'check': check, 'reason': '설치된 검증기가 이 필수 검사를 통과하지 못했습니다. 실제 기록을 확인하고 담당자에게 보완·독립 검증을 배정하세요.'})
    active = any(m.get('status') in ('ready', 'running') for _, m, _ in board.values())
    human = any((m.get('gate') == 'human' and m.get('status') in ('blocked', 'done')) or
                (m.get('status') == 'partial' and m.get('resume_policy') == 'manual')
                for _, m, _ in board.values())
    # Exclude task timestamps, Git commit IDs, review wording and coordinator chatter.
    # Repeating a poll or appending a narrative is not evidence of repair progress.
    content = {}
    for tid in sorted(relevant):
        if tid not in producers:
            continue
        for name in split(producers[tid].get('expects')):
            try:
                content[name] = audit_gate.digest(audit_gate.safe_file(root, name))
            except (ValueError, OSError):
                content[name] = 'missing_or_unsafe'
    progress = hashlib.sha256(json.dumps({'missing': sorted(g['check'] for g in gaps),
                                         'content': content}, sort_keys=True).encode()).hexdigest()
    return {'missing': gaps, 'intermediate_audit': mid_ok, 'outputs': names,
            'active': active, 'human_required': human, 'progress': progress}


def recovery_event(root, board, request):
    thread = request.get('thread', '')
    group = {tid: task for tid, task in board.items() if task[1].get('thread', '') == thread}
    if not group:
        return None, None
    declared_delivery = bool(request.get('outputs') or any(m.get('deliver') for _, m, _ in group.values()))
    status = completion_status(root, group, request.get('outputs', ()),
                               require_intermediate=request.get('require_intermediate', declared_delivery),
                               observed=request.get('checks'))
    if not status['missing'] or status['active'] or status['human_required']:
        return None, status
    task = next((t for g in status['missing'] for t in g.get('targets', ()) if t in group), sorted(group)[0])
    event = {'task': task, 'status': 'blocked', 'observed_status': group[task][1].get('status'),
             'diagnostic': 'RequiredValidationMissing', 'thread': thread,
             'missing_checks': status['missing'], 'outputs': status['outputs'], 'progress': status['progress'],
             'instruction': 'This is a validator observation, not permission or an agent result. '
             'Inspect current versions and prior reject/unverifiable findings. Assign corrections to the original '
             'responsible role; the reviewer must not edit originals. Create independent intermediate re-audits '
             'of the corrected producers and revalidate affected downstream analysis/final artifacts. '
             'A final pass does not replace a required intermediate pass. Never edit receipts, readiness flags, '
             'history or budgets. Reuse saved evidence. Ask the human only for a specific missing input or authority; '
             'record that task as gate=human/status=blocked with the exact question. Otherwise keep working.'}
    return event, status


def recovery_step(previous, status, clock, *, max_attempts, no_progress_limit=3, interval=60):
    """Persistent scheduling decision, not a pass/fail authority or budget reset.

    The caller increments attempts only when the lead is actually invoked. Ready
    workers, new timestamps and repeated polls do not consume an attempt. Changes
    to task IDs alone do not erase failed recovery history.
    """
    state = dict(previous or {})
    state['missing'] = status['missing']
    if status['human_required']:
        state.update(state='waiting_for_user', reason='명시된 사용자 입력·승인 또는 수동 실험 재개가 필요합니다.')
        return 'wait', state
    if status['active']:
        state.update(state='waiting_for_workers', reason='이미 배정된 담당 작업·감사가 실행 중입니다.')
        return 'wait', state
    if not status['missing']:
        state.update(state='verified', reason='현재 파일 버전의 필수 검증을 확인했습니다.')
        return 'complete', state
    if any(g['check'] == 'ledger' for g in status['missing']):
        state.update(state='paused', reason='작업 원장 무결성 검증이 실패했습니다. 원장을 덮어쓰지 않고 확인이 필요합니다.')
        return ('wait' if previous and previous.get('state') == 'paused' else 'pause'), state
    progressed = state.get('progress') != status['progress']
    if state.get('state') == 'paused' and not progressed:
        return 'wait', state
    attempts = int(state.get('attempts', 0))
    repeats = 0 if progressed else int(state.get('no_progress', 0))
    if attempts >= max_attempts or repeats >= no_progress_limit:
        state.update(state='paused', reason='필수 검증 복구의 실행 한도 또는 무진전 반복 한도에 도달했습니다. 누락 검사·담당 조치 기록을 확인하세요.')
        return 'pause', state
    if clock < state.get('next_try', 0):
        return 'wait', state
    state.update(state='recovering', progress=status['progress'], no_progress=repeats,
                 reason='누락된 필수 검증을 총괄에게 전달해 담당자 수정·독립 재감사를 배정합니다.')
    return 'invoke', state


def invoked(state, clock, *, interval=60):
    state = dict(state)
    state.update(attempts=int(state.get('attempts', 0)) + 1,
                 no_progress=int(state.get('no_progress', 0)) + 1,
                 next_try=clock + interval)
    return state

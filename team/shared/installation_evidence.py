"""Installation checks over real board evidence, also exercised with offline fixtures."""
import csv
import hashlib
import json
import math
import statistics
import sys
from pathlib import Path
_SHARED = Path(__file__).resolve().parent
if str(_SHARED) not in sys.path:
    sys.path.insert(0, str(_SHARED))
import audit_gate

ROLES = {'research-lead', 'research-scout', 'research-worker', 'research-reviewer'}
SCENARIOS = {
    'S1': ('RAG 관련 연구를 시작하려고 해. 기존 접근법의 방법·데이터·성과·한계를 원문 근거와 비교한 Word 문헌검토 보고서를 만들어줘. 참고문헌과 후속 연구 질문도 포함해줘.', 'reports/result.md:docx'),
    'S2': ('제공한 합성 CSV와 데이터 사전으로 A/B 조건의 측정값 차이를 검토해줘. 결측·중복·단위를 점검하고 그룹별 표본 수·평균·표본 표준편차와 그래프를 실제 계산해줘. 실행 코드·재실행 방법·분석 보고서·검증 기록을 함께 줘.', 'reports/result.md:docx'),
    'S3': ('제공한 검증된 합성 분석 참조 결과를 이 PC의 연구자에게 공유할 내부 웹 보고서로 정리해줘. 목적·방법·수치·한계·출처와 버전을 연결하고 공유 전에 대조 검증해줘.', 'reports/result.html'),
}


def verify_numbers(root):
    root = Path(root)
    # Fixed installation fixture, never represented as scientific evidence.
    with (root / 'sources/measurements.csv').open(encoding='utf-8') as stream:
        rows = list(csv.DictReader(stream))
    got = json.loads((root / 'evidence/statistics.json').read_text(encoding='utf-8'))
    for group in ('A', 'B'):
        values = [float(r['value']) for r in rows if r['condition'] == group]
        expected = {'n': len(values), 'mean': statistics.mean(values), 'sample_std': statistics.stdev(values)}
        if set(got.get(group, {})) != set(expected):
            return False
        if any(not isinstance(got[group][k], (int, float)) or
               not math.isclose(got[group][k], v, rel_tol=1e-6, abs_tol=1e-6) for k, v in expected.items()):
            return False
    return (any((root / 'experiments').rglob('*.py')) and
            any(p.suffix.lower() in ('.svg', '.png') for p in (root / 'evidence').rglob('*')))


def scenario_evidence(root, name, lead_ran, ledger_ok):
    root = Path(root)
    target = SCENARIOS[name][1].partition(':')[0]
    try:
        events = [json.loads(l) for l in (root / '.tasks/ledger.jsonl').read_text(encoding='utf-8').splitlines() if l.strip()]
        completed = {e['role'] for e in events if e.get('status') == 'done'}
        if lead_ran:
            completed.add('research-lead')
        approved = audit_gate.delivery_allowed(root, [target])
        all_roles = ROLES.issubset(completed)
        receipts = list(audit_gate.receipts(root))
        intermediate = any(r['scope'] == 'intermediate' for r in receipts)
        checks = {'roles': all_roles, 'ledger': bool(ledger_ok), 'audit': approved,
                  'intermediate_audit': intermediate, 'output': (root / target).is_file()}
        if name == 'S1':
            checks['sources_saved'] = any(p.is_file() and p.name != '.gitkeep' and p.stat().st_size >= 200 for p in (root / 'sources').rglob('*'))
        if name == 'S2':
            checks['numeric_recalculation'] = verify_numbers(root)
        if name == 'S3':
            html = (root / target).read_text(encoding='utf-8')
            checks['html'] = '<html' in html.lower() and 'verified-reference' in html
        return {'ready_for_delivery': all(checks.values()), 'checks': checks,
                'roles': sorted(completed), 'artifact_sha256': audit_gate.digest(root / target) if (root / target).is_file() else ''}
    except (OSError, ValueError, KeyError, TypeError):
        return {'ready_for_delivery': False, 'checks': {}, 'roles': []}


REQUIRED_CHECKS = {'roles', 'ledger', 'audit', 'intermediate_audit', 'output'}
SCENARIO_CHECKS = {'S1': {'sources_saved'}, 'S2': {'numeric_recalculation'},
                   'S3': {'html', 'local_http'}}


def suite_ready(result, binding):
    scenarios = result.get('scenarios', {})
    return (result.get('live') is True and result.get('binding') == binding and
            set(scenarios) == set(SCENARIOS) and
            all(s.get('ready_for_delivery') is True and s.get('delivered') is True and
                set(s.get('roles', [])) == ROLES and all(s.get('checks', {}).values()) and
                (REQUIRED_CHECKS | SCENARIO_CHECKS[name]).issubset(s.get('checks', {})) and
                isinstance(s.get('artifact_sha256'), str) and len(s['artifact_sha256']) == 64
                for name, s in scenarios.items()))

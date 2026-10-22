"""Read-only comparison of fork and hybrid contracts; not an LLM quality benchmark."""
import argparse
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'team/shared'))

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

def inspect(base, name):
    rb = load(base / 'team/shared/research_board.py', name)
    with tempfile.TemporaryDirectory(prefix='compare-') as tmp:
        root = Path(tmp); (root/'.tasks').mkdir(); (root/'reports').mkdir()
        (root/'reports/result.md').write_text('# Fixture\nNot a real report.', encoding='utf-8')
        (root/'reports/result.html').write_text('<html>Not a real report</html>', encoding='utf-8')
        task = root/'.tasks/p.md'; task.write_text('producer')
        producer = {'p':(task, {'status':'done','assignee':'research-scout'}, '')}
        gated = bool(rb.waiting_on({'after':'p','assignee':'research-worker'}, producer))
        # Replace only transport for this component experiment. No model or network.
        rb.sync = lambda repo: None
        rb.git = lambda *a, **k: SimpleNamespace(stdout='', returncode=0)
        rb.Notifier = lambda *a: SimpleNamespace(deliver=lambda *args: (True, 'fixture'))
        results = {}
        for scenario, file in [('S1','reports/result.md'),('S2','reports/result.md'),('S3','reports/result.html')]:
            try:
                rb.cmd_deliver(SimpleNamespace(paper=str(root), items=[file], profile='research-lead', thread='fixture', label='offline'))
            except SystemExit as e:
                results[scenario] = {'unaudited_delivery_blocked':e.code not in (None,0)}
        return {'runner_roles':list(rb.OUTPUTS), 'blind_roles':sorted(rb.BLIND),
                'max_turns':rb.TEAM_MAX_TURNS, 'transient_retries':len(rb.RETRY_DELAYS),
                'dependent_work_requires_audit':gated, 'scenarios':results}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--fork', required=True); ap.add_argument('--output', required=True)
    a=ap.parse_args()
    value={'scope':'offline contract comparison only; NO claim about live S1/S2/S3 quality',
           'model_calls':0, 'fork':inspect(Path(a.fork),'fork_board'),
           'hybrid':inspect(ROOT,'hybrid_board'),
           'quality_winner':None, 'quality_status':'requires matched real model runs in an approved isolated installation'}
    Path(a.output).write_text(json.dumps(value, ensure_ascii=False, indent=2),encoding='utf-8')
    print(json.dumps(value, ensure_ascii=False))
if __name__=='__main__': main()

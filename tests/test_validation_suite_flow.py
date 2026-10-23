"""Offline installed-suite control flow, NOT real-model installation evidence.

Runs the production suite, Git board, blind snapshot, audit runner, validator,
recovery watchdog and local HTTP check. Only model and Mattermost boundaries are
fixtures. Every S1/S2/S3 starts with an invalid intermediate pass and valid final.
"""
import json
import contextlib
import io
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'team/shared'))
import research_board as rb
import team_selftest as suite
import audit_gate as ag


class SuiteRecoveryFlow(unittest.TestCase):
    def test_s1_s2_s3_only_advance_after_current_blind_reaudit(self):
        with tempfile.TemporaryDirectory(prefix='suite-flow-') as tmp:
            base = Path(tmp); home = base / 'runtime'; workspace = base / 'workspace'; workspace.mkdir()
            for name in ('team.json', 'service.json', 'team/manifest.json', 'team/shared/profile-manifest.json'):
                p = home / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('{}')
            real_board = suite.board
            projects = []; repaired = []; delivered = []; state = {}; errors = {}

            def write(root, name, value):
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(value, encoding='utf-8'); return p

            def publish(root):
                rb.git(root, 'add', '.'); rb.commit_push(root, 'offline fixture')

            def receipt(root, name, targets, scope, files, verdict='pass'):
                contract = ag.contract(root, targets, scope, files)
                contract['target_versions'] = {t: ag.digest(root / '.tasks' / (t + '.md')) for t in targets}
                result = verdict_result(verdict)
                write(root, '.tasks/audits/' + name + '.json', json.dumps(ag.validate(root, contract, result)))

            def verdict_result(verdict):
                return {'verdict': verdict, 'checks': {c: {'status': verdict, 'evidence': 'OFFLINE location checked'} for c in ag.CHECKS},
                        'findings': [] if verdict == 'pass' else [{'location': 'sources/extract.md:1', 'evidence': 'numeric mismatch',
                            'correction': 'use corrected source value', 'blocking': True}], 'notes': 'OFFLINE MODEL FIXTURE'}

            def transport(*args, cwd, check=True):
                if args[0] == 'setup':
                    write(Path(args[1]), '.tasks/board.conf', 'mattermost_channel=offline-channel\n')
                    publish(Path(args[1])); return SimpleNamespace(returncode=0, stdout='', stderr='')
                if args[0] == 'thread':
                    return SimpleNamespace(returncode=0, stdout='thread-' + Path(args[1]).name, stderr='')
                return real_board(*args, cwd=cwd, check=check)

            def dispatch(command, **kwargs):
                root = Path(kwargs['cwd']); name = json.loads((root / '.tasks/project.json').read_text())['validation']
                self.assertEqual(delivered, list(suite.SCENARIOS)[:len(projects)], 'next scenario must wait for verified prior delivery')
                projects.append(name)
                return SimpleNamespace(returncode=0, root=root, name=name)

            def capture(proc, *args):
                root = proc.root
                output = suite.SCENARIOS[proc.name][1]
                final_files = ['reports/result.html'] if proc.name == 'S3' else ['reports/result.md', 'reports/result.docx']
                write(root, 'sources/extract.md', 'old primary evidence ' * 30)
                for tid, role, meta in (
                        ('source', 'research-scout', {'expects': 'sources/extract.md'}),
                        ('middle', 'research-reviewer', {'after': 'source', 'audit_of': 'source', 'audit_scope': 'intermediate'}),
                        ('author', 'research-worker', {'after': 'middle', 'expects': ','.join(final_files), 'deliver': output}),
                        ('final', 'research-reviewer', {'after': 'author', 'audit_of': 'author', 'audit_scope': 'final'})):
                    rb.save(root / '.tasks' / (tid + '.md'), {'id': tid, 'status': 'done', 'assignee': role,
                        'thread': 'thread-' + root.name, **meta}, 'OFFLINE initial task')
                    rb.ledger_append(root, {'task': tid, 'role': role, 'status': 'done'})
                receipt(root, 'middle-old', ['source'], 'intermediate', ['sources/extract.md'])
                write(root, 'sources/extract.md', 'corrected primary evidence ' * 30)
                receipt(root, 'middle-rejected', ['source'], 'intermediate', ['sources/extract.md'], 'reject')
                for name in final_files:
                    write(root, name, '<html>verified-reference synthetic report</html>' if name.endswith('.html') else 'OFFLINE prepared report bytes')
                if proc.name == 'S2':
                    write(root, 'evidence/statistics.json', json.dumps({'A': {'n': 2, 'mean': 2, 'sample_std': math.sqrt(2)},
                                                                     'B': {'n': 2, 'mean': 6, 'sample_std': math.sqrt(8)}}))
                    write(root, 'experiments/reproduce.py', '# offline fixture code')
                    write(root, 'evidence/chart.svg', '<svg/>')
                files = [p.relative_to(root).as_posix() for d in ('sources', 'evidence', 'reports', 'experiments')
                         for p in (root / d).rglob('*') if p.is_file()]
                receipt(root, 'final-current', ['author'], 'final', files)
                publish(root)
                return 'OFFLINE dispatched', '', 0

            def model_recovery(args, root, event, *rest):
                self.assertEqual(event['diagnostic'], 'RequiredValidationMissing')
                self.assertIn('intermediate_audit', [g['check'] for g in event['missing_checks']])
                self.assertEqual(delivered, list(suite.SCENARIOS)[:len(repaired)])
                tid = 'middle-current'
                real_board('new', str(root), '--id', tid, '--assignee', 'research-reviewer', '--audit-of', 'source',
                           '--audit-scope', 'intermediate', '--expects', 'reviews/' + tid + '/verdict.json',
                           '--thread', event['thread'], '--body', 'OFFLINE independent re-audit', cwd=workspace)
                task = root / '.tasks' / (tid + '.md')
                self.assertTrue(rb.claim(root, task, 'offline-reviewer'))
                def audit_model(a, command, snapshot, *rest):
                    self.assertFalse((snapshot / '.git').exists())
                    self.assertFalse((snapshot / '.tasks').exists())
                    write(snapshot, 'reviews/' + tid + '/verdict.json', json.dumps(verdict_result('pass')))
                    return 'OFFLINE independent fixture\nSTATUS: done', '', 0
                with patch.object(rb, 'run_agent', side_effect=audit_model):
                    rb.execute(SimpleNamespace(role='research-reviewer', profile=None, hermes='OFFLINE-NOT-EXECUTED',
                        yolo=False, task_timeout=60, heartbeat=1), root, task, 'offline-reviewer')
                repaired.append(json.loads((root / '.tasks/project.json').read_text())['validation'])
                return True

            def poll(_seconds):
                result = json.loads((home / 'live-test.json').read_text(encoding='utf-8'))
                name = projects[-1]; root = Path(result['folder']) / (result['binding'][:12] + '-' + name.lower())
                key = rb.validation_remote_key(root)
                rb.recover_required_validation(SimpleNamespace(interval=30), root, state, key,
                    home / 'run/lead-coordinator.json', errors, home / 'run/errors.json')

            def delivery(root, output, thread):
                name = json.loads((root / '.tasks/project.json').read_text())['validation']
                self.assertIn(name, repaired, 'final-only pass must never advance scenario')
                delivered.append(name)
                return {'verified': True, 'reason': 'OFFLINE transport fixture'}

            with patch.dict(os.environ, {'RESEARCH_TEAM_HOME': str(home), 'PYTHONUTF8': '1'}), \
                 patch.object(rb, 'TEAM_HOME', home), patch.object(rb, 'profile_drift', return_value=[]), \
                 patch.object(rb, 'child_env', return_value=({}, 'public', False)), \
                 patch.object(rb, 'popen_group', side_effect=dispatch), patch.object(rb.activity, 'capture', side_effect=capture), \
                 patch.object(suite, 'board', side_effect=transport), patch.object(suite, 'verify_lead_attachment', side_effect=delivery), \
                 patch.object(rb, 'coordinate_with_retry', side_effect=model_recovery), patch.object(suite.time, 'sleep', side_effect=poll), \
                 patch.object(sys, 'argv', ['team_selftest', '--workspace', str(workspace), '--channel', 'offline/channel', '--hermes', 'OFFLINE-NOT-EXECUTED']):
                # Do not print a fixture's live=true JSON into regression logs
                # where it could be mistaken for real installed-model evidence.
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(suite.main(), 0)
            self.assertEqual(projects, ['S1', 'S2', 'S3'])
            self.assertEqual(repaired, projects); self.assertEqual(delivered, projects)
            result = json.loads((home / 'live-test.json').read_text(encoding='utf-8'))
            self.assertTrue(result['scenarios']['S3']['checks']['local_http'])
            # This temporary result is deleted with its fixture, never installed
            # or published as real-model evidence.


if __name__ == '__main__': unittest.main()

"""Offline recovery regression: real files/receipts/Git, mocked model boundary.

These tests prove scheduler/gate behavior, NOT a real-model S1/S2/S3 pass.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'team/shared'))
import audit_gate as ag
import research_board as rb
import validation_recovery as vr
import installation_evidence as ie
import team_selftest as suite


class RecoveryFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='validation-recovery-')
        self.root = Path(self.temp.name)
        self.home = self.root / 'runtime'
        self.repo = self.root / 'project'; self.repo.mkdir()
        self.board = {}
        self.file('sources/evidence.md', 'original evidence ' * 25)
        self.file('reports/result.md', '# Report\nCorrected current report')
        self.file('reports/result.docx', b'prepared Word bytes')
        self.file('REQUEST.md', 'desired outcome')
        self.task('scout', 'research-scout', expects='sources/evidence.md')
        self.task('mid', 'research-reviewer', after='scout', audit_of='scout', audit_scope='intermediate')
        self.task('worker', 'research-worker', after='mid', expects='reports/result.md,reports/result.docx', deliver='reports/result.md:docx')
        self.task('final', 'research-reviewer', after='worker', audit_of='worker', audit_scope='final')
        self.receipt('mid-old', ['scout'], 'intermediate', ['sources/evidence.md'])
        self.file('sources/evidence.md', 'corrected source numeric value ' * 25)
        self.receipt('mid-rejected', ['scout'], 'intermediate', ['sources/evidence.md'], verdict='reject')
        self.receipt('final-pass', ['worker'], 'final', ['sources/evidence.md', 'reports/result.md', 'reports/result.docx'])

    def tearDown(self):
        self.temp.cleanup()

    def file(self, name, value):
        path = self.repo / name; path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, bytes): path.write_bytes(value)
        else: path.write_text(value, encoding='utf-8')
        return path

    def task(self, tid, role, **meta):
        value = {'id': tid, 'assignee': role, 'status': 'done', 'thread': 'request', **meta}
        path = self.repo / '.tasks' / (tid + '.md')
        path.parent.mkdir(parents=True, exist_ok=True)
        rb.save(path, value, 'task ' + tid)
        self.board[tid] = (path, value, 'task ' + tid)

    def receipt(self, name, targets, scope, files, verdict='pass'):
        assignment = ag.contract(self.repo, targets, scope, files)
        assignment['target_versions'] = {t: ag.digest(self.repo / '.tasks' / (t + '.md')) for t in targets}
        result = {'verdict': verdict, 'checks': {k: {'status': verdict, 'evidence': 'offline fixture: verified location'} for k in ag.CHECKS},
                  'findings': [] if verdict == 'pass' else [{'location': 'sources/evidence.md:1', 'evidence': 'numeric mismatch',
                      'correction': 'recalculate against saved source', 'blocking': True}], 'notes': 'OFFLINE FIXTURE ONLY'}
        self.file('.tasks/audits/' + name + '.json', json.dumps(ag.validate(self.repo, assignment, result)))

    def request(self):
        return {'thread': 'request', 'outputs': ['reports/result.md:docx'], 'require_intermediate': True}

    def status(self):
        return vr.recovery_event(self.repo, self.board, self.request())

    def test_final_pass_does_not_hide_stale_and_rejected_middle_audits(self):
        self.assertTrue(ag.delivery_allowed(self.repo, ['reports/result.md', 'reports/result.docx']))
        event, status = self.status()
        self.assertEqual(event['diagnostic'], 'RequiredValidationMissing')
        self.assertEqual(event['observed_status'], 'done')
        self.assertEqual([g['check'] for g in status['missing']], ['intermediate_audit'])
        evidence = event['missing_checks'][0]['evidence']
        self.assertTrue(any(r['changed_files'] for r in evidence))
        self.assertTrue(any(r['verdict'] == 'reject' and r['findings'][0]['correction'] for r in evidence))

    def test_only_current_independent_middle_receipt_opens_gate(self):
        before = {p.name: p.read_bytes() for p in (self.repo / '.tasks/audits').glob('*.json')}
        self.receipt('mid-new', ['scout'], 'intermediate', ['sources/evidence.md'])
        event, status = self.status()
        self.assertIsNone(event); self.assertFalse(status['missing'])
        for name, data in before.items(): self.assertEqual((self.repo / '.tasks/audits' / name).read_bytes(), data)
        self.file('sources/evidence.md', 'later edit')
        self.assertIsNotNone(self.status()[0])

    def test_another_thread_or_final_receipt_cannot_supply_middle_pass(self):
        self.task('other-scout', 'research-scout', thread='other', expects='sources/evidence.md')
        self.receipt('other-pass', ['other-scout'], 'intermediate', ['sources/evidence.md'])
        self.assertEqual(self.status()[1]['missing'][0]['targets'], ['scout'])

    def test_ready_running_and_real_user_gates_do_not_duplicate_work(self):
        for change in ({'status': 'ready'}, {'status': 'running'}, {'gate': 'human', 'status': 'blocked'},
                       {'status': 'partial', 'resume_policy': 'manual'}):
            original = dict(self.board['scout'][1]); self.board['scout'][1].update(change)
            with self.subTest(change=change): self.assertIsNone(self.status()[0])
            self.board['scout'][1].clear(); self.board['scout'][1].update(original)

    def test_positive_observation_cannot_forge_pass_and_negative_is_actionable(self):
        req = self.request(); req['checks'] = {'intermediate_audit': True, 'numeric_recalculation': False}
        event, status = vr.recovery_event(self.repo, self.board, req)
        self.assertEqual({g['check'] for g in status['missing']}, {'intermediate_audit', 'numeric_recalculation'})

    def test_non_s1_required_checks_wake_lead_without_changing_evidence(self):
        self.receipt('current-middle', ['scout'], 'intermediate', ['sources/evidence.md'])
        before = ag.digest(self.repo / 'sources/evidence.md')
        for check in ('numeric_recalculation', 'html', 'roles', 'lead_delivery', 'custom_required_check'):
            request = self.request(); request['checks'] = {check: False}
            event, status = vr.recovery_event(self.repo, self.board, request)
            with self.subTest(check=check):
                self.assertEqual([g['check'] for g in event['missing_checks']], [check])
                self.assertEqual(status['outputs'], ['reports/result.docx', 'reports/result.md'])
                self.assertEqual(ag.digest(self.repo / 'sources/evidence.md'), before)

    def test_timestamps_and_new_card_ids_do_not_reset_recovery_limit(self):
        _, status = self.status(); previous = {}
        for i in range(3):
            action, previous = vr.recovery_step(previous, status, i * 100, max_attempts=50)
            self.assertEqual(action, 'invoke'); previous = vr.invoked(previous, i * 100)
            previous = json.loads(json.dumps(previous))  # process restart
            self.board['scout'][1]['updated'] = str(i)
            self.assertEqual(self.status()[1]['progress'], status['progress'])
        action, stopped = vr.recovery_step(previous, status, 500, max_attempts=50)
        self.assertEqual(action, 'pause'); self.assertEqual(stopped['attempts'], 3)
        self.assertEqual(vr.recovery_step(stopped, status, 900, max_attempts=50)[0], 'wait')

    def test_changed_file_allows_progress_but_never_resets_attempts(self):
        status = self.status()[1]
        _, old = vr.recovery_step({}, status, 0, max_attempts=1)
        old = vr.invoked(old, 0)
        self.file('sources/evidence.md', 'actually revised evidence')
        action, state = vr.recovery_step(old, self.status()[1], 100, max_attempts=1)
        self.assertEqual(action, 'pause'); self.assertEqual(state['attempts'], 1)

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True, encoding='utf-8').stdout.strip()

    def init_git(self):
        self.git('init', '-q'); self.git('config', 'user.name', 'Offline Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('remote', 'add', 'origin', str(self.root / 'board.git'))
        self.git('add', '.'); self.git('commit', '-qm', 'offline fixture')

    def test_negative_observation_is_bound_to_tree_remote_and_thread(self):
        self.init_git()
        with patch.object(rb, 'TEAM_HOME', self.home):
            rb.observe_validation(self.repo, 'request', ['reports/result.md:docx'], {'numeric_recalculation': False})
            self.assertFalse(rb.required_validation_requests(self.repo)['request']['checks']['numeric_recalculation'])
            self.file('reports/result.md', 'corrected'); self.git('add', '.'); self.git('commit', '-qm', 'correction')
            self.assertNotIn('checks', rb.required_validation_requests(self.repo)['request'])
            rb.register_validation_request(self.repo, 'other', 'other-task')
            self.assertEqual(set(rb.required_validation_requests(self.repo)), {'request', 'other'})

    def test_all_done_watchdog_actually_invokes_lead_and_persists_count(self):
        self.init_git(); state = {}; state_path = self.home / 'run/lead-coordinator.json'
        key = __import__('hashlib').sha256(str(self.root / 'board.git').encode()).hexdigest()
        with patch.object(rb, 'TEAM_HOME', self.home), patch.object(rb, 'sync'), \
             patch.object(rb, 'coordinate_with_retry', return_value=True) as lead:
            rb.register_validation_request(self.repo, 'request', 'final')
            args = SimpleNamespace(interval=30)
            rb.recover_required_validation(args, self.repo, state, key, state_path, {}, self.home / 'errors.json')
            self.assertEqual(lead.call_count, 1)
            self.assertEqual(lead.call_args.args[2]['diagnostic'], 'RequiredValidationMissing')
            saved = json.loads(state_path.read_text(encoding='utf-8'))
            self.assertEqual(saved['validation:' + key]['request']['attempts'], 1)
            rb.recover_required_validation(args, self.repo, saved, key, state_path, {}, self.home / 'errors.json')
            self.assertEqual(lead.call_count, 1)

    def test_real_scenario_gate_remains_closed_until_reaudit(self):
        events = [{'role': r, 'status': 'done'} for r in ie.ROLES - {'research-lead'}]
        self.file('.tasks/ledger.jsonl', '\n'.join(json.dumps(e) for e in events))
        self.assertFalse(ie.scenario_evidence(self.repo, 'S1', True, True)['ready_for_delivery'])
        self.receipt('current-middle', ['scout'], 'intermediate', ['sources/evidence.md'])
        self.assertTrue(ie.scenario_evidence(self.repo, 'S1', True, True)['ready_for_delivery'])

    def test_replacement_author_requires_current_middle_receipt_for_same_role_and_paths(self):
        self.task('repair', 'research-scout', expects='sources/evidence.md')
        self.receipt('repair-pass', ['repair'], 'intermediate', ['sources/evidence.md'])
        self.assertFalse(self.status()[1]['missing'])
        self.file('sources/evidence.md', 'changed again')
        self.assertTrue(self.status()[1]['missing'])

    def test_no_duplicate_upload_after_successful_post_but_interrupted_ack(self):
        note = object.__new__(rb.Notifier); note.creds = ('local', 'fixture'); note.channel = 'channel'
        def api(creds, method, path):
            if path == '/users/me': return {'id': 'lead'}
            if path == '/posts/request/thread':
                return {'posts': {'p': {'id': 'p', 'user_id': 'lead', 'channel_id': 'channel',
                        'root_id': 'request', 'file_ids': ['file']}}}
            if path == '/files/file/info': return {'name': 'result.docx', 'size': 4}
            raise AssertionError(path)
        with patch.object(rb, 'mm_api', side_effect=api), patch.object(rb, 'mm_download', return_value=b'word'), \
             patch.object(rb, 'mm_upload', side_effect=AssertionError('duplicate upload')):
            self.assertTrue(note.deliver('result.docx', b'word', 'test', 'request', 'result')[0])

    def test_delivery_lookup_failure_is_not_permission_for_duplicate_post(self):
        note = object.__new__(rb.Notifier); note.creds = ('local', 'fixture'); note.channel = 'channel'
        with patch.object(rb, 'mm_api', side_effect=OSError('connection unavailable')), \
             patch.object(rb, 'mm_upload', side_effect=AssertionError('uncertain duplicate')):
            self.assertFalse(note.deliver('result.docx', b'word', 'test', 'request', 'result')[0])


if __name__ == '__main__': unittest.main()

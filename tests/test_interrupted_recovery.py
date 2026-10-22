"""Real isolated Git recovery: no model, profiles, server or real runtime writes."""
import json
import subprocess as sp
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'team/shared'))
import research_board as board


class InterruptedRecovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='interrupted-runner-')
        self.root = Path(self.temp.name)
        self.bare = self.root / 'remote.git'
        self.clone = self.root / 'worker'
        sp.run(['git', 'init', '--bare', str(self.bare)], capture_output=True, check=True)
        sp.run(['git', 'clone', '-c', 'core.autocrlf=false', str(self.bare), str(self.clone)], capture_output=True, check=True)
        board.git_identity(self.clone, 'offline worker')
        self.task = self.clone / '.tasks/task.md'
        self.task.parent.mkdir()
        board.save(self.task, {'id': 'task', 'assignee': 'research-worker', 'status': 'running',
            'claimed_by': 'pc/worker/slot1', 'attempt': '1', 'max_attempts': '3',
            'resume_policy': 'auto', 'gate': 'auto', 'expects': 'reports/result.html'}, 'Original assignment')
        board.publish(self.clone, ['.tasks'], 'owned claim')
        self.output = self.clone / 'reports/result.html'
        self.output.parent.mkdir()
        self.output.write_text('<h1>검수 전 초안</h1>', encoding='utf-8')
        self.original = self.output.read_bytes()
        self.home_patch = patch.object(board, 'TEAM_HOME', self.root / 'isolated-runtime')
        self.home_patch.start()

    def tearDown(self):
        self.home_patch.stop()
        self.temp.cleanup()

    def recover(self):
        return board.recover_interrupted_claims(self.clone, 'research-worker', 'pc/worker/slot1')

    def test_partial_saved_before_reset_then_attempt_increments_without_approval(self):
        self.assertEqual(self.recover(), 1)
        board.reset_to_remote(self.clone)
        self.assertEqual(self.output.read_bytes(), self.original)
        meta, _ = board.load(self.task)
        self.assertEqual((meta['status'], meta['attempt']), ('ready', '1'))
        record = json.loads((self.clone / '.tasks/attempts/task/1.json').read_text())
        self.assertEqual(record['status'], 'partial')
        self.assertEqual(record['origin'], 'interrupted-runner')
        entries = [json.loads(x) for x in board.ledger_lines(self.clone)]
        self.assertEqual(entries[0]['outputs']['reports/result.html'], board.sha256_file(self.output))
        self.assertIsNone(board.ledger_check(board.ledger_lines(self.clone)))
        self.assertFalse(board.audit_gate.approved(self.clone, 'task'))
        self.assertEqual(self.recover(), 0)
        self.assertEqual(len(board.ledger_lines(self.clone)), 1)
        self.assertTrue(board.claim(self.clone, self.task, 'pc/worker/slot1'))
        self.assertEqual(board.load(self.task)[0]['attempt'], '2')

    def test_manual_or_exhausted_or_human_gate_does_not_auto_resume(self):
        for field, value in [('resume_policy', 'manual'), ('max_attempts', '1'), ('gate', 'human')]:
            with self.subTest(field=field):
                meta, body = board.load(self.task)
                meta.update(status='running', claimed_by='pc/worker/slot1', resume_policy='auto',
                            max_attempts='3', gate='auto')
                meta[field] = value
                board.save(self.task, meta, body)
                board.publish(self.clone, ['.tasks'], 'policy')
                attempt = self.clone / '.tasks/attempts/task/1.json'
                if attempt.exists():
                    # Each subcase is an independent simulated first interruption.
                    attempt.unlink()
                    board.publish(self.clone, ['.tasks'], 'offline test fixture reset')
                self.recover()
                self.assertEqual(board.load(self.task)[0]['status'], 'partial')
                self.assertEqual(self.output.read_bytes(), self.original)

    def test_unknown_changes_are_preserved_and_not_published(self):
        other = self.clone / 'REQUEST.md'
        other.write_text('must not discard or attribute to worker')
        with self.assertRaisesRegex(RuntimeError, 'outside role'):
            self.recover()
        self.assertEqual(self.output.read_bytes(), self.original)
        self.assertTrue(other.exists())
        self.assertEqual(board.load(self.task)[0]['status'], 'running')

    def test_changed_remote_claim_is_not_overwritten(self):
        second = self.root / 'lead'
        sp.run(['git', 'clone', str(self.bare), str(second)], check=True, capture_output=True)
        board.git_identity(second, 'offline lead')
        p = second / '.tasks/task.md'
        meta, body = board.load(p)
        meta['status'] = 'blocked'
        board.save(p, meta, body)
        board.publish(second, ['.tasks'], 'lead intervention')
        with self.assertRaisesRegex(RuntimeError, 'remote claim changed'):
            self.recover()
        self.assertEqual(self.output.read_bytes(), self.original)
        self.assertEqual(board.load(self.task)[0]['status'], 'running')

    def test_unclaimed_dirty_clone_is_not_reset(self):
        with self.assertRaisesRegex(RuntimeError, 'unclaimed local changes'):
            board.recover_interrupted_claims(self.clone, 'research-worker', 'another owner')
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_existing_attempt_record_is_not_overwritten(self):
        attempt = self.clone / '.tasks/attempts/task/1.json'
        attempt.parent.mkdir(parents=True)
        attempt.write_text('{"existing":true}')
        board.publish(self.clone, ['.tasks'], 'pre-existing record')
        task_before = self.task.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'existing attempt record'):
            self.recover()
        self.assertEqual(self.task.read_bytes(), task_before)
        self.assertEqual(attempt.read_text(), '{"existing":true}')

    def test_approval_edits_cannot_be_published_as_recovered_outputs(self):
        approval = self.clone / 'experiments/e1/approval.md'
        approval.parent.mkdir(parents=True)
        approval.write_text('fabricated approval')
        with self.assertRaisesRegex(RuntimeError, 'frozen edits'):
            self.recover()
        self.assertEqual(board.load(self.task)[0]['status'], 'running')
        self.assertEqual(board.git(self.clone, 'ls-files', str(approval)).stdout.strip(), '')


if __name__ == '__main__':
    unittest.main()

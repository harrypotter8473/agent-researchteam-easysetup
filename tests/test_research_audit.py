"""Free component tests. No Hermes, network model, personal profile or GitHub call."""
import copy
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SHARED = Path(__file__).resolve().parents[1] / 'team/shared'
sys.path.insert(0, str(SHARED))
import audit_gate as ag
import installation_evidence as ie
import research_board as rb
import team_selftest as live_test


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='audit-')
        self.root = Path(self.temp.name)
        for name, data in {'.tasks/p.md':'producer v1', 'reports/result.md':'result v1',
                           'sources/original.txt':'source evidence', 'REQUEST.md':'user outcome'}.items():
            p = self.root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(data, encoding='utf-8')
        self.assignment = ag.contract(self.root, ['p'], 'final', ['reports/result.md', 'sources/original.txt', 'REQUEST.md'])
        self.assignment['target_versions'] = {'p': ag.digest(self.root / '.tasks/p.md')}
        self.result = {'verdict':'pass', 'checks':{k:{'status':'pass','evidence':'file:line; checked'} for k in ag.CHECKS},
                       'findings':[], 'notes':'mock'}

    def tearDown(self):
        self.temp.cleanup()

    def receipt(self, result=None, assignment=None):
        r = ag.validate(self.root, assignment or self.assignment, result or self.result)
        p = self.root / '.tasks/audits/a.json'; p.parent.mkdir(exist_ok=True)
        p.write_text(json.dumps(r), encoding='utf-8')
        return r

    def test_no_audit_no_delivery(self):
        self.assertFalse(ag.delivery_allowed(self.root, ['reports/result.md']))

    def test_valid_exact_version_delivery(self):
        self.receipt()
        self.assertTrue(ag.delivery_allowed(self.root, ['reports/result.md']))

    def test_changed_output_revokes_pass(self):
        self.receipt(); (self.root/'reports/result.md').write_text('v2')
        self.assertFalse(ag.delivery_allowed(self.root, ['reports/result.md']))

    def test_changed_evidence_revokes_pass(self):
        self.receipt(); (self.root/'sources/original.txt').write_text('v2')
        self.assertFalse(ag.approved(self.root, 'p'))

    def test_changed_task_revision_revokes_pass(self):
        self.receipt(); (self.root/'.tasks/p.md').write_text('producer v2')
        self.assertFalse(ag.approved(self.root, 'p'))

    def test_changed_requirements_revokes_pass(self):
        self.receipt(); (self.root/'REQUEST.md').write_text('new scope')
        self.assertFalse(ag.approved(self.root, 'p'))

    def test_intermediate_does_not_authorize_delivery(self):
        self.assignment['scope'] = 'intermediate'; self.receipt()
        self.assertTrue(ag.approved(self.root, 'p'))
        self.assertFalse(ag.delivery_allowed(self.root, ['reports/result.md']))

    def test_reject_is_not_approval(self):
        self.result['verdict'] = 'reject'
        self.result['findings'] = [{'location':'p1','evidence':'missing source','correction':'obtain source','blocking':True}]
        self.receipt()
        self.assertFalse(ag.approved(self.root, 'p'))

    def test_unverifiable_is_not_approval(self):
        self.result['verdict'] = 'unverifiable'
        self.result['findings'] = [{'location':'p1','evidence':'no access','correction':'equivalent source','blocking':True}]
        self.receipt()
        self.assertFalse(ag.approved(self.root, 'p'))

    def test_nonblocking_style_comment_does_not_fail(self):
        self.result['findings'] = [{'location':'p1','evidence':'long sentence','correction':'optional shortening','blocking':False}]
        self.receipt()
        self.assertTrue(ag.approved(self.root, 'p'))

    def test_contradictory_pass_refused(self):
        self.result['checks']['sources']['status'] = 'unverifiable'
        with self.assertRaises(ValueError): self.receipt()

    def test_missing_checks_refused(self):
        del self.result['checks']['sources']
        with self.assertRaises(ValueError): self.receipt()

    def test_reviewer_input_mutation_refused(self):
        (self.root/'reports/result.md').write_text('reviewer modification')
        with self.assertRaises(ValueError): self.receipt()

    def test_unsafe_paths_refused(self):
        for name in ('../outside', 'C:/auth.json', '/outside', 'sources\\other'):
            with self.subTest(name=name), self.assertRaises(ValueError): ag.safe_file(self.root, name)

    def test_done_not_sufficient_for_dependency(self):
        board = {'p':(self.root/'.tasks/p.md', {'status':'done','assignee':'research-scout'}, '')}
        worker = {'after':'p','assignee':'research-worker'}
        self.assertEqual(['p:audit'], rb.waiting_on(worker, board))
        self.receipt()
        self.assertEqual([], rb.waiting_on(worker, board))

    def test_reviewer_can_inspect_unapproved_producer(self):
        board = {'p':(self.root/'.tasks/p.md', {'status':'done','assignee':'research-scout'}, '')}
        self.assertEqual([], rb.waiting_on({'after':'p','assignee':'research-reviewer'}, board))

    def test_independent_work_not_blocked(self):
        self.assertEqual([], rb.waiting_on({'after':'','assignee':'research-worker'}, {}))

    def test_missing_attestation_fails_closed(self):
        with patch.object(rb, 'MANIFEST', self.root/'missing.json'):
            self.assertTrue(rb.profile_drift('research-lead'))

    def test_lead_cannot_mark_done(self):
        rb.save(self.root/'.tasks/p.md', {'id':'p','status':'ready'}, 'request')
        args = type('A', (), dict(paper=str(self.root), id='p', after=None, append=None, status='done'))()
        with patch.object(rb,'sync'), self.assertRaises(SystemExit):
            rb.cmd_edit(args)

    def test_lead_cannot_publish_fabricated_receipt_or_ledger(self):
        for name in ('.tasks/audits/forged.json', '.tasks/ledger.jsonl', '.tasks/p.md', '.', ':*', '../outside'):
            args = type('A', (), dict(paper=str(self.root), paths=[name], message='fake'))()
            with self.subTest(path=name), self.assertRaises(SystemExit):
                rb.cmd_publish(args)


class InstallationTests(unittest.TestCase):
    def fixture(self):
        checks = {k:True for k in ('roles','ledger','audit','intermediate_audit','output')}
        entry = {'ready_for_delivery':True,'delivered':True,'roles':sorted(ie.ROLES),'checks':checks,'artifact_sha256':'a'*64}
        scenarios = {s:copy.deepcopy(entry) for s in ie.SCENARIOS}
        for name, value in scenarios.items():
            value['checks'].update({k:True for k in ie.SCENARIO_CHECKS[name]})
        return {'live':True,'binding':'fixture','scenarios':scenarios}

    def test_all_three_required(self):
        f = self.fixture(); self.assertTrue(ie.suite_ready(f,'fixture'))
        del f['scenarios']['S3']; self.assertFalse(ie.suite_ready(f,'fixture'))

    def test_mock_cannot_make_install_ready(self):
        f = self.fixture(); f['live'] = False
        self.assertFalse(ie.suite_ready(f,'fixture'))

    def test_changed_installation_cannot_reuse_pass(self):
        self.assertFalse(ie.suite_ready(self.fixture(),'different-model-or-code'))

    def test_done_reviewer_not_enough(self):
        f = self.fixture(); f['scenarios']['S1']['checks']['audit'] = False
        self.assertFalse(ie.suite_ready(f,'fixture'))

    def test_no_attachment_no_ready(self):
        f = self.fixture(); f['scenarios']['S2']['delivered'] = False
        self.assertFalse(ie.suite_ready(f,'fixture'))

    def test_no_checks_no_ready(self):
        f = self.fixture(); f['scenarios']['S3']['checks'] = {}
        self.assertFalse(ie.suite_ready(f,'fixture'))

    def test_numeric_recalculation(self):
        with tempfile.TemporaryDirectory(prefix='numeric-') as tmp:
            root=Path(tmp)
            for d in ('sources','evidence','experiments'): (root/d).mkdir()
            (root/'sources/measurements.csv').write_text('id,condition,value\na,A,1\nb,A,3\nc,B,4\nd,B,8\n')
            (root/'experiments/analysis.py').write_text('# fixture')
            (root/'evidence/chart.svg').write_text('<svg/>')
            import math
            p=root/'evidence/statistics.json'
            p.write_text(json.dumps({'A':{'n':2,'mean':2,'sample_std':math.sqrt(2)},'B':{'n':2,'mean':6,'sample_std':math.sqrt(8)}}))
            self.assertTrue(ie.verify_numbers(root))
            bad=json.loads(p.read_text());bad['B']['mean']=7;p.write_text(json.dumps(bad))
            self.assertFalse(ie.verify_numbers(root))

    def test_scenario_specific_checks_cannot_be_omitted(self):
        for name, checks in ie.SCENARIO_CHECKS.items():
            for check in checks:
                with self.subTest(scenario=name, check=check):
                    f = self.fixture(); del f['scenarios'][name]['checks'][check]
                    self.assertFalse(ie.suite_ready(f, 'fixture'))

    def test_runtime_payload_change_invalidates_installation_binding(self):
        with tempfile.TemporaryDirectory(prefix='binding-') as tmp:
            root = Path(tmp); (root/'team/shared').mkdir(parents=True)
            for name in ('team.json', 'service.json', 'team/manifest.json', 'team/shared/profile-manifest.json'):
                (root/name).write_text('{}', encoding='utf-8')
            before = live_test.binding_for(root)
            (root/'team/manifest.json').write_text('{"files":{"board":"changed"}}', encoding='utf-8')
            self.assertNotEqual(before, live_test.binding_for(root))


class CoordinatorRetryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coord-')
        self.root = Path(self.temp.name)
        self.errors = {}; self.path = self.root/'errors.json'
        self.event = {'task': 't1', 'status': 'failed'}
        self.notify = patch.object(rb, 'Notifier'); self.notify.start()
        self.board = patch.object(rb, 'tasks', return_value={}); self.board.start()

    def tearDown(self):
        self.board.stop(); self.notify.stop(); self.temp.cleanup()

    def run_event(self):
        return rb.coordinate_with_retry(None, self.root, self.event, self.errors, self.path)

    def test_auth_error_does_not_repeat_automatically(self):
        with patch.object(rb, 'coordinate_event', side_effect=RuntimeError('401 unauthorized')) as call:
            self.assertFalse(self.run_event()); self.assertFalse(self.run_event())
            self.assertEqual(1, call.call_count)
            self.assertTrue(next(iter(self.errors.values()))['paused'])

    def test_transient_error_waits_then_resumes_without_losing_state(self):
        with patch.object(rb, 'coordinate_event', side_effect=[RuntimeError('503 overloaded'), True]) as call:
            self.assertFalse(self.run_event()); self.assertFalse(self.run_event())
            self.assertEqual(1, call.call_count)
            next(iter(self.errors.values()))['next_try'] = 0
            self.assertTrue(self.run_event()); self.assertEqual({}, self.errors)

    def test_retry_count_is_bounded_and_persisted(self):
        with patch.object(rb, 'RETRY_DELAYS', [0]), patch.object(rb, 'coordinate_event', side_effect=RuntimeError('503')) as call:
            self.assertFalse(self.run_event()); self.assertFalse(self.run_event()); self.assertFalse(self.run_event())
            self.assertEqual(2, call.call_count)
            self.assertTrue(next(iter(json.loads(self.path.read_text()).values()))['paused'])

    def test_limit_checkpoint_keeps_existing_partial_handling(self):
        with patch.object(rb, 'coordinate_event', side_effect=rb.LeadTurnPartial('saved checkpoint')):
            with self.assertRaises(rb.LeadTurnPartial): self.run_event()

if __name__ == '__main__':
    unittest.main()

"""Real selftest project bootstrap, with local Git only and no model calls."""
import json
import os
from pathlib import Path
import subprocess as sp
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SHARED = Path(__file__).resolve().parents[1] / 'team/shared'
sys.path.insert(0, str(SHARED))
import team_selftest as suite


class SelftestBootstrapTests(unittest.TestCase):
    def test_marker_publishes_after_real_init_without_preexisting_tasks(self):
        with tempfile.TemporaryDirectory(prefix='installed suite bootstrap ') as temp:
            root = Path(temp)
            workspace = root / 'workspace'; workspace.mkdir()
            project = workspace / 'suite-s1'; project.mkdir()
            (project / 'CLAUDE.md').write_text('# Public test\n**Sensitivity:** public\n')
            env = {'RESEARCH_TEAM_HOME': str(root / 'runtime'), 'PYTHONSAFEPATH': '1',
                   'PYTHONNOUSERSITE': '1', 'PYTHONUTF8': '1'}
            with patch.dict(os.environ, env):
                suite.board('init', str(project), cwd=workspace)
                self.assertFalse((project / '.tasks').exists())
                suite.write_project_marker(project, 'S1')
                suite.board('publish', str(project), '.tasks/project.json',
                            '-m', 'installation request', cwd=workspace)
            bare = root / 'runtime/boards/suite-s1.git'
            result = sp.run(['git', f'--git-dir={bare}', 'show', 'HEAD:.tasks/project.json'],
                            capture_output=True, encoding='utf-8', timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {'schema': 1, 'validation': 'S1'})


class ObservedDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='observed delivery ')
        self.folder = Path(self.temp.name)
        (self.folder / 'reports').mkdir()
        self.data = b'audited Word package'
        (self.folder / 'reports/result.docx').write_bytes(self.data)
        self.post = {'id':'post', 'user_id':'lead', 'channel_id':'channel',
                     'root_id':'request', 'file_ids':['attachment']}

    def tearDown(self): self.temp.cleanup()

    def api(self, creds, method, path):
        self.assertEqual(method, 'GET', 'test must never create a duplicate delivery')
        if path == '/users/me': return {'id':'lead'}
        if path == '/posts/request/thread': return {'posts':{'post':self.post}}
        if path == '/files/attachment/info': return {'name':'result.docx','size':len(self.data)}
        raise AssertionError(path)

    def observe(self, downloaded=None, approved=True):
        note = SimpleNamespace(creds=('local test','not-a-real-token'), channel='channel')
        with patch.object(suite.rb, 'Notifier', return_value=note), \
             patch.object(suite.rb.audit_gate, 'delivery_allowed', return_value=approved) as audit, \
             patch.object(suite.rb, 'mm_api', side_effect=self.api), \
             patch.object(suite.rb, 'mm_upload', side_effect=AssertionError('duplicate upload')), \
             patch.object(suite.rb, 'mm_download', return_value=self.data if downloaded is None else downloaded):
            result = suite.verify_lead_attachment(self.folder, 'reports/result.md:docx', 'request')
            audit.assert_called_once_with(self.folder, ['reports/result.md','reports/result.docx'])
            return result

    def test_actual_lead_post_is_independently_downloaded_without_test_upload(self):
        result = self.observe()
        self.assertTrue(result['verified']); self.assertEqual(result['actor'],'research-lead')
        self.assertEqual(result['file'],'attachment')

    def test_local_file_or_uploaded_but_unposted_file_is_not_delivery(self):
        self.post['file_ids'] = []
        self.assertFalse(self.observe()['verified'])

    def test_changed_download_is_not_delivery(self):
        self.assertEqual(self.observe(downloaded=b'wrong version')['reason'],'attachment_hash_mismatch')

    def test_wrong_author_channel_or_thread_is_not_delivery(self):
        for field in ('user_id','channel_id','root_id'):
            original = self.post[field]; self.post[field]='other'
            with self.subTest(field=field): self.assertFalse(self.observe()['verified'])
            self.post[field]=original

    def test_md_and_prepared_word_both_need_current_audit(self):
        self.assertEqual(self.observe(approved=False)['reason'],'awaiting_current_final_audit')


if __name__ == '__main__':
    unittest.main()

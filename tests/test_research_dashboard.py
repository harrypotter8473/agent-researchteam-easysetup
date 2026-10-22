"""Offline UI API, event-stream and permission regressions; no model calls."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess as sp
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

SHARED = Path(__file__).resolve().parents[1] / 'team/shared'
sys.path.insert(0, str(SHARED))
import research_activity as activity
import research_dashboard as dashboard
import audit_gate


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='research web board ')
        self.root = Path(self.temp.name)
        self.home = self.root / 'runtime'; self.home.mkdir()
        self.workspace = self.root / 'workspace'; self.workspace.mkdir()
        self.project = self.workspace / 'report-one'; self.project.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'core.autocrlf', 'false')
        self.git('config', 'user.email', 'fixture@localhost'); self.git('config', 'user.name', 'offline')
        (self.project / '.tasks').mkdir(); (self.project / 'reports').mkdir()
        (self.project / '.tasks/task-1.md').write_text('---\nid: task-1\nassignee: research-worker\nstatus: running\nexpects: reports/report.md\n---\nRequested work\n', encoding='utf-8')
        (self.project / 'reports/report.md').write_text('# <script>alert(1)</script>\nSaved text', encoding='utf-8')
        (self.project / '.env').write_text('TOKEN=NEVER_EXPOSE')
        self.git('add', '.'); self.git('commit', '-qm', 'fixture')
        self.board = dashboard.Board(self.workspace, self.home)
        self.key = next(iter(self.board.projects()))

    def tearDown(self): self.temp.cleanup()

    def git(self, *args):
        r = sp.run(['git', '-C', str(self.project), *args], capture_output=True, encoding='utf-8')
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def test_projects_tasks_saved_files_and_no_secret(self):
        result = self.board.snapshot(); p = result['projects'][0]
        self.assertEqual(p['tasks'][0]['status'], 'running')
        self.assertEqual(p['tasks'][0]['audit'], '미감사')
        self.assertTrue(p['tasks'][0]['outputs'][0]['available'])
        self.assertNotIn('NEVER_EXPOSE', json.dumps(result))
        self.assertFalse(result['validation']['passed'])

    def test_uncommitted_edits_never_appear_as_saved_output(self):
        p = self.board.snapshot()['projects'][0]
        (self.project / 'reports/report.md').write_text('UNCOMMITTED')
        self.assertNotIn(b'UNCOMMITTED', self.board.output(self.key, 'reports/report.md', p['commit']))

    def test_hidden_directory_markers_are_valid_audit_inputs_not_public_outputs(self):
        marker = self.project / 'reports/.gitkeep'
        marker.write_text('')
        audit_task = self.project / '.tasks/review-1.md'
        audit_task.write_text('---\nid: review-1\nassignee: research-reviewer\nstatus: done\n---\nReview saved\n')
        receipt = {'schema': 1, 'targets': ['task-1'], 'scope': 'intermediate',
            'phase': 'intermediate', 'files': audit_gate.bind(self.project, ['reports/report.md', 'reports/.gitkeep']),
            'target_versions': {'task-1': audit_gate.digest(self.project / '.tasks/task-1.md')},
            'verdict': 'pass', 'checks': {k: {'status': 'pass', 'evidence': 'offline source comparison'} for k in audit_gate.CHECKS},
            'findings': [], 'notes': 'isolated fixture'}
        folder = self.project / '.tasks/audits'; folder.mkdir()
        (folder / 'review-1-1.json').write_text(json.dumps(receipt))
        self.git('add', '.'); self.git('commit', '-qm', 'version-bound audit with directory marker')
        p = self.board.snapshot()['projects'][0]
        self.assertTrue(p['audits'][0]['current'])
        self.assertEqual(next(t for t in p['tasks'] if t['id'] == 'task-1')['audit'], '통과（현재 버전）')
        self.assertEqual(next(t for t in p['tasks'] if t['id'] == 'review-1')['audit'], '판정 통과（현재 버전）')
        with self.assertRaises(ValueError): self.board.output(self.key, 'reports/.gitkeep', p['commit'])
        marker.write_text('changed')
        self.git('add', '.'); self.git('commit', '-qm', 'marker changed')
        self.board.cached_at = 0
        self.assertFalse(self.board.snapshot()['projects'][0]['audits'][0]['current'])
        self.assertFalse(dashboard.audit_input_allowed('reports/.env'))

    def test_blocked_recoverable_work_is_not_a_user_approval_request(self):
        task = self.project / '.tasks/task-1.md'
        task.write_text(task.read_text(encoding='utf-8').replace('status: running', 'status: blocked\ngate: auto'), encoding='utf-8')
        self.git('add','.'); self.git('commit','-qm','recoverable failure')
        self.assertEqual(self.board.snapshot()['projects'][0]['tasks'][0]['approval'], '')

    def test_explicit_human_question_is_listed(self):
        task = self.project / '.tasks/task-1.md'
        task.write_text(task.read_text(encoding='utf-8').replace('status: running', 'status: blocked\ngate: human'), encoding='utf-8')
        self.git('add','.'); self.git('commit','-qm','explicit human decision')
        self.assertEqual(self.board.snapshot()['projects'][0]['tasks'][0]['approval'], '사용자 결정 필요')

    def test_old_or_fork_validation_cannot_be_shown_as_our_ready_installation(self):
        (self.home / 'live-test.json').write_text(json.dumps({'passed':True,'lead':'done','delivered':True}), encoding='utf-8')
        self.assertFalse(self.board.snapshot()['validation']['passed'])

    def test_nested_validation_projects_are_discovered(self):
        parent=self.workspace/'_validation-offline';parent.mkdir()
        child=parent/'offline-s1'
        sp.run(['git','clone','-q',str(self.project),str(child)],check=True)
        result=self.board.snapshot()['projects']
        self.assertTrue(any(p['name']=='offline-s1' and p['test'] for p in result))

    def test_snapshot_version_binding(self):
        p = self.board.snapshot()['projects'][0]
        (self.project / 'reports/report.md').write_text('new version')
        self.git('add', '.'); self.git('commit', '-qm', 'changed')
        with self.assertRaises(ValueError): self.board.output(self.key, 'reports/report.md', p['commit'])

    def test_unchanged_commit_reuses_metadata_without_reloading_every_blob(self):
        first=self.board.project(self.key,self.project)
        with patch.object(self.board,'blob',side_effect=AssertionError('unchanged version re-read')):
            second=self.board.project(self.key,self.project)
        self.assertEqual(first['commit'],second['commit'])

    def test_paths_credentials_git_metadata_and_windows_paths_blocked(self):
        commit = self.git('rev-parse', 'HEAD')
        for path in ('../.env', '.env', '.git/config', 'C:/Users/user/auth.json', 'sources/../../.env', 'sources\\token'):
            with self.subTest(path=path), self.assertRaises(ValueError): self.board.output(self.key, path, commit)

    def test_remote_outside_managed_board_does_not_expose_other_repo(self):
        other = self.root / 'outside.git'
        sp.run(['git', 'clone', '-q', '--bare', str(self.project), str(other)], check=True)
        self.git('remote', 'add', 'origin', str(other))
        repo, _, label = self.board.source(self.project)
        self.assertEqual(repo, self.project)
        self.assertIn('로컬', label)

    def test_live_event_is_visible_before_git_commit_and_survives_recreation(self):
        journal = activity.Journal(self.home, self.project.name, 'task-1', 'research-scout')
        journal.emit('검색', '시작', 'running', 'web_search', 'RAG primary sources')
        rows = activity.read_events(self.home, self.project.name)
        self.assertEqual(rows[-1]['action'], '검색')
        self.assertEqual(dashboard.Board(self.workspace, self.home).snapshot()['projects'][0]['tasks'][0]['status'], 'running')
        self.assertEqual(activity.read_events(self.home, 'another-project'), [])

    def test_partial_json_and_unknown_sensitive_fields_are_not_published(self):
        folder = self.home / 'activity'; folder.mkdir()
        record = {'schema':1,'role':'research-lead','time':'2026-01-01','project':'x','api_key':'NEVER_EXPOSE'}
        (folder / 'test.jsonl').write_text(json.dumps(record) + '\n{"unfinished":', encoding='utf-8')
        self.assertNotIn('NEVER_EXPOSE', json.dumps(activity.read_events(self.home)))

    def test_http_local_host_readonly_preview_and_download(self):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), dashboard.handler(self.board))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = 'http://127.0.0.1:' + str(server.server_port)
        try:
            with urllib.request.urlopen(base + '/') as r:
                self.assertIn('frame-ancestors', r.headers['Content-Security-Policy'])
                self.assertIn('작업 보드', r.read().decode())
            for headers in ({'Host':'evil.example'}, {'Origin':'https://evil.example'}, {'Sec-Fetch-Site':'cross-site'}):
                with self.assertRaises(urllib.error.HTTPError) as err:
                    urllib.request.urlopen(urllib.request.Request(base + '/api/projects', headers=headers))
                self.assertEqual(err.exception.code, 403)
            with self.assertRaises(urllib.error.HTTPError) as err:
                urllib.request.urlopen(urllib.request.Request(base + '/api/approve', data=b'approve'))
            self.assertEqual(err.exception.code, 501)
            p = self.board.snapshot()['projects'][0]
            url = base + '/api/output?' + urllib.parse.urlencode({'project':self.key,'commit':p['commit'],'path':'reports/report.md'})
            with urllib.request.urlopen(url + '&preview=1') as r:
                self.assertTrue(r.headers['Content-Type'].startswith('text/plain'))
            with urllib.request.urlopen(url) as r:
                self.assertIn('attachment', r.headers['Content-Disposition'])
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_ui_renders_untrusted_text_without_html_execution(self):
        js = (SHARED / 'board-ui/app.js').read_text(encoding='utf-8')
        self.assertNotIn('innerHTML', js)
        self.assertNotIn('eval(', js)
        self.assertIn('textContent', js)


class ActivityTests(unittest.TestCase):
    def test_redaction_and_url_credentials(self):
        self.assertNotIn('abcd1234', activity.clean('token=abcd1234'))
        self.assertNotIn('hunter2', activity.clean('password: hunter2'))
        self.assertEqual(activity.target({'url':'https://bob:pass@example.com/p?token=secret#fragment'}), 'https://example.com/p')
        self.assertEqual(activity.target({'command':'curl -H secret'}), '')
        self.assertEqual(activity.target({'urls':['https://u:p@example.com/a?token=x', 'https://example.com/b']}),
                         'https://example.com/a · https://example.com/b')

    def test_parallel_same_tool_without_call_ids_never_guesses_completion_target(self):
        with tempfile.TemporaryDirectory() as temp:
            journal = activity.Journal(temp, 'p', 't', 'research-scout')
            events = [{'type':'tool_use','name':'read_file','input':{'path':'sources/a.txt'}},
                      {'type':'tool_use','name':'read_file','input':{'path':'sources/b.txt'}},
                      {'type':'tool_result','name':'read_file','output':'missing','is_error':True},
                      {'type':'tool_result','name':'read_file','output':'ok'}]
            code = 'import json; events='+repr(events)+'; [print(json.dumps(e),flush=True) for e in events]'
            proc = sp.Popen([sys.executable,'-c',code],stdout=sp.PIPE,stderr=sp.PIPE,encoding='utf-8')
            activity.capture(proc,journal,10,lambda p:p.kill())
            rows = activity.read_events(temp)
            self.assertEqual([r['detail'] for r in rows[:2]],['sources/a.txt','sources/b.txt'])
            self.assertTrue(all(r['detail']=='' and '개별 대상 연결 정보 없음' in r['result'] for r in rows[2:]))

    def test_stream_drains_stderr_preserves_final_and_records_actual_tools(self):
        with tempfile.TemporaryDirectory() as temp:
            journal = activity.Journal(temp, 'project', 't1', 'research-scout')
            code = ('import sys,json;sys.stderr.write("x"*100000);sys.stderr.flush();'
                    'print(json.dumps({"type":"tool_use","name":"web_search","input":{"query":"RAG"}}),flush=True);'
                    'print(json.dumps({"type":"tool_result","name":"web_search","output":"SECRET_RAW_RESULT"}),flush=True);'
                    'print(json.dumps({"type":"text","text":"PRIVATE_REASONING"}),flush=True);'
                    'print(json.dumps({"type":"result","text":"Saved files.\\nSTATUS: done","tokens":{"total":12}}),flush=True)')
            proc = sp.Popen([sys.executable, '-c', code], stdout=sp.PIPE, stderr=sp.PIPE, encoding='utf-8')
            out, err, status = activity.capture(proc, journal, 10, lambda p:p.kill())
            self.assertEqual(status, 0); self.assertIn('STATUS: done', out)
            self.assertIn('x', err)
            rows = activity.read_events(temp)
            self.assertTrue(any(r['action'] == '검색' and r['state'] == 'done' for r in rows))
            self.assertNotIn('SECRET_RAW_RESULT', json.dumps(rows)); self.assertNotIn('PRIVATE_REASONING', json.dumps(rows))

    def test_plain_legacy_output_is_not_lost_or_faked(self):
        with tempfile.TemporaryDirectory() as temp:
            journal = activity.Journal(temp, 'p', 't', 'research-worker')
            proc = sp.Popen([sys.executable, '-c', 'print("STATUS: done")'], stdout=sp.PIPE, stderr=sp.PIPE, encoding='utf-8')
            out, _, status = activity.capture(proc, journal, 10, lambda p:p.kill())
            self.assertEqual(status, 0); self.assertIn('STATUS: done', out)
            self.assertEqual(activity.read_events(temp)[-1]['action'], '관측 범위')

    def test_timeout_is_failure_not_ready(self):
        with tempfile.TemporaryDirectory() as temp:
            journal = activity.Journal(temp, 'p', 't', 'research-worker')
            proc = sp.Popen([sys.executable, '-c', 'import time;time.sleep(60)'], stdout=sp.PIPE, stderr=sp.PIPE, encoding='utf-8')
            _, _, status = activity.capture(proc, journal, .2, lambda p:p.kill())
            self.assertEqual(status, 124)


if __name__ == '__main__': unittest.main()

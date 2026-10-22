"""team_service: starts one runner per role/slot, restarts a crashed one, passes each runner
only its own bot token, and stops every child on request."""
import json
import os
import shutil
import subprocess as sp
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "team" / "shared" / "team_service.py"

FAKE_BOARD = r'''
import json, os, sys, time
from pathlib import Path
role = sys.argv[sys.argv.index("--role") + 1]; slot = sys.argv[sys.argv.index("--slot") + 1]
out = Path(os.environ["RESEARCH_TEAM_HOME"]) / f"env-{role}-{slot}.json"
out.write_text(json.dumps({"token": os.environ.get("MATTERMOST_TOKEN"), "secret": os.environ.get("RESEARCH_GATEWAY_SECRET"),
                           "pid": os.getpid()}))
trigger = Path(os.environ["RESEARCH_TEAM_HOME"]) / f"crash-{role}-{slot}"
for _ in range(6000):
    if trigger.exists():
        trigger.unlink(); sys.exit(9)
    time.sleep(0.1)
'''


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="service-test-"))
        board = self.tmp / "board.py"; board.write_text(FAKE_BOARD)
        secrets = self.tmp / "secrets.env"
        secrets.write_text("MATTERMOST_URL=http://127.0.0.1:1\nMATTERMOST_TOKEN__research-worker=" + "w" * 26 +
                           "\nMATTERMOST_TOKEN__research-reviewer=" + "r" * 26 + "\nRESEARCH_GATEWAY_SECRET=s3\n")
        self.home = self.tmp / "home"
        self.cfg = self.tmp / "service.json"
        self.cfg.write_text(json.dumps({
            "team_home": str(self.home), "hermes_home": str(self.tmp / "hh"), "python": sys.executable,
            "hermes": "hermes", "board": str(board), "papers_file": str(self.tmp / "papers"),
            "secrets_file": str(secrets), "gateway": None,
            "runners": [{"role": "research-worker", "slot": 1}, {"role": "research-reviewer", "slot": 1},
                        {"role": "research-reviewer", "slot": 2}]}))
        import team_service_under_test  # noqa: F401
        self.proc = sp.Popen([sys.executable, str(SERVICE), "serve", "--config", str(self.cfg)])

    def tearDown(self):
        sp.run([sys.executable, str(SERVICE), "stop", "--config", str(self.cfg)], capture_output=True)
        try:
            self.proc.wait(timeout=30)
        except sp.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def status(self):
        p = self.home / "service-status.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def wait_for(self, cond, timeout=30):
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                if cond():
                    return True
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.5)
        return False

    def test_runners_started_with_own_token_restarted_and_stopped(self):
        files = [self.home / f"env-{n}.json" for n in ("research-worker-1", "research-reviewer-1", "research-reviewer-2")]
        self.assertTrue(self.wait_for(lambda: all(f.exists() for f in files)))
        w = json.loads(files[0].read_text()); r = json.loads(files[2].read_text())
        self.assertEqual("w" * 26, w["token"]); self.assertEqual("r" * 26, r["token"]); self.assertEqual("s3", w["secret"])
        self.assertTrue(self.wait_for(lambda: all(c["state"] == "running" for c in self.status()["children"])))
        victim = json.loads(files[1].read_text())["pid"]
        files[1].unlink()
        (self.home / "crash-research-reviewer-1").write_text("offline test")
        self.assertTrue(self.wait_for(lambda: files[1].exists(), timeout=40), "crashed runner was not restarted")
        self.assertEqual(1, [c for c in self.status()["children"] if c["name"] == "research-reviewer-1"][0]["restarts"])
        pids = [json.loads(f.read_text())["pid"] for f in files]
        sp.run([sys.executable, str(SERVICE), "stop", "--config", str(self.cfg)], check=True, capture_output=True)
        self.proc.wait(timeout=30)
        self.assertTrue(self.status().get("stopped"))
        time.sleep(1)
        for pid in pids:
            if os.name != "nt":
                with self.assertRaises(OSError):
                    os.kill(pid, 0)

    def test_coordinator_child_gets_gateway_secret_without_bot_token(self):
        import team_service_under_test as service
        cfg = json.loads(self.cfg.read_text(encoding="utf-8"))
        cfg["coordinator"] = {"enabled": True, "task_timeout": 1200}
        lead = [child for child in service.children(cfg) if child.name == "lead-coordinator"]
        self.assertEqual(1, len(lead))
        self.assertEqual("s3", lead[0].env["RESEARCH_GATEWAY_SECRET"])
        self.assertNotIn("MATTERMOST_TOKEN", lead[0].env)
        self.assertIn("coordinate", lead[0].argv)

    def test_duplicate_supervisor_refused_without_replacing_live_children(self):
        self.assertTrue(self.wait_for(lambda: bool(self.status().get('children'))))
        before=self.status()['pid']
        duplicate=sp.run([sys.executable,str(SERVICE),'serve','--config',str(self.cfg)],
                         capture_output=True,text=True,timeout=10)
        self.assertNotEqual(duplicate.returncode,0)
        self.assertIn('already running',duplicate.stderr)
        self.assertEqual(self.status()['pid'],before)

    def test_real_dashboard_startup_binds_redirector_parent_and_instance(self):
        import urllib.request
        folder=self.tmp/'actual-web-board';folder.mkdir()
        workspace=folder/'workspace';workspace.mkdir()
        cfg=json.loads(self.cfg.read_text())
        cfg.update(team_home=str(folder), board=str(SERVICE.with_name('research_board.py')),
                   runners=[], dashboard={'workspace':str(workspace)})
        path=folder/'config.json';path.write_text(json.dumps(cfg),encoding='utf-8')
        proc=sp.Popen([sys.executable,str(SERVICE),'serve','--config',str(path)])
        try:
            self.assertTrue(self.wait_for(lambda:(folder/'dashboard.json').is_file() and (folder/'service-status.json').is_file()))
            record=json.loads((folder/'dashboard.json').read_text())
            status=json.loads((folder/'service-status.json').read_text())
            child=next(c for c in status['children'] if c['name']=='research-board')
            self.assertEqual(child['instance'],record['instance'])
            self.assertEqual(32,len(record['instance']))
            self.assertIn(child['pid'],(record['pid'],record['parent']))
            with urllib.request.urlopen(record['url']+'api/projects',timeout=10) as response:
                self.assertEqual(json.load(response)['workspace'],str(workspace.resolve()))
        finally:
            sp.run([sys.executable,str(SERVICE),'stop','--config',str(path)],capture_output=True)
            proc.wait(timeout=30)


import importlib.util as _u  # noqa: E402
_spec = _u.spec_from_file_location("team_service_under_test", SERVICE)
sys.modules["team_service_under_test"] = _u.module_from_spec(_spec); _spec.loader.exec_module(sys.modules["team_service_under_test"])


class ServiceStatusResilience(unittest.TestCase):
    def test_transient_replace_denial_retried_without_partial_json(self):
        import team_service_under_test as service
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'service-status.json'
            path.write_text('{"previous":true}')
            replace = os.replace
            calls = []
            def contested(src, dst):
                calls.append(1)
                self.assertEqual(json.loads(path.read_text()), {'previous': True})
                if len(calls) < 3:
                    raise PermissionError('sharing violation')
                replace(src, dst)
            with patch.object(service.os, 'replace', side_effect=contested), patch.object(service.time, 'sleep'):
                service.write_json(path, {'new': True})
            self.assertEqual(len(calls), 3)
            self.assertEqual(json.loads(path.read_text()), {'new': True})
            self.assertEqual(list(Path(temp).glob('*.tmp')), [])

    def test_status_failure_nonfatal_and_safe_diagnostic(self):
        import team_service_under_test as service
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(service, 'write_json', side_effect=PermissionError('SECRET_MUST_NOT_LOG')):
                self.assertFalse(service.write_status(temp, {'pid': 1}))
            log = (Path(temp) / 'logs/team-supervisor.jsonl').read_text()
            self.assertNotIn('SECRET_MUST_NOT_LOG', log)
            self.assertEqual(json.loads(log)['phase'], 'status-write')

    def test_fatal_exception_durable_not_silently_success(self):
        import team_service_under_test as service
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(service, '_serve_owned', side_effect=RuntimeError('SECRET_MUST_NOT_LOG')):
                with self.assertRaises(RuntimeError):
                    service.serve({'team_home': temp}, 'offline-config')
            log = (Path(temp) / 'logs/team-supervisor.jsonl').read_text()
            self.assertEqual(json.loads(log)['phase'], 'fatal')
            self.assertNotIn('SECRET_MUST_NOT_LOG', log)

    @unittest.skipUnless(os.name == 'nt', 'Windows real sharing semantics')
    def test_real_windows_reader_lock_does_not_end_service_work(self):
        import ctypes
        import threading
        from ctypes import wintypes
        import team_service_under_test as service
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'service-status.json'
            path.write_text('{"old":true}')
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                          ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
            kernel.CreateFileW.restype = wintypes.HANDLE
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.CreateFileW(str(path), 0x80000000, 1, None, 3, 0, None)
            self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
            # An actual reader without FILE_SHARE_DELETE makes os.replace fail.
            try:
                replacement = Path(temp) / 'probe'
                replacement.write_text('{}')
                with self.assertRaises(PermissionError):
                    os.replace(replacement, path)
                timer = threading.Timer(0.2, lambda h=handle: kernel.CloseHandle(h))
                timer.start()
                handle = None
                self.assertTrue(service.write_status(temp, {'recovered': True}))
                timer.join()
                self.assertEqual(json.loads(path.read_text()), {'recovered': True})
            finally:
                if handle:
                    kernel.CloseHandle(handle)

if __name__ == "__main__":
    unittest.main()

"""Local fixture HTTP only: no Mattermost installation, agents or model requests."""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

SOURCE=Path(__file__).resolve().parents[1]/'plugins/research-board/bridge.py'
spec=importlib.util.spec_from_file_location('mm_board_bridge',SOURCE)
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='read-only-board-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.home=self.root/'research';self.home.mkdir()
        self.workspace=self.root/'workspace';self.workspace.mkdir()
        self.team='b'*32;self.secret='c'*64
        self.team_file=self.home/'team.json'
        self.team_file.write_text(json.dumps({'TeamID':self.team,'RuntimeRoot':str(self.root)}))
        workspace=str(self.workspace)
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self,*_):pass
            def do_GET(s):
                raw=json.dumps({'workspace':workspace,'projects':[]}).encode()
                s.send_response(200);s.send_header('Content-Type','application/json');s.send_header('Content-Length',str(len(raw)));s.end_headers();s.wfile.write(raw)
        self.up=http.server.ThreadingHTTPServer(('127.0.0.1',0),Upstream)
        threading.Thread(target=self.up.serve_forever,daemon=True).start()
        self.addCleanup(self.up.server_close);self.addCleanup(self.up.shutdown)
        self.record=self.home/'dashboard.json'
        self.record.write_text(json.dumps({'url':f'http://127.0.0.1:{self.up.server_port}/','pid':os.getpid()}))
        self.adapter=bridge.Bridge({'research_root':str(self.home),'workspace':str(self.workspace),'team_id':self.team,'secret':self.secret,'port':54321})
        self.http=http.server.ThreadingHTTPServer(('127.0.0.1',0),bridge.handler(self.adapter))
        threading.Thread(target=self.http.serve_forever,daemon=True).start()
        self.addCleanup(self.http.server_close);self.addCleanup(self.http.shutdown)
        self.base=f'http://127.0.0.1:{self.http.server_port}'

    def request(self,path='/health',secret=None,method='GET',extra=None):
        headers={'X-Hermes-Board-Secret':secret or self.secret};headers.update(extra or {})
        req=urllib.request.Request(self.base+path,headers=headers,method=method)
        try:return urllib.request.urlopen(req,timeout=3)
        except urllib.error.HTTPError as error:return error

    def test_no_auth_or_wrong_auth_is_rejected(self):
        with self.request(secret='wrong') as r:self.assertEqual(r.status,403);self.assertNotIn(self.secret.encode(),r.read())
    def test_origin_header_is_not_a_browser_backdoor(self):
        with self.request(extra={'Origin':'http://127.0.0.1:18065'}) as r:self.assertEqual(r.status,403)
    def test_write_methods_cannot_change_research(self):
        before=self.team_file.read_bytes()
        for method in ('POST','PUT','PATCH','DELETE'):
            with self.request('/api/approve',method=method) as r:self.assertEqual(r.status,405)
        self.assertEqual(self.team_file.read_bytes(),before)
    def test_auth_read_and_health(self):
        with self.request() as r:self.assertTrue(json.load(r)['ready'])
        with self.request('/api/projects') as r:self.assertEqual(json.load(r)['workspace'],str(self.workspace))
    def test_allowlist_rejects_arbitrary_routes_and_duplicate_parameters(self):
        for path,query in [('/api/config',''),('/api/output','path=a&path=b'),('/api/projects','url=http://evil'),('/api/log','project=x%0ay')]:
            with self.assertRaises(ValueError):bridge.validate_query(path,query)
    def test_cannot_follow_non_loopback_or_dead_board(self):
        for url in ('http://evil.example:8080/','http://127.0.0.1:8000/private','file:///etc/passwd'):
            self.record.write_text(json.dumps({'url':url,'pid':os.getpid()}))
            with self.assertRaises(ValueError):self.adapter.target()
        self.record.write_text(json.dumps({'url':f'http://127.0.0.1:{self.up.server_port}/','pid':os.getpid()}))
        with patch.object(bridge,'process_alive',return_value=False):
            with self.assertRaises(ValueError):self.adapter.target()
    def test_dashboard_restart_is_followed_without_restarting_adapter(self):
        first=self.adapter.target()
        self.record.write_text(json.dumps({'url':'http://127.0.0.1:56789/','pid':os.getpid()}))
        self.assertNotEqual(self.adapter.target(),first)
    def test_research_owner_change_rejects_all_reads(self):
        self.team_file.write_text(json.dumps({'TeamID':'f'*32,'RuntimeRoot':str(self.root)}))
        with self.request() as r:self.assertEqual(r.status,503)


if __name__=='__main__':unittest.main()

"""Read-only localhost adapter for an existing board. Never runs a model or edits research.

Docker's server plugin authenticates each reader with Mattermost. Its bridge secret
stays server-side. The adapter follows dashboard.json after board restarts, so no
agent payload replacement or scenario rerun is required to add the integration.
"""
import argparse
import ctypes
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

ROUTES = {'/api/projects': set(), '/api/activity': {'project', 'role', 'task', 'before', 'limit'},
          '/api/output': {'project', 'path', 'commit', 'preview'},
          '/api/log': {'project', 'role', 'task', 'before', 'limit'}}
MAX_BYTES = 21 * 1024 * 1024


def validate_query(path, query):
    if path not in ROUTES or len(query) > 16384:
        raise ValueError('read-only route rejected')
    values = urllib.parse.parse_qs(query, keep_blank_values=True, strict_parsing=True)
    if set(values) - ROUTES[path] or any(len(v) != 1 or re.search(r'[\x00-\x1f]', v[0]) for v in values.values()):
        raise ValueError('query rejected')
    if 'role' in values and values['role'][0] not in ('', 'research-lead', 'research-scout', 'research-worker', 'research-reviewer'):
        raise ValueError('role rejected')
    if 'limit' in values and (not values['limit'][0].isdigit() or not 1 <= int(values['limit'][0]) <= 500):
        raise ValueError('page size rejected')
    if 'before' in values and (len(values['before'][0]) > 1024 or not re.fullmatch(r'[A-Za-z0-9_-]+', values['before'][0])):
        raise ValueError('cursor rejected')


def process_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    if os.name != 'nt':
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    # On Windows, os.kill is NOT used: only query access, never termination.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    try:
        result = ctypes.c_ulong()
        return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(result))) and result.value == 259
    finally:
        kernel.CloseHandle(handle)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class Bridge:
    def __init__(self, config):
        self.home = Path(config['research_root']).resolve()
        self.workspace = Path(config['workspace']).resolve()
        self.team = config['team_id']
        self.secret = config['secret']
        self.port = config['port']
        if not re.fullmatch(r'[a-f0-9]{32}', self.team) or not re.fullmatch(r'[a-f0-9]{64}', self.secret):
            raise ValueError('bridge identity rejected')
        if not isinstance(self.port, int) or not 1024 <= self.port <= 65535:
            raise ValueError('bridge port rejected')
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def target(self):
        state = json.loads((self.home / 'team.json').read_text(encoding='utf-8-sig'))
        if state.get('TeamID') != self.team or Path(state['RuntimeRoot']).resolve() / 'research' != self.home:
            raise ValueError('research ownership changed')
        record_path = self.home / 'dashboard.json'
        if record_path.stat().st_size > 4096:
            raise ValueError('invalid dashboard record')
        record = json.loads(record_path.read_text(encoding='utf-8-sig'))
        url = record.get('url', '')
        if not re.fullmatch(r'http://127\.0\.0\.1:[1-9][0-9]{0,4}/', url) or not 1 <= urllib.parse.urlsplit(url).port <= 65535:
            raise ValueError('non-loopback board rejected')
        if not process_alive(record.get('pid')):
            raise ValueError('board process is not running')
        return url

    def get(self, path, query=''):
        validate_query(path, query)
        url = self.target() + path.lstrip('/') + ('?' + query if query else '')
        try:
            response = self.opener.open(urllib.request.Request(url, method='GET'), timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError('response too large')
            if path == '/api/projects' and response.status == 200:
                if Path(json.loads(raw)['workspace']).resolve() != self.workspace:
                    raise ValueError('board workspace changed')
            return response.status, raw, {k: response.headers[k] for k in ('Content-Type', 'Content-Disposition') if k in response.headers}


def handler(bridge):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # Never log a URL's document names or authentication headers.

        def reply(self, status, raw, headers=None):
            self.send_response(status)
            for k, v in (headers or {'Content-Type': 'text/plain; charset=utf-8'}).items():
                self.send_header(k, v)
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            if (self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}' or
                self.headers.get('Origin') is not None or
                not hmac.compare_digest(self.headers.get('X-Hermes-Board-Secret', '').encode(), bridge.secret.encode())):
                return self.reply(403, b'Forbidden')
            parsed = urllib.parse.urlsplit(self.path)
            try:
                if parsed.path == '/health' and not parsed.query:
                    status, _raw, _headers = bridge.get('/api/projects')
                    if status != 200:
                        raise ValueError('board not ready')
                    raw = json.dumps({'ready': True, 'read_only': True}).encode()
                    return self.reply(200, raw, {'Content-Type': 'application/json'})
                status, raw, headers = bridge.get(parsed.path, parsed.query)
                return self.reply(status, raw, headers)
            except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
                return self.reply(503, '보드 연결 대기. 마법사에서 보드 연결 상태를 확인하세요.'.encode())

        def do_POST(self):
            self.reply(405, b'Read only')
        do_PUT = do_PATCH = do_DELETE = do_POST
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    path = Path(args.config)
    if path.stat().st_size > 16384:
        raise ValueError('bridge config too large')
    config = json.loads(path.read_text(encoding='utf-8-sig'))
    bridge = Bridge(config)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', bridge.port), handler(bridge))
    public = {'pid': os.getpid(), 'port': bridge.port, 'config_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    # This receipt is private too; it contains no secret or model authentication.
    (path.parent / 'process.json').write_text(json.dumps(public), encoding='utf-8')
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()

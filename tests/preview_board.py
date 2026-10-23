"""Read-only design preview: does not overwrite the installed dashboard record."""
import argparse
import http.server
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'team/shared'))
import research_dashboard as dashboard

ap = argparse.ArgumentParser()
ap.add_argument('--workspace', required=True)
ap.add_argument('--home', required=True)
ap.add_argument('--port', type=int, default=0)
args = ap.parse_args()
board = dashboard.Board(args.workspace, args.home)
server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), dashboard.handler(board))
print(f'PREVIEW_URL=http://127.0.0.1:{server.server_port}/', flush=True)
try: server.serve_forever()
finally: server.server_close()

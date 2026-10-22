"""Contained foreground Gateway: closing this service kills its owned descendants."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path: sys.path.insert(0, str(HERE))
from team_service import Job

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', required=True)
a = parser.parse_args()
cfg = json.loads(Path(a.config).read_text(encoding='utf-8-sig'))
job = Job()
try:
    Path(cfg['log']).parent.mkdir(parents=True, exist_ok=True)
    with open(cfg['log'], 'ab') as log:
        proc = subprocess.Popen(cfg['argv'], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP | 0x08000000) if sys.platform == 'win32' else 0)
        job.add(proc)
        raise SystemExit(proc.wait())
finally: job.close()

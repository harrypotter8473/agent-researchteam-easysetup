"""Build the reviewed Linux Mattermost plugin; installer users need neither Go nor Node."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'plugins/research-board'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(files, target):
    with target.open('wb') as output, gzip.GzipFile(filename='', fileobj=output, mode='wb', mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name, (path, mode) in sorted(files.items()):
                raw = path.read_bytes()
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime, info.uid, info.gid = len(raw), mode, 0, 0, 0
                archive.addfile(info, io.BytesIO(raw))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--go', default='go')
    args = parser.parse_args()
    manifest = json.loads((PLUGIN / 'plugin.json').read_text(encoding='utf-8-sig'))
    target = ROOT / 'assets/mattermost-plugins' / f"{manifest['id']}-{manifest['version']}.tar.gz"
    target.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, GOOS='linux', GOARCH='amd64', CGO_ENABLED='0', GOTOOLCHAIN='local')
    with tempfile.TemporaryDirectory(prefix='research-plugin-build-') as temp:
        binary = Path(temp) / 'plugin-linux-amd64'
        subprocess.run([args.go, 'build', '-mod=readonly', '-trimpath', '-buildvcs=false',
                        '-ldflags=-s -w -buildid=', '-o', str(binary), './server'], cwd=PLUGIN, env=env, check=True)
        package({'plugin.json': (PLUGIN/'plugin.json', 0o644),
                 'webapp/dist/main.js': (PLUGIN/'webapp/dist/main.js', 0o644),
                 'server/dist/plugin-linux-amd64': (binary, 0o755)}, target)
    branding = ROOT / 'assets/mattermost-plugins/com.nst.wordmark-0.1.0.tar.gz'
    pin = {'schema': 1, 'packages': [
        {'id': manifest['id'], 'version': manifest['version'], 'file': target.name, 'sha256': digest(target)},
        {'id': 'com.nst.wordmark', 'version': '0.1.0', 'file': branding.name, 'sha256': digest(branding)}],
        'bridge': {'path': 'plugins/research-board/bridge.py', 'sha256': digest(PLUGIN/'bridge.py')}}
    (ROOT/'config/mattermost-plugins.json').write_text(json.dumps(pin, indent=2)+'\n', encoding='utf-8', newline='\n')
    print(json.dumps({'packages': pin['packages'], 'bridge_pinned': True}))


if __name__ == '__main__':
    main()

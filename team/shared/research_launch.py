"""Read-only resolution of the official store interpreter for a research gateway.

Avoids the obsolete venv exe -> inline-source bridge whose live command is
rejected by Hermes's own process identity matcher. Never disables that matcher.
"""
import argparse
import json
from pathlib import Path
import sys


def resolve(install):
    root = Path(install).resolve()
    main = root / 'hermes_cli/main.py'
    launchers = root / 'hermes_cli/_launchers.py'
    if not launchers.is_file() or not main.is_file(): return {'direct': False}
    # Older releases may not support safe script-mode entry; keep their official exe.
    if '_bootstrap_root' not in main.read_text(encoding='utf-8'): return {'direct': False}
    sys.path.insert(0, str(root))
    from hermes_cli._launchers import resolve_store_python
    python = resolve_store_python(root)
    if python is None or not Path(python).is_file(): return {'direct': False}
    return {'direct': True, 'python': str(Path(python).resolve()),
            'main': str(Path(__file__).with_name('hermes').resolve())}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('install')
    args = parser.parse_args()
    print(json.dumps(resolve(args.install)))

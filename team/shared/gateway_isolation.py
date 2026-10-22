"""Read-only compatibility check; never edits the personal Hermes configuration."""
import ast
import json
import os
import sys
from pathlib import Path
import yaml

PROFILES = ('research-lead', 'research-scout', 'research-worker', 'research-reviewer')

def read_config(path):
    value = yaml.safe_load(path.read_text(encoding='utf-8-sig')) if path.is_file() else {}
    if value is None: value = {}
    if not isinstance(value, dict): raise ValueError('Invalid configuration mapping')
    return value

def standalone_supported(install):
    """Inspect capabilities, not a guessed version or the retired allowlist key.

    No Hermes module is imported: a probe must not bootstrap the user's runtime.
    The installed CLI must both exclude standalone profiles and allow their gateway.
    """
    try:
        profile_tree = ast.parse((install/'hermes_cli/profiles.py').read_text(encoding='utf-8-sig'))
        cli_tree = ast.parse((install/'hermes_cli/gateway.py').read_text(encoding='utf-8-sig'))
        functions = {node.name: node for node in profile_tree.body if isinstance(node, ast.FunctionDef)}
        own = functions['profile_is_standalone']; served = functions['profiles_to_serve']
        keys = {n.value for n in ast.walk(own) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
        excludes = any(isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.Not)
            and isinstance(n.operand, ast.Call) and isinstance(n.operand.func, ast.Name)
            and n.operand.func.id == 'profile_is_standalone' for n in ast.walk(served))
        default_false = any(arg.arg == 'include_standalone' and isinstance(value, ast.Constant) and value.value is False
            for arg, value in zip(served.args.kwonlyargs, served.args.kw_defaults))
        guard = next(n for n in cli_tree.body if isinstance(n, ast.FunctionDef) and n.name == '_named_profile_refused_under_multiplexer')
        guard_uses_optout = any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
            and n.func.id == 'profile_is_standalone' for n in ast.walk(guard))
        return {'gateway', 'standalone'}.issubset(keys) and excludes and default_false and guard_uses_optout
    except (OSError, SyntaxError, KeyError, StopIteration):
        return False

def probe(install, home, environ=None):
    env = os.environ if environ is None else environ
    cfg = read_config(home/'config.yaml')
    gw = cfg.get('gateway') or {}
    if not isinstance(gw, dict): raise ValueError('Invalid gateway mapping')
    forced = env.get('GATEWAY_MULTIPLEX_PROFILES', '').strip().lower()
    multiplex = forced in ('1', 'true', 'yes', 'on') or gw.get('multiplex_profiles') is True
    supported = standalone_supported(install)
    # An allowlist is not a reliable isolation mechanism: current Hermes retired it.
    return {'schema': 1, 'mode': 'standalone' if supported else ('conflict' if multiplex else 'single'),
            'standalone_supported': supported, 'root_multiplex': multiplex,
            'personal_config_changed': False}

def verify(home):
    for name in PROFILES:
        cfg = read_config(home/'profiles'/name/'config.yaml')
        gw = cfg.get('gateway') or {}
        if gw.get('standalone') is not True or gw.get('multiplex_profiles') is not False:
            raise ValueError('Research profile isolation missing: '+name)
    return {'schema': 1, 'verified': True, 'profiles': list(PROFILES), 'personal_config_changed': False}

def main():
    try:
        action = sys.argv[1]
        if action == 'probe' and len(sys.argv) == 4:
            result = probe(Path(sys.argv[2]), Path(sys.argv[3]))
        elif action == 'verify' and len(sys.argv) == 3:
            result = verify(Path(sys.argv[2]))
        else: raise ValueError('Invalid isolation arguments')
        print(json.dumps(result))
    except (ValueError, OSError, yaml.YAMLError):
        print('ResearchGatewayIsolationCheckFailed', file=sys.stderr); return 1
    return 0

if __name__ == '__main__': sys.exit(main())

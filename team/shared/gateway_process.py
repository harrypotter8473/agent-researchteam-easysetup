"""Identify one owned, idle research Gateway, including the official legacy bridge.

Never execute inline source. Only an exact four-statement official launcher AST
is accepted, bound to the install, named profile, process owner and creation time.
Personal/default Gateway command lines and generic python -c are rejected.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import sys


def same_path(a, b): return os.path.normcase(os.path.abspath(str(a))) == os.path.normcase(os.path.abspath(str(b)))


def valid_tail(args, profile):
    return args in (['-p', profile, 'gateway', 'run', '--replace'],
                    ['-p', profile, 'gateway', 'run'],
                    ['--profile', profile, 'gateway', 'run', '--replace'])


def official_bridge(source, install, profile):
    try:
        tree = ast.parse(source)
        if len(tree.body) != 4: return False
        first, second, third, fourth = tree.body
        if not isinstance(first, ast.Import) or [(a.name, a.asname) for a in first.names] != [('sys', None), ('runpy', None)]: return False
        path = second.value if isinstance(second, ast.Expr) else None
        if not isinstance(path, ast.Call) or ast.unparse(path.func) != 'sys.path.insert' or path.keywords or len(path.args) != 2: return False
        if ast.literal_eval(path.args[0]) != 0 or not same_path(ast.literal_eval(path.args[1]), install): return False
        if not isinstance(third, ast.Assign) or len(third.targets) != 1 or ast.unparse(third.targets[0]) != 'sys.argv': return False
        argv = ast.literal_eval(third.value)
        if not isinstance(argv, list) or not all(isinstance(x, str) for x in argv): return False
        exe = Path(install) / 'bin/hermes.exe'
        if not argv or not same_path(argv[0], exe) or not valid_tail(argv[1:], profile): return False
        call = fourth.value if isinstance(fourth, ast.Expr) else None
        return (isinstance(call, ast.Call) and ast.unparse(call.func) == 'runpy.run_path'
                and len(call.args) == 1 and same_path(ast.literal_eval(call.args[0]), exe)
                and len(call.keywords) == 1 and call.keywords[0].arg == 'run_name'
                and ast.literal_eval(call.keywords[0].value) == '__main__')
    except (SyntaxError, ValueError, TypeError, AttributeError): return False


def matches(argv, install, team, profile):
    if not argv: return False
    args = list(argv[1:])
    if '-c' in args:
        index = args.index('-c')
        return (args[:index] in (['-I'], ['-I', '-B']) and len(args) == index + 2
                and official_bridge(args[index + 1], install, profile))
    while args and args[0] in ('-I', '-B', '-u'): args.pop(0)
    if not args: return False
    if same_path(args[0], Path(team) / 'shared/hermes'):
        return valid_tail(args[1:], profile)
    if same_path(argv[0], Path(install) / 'bin/hermes.exe'):
        return valid_tail(args, profile)
    return False


def inspect(home, install, team, profile):
    import psutil
    path = Path(home) / 'profiles' / profile / 'gateway_state.json'
    if not path.is_file(): return {'state':'absent'}
    record = json.loads(path.read_text(encoding='utf-8-sig'))
    if record.get('kind') != 'hermes-gateway' or not same_path(record.get('hermes_home', ''), path.parent):
        raise ValueError('ResearchGatewayHomeBindingMismatch')
    pid = record.get('pid')
    if type(pid) is not int or pid <= 0: raise ValueError('ResearchGatewayPIDInvalid')
    try: proc = psutil.Process(pid)
    except psutil.NoSuchProcess: return {'state':'absent'}
    created = proc.create_time()
    if abs(created * 100 - float(record.get('start_time', 0))) > 2:
        return {'state':'absent', 'reason':'old_pid_reused'}  # never touch the unrelated new process
    if proc.username().casefold() != psutil.Process(os.getpid()).username().casefold():
        raise ValueError('ResearchGatewayOwnerMismatch')
    sys.path.insert(0, str(Path(install).resolve()))
    from hermes_cli._launchers import resolve_store_python
    physical = proc.exe()
    allowed = [Path(install) / 'venv/Scripts/python.exe', Path(install) / 'bin/hermes.exe']
    native = resolve_store_python(Path(install))
    if native: allowed.append(native)
    if not any(same_path(physical, a) for a in allowed) or not matches(proc.cmdline(), install, team, profile):
        raise ValueError('ResearchGatewayCommandIdentityRejected')
    if record.get('active_agents', 0): raise ValueError('ResearchGatewayBusy: wait for the current chat turn before updating')
    return {'state':'owned_idle','pid':pid,'start_time':record['start_time'],'exe':physical}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ('home','install','team','profile'): parser.add_argument('--' + field, required=True)
    a = parser.parse_args()
    if a.profile != 'research-lead': parser.error('only the owned research-lead Gateway can be selected')
    print(json.dumps(inspect(a.home, a.install, a.team, a.profile)))

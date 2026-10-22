"""Version-bound audit gates. No model verdict or task 'done' alone opens a gate.

This is application-level enforcement, not an OS sandbox against arbitrary code
running with the same Windows account. The reviewer receives a blind snapshot.
"""
import hashlib
import json
from pathlib import Path

CHECKS = ('requirements', 'sources', 'methods', 'consistency', 'uncertainty')


def safe_file(root, name):
    root = Path(root).resolve()
    rel = Path(name)
    if not name or rel.is_absolute() or '..' in rel.parts or ':' in name or '\\' in name:
        raise ValueError('Unsafe artifact path')
    path = root / rel
    if not path.resolve().is_relative_to(root) or any(p.is_symlink() for p in [path, *path.parents] if p != root):
        raise ValueError('Artifact escaped workspace')
    if not path.is_file():
        raise ValueError('Missing artifact: ' + name)
    return path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def bind(root, names):
    return {n: digest(safe_file(root, n)) for n in sorted(set(names))}


def contract(root, targets, scope, files):
    if scope not in ('intermediate', 'final') or not targets or not files:
        raise ValueError('Audit needs targets, scope and concrete files')
    return {'schema': 1, 'targets': sorted(targets), 'scope': scope,
            'phase': 'pre_release' if scope == 'final' else 'intermediate',
            'files': bind(root, files), 'checks': list(CHECKS)}


def validate(root, assignment, result):
    """Return a runner-generated receipt; model cannot choose approved hashes."""
    if bind(root, assignment['files']) != assignment['files']:
        raise ValueError('Reviewed input was modified')
    return validate_result(assignment, result)


def validate_result(assignment, result):
    """Validate verdict structure; caller must separately verify the exact file hashes."""
    if not isinstance(result, dict) or set(result) != {'verdict', 'checks', 'findings', 'notes'}:
        raise ValueError('Audit response schema invalid')
    if result['verdict'] not in ('pass', 'reject', 'unverifiable'):
        raise ValueError('Audit verdict invalid')
    if not isinstance(result['checks'], dict) or set(result['checks']) != set(CHECKS):
        raise ValueError('Mandatory audit checks missing')
    for value in result['checks'].values():
        if (not isinstance(value, dict) or set(value) != {'status', 'evidence'} or
                value['status'] not in ('pass', 'reject', 'unverifiable', 'not_applicable') or
                not isinstance(value['evidence'], str) or not value['evidence'].strip()):
            raise ValueError('Each check needs a verdict and location/evidence or not-applicable reason')
    if not isinstance(result['findings'], list) or not isinstance(result['notes'], str):
        raise ValueError('Audit findings invalid')
    for finding in result['findings']:
        if (not isinstance(finding, dict) or set(finding) != {'location', 'evidence', 'correction', 'blocking'} or
                type(finding['blocking']) is not bool or
                any(not isinstance(finding[k], str) or not finding[k].strip() for k in ('location', 'evidence', 'correction'))):
            raise ValueError('Finding must name location, evidence, correction and blocking flag')
    if result['verdict'] == 'pass' and (any(v['status'] in ('reject', 'unverifiable') for v in result['checks'].values()) or
                                      any(f['blocking'] for f in result['findings'])):
        raise ValueError('Blocking findings cannot pass')
    if result['verdict'] != 'pass' and not any(f['blocking'] for f in result['findings']):
        raise ValueError('Rejection needs actionable blocking findings')
    return {**assignment, 'verdict': result['verdict'], 'checks': result['checks'],
            'findings': result['findings'], 'notes': result['notes']}


def receipts(root):
    for path in sorted((Path(root) / '.tasks' / 'audits').glob('*.json')):
        try:
            value = json.loads(path.read_text(encoding='utf-8'))
            if value.get('schema') == 1 and value.get('verdict') == 'pass' and value.get('files'):
                versions = value.get('target_versions', {})
                if set(versions) != set(value.get('targets', [])) or not versions:
                    continue
                if any(digest(safe_file(root, '.tasks/' + t + '.md')) != h for t, h in versions.items()):
                    continue
                # Re-check receipt structure and all bound input versions, not just delivered file.
                validate(root, value, {k: value[k] for k in ('verdict', 'checks', 'findings', 'notes')})
                yield value
        except (ValueError, KeyError, OSError, TypeError):
            continue


def approved(root, target, scope='intermediate'):
    return any(target in r['targets'] and (scope == 'intermediate' or r['scope'] == 'final') for r in receipts(root))


def delivery_allowed(root, names):
    names = set(names)
    return bool(names) and any(r['scope'] == 'final' and names.issubset(r['files']) for r in receipts(root))

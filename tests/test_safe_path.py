"""Real child-process imports under the installer's safe-path policy. No model calls."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SHARED = Path(__file__).resolve().parents[1] / 'team/shared'


class SafePathTests(unittest.TestCase):
    def test_entrypoints_import_with_safe_path_from_untrusted_cwd(self):
        with tempfile.TemporaryDirectory(prefix='research safe path ') as temp:
            cwd = Path(temp)
            # Neither cwd nor a same-named module in the paper may be imported.
            for name in ('audit_gate', 'research_board', 'installation_evidence'):
                (cwd / (name + '.py')).write_text('raise RuntimeError("UNTRUSTED_CWD_IMPORTED")')
            env = os.environ.copy()
            env.pop('PYTHONPATH', None)
            env.pop('PYTHONHOME', None)
            env.update(PYTHONSAFEPATH='1', PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1', PYTHONUTF8='1')
            for module in ('research_board', 'team_selftest', 'installation_evidence'):
                with self.subTest(module=module):
                    script = SHARED / (module + '.py')
                    code = ('import runpy,sys,json; runpy.run_path(sys.argv[1],run_name="import_probe"); '
                            'print(json.dumps({"safe":sys.flags.safe_path,"audit":sys.modules["audit_gate"].__file__}))')
                    result = subprocess.run([sys.executable, '-B', '-c', code, str(script)], cwd=cwd,
                                            env=env, capture_output=True, encoding='utf-8', timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    data = json.loads(result.stdout)
                    self.assertTrue(data['safe'])
                    self.assertEqual(Path(data['audit']).resolve(), (SHARED / 'audit_gate.py').resolve())

    def test_direct_cli_help_in_safe_environment(self):
        env = os.environ.copy()
        env.pop('PYTHONPATH', None)
        env.update(PYTHONSAFEPATH='1', PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1', PYTHONUTF8='1')
        for script in ('research_board.py', 'team_selftest.py', 'team_service.py'):
            with self.subTest(script=script):
                result = subprocess.run([sys.executable, '-B', str(SHARED / script), '--help'],
                                        env=env, capture_output=True, encoding='utf-8', timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('usage:', result.stdout)


if __name__ == '__main__':
    unittest.main()

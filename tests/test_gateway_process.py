"""Strict legacy bridge recognition; no process is stopped by these tests."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'team/shared'))
import gateway_process as gp

class GatewayProcessTests(unittest.TestCase):
    def setUp(self):
        self.install=str(Path('fixture install').resolve())
        self.team=str(Path('fixture team').resolve())
        self.exe=str(Path(self.install)/'bin/hermes.exe')
        self.tail=['-p','research-lead','gateway','run','--replace']
        self.source=(f'import sys, runpy; sys.path.insert(0, {self.install!r}); '
                     f'sys.argv = {[self.exe,*self.tail]!r}; '
                     f'runpy.run_path({self.exe!r}, run_name="__main__")')
    def test_exact_official_bridge_accepted(self):
        self.assertTrue(gp.matches(['python','-I','-c',self.source],self.install,self.team,'research-lead'))
    def test_direct_owned_wrapper_accepted(self):
        self.assertTrue(gp.matches(['python','-I','-B',str(Path(self.team)/'shared/hermes'),*self.tail],self.install,self.team,'research-lead'))
    def test_default_or_personal_profile_never_matches(self):
        for name in ('default','lab-agent'):
            self.assertFalse(gp.matches(['python','-I','-c',self.source.replace('research-lead',name)],self.install,self.team,'research-lead'))
    def test_extra_inline_code_rejected(self):
        self.assertFalse(gp.matches(['python','-I','-c',self.source+'; print("extra")'],self.install,self.team,'research-lead'))
    def test_arbitrary_inline_source_with_gateway_words_rejected(self):
        self.assertFalse(gp.matches(['python','-I','-c','print("hermes gateway run")'],self.install,self.team,'research-lead'))
    def test_changed_install_or_launcher_rejected(self):
        self.assertFalse(gp.matches(['python','-I','-c',self.source.replace(repr(self.exe), repr(self.exe+'-other'))],self.install,self.team,'research-lead'))
        self.assertFalse(gp.matches(['python','-I','-c',self.source],self.install+'-other',self.team,'research-lead'))
    def test_status_and_restart_intents_not_live_gateway(self):
        for value in ('status','stop'):
            self.assertFalse(gp.matches(['python','-I','-c',self.source.replace("'run'",repr(value))],self.install,self.team,'research-lead'))
    def test_function_calls_in_literal_values_rejected_without_execution(self):
        source=self.source.replace(repr(self.install),'__import__("os").getcwd()')
        self.assertFalse(gp.matches(['python','-I','-c',source],self.install,self.team,'research-lead'))
    def test_watcher_trailing_gateway_args_rejected(self):
        self.assertFalse(gp.matches(['python','-I','-c',self.source,*self.tail],self.install,self.team,'research-lead'))

if __name__=='__main__':unittest.main()

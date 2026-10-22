"""Free tests: no real profiles, gateway, tokens, network or model calls."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
import yaml

HELPER = Path(__file__).resolve().parents[1]/'team/shared/gateway_isolation.py'
spec = importlib.util.spec_from_file_location('research_gateway_isolation', HELPER)
gi = importlib.util.module_from_spec(spec); spec.loader.exec_module(gi)
NATIVE_PROFILES = '''
def profile_is_standalone(home):
    return home.get('gateway', {}).get('standalone') is True
def profiles_to_serve(multiplex, *, include_standalone=False):
    return [p for p in profiles if include_standalone or not profile_is_standalone(p)]
'''
NATIVE_CLI = '''
def _named_profile_refused_under_multiplexer():
    return not profile_is_standalone(home)
'''

class GatewayIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='research-isolation-')
        self.root = Path(self.temp.name); self.home = self.root/'home'; self.home.mkdir()
        self.install = self.root/'code'; (self.install/'hermes_cli').mkdir(parents=True)

    def tearDown(self): self.temp.cleanup()

    def native(self):
        (self.install/'hermes_cli/profiles.py').write_text(NATIVE_PROFILES, encoding='utf-8')
        (self.install/'hermes_cli/gateway.py').write_text(NATIVE_CLI, encoding='utf-8')

    def config(self, value):
        (self.home/'config.yaml').write_text(yaml.safe_dump(value), encoding='utf-8')

    def test_research_lead_mattermost_quiet_policy_does_not_change_personal_settings(self):
        overlay = HELPER.parents[1] / 'research-lead/config.overlay.yaml'
        cfg = yaml.safe_load(overlay.read_text(encoding='utf-8'))
        display = cfg['display']
        self.assertEqual(display['busy_input_mode'], 'queue')
        mm = display['platforms']['mattermost']
        self.assertEqual(mm['tool_progress'], 'off')
        self.assertIs(mm['show_reasoning'], False)
        self.assertIs(mm['interim_assistant_messages'], False)
        self.assertIs(mm['busy_ack_detail'], False)
        self.assertNotIn('tool_progress', display)
        self.assertEqual(set(display['platforms']), {'mattermost'})

    def test_native_multiplexer_uses_profile_optout_without_changing_root(self):
        self.native(); self.config({'gateway':{'multiplex_profiles':True}, 'personal_setting':'KEEP'})
        before=(self.home/'config.yaml').read_bytes()
        result=gi.probe(self.install,self.home,{})
        self.assertEqual('standalone',result['mode'])
        self.assertTrue(result['standalone_supported'])
        self.assertEqual(before,(self.home/'config.yaml').read_bytes())

    def test_legacy_multiplex_still_fails_closed(self):
        self.config({'gateway':{'multiplex_profiles':True}})
        self.assertEqual('conflict',gi.probe(self.install,self.home,{})['mode'])

    def test_legacy_single_gateway_remains_supported(self):
        self.config({'gateway':{'multiplex_profiles':False}})
        self.assertEqual('single',gi.probe(self.install,self.home,{})['mode'])

    def test_retired_allowlist_does_not_authorize_legacy_duplicate(self):
        self.config({'gateway':{'multiplex_profiles':True,'multiplex_profile_allowlist':['lab-agent']}})
        self.assertEqual('conflict',gi.probe(self.install,self.home,{})['mode'])

    def test_environment_enable_needs_real_optout_support(self):
        self.config({})
        self.assertEqual('conflict',gi.probe(self.install,self.home,{'GATEWAY_MULTIPLEX_PROFILES':'true'})['mode'])
        self.native()
        self.assertEqual('standalone',gi.probe(self.install,self.home,{'GATEWAY_MULTIPLEX_PROFILES':'true'})['mode'])

    def test_function_names_alone_are_not_capability_evidence(self):
        self.native()
        (self.install/'hermes_cli/profiles.py').write_text('def profile_is_standalone(home): return True\ndef profiles_to_serve(multiplex): return []\n')
        self.assertFalse(gi.standalone_supported(self.install))

    def test_all_four_profiles_must_be_isolated_and_not_multiplex(self):
        for name in gi.PROFILES:
            path=self.home/'profiles'/name/'config.yaml'; path.parent.mkdir(parents=True)
            path.write_text('gateway:\n  standalone: true\n  multiplex_profiles: false\n')
        self.assertTrue(gi.verify(self.home)['verified'])
        path.write_text('gateway:\n  standalone: true\n  multiplex_profiles: true\n')
        with self.assertRaisesRegex(ValueError,'research-reviewer'):gi.verify(self.home)

    def test_missing_profiles_cannot_pass_by_default(self):
        with self.assertRaisesRegex(ValueError,'research-lead'):gi.verify(self.home)

    def test_invalid_root_config_is_not_silently_treated_as_safe(self):
        self.config(['not','a','mapping'])
        with self.assertRaises(ValueError):gi.probe(self.install,self.home,{})

if __name__=='__main__':unittest.main()

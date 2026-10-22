"""Gateway config rendering and routing policy, as installed by the wizard."""
import json
import subprocess as sp
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
GW = ROOT / "team" / "gateway"
sys.path.insert(0, str(GW))
import render_config  # noqa: E402
import research_gateway_policy as policy  # noqa: E402


def names(text):
    return {m["model_name"] for m in yaml.safe_load(text)["model_list"]}


class RenderTests(unittest.TestCase):
    template = (GW / "litellm.config.yaml").read_text(encoding="utf-8")

    def test_claude_first_with_openai_fallback(self):
        cfg = yaml.safe_load(render_config.render(self.template, {"cloud": ["anthropic", "openai"]}))
        self.assertIn({"cloud-strong": ["cloud-strong-openai"]}, cfg["router_settings"]["fallbacks"])
        self.assertTrue(all(m["litellm_params"].get("store") is False for m in cfg["model_list"] if "openai" in m["litellm_params"]["model"]))
        self.assertEqual("research_gateway_litellm.user_api_key_auth", cfg["general_settings"]["custom_auth"])

    def test_openai_only_has_no_fallback_and_no_local(self):
        text = render_config.render(self.template, {"cloud": ["openai"]})
        self.assertEqual({"cloud-strong", "cloud-mid", "cloud-cheap"}, names(text))
        self.assertEqual([], yaml.safe_load(text)["router_settings"]["fallbacks"])

    def test_local_side_never_falls_back_to_cloud(self):
        text = render_config.render(self.template, {"cloud": ["anthropic"], "local": {"base_url": "http://127.0.0.1:8000/v1", "model": "qwen"}})
        cfg = yaml.safe_load(text)
        self.assertIn("local-fast", names(text))
        for fb in cfg["router_settings"]["fallbacks"]:
            self.assertFalse(any(k.startswith("local") for k in fb))

    def test_policy_sees_which_sides_exist(self):
        routing = policy.load(GW / "routing.yaml")
        for spec, local_ok in (({"cloud": ["anthropic"]}, False),
                               ({"cloud": [], "local": {"base_url": "http://h:1/v1", "model": "m"}}, True)):
            configured = names(render_config.render(self.template, spec))
            sides = {side: all(n in configured for n in routing["models"][side].values()) for side in ("cloud", "local")}
            self.assertEqual(local_ok, sides["local"])

    def test_no_models_refused(self):
        with self.assertRaises(SystemExit):
            render_config.render(self.template, {"cloud": []})


if __name__ == "__main__":
    unittest.main()

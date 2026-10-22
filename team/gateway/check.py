#!/usr/bin/env python3
"""check.py <profile> — is this Hermes profile really going through the paper gateway?

  1. config: main model and auxiliary calls point at the `research-gateway` provider;
  2. .env: the right gateway variable is set, and no cloud provider key is left that would
     let an un-routed call bypass the gateway (warning, not an error);
  3. routing: where each sensitivity class would go (a probe; no model is called), and one
     real 1-token call through the public cheap model to prove the upstream works.

Exit 1 if any check fails.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared"))
from research_board import profile_env  # noqa: E402

CLOUD_KEYS = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "GOOGLE_API_KEY",
              "GEMINI_API_KEY", "NOUS_API_KEY", "DEEPSEEK_API_KEY", "XAI_API_KEY", "MISTRAL_API_KEY"]
AUX = ["compression", "vision", "web_extract"]
RUNNER_ROLES = {"research-worker", "research-reviewer", "research-scout", "research-worker"}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    prof = sys.argv[1]
    hh = Path(os.environ.get("HERMES_HOME") or os.environ.get("HERMES_ROOT") or Path.home() / ".hermes")
    cfg = yaml.safe_load((hh / "profiles" / prof / "config.yaml").read_text(encoding="utf-8")) or {}
    env = profile_env(prof)
    bad = 0

    def report(ok, msg, warn=False):
        nonlocal bad
        print(("ok    " if ok else "WARN  " if warn else "FAIL  ") + msg)
        bad += not ok and not warn

    model = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
    report(model.get("provider") == "research-gateway", f"model.provider = {model.get('provider')!r}")
    url = (cfg.get("providers", {}).get("research-gateway") or {}).get("api", "")
    report(url.startswith("http"), f"providers.research-gateway.api = {url!r}")
    for a in AUX:
        p = (cfg.get("auxiliary", {}).get(a) or {}).get("provider")
        report(p == "research-gateway", f"auxiliary.{a}.provider = {p!r}")
    left = [k for k in CLOUD_KEYS if env.get(k)]
    report(not left, "cloud keys in .env: " + (", ".join(left) or "none") +
           (" — an un-routed call could reach a cloud model with these" if left else ""), warn=True)

    if prof in RUNNER_ROLES:
        secret = env.get("RESEARCH_GATEWAY_SECRET") or os.environ.get("RESEARCH_GATEWAY_SECRET")
        report(bool(secret), "RESEARCH_GATEWAY_SECRET set (runner builds the key per task)")
        report("RESEARCH_GATEWAY_API_KEY" not in env, "no fixed RESEARCH_GATEWAY_API_KEY in .env")
        keys = {s: f"rgw.{prof}.{s}.{secret}" for s in ("public", "private", "air-gapped")} if secret else {}
    else:
        key = env.get("RESEARCH_GATEWAY_API_KEY", "")
        report(key.startswith(f"rgw.{prof}."), f"RESEARCH_GATEWAY_API_KEY is for {prof}")
        keys = {key.split(".")[2]: key} if key.count(".") >= 3 else {}

    def call(key, model):
        req = urllib.request.Request(
            url.rstrip("/") + "/chat/completions", method="POST",
            data=json.dumps({"model": model, "max_tokens": 1,
                             "messages": [{"role": "user", "content": "ping"}]}).encode(),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.status, f"{r.headers.get('x-litellm-model-group')} ({r.headers.get('x-litellm-model-name')})"
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read() or b"{}").get("error", {}).get("message", "")
            except ValueError:
                return e.code, ""
        except OSError as e:
            return 0, str(e)

    for sens, key in keys.items():
        # Where would this class go? (research-probe: the gateway routes but calls no model)
        code, msg = call(key, "research-probe")
        if "research-gateway-probe: ok" in msg:
            report(True, f"route {sens:10} -> {msg.split('ok', 1)[1].strip()}")
        elif "local models unavailable" in msg:
            report(False, f"route {sens:10} -> refused: local models unavailable (expected until they are configured)", warn=True)
        else:
            report(False, f"route {sens:10} -> HTTP {code}: {msg}")
    if "public" in keys:  # one real, 1-token call through the cheap model proves the upstream works
        code, msg = call(keys["public"], "research-aux")
        report(code == 200, f"live  public     research-aux -> {msg if code == 200 else f'HTTP {code}: {msg}'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

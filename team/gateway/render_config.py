#!/usr/bin/env python3
"""render_config.py <template litellm.config.yaml> <out> <spec.json>

Writes the gateway's LiteLLM config for the models this PC actually has, from the template
in this folder. spec.json (no secrets — keys stay in the gateway's env file):

  {"cloud": ["anthropic", "openai"],          # providers with a key, any subset
   "local": null | {"base_url": "http://127.0.0.1:8000/v1", "model": "...", "fast_model": "..."}}

- Anthropic key: cloud-strong/mid/cheap are Claude; with an OpenAI key too, OpenAI is the
  fallback on an outage (Claude first).
- Only an OpenAI key: cloud-* are OpenAI models, no fallback.
- Local: local-strong and local-fast on the given OpenAI-compatible server (vLLM, Ollama,
  LM Studio). Never a cloud fallback from local — a private paper must not reach the cloud
  because the local server is down.
A side whose three names are not all present counts as unavailable (routing.yaml), so a PC
without local models refuses private and air-gapped papers instead of running them elsewhere.
"""
import json
import sys
from pathlib import Path

import yaml

CLAUDE = {"cloud-strong": "anthropic/claude-opus-5-5", "cloud-mid": "anthropic/claude-sonnet-5-5",
          "cloud-cheap": "anthropic/claude-haiku-4-5-20251001"}
OPENAI = {"cloud-strong": "openai/responses/gpt-6-astra", "cloud-mid": "openai/responses/gpt-6.1-sol",
          "cloud-cheap": "openai/responses/gpt-6-luna"}


def render(template, spec):
    cfg = yaml.safe_load(template)
    cloud, local = set(spec.get("cloud") or []), spec.get("local")
    models, fallbacks = [], []
    if "anthropic" in cloud:
        for name, model in CLAUDE.items():
            models.append({"model_name": name, "litellm_params": {"model": model, "api_key": "os.environ/ANTHROPIC_API_KEY"}})
        if "openai" in cloud:
            for name, model in OPENAI.items():
                models.append({"model_name": f"{name}-openai", "litellm_params": {
                    "model": model, "api_key": "os.environ/OPENAI_API_KEY", "store": False}})
                fallbacks.append({name: [f"{name}-openai"]})
    elif "openai" in cloud:
        for name, model in OPENAI.items():
            models.append({"model_name": name, "litellm_params": {"model": model, "api_key": "os.environ/OPENAI_API_KEY", "store": False}})
    if local:
        for name, model in (("local-strong", local["model"]), ("local-fast", local.get("fast_model") or local["model"])):
            models.append({"model_name": name, "litellm_params": {
                "model": f"openai/{model}", "api_base": local["base_url"], "api_key": "local"}})
    if not models:
        raise SystemExit("render_config: no models — give at least one cloud key or a local model")
    cfg["model_list"] = models
    cfg.setdefault("router_settings", {})["fallbacks"] = fallbacks
    return yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True)


if __name__ == "__main__":
    template, out, spec = sys.argv[1:4]
    text = render(Path(template).read_text(encoding="utf-8"), json.loads(Path(spec).read_text(encoding="utf-8")))
    header = "# Written by the installer from the gateway template; re-run the wizard to change models.\n"
    Path(out).write_text(header + text, encoding="utf-8", newline="\n")
    print(f"wrote {out}")

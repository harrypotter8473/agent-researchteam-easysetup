"""LiteLLM proxy plug-ins for the research team: custom auth + routing and effort hooks.

litellm.config.yaml wires them in:
    general_settings: {custom_auth: research_gateway_litellm.user_api_key_auth}
    litellm_settings: {callbacks: research_gateway_litellm.proxy_handler_instance}

The rules live in research_gateway_policy.py; this file only adapts them to LiteLLM.
Environment: RESEARCH_GATEWAY_SECRET (shared with the devices), RESEARCH_GATEWAY_ROUTING (default: routing.yaml
next to this file). Logs one line per request and per deployment attempt — profile, tier,
class, effort, target — never content.

Two hooks, because effort has to be set twice:
  async_pre_call_hook             once per request: authenticate → route → strip any
                                  thinking/effort the client sent → note the policy's effort
                                  in the request metadata. Model `research-probe` only answers
                                  where a request would go (the runner's preflight); no model
                                  is called.
  async_pre_call_deployment_hook  once per deployment LiteLLM actually calls, fallbacks
                                  included: fit that effort to the concrete model (a request
                                  value would otherwise go unchanged to the fallback model).
"""
import os
import sys
from pathlib import Path

import litellm
from fastapi import HTTPException, Request
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy._types import UserAPIKeyAuth

sys.path.insert(0, str(Path(__file__).resolve().parent))
import research_gateway_policy as policy  # noqa: E402

CFG = policy.load(os.environ.get("RESEARCH_GATEWAY_ROUTING", Path(__file__).with_name("routing.yaml")))
SECRET = os.environ["RESEARCH_GATEWAY_SECRET"]
# Params a client could use to pick its own thinking depth; the policy decides instead.
CLIENT_EFFORT_PARAMS = ("reasoning_effort", "thinking", "output_config", "reasoning")


def configured_models():
    from litellm.proxy.proxy_server import llm_router  # set once the proxy has loaded its config
    return set(llm_router.get_model_names()) if llm_router else set()


ROUTER = policy.Router(CFG, available=configured_models)


def model_caps(model):
    """Capability flags for clamp_effort, from LiteLLM's model map. `model` is the
    deployment's model string, e.g. anthropic/claude-opus-5-5 or openai/responses/gpt-6-astra."""
    provider, _, rest = str(model).partition("/")
    bare = rest.split("/")[-1] if rest else provider
    info = litellm.model_cost.get(bare) or litellm.model_cost.get(f"{provider}/{bare}") or {}
    adaptive = bool(info.get("supports_adaptive_thinking"))
    return {
        "reasoning": bool(info.get("supports_reasoning")),
        "none": bool(info.get("supports_none_reasoning_effort")),
        "xhigh": bool(info.get("supports_xhigh_reasoning_effort")),
        "max": bool(info.get("supports_max_reasoning_effort")),
        # Older Claude models (Haiku 4.5) think only when asked; adaptive ones always do.
        "omit_is_none": provider == "anthropic" and not adaptive,
    }


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    try:
        profile, sens = policy.parse_key(api_key, SECRET, CFG)
    except policy.Refused as e:
        raise HTTPException(status_code=e.status, detail=f"research-gateway: {e}")
    return UserAPIKeyAuth(api_key=f"rgw.{profile}.{sens}", user_id=profile,
                          metadata={"research_gateway_profile": profile, "research_gateway_sensitivity": sens})


class ResearchRouter(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        md = user_api_key_dict.metadata or {}
        profile, sens = md.get("research_gateway_profile"), md.get("research_gateway_sensitivity", "private")
        if not profile:
            raise HTTPException(status_code=403, detail="research-gateway: request did not come through research-gateway auth")
        probe = data.get("model") == policy.PROBE_MODEL
        try:
            target, effort, why = ROUTER.route(profile, sens, "research" if probe else data.get("model"),
                                               data.get("messages"))
        except policy.Refused as e:
            print(f"research-gateway REFUSED {profile} {sens}: {e}", flush=True)
            raise HTTPException(status_code=e.status, detail=f"research-gateway: {e}")
        if probe:  # LiteLLM answers a returned string as an error carrying it; no model is called
            return f"research-gateway-probe: ok {target}"
        print(f"research-gateway {why} {data.get('model')} -> {target} ({call_type})", flush=True)
        data["model"] = target
        for p in CLIENT_EFFORT_PARAMS:
            data.pop(p, None)
        data.setdefault("metadata", {})["research_gateway_effort"] = effort
        return data

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        md = kwargs.get("metadata") or {}
        if "research_gateway_effort" not in md:
            return kwargs  # not a research-gateway request (should not happen: auth refuses those)
        model = kwargs.get("model")
        effort = policy.clamp_effort(md["research_gateway_effort"], model_caps(model))
        for p in CLIENT_EFFORT_PARAMS:
            kwargs.pop(p, None)
        if effort is not None:
            kwargs["reasoning_effort"] = effort
        print(f"research-gateway   attempt {md.get('model_group')} -> {model} effort={effort}", flush=True)
        return kwargs


proxy_handler_instance = ResearchRouter()

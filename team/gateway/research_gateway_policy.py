"""research_gateway_policy — which model a research-team request goes to, at what effort. Pure Python, no
LiteLLM import, so the rules can be tested on their own (test_policy.py).

Every agent authenticates with a key of the form

    rgw.<profile>.<sensitivity>.<secret>       e.g. rgw.research-reviewer.private.s3cr3t

The runner builds that key per task from the paper's CLAUDE.md (`**Sensitivity:**`); the
lead and the *-chat profiles carry a fixed one in their .env. A request is then routed:

  tier         the profile's tier from routing.yaml (strong / mid / cheap). `auto` (the lead)
               picks once per conversation from its first user message, so a session never
               switches model halfway through. Auxiliary calls (model `research-aux`: context
               compression, titles, vision) always go to `cheap`.
  sensitivity  public < private < air-gapped: the highest of the key and any sensitivity line
               in the conversation. It only ever goes up.
  side         public      → cloud.
               private     → decide_side(): cloud or local, per request. Until that module
                             exists it returns None and `private_default` (local) applies.
                             If local is chosen and no local models are configured, the
                             request is refused with "local models unavailable" — it is
                             never sent to the cloud instead.
               air-gapped  → local only; refused the same way when local is unavailable.

Effort comes from routing.yaml (per tier, per-role overrides) as one OpenAI-style level.
clamp_effort() fits it to each concrete model when LiteLLM picks the deployment, so a
fallback from Claude to OpenAI still gets a level that model accepts.
"""
import hashlib
import hmac
import re
from collections import OrderedDict

import yaml

SENSITIVITIES = ("public", "private", "air-gapped")  # ascending
RANK = {s: i for i, s in enumerate(SENSITIVITIES)}
TIERS = ("strong", "mid", "cheap")
SIDES = ("cloud", "local")
EFFORTS = ("none", "low", "medium", "high", "xhigh", "max")
PROBE_MODEL = "research-probe"
# "**Sensitivity:** private" in a paper's CLAUDE.md, or the runner's footer line. Matching too
# much only raises the class, which is the safe direction.
MARK = re.compile(r"sensitivity[\s:*_`]*(private|air-gapped)\b", re.I)
UNAVAILABLE = "local models unavailable"


class Refused(Exception):
    """The request must not be sent anywhere. `status` is the HTTP status to answer with."""

    def __init__(self, msg, status=403):
        super().__init__(msg)
        self.status = status


def load(path):
    with open(path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    for side in SIDES:
        if set(cfg["models"][side]) != set(TIERS):
            raise ValueError(f"routing: models.{side} must map {TIERS}")
    local = set(cfg["models"]["local"].values())
    if set(cfg["models"]["cloud"].values()) & local:
        raise ValueError("routing: a model_name cannot be both cloud and local")
    if cfg.get("private_default", "local") not in SIDES:
        raise ValueError(f"routing: private_default must be one of {SIDES}")
    for prof, tier in cfg["roles"].items():
        if tier != "auto" and tier not in TIERS:
            raise ValueError(f"routing: role {prof!r} has unknown tier {tier!r}")
    for k, v in {**cfg.get("effort", {}), **cfg.get("role_effort", {})}.items():
        if v not in EFFORTS:
            raise ValueError(f"routing: effort for {k!r} is {v!r}, not one of {EFFORTS}")
    cfg["_auto_cheap"] = [re.compile(p, re.I) for p in cfg.get("auto", {}).get("cheap_if", [])]
    return cfg


def parse_key(key, secret, cfg):
    """-> (profile, sensitivity). Raises Refused on a bad key."""
    parts = (key or "").removeprefix("Bearer ").strip().split(".", 3)
    if len(parts) != 4 or parts[0] != "rgw":
        raise Refused("key is not of the form rgw.<profile>.<sensitivity>.<secret>", 401)
    _, profile, sens, given = parts
    if not hmac.compare_digest(given.encode(), secret.encode()):
        raise Refused("bad secret", 401)
    if profile not in cfg["roles"]:
        raise Refused(f"unknown profile {profile!r}", 401)
    # An unknown sensitivity is treated as the strictest, not refused: fail closed.
    return profile, sens if sens in RANK else "air-gapped"


def _texts(messages):
    for m in messages or []:
        c = m.get("content")
        if isinstance(c, str):
            yield m.get("role", ""), c
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    yield m.get("role", ""), part["text"]


def marked_sensitivity(messages):
    """The highest sensitivity line in the conversation, or None."""
    found = [m.group(1).lower() for _, t in _texts(messages) for m in MARK.finditer(t)]
    return max(found, key=RANK.get) if found else None


def decide_side(profile, tier, messages):
    """The decision module for PRIVATE papers (not implemented yet).

    Return "cloud" when this request may go to a cloud model, "local" when it must stay on a
    local one, or None to use routing.yaml's `private_default`. Called only for private
    requests — public always goes to the cloud and air-gapped always stays local.
    """
    return None


def clamp_effort(effort, caps):
    """Fit an OpenAI-style effort level to one concrete model.

    caps: {"reasoning", "none", "xhigh", "max", "omit_is_none"} — booleans from the model map.
    Returns the level to send, or None to send no effort at all.
    """
    if effort is None or not caps.get("reasoning"):
        return None  # local / unknown models: send nothing rather than a param they reject
    if effort == "none":
        if caps.get("none"):
            return "none"
        return None if caps.get("omit_is_none") else "low"
    if effort == "max" and not caps.get("max"):
        effort = "xhigh"
    if effort == "xhigh" and not caps.get("xhigh"):
        effort = "high"
    return effort


class Router:
    def __init__(self, cfg, available=None, remember=4096):
        """available: () -> set of model_names LiteLLM has; None means every name exists."""
        self.cfg = cfg
        self.available = available
        self.sessions = OrderedDict()  # conversation fingerprint -> tier, for `auto`
        self.remember = remember

    def _auto_tier(self, messages):
        texts = list(_texts(messages))
        system = next((t for r, t in texts if r == "system"), "")
        first = next((t for r, t in texts if r == "user"), "")
        fp = hashlib.sha256((system[:4000] + "\0" + first).encode()).hexdigest()
        if fp in self.sessions:
            self.sessions.move_to_end(fp)
            return self.sessions[fp]
        auto = self.cfg.get("auto", {})
        short = len(first.strip()) <= auto.get("max_chars", 280)
        cheap = short and any(p.search(first) for p in self.cfg["_auto_cheap"])
        tier = "cheap" if cheap else auto.get("default", "strong")
        self.sessions[fp] = tier
        while len(self.sessions) > self.remember:
            self.sessions.popitem(last=False)
        return tier

    def side_available(self, side):
        """All of a side's tiers must exist: main and auxiliary calls must not split."""
        if self.available is None:
            return True
        have = self.available()
        return all(t in have for t in self.cfg["models"][side].values())

    def route(self, profile, sensitivity, requested_model, messages):
        """-> (target model_name, effort or None, why). Raises Refused."""
        cfg = self.cfg
        if requested_model == cfg.get("aux_model_name", "research-aux"):
            tier, how = "cheap", "aux"
        else:
            tier, how = cfg["roles"][profile], "role"
            if tier == "auto":
                tier, how = self._auto_tier(messages), "auto"

        sens = sensitivity
        marked = marked_sensitivity(messages)
        if marked and RANK[marked] > RANK[sens]:
            sens, how = marked, f"{how}+marker"

        if sens == "public":
            side = "cloud"
        elif sens == "air-gapped":
            side = "local"
        else:
            decided = decide_side(profile, tier, messages)
            side = decided if decided in SIDES else cfg.get("private_default", "local")
            how += "+module" if decided in SIDES else "+default"

        if not self.side_available(side):
            if side == "local":
                raise Refused(f"{UNAVAILABLE} for this {sens} paper; it is not sent to the cloud", 503)
            raise Refused("cloud models are not configured", 503)
        target = cfg["models"][side][tier]
        if how == "aux" or tier == "cheap":
            effort = cfg.get("effort", {}).get(tier)
        else:
            effort = cfg.get("role_effort", {}).get(profile, cfg.get("effort", {}).get(tier))
        return target, effort, f"{profile} {how} tier={tier} sensitivity={sens} side={side} effort={effort}"

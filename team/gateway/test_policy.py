"""python3 -m pytest hermes/gateway/test_policy.py — routing rules, without LiteLLM."""
from pathlib import Path

import pytest

import research_gateway_policy as policy

CFG = policy.load(Path(__file__).with_name("routing.yaml"))
S = "s3cr3t"
CLOUD = {"cloud-strong", "cloud-mid", "cloud-cheap"}
LOCAL = {"local-strong", "local-fast"}
ALL = CLOUD | LOCAL


def msgs(*pairs):
    return [{"role": r, "content": c} for r, c in pairs]


def route(key, model="research", messages=(), router=None, have=ALL):
    prof, sens = policy.parse_key(key, S, CFG)
    r = router or policy.Router(CFG, available=lambda: have)
    return r.route(prof, sens, model, list(messages))


def target(*a, **k):
    return route(*a, **k)[0]


# ── difficulty ──────────────────────────────────────────────────────────────────

def test_role_tiers():
    assert target(f"rgw.research-reviewer.public.{S}") == "cloud-strong"
    assert target(f"rgw.research-worker.public.{S}") == "cloud-strong"
    assert target(f"rgw.research-scout.public.{S}") == "cloud-mid"


def test_aux_is_cheap_on_the_same_side():
    assert target(f"rgw.research-worker.public.{S}", "research-aux") == "cloud-cheap"
    assert target(f"rgw.research-worker.private.{S}", "research-aux") == "local-fast"
    assert target(f"rgw.research-worker.air-gapped.{S}", "research-aux") == "local-fast"


def test_lead_auto_is_sticky_per_conversation():
    r = policy.Router(CFG, available=lambda: ALL)
    k = f"rgw.research-lead.public.{S}"
    status = msgs(("system", "lead"), ("user", "@research-lead status?"))
    assert target(k, messages=status, router=r) == "cloud-cheap"
    assert target(k, messages=status + msgs(("assistant", "…"), ("user", "now run round 2")), router=r) == "cloud-cheap"
    assert target(k, messages=msgs(("system", "lead"), ("user", "review my paper in x")), router=r) == "cloud-strong"


# ── sensitivity ─────────────────────────────────────────────────────────────────

def test_three_classes_with_local():
    assert target(f"rgw.research-reviewer.public.{S}") == "cloud-strong"
    assert target(f"rgw.research-reviewer.private.{S}") == "local-strong"     # module unset → private_default
    assert target(f"rgw.research-reviewer.air-gapped.{S}") == "local-strong"


def test_marker_raises_never_lowers():
    claude_md = "## Target\n- **Venue:** X\n- **Sensitivity:** private\n"
    assert route(f"rgw.research-lead.public.{S}", messages=msgs(("user", "hi"), ("tool", claude_md)))[2].count("sensitivity=private")
    assert "air-gapped" in route(f"rgw.research-worker.private.{S}", messages=msgs(("user", "Sensitivity: air-gapped")))[2]
    assert "sensitivity=air-gapped" in route(f"rgw.research-worker.air-gapped.{S}", messages=msgs(("user", "**Sensitivity:** public")))[2]


def test_highest_marker_wins():
    m = msgs(("user", "Sensitivity: private"), ("tool", "**Sensitivity:** air-gapped"))
    assert policy.marked_sensitivity(m) == "air-gapped"


def test_choice_text_is_not_a_marker():
    assert policy.marked_sensitivity(msgs(("system", "set **Sensitivity:** to `public`, `private` or `air-gapped`"))) is None


def test_marker_in_content_parts():
    m = [{"role": "user", "content": [{"type": "text", "text": "Sensitivity: PRIVATE"}]}]
    assert policy.marked_sensitivity(m) == "private"


# ── the private-paper module and availability ───────────────────────────────────

def test_module_decides_private_only(monkeypatch):
    monkeypatch.setattr(policy, "decide_side", lambda p, t, m: "cloud")
    assert target(f"rgw.research-worker.private.{S}") == "cloud-strong"
    assert target(f"rgw.research-worker.air-gapped.{S}") == "local-strong"   # module never consulted
    monkeypatch.setattr(policy, "decide_side", lambda p, t, m: "local")
    assert target(f"rgw.research-worker.public.{S}") == "cloud-strong"


def test_no_local_refuses_private_and_air_gapped():
    for sens in ("private", "air-gapped"):
        with pytest.raises(policy.Refused) as e:
            route(f"rgw.research-reviewer.{sens}.{S}", have=CLOUD)
        assert e.value.status == 503 and policy.UNAVAILABLE in str(e.value)
    assert target(f"rgw.research-reviewer.public.{S}", have=CLOUD) == "cloud-strong"


def test_module_cloud_choice_works_without_local(monkeypatch):
    monkeypatch.setattr(policy, "decide_side", lambda p, t, m: "cloud")
    assert target(f"rgw.research-worker.private.{S}", have=CLOUD) == "cloud-strong"


def test_partial_local_is_unavailable():
    # local-strong alone is not "local available": aux calls would have nowhere local to go
    with pytest.raises(policy.Refused):
        route(f"rgw.research-worker.private.{S}", have=CLOUD | {"local-strong"})


def test_no_cloud_refuses_public():
    with pytest.raises(policy.Refused):
        route(f"rgw.research-worker.public.{S}", have=LOCAL)


# ── effort ──────────────────────────────────────────────────────────────────────

def test_effort_by_tier_and_role():
    assert route(f"rgw.research-worker.public.{S}")[1] == "high"
    assert route(f"rgw.research-scout.public.{S}")[1] == "medium"
    assert route(f"rgw.research-reviewer.public.{S}")[1] == "xhigh"
    assert route(f"rgw.research-reviewer.public.{S}", "research-aux")[1] == "none"  # role override skips aux
    assert route(f"rgw.research-lead.public.{S}", messages=msgs(("user", "status?")))[1] == "none"
    assert route(f"rgw.research-reviewer.air-gapped.{S}")[1] == "xhigh"  # local models then get none sent (clamp)
    assert route(f"rgw.research-lead.public.{S}", messages=msgs(("user", "start a paper on X")))[1] == "medium"


OPUS = {"reasoning": True, "none": False, "xhigh": True, "max": True, "omit_is_none": False}
HAIKU = {"reasoning": True, "none": False, "xhigh": False, "max": False, "omit_is_none": True}
ASTRA = {"reasoning": True, "none": False, "xhigh": True, "max": True, "omit_is_none": False}
LUNA = {"reasoning": True, "none": True, "xhigh": True, "max": True, "omit_is_none": False}
GPT55 = {"reasoning": True, "none": True, "xhigh": True, "max": False, "omit_is_none": False}
LOCALM = {}


@pytest.mark.parametrize("effort,caps,want", [
    ("xhigh", OPUS, "xhigh"), ("none", OPUS, "low"),
    ("none", HAIKU, None), ("xhigh", HAIKU, "high"), ("max", HAIKU, "high"),
    ("none", ASTRA, "low"), ("none", LUNA, "none"),
    ("max", GPT55, "xhigh"),
    ("high", LOCALM, None), (None, OPUS, None),
])
def test_clamp_effort(effort, caps, want):
    assert policy.clamp_effort(effort, caps) == want


# ── keys and config ─────────────────────────────────────────────────────────────

def test_bad_keys_refused():
    for k in ["", "sk-abc", "rgw.research-worker.public.wrong", f"rgw.someone.public.{S}"]:
        with pytest.raises(policy.Refused) as e:
            policy.parse_key(k, S, CFG)
        assert e.value.status == 401


def test_unknown_sensitivity_is_strictest():
    assert policy.parse_key(f"rgw.research-worker.secret.{S}", S, CFG) == ("research-worker", "air-gapped")


@pytest.mark.parametrize("old,new", [
    ("cheap: local-fast", "cheap: cloud-cheap"),            # a name on both sides
    ("private_default: local", "private_default: zdr"),     # unknown side
    ("  strong: high", "  strong: extreme"),                # unknown effort
])
def test_bad_routing_rejected(tmp_path, old, new):
    text = Path(__file__).with_name("routing.yaml").read_text()
    assert old in text
    (tmp_path / "r.yaml").write_text(text.replace(old, new, 1))
    with pytest.raises(ValueError):
        policy.load(tmp_path / "r.yaml")

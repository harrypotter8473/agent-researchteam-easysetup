# Model gateway: route by role and paper sensitivity

Every Hermes profile talks to one LiteLLM proxy. The proxy picks the model and the effort
for each request:

```
hermes (any profile) ──key: rgw.<profile>.<sensitivity>.<secret>──▶ LiteLLM + research-gateway hooks
  1 tier         "research" → the profile's tier (strong / mid / cheap); "research-aux" → cheap
  2 sensitivity  public < private < air-gapped: highest of the key and any sensitivity line
  3 side         public → cloud · private → decide_side() (default local) · air-gapped → local
  4 available?   local chosen but not configured → refused "local models unavailable"
  5 effort       per tier / per role, fitted to whichever model is actually called
  6 fallback     Claude fails after retries → OpenAI (cloud side only)
```

| Sensitivity | Models | When local models are unavailable |
|---|---|---|
| `public` (default) | cloud, freely: Claude (Opus 5.5 / Sonnet 5.5 / Haiku 4.5), OpenAI fallback (GPT-6 Astra / 6.1 Sol / 6 Luna) | not affected |
| `private` | cloud **or** local, decided per request by `decide_side()`. That module isn't written yet, so `private_default: local` applies | refused with "local models unavailable"; never sent to the cloud instead |
| `air-gapped` | local only; the runner also tells the agent to use no web tools | refused the same way |

When local models are unavailable, the runner checks with the gateway before each task
(`research-probe`, which calls no model). A private or air-gapped task is then marked
**blocked** with the reason and posted to Mattermost; the agent never starts. Once local
models are configured, unblock it through the lead.

**Today no local models are configured, so only public papers run.** Papers are public
unless their `CLAUDE.md` says otherwise (the template's default, and what a missing line means).

| File | What it is |
|---|---|
| `routing.yaml` | Tier per profile, cloud/local model names, `private_default`, effort per tier and role, the lead's `auto` rule |
| `litellm.config.yaml` | The proxy: cloud models with Claude→OpenAI fallbacks, local models (commented out until you have them), no cache |
| `research_gateway_policy.py` | The rules in plain Python, including `decide_side()` (the future module) and `clamp_effort()`. `test_policy.py` tests them |
| `research_gateway_litellm.py` | LiteLLM custom auth, plus two hooks: route each request, fit effort per deployment. Also answers `research-probe` |
| `hermes.overlay.yaml` | Profile config: main and auxiliary models → the `research-gateway` provider |
| `check.py` | Checks one profile: config, `.env`, where each class routes, one real call |

On a single server, `../server/install-server.sh` sets all of this up. See the main README.

## How each rule is decided

**Tier comes from the role, not from each message.** The writer, reviewer and experimenter
get `strong`; research gets `mid`. Keeping one model per session keeps the prompt cache and
the tool-call style stable, and Claude's thinking blocks are tied to the model that wrote
them. The lead is the exception (`auto`): its tier is chosen once per conversation from the
first message, `cheap` for a short status question and `strong` for anything else.

**Sensitivity only goes up.** It is the higher of:
- the key, which the runner builds per task from the paper's `CLAUDE.md`; a missing line
  counts as public;
- a `Sensitivity:` line anywhere in the conversation.

The lead and the `-chat` profiles hold fixed keys (`CHAT_SENSITIVITY`, default public), so
they rely on the second rule. Once one of them reads a private paper's `CLAUDE.md`, that
conversation is private. An unknown value in a key counts as air-gapped.

**`decide_side()` only exists for private papers.** It returns `cloud`, `local` or `None`
(meaning `private_default`). Public always goes to the cloud and air-gapped always stays
local, so the module is never asked about either. If it picks `cloud` for a request, that
request goes to the cloud even while local models are unavailable. The rule is only that a
request which belongs on local models is never moved to the cloud.

**Availability is decided by the setup.**
- A side counts as available only if all three of its model names are in
  `litellm.config.yaml`. That way, main and auxiliary calls never split across sides.
- A local model that is configured but down also fails the request, with the upstream
  error.
- No fallback ever leads out of a local model.

### Effort

`reasoning_effort` is the one LiteLLM setting that maps onto every provider. Checked in
LiteLLM 1.104's source and against a fake upstream that records what it receives:

| Model | What `reasoning_effort: X` becomes |
|---|---|
| Opus 5.5, Sonnet 5.5 | `thinking: {type: adaptive}` + `output_config: {effort: X}` |
| Haiku 4.5 | `thinking: {type: enabled, budget_tokens: …}`; omitted or `none` = no thinking |
| GPT-6 Astra / 6.1 Sol / 6 Luna (`openai/responses/…`) | `reasoning: {effort: X}`; only Luna accepts `none` |
| local (`hosted_vllm/…`) | nothing is sent |

Two LiteLLM behaviours decide where effort has to be set:
- a value sent with the request overrides the per-model one;
- on a fallback, the request's value is passed unchanged to the fallback model.

So effort is set in two steps:
1. **Once per request** (`async_pre_call_hook`): discard any effort or thinking settings
   the client sent (`reasoning_effort`, `thinking`, `output_config`, `reasoning`), and record
   the level from `routing.yaml`.
2. **For each model LiteLLM actually calls, fallbacks included**
   (`async_pre_call_deployment_hook`): `clamp_effort()` fits the level to that model.
   - `max` steps down to `xhigh`, and `xhigh` to `high`, on models that lack them.
   - `none` becomes `low` on models that always think, and nothing at all on Haiku.
   - Local models get no effort sent.

Hermes's own setting is ignored because Hermes can't know which model it will get (cloud,
fallback or local). The per-model fitting can only happen after LiteLLM has picked the
model.

| Who | Effort |
|---|---|
| strong tier | `high` |
| reviewer | `xhigh` |
| lead | `medium` |
| mid tier | `medium` |
| cheap tier and auxiliary calls | `none` |

## Changing things later

The installer copies the config into `/opt/research-gateway/` once and keeps your edits on re-runs.
Edit it there, then run `sudo systemctl restart research-gateway`.

- **Local models:**
  1. Serve them with tool calling on (vLLM: `--enable-auto-tool-choice --tool-call-parser
     <parser>`, context ≥ 64k).
  2. Uncomment `local-strong` and `local-fast` in `litellm.config.yaml`, then restart.
  3. Private papers now run locally (while `private_default: local`), and air-gapped ones
     run at all.
  4. Ask the lead to retry the blocked tasks.
- **The decision module:** implement `decide_side()` in `research_gateway_policy.py`, keeping
  `test_policy.py` passing. Then re-run the installer, which updates the code, or copy the
  file to `/opt/research-gateway/` and restart.

## What the gateway does not cover

- **Web search and fetches.** These are tool calls, not model calls. For private papers the
  agents are told to search by topic terms only; for air-gapped papers, to use no web tools
  at all. Both are instructions; nothing enforces them.
- **Mattermost.** Task headlines and the lead's replies go to your Mattermost server.
  Self-host it.
- **The lead after context compression.** If compression drops the sensitivity line, later
  turns go back to the key's class.
- **Non-outage errors.** LiteLLM's `fallbacks` can also fire on some request errors, not
  only outages, in which case OpenAI answers. Watch for `attempt … -openai` lines in the
  gateway log.

## Tested vs. assumed

**Tested with LiteLLM 1.104 against the fake upstream:**
- every route and both sides, with and without local models configured;
- refusals with "local models unavailable", for both private and air-gapped;
- `decide_side()` overrides;
- Claude down → OpenAI through the Responses bridge, with `store: false` and effort fitted
  to the model;
- the client's effort setting overridden;
- probes, auth refusals and `check.py`;
- the runner blocking a private task without starting the agent, and posting it to
  Mattermost;
- the full server installer, run twice against stand-ins.

`test_policy.py` (29 tests) covers the rules.

**Not tested against the real services:**
- the Anthropic and OpenAI APIs themselves, and whether your OpenAI account has the GPT-6
  models;
- a live Hermes: the `providers:` and `auxiliary.<task>` config keys, and
  `hermes -p <profile> gateway start` installing its service;
- systemd itself.

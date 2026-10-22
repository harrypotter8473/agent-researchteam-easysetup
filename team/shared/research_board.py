#!/usr/bin/env python3
"""research_board — the research team's task board, carried inside each paper's git repo.

The agents share nothing but each paper's git remote, so that is the board: one task = one
file, <paper>/.tasks/<id>.md. On one PC the remotes are bare repos under
<team home>/boards/; across devices any git remote every device can push to works.

  Lead (interactive, in its clone of the paper; the workspace is its terminal cwd):
    research_board.py project-create <name>          # scaffold, initialize, bind and register a project
    research_board.py init   <folder>                # manually register an existing paper repo
    research_board.py new    <paper> --id r1-methods --assignee research-reviewer --audit-of r1-author \
                                 --expects reviews/r1-methods/verdict.json --body-file prompt.md
    research_board.py list   <paper>
    research_board.py show   <paper> <id>
    research_board.py wait   <paper> <id> [<id> ...] [--timeout 150]
    research_board.py edit   <paper> <id> [--after a,b] [--append TEXT] [--status ready]
    research_board.py publish <paper> -m MSG <path> [...]      # lead's own files (CLAUDE.md, claims.md, notes/)
    research_board.py ledger <paper> [--verify]                # what each task read and produced
    research_board.py locations [--write]                      # paths, projects and remotes
    research_board.py deliver <paper> <path>[:docx] --thread TH   # attach a file to the thread, verified

    research_board.py setup  <paper> --channel <team>/<channel-name> [--mention @you]   # once per paper
    research_board.py thread <paper> "Request — research, analysis, independent audit"
                                 # prints a post id; pass it to `new --thread` for the round's tasks
    research_board.py approve <paper> x1 --by @you [--amendment 1]   # record the user's approval

  Worker (one per role; start several --slot's for parallel referees):
    research_board.py run --role research-reviewer [--slot 1] [--papers-file F] [<git-url> ...]

A worker loop: fetch -> pick a `ready` task whose prerequisites are done and audited
-> claim it by pushing `status: running` (a rejected push means another worker won) -> run
`hermes -p <role> chat -Q --query-file <prompt>` -> commit only the role's output paths, the
task file and one ledger line -> push. With --papers-file the list of papers is re-read on
every pass, so a paper added with `project-create` is picked up without restarting the runners.

The blind reviewer (research-reviewer) runs in an exported snapshot of the paper
with no .git, .tasks or prior reviews; only current content and criteria reach it.

Record (.tasks/ledger.jsonl, append-only): one line per finished task — role, status, the
commit the agent worked on, and the SHA-256 of every file it published. Each line carries the
hash of the line before it, so a rewritten history is detected (`ledger --verify`) and
reported instead of silently extended. A review therefore always names the exact version it
read; the task result and the round checkpoint repeat that commit.

Safeguards: before each task the runner checks the profile's SOUL.md and team skills against
the manifest written at install (profile-manifest.json next to this file); a changed file blocks the
task instead of running an agent with unknown instructions. A run that fails on a transient
model error (rate limit, overload, timeout, 5xx) is retried with backoff. The agent's process
never receives the bot token or the gateway secret.

Delivery: a task may carry `deliver: <path>[:docx], ...`. When it is done the runner attaches
each file to the task's thread as its own bot, downloads it again and compares SHA-256; a
Markdown report with `:docx` is converted to Word first (report_docx.py, no dependencies).
Delivery happens after the work is accepted, so a failed upload never turns into a rewrite.

Experiments: a task may carry `ready_when: jobs-done <exp-id>`; the runner then starts it only
once every job the experimenter launched for that experiment (under <team home>/jobs/, or
$RESEARCH_TEAM_JOBS) has finished, and posts job progress while it waits. An experiment's
protocol.md is frozen once the lead has recorded an approval.md next to it: the runner
restores any edit to it, or to any approval.md, and fails the task.

Progress goes to Mattermost when the paper has `.tasks/board.conf` (written by `setup`):
the runner updates a progress post in the task's round thread as its own bot and mentions
the user on decisions and round checkpoints. The private lead coordinator consumes board
results without agent-to-agent Mattermost messages. Credentials: MATTERMOST_URL and MATTERMOST_TOKEN
from the environment, else from the Hermes profile's .env. Posting never blocks the board —
if Mattermost is down, the git board still works.

Model gateway (optional, ../gateway/): when RESEARCH_GATEWAY_SECRET is set (environment, else the
Hermes profile's .env), each task's hermes process gets RESEARCH_GATEWAY_API_KEY =
rgw.<profile>.<sensitivity>.<secret>, with the sensitivity read from the paper's CLAUDE.md
(`**Sensitivity:** public|private|air-gapped`; a missing line counts as public for now, an
unreadable CLAUDE.md as private).
The gateway decides which models each class may use (../gateway/routing.yaml). Before a
non-public task, the runner asks the gateway (model `research-probe`) whether it can serve it;
if local models are unavailable the task is marked blocked with that reason instead of run.
Without a gateway, a non-public paper is refused the same way: its models would be cloud ones.

Paths: RESEARCH_TEAM_HOME (default ~/.hermes-research-team), HERMES_HOME or HERMES_ROOT
(default ~/.hermes) for the profiles, RESEARCH_TEAM_HERMES or --hermes for the hermes command.
"""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess as sp
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
# The installer deliberately enables PYTHONSAFEPATH and clears PYTHONPATH.
# Trust only this manifest-verified payload directory, never the paper/cwd.
HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import audit_gate
import research_activity as activity

TASKS = ".tasks"
LEDGER = f"{TASKS}/ledger.jsonl"
FIELDS = ["id", "assignee", "status", "after", "ready_when", "expects", "skills", "thread", "notify_done", "gate",
          "deliver", "audit_of", "audit_scope", "resume_policy", "max_attempts", "attempt", "stop_reason", "claimed_by", "base", "updated"]
TERMINAL = {"done", "partial", "blocked", "failed"}
# What each role may publish. Everything else a worker leaves behind is discarded.
OUTPUTS = {
    "research-worker": ["paper", "claims.md", "outline.md", "experiments", "evidence", "reports"],
    "research-reviewer": ["reviews"],
    "research-scout": ["notes", "sources"],
}
BLIND = {"research-reviewer"}
# Skills every task of a role preloads (Hermes has no per-profile auto-load), plus the task's own.
ROLE_SKILLS = {
    "research-worker": ["lit-search"],
    "research-reviewer": ["lit-search", "report-audit"],
    "research-scout": ["lit-search"],
}
BUILD_JUNK = ["aux", "log", "fls", "fdb_latexmk", "out", "synctex.gz", "blg", "toc", "bcf", "run.xml"]
GITIGNORE = [".DS_Store", "Thumbs.db", ".hermes.md"] + [f"*.{e}" for e in BUILD_JUNK]
TEAM_CONTEXT = HERE / "team.hermes.md"


def _team_home():
    """RESEARCH_TEAM_HOME, else the home the installer recorded next to this file, else the default."""
    if os.environ.get("RESEARCH_TEAM_HOME"):
        return Path(os.environ["RESEARCH_TEAM_HOME"])
    rec = HERE / "team-home.txt"
    if rec.is_file() and rec.read_text(encoding="utf-8").strip():
        return Path(rec.read_text(encoding="utf-8").strip())
    return Path.home() / ".hermes-research-team"


TEAM_HOME = _team_home()
JOBS = Path(os.environ.get("RESEARCH_TEAM_JOBS", TEAM_HOME / "jobs"))
# Written at install: SHA-256 of each profile's SOUL.md and team skills.
MANIFEST = Path(os.environ.get("RESEARCH_TEAM_MANIFEST", HERE / "profile-manifest.json"))
WINDOWS = os.name == "nt"
MAX_DELIVERY_BYTES = 25 * 1024 * 1024
TEAM_MAX_TURNS = int(os.environ.get("RESEARCH_MAX_TURNS", "2000"))
MAX_ATTEMPTS = int(os.environ.get("RESEARCH_MAX_ATTEMPTS", "50"))
RETRY_DELAYS = [min(120, 2 ** min(n + 1, 7)) for n in range(int(os.environ.get("RESEARCH_MODEL_RETRIES", "100")))]
TRANSIENT = re.compile(r"\b(429|500|502|503|504|529)\b|rate.?limit|overloaded|temporar(il)?y unavailable|"
                       r"timed? ?out|connection (reset|refused|aborted|error)|ECONNRESET|service unavailable", re.I)
ITERATION_LIMIT = re.compile(r"max(?:imum)?[_ -]?(?:tool[_ -]?)?iterations?[_ -]?reached|"
                             r"reached\s+(?:the\s+)?max(?:imum)?\s+(?:tool[- ]?)?iterations?|"
                             r"(?:tool[- ]?)?iteration (?:limit|budget)|budget exhausted|"
                             r"max_turns|maximum tool-iteration limit", re.I)


class LeadTurnPartial(RuntimeError):
    """The coordinator saved a bounded lead attempt that needs a human to resume."""


# Never handed to an agent's process: the agent does not post as the bot or mint gateway keys.
CHILD_ENV_DROP = {"MATTERMOST_TOKEN", "MATTERMOST_URL", "RESEARCH_GATEWAY_SECRET"}
SENSITIVE_NOTE = {
    "private": """
Sensitivity: private — keep this paper's unpublished text, results and claims out of web
searches and fetched URLs; search the literature by topic terms only.
""",
    "air-gapped": """
Sensitivity: air-gapped — do not use any web search, web fetch or browser tool for this
task, and send nothing about the paper off this machine. If the task cannot be done without
the web, block and say so.
""",
}
FOOTER = """
---
Runner note: you are task `{id}`, running unattended as {role}. Your working directory is
the paper folder ({cwd}); every path in this task is relative to it. There is no human to
answer questions — if you cannot proceed, block. Do not run git; the runner commits your
output. End your reply with exactly one line:
`STATUS: done` or `STATUS: blocked — <reason>`.
"""


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def die(msg):
    sys.exit(f"research_board: {msg}")


def rd(path):
    """Text files are UTF-8 everywhere (Windows would otherwise use the ANSI code page)."""
    return Path(path).read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")


def wr(path, text, append=False):
    with open(path, "a" if append else "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(repo, *args, check=True):
    r = sp.run(["git", "-C", str(repo), *args], capture_output=True, encoding="utf-8", errors="replace")
    if check and r.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip() or r.stdout.strip()}")
    return r


def git_identity(repo, name):
    """Commits need an author; a fresh Windows user often has none configured."""
    if not git(repo, "config", "user.email", check=False).stdout.strip():
        git(repo, "config", "user.name", name)
        git(repo, "config", "user.email", f"{name}@research-team.local")
    git(repo, "config", "core.autocrlf", "false")  # task files must keep LF


def hermes_root():
    home = Path(os.environ.get("HERMES_HOME") or os.environ.get("HERMES_ROOT") or Path.home() / ".hermes")
    # Hermes changes HERMES_HOME to the active profile during chat. Board
    # subprocesses must not look under profiles/<role>/profiles/<role>/.env.
    return home.parent.parent if home.parent.name.casefold() == "profiles" else home


def repo_name(url):
    return re.sub(r"\.git$", "", re.split(r"[\\/:]", url.rstrip("/\\"))[-1])


def clone_path(root, url):
    """Keep an existing clone when it matches, but avoid same-name remote collisions."""
    name = re.sub(r"[^A-Za-z0-9._-]", "_", repo_name(url))[:64] or "project"
    legacy = root / name
    if legacy.is_dir():
        origin = git(legacy, "remote", "get-url", "origin", check=False)
        if origin.returncode == 0 and origin.stdout.strip() == url:
            return legacy
    return root / f"{name}-{hashlib.sha256(url.encode()).hexdigest()[:10]}"


# ---------- processes (POSIX and Windows) ----------

def pid_alive(pid):
    if WINDOWS:
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k32.GetExitCodeProcess(h, ctypes.byref(code))
        k32.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


def kill_tree(proc):
    """Stop an agent and everything its shell started."""
    if WINDOWS:
        result = sp.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True, timeout=10)
        if result.returncode and proc.poll() is None:
            proc.kill()
    else:
        try:
            os.killpg(proc.pid, 9)
        except OSError:
            proc.kill()


def popen_group(cmd, **kw):
    if WINDOWS:
        kw["creationflags"] = kw.get("creationflags", 0) | sp.CREATE_NEW_PROCESS_GROUP
    else:
        kw["start_new_session"] = True
    return sp.Popen(cmd, **kw)


# ---------- task files ----------

def load(path):
    m = re.match(r"---\n(.*?)\n---\n?(.*)", rd(path), re.S)
    if not m:
        die(f"{path}: no front matter")
    meta = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip()
    return meta, m.group(2)


def save(path, meta, body):
    fm = "\n".join(f"{k}: {meta.get(k, '')}".rstrip() for k in FIELDS)
    path.parent.mkdir(exist_ok=True)
    wr(path, f"---\n{fm}\n---\n{body}")


def csv(v):
    return [x.strip() for x in (v or "").split(",") if x.strip()]


def tasks(repo):
    d = Path(repo) / TASKS
    return {p.stem: (p, *load(p)) for p in sorted(d.glob("*.md"))} if d.is_dir() else {}


def waiting_on(meta, board):
    waiting = []
    for tid in csv(meta.get("after")):
        if tid not in board or board[tid][1].get("status") != "done":
            waiting.append(tid)
            continue
        path, source, _ = board[tid]
        # Audits consume unapproved versions; ordinary dependent work must not.
        if meta.get("assignee") != "research-reviewer" and source.get("assignee") != "research-reviewer":
            if not audit_gate.approved(path.parent.parent, tid):
                waiting.append(tid + ":audit")
        elif source.get("assignee") == "research-reviewer":
            if not csv(source.get("audit_of")) or not all(audit_gate.approved(path.parent.parent, t) for t in csv(source.get("audit_of"))):
                waiting.append(tid + ":rejected")
    return waiting


# ---------- git plumbing ----------

def sync(repo):
    """Lead clone: bring in the workers' pushes, keeping any local edits."""
    git(repo, "pull", "--rebase", "--autostash", "-q")


def stage(repo, paths, excludes=()):
    """Stage paths; return the staged file names (relative, '/'-separated)."""
    spec = [str(p) for p in paths if (Path(repo) / p).exists()] + [f":(exclude,glob)**/*.{e}" for e in excludes]
    if not any(not s.startswith(":(") for s in spec):
        return []
    git(repo, "add", "-A", "--", *spec)
    return [l for l in git(repo, "diff", "--cached", "--name-only").stdout.splitlines() if l.strip()]


def commit_push(repo, msg):
    if not git(repo, "diff", "--cached", "--quiet", check=False).returncode:
        return False
    git(repo, "commit", "-q", "-m", msg)
    for _ in range(5):
        if not git(repo, "push", "-q", check=False).returncode:
            return True
        if git(repo, "pull", "--rebase", "-q", check=False).returncode:
            # Independent roles append to the same hash chain. Rebase cannot
            # text-merge two new tails, but published events must stay byte-exact.
            if merge_unpublished_ledger(repo):
                if not git(repo, "-c", "core.editor=true", "rebase", "--continue", check=False).returncode:
                    continue
            git(repo, "rebase", "--abort", check=False)
            raise RuntimeError("rebase conflict while publishing; local commit preserved for recovery")
    raise RuntimeError("push kept failing")


def merge_unpublished_ledger(repo):
    """Resolve ONLY concurrent ledger tails; never alter published chain bytes.

    During rebase/cherry-pick stage 2 is the published/current side and stage 3
    is the pending local side. Event identity excludes only the chaining field.
    Other conflicts or damaged chains require explicit recovery, not guessing.
    """
    conflicts = git(repo, "diff", "--name-only", "--diff-filter=U").stdout.splitlines()
    if conflicts != [LEDGER]:
        return False
    current = git(repo, "show", ":2:" + LEDGER, check=False)
    pending = git(repo, "show", ":3:" + LEDGER, check=False)
    if current.returncode or pending.returncode:
        return False
    upstream = [line for line in current.stdout.splitlines() if line.strip()]
    local = [line for line in pending.stdout.splitlines() if line.strip()]
    if ledger_check(upstream) is not None or ledger_check(local) is not None:
        return False
    def identity(entry):
        return json.dumps({k: v for k, v in entry.items() if k != "prev"},
                          sort_keys=True, ensure_ascii=False)
    seen = {identity(json.loads(line)) for line in upstream}
    merged = list(upstream)
    for line in local:
        entry = json.loads(line)
        key = identity(entry)
        if key in seen:
            continue
        entry["prev"] = hashlib.sha256(merged[-1].encode("utf-8")).hexdigest() if merged else ""
        merged.append(json.dumps(entry, sort_keys=True, ensure_ascii=False))
        seen.add(key)
    wr(Path(repo) / LEDGER, "\n".join(merged) + ("\n" if merged else ""))
    git(repo, "add", "--", LEDGER)
    return True


def publish(repo, paths, msg, excludes=()):
    """Stage paths, commit, push; rebase and retry if another worker pushed first."""
    stage(repo, paths, excludes)
    return commit_push(repo, msg)


def reset_to_remote(repo, discard_claim=False):
    git(repo, "fetch", "-q", "origin")
    pending = git(repo, "log", "--format=%H", "@{u}..HEAD").stdout.strip()
    if pending and not (discard_claim and all(subject.startswith("board: claim ") for subject in
            git(repo, "log", "--format=%s", "@{u}..HEAD").stdout.splitlines())):
        raise RuntimeError("unpublished local commits preserved; recover publication before resetting: " + pending.splitlines()[0])
    git(repo, "reset", "-q", "--hard", "@{u}")
    git(repo, "clean", "-fdq")


# ---------- ledger (append-only, hash-chained) ----------

def ledger_lines(repo):
    p = Path(repo) / LEDGER
    return [l for l in rd(p).splitlines() if l.strip()] if p.is_file() else []


def ledger_check(lines):
    """-> index of a line whose `prev` does not match the line before it (or that is not JSON),
    or None. A break that a later entry records (`chain_break_at_line`) counts as reported."""
    prev, broken = "", None
    for i, line in enumerate(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            entry = None
        if broken is None and (entry is None or entry.get("prev", "") != prev):
            broken = i
        elif broken is not None and entry and entry.get("chain_break_at_line") == broken + 1:
            broken = None
        prev = hashlib.sha256(line.encode("utf-8")).hexdigest()
    return broken


def ledger_append(repo, entry):
    lines = ledger_lines(repo)
    broken = ledger_check(lines)
    entry = dict(entry)
    if broken is not None:
        entry["chain_break_at_line"] = broken + 1  # recorded, never repaired silently
    entry["prev"] = hashlib.sha256(lines[-1].encode("utf-8")).hexdigest() if lines else ""
    p = Path(repo) / LEDGER
    p.parent.mkdir(exist_ok=True)
    wr(p, json.dumps(entry, ensure_ascii=False, sort_keys=True) + "\n", append=True)
    return broken


# ---------- Mattermost ----------

def _dotenv(path):
    out = {}
    if path.is_file():
        for line in rd(path).splitlines():
            k, sep, v = line.strip().partition("=")
            if sep and not k.startswith("#"):
                out[k.strip().removeprefix("export ").strip()] = v.strip().strip("'\"")
    return out


def profile_env(profile):
    """The profile's own .env — the only one a Hermes profile reads (not the root .env)."""
    return _dotenv(hermes_root() / "profiles" / profile / ".env")


def sensitivity(clone):
    """The paper's `**Sensitivity:**` from its CLAUDE.md. No such line: public (the current
    default). No readable CLAUDE.md: private, since we cannot tell what the paper is."""
    try:
        text = rd(Path(clone) / "CLAUDE.md")
    except OSError:
        return "private"
    m = re.search(r"\*\*Sensitivity:\*\*\s*`?(public|private|air-gapped)\b", text, re.I)
    return m.group(1).lower() if m else "public"


def child_env(clone, profile):
    """Environment for one task's hermes process: the gateway key for this paper if a gateway
    is configured; never the bot token or the gateway secret."""
    env = {k: v for k, v in os.environ.items() if k not in CHILD_ENV_DROP}
    sens = sensitivity(clone)
    secret = os.environ.get("RESEARCH_GATEWAY_SECRET") or profile_env(profile).get("RESEARCH_GATEWAY_SECRET")
    if secret:
        env["RESEARCH_GATEWAY_API_KEY"] = f"rgw.{profile}.{sens}.{secret}"
    return env, sens, bool(secret)


def gateway_probe(env, profile):
    """Ask the gateway whether it can serve this task (model `research-probe`; no model is
    called). -> None if it can, or cannot be asked; else the reason it cannot."""
    url = env.get("RESEARCH_GATEWAY_URL") or profile_env(profile).get("RESEARCH_GATEWAY_URL")
    key = env.get("RESEARCH_GATEWAY_API_KEY")
    if not url or not key:
        return None
    req = urllib.request.Request(
        url.rstrip("/") + "/chat/completions", method="POST",
        data=json.dumps({"model": "research-probe", "max_tokens": 1,
                         "messages": [{"role": "user", "content": "probe"}]}).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30).close()
        return None
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read() or b"{}").get("error", {}).get("message", "")
        except ValueError:
            msg = ""
        if "research-gateway-probe: ok" in msg:
            return None
        return msg.removeprefix("research-gateway: ") or f"gateway answered HTTP {e.code}"
    except OSError as e:
        return f"model gateway unreachable at {url} ({e})"


def mm_creds(profile):
    """URL and bot token: environment, else the Hermes profile's own .env."""
    env = profile_env(profile)
    env.update({k: v for k, v in os.environ.items() if k.startswith("MATTERMOST_")})
    url, token = env.get("MATTERMOST_URL", "").rstrip("/"), env.get("MATTERMOST_TOKEN", "")
    return (url, token) if url and token else None


def mm_api(creds, method, path, payload=None):
    url, token = creds
    req = urllib.request.Request(f"{url}/api/v4{path}", method=method,
                                 data=json.dumps(payload).encode() if payload is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def mm_upload(creds, channel, name, data, mime):
    """Upload one file; -> file id. Fails unless the server reports exactly this file."""
    url, token = creds
    boundary = "research" + uuid.uuid4().hex
    safe = re.sub(r'[^A-Za-z0-9._-]', "_", name)
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"channel_id\"\r\n\r\n{channel}\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{safe}\"\r\n"
            f"Content-Type: {mime}\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{url}/api/v4/files", data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        infos = json.load(r).get("file_infos", [])
    if len(infos) != 1 or infos[0].get("size") != len(data):
        raise RuntimeError("upload not confirmed by the server")
    return infos[0]["id"]


def mm_download(creds, file_id):
    url, token = creds
    req = urllib.request.Request(f"{url}/api/v4/files/{file_id}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read(MAX_DELIVERY_BYTES + 1)


def board_conf(repo):
    return _dotenv(Path(repo) / TASKS / "board.conf")


def activity_project(repo):
    """Workers have hashed clone names; all views must use the shared project name."""
    origin = git(repo, 'remote', 'get-url', 'origin', check=False)
    return repo_name(origin.stdout.strip()) if origin.returncode == 0 and origin.stdout.strip() else Path(repo).name


class Notifier:
    """Posts task events for one paper. Every failure is logged and swallowed."""

    def __init__(self, repo, profile):
        self.conf, self.creds = board_conf(repo), mm_creds(profile)
        self.channel = self.conf.get("mattermost_channel")
        self.mention = self.conf.get("mention", "")
        self.project = activity_project(repo)
        self.role = profile if profile in activity.ROLES else 'research-lead'
        self.journals = {}

    def journal(self, task):
        if task not in self.journals:
            self.journals[task] = activity.Journal(TEAM_HOME, self.project, task, self.role)
        return self.journals[task]

    def board_link(self):
        try:
            url = json.loads(rd(TEAM_HOME / 'dashboard.json')).get('url', '')
            if re.fullmatch(r'http://127\.0\.0\.1:[1-9][0-9]{0,4}/', url):
                return '\n상세 진행·문서·승인 요청: ' + url
        except (OSError, ValueError, TypeError): pass
        return ''

    def post(self, text, thread="", ping=False, file_ids=None):
        if not (self.creds and self.channel):
            return None
        try:
            # Task output and notify_done are model-authored. Only the configured human
            # mention may create a notification; never route a bot post to another bot.
            safe = re.sub(r"@(?=[A-Za-z0-9_-])", "@\u200b", activity.clean(headline(text, 400), 450)) + self.board_link()
            msg = f"{safe} {self.mention}".rstrip() if ping else safe
            payload = {"channel_id": self.channel, "message": msg, "root_id": thread or ""}
            if file_ids:
                payload["file_ids"] = file_ids
            return mm_api(self.creds, "POST", "/posts", payload)["id"]
        except Exception as e:  # never let chat break the board
            print(f"[{now()}] mattermost: {e}", file=sys.stderr, flush=True)
            return None

    def progress(self, task_id, text, thread=""):
        """Routine progress belongs to the local board, never a chat heartbeat."""
        self.journal(task_id).emit('작업 상태', text)
        return None

    def deliver(self, name, data, mime, thread, label):
        """Attach bytes to the thread, read them back, compare SHA-256. -> (ok, detail)."""
        if not (self.creds and self.channel):
            return False, "no Mattermost channel or bot token for this paper"
        digest = hashlib.sha256(data).hexdigest()
        try:
            fid = mm_upload(self.creds, self.channel, name, data, mime)
            if hashlib.sha256(mm_download(self.creds, fid)).hexdigest() != digest:
                return False, "the downloaded copy does not match (SHA-256)"
            if not self.post(f":page_facing_up: {label} — sha256 `{digest[:16]}…`, verified after upload", thread, file_ids=[fid]):
                return False, "uploaded and verified, but the post failed"
            return True, digest
        except Exception as e:
            return False, str(e)[:300]


def headline(report, limit=600):
    lines = [l.strip() for l in report.splitlines() if l.strip() and not re.match(r"^\W*STATUS:", l.strip(), re.I)]
    text = " · ".join(lines[:4])
    return text if len(text) <= limit else text[:limit - 1] + "…"


def checkpoint(meta_md):
    """One line from the chair's meta.md: the call and the plan's tag counts."""
    text = rd(meta_md) if meta_md.is_file() else ""
    counts = " · ".join(f"{t} {len(re.findall(t, text))}" for t in ("CLAIM-CHANGING", "EVIDENCE-NEEDED", "PRESENTATION"))
    call = ""
    m = re.search(r"^\W*(?:#+\s*)?\**Call\**\W*(.*)$", text, re.M | re.I)
    if m:
        call = m.group(1).strip() or next((l.strip() for l in text[m.end():].splitlines() if l.strip()), "")
    return f"Call: {call[:300] or '(see meta.md)'} — {counts}"


def fmt_age(sec):
    return f"{int(sec // 3600)}h {int(sec % 3600 // 60)}m"


# ---------- experiment jobs (same layout as exp-run/scripts/launch.py) ----------

def job_state(d):
    """done / failed / capped / running / lost for one run dir <JOBS>/<paper>/<exp>/<run>/."""
    if (d / "DONE").exists():
        code = rd(d / "exit_code").strip() if (d / "exit_code").exists() else "?"
        return "done" if code == "0" else ("capped" if code == "124" else "failed")
    try:
        return "running" if pid_alive(int(rd(d / "pid").strip())) else "lost"
    except (OSError, ValueError):
        return "lost"  # no DONE and no live process: machine rebooted or the job was killed


def jobs_summary(paper, exp):
    runs = sorted(x for x in (JOBS / paper / exp).glob("*") if x.is_dir()) if (JOBS / paper / exp).is_dir() else []
    states = [job_state(r) for r in runs]
    starts = [r.stat().st_mtime for r in runs]
    return {"total": len(runs), **{k: states.count(k) for k in ("done", "failed", "capped", "running", "lost")},
            "age": time.time() - min(starts) if starts else 0}


def condition_met(clone, cond):
    """Built-in wait conditions only — never shell from a task file. Returns (met, why, lost)."""
    if not cond:
        return True, "", 0
    kind, _, arg = cond.partition(" ")
    if kind == "jobs-done" and arg.strip():
        js = jobs_summary(clone.name, arg.strip())
        if js["total"] == 0:
            return False, "no jobs launched on this device", 0
        return js["running"] == 0, (f"jobs {js['total'] - js['running']}/{js['total']} finished"
                                    f" ({js['done']} ok, {js['failed']} failed, {js['capped']} hit the time cap,"
                                    f" {js['lost']} lost), running {fmt_age(js['age'])}"), js["lost"]
    return False, f"unknown ready_when condition: {cond}", 0


def guard_frozen(clone):
    """Undo edits to approval records and to approved protocols; return what was touched."""
    st = git(clone, "status", "--porcelain", "-uall").stdout.splitlines()
    touched = []
    for line in st:
        path = line[3:].split(" -> ")[-1].strip('"')
        m = re.match(r"experiments/([^/]+)/(approval\.md|protocol\.md)$", path)
        if not m:
            continue
        approved = git(clone, "cat-file", "-e", f"HEAD:experiments/{m.group(1)}/approval.md", check=False).returncode == 0
        if m.group(2) == "approval.md" or approved:
            touched.append(path)
            if git(clone, "cat-file", "-e", f"HEAD:{path}", check=False).returncode == 0:
                git(clone, "checkout", "HEAD", "--", path)
            else:
                (clone / path).unlink(missing_ok=True)
    return touched


# ---------- profile integrity ----------

def profile_drift(profile):
    """Return mismatched files; a missing manifest fails closed too."""
    if not MANIFEST.is_file():
        return ["profile-manifest.json (missing)"]
    try:
        expected = json.loads(rd(MANIFEST)).get("profiles", {}).get(profile)
    except ValueError:
        return ["manifest.json (unreadable)"]
    if not expected or "SOUL.md" not in expected:
        return [f"{profile} (not in manifest)"]
    root = hermes_root() / "profiles" / profile
    bad = [rel for rel, digest in expected.items()
           if not (root / rel).is_file() or sha256_file(root / rel) != digest]
    skills = root / "skills" / "research-team"
    if skills.is_dir():
        for f in skills.rglob("*"):
            rel = f.relative_to(root).as_posix()
            if f.is_file() and rel not in expected and "__pycache__" not in rel:
                bad.append(rel + " (not installed by the team)")
    return sorted(bad)


# ---------- lead commands ----------

LOCATION_MARKER = "<!-- Hermes Research locations: generated by research_board.py -->"


def _location_text(value):
    """Keep paths and remote names readable in Markdown without allowing table markup."""
    return str(value).replace("|", "\\|").replace("`", "'")


def _public_remote(url):
    """Never copy credentials embedded in an HTTPS remote into the user's path guide."""
    if "://" not in url:
        return url
    parsed = urllib.parse.urlsplit(url)
    host = parsed.netloc.rsplit("@", 1)[-1]
    return urllib.parse.urlunsplit((parsed.scheme, host, parsed.path, "", ""))


def location_guide(workspace):
    workspace = Path(workspace).resolve()
    if not workspace.is_dir():
        die(f"workspace does not exist: {workspace}")
    guide = workspace / "RESEARCH_PATHS.md"
    papers_file = TEAM_HOME / "papers"
    registered = [line.strip() for line in rd(papers_file).splitlines()
                  if line.strip() and not line.lstrip().startswith("#")] if papers_file.is_file() else []
    projects = []
    local_remotes = set()
    for child in sorted(workspace.iterdir(), key=lambda p: p.name.casefold()):
        if not child.is_dir() or not (child / ".git").exists():
            continue
        result = git(child, "remote", "get-url", "origin", check=False)
        url = result.stdout.strip() if result.returncode == 0 else ""
        local_remotes.add(url)
        projects.append((child, url, url in registered))
    state_file = TEAM_HOME / "team.json"
    try:
        state = json.loads(rd(state_file)) if state_file.is_file() else {}
    except ValueError:
        state = {}
    hermes_home = state.get("HermesHome") or os.environ.get("HERMES_HOME") or "(see team.json)"
    install_dir = state.get("InstallDir") or "(see team.json)"
    admin_root = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))) / "HermesEasySetup" / "servers"
    lines = [LOCATION_MARKER, "# Research team: files and projects", "",
             "This guide is regenerated by the setup wizard and whenever the lead initializes a project.",
             "Ask `research-lead` where files are, or run `research_board.py locations --write` to refresh it.",
             "Paths below describe this PC; project remotes may be local Git repositories or hosted Git URLs.", "",
             "## Your research workspace", "",
             f"- Workspace: `{_location_text(workspace)}`",
             f"- This guide: `{_location_text(guide)}`",
             f"- New-paper template: `{_location_text(workspace / '_template')}`",
             f"- Shared public reports: `{_location_text(workspace / 'reports')}`",
             f"- Lead's temporary task prompts: `{_location_text(workspace / '.scratch')}`", "",
             "## Project repositories", "",
             "Each initialized paper or private report has its own Git repository. The local folder contains",
             "`.tasks/` (board), `.tasks/ledger.jsonl` (task record), and its research outputs.",
             "The remote is the task exchange; a local bare remote is not a GitHub repository.", "",
             "| Local folder | Registered for runners | Origin remote |", "| --- | --- | --- |"]
    for child, url, active in projects:
        lines.append(f"| `{_location_text(child)}` | {'yes' if active else 'no'} | `{_location_text(_public_remote(url or '(none)'))}` |")
    if not projects:
        lines.append("| (no initialized projects yet) | | |")
    missing = [url for url in registered if url not in local_remotes]
    if missing:
        lines += ["", "Registered remotes without a local folder in this workspace:"]
        lines += [f"- `{_location_text(_public_remote(url))}`" for url in missing]
    lines += ["", "## Team runtime and software", "",
              f"- Team runtime: `{_location_text(TEAM_HOME)}`",
              f"- Registered project remotes: `{_location_text(papers_file)}`",
              f"- Default local bare remotes: `{_location_text(TEAM_HOME / 'boards')}`",
              f"- Worker and lead-coordinator clones: `{_location_text(TEAM_HOME / 'work')}`",
              f"- Lead-coordinator cursor: `{_location_text(TEAM_HOME / 'run' / 'lead-coordinator.json')}`",
              f"- Capped lead-turn checkpoints: `{_location_text(TEAM_HOME / 'run' / 'lead-attempts')}`",
              f"- Detached experiment jobs: `{_location_text(JOBS)}`",
              f"- Service status: `{_location_text(TEAM_HOME / 'service-status.json')}`",
              f"- Service and runner logs: `{_location_text(TEAM_HOME / 'logs')}`",
              f"- Install test result: `{_location_text(TEAM_HOME / 'live-test.json')}`",
              f"- Team settings: `{_location_text(state_file)}`",
              f"- Installed agent code: `{_location_text(TEAM_HOME / 'team')}`",
              f"- Hermes profiles and sessions: `{_location_text(Path(hermes_home) / 'profiles') if hermes_home != '(see team.json)' else hermes_home}`",
              f"- Hermes source installation: `{_location_text(install_dir)}`",
              f"- Mattermost server deployments: `{_location_text(admin_root)}` (database and uploads live in Docker volumes)",
              "", "Private credentials are under the team runtime's `private/` and `gateway/env`,",
              "and in the lead profile's `.env`. Do not share those files or this PC's private papers.", ""]
    return guide, "\n".join(lines)


def cmd_locations(a):
    record = TEAM_HOME / "workspace-root.txt"
    workspace = a.workspace or (rd(record).strip() if record.is_file() else "")
    if not workspace and (TEAM_HOME / "team.json").is_file():
        try:
            workspace = json.loads(rd(TEAM_HOME / "team.json")).get("WizardOptions", {}).get("WorkspacePath", "")
        except (ValueError, AttributeError):
            pass
    if not workspace:
        die("workspace is unknown — pass --workspace or reinstall the research team")
    guide, content = location_guide(workspace)
    if a.write:
        if guide.exists() and not rd(guide).startswith(LOCATION_MARKER):
            die(f"refusing to overwrite an unmanaged file: {guide}")
        tmp = guide.with_name(guide.name + ".tmp")
        wr(tmp, content)
        os.replace(tmp, guide)
        print(f"Updated {guide}")
    else:
        print(content)


def cmd_init(a):
    """Make a folder a paper with a task board: a git repo whose remote is a bare repo under
    <team home>/boards/, registered in the papers file the runners read."""
    d = Path(a.folder).resolve()
    if not d.is_dir():
        die(f"no folder {d}")
    if not (d / "CLAUDE.md").is_file() and not a.force:
        die(f"{d} has no CLAUDE.md — scaffold it from _template/ first (or pass --force)")
    if not (d / ".git").exists():
        git(d, "init", "-q", "-b", "main")
    git_identity(d, "research-lead")
    gi = d / ".gitignore"
    have = rd(gi).splitlines() if gi.is_file() else []
    missing = [p for p in GITIGNORE if p not in have]
    if missing:
        wr(gi, "\n".join(have + missing) + "\n")
    if git(d, "rev-parse", "-q", "--verify", "HEAD", check=False).returncode:
        git(d, "add", "-A")
        git(d, "commit", "-q", "-m", "initial import for the research team")
    r = git(d, "remote", "get-url", "origin", check=False)
    if r.returncode == 0:
        url = r.stdout.strip()
        branch = git(d, "symbolic-ref", "--short", "HEAD").stdout.strip()
        upstream = git(d, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", check=False)
        if upstream.returncode != 0:
            remote = git(d, "ls-remote", "--heads", "origin", branch)
            if remote.stdout.strip():
                git(d, "fetch", "-q", "origin")
                remote_ref = f"origin/{branch}"
                if git(d, "merge-base", "--is-ancestor", remote_ref, "HEAD", check=False).returncode == 0:
                    git(d, "push", "-q", "-u", "origin", branch)
                elif git(d, "merge-base", "--is-ancestor", "HEAD", remote_ref, check=False).returncode == 0:
                    git(d, "branch", "--set-upstream-to", remote_ref, branch)
                else:
                    die(f"{d.name}: origin/{branch} has different history — clone that repo or choose an empty remote")
            else:
                git(d, "push", "-q", "-u", "origin", branch)
        print(f"{d.name}: using its existing remote {_public_remote(url)}")
    else:
        boards = Path(a.boards) if a.boards else TEAM_HOME / "boards"
        boards.mkdir(parents=True, exist_ok=True)
        bare = boards / f"{d.name}.git"
        if not bare.exists():
            sp.run(["git", "init", "-q", "--bare", str(bare)], check=True)
        url = str(bare)
        git(d, "remote", "add", "origin", url)
        branch = git(d, "symbolic-ref", "--short", "HEAD").stdout.strip()
        git(d, "push", "-q", "-u", "origin", branch)
        sp.run(["git", f"--git-dir={bare}", "symbolic-ref", "HEAD", f"refs/heads/{branch}"], check=True)
        print(f"{d.name}: task board at {url}")
    papers = Path(a.papers_file) if a.papers_file else TEAM_HOME / "papers"
    papers.parent.mkdir(parents=True, exist_ok=True)
    known = rd(papers).splitlines() if papers.is_file() else []
    if url not in known:
        wr(papers, url + "\n", append=True)
        print(f"registered in {papers}; runners started with --papers-file pick it up on their next pass")
    record = TEAM_HOME / "workspace-root.txt"
    if record.is_file() and d.parent == Path(rd(record).strip()).resolve():
        cmd_locations(argparse.Namespace(workspace=str(d.parent), write=True))


def cmd_project_create(a):
    """Scaffold, initialize, register and bind one project; safe to repeat after interruption."""
    name = a.name
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?", name):
        die("project name must be 1-64 lowercase letters, digits or internal hyphens")
    record = TEAM_HOME / "workspace-root.txt"
    workspace = Path(a.workspace or rd(record).strip()).resolve()
    if not workspace.is_dir() or not (workspace / "_template" / "CLAUDE.md").is_file():
        die("research workspace or _template is missing; run team setup first")
    target = workspace / name
    marker = target / TASKS / "project.json"
    if target.exists():
        if not marker.is_file():
            die(f"{target} exists but was not created by project-create")
        try:
            info = json.loads(rd(marker))
        except ValueError:
            die(f"{marker} is unreadable")
        if info.get("name") != name or info.get("schema") != 1:
            die(f"{marker} identifies a different project")
    else:
        staging = workspace / f".{name}.creating-{uuid.uuid4().hex}"
        try:
            shutil.copytree(workspace / "_template", staging)
            (staging / TASKS).mkdir()
            wr(staging / TASKS / "project.json", json.dumps({"schema": 1, "name": name,
                "created": now()}, ensure_ascii=False, indent=2) + "\n")
            os.replace(staging, target)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    if a.remote:
        parsed = urllib.parse.urlsplit(a.remote)
        if parsed.username or parsed.password:
            die("put Git credentials in a credential manager, not the remote URL")
        if not (target / ".git").exists():
            git(target, "init", "-q", "-b", "main")
        existing = git(target, "remote", "get-url", "origin", check=False)
        if existing.returncode == 0 and existing.stdout.strip() != a.remote:
            die(f"{name} already has a different origin; inspect it before retrying")
        if existing.returncode != 0:
            git(target, "remote", "add", "origin", a.remote)
    cmd_init(argparse.Namespace(folder=str(target), force=False, boards=None, papers_file=None))
    state_path = TEAM_HOME / "team.json"
    try:
        state = json.loads(rd(state_path)) if state_path.is_file() else {}
    except ValueError:
        state = {}
    channel = a.channel or state.get("HomeChannelID", "")
    human = state.get("WizardOptions", {}).get("HumanUsername", "")
    mention = a.mention if a.mention is not None else ("@" + human if human else "")
    if not channel:
        die(f"{name} was initialized; pass --channel to finish Mattermost binding")
    cmd_setup(argparse.Namespace(paper=str(target), channel=channel, mention=mention,
                                 profile="research-lead"))
    cmd_locations(argparse.Namespace(workspace=str(workspace), write=True))
    print(f"{name}: ready at {target}")


def cmd_new(a):
    repo = Path(a.paper)
    sync(repo)
    p = repo / TASKS / f"{a.id}.md"
    if p.exists():  # idempotent: re-running a skill step never duplicates a task
        print(f"{a.id}: exists, status {load(p)[0].get('status')}")
        return
    if a.assignee not in OUTPUTS:
        die(f"assignee must be one of {', '.join(OUTPUTS)}")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", a.id):
        die("task id must be 1-128 letters, digits, dots, underscores or hyphens")
    if not 1 <= a.max_attempts <= MAX_ATTEMPTS:
        die(f"max attempts must be between 1 and {MAX_ATTEMPTS}")
    if a.assignee == "research-reviewer" and not a.audit_of:
        die("review tasks require --audit-of and structured, version-bound review")
    if a.assignee == "research-reviewer":
        board = tasks(repo)
        targets = csv(a.audit_of)
        if any(t not in board or board[t][1].get('assignee') == 'research-reviewer' for t in targets):
            die('AuditTargetsInvalid: name existing producer tasks, not other reviews')
        for target in targets:
            producer = board[target][1]
            if producer.get('status') == 'done':
                for rel in csv(producer.get('expects')):
                    try:
                        audit_gate.safe_file(repo, rel)
                        if (git(repo, 'cat-file', '-e', 'HEAD:' + rel, check=False).returncode or
                                git(repo, 'diff', '--quiet', 'HEAD', '--', rel, check=False).returncode):
                            raise ValueError('artifact is not the committed producer version')
                    except (ValueError, OSError):
                        die('AuditInputsUnavailable: ' + target + ' expects ' + rel +
                            '. Use the corrected producer version with actually published evidence; '
                            'do not fabricate the missing file or approve the obsolete task.')
        if csv(a.expects) != [f'reviews/{a.id}/verdict.json']:
            die('AuditOutputInvalid: use reviews/<audit-task-id>/verdict.json')
        a.after = ','.join(dict.fromkeys(csv(a.after) + targets))
    if a.assignee != "research-reviewer" and a.audit_of:
        die("only research-reviewer can produce an audit")
    if not a.expects:
        die("every task needs --expects: concrete output files")
    for rel in csv(a.expects) + csv(a.deliver):
        rel = rel.partition(":")[0]
        if Path(rel).is_absolute() or ".." in Path(rel).parts or "\\" in rel or not any(rel == x or rel.startswith(x + "/") for x in OUTPUTS[a.assignee]):
            die("output path is outside role's publication permissions")
    for item in csv(a.deliver):
        path, _, kind = item.partition(":")
        if kind not in ("", "docx") or (kind == "docx" and not path.endswith(".md")):
            die(f"--deliver {item}: use <path> or <report.md>:docx")
    body = a.body if a.body is not None else (sys.stdin.read() if a.body_file == "-" else rd(a.body_file))
    meta = {"id": a.id, "assignee": a.assignee, "status": "ready", "after": a.after or "",
            "expects": a.expects or "", "skills": a.skills or "", "thread": a.thread or "",
            "ready_when": a.ready_when or "", "notify_done": a.notify_done or "", "gate": a.gate,
            "deliver": a.deliver or "", "audit_of": a.audit_of or "", "audit_scope": a.audit_scope,
            "resume_policy": a.resume_policy or ("manual" if any(x.startswith("experiments/") for x in csv(a.expects)) else "auto"),
            "max_attempts": str(a.max_attempts), "attempt": "0", "stop_reason": "",
            "updated": now()}
    save(p, meta, body.strip() + "\n")
    publish(repo, [p.relative_to(repo)], f"board: new task {a.id} -> {a.assignee}")
    activity.Journal(TEAM_HOME, activity_project(repo), a.id, 'research-lead').emit(
        '작업 배정', activity.LABELS[a.assignee] + ' 담당 · 결과: ' + a.expects, 'done')
    print(f"{a.id}: created for {a.assignee}" + (f", after {a.after}" if a.after else ""))


def cmd_list(a):
    repo = Path(a.paper)
    if not a.no_sync:
        sync(repo)
    board = tasks(repo)
    if not board:
        print("(no tasks)")
    for tid, (_, m, _) in board.items():
        st = m.get("status")
        w = waiting_on(m, board) if st == "ready" else []
        extra = f"  waiting on {', '.join(w)}" if w else ""
        if st == "ready" and not w and m.get("ready_when"):
            extra = f"  until {m['ready_when']} (checked on the worker's device)"
        who = f"  [{m['claimed_by']}]" if m.get("claimed_by") and st == "running" else ""
        base = f"  @{m['base'][:10]}" if m.get("base") and st in TERMINAL else ""
        print(f"{tid:28} {st:8} {m.get('assignee', ''):15} {m.get('updated', '')}{who}{base}{extra}")


def cmd_show(a):
    repo = Path(a.paper)
    sync(repo)
    p = repo / TASKS / f"{a.id}.md"
    print(rd(p) if p.exists() else f"{a.id}: no such task")


def cmd_wait(a):
    repo, t0 = Path(a.paper), time.time()
    while True:
        sync(repo)
        board = tasks(repo)
        st = {i: board[i][1].get("status") if i in board else "missing" for i in a.ids}
        if all(s in TERMINAL or s == "missing" for s in st.values()) or time.time() - t0 > a.timeout:
            for i, s in st.items():
                print(f"{i}: {s}")
            sys.exit(0 if all(s == "done" for s in st.values()) else 2)
        time.sleep(a.poll)


def cmd_edit(a):
    repo = Path(a.paper)
    sync(repo)
    p = repo / TASKS / f"{a.id}.md"
    if not p.exists():
        die(f"{a.id}: no such task")
    meta, body = load(p)
    if getattr(a, 'gate', None) is not None:
        meta['gate'] = a.gate
    if a.after is not None:
        meta["after"] = a.after
    if a.append:
        body = body.rstrip() + "\n\n" + a.append.strip() + "\n"
    if a.status:
        if a.status == "done":
            die("done can only be recorded by a role runner; a lead cannot manufacture completion")
        if a.status == "ready" and int(meta.get("attempt") or 0) >= int(meta.get("max_attempts") or MAX_ATTEMPTS):
            die("TaskAttemptLimit: saved history retained; a retry cannot reset its limit")
        meta["status"] = a.status
        if a.status == "ready":
            meta["claimed_by"] = ""
            meta["base"] = ""
            body = re.split(r"\n## Result — ", body)[0].rstrip() + "\n"  # retry starts clean
    meta["updated"] = now()
    save(p, meta, body)
    publish(repo, [p.relative_to(repo)], f"board: edit {a.id}")
    note = Notifier(repo, 'research-lead')
    note.journal(a.id).emit('계획·작업 변경', '상태 ' + meta.get('status', '') + ' · ' + (a.append or '')[:180],
                           'waiting' if meta.get('gate') == 'human' else 'info')
    if getattr(a, 'gate', None) == 'human' and a.append:
        note.post('사용자 확인 요청 · ' + a.id + ': ' + headline(a.append, 200), meta.get('thread', ''), ping=True)
    print(f"{a.id}: updated")


def cmd_ledger(a):
    repo = Path(a.paper)
    if not a.no_sync:
        sync(repo)
    lines = ledger_lines(repo)
    broken = ledger_check(lines)
    if a.verify:
        if broken is None:
            print(f"ledger intact: {len(lines)} entries")
            return
        die(f"ledger chain broken at line {broken + 1} of {len(lines)} — someone rewrote it; see git log -p {LEDGER}")
    for line in lines:
        e = json.loads(line)
        outs = ", ".join(f"{k} {v[:8]}" for k, v in sorted(e.get("outputs", {}).items())[:6])
        more = len(e.get("outputs", {})) - 6
        print(f"{e.get('finished', '')}  {e.get('task', ''):24} {e.get('status', ''):8} {e.get('role', ''):22}"
              f" @{e.get('base', '')[:10]}  {outs}{f' (+{more})' if more > 0 else ''}")
    if broken is not None:
        print(f"WARNING: chain broken at line {broken + 1}")


def cmd_deliver(a):
    """The lead's delivery of a finished file (e.g. an audited report) to a thread."""
    repo = Path(a.paper)
    sync(repo)
    if not audit_gate.delivery_allowed(repo, delivery_inputs(a.items)):
        die("FinalAuditRequired: final audit must pass for exactly the current file and evidence versions")
    if git(repo, "status", "--porcelain", "--", *delivery_inputs(a.items)).stdout.strip():
        die("deliver only what is committed and pushed — the file has local changes")
    base = git(repo, "rev-parse", "HEAD").stdout.strip()
    note = Notifier(repo, a.profile)
    failed = 0
    for name, data, mime, label in deliveries({"id": "delivery", "label": a.label}, repo, base, a.items):
        if data is None:
            print(f"not found: {label}"); failed += 1
            continue
        if len(data) > MAX_DELIVERY_BYTES:
            print(f"too large to attach: {name}"); failed += 1
            continue
        ok, detail = note.deliver(name, data, mime, a.thread, f"{label} (`{name}`, commit {base[:12]})")
        note.journal('delivery').emit('최종 파일 전달', '첨부 재다운로드 해시 일치' if ok else '전달 실패',
                                      'done' if ok else 'failed', detail=name)
        print(f"{name}: " + (f"delivered and verified, sha256 {detail}" if ok else f"NOT delivered — {detail}"))
        failed += not ok
    sys.exit(1 if failed else 0)


def cmd_setup(a):
    """Bind a paper to a Mattermost channel (id, or team/channel-name resolved via the API)."""
    repo = Path(a.paper)
    sync(repo)
    channel = a.channel
    if "/" in channel:
        creds = mm_creds(a.profile) or die("no MATTERMOST_URL/MATTERMOST_TOKEN for profile " + a.profile)
        team, name = channel.split("/", 1)
        channel = mm_api(creds, "GET", f"/teams/name/{team}/channels/name/{name}")["id"]
    conf = repo / TASKS / "board.conf"
    conf.parent.mkdir(exist_ok=True)
    wr(conf, f"mattermost_channel={channel}\n" + (f"mention={a.mention}\n" if a.mention else ""))
    publish(repo, [conf.relative_to(repo)], "board: mattermost channel")
    print(f"board.conf: channel {channel}" + (f", mention {a.mention}" if a.mention else ""))


def cmd_thread(a):
    """Start a round thread in the paper's channel; print its post id for `new --thread`."""
    repo = Path(a.paper)
    sync(repo)
    n = Notifier(repo, a.profile)
    if not n.channel:
        die("no .tasks/board.conf — run `setup` first")
    if not n.creds:
        die("no MATTERMOST_URL/MATTERMOST_TOKEN for profile " + a.profile)
    pid = n.post(f"#### {a.title}", a.root or "")
    if not pid:
        die("could not post to Mattermost (see error above)")
    print(a.root or pid)
    print(f"link: {n.creds[0]}/_redirect/pl/{pid}", file=sys.stderr)


def cmd_approve(a):
    """Record the user's approval of an experiment protocol (or an amendment to it)."""
    repo = Path(a.paper)
    sync(repo)
    d = repo / "experiments" / a.exp
    target = d / ("amendments.md" if a.amendment else "protocol.md")
    rel = target.relative_to(repo).as_posix()
    if not target.exists():
        die(f"{rel} does not exist")
    if git(repo, "status", "--porcelain", "--", rel).stdout.strip():
        die(f"{rel} has uncommitted changes — approve only what is on the remote")
    sha = git(repo, "log", "-1", "--format=%H", "--", rel).stdout.strip() or die(f"{rel} is not committed")
    blob = git(repo, "rev-parse", f"HEAD:{rel}").stdout.strip()
    what = f"amendment {a.amendment} in amendments.md" if a.amendment else "protocol.md"
    rec = d / "approval.md"
    head = "" if rec.exists() else f"# Approvals — {a.exp}\n\nWritten by research-lead only. The runner freezes protocol.md once this file exists.\n\n"
    wr(rec, f"{head}- {now()} — {what} approved by {a.by} (commit {sha[:12]}, blob {blob[:12]})"
       + (f" — {a.note}" if a.note else "") + "\n", append=True)
    publish(repo, [rec.relative_to(repo)], f"board: approve {a.exp} {what}")
    print(f"{a.exp}: {what} approved by {a.by}")


def cmd_publish(a):
    repo = Path(a.paper)
    for value in a.paths:
        rel = Path(value)
        if (rel.is_absolute() or '..' in rel.parts or not rel.parts or
                ':' in value or '\\' in value or '*' in value or '?' in value or
                (rel.parts[0] in ('.git', TASKS) and value != '.tasks/project.json')):
            die('PublishDenied: publish concrete project files, not runner-owned tasks, audit receipts or ledger')
    sync(repo)
    print("pushed" if publish(repo, a.paths, a.message) else "nothing to commit")


# ---------- worker ----------

def snapshot(clone):
    """Export HEAD without .git and .tasks/ — what a blind reviewer is allowed to see."""
    work = Path(tempfile.mkdtemp(prefix="research-task-"))
    tar = sp.run(["git", "-C", str(clone), "archive", "HEAD"], capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        t.extractall(work, filter="data") if hasattr(tarfile, "data_filter") else t.extractall(work)
    shutil.rmtree(work / TASKS, ignore_errors=True)
    return work


def exclude_locally(clone, name):
    excl = clone / ".git" / "info" / "exclude"
    excl.parent.mkdir(parents=True, exist_ok=True)
    if name not in (rd(excl).splitlines() if excl.exists() else []):
        wr(excl, f"\n{name}\n", append=True)


def run_agent(a, cmd, work, env, note, tid, role, thread):
    """One Hermes run, real tool activity to the web board, unchanged task deadline."""
    journal = note.journal(tid)
    journal.emit('역할 실행', '시작; 감사 통과·최종 완료 판정과 별개', 'running')
    proc = popen_group(activity.stream_command(cmd), cwd=work, env=env, stdout=sp.PIPE, stderr=sp.PIPE,
                       encoding="utf-8", errors="replace")
    out, err, code = activity.capture(proc, journal, a.task_timeout, kill_tree, a.heartbeat)
    if code == 124: err += f'\ntimed out after {a.task_timeout}s'
    return out, err, code


def delivery_inputs(items):
    names=[]
    for item in items:
        rel, _, kind=item.partition(':')
        names.append(rel)
        if kind=='docx':names.append(Path(rel).with_suffix('.docx').as_posix())
    return list(dict.fromkeys(names))


def deliveries(meta, src, base, items=None):
    """(name, bytes, mime, label) for each `deliver` entry that exists in src."""
    out = []
    for item in (items if items is not None else csv(meta.get("deliver"))):
        rel, _, kind = item.partition(":")
        f = src / rel
        if not f.is_file():
            out.append((rel, None, None, f"`{rel}` was not produced"))
            continue
        if kind == "docx":
            sys.path.insert(0, str(HERE))
            import report_docx
            prepared=f.with_suffix('.docx')
            if not prepared.is_file():
                out.append((prepared.name,None,None,'Prepare and audit the Word file before delivery: '+str(prepared)))
                continue
            data = prepared.read_bytes()  # exact audited bytes, never a post-audit conversion
            out.append((Path(rel).stem + ".docx", data, report_docx.MIME, meta.get("label") or f"**{meta['id']}** — `{rel}` as Word"))
        else:
            mime = {"pdf": "application/pdf", "md": "text/markdown", "json": "application/json",
                    "html": "text/html", "svg": "image/svg+xml", "png": "image/png",
                    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}.get(
                f.suffix.lstrip(".").lower(), "application/octet-stream")
            data = f.read_bytes()
            out.append((f.name, data, mime, meta.get("label") or f"**{meta['id']}** — `{rel}`"))
    return out


def execute(a, clone, p, me):
    meta, body = load(p)
    tid, role = meta["id"], a.role
    profile = a.profile or role
    thread = meta.get("thread", "")
    note = Notifier(clone, profile)
    base = git(clone, "rev-parse", "HEAD").stdout.strip()
    work = snapshot(clone) if role in BLIND else clone
    assignment = None
    if role == "research-reviewer":
        shutil.rmtree(work / "reviews", ignore_errors=True)
        board = tasks(clone)
        targets = csv(meta.get("audit_of"))
        if not targets or any(t not in board or board[t][1].get("status") != "done" for t in targets):
            raise RuntimeError("AuditTargetsNotReady")
        inputs = set()
        for t in targets:
            inputs.update(csv(board[t][1].get("expects")))
        # Include original sources and task acceptance criteria, not authorship/history.
        for prefix in ("notes", "sources", "evidence", "experiments", "reports", "paper"):
            inputs.update(p.relative_to(work).as_posix() for p in (work / prefix).rglob("*") if p.is_file())
        for name in ("CLAUDE.md", "REQUEST.md", "ACCEPTANCE.md", "claims.md", "outline.md"):
            if (work / name).is_file():
                inputs.add(name)
        assignment = audit_gate.contract(work, targets, meta.get("audit_scope", "intermediate"), inputs)
        assignment["target_versions"] = {t: audit_gate.digest(clone / TASKS / (t + ".md")) for t in targets}
        phase = ("This is a PRE-RELEASE final content and file-format audit, not a claim of whole-request completion. "
                 "All requested local final files (including prepared Word when requested) must exist and be checked. "
                 "Verify exact content, source versions, tables/figures and required limits. "
                 "External upload, download-hash verification and recipient access occur AFTER this audit passes, "
                 "and are enforced separately by the delivery/installation code. Do not require already-posted "
                 "attachments to grant pre-release approval; do not claim transport verified from this snapshot. "
                 if assignment['scope']=='final' else
                 "This is an intermediate preparation/content audit, not the final-delivery acceptance stage. ")
        # Audit task identifiers and prior author's narrative are not in the reviewer prompt.
        body = (phase + "Independently audit the enclosed outputs against REQUEST.md / ACCEPTANCE.md and source evidence. "
                "Do not change inputs. Write reviews/" + tid + "/verdict.json with exactly verdict, checks, findings, notes. "
                "verdict is pass/reject/unverifiable. checks has requirements,sources,methods,consistency,uncertainty; "
                "each has status (pass/reject/unverifiable/not_applicable) and evidence (location and justification). "
                "findings is an array of {location,evidence,correction,blocking:boolean}. "
                "Optional style/novelty improvements must not block unless explicitly requested. "
                "Missing decisive evidence means unverifiable, never fabricated pass. End STATUS: done when the audit is recorded, even if rejected.\n"
                + json.dumps({"scope": assignment["scope"], "phase": assignment['phase'], "files": assignment["files"]}, ensure_ascii=False))
    if TEAM_CONTEXT.exists():
        shutil.copy2(TEAM_CONTEXT, work / ".hermes.md")  # outranks the paper's CLAUDE.md
        if work == clone:
            exclude_locally(clone, ".hermes.md")
    env, sens, gw = child_env(clone, profile)
    prior = ""
    attempt_num = int(meta.get("attempt") or 1)
    if attempt_num > 1 and role != "research-reviewer":
        previous = clone / TASKS / "attempts" / tid / f"{attempt_num - 1}.json"
        if previous.is_file():
            record = json.loads(rd(previous))
            prior = ("\nPrevious attempt stopped before completion. Continue from the files already "
                     "present; do not redo finished work. Its checkpoint follows:\n"
                     + str(record.get("report", ""))[-2500:] + "\n")
    prompt = body.strip() + prior + "\n" + SENSITIVE_NOTE.get(sens, "") + FOOTER.format(id=tid, role=role, cwd=work)
    # The prompt goes in a file outside the paper: no command-line length or quoting limits.
    qdir = TEAM_HOME / "run" / "prompts"
    qdir.mkdir(parents=True, exist_ok=True)
    qfile = qdir / f"{Path(clone).name}-{tid}-{os.getpid()}.md"
    wr(qfile, prompt)
    cmd = [a.hermes, "-p", profile, "chat", "-Q", "--query-file", str(qfile),
           "--max-turns", str(TEAM_MAX_TURNS)]
    for s in dict.fromkeys(ROLE_SKILLS.get(role, []) + csv(meta.get("skills"))):
        cmd += ["-s", s]
    if a.yolo:
        cmd.append("--yolo")
    print(f"[{now()}] {tid}: running in {work} at {base[:12]}" + (f" (gateway: {sens})" if gw else ""), flush=True)
    t0 = time.time()

    refusal = None
    drift = profile_drift(profile)
    if drift:
        refusal = f"profile {profile} differs from the install: {', '.join(drift[:5])} — reinstall the team to restore it"
    elif sens in SENSITIVE_NOTE:
        # Never run a non-public paper on a model we cannot vouch for.
        refusal = gateway_probe(env, profile) if gw else (
            f"this paper is {sens}, and without the model gateway every model is a cloud one — "
            "set up the gateway with local models, or mark the paper public")
    if refusal:
        print(f"[{now()}] {tid}: not run — {refusal}", flush=True)
        out, err, code = f"Not run.\nSTATUS: blocked — {refusal}", "", 0
    else:
        for retry_index in range(len(RETRY_DELAYS) + 1):
            remaining = a.task_timeout - (time.time() - t0)
            if remaining <= 0:
                out, err, code = "", "task deadline exceeded", 124
                break
            original_timeout = a.task_timeout
            a.task_timeout = remaining
            out, err, code = run_agent(a, cmd, work, env, note, tid, role, thread)
            a.task_timeout = original_timeout
            said = re.search(r"^\W*STATUS:\s*(done|blocked)\b", out, re.M | re.I)
            if code in (0, 124) or said or retry_index == len(RETRY_DELAYS) or not TRANSIENT.search((err or "")[-4000:] + out[-2000:]):
                break
            wait = min(RETRY_DELAYS[retry_index], max(0, a.task_timeout - (time.time() - t0)))
            note.progress(tid, f"{tid}: 일시적 모델 연결 오류(종료 코드 {code}). {wait}초 후 재시도"
                          f" ({retry_index + 1}/{len(RETRY_DELAYS)}), 저장 자료 유지", thread)
            print(f"[{now()}] {tid}: transient failure (exit {code}); retry in {wait}s", flush=True)
            time.sleep(wait)
            # Preserve completed source reads and drafts across transport retries.

    qfile.unlink(missing_ok=True)
    touched = guard_frozen(clone) if work == clone else []
    if work == clone:
        # Workers publish outputs only; board state is written by this process afterwards.
        changed_board = git(clone, "status", "--porcelain", "--", TASKS).stdout.strip()
        if changed_board:
            touched.append("task board (runner-owned): " + changed_board.replace('\n', '; ')[:500])
            git(clone, "restore", "--source=HEAD", "--staged", "--worktree", "--", TASKS)
            git(clone, "clean", "-fdq", "--", TASKS)
        git(clone, "reset", "-q")  # discard agent staging; role allowlist stages afresh

    marks = re.findall(r"^\W*STATUS:\s*(done|blocked)\b\W*(.*)$", out, re.M | re.I)
    said, reason = (marks[-1][0].lower(), marks[-1][1].strip()) if marks else (None, "")
    missing = [e for e in csv(meta.get("expects")) if not (work / e).is_file()]
    limit_hit = code == 124 or bool(ITERATION_LIMIT.search((out or "")[-4000:] + (err or "")[-4000:]))
    if limit_hit:
        status = "partial"
        reason = "task time limit" if code == 124 else "Hermes turn limit"
        if missing:
            reason += f"; still missing {', '.join(missing)}"
    elif code == 0 and said == "done" and not missing:
        status = "done"
    elif said == "blocked":
        status = "blocked"
    else:
        status = "failed"
        reason = f"exit {code}" + (f"; missing {', '.join(missing)}" if missing else "") + ("" if said else "; no STATUS line")
    if touched:
        status = "failed"
        reason = f"edited frozen file(s) {', '.join(touched)} — restored; amendments go in amendments.md"

    receipt_rel = None
    if assignment and status == "done":
        try:
            verdict = json.loads(rd(work / "reviews" / tid / "verdict.json"))
            receipt = audit_gate.validate(work, assignment, verdict)
            receipt_rel = f"{TASKS}/audits/{tid}-{attempt_num}.json"
            (clone / receipt_rel).parent.mkdir(parents=True, exist_ok=True)
            wr(clone / receipt_rel, json.dumps(receipt, ensure_ascii=False, indent=2))
        except (ValueError, OSError, KeyError) as e:
            status, reason = "failed", "AuditInvalid: " + str(e)

    if role in BLIND:  # bring the outputs back from the snapshot
        for rel in OUTPUTS[role]:
            src = work / rel
            if src.is_dir():
                shutil.copytree(src, clone / rel, dirs_exist_ok=True)
            elif src.is_file():
                shutil.copy2(src, clone / rel)

    # Build noise stays excluded, but a named test log is a requested artifact.
    # Without this override a task could say done while its expected evidence
    # never reached the shared repo. Never force-add unrequested process logs.
    for rel in csv(meta.get("expects")):
        if (Path(rel).suffix.lower() == '.log' and
                any(rel.startswith(root + '/') for root in OUTPUTS[role]) and
                (clone / rel).is_file()):
            audit_gate.safe_file(clone, rel)
            git(clone, 'add', '-f', '--', rel)

    report = out.strip()[-20000:] or "(no output)"
    if status in ("failed", "partial") and err.strip():
        report += "\n\nstderr (tail):\n" + err.strip()[-3000:]
    body = (body.rstrip() + f"\n\n## Result — {status} ({me}, {now()}, at commit {base[:12]})\n\n"
            + (f"**{reason}**\n\n" if reason else "") + report + "\n")
    meta.update(status=status, stop_reason=reason if status == "partial" else "", base=base, updated=now())
    save(p, meta, body)
    rel_task = p.relative_to(clone).as_posix()
    attempt_file = clone / TASKS / "attempts" / tid / f"{attempt_num}.json"
    attempt_file.parent.mkdir(parents=True, exist_ok=True)
    wr(attempt_file, json.dumps({"schema": 1, "task": tid, "attempt": attempt_num, "status": status,
        "reason": reason, "base": base, "finished": now(), "report": report[-4000:]},
        ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    rel_attempt = attempt_file.relative_to(clone).as_posix()
    staged = stage(clone, OUTPUTS[role] + [rel_task, rel_attempt] + ([receipt_rel] if receipt_rel else []), excludes=BUILD_JUNK)
    outputs = {f: sha256_file(clone / f) for f in staged if f not in (rel_task, rel_attempt) and (clone / f).is_file()}
    broken = ledger_append(clone, {"task": tid, "role": role, "worker": me, "status": status, "base": base,
                                   "attempt": attempt_num, "stop_reason": meta["stop_reason"],
                                   "started": dt.datetime.fromtimestamp(t0, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                   "finished": now(), "sensitivity": sens, "outputs": outputs})
    stage(clone, [LEDGER])
    commit_push(clone, f"{role}: {tid} {status}")
    note.journal(tid).emit('감사 결과 저장' if assignment else '작업 결과 저장',
                           (str(receipt.get('verdict')) if assignment and receipt_rel else status) +
                           ' · 파일 ' + str(len(outputs)) + '개 · ' + reason,
                           'done' if status == 'done' else 'waiting' if status in ('blocked', 'partial') else 'failed')
    print(f"[{now()}] {tid}: {status} {reason}", flush=True)
    if broken is not None:
        note.post(f":warning: **{Path(clone).name}**: the task ledger was rewritten before line {broken + 1}; "
                  f"recorded the break and continued. Check `git log -p {LEDGER}`.", thread, ping=True)

    took = fmt_age(time.time() - t0)
    auto_resume = (status == "partial" and meta.get("resume_policy") == "auto"
                   and attempt_num < int(meta.get("max_attempts") or 1))
    metas = [e for e in csv(meta.get("expects")) if e.endswith("meta.md")]
    if status == "done" and metas:
        note.progress(tid, f"{tid}: 작업 완료·판단 지점 (검토 버전 {base[:12]}). "
                      f"{checkpoint(clone / metas[0])}", thread)
        note.post(f"Read `{metas[0]}` and tell research-lead your decision.", thread, ping=True)
    elif status == "done" and meta.get("gate") == "human":
        note.progress(tid, f"{tid}: 작업 완료 · 소요 {took} · {headline(out)}", thread)
        note.post(meta.get("notify_done") or
                  f"**{tid}** is ready for your decision. Ask research-lead to review the result.",
                  thread, ping=True)
    elif status == "done" and meta.get("notify_done"):
        note.progress(tid, f"{tid}: 작업 완료 · 소요 {took} · {headline(out)}", thread)
        note.post(meta['notify_done'], thread, ping=True)
    elif status == "done":
        note.progress(tid, f"{tid}: 작업 완료 · 소요 {took} · {headline(out)}", thread)
    else:
        label = {'blocked': '후속 판단 필요', 'partial': '부분 완료', 'failed': '실패'}.get(status, status)
        note.progress(tid, f"{tid}: {label} · 소요 {took} · {reason or headline(out)}", thread)
        if not auto_resume:
            note.post(f"**{tid}** needs a decision. Research-lead will review the board entry.", thread, ping=True)

    if status == "done":
        delivery_items = csv(meta.get("deliver"))
        can_deliver = audit_gate.delivery_allowed(clone, delivery_inputs(delivery_items))
        if delivery_items and not can_deliver:
            note.post("FinalAuditRequired: output is saved; lead must obtain final approval before delivery.", thread)
        for name, data, mime, label in (deliveries(meta, clone, base) if can_deliver else []):
            if data is None:
                note.post(f":warning: {label} — nothing to deliver", thread)
            elif len(data) > MAX_DELIVERY_BYTES:
                note.post(f":warning: {label} is {len(data) // 1048576} MB — too large to attach; it is in the repo", thread)
            else:
                ok, detail = note.deliver(name, data, mime, thread, label)
                if not ok:
                    note.post(f":warning: {label} could not be delivered: {detail}. The file is in the repo.", thread, ping=True)
    if role in BLIND:
        shutil.rmtree(work, ignore_errors=True)
    if auto_resume:
        meta.update(status="ready", claimed_by="", base="", updated=now())
        original = re.split(r"\n## Result — ", body)[0].rstrip() + "\n"
        save(p, meta, original)
        publish(clone, [rel_task], f"board: continue {tid} attempt {attempt_num + 1}")


def claim(clone, p, me):
    meta, body = load(p)
    if int(meta.get("attempt") or 0) >= int(meta.get("max_attempts") or MAX_ATTEMPTS):
        meta.update(status="blocked", stop_reason="TaskAttemptLimit", updated=now())
        save(p, meta, body)
        publish(clone, [p.relative_to(clone)], "board: attempt limit " + meta["id"])
        Notifier(clone, a_profile if (a_profile := meta.get("assignee")) else "research-lead").post(
            "TaskAttemptLimit: " + meta["id"] + " — saved outputs and attempts retained.", meta.get("thread",""))
        return False
    meta.update(status="running", claimed_by=me, attempt=str(int(meta.get("attempt") or 0) + 1), updated=now())
    save(p, meta, body)
    try:
        git(clone, "add", p.relative_to(clone).as_posix())
        git(clone, "commit", "-q", "-m", f"board: claim {meta['id']}")
        if git(clone, "push", "-q", check=False).returncode == 0:
            return True
    except RuntimeError:
        pass
    reset_to_remote(clone, discard_claim=True)  # only an unsuccessful claim may be discarded
    return False


def remotes(a):
    urls = list(a.remotes)
    if a.papers_file and Path(a.papers_file).is_file():
        urls += [l.strip() for l in rd(a.papers_file).splitlines() if l.strip() and not l.startswith("#")]
    return list(dict.fromkeys(urls))


def lead_skill_for(task):
    if task.startswith("rep-"):
        return "research-report"
    if re.match(r"^x[0-9]+-", task):
        return "research-experiment"
    if re.match(r"^r[0-9]+-", task):
        return "research-round"
    if re.match(r"^s[0-9]+-", task):
        return "research-start"
    return None


def coordinate_event(a, clone, event):
    """Give the lead one private, bounded board event; never use Mattermost as a queue."""
    task = str(event.get("task", ""))
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task):
        raise RuntimeError("invalid task id in ledger")
    status = str(event.get("status", ""))
    if status not in TERMINAL:
        return True
    env, sens, gw = child_env(clone, "research-lead")
    if profile_drift("research-lead"):
        raise RuntimeError("Lead persona/skills differ from installed manifest")
    if sens in SENSITIVE_NOTE:
        refusal = gateway_probe(env, "research-lead") if gw else "no local model gateway for a non-public paper"
        if refusal:
            raise RuntimeError(refusal)
    event_id = hashlib.sha256(json.dumps(event, sort_keys=True).encode()).hexdigest()[:16]
    prompt_dir = TEAM_HOME / "run" / "prompts"
    prompt_dir.mkdir(parents=True, exist_ok=True)
    query = prompt_dir / f"lead-{clone.name}-{event_id}.md"
    event_description = (f"Scheduler diagnostic for task `{task}`; actual observed status is "
                         f"`{event.get('observed_status')}`, not a new agent result. " if event.get('diagnostic') else
                         f"Task `{task}` ended with `{status}`. ")
    prompt = (f"Internal research-board event for project `{clone.name}` at `{clone}`.\n"
              + event_description + "Read its task file and the project board using "
              "the installed research_board.py commands. Check current state before taking action: "
              "a dependent task may already be running. Continue the project plan if the next "
              "step is authorized; otherwise record the decision needed and wait for the human. "
              "Do not treat this event as new human approval, but the original user's requested "
              "research, local verification and final-file delivery remain authorized. Do not "
              "send agent-to-agent messages or arbitrary Mattermost posts. After a current final "
              "audit pass, use the installed board deliver command for the requested files in "
              "the existing thread; it enforces version approval and download-hash verification. "
              "Do not stop solely because optional docx/lxml helpers are absent: the built-in "
              "Word converter uses the standard library, and read-only verification can use a "
              "saved script. No new approval is needed for those local steps. Do not run git "
              "directly. Use stable task IDs so repeating "
              "this event cannot duplicate work. Give a short summary of what you changed.\n"
              f"Event: {json.dumps(event, ensure_ascii=False, sort_keys=True)}\n"
              + SENSITIVE_NOTE.get(sens, ""))
    wr(query, prompt)
    cmd = [a.hermes, "-p", "research-lead", "chat", "-Q", "--query-file", str(query),
           "--max-turns", str(TEAM_MAX_TURNS)]
    cmd += ["-s", "research-orchestrate"]
    skill = lead_skill_for(task)
    if skill:
        cmd += ["-s", skill]
    def partial(reason, out, err):
        checkpoint = TEAM_HOME / "run" / "lead-attempts" / f"{clone.name}-{event_id}.json"
        checkpoint.parent.mkdir(parents=True, exist_ok=True)
        wr(checkpoint, json.dumps({"schema": 1, "task": task, "event": event_id,
            "reason": reason, "finished": now(), "report": (out or "")[-4000:],
            "stderr": (err or "")[-2000:]}, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
        raise LeadTurnPartial(f"{reason}; saved {checkpoint}")
    try:
        journal = activity.Journal(TEAM_HOME, activity_project(clone), task, 'research-lead')
        journal.emit('후속 계획 판단', '작업 결과·감사·실패 원인을 읽고 다음 조치를 결정', 'running')
        proc = popen_group(activity.stream_command(cmd), cwd=clone, env=env, stdout=sp.PIPE, stderr=sp.PIPE,
                           encoding="utf-8", errors="replace")
        out, err, exit_code = activity.capture(proc, journal, a.task_timeout, kill_tree)
        if exit_code == 124:
            partial(f"lead event timed out after {a.task_timeout}s", out, err)
        if ITERATION_LIMIT.search((out or "")[-4000:] + (err or "")[-4000:]):
            partial("lead reached its Hermes turn limit", out, err)
        if proc.returncode:
            raise RuntimeError(f"lead event {event_id} exited {proc.returncode}: {(err or out)[-1000:]}")
        current = tasks(clone).get(task)
        thread = current[1].get("thread", "") if current else ""
        journal.emit('후속 계획 판단', headline(out, 220), 'done')
        if status in ('blocked', 'failed'):
            Notifier(clone, 'research-lead').post(
                f'계획 조정 · {task}: {headline(out, 180)}', thread)
        print(f"[{now()}] lead handled {clone.name}/{task}/{status}: {headline(out)}", flush=True)
        return True
    finally:
        query.unlink(missing_ok=True)


def coordinate_with_retry(a, clone, event, errors, error_path):
    """Persistent, bounded transport retry. Never repeat auth failures every poll."""
    key = hashlib.sha256((str(clone) + json.dumps(event, sort_keys=True)).encode()).hexdigest()
    previous = errors.get(key, {})
    if previous.get('paused') or time.time() < previous.get('next_try', 0):
        return False
    try:
        coordinate_event(a, clone, event)
    except LeadTurnPartial:
        raise
    except (RuntimeError, OSError, ValueError) as exc:
        count = previous.get('failures', 0) + 1
        reason = str(exc)[-1000:]
        transient = bool(TRANSIENT.search(reason))
        retry = transient and count <= len(RETRY_DELAYS)
        delay = RETRY_DELAYS[count - 1] if retry else 0
        errors[key] = {'task': event.get('task'), 'failures': count, 'paused': not retry,
                       'next_try': time.time() + delay, 'reason': reason, 'updated': now()}
        write_state(error_path, errors)
        task = tasks(clone).get(event.get('task'))
        thread = task[1].get('thread', '') if task else ''
        next_action = (f'{delay}초 후 저장된 보드를 확인해 재시도 ({count}/{len(RETRY_DELAYS)})'
                       if retry else '원인 해결 후 coordinate --retry-paused로 명시적으로 재개')
        Notifier(clone, 'research-lead').post(
            f"총괄 후속 판단 오류 · {event.get('task')}\n원인: {reason}\n다음 조치: {next_action}\n"
            f"문서·기록: {clone / TASKS}\n오류 기록: {error_path}", thread, ping=not retry)
        return False
    if key in errors:
        del errors[key]
        write_state(error_path, errors)
    return True


def cmd_coordinate(a):
    """Consume each new ledger result once, using project state rather than chat mentions."""
    a.hermes = a.hermes or os.environ.get("RESEARCH_TEAM_HERMES") or shutil.which("hermes")
    if not a.hermes:
        die("hermes not found — pass --hermes")
    a.papers_file = a.papers_file or str(TEAM_HOME / "papers")
    root = TEAM_HOME / "work" / "lead-coordinator"
    root.mkdir(parents=True, exist_ok=True)
    state_path = TEAM_HOME / "run" / "lead-coordinator.json"
    error_path = TEAM_HOME / "run" / "lead-coordinator-errors.json"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        state = json.loads(rd(state_path)) if state_path.is_file() else {}
        errors = json.loads(rd(error_path)) if error_path.is_file() else {}
        if getattr(a, 'retry_paused', False):
            errors = {k: v for k, v in errors.items() if not v.get('paused')}
            write_state(error_path, errors)
    except ValueError:
        die(f"{state_path} is unreadable; restore it rather than replaying events blindly")
    a.remotes = []
    while True:
        for url in remotes(a):
            key = hashlib.sha256(url.encode()).hexdigest()
            clone = clone_path(root, url)
            try:
                if not clone.exists():
                    git(root, "clone", "-q", "-c", "core.autocrlf=false", url, str(clone))
                    git_identity(clone, "research-lead")
                else:
                    sync(clone)
                lines = ledger_lines(clone)
                if ledger_check(lines) is not None:
                    raise RuntimeError("ledger hash chain is broken; lead event processing paused")
                if key not in state:
                    # Existing unmanaged projects have historical entries. A project made by
                    # project-create is new and must process its first event even if it arrived
                    # before this coordinator's first scan.
                    state[key] = 0 if (clone / TASKS / "project.json").is_file() else len(lines)
                    write_state(state_path, state)
                while state[key] < len(lines):
                    event = json.loads(lines[state[key]])
                    if event.get("status") in TERMINAL:
                        task_file = clone / TASKS / f"{event.get('task', '')}.md"
                        meta = load(task_file)[0] if task_file.is_file() else {}
                        continuing = (event.get("status") == "partial" and meta.get("resume_policy") == "auto"
                                      and int(event.get("attempt") or 1) < int(meta.get("max_attempts") or 1))
                        human_gate = meta.get('status') in ('done', 'blocked') and meta.get('gate') == 'human'
                        experiment_pause = (event.get("status") == "partial" and
                                            meta.get("resume_policy") == "manual")
                        if not (continuing or human_gate or experiment_pause):
                            try:
                                if not coordinate_with_retry(a, clone, event, errors, error_path):
                                    break
                            except LeadTurnPartial as e:
                                print(f"[{now()}] lead coordinator {clone.name}: {e}", file=sys.stderr, flush=True)
                                Notifier(clone, "research-lead").post(
                                    f"Background lead work after **{event['task']}** paused at its limit. "
                                    "Its partial result is saved in the team runtime. Ask research-lead to "
                                    "review the board and continue this project.", meta.get("thread", ""), ping=True)
                    state[key] += 1
                    write_state(state_path, state)
                    sync(clone)
                    lines = ledger_lines(clone)
                diagnostic = blocked_plan_event(clone)
                if diagnostic:
                    fingerprint = hashlib.sha256(json.dumps(diagnostic, sort_keys=True).encode()).hexdigest()
                    watch_key = 'plan:' + key
                    seen_key = 'plan-seen:' + key
                    seen = state.get(seen_key, {})
                    if seen.get('fingerprint') != fingerprint:
                        state[seen_key] = {'fingerprint': fingerprint, 'since': time.time()}
                        write_state(state_path, state)
                    elif (state.get(watch_key) != fingerprint and
                          time.time() - seen.get('since', time.time()) >= max(60, 2 * a.interval)):
                        if coordinate_with_retry(a, clone, diagnostic, errors, error_path):
                            state[watch_key] = fingerprint
                            write_state(state_path, state)
            except (RuntimeError, OSError, ValueError) as e:
                print(f"[{now()}] lead coordinator {repo_name(url)}: {e}", file=sys.stderr, flush=True)
        if a.once:
            return
        time.sleep(a.interval)


def blocked_plan_event(clone):
    """Diagnose an unrunnable plan, without inventing a ledger result or approval.

    Result events alone cannot wake the lead when its newly-created dependencies
    make all remaining tasks unrunnable. Respect running work and human gates;
    the lead must inspect the board and repair the plan, never waive an audit.
    """
    board = tasks(clone)
    if any(m.get('status') == 'running' or
           (m.get('status') in ('done', 'blocked') and m.get('gate') == 'human') for _, m, _ in board.values()):
        return None
    ready = {tid: m for tid, (_, m, _) in board.items() if m.get('status') == 'ready'}
    if not ready or any(not waiting_on(m, board) for m in ready.values()):
        return None
    waiting = {tid: waiting_on(m, board) for tid, m in sorted(ready.items())}
    return {'task': sorted(ready)[0], 'status': 'blocked', 'observed_status': 'ready',
            'diagnostic': 'UnrunnableDependencyPlan', 'waiting': waiting,
            'instruction': 'This is a scheduler observation, not a completed or failed agent run. '
            'Read current state. Repair work may read its own unapproved saved outputs; do not '
            'make a correction depend on an unaudited producer or rejected audit. Keep actual '
            'analysis/delivery gates and installed budgets. Ask only for genuinely missing authority.'}


def write_state(path, state):
    tmp = path.with_name(path.name + ".tmp")
    wr(tmp, json.dumps(state, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(tmp, path)


def record_runner_error(clone, p, me, error):
    """Return a claimed task's preparation/runtime error to the lead, not a ghost run.

    Never replace a finished local result or discard unpublished commits: those
    need publication recovery instead of a fabricated new failure.
    """
    meta, body = load(p)
    if meta.get('status') != 'running' or git(clone, 'log', '--format=%H', '@{u}..HEAD').stdout.strip():
        return False
    reason = 'RunnerError: ' + str(error)[:1600]
    stamp=now();tid=meta['id'];role=meta['assignee']
    meta.update(status='failed',stop_reason=reason,updated=stamp)
    save(p,meta,body.rstrip()+'\n\n## Runner failure — '+stamp+'\n\n'+reason+
         '\nNo audit approval was issued. Inspect actual saved files and correct the assignment.\n')
    attempt=clone/TASKS/'attempts'/tid/(str(meta.get('attempt') or 1)+'.json')
    attempt.parent.mkdir(parents=True,exist_ok=True)
    wr(attempt,json.dumps({'schema':1,'task':tid,'attempt':int(meta.get('attempt') or 1),
        'status':'failed','reason':reason,'finished':stamp,'origin':'runner'},ensure_ascii=False,sort_keys=True)+'\n')
    partial=stage(clone,OUTPUTS[role],excludes=BUILD_JUNK)
    outputs={rel:sha256_file(clone/rel) for rel in partial if (clone/rel).is_file()}
    ledger_append(clone,{'task':tid,'role':role,'worker':me,'status':'failed','attempt':int(meta.get('attempt') or 1),
        'stop_reason':reason,'base':git(clone,'rev-parse','HEAD').stdout.strip(),
        'started':stamp,'finished':stamp,'outputs':outputs,'origin':'runner'})
    publish(clone,[p.relative_to(clone).as_posix(),attempt.relative_to(clone).as_posix(),LEDGER],
            role+': '+tid+' runner failure')
    Notifier(clone,role).post('**'+tid+' — 실행 준비/처리 실패**\n'+reason+
                            '\n기록을 보존했으며 총괄이 배정·입력을 다시 확인합니다.',meta.get('thread',''))
    print('['+stamp+'] '+tid+': failed '+reason,flush=True)
    return True


def recover_interrupted_claims(clone, role, me):
    """Checkpoint our old process's claim BEFORE a fetch/reset can erase its draft.

    Called only by a newly-started, single-slot runner, not by the lead. A saved
    file is partial work, never a completed task or an audit approval. Unknown
    edits, changed remote claims and unpublished commits require recovery instead
    of silently discarding or attributing them to this attempt.
    """
    owned = [(p, m, b) for p, m, b in tasks(clone).values()
             if m.get('status') == 'running' and m.get('claimed_by') == me
             and m.get('assignee') == role]
    dirty = set()
    for args in (('diff', '--name-only', '-z'), ('diff', '--cached', '--name-only', '-z'),
                 ('ls-files', '--others', '--exclude-standard', '-z')):
        dirty.update(x for x in git(clone, *args).stdout.split('\0') if x)
    if not owned:
        if dirty:
            raise RuntimeError('unclaimed local changes preserved; inspect before resetting')
        return 0
    if len(owned) != 1 or git(clone, 'log', '--format=%H', '@{u}..HEAD').stdout.strip():
        raise RuntimeError('ambiguous or unpublished interrupted work preserved')
    allowed = lambda rel: any(rel == x or rel.startswith(x + '/') for x in OUTPUTS[role])
    if any(not allowed(rel) for rel in dirty):
        raise RuntimeError('interrupted edits outside role outputs preserved; inspect before resetting')
    for rel in dirty:
        frozen = re.fullmatch(r'experiments/([^/]+)/(approval\.md|protocol\.md)', rel)
        if frozen and (frozen.group(2) == 'approval.md' or git(clone, 'cat-file', '-e',
                'HEAD:experiments/' + frozen.group(1) + '/approval.md', check=False).returncode == 0):
            raise RuntimeError('interrupted frozen edits preserved for inspection; publication forbidden')
        if (clone / rel).exists() or (clone / rel).is_symlink():
            audit_gate.safe_file(clone, rel)  # reject links/escapes before staging
    p, meta, body = owned[0]
    rel_task = p.relative_to(clone).as_posix()
    git(clone, 'fetch', '-q', 'origin')
    if git(clone, 'diff', '--quiet', 'HEAD..@{u}', '--', rel_task, check=False).returncode:
        raise RuntimeError('interrupted remote claim changed; saved local work preserved')
    stamp, tid = now(), meta['id']
    attempt_num = int(meta.get('attempt') or 1)
    attempt = clone / TASKS / 'attempts' / tid / (str(attempt_num) + '.json')
    if attempt.exists():
        raise RuntimeError('existing attempt record preserved; inspect interrupted publication')
    reason = 'ProcessInterrupted: prior runner exited before reporting completion'
    base = git(clone, 'rev-parse', 'HEAD').stdout.strip()
    partial = stage(clone, OUTPUTS[role], excludes=BUILD_JUNK)
    outputs = {rel: sha256_file(clone / rel) for rel in partial if (clone / rel).is_file()}
    report = ('Research process interruption; completion was not observed. Continue from saved files, '
              'verify them, and obtain independent audit. No approval was issued.\nSaved outputs: '
              + json.dumps(outputs, ensure_ascii=False, sort_keys=True))
    meta.update(status='partial', stop_reason=reason, base=base, updated=stamp)
    save(p, meta, body.rstrip() + '\n\n## Interrupted checkpoint — ' + stamp + '\n\n' + report + '\n')
    attempt.parent.mkdir(parents=True, exist_ok=True)
    wr(attempt, json.dumps({'schema': 1, 'task': tid, 'attempt': attempt_num, 'status': 'partial',
        'reason': reason, 'base': base, 'finished': stamp, 'report': report,
        'origin': 'interrupted-runner'}, ensure_ascii=False, sort_keys=True) + '\n')
    ledger_append(clone, {'task': tid, 'role': role, 'worker': me, 'status': 'partial',
        'attempt': attempt_num, 'stop_reason': reason, 'base': base, 'finished': stamp,
        'outputs': outputs, 'origin': 'interrupted-runner'})
    publish(clone, [rel_task, attempt.relative_to(clone).as_posix(), LEDGER], role + ': ' + tid + ' interrupted checkpoint')
    if meta.get('resume_policy') == 'auto' and meta.get('gate') != 'human' and attempt_num < int(meta.get('max_attempts') or 1):
        meta.update(status='ready', claimed_by='', base='', updated=now())
        save(p, meta, body)
        publish(clone, [rel_task], 'board: resume interrupted ' + tid)
    activity.Journal(TEAM_HOME, activity_project(clone), tid, role).emit('중단 작업 복구',
        '미완료 파일 ' + str(len(outputs)) + '개 저장 · 기존 시도 ' + str(attempt_num) + ' 유지 · 감사 미통과', 'waiting')
    print('[' + stamp + '] ' + tid + ': interrupted checkpoint saved; attempt ' + str(attempt_num) + ' retained', flush=True)
    return 1


def cmd_run(a):
    if a.role not in OUTPUTS:
        die(f"--role must be one of {', '.join(OUTPUTS)} (the lead is interactive, not a runner)")
    a.hermes = a.hermes or os.environ.get("RESEARCH_TEAM_HERMES") or shutil.which("hermes")
    if not a.hermes:
        die("hermes not found — pass --hermes or set RESEARCH_TEAM_HERMES")
    if not a.papers_file and not a.remotes and (TEAM_HOME / "papers").is_file():
        a.papers_file = str(TEAM_HOME / "papers")
    if "RESEARCH_GATEWAY_API_KEY" in profile_env(a.profile or a.role):
        die(f"remove RESEARCH_GATEWAY_API_KEY from the {a.profile or a.role} profile's .env — the runner sets it per "
            "task from each paper's sensitivity (keep only RESEARCH_GATEWAY_SECRET there)")
    me = f"{socket.gethostname()}/{a.role}/slot{a.slot}"
    root = Path(a.work or TEAM_HOME / "work" / a.role / f"slot-{a.slot}")
    root.mkdir(parents=True, exist_ok=True)
    clones, first, waits = {}, set(), {}  # waits: task id -> (last post time, lost already pinged)
    print(f"research_board runner {me}: every {a.interval}s"
          + (f", papers from {a.papers_file}" if a.papers_file else ""), flush=True)
    while True:
        for url in remotes(a):
            if url in clones:
                continue
            c = clone_path(root, url)
            try:
                if not c.exists():
                    git(root, "clone", "-q", "-c", "core.autocrlf=false", url, str(c))
                git_identity(c, a.role)
                clones[url] = c
                print(f"[{now()}] serving {c.name}", flush=True)
            except RuntimeError as e:
                print(f"[{now()}] {url}: {e}", file=sys.stderr, flush=True)
        did = False
        for url, c in clones.items():
            try:
                if url not in first:
                    recover_interrupted_claims(c, a.role, me)
                reset_to_remote(c)
                board = tasks(c)
                if url not in first:
                    # Also handle an owned claim fetched into a new/clean clone.
                    recover_interrupted_claims(c, a.role, me)
                    first.add(url)
                    board = tasks(c)
                for tid, (p, m, _) in board.items():
                    if m.get("assignee") == a.role and m.get("status") == "ready" and not waiting_on(m, board):
                        ok, why, lost = condition_met(c, m.get("ready_when", ""))
                        if not ok:
                            last, pinged = waits.get(tid, (0, False))
                            if why.startswith("no jobs"):
                                continue  # another device launched them; it will collect
                            if time.time() - last >= a.heartbeat or (lost and not pinged):
                                Notifier(c, a.profile or a.role).progress(tid,
                                    f"{tid}: 선행 실행 대기 · {why}" + ("\n일부 실행의 프로세스와 완료 기록이 없어 확인이 필요합니다." if lost else ""),
                                     m.get("thread", ""))
                                if lost and not pinged:
                                    Notifier(c, a.profile or a.role).post(
                                        f"**{tid}** has lost experiment jobs; review before retrying.",
                                        m.get("thread", ""), ping=True)
                                waits[tid] = (time.time(), pinged or lost)
                            continue
                        waits.pop(tid, None)
                        if claim(c, p, me):
                            Notifier(c, a.profile or a.role).progress(
                                tid, f"{tid}: {activity.LABELS.get(a.role, a.role)} 실행기가 작업을 맡았습니다 ({me})", m.get("thread", ""))
                            try:
                                execute(a, c, p, me)
                            except (RuntimeError, OSError, ValueError) as error:
                                if not record_runner_error(c,p,me,error):
                                    raise
                            did = True
                        break
            except Exception as e:  # keep the loop alive; the board shows what happened
                print(f"[{now()}] {c.name}: {e}", file=sys.stderr, flush=True)
        if a.status_file:
            try:
                wr(a.status_file, json.dumps({"pid": os.getpid(), "role": a.role, "slot": a.slot, "updated": now(),
                                              "papers": sorted(c.name for c in clones.values())}))
            except OSError:
                pass
        if a.once and not did:
            return
        if not did:
            time.sleep(a.interval)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("init", help="give a paper folder its task board and register it for the runners")
    s.add_argument("folder"); s.add_argument("--boards", help="where bare board repos live (default <team home>/boards)")
    s.add_argument("--papers-file", help="the runners' papers list (default <team home>/papers)")
    s.add_argument("--force", action="store_true", help="also for a folder without CLAUDE.md")
    s.set_defaults(fn=cmd_init)

    s = sub.add_parser("project-create", help="create and bind a project in the research workspace")
    s.add_argument("name", help="lowercase project folder name")
    s.add_argument("--workspace", help="default: the workspace recorded by team setup")
    s.add_argument("--remote", help="optional existing shared Git remote; local bare remote by default")
    s.add_argument("--channel", help="Mattermost channel id or team/name (default: installed home channel)")
    s.add_argument("--mention", help="human user to notify (default: installed researcher)")
    s.set_defaults(fn=cmd_project_create)

    s = sub.add_parser("locations", help="show workspace, project and runtime paths; --write refreshes RESEARCH_PATHS.md")
    s.add_argument("--workspace", help="workspace root (default: the path saved by the installer)")
    s.add_argument("--write", action="store_true", help="refresh the generated guide in the workspace")
    s.set_defaults(fn=cmd_locations)

    s = sub.add_parser("new", help="create a task (idempotent on --id)")
    s.add_argument("paper"); s.add_argument("--id", required=True); s.add_argument("--assignee", required=True)
    s.add_argument("--after", help="comma-separated task ids that must be done first")
    s.add_argument("--expects", help="comma-separated paths the task must produce")
    s.add_argument("--skills", help="comma-separated skills to preload")
    s.add_argument("--thread", help="Mattermost post id of the round thread (from `thread`)")
    s.add_argument("--ready-when", help="built-in wait condition, e.g. 'jobs-done x1'")
    s.add_argument("--notify-done", help="text posted with an @mention when the task is done (e.g. an approval request)")
    s.add_argument("--gate", choices=["auto", "human"], default="auto", help="human gate prevents background lead continuation")
    s.add_argument("--deliver", help="files to attach to the thread when done: <path> or <report.md>:docx, comma-separated")
    s.add_argument("--resume-policy", choices=["auto", "manual"], help="auto resumes capped read/write tasks; experiment tasks default to manual")
    s.add_argument("--max-attempts", type=int, default=MAX_ATTEMPTS, help="maximum checkpoint attempts before lead intervention")
    s.add_argument("--audit-of", help="comma-separated producer task ids; required for reviewer")
    s.add_argument("--audit-scope", choices=["intermediate", "final"], default="intermediate")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--body"); g.add_argument("--body-file", help="file with the prompt, or - for stdin")
    s.set_defaults(fn=cmd_new)

    s = sub.add_parser("list", help="tasks and their status"); s.add_argument("paper")
    s.add_argument("--no-sync", action="store_true"); s.set_defaults(fn=cmd_list)
    s = sub.add_parser("show", help="print one task with its result"); s.add_argument("paper"); s.add_argument("id")
    s.set_defaults(fn=cmd_show)
    s = sub.add_parser("wait", help="poll until the tasks finish or --timeout; exit 0 only if all done")
    s.add_argument("paper"); s.add_argument("ids", nargs="+")
    s.add_argument("--timeout", type=int, default=150, help="seconds (keep under your terminal tool timeout)")
    s.add_argument("--poll", type=int, default=20); s.set_defaults(fn=cmd_wait)
    s = sub.add_parser("edit", help="change after/status or append a note to a task")
    s.add_argument("paper"); s.add_argument("id"); s.add_argument("--after"); s.add_argument("--append")
    s.add_argument('--gate', choices=['auto', 'human'], help='explicit user decision/input request; never an audit pass')
    s.add_argument("--status", choices=["ready", "partial", "blocked", "failed", "done"]); s.set_defaults(fn=cmd_edit)
    s = sub.add_parser("ledger", help="the append-only record of finished tasks")
    s.add_argument("paper"); s.add_argument("--verify", action="store_true", help="only check the hash chain")
    s.add_argument("--no-sync", action="store_true"); s.set_defaults(fn=cmd_ledger)
    s = sub.add_parser("deliver", help="attach committed files to a thread, verified by SHA-256 after upload")
    s.add_argument("paper"); s.add_argument("items", nargs="+", help="<path> or <report.md>:docx")
    s.add_argument("--thread", default="", help="post id of the thread"); s.add_argument("--label", default="")
    s.add_argument("--profile", default="research-lead"); s.set_defaults(fn=cmd_deliver)
    s = sub.add_parser("setup", help="bind the paper to a Mattermost channel for progress posts")
    s.add_argument("paper"); s.add_argument("--channel", required=True, help="channel id, or team/channel-name")
    s.add_argument("--mention", help="who to @mention on blocks and checkpoints, e.g. @paul")
    s.add_argument("--profile", default="research-lead", help="hermes profile whose .env holds the bot token")
    s.set_defaults(fn=cmd_setup)
    s = sub.add_parser("thread", help="post a round's root message; prints its id for `new --thread`")
    s.add_argument("paper"); s.add_argument("title")
    s.add_argument("--root", help="post inside this existing thread instead (e.g. the user's request) and print its id")
    s.add_argument("--profile", default="research-lead"); s.set_defaults(fn=cmd_thread)
    s = sub.add_parser("approve", help="record the user's approval of an experiment protocol or amendment")
    s.add_argument("paper"); s.add_argument("exp", help="experiment id, e.g. x1")
    s.add_argument("--by", required=True, help="who approved, e.g. @paul")
    s.add_argument("--amendment", type=int, help="approve amendment N in amendments.md instead of the protocol")
    s.add_argument("--note"); s.set_defaults(fn=cmd_approve)
    s = sub.add_parser("publish", help="commit and push the lead's own files")
    s.add_argument("paper"); s.add_argument("paths", nargs="+"); s.add_argument("-m", "--message", required=True)
    s.set_defaults(fn=cmd_publish)

    s = sub.add_parser("run", help="worker loop for one role on this device")
    s.add_argument("remotes", nargs="*", help="git URLs of the paper repos to serve")
    s.add_argument("--papers-file", help="file with one git URL per line, re-read on every pass "
                                         "(default <team home>/papers when no URLs are given)")
    s.add_argument("--role", required=True); s.add_argument("--profile", help="hermes profile (default: the role)")
    s.add_argument("--hermes", help="hermes command (default $RESEARCH_TEAM_HERMES, else hermes on PATH)")
    s.add_argument("--slot", type=int, default=1, help="run several slots for parallel tasks")
    s.add_argument("--work", help="clone dir (default <team home>/work/<role>/slot-<n>)")
    s.add_argument("--interval", type=int, default=60)
    s.add_argument("--task-timeout", type=int, default=3 * 3600)
    s.add_argument("--heartbeat", type=int, default=1800, help="seconds between 'still running' posts")
    s.add_argument("--status-file", help="write a small JSON heartbeat here after every pass")
    s.add_argument("--yolo", action="store_true", help="pass --yolo to hermes (skip dangerous-command approvals)")
    s.add_argument("--once", action="store_true", help="exit when no task is ready")
    s.set_defaults(fn=cmd_run)

    s = sub.add_parser("coordinate", help="privately wake the lead for new board results")
    s.add_argument("--retry-paused", action="store_true", help="explicitly retry diagnosed coordinator failures; keeps the saved board and cursor")
    s.add_argument("--papers-file", help="registered project remotes (default: team home/papers)")
    s.add_argument("--hermes", help="hermes command")
    s.add_argument("--interval", type=int, default=30)
    s.add_argument("--task-timeout", type=int, default=1200)
    s.add_argument("--once", action="store_true")
    s.set_defaults(fn=cmd_coordinate)

    a = ap.parse_args()
    try:
        a.fn(a)
    except RuntimeError as e:
        die(str(e))


if __name__ == "__main__":
    main()

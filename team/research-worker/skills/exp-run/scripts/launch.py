#!/usr/bin/env python3
"""launch.py — start one experiment run as a detached job with a hard time cap.

    launch.py <exp-id> <run-name> --max-hours H [--gpus 0,1] [--cwd DIR] -- <command> [args...]

Run it from the paper clone (the paper name is taken from the git top-level folder), or
pass --paper. Each run gets its own directory, which is the whole job contract:

    $RESEARCH_TEAM_JOBS/<paper>/<exp-id>/<run-name>/     (default RESEARCH_TEAM_JOBS=~/.hermes-research-team/jobs)
        meta.json   command, cwd, gpus, cap, code commit, start time
        pid         the supervisor's pid (alive while the job runs)
        stdout.log  stderr.log
        exit_code   written when the command ends (124 = killed at the time cap)
        DONE        written last; the runner's `ready_when: jobs-done <exp-id>` waits for it

No scheduler needed: a detached supervisor process runs the command and enforces the cap.
To move to Slurm later, replace this script with one that submits the job and writes the
same files (e.g. via an epilog) — nothing else in the team changes.

A run name can be used once. A rerun is a new run name, so every attempt stays on record.
"""
import argparse
import json
import os
import platform
import signal
import subprocess as sp
import sys
import time
from pathlib import Path

JOBS = Path(os.environ.get("RESEARCH_TEAM_JOBS", Path(os.environ.get("RESEARCH_TEAM_HOME", Path.home() / ".hermes-research-team")) / "jobs"))
WINDOWS = os.name == "nt"
# Windows: a new process group, no console, and out of the agent's job object, so the run
# outlives the Hermes session that launched it.
DETACH = (sp.CREATE_NEW_PROCESS_GROUP | sp.DETACHED_PROCESS | 0x01000000) if WINDOWS else 0  # 0x01000000: CREATE_BREAKAWAY_FROM_JOB


def spawn(cmd, **kw):
    if WINDOWS:
        try:
            return sp.Popen(cmd, creationflags=DETACH, **kw)
        except OSError:  # the job object forbids breakaway: still detach from the console
            return sp.Popen(cmd, creationflags=DETACH & ~0x01000000, **kw)
    return sp.Popen(cmd, start_new_session=True, **kw)


def stop(p, force=False):
    """Stop the run and every process it started."""
    if WINDOWS:
        sp.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
    else:
        os.killpg(p.pid, signal.SIGKILL if force else signal.SIGTERM)


def supervise(run):
    meta = json.loads((run / "meta.json").read_text(encoding="utf-8"))
    env = dict(os.environ)
    if meta.get("gpus") is not None:
        env["CUDA_VISIBLE_DEVICES"] = meta["gpus"]
    with open(run / "stdout.log", "ab") as out, open(run / "stderr.log", "ab") as err:
        p = spawn(meta["command"], cwd=meta["cwd"], env=env, stdout=out, stderr=err)
        try:
            code = p.wait(timeout=meta["max_hours"] * 3600)
        except sp.TimeoutExpired:
            stop(p)
            try:
                p.wait(timeout=60)
            except sp.TimeoutExpired:
                stop(p, force=True)
                p.wait()
            code = 124
    (run / "exit_code").write_text(f"{code}\n", encoding="utf-8")
    meta["ended"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    (run / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    (run / "DONE").write_text("")


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--_supervise":
        return supervise(Path(sys.argv[2]))
    if "--" not in sys.argv:
        sys.exit("usage: launch.py <exp-id> <run-name> --max-hours H [--gpus 0,1] [--cwd DIR] -- <command...>")
    cut = sys.argv.index("--")
    ap = argparse.ArgumentParser()
    ap.add_argument("exp"); ap.add_argument("run")
    ap.add_argument("--max-hours", type=float, required=True, help="hard wall-clock cap for this run")
    ap.add_argument("--gpus", help="CUDA_VISIBLE_DEVICES for this run, e.g. 0 or 0,1")
    ap.add_argument("--cwd", default=".", help="where the command runs (usually the code checkout)")
    ap.add_argument("--paper", help="paper name (default: git top-level folder of the current dir)")
    a = ap.parse_args(sys.argv[1:cut])
    command = sys.argv[cut + 1:]
    if not command:
        sys.exit("no command after --")
    paper = a.paper or Path(sp.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                                   check=True).stdout.strip()).name
    run = JOBS / paper / a.exp / a.run
    if run.exists():
        sys.exit(f"{run} exists — a run name is used once; pick a new one for a rerun")
    run.mkdir(parents=True)
    cwd = str(Path(a.cwd).resolve())
    commit = sp.run(["git", "-C", cwd, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip() or None
    dirty = bool(sp.run(["git", "-C", cwd, "status", "--porcelain"], capture_output=True, text=True).stdout.strip()) if commit else None
    (run / "meta.json").write_text(json.dumps({
        "paper": paper, "exp": a.exp, "run": a.run, "command": command, "cwd": cwd, "gpus": a.gpus,
        "max_hours": a.max_hours, "code_commit": commit, "code_dirty": dirty,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "host": platform.node()}, indent=2), encoding="utf-8")
    sup = spawn([sys.executable, str(Path(__file__).resolve()), "--_supervise", str(run)],
                stdin=sp.DEVNULL, stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    (run / "pid").write_text(f"{sup.pid}\n", encoding="utf-8")
    print(f"launched {a.exp}/{a.run} (pid {sup.pid}, cap {a.max_hours}h) -> {run}")
    if dirty:
        print("warning: the code checkout has uncommitted changes — the protocol pins a commit", file=sys.stderr)


if __name__ == "__main__":
    main()

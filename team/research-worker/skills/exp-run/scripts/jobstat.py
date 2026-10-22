#!/usr/bin/env python3
"""jobstat.py — state of every run of an experiment launched with launch.py.

    jobstat.py <exp-id> [--paper P] [--json]

State per run: running · done (exit 0) · failed (non-zero exit) · capped (killed at the time
cap, exit 124) · lost (no DONE and no live process — the machine rebooted or the job was
killed outside the supervisor). Same rules the runner uses for `ready_when: jobs-done`.
"""
import argparse
import json
import os
import subprocess as sp
import time
from pathlib import Path

JOBS = Path(os.environ.get("RESEARCH_TEAM_JOBS", Path(os.environ.get("RESEARCH_TEAM_HOME", Path.home() / ".hermes-research-team")) / "jobs"))


def pid_alive(pid):
    if os.name == "nt":  # os.kill(pid, 0) would terminate the process on Windows
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, pid)
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k32.GetExitCodeProcess(h, ctypes.byref(code))
        k32.CloseHandle(h)
        return bool(ok) and code.value == 259
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def state(d):
    if (d / "DONE").exists():
        code = (d / "exit_code").read_text(encoding="utf-8").strip() if (d / "exit_code").exists() else "?"
        return "done" if code == "0" else ("capped" if code == "124" else "failed"), code
    try:
        return ("running" if pid_alive(int((d / "pid").read_text(encoding="utf-8").strip())) else "lost"), None
    except (OSError, ValueError):
        return "lost", None


def last_line(f):
    try:
        lines = [l for l in f.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip()]
        return lines[-1][:160] if lines else ""
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exp"); ap.add_argument("--paper"); ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    paper = a.paper or Path(sp.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                                   check=True).stdout.strip()).name
    root = JOBS / paper / a.exp
    rows = []
    for d in sorted(x for x in root.glob("*") if x.is_dir()) if root.is_dir() else []:
        meta = json.loads((d / "meta.json").read_text(encoding="utf-8")) if (d / "meta.json").exists() else {}
        st, code = state(d)
        rows.append({"run": d.name, "state": st, "exit_code": code, "max_hours": meta.get("max_hours"),
                     "gpus": meta.get("gpus"), "started": meta.get("started"), "ended": meta.get("ended"),
                     "elapsed_h": round((time.time() - (d / "meta.json").stat().st_mtime) / 3600, 2) if st == "running" else None,
                     "dir": str(d), "last_stderr": last_line(d / "stderr.log"), "last_stdout": last_line(d / "stdout.log")})
    if a.json:
        print(json.dumps(rows, indent=2))
        return
    if not rows:
        print(f"no runs under {root}")
        return
    for r in rows:
        print(f"{r['run']:28} {r['state']:8} exit={r['exit_code'] or '-':4} cap={r['max_hours']}h gpus={r['gpus'] or '-'}"
              + (f"  running {r['elapsed_h']}h" if r["elapsed_h"] is not None else "") + f"  {r['dir']}")
    counts = {s: sum(r["state"] == s for r in rows) for s in ("running", "done", "failed", "capped", "lost")}
    print(" · ".join(f"{k} {v}" for k, v in counts.items()))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""team_service — keeps the research team's background processes running on one PC.

    team_service.py serve  --config service.json    # the logon task runs this
    team_service.py status --config service.json    # print the last status (JSON)
    team_service.py stop   --config service.json    # ask a running service to stop

One supervisor for everything that is not the lead's chat gateway (that one is Hermes's own
`gateway run`, a separate task): the model gateway (LiteLLM, when configured) and one
research_board runner per role and slot. A child that exits is restarted with a growing
delay; every few seconds the service writes <team home>/service-status.json, which the
installer waits on and `status` prints.

service.json (written by the installer; no secrets):
  {"team_home", "hermes_home", "python", "hermes", "board", "papers_file",
   "secrets_file",                       # KEY=VALUE file, readable only by this user
   "runners": [{"role", "slot", "task_timeout", "heartbeat"}],
   "coordinator": {"enabled": true, "task_timeout": 1200},
   "gateway": null | {"dir", "port", "litellm"}}
secrets_file holds MATTERMOST_URL, MATTERMOST_TOKEN__<role> (one bot per role),
RESEARCH_GATEWAY_SECRET and RESEARCH_GATEWAY_URL; the gateway's provider keys live in
<gateway dir>/env. Each runner gets only its own bot token.

On Windows the children are put in a job object that is closed with the service, so stopping
the task stops the runners and the agents they started; detached experiment jobs
are not permitted to bypass this owned-process shutdown boundary.
"""
import argparse
import contextlib
import json
import os
import subprocess as sp
import sys
import time
import traceback
import urllib.error
import urllib.request
import uuid
from pathlib import Path

WINDOWS = os.name == "nt"
STATUS_EVERY = 5
BACKOFF = [5, 15, 60, 300]


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_env(path):
    out = {}
    p = Path(path)
    if p.is_file():
        for line in p.read_text(encoding="utf-8").splitlines():
            k, sep, v = line.strip().partition("=")
            if sep and k and not k.startswith("#"):
                out[k.strip()] = v.strip()
    return out


def write_json(path, obj):
    # Windows readers/AV may briefly deny replacement. Keep the last complete
    # snapshot and retry; a failed status observation must not kill model work.
    path = Path(path)
    tmp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        tmp.write_text(json.dumps(obj, indent=1), encoding="utf-8")
        for attempt in range(6):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(0.05 * 2 ** attempt)
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def diagnostic(home, phase, error):
    """Durable safe diagnostics, without exception values/locals or credentials."""
    record = {'time': now(), 'pid': os.getpid(), 'phase': phase,
              'error_class': type(error).__name__,
              'errno': getattr(error, 'errno', None), 'winerror': getattr(error, 'winerror', None),
              'frames': [{'file': Path(f.filename).name, 'line': f.lineno, 'function': f.name}
                         for f in traceback.extract_tb(error.__traceback__)]}
    try:
        folder = Path(home) / 'logs'
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / 'team-supervisor.jsonl').open('a', encoding='utf-8') as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + '\n')
    except OSError:
        pass
    print('Research service ' + phase + ': ' + type(error).__name__, file=sys.stderr, flush=True)


def write_status(home, obj):
    try:
        write_json(Path(home) / 'service-status.json', obj)
        return True
    except OSError as error:
        diagnostic(home, 'status-write', error)
        return False


class Job:
    """Windows job object: children die with the service unless they break away."""

    def __init__(self):
        self.handle = None
        if not WINDOWS:
            return
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.windll.kernel32
        k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        k32.CreateJobObjectW.restype = wintypes.HANDLE
        k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        k32.SetInformationJobObject.restype = wintypes.BOOL
        k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        k32.AssignProcessToJobObject.restype = wintypes.BOOL
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.CloseHandle.restype = wintypes.BOOL

        class BASIC(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class IO(ctypes.Structure):
            _fields_ = [(n, ctypes.c_uint64) for n in ("r", "w", "o", "rb", "wb", "ob")]

        class EXT(ctypes.Structure):
            _fields_ = [("Basic", BASIC), ("Io", IO), ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        self.k32 = k32
        self.handle = k32.CreateJobObjectW(None, None)
        info = EXT()
        info.Basic.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE; do not permit orphan breakaways
        if not self.handle or not k32.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            raise OSError("Cannot initialize research child-process job")

    def add(self, proc):
        if self.handle:
            h = self.k32.OpenProcess(0x0100 | 0x0001, False, proc.pid)  # SET_QUOTA | TERMINATE
            if h:
                try:
                    if not self.k32.AssignProcessToJobObject(self.handle, h):
                        proc.kill()
                        raise OSError("Cannot contain research child process")
                finally:
                    self.k32.CloseHandle(h)
            else:
                proc.kill()
                raise OSError("Cannot open research child process for containment")

    def close(self):
        if self.handle:
            self.k32.CloseHandle(self.handle)
            self.handle = None


def kill_tree(proc):
    if proc.poll() is not None:
        return
    if WINDOWS:
        result = sp.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True, timeout=10)
        if result.returncode and proc.poll() is None:
            proc.kill()
    else:
        try:
            os.killpg(proc.pid, 15)
        except OSError:
            proc.terminate()
    try:
        proc.wait(timeout=20)
    except sp.TimeoutExpired:
        proc.kill()


class Child:
    def __init__(self, name, argv, env, cwd, log):
        self.name, self.argv, self.env, self.cwd, self.log = name, argv, env, cwd, log
        self.proc, self.restarts, self.last_exit, self.next_start = None, 0, None, 0.0
        self.instance = None

    def start(self, job):
        Path(self.log).parent.mkdir(parents=True, exist_ok=True)
        out = open(self.log, "ab")
        kw = {"creationflags": sp.CREATE_NEW_PROCESS_GROUP | 0x08000000} if WINDOWS else {"start_new_session": True}
        self.instance = uuid.uuid4().hex
        env = {**self.env, 'RESEARCH_PROCESS_INSTANCE': self.instance}
        self.proc = sp.Popen(self.argv, cwd=self.cwd, env=env, stdin=sp.DEVNULL, stdout=out, stderr=sp.STDOUT, **kw)
        out.close()
        job.add(self.proc)

    def tick(self, job, stopping):
        if self.proc and self.proc.poll() is not None:
            self.last_exit = self.proc.returncode
            self.proc = None
            self.next_start = time.time() + BACKOFF[min(self.restarts, len(BACKOFF) - 1)]
            self.restarts += 1
        if not self.proc and not stopping and time.time() >= self.next_start:
            self.start(job)

    def state(self):
        return {"name": self.name, "pid": self.proc.pid if self.proc else None,
                "instance": self.instance,
                "state": "running" if self.proc else "restarting", "restarts": self.restarts,
                "last_exit": self.last_exit, "log": str(self.log)}


def gateway_check(port, secret):
    """-> (ok, detail): the gateway answers on the port AS this team's gateway (probe with the secret)."""
    base = f"http://127.0.0.1:{port}"
    try:
        urllib.request.urlopen(base + "/health/liveliness", timeout=5).close()
    except OSError as e:
        return False, f"not answering on 127.0.0.1:{port} ({e.__class__.__name__})"
    req = urllib.request.Request(
        base + "/v1/chat/completions", method="POST",
        data=json.dumps({"model": "research-probe", "max_tokens": 1,
                         "messages": [{"role": "user", "content": "probe"}]}).encode(),
        headers={"Authorization": f"Bearer rgw.research-lead.public.{secret}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=15).close()
        return False, "port answered, but not as the research gateway"
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        return ("research-gateway-probe: ok" in body), ("ok" if "research-gateway-probe: ok" in body else body[:200])
    except OSError as e:
        return False, str(e)


def children(cfg):
    home = Path(cfg["team_home"])
    secrets = read_env(cfg["secrets_file"])
    base = {k: v for k, v in os.environ.items() if not k.startswith(("MATTERMOST_", "RESEARCH_GATEWAY_"))}
    base.update({"RESEARCH_TEAM_HOME": str(home), "HERMES_HOME": cfg["hermes_home"], "PYTHONUTF8": "1",
                 "PYTHONIOENCODING": "utf-8"})
    out = []
    limits = cfg.get("limits", {})
    for key, field, default in (("RESEARCH_MAX_TURNS", "max_turns", 2000),
                                ("RESEARCH_MAX_ATTEMPTS", "max_attempts", 50),
                                ("RESEARCH_MODEL_RETRIES", "model_retries", 100)):
        base[key] = str(limits.get(field, default))
    gw = cfg.get("gateway")
    if gw:
        genv = dict(base)
        genv.update(read_env(Path(gw["dir"]) / "env"))
        out.append(Child("gateway", [gw["litellm"], "--config", "litellm.config.yaml", "--host", "127.0.0.1",
                                     "--port", str(gw["port"])], genv, gw["dir"], home / "logs" / "gateway.log"))
    dashboard = cfg.get('dashboard')
    if dashboard:
        # No Mattermost token or model/router key is passed to the web server.
        denv = {k: v for k, v in base.items() if not any(x in k.upper() for x in ('TOKEN', 'SECRET', 'API_KEY'))}
        out.append(Child('research-board', [cfg['python'], str(Path(cfg['board']).with_name('research_dashboard.py')),
                         '--workspace', dashboard['workspace'], '--home', str(home)], denv, str(home),
                         home / 'logs' / 'research-board.log'))
    for r in cfg["runners"]:
        env = dict(base)
        env["MATTERMOST_URL"] = secrets.get("MATTERMOST_URL", "")
        env["MATTERMOST_TOKEN"] = secrets.get(f"MATTERMOST_TOKEN__{r['role']}", "")
        for k in ("RESEARCH_GATEWAY_SECRET", "RESEARCH_GATEWAY_URL"):
            if secrets.get(k):
                env[k] = secrets[k]
        name = f"{r['role']}-{r['slot']}"
        argv = [cfg["python"], cfg["board"], "run", "--role", r["role"], "--slot", str(r["slot"]),
                "--papers-file", cfg["papers_file"], "--hermes", cfg["hermes"],
                "--task-timeout", str(r.get("task_timeout", 10800)), "--heartbeat", str(r.get("heartbeat", 1800)),
                "--status-file", str(home / "run" / f"{name}.json")]
        out.append(Child(name, argv, env, str(home), home / "logs" / f"{name}.log"))
    coordinator = cfg.get("coordinator") or {}
    if coordinator.get("enabled"):
        env = dict(base)
        for k in ("RESEARCH_GATEWAY_SECRET", "RESEARCH_GATEWAY_URL"):
            if secrets.get(k):
                env[k] = secrets[k]
        argv = [cfg["python"], cfg["board"], "coordinate", "--papers-file", cfg["papers_file"],
                "--hermes", cfg["hermes"], "--task-timeout", str(coordinator.get("task_timeout", 1200))]
        out.append(Child("lead-coordinator", argv, env, str(home), home / "logs" / "lead-coordinator.log"))
    return out


@contextlib.contextmanager
def service_instance_lock(home):
    """OS-owned lock; release on crash, reject duplicate supervisors per team."""
    folder=Path(home)/'run';folder.mkdir(parents=True,exist_ok=True)
    handle=(folder/'service.lock').open('a+b')
    try:
        if os.fstat(handle.fileno()).st_size==0:
            handle.write(b'\0');handle.flush()
        handle.seek(0)
        try:
            if WINDOWS:
                import msvcrt
                msvcrt.locking(handle.fileno(),msvcrt.LK_NBLCK,1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError as exc:
            raise RuntimeError('team service already running or instance lock unavailable: '+str(folder)) from exc
        yield
    finally:
        handle.close()


def serve(cfg, cfg_path):
    try:
        with service_instance_lock(cfg['team_home']):
            return _serve_owned(cfg,cfg_path)
    except Exception as error:
        diagnostic(cfg['team_home'], 'fatal', error)
        raise


def _serve_owned(cfg, cfg_path):
    home = Path(cfg["team_home"])
    for d in ("logs", "run"):
        (home / d).mkdir(parents=True, exist_ok=True)
    stop_file, status_file = home / "run" / "service.stop", home / "service-status.json"
    stop_file.unlink(missing_ok=True)
    job, kids = Job(), children(cfg)
    secret = read_env(cfg["secrets_file"]).get("RESEARCH_GATEWAY_SECRET", "")
    gw_state = None
    started = now()
    try:
        while True:
            stopping = stop_file.exists()
            gateway = next((k for k in kids if k.name == "gateway"), None)
            if gateway:
                gateway.tick(job, stopping)
            ok, detail = gateway_check(cfg["gateway"]["port"], secret) if gateway and gateway.proc else (gateway is None, "not configured" if gateway is None else "starting")
            gw_state = {"ok": ok, "detail": detail}
            for k in kids:
                if k.name != "gateway" and (k.name == 'research-board' or ok or gateway is None or k.proc):
                    k.tick(job, stopping)
            write_status(home, {"pid": os.getpid(), "started": started, "updated": now(), "config": str(cfg_path),
                                     "stopping": stopping, "gateway": gw_state, "children": [k.state() for k in kids]})
            if stopping:
                break
            time.sleep(STATUS_EVERY)
    finally:
        # Close the service-owned job first: all contained descendants terminate,
        # including nested shells. No unrelated process or personal gateway is targeted.
        job.close()
        for k in kids:
            if k.proc:
                if WINDOWS:
                    try: k.proc.wait(timeout=10)
                    except sp.TimeoutExpired: kill_tree(k.proc)
                else:
                    kill_tree(k.proc)
        states = [dict(k.state(), state='stopped', pid=None) for k in kids]
        write_status(home, {"pid": None, "started": started, "updated": now(), "config": str(cfg_path),
                           "stopped": True, "gateway": gw_state, "children": states})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["serve", "status", "stop"])
    ap.add_argument("--config", required=True)
    a = ap.parse_args()
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    home = Path(cfg["team_home"])
    if a.cmd == "serve":
        serve(cfg, a.config)
    elif a.cmd == "status":
        p = home / "service-status.json"
        print(p.read_text(encoding="utf-8") if p.exists() else '{"pid": null}')
    else:
        (home / "run").mkdir(parents=True, exist_ok=True)
        (home / "run" / "service.stop").write_text(now(), encoding="utf-8")
        print("stop requested")


if __name__ == "__main__":
    main()

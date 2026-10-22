"""research_board end to end: a bare board repo, a stub `hermes`, a mock Mattermost.

Runs on Windows and POSIX. Covers init + papers file, blind snapshots, output filtering,
the hash-chained ledger, transient retries, the profile integrity check, refusal of
non-public papers without a gateway, frozen protocols and verified delivery.
"""
import hashlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import subprocess as sp
import sys
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOARD = ROOT / "team" / "shared" / "research_board.py"
sys.path.insert(0, str(BOARD.parent))

STUB = r'''
import json, os, sys, re
from pathlib import Path
args = sys.argv[1:]
prompt = Path(args[args.index("--query-file") + 1]).read_text(encoding="utf-8")
log = Path(os.environ["STUB_LOG"])
with log.open("a", encoding="utf-8") as f:
    f.write(json.dumps({"cwd": os.getcwd(), "profile": args[args.index("-p") + 1],
                        "has_git": Path(".git").exists(), "has_tasks": Path(".tasks").exists(),
                        "token": os.environ.get("MATTERMOST_TOKEN"), "secret": os.environ.get("RESEARCH_GATEWAY_SECRET"),
                        "len": len(prompt), "max_turns": args[args.index("--max-turns") + 1],
                        "skills": [args[i + 1] for i, x in enumerate(args) if x == "-s"]}) + "\n")
counter = Path(os.environ["STUB_LOG"] + ".count")
n = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(n))
if "FLAKY" in prompt and n == 1:
    print("upstream error: 529 overloaded", file=sys.stderr); sys.exit(1)
if "WRITE-PAPER" in prompt:
    Path("paper").mkdir(exist_ok=True); Path("paper/main.tex").write_text("\\section{x} é\n", encoding="utf-8")
    Path("stray.txt").write_text("not an output")
    Path("paper/main.aux").write_text("junk")
if "NAMED-TEST-LOG" in prompt:
    Path("evidence").mkdir(exist_ok=True)
    Path("evidence/tests.log").write_text("actual fixture tests passed\n")
    Path("evidence/unrequested.log").write_text("unrequested build noise\n")
if "REVIEW" in prompt:
    Path("reviews/round-1").mkdir(parents=True, exist_ok=True)
    Path("reviews/round-1/meta.md").write_text("# Meta\n**Call:** minor revision\nPRESENTATION one\n", encoding="utf-8")
    Path("paper").mkdir(exist_ok=True); Path("paper/main.tex").write_text("reviewer edit")
if "REPORT" in prompt:
    Path("notes").mkdir(exist_ok=True)
    Path("notes/report.md").write_text("# 보고서\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n", encoding="utf-8")
    sys.path.insert(0, os.environ["STUB_SHARED"])
    import report_docx
    Path("notes/report.docx").write_bytes(report_docx.build_docx(Path("notes/report.md").read_text(encoding="utf-8"), source="offline fixture"))
if args[args.index("-p") + 1] == "research-reviewer":
    dest = re.search(r"Write (reviews/[^ ]+/verdict.json)", prompt).group(1)
    path = Path(dest); path.parent.mkdir(parents=True, exist_ok=True)
    result = {"verdict": "pass", "checks": {k: {"status": "pass", "evidence": "Offline stub checked fixture file"}
        for k in ("requirements","sources","methods","consistency","uncertainty")}, "findings": [], "notes": "OFFLINE STUB"}
    if os.environ.get("AUDIT_REJECT") == "1":
        result["verdict"] = "reject"
        result["findings"] = [{"location":"report paragraph 1","evidence":"fixture missing source","correction":"add source","blocking":True}]
    path.write_text(json.dumps(result), encoding="utf-8")
    if os.environ.get("AUDIT_MUTATE_INPUT") == "1":
        Path("paper/main.tex").write_text("reviewer edit", encoding="utf-8")
if "TOUCH-PROTOCOL" in prompt:
    Path("experiments/x1/protocol.md").write_text("changed")
if args[args.index("-p") + 1] == "research-lead" and "LEAD-CAPPED" in prompt:
    print("lead made a partial plan")
    print("maximum tool-iteration limit was reached")
    sys.exit(0)
if "CAPPED" in prompt and "LEAD-CAPPED" not in prompt and n == 1:
    print("maximum tool-iteration limit was reached")
    if "CAPPED-DONE" in prompt:
        print("STATUS: done")
    sys.exit(0)
print("work done")
print("STATUS: blocked — cannot" if "BLOCK" in prompt else "STATUS: done")
'''


class MockMattermost(http.server.BaseHTTPRequestHandler):
    posts, files = [], {}

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/api/v4/posts":
            post = json.loads(body); post["id"] = f"p{len(self.posts):025d}"
            MockMattermost.posts.append(post); return self._json(post)
        if self.path == "/api/v4/files":
            boundary = self.headers["Content-Type"].split("boundary=")[1].encode()
            part = [p for p in body.split(b"--" + boundary) if b'name="files"' in p][0]
            data = part.split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n", 1)[0]
            fid = f"f{len(self.files):025d}"; MockMattermost.files[fid] = data
            return self._json({"file_infos": [{"id": fid, "size": len(data)}]})
        self._json({}, 404)

    def do_GET(self):
        fid = self.path.rsplit("/", 1)[-1]
        if fid in self.files:
            data = self.files[fid]
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
            self.wfile.write(data); return
        self._json({}, 404)

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        pid = self.path.rsplit("/", 1)[-1]
        for post in MockMattermost.posts:
            if post["id"] == pid:
                post["message"] = body["message"]
                return self._json(post)
        self._json({}, 404)


def git(*args, cwd=None):
    return sp.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MockMattermost)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        MockMattermost.posts.clear(); MockMattermost.files.clear()
        self.tmp = Path(tempfile.mkdtemp(prefix="board-test-"))
        self.home = self.tmp / "team"; self.hh = self.tmp / "hermes"
        self.ws = self.tmp / "ws"; self.ws.mkdir(); (self.tmp / "empty.gitconfig").write_text("")
        stub = self.tmp / "stub.py"; stub.write_text(STUB, encoding="utf-8")
        if os.name == "nt":
            self.hermes = self.tmp / "hermes-stub.cmd"
            self.hermes.write_text(f'@"{sys.executable}" "{stub}" %*\r\n')
        else:
            self.hermes = self.tmp / "hermes-stub"
            self.hermes.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{stub}" "$@"\n'); self.hermes.chmod(0o755)
        self.log = self.tmp / "stub.log"
        self.env = {**os.environ, "RESEARCH_TEAM_HOME": str(self.home), "HERMES_HOME": str(self.hh),
                    "STUB_LOG": str(self.log), "STUB_SHARED": str(BOARD.parent), "MATTERMOST_URL": f"http://127.0.0.1:{self.server.server_port}",
                    "MATTERMOST_TOKEN": "t" * 26, "RESEARCH_GATEWAY_SECRET": "",
                    # no global git identity, as on a fresh Windows account
                    "GIT_CONFIG_GLOBAL": str(self.tmp / "empty.gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
                    "RESEARCH_TEAM_MANIFEST": str(self.tmp / "manifest.json")}
        for role in ("research-lead", "research-reviewer", "research-scout", "research-worker"):
            (self.hh / "profiles" / role).mkdir(parents=True)
            (self.hh / "profiles" / role / "SOUL.md").write_text("offline persona", encoding="utf-8")
        (self.tmp / "manifest.json").write_text(json.dumps({"profiles": {
            role: {"SOUL.md": hashlib.sha256(b"offline persona").hexdigest()}
            for role in ("research-lead", "research-scout", "research-worker", "research-reviewer")}}), encoding="utf-8")
        self.paper = self.ws / "p1"; self.paper.mkdir()
        (self.paper / "CLAUDE.md").write_text("# p1\n**Sensitivity:** public\n", encoding="utf-8")
        self.board("init", str(self.paper))
        self.board("setup", str(self.paper), "--channel", "c" * 26, "--mention", "@me")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def board(self, *args, check=True):
        r = sp.run([sys.executable, str(BOARD), *args], env=self.env, capture_output=True,
                   encoding="utf-8", errors="replace", cwd=self.ws)
        if check and r.returncode:
            self.fail(f"{args[0]} failed: {r.stdout}\n{r.stderr}")
        return r

    def run_role(self, role, *extra):
        return self.board("run", "--role", role, "--once", "--interval", "1", "--hermes", str(self.hermes), *extra)

    def task(self, tid, assignee, body, *extra):
        if "--expects" not in extra:
            extra += ("--expects", "notes/report.md" if assignee == "research-scout" else
                      "experiments/x1/protocol.md" if "PROTOCOL" in body or body == "CAPPED" else "paper/main.tex")
        self.board("new", str(self.paper), "--id", tid, "--assignee", assignee, "--body", body, *extra)

    def audit(self, producer, scope="final", tid="r1"):
        self.task(tid, "research-reviewer", "independent audit", "--expects", f"reviews/{tid}/verdict.json",
                  "--after", producer, "--audit-of", producer, "--audit-scope", scope)
        self.run_role("research-reviewer")
        git("pull", "-q", cwd=self.paper)

    def state(self, tid):
        git("pull", "-q", cwd=self.paper)
        return self.board("show", str(self.paper), tid).stdout

    def calls(self):
        return [json.loads(l) for l in self.log.read_text(encoding="utf-8").splitlines()] if self.log.exists() else []



class BoardTests(Base):
    def test_word_is_not_generated_after_markdown_only_final_approval(self):
        self.task('md-only','research-scout','REPORT','--expects','notes/report.md')
        self.run_role('research-scout');git('pull','-q',cwd=self.paper)
        git('rm','notes/report.docx',cwd=self.paper);git('commit','-m','fixture no prepared Word',cwd=self.paper);git('push',cwd=self.paper)
        self.audit('md-only')
        result=self.board('deliver',str(self.paper),'notes/report.md:docx','--thread','p'*26,check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('FinalAuditRequired',result.stderr)
        self.assertFalse(MockMattermost.files)

    def test_audit_preparation_failure_becomes_failed_event_not_ghost_running(self):
        self.task('w-prep','research-worker','WRITE-PAPER','--expects','paper/main.tex')
        self.run_role('research-worker');git('pull','-q',cwd=self.paper)
        self.task('audit-prep','research-reviewer','independent','--audit-of','w-prep',
                  '--expects','reviews/audit-prep/verdict.json')
        git('rm','paper/main.tex',cwd=self.paper);git('commit','-m','fixture lost input after assignment',cwd=self.paper)
        git('push',cwd=self.paper)
        self.run_role('research-reviewer')
        result=self.state('audit-prep')
        self.assertIn('status: failed',result)
        self.assertIn('RunnerError: Missing artifact',result)
        self.assertEqual(len(self.calls()),1)
        self.assertIn('ledger intact: 2',self.board('ledger',str(self.paper),'--verify').stdout)

    def test_audit_of_done_producer_with_missing_published_input_refused_early(self):
        self.task('w-missing', 'research-worker', 'WRITE-PAPER', '--expects', 'paper/main.tex')
        self.run_role('research-worker');git('pull','-q',cwd=self.paper)
        git('rm','paper/main.tex',cwd=self.paper)
        git('commit','-m','fixture removed artifact',cwd=self.paper);git('push',cwd=self.paper)
        # A local, untracked copy is not evidence published in the shared board.
        (self.paper/'paper').mkdir(parents=True,exist_ok=True)
        (self.paper/'paper/main.tex').write_text('unpublished local copy',encoding='utf-8')
        result=self.board('new',str(self.paper),'--id','audit-missing','--assignee','research-reviewer',
            '--audit-of','w-missing','--expects','reviews/audit-missing/verdict.json','--body','independent',check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('AuditInputsUnavailable',result.stderr)
        self.assertFalse((self.paper/'.tasks/audit-missing.md').exists())
        self.assertEqual(len(self.calls()),1)

    def test_named_evidence_log_published_but_unnamed_log_filtered(self):
        self.task('w-log', 'research-worker', 'NAMED-TEST-LOG', '--expects', 'evidence/tests.log')
        self.run_role('research-worker')
        self.assertIn('status: done', self.state('w-log'))
        tracked=git('ls-files',cwd=self.paper).splitlines()
        self.assertIn('evidence/tests.log',tracked)
        self.assertNotIn('evidence/unrequested.log',tracked)
        ledger=[json.loads(line) for line in (self.paper/'.tasks/ledger.jsonl').read_text(encoding='utf-8').splitlines()]
        self.assertIn('evidence/tests.log',ledger[-1]['outputs'])

    def test_coordinator_selects_workflow_skill_from_task_id(self):
        board = _load_board()
        self.assertTrue(board.ITERATION_LIMIT.search("Reached maximum iterations (40) — response may be incomplete"))
        self.assertEqual("research-report", board.lead_skill_for("rep-foo-audit-1"))
        self.assertEqual("research-start", board.lead_skill_for("s3-outline"))
        self.assertEqual("research-experiment", board.lead_skill_for("x2-check"))
        self.assertEqual("research-round", board.lead_skill_for("r3-chair"))
        self.assertIsNone(board.lead_skill_for("custom-task"))
        self.assertNotEqual(board.clone_path(self.home / "work", "https://one.example/p.git"),
                            board.clone_path(self.home / "work", "https://two.example/p.git"))

    def test_project_create_is_idempotent_and_registers_local_remote(self):
        (self.ws / "_template").mkdir()
        shutil.copytree(ROOT / "team" / "template", self.ws / "_template", dirs_exist_ok=True)
        self.home.mkdir(exist_ok=True)
        (self.home / "workspace-root.txt").write_text(str(self.ws) + "\n", encoding="utf-8")
        (self.home / "team.json").write_text(json.dumps({"HomeChannelID": "c" * 26,
            "WizardOptions": {"HumanUsername": "me"}}), encoding="utf-8")
        self.board("project-create", "p2")
        self.board("project-create", "p2")
        self.assertTrue((self.ws / "p2/.tasks/project.json").is_file())
        self.assertTrue((self.ws / "p2/.tasks/board.conf").is_file())
        self.assertEqual(1, (self.home / "papers").read_text(encoding="utf-8").splitlines().count(
            str(self.home / "boards/p2.git")))
        self.assertIn(str((self.ws / "p2").resolve()), (self.ws / "RESEARCH_PATHS.md").read_text(encoding="utf-8"))

    def test_coordinator_consumes_result_once_without_mattermost_handoff(self):
        shutil.copytree(ROOT / "team" / "template", self.ws / "_template")
        self.home.mkdir(exist_ok=True)
        (self.home / "workspace-root.txt").write_text(str(self.ws) + "\n", encoding="utf-8")
        (self.home / "team.json").write_text(json.dumps({"HomeChannelID": "c" * 26,
            "WizardOptions": {"HumanUsername": "me"}}), encoding="utf-8")
        self.board("project-create", "p2")
        self.paper = self.ws / "p2"
        self.task("w1", "research-worker", "WRITE-PAPER", "--expects", "paper/main.tex")
        self.run_role("research-worker")
        before = len(MockMattermost.posts)
        self.board("coordinate", "--once", "--hermes", str(self.hermes))
        self.board("coordinate", "--once", "--hermes", str(self.hermes))
        self.assertEqual(1, len([call for call in self.calls() if call["profile"] == "research-lead"]))
        self.assertEqual(before, len(MockMattermost.posts), 'routine lead results go to the web board, not chat')
        from research_activity import read_events
        rows = read_events(self.home, self.paper.name)
        self.assertTrue(any(row['action'] == '후속 계획 판단' for row in rows))

    def test_human_gate_notifies_user_without_background_lead_turn(self):
        shutil.copytree(ROOT / "team" / "template", self.ws / "_template")
        self.home.mkdir(exist_ok=True)
        (self.home / "workspace-root.txt").write_text(str(self.ws) + "\n", encoding="utf-8")
        (self.home / "team.json").write_text(json.dumps({"HomeChannelID": "c" * 26,
            "WizardOptions": {"HumanUsername": "me"}}), encoding="utf-8")
        self.board("project-create", "p2")
        self.paper = self.ws / "p2"
        self.task("w1", "research-worker", "WRITE-PAPER", "--expects", "paper/main.tex", "--gate", "human")
        self.run_role("research-worker")
        self.board("coordinate", "--once", "--hermes", str(self.hermes))
        self.assertFalse(any(call["profile"] == "research-lead" for call in self.calls()))
        self.assertTrue(any("ready for your decision" in post["message"] and "@me" in post["message"]
                            for post in MockMattermost.posts))

    def test_capped_lead_turn_saves_checkpoint_and_requests_human_resume(self):
        shutil.copytree(ROOT / "team" / "template", self.ws / "_template")
        self.home.mkdir(exist_ok=True)
        (self.home / "workspace-root.txt").write_text(str(self.ws) + "\n", encoding="utf-8")
        (self.home / "team.json").write_text(json.dumps({"HomeChannelID": "c" * 26,
            "WizardOptions": {"HumanUsername": "me"}}), encoding="utf-8")
        self.board("project-create", "p2")
        self.paper = self.ws / "p2"
        self.task("LEAD-CAPPED", "research-worker", "WRITE-PAPER", "--expects", "paper/main.tex")
        self.run_role("research-worker")
        self.board("coordinate", "--once", "--hermes", str(self.hermes))
        self.board("coordinate", "--once", "--hermes", str(self.hermes))
        self.assertEqual(1, len([call for call in self.calls() if call["profile"] == "research-lead"]))
        checkpoints = list((self.home / "run" / "lead-attempts").glob("*.json"))
        self.assertEqual(1, len(checkpoints))
        self.assertIn("lead made a partial plan", checkpoints[0].read_text(encoding="utf-8"))
        self.assertTrue(any("Background lead work" in post["message"] and "@me" in post["message"]
                            for post in MockMattermost.posts))

    def test_init_pushes_a_preconfigured_empty_remote_and_sets_tracking(self):
        remote = self.tmp / "shared.git"
        git("init", "--bare", "-q", "-b", "main", str(remote))
        other = self.ws / "external"; other.mkdir()
        (other / "CLAUDE.md").write_text("# external\n", encoding="utf-8")
        git("init", "-q", "-b", "main", cwd=other)
        git("remote", "add", "origin", str(remote), cwd=other)
        self.board("init", str(other))
        self.assertEqual("origin/main", git("rev-parse", "--abbrev-ref", "@{u}", cwd=other))
        self.assertEqual("# external", git("show", "main:CLAUDE.md", cwd=remote))
        self.assertIn(str(remote), (self.home / "papers").read_text(encoding="utf-8").splitlines())

    def test_locations_guide_tracks_new_projects_and_hides_remote_credentials(self):
        self.home.mkdir(exist_ok=True)
        (self.home / "workspace-root.txt").write_text(str(self.ws) + "\n", encoding="utf-8")
        (self.home / "team.json").write_text(json.dumps({"HermesHome": str(self.hh),
            "InstallDir": str(self.tmp / "hermes-source")}), encoding="utf-8")
        second = self.ws / "p2"; second.mkdir()
        (second / "CLAUDE.md").write_text("# p2\n", encoding="utf-8")
        self.board("init", str(second.resolve()))
        guide = self.ws / "RESEARCH_PATHS.md"
        content = guide.read_text(encoding="utf-8")
        self.assertIn(str(second.resolve()), content)
        self.assertIn(str(self.home / "boards" / "p2.git"), content)
        self.assertIn(str(self.home / "service-status.json"), content)
        self.assertIn(str(self.hh / "profiles"), content)
        self.assertIn("not a GitHub repository", content)
        # The guide canonicalizes project paths; Windows TEMP can use RUNNER~1
        # while Path.resolve() returns the equivalent long directory name.
        self.assertIn(str(self.paper.resolve()), self.board("locations").stdout)
        self.assertEqual("https://github.com/org/p2.git",
                         self._public_remote_for_test("https://secret@github.com/org/p2.git"))

    @staticmethod
    def _load_board_spec():
        return importlib.util.spec_from_file_location("research_board", BOARD)

    @classmethod
    def _public_remote_for_test(cls, url):
        spec = cls._load_board_spec()
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module._public_remote(url)

    def test_init_registers_paper_and_runner_reads_papers_file(self):
        papers = (self.home / "papers").read_text(encoding="utf-8").splitlines()
        self.assertEqual([str(self.home / "boards" / "p1.git")], papers)
        self.task("w1", "research-worker", "WRITE-PAPER", "--expects", "paper/main.tex")
        self.run_role("research-worker")  # no URLs given: <team home>/papers
        self.assertIn("status: done", self.state("w1"))

    def test_writer_outputs_filtered_ledger_chained_and_secrets_withheld(self):
        self.task("w1", "research-worker", "WRITE-PAPER", "--expects", "paper/main.tex")
        self.run_role("research-worker")
        git("pull", "-q", cwd=self.paper)
        files = git("ls-files", cwd=self.paper).split("\n")
        self.assertIn("paper/main.tex", files)
        self.assertNotIn("stray.txt", files); self.assertNotIn("paper/main.aux", files)
        self.assertEqual("\\section{x} é\n", (self.paper / "paper/main.tex").read_text(encoding="utf-8"))
        call = self.calls()[0]
        self.assertIsNone(call["token"]); self.assertFalse(call["secret"])
        ledger = [json.loads(l) for l in (self.paper / ".tasks/ledger.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual("done", ledger[0]["status"]); self.assertEqual("", ledger[0]["prev"])
        self.assertEqual(hashlib.sha256((self.paper / "paper/main.tex").read_bytes()).hexdigest(),
                         ledger[0]["outputs"]["paper/main.tex"])
        self.assertIn("at commit", self.state("w1"))
        self.assertIn("ledger intact: 1", self.board("ledger", str(self.paper), "--verify").stdout)

    def test_capped_task_preserves_partial_work_then_resumes_once(self):
        self.task("w1", "research-worker", "CAPPED-DONE WRITE-PAPER", "--expects", "paper/main.tex")
        self.run_role("research-worker")
        self.assertIn("status: done", self.state("w1"))
        self.assertEqual(2, len(self.calls()))
        self.assertTrue(all(call["max_turns"] == "2000" for call in self.calls()))
        attempts = sorted((self.paper / ".tasks/attempts/w1").glob("*.json"))
        self.assertEqual(["1.json", "2.json"], [p.name for p in attempts])
        self.assertEqual("partial", json.loads(attempts[0].read_text(encoding="utf-8"))["status"])
        ledger = [json.loads(l) for l in (self.paper / ".tasks/ledger.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(["partial", "done"], [entry["status"] for entry in ledger])

    def test_experimenter_cap_stays_partial_for_lead_review(self):
        self.task("e1", "research-worker", "CAPPED")
        self.run_role("research-worker")
        self.assertIn("status: partial", self.state("e1"))
        self.assertEqual(1, len(self.calls()))

    def test_bot_notice_does_not_mention_another_bot(self):
        self.task("w1", "research-worker", "WRITE-PAPER", "--notify-done", "Tell @research-lead to continue")
        self.run_role("research-worker")
        messages = [p["message"] for p in MockMattermost.posts]
        self.assertFalse(any("@research-lead" in message for message in messages))
        self.assertTrue(any("@me" in message for message in messages))

    def test_ledger_rewrite_is_detected_and_reported(self):
        for tid in ("w1", "w2"):
            self.task(tid, "research-worker", "WRITE-PAPER")
            self.run_role("research-worker")
        git("pull", "-q", cwd=self.paper)
        led = self.paper / ".tasks/ledger.jsonl"
        lines = led.read_text(encoding="utf-8").splitlines()
        lines[0] = lines[0].replace('"done"', '"failed"')  # rewrite an earlier entry
        led.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.task("w3", "research-worker", "WRITE-PAPER")
        git("add", "-A", cwd=self.paper); git("commit", "-qm", "tamper", cwd=self.paper); git("push", "-q", cwd=self.paper)
        self.assertNotEqual(0, self.board("ledger", str(self.paper), "--verify", check=False).returncode)
        self.run_role("research-worker")
        self.assertTrue(any("ledger was rewritten" in p["message"] for p in MockMattermost.posts))
        # the break is now on record, so later tasks do not warn again
        self.assertEqual(0, self.board("ledger", str(self.paper), "--verify", check=False).returncode)

    def test_blind_reviewer_sees_snapshot_cannot_edit_paper_and_checkpoint_names_commit(self):
        self.task("w1", "research-worker", "WRITE-PAPER")
        self.run_role("research-worker")
        self.env["AUDIT_MUTATE_INPUT"] = "1"
        self.audit("w1")
        call = [c for c in self.calls() if c["profile"] == "research-reviewer"][0]
        self.assertFalse(call["has_git"]); self.assertFalse(call["has_tasks"])
        self.assertNotEqual("reviewer edit", (self.paper / "paper/main.tex").read_text(encoding="utf-8"))
        self.assertIn("status: failed", self.state("r1"))
        self.assertIn("Reviewed input was modified", self.state("r1"))
        self.assertNotEqual(0, self.board("deliver", str(self.paper), "paper/main.tex", check=False).returncode)

    def test_drifted_profile_blocks_task(self):
        soul = self.hh / "profiles/research-worker/SOUL.md"; soul.write_text("original", encoding="utf-8")
        (self.tmp / "manifest.json").write_text(json.dumps({"profiles": {"research-worker": {
            "SOUL.md": hashlib.sha256(b"original").hexdigest()}}}), encoding="utf-8")
        soul.write_text("tampered", encoding="utf-8")
        self.task("w1", "research-worker", "WRITE-PAPER")
        self.run_role("research-worker")
        self.assertIn("status: blocked", self.state("w1")); self.assertIn("differs from the install", self.state("w1"))
        self.assertEqual([], self.calls())

    def test_private_paper_refused_without_gateway(self):
        (self.paper / "CLAUDE.md").write_text("**Sensitivity:** private\n", encoding="utf-8")
        self.board("publish", str(self.paper), "-m", "private", "CLAUDE.md")
        self.task("w1", "research-worker", "WRITE-PAPER")
        self.run_role("research-worker")
        self.assertIn("status: blocked", self.state("w1")); self.assertEqual([], self.calls())

    def test_frozen_protocol_restored_and_task_failed(self):
        d = self.paper / "experiments/x1"; d.mkdir(parents=True)
        (d / "protocol.md").write_text("plan", encoding="utf-8")
        self.board("publish", str(self.paper), "-m", "protocol", "experiments")
        self.board("approve", str(self.paper), "x1", "--by", "@me")
        self.task("e1", "research-worker", "TOUCH-PROTOCOL")
        self.run_role("research-worker")
        self.assertIn("status: failed", self.state("e1"))
        self.assertEqual("plan", (d / "protocol.md").read_text(encoding="utf-8"))

    def test_long_prompt_passed_as_file_and_role_skills_preloaded(self):
        prompt = self.ws / "long-prompt.md"
        prompt.write_text("WRITE-PAPER " + "x" * 40000, encoding="utf-8")
        self.board("new", str(self.paper), "--id", "w1", "--assignee", "research-worker",
                   "--body-file", str(prompt), "--skills", "presubmission", "--expects", "paper/main.tex")
        self.run_role("research-worker")
        self.assertIn("status: done", self.state("w1"))
        self.assertGreater(self.calls()[0]["len"], 40000)
        self.assertEqual(["lit-search", "presubmission"], self.calls()[0]["skills"])
        self.assertEqual([], list((self.home / "run" / "prompts").glob("*")))

    def test_report_delivered_as_verified_docx(self):
        self.task("l1", "research-scout", "REPORT", "--expects", "notes/report.md", "--deliver", "notes/report.md:docx")
        self.run_role("research-scout")
        self.assertIn("status: done", self.state("l1"))
        self.assertEqual(0, len(MockMattermost.files))  # completion is NOT final audit approval
        self.audit("l1")
        self.board("deliver", str(self.paper), "notes/report.md:docx", "--thread", "p" * 26)
        self.assertEqual(1, len(MockMattermost.files))
        data = next(iter(MockMattermost.files.values()))
        self.assertEqual((self.paper / "notes/report.docx").read_bytes(), data)
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            self.assertIn("1", z.read("word/document.xml").decode())
        posted = [p for p in MockMattermost.posts if p.get("file_ids")]
        self.assertTrue(posted and "verified" in posted[0]["message"])

    def test_lead_delivers_committed_report_and_refuses_local_edits(self):
        self.task("l1", "research-scout", "REPORT", "--expects", "notes/report.md")
        self.run_role("research-scout")
        self.audit("l1")
        r = self.board("deliver", str(self.paper), "notes/report.md:docx", "notes/report.md", "--thread", "p" * 26)
        self.assertIn("delivered and verified", r.stdout)
        self.assertEqual(2, len(MockMattermost.files))
        self.assertTrue(all(p["root_id"] == "p" * 26 for p in MockMattermost.posts if p.get("file_ids")))
        (self.paper / "notes/report.md").write_text("edited", encoding="utf-8")
        self.assertNotEqual(0, self.board("deliver", str(self.paper), "notes/report.md", check=False).returncode)

    def test_bad_deliver_spec_rejected(self):
        r = self.board("new", str(self.paper), "--id", "x", "--assignee", "research-worker", "--body", "b",
                       "--deliver", "paper/main.pdf:docx", check=False)
        self.assertNotEqual(0, r.returncode)


# The retry delays are minutes in production; exercise the retry path in-process with them shortened.
def _load_board():
    spec = importlib.util.spec_from_file_location("research_board_under_test", BOARD)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    sys.modules["research_board_under_test"] = mod
    return mod


class RetryTests(Base):
    def test_transient_failure_retried(self):
        rb = _load_board()
        rb.RETRY_DELAYS = [0]
        os.environ.update({k: v for k, v in self.env.items() if k in ("STUB_LOG", "HERMES_HOME")})
        rb.TEAM_HOME = self.home
        rb.MANIFEST = self.tmp / "manifest.json"
        self.task("w1", "research-worker", "FLAKY WRITE-PAPER")
        clone = self.tmp / "clone"; git("clone", "-q", "-c", "core.autocrlf=false", str(self.home / "boards/p1.git"), str(clone))
        rb.git_identity(clone, "research-worker")
        p = clone / ".tasks/w1.md"
        args = type("A", (), dict(role="research-worker", profile=None, hermes=str(self.hermes), yolo=False,
                                  heartbeat=600, task_timeout=600))()
        self.assertTrue(rb.claim(clone, p, "me"))
        self.assertEqual('', rb.git(clone, 'status', '--porcelain', '--', '.tasks').stdout.strip())
        rb.execute(args, clone, p, "me")
        self.assertEqual(2, len(self.calls()))
        self.assertIn("status: done", self.state("w1"))


if __name__ == "__main__":
    unittest.main()

"""Exercise Codex app-server policy on POSIX with a local Responses fixture.

Run with python3 scripts/probe-codex-hook-policy.py. Requires codex on PATH.
Each server gets a fresh config directory, no credentials and a fixed local model.
"""

import argparse
import asyncio
import errno
import json
import os
import pty
import select
import shutil
import sys
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

GATE = """printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"fixture denied"}}'"""
# Pre-existing approval fixture for the literal above on Codex 0.171.0.
# Never copy provider-reported hashes into the operator's trust store.
REVIEWED_KEY = "/<session-flags>/config.toml:pre_tool_use:0:0"
REVIEWED_HASH = "sha256:3b3bc375876512468f0c83fd8202ea81354e2264a82331276d1ab56088d9c498"
COMMAND = "printf ran > marker; exit 7"


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


class Model(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if getattr(self.server, "require_single_thread", False):
            names = {tool.get("name") for tool in request.get("tools", [])}
            if names & {"spawn_agent", "send_input", "wait_agent"}:
                self.send_error(500, "policy turn exposed delegation tools")
                return
        self.server.requests += 1
        number = self.server.requests
        time.sleep(getattr(self.server, "delay", 0))
        response_id = f"response-{number}"
        had_tool_result = any(part.get("type") == "function_call_output"
                              and part.get("call_id") == "fixture-call"
                              for part in request.get("input", []) if isinstance(part, dict))
        if not had_tool_result:
            item = {"type": "function_call", "call_id": "fixture-call", "name": "exec_command",
                    "arguments": json.dumps({"cmd": COMMAND, "login": False})}
        else:
            item = {"type": "message", "role": "assistant", "id": "answer",
                    "content": [{"type": "output_text", "text": "Finished."}]}
        events = [
            {"type": "response.created", "response": {"id": response_id}},
            {"type": "response.output_item.done", "item": item},
            {"type": "response.completed", "response": {"id": response_id,
             "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}}},
        ]
        body = "".join(f"data: {json.dumps(event)}\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class AppServer:
    def __init__(self, process):
        self.process = process
        self.request_id = 0
        self.notifications = []

    async def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        await self.process.stdin.drain()

    async def read(self):
        line = await self.process.stdout.readline()
        check(line, "Codex closed stdout before replying")
        message = json.loads(line)
        if "method" in message:
            check("id" not in message, "unexpected server request")
            self.notifications.append(message)
        return message

    async def request(self, method, params):
        self.request_id += 1
        await self.send({"id": self.request_id, "method": method, "params": params})
        while True:
            message = await self.read()
            if message.get("id") == self.request_id:
                check("result" in message, f"{method} failed: {message.get('error')}")
                return message["result"]

    async def inspect(self, work, gate):
        config = {} if gate is None else {"hooks": {"PreToolUse": [
            {"matcher": "^Bash$", "hooks": [{"type": "command", "command": gate}]}]}}
        result = await self.request("thread/start", {"cwd": str(work), "ephemeral": True,
            "sandbox": "workspace-write", "approvalPolicy": "never", "config": config})
        thread = result["thread"]["id"]
        inventory = await self.request("hooks/list", {"threadId": thread})
        row, = inventory["data"]
        check(not row["errors"] and not row["warnings"], "incomplete hook inventory")
        ambient = {h["command"]: h["trustStatus"] for h in row["hooks"] if h["source"] == "user"}
        check(ambient == {"exit 2": "untrusted", ":": "trusted"}, "ambient review state changed")
        supplied = [h for h in row["hooks"] if h["source"] == "sessionFlags"]
        if gate is None:
            check(not supplied, "previous thread's gate leaked into a new thread")
            return thread, None
        actual, = supplied
        check(actual["command"] == gate and actual["key"] == REVIEWED_KEY
              and actual["enabled"] and actual["async"] is False
              and actual["eventName"] == "preToolUse" and actual["matcher"] == "^Bash$",
              "requested synchronous gate missing from thread inventory")
        return thread, actual

    async def turn(self, thread):
        self.notifications.clear()
        result = await self.request("turn/start", {"threadId": thread, "input": [
            {"type": "text", "text": "Run the fixture.", "text_elements": []}]})
        turn = result["turn"]["id"]
        def finished(message):
            params = message["params"]
            return (message["method"] == "turn/completed" and params["threadId"] == thread
                    and params["turn"]["id"] == turn)
        while not any(finished(m) for m in self.notifications):
            await self.read()
        terminal, = [m for m in self.notifications if finished(m)]
        check(terminal["params"]["turn"]["status"] == "completed", "turn failed")
        return [m for m in self.notifications if m["params"].get("threadId") == thread
                and m["params"].get("turnId") == turn]


async def exercise(root, model, reviewed):
    config = root / "config"
    work = root / "project"
    config.mkdir()
    work.mkdir()
    config_file = config / "config.toml"
    ambient_key = f"{config_file.resolve()}:pre_tool_use:0:1"
    contents = f'''model = "gpt-5.4"
model_provider = "fixture"
[model_providers.fixture]
name = "loopback"
base_url = "http://127.0.0.1:{model.server_port}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0

[[hooks.PreToolUse]]
matcher = "^Bash$"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "exit 2"
[[hooks.PreToolUse.hooks]]
type = "command"
command = ":"

[hooks.state.{json.dumps(ambient_key)}]
trusted_hash = "sha256:bdc318cee0a3f6676683353dcfece8ff27b1c0732338f93048dd239d8414ac9e"
'''
    if reviewed:
        contents += f'\n[hooks.state."{REVIEWED_KEY}"]\ntrusted_hash = "{REVIEWED_HASH}"\n'
    config_file.write_text(contents)
    env = {k: os.environ[k] for k in ("PATH", "TMPDIR", "LANG") if k in os.environ}
    log_path = root / "codex-stderr"
    with log_path.open("wb") as log:
        process = await asyncio.create_subprocess_exec(
            "codex", "app-server", "--stdio", cwd=work,
            env={**env, "CODEX_HOME": str(config)}, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=log, limit=2**20)
    app = AppServer(process)
    try:
        await app.request("initialize", {"clientInfo": {"name": "baikai-hook-probe",
                          "version": "1"}, "capabilities": None})
        await app.send({"method": "initialized"})
        thread, gate = await app.inspect(work, GATE)
        if not reviewed:
            check(gate["trustStatus"] == "untrusted" and model.requests == 0, "expected review")
            print("Fresh hook requires review before the first model request.")
            return
        check(gate["trustStatus"] == "trusted" and gate["currentHash"] == REVIEWED_HASH,
              "installed Codex did not recognize the fixed approval fixture")
        events = await app.turn(thread)
        hooks = [m["params"]["run"] for m in events if m["method"] == "hook/completed"]
        check(any(h["status"] == "completed" and h["source"] == "user" for h in hooks),
              "operator's reviewed hook did not run alongside the caller's gate")
        blocked, = [h for h in hooks if h["eventName"] == "preToolUse" and h["source"] == "sessionFlags"]
        check(blocked["status"] == "blocked" and blocked["source"] == "sessionFlags"
              and not (work / "marker").exists(), "denial evidence or enforcement missing")
        print("Reviewed gate blocked the call. Turn completed, marker absent.")
        before = model.requests
        _, changed = await app.inspect(work, GATE + " ")
        check(changed["trustStatus"] == "modified" and model.requests == before,
              "changed policy did not require fresh review")
        print("Changed hook requires review before another model request.")
        plain, _ = await app.inspect(work, None)
        events = await app.turn(plain)
        commands = [m["params"]["item"] for m in events if m["method"] == "item/completed"
                    and m["params"]["item"]["type"] == "commandExecution"]
        command, = commands
        check(command["status"] == "failed" and command["exitCode"] == 7
              and (work / "marker").read_text() == "ran"
              and [m["params"]["run"]["status"] for m in events if m["method"] == "hook/completed"] == ["completed"],
              "control command did not run and fail normally")
        print("Fresh thread ran the command and reported exit 7. No hook denial.")
    except Exception as error:
        detail = log_path.read_text(errors="replace")[-1500:].strip()
        if detail:
            raise RuntimeError(f"Codex diagnostics: {detail}") from error
        raise
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 4)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
        check(config_file.read_text() == contents, "probe changed the fixture's trust configuration")


def confirm_review(binary, work, hooks, env, reply):
    master, slave = pty.openpty()
    spec = [binary, "agent", "review-codex-hooks", str(hooks)]
    with subprocess.Popen(spec, cwd=work, env=env, stdin=slave, stdout=slave, stderr=slave) as process:
        os.close(slave)
        output = bytearray()
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.25)
                if not ready:
                    continue
                try:
                    chunk = os.read(master, 4096)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
                if reply is not None and b"Type yes" in output:
                    os.write(master, reply + b"\n")
                    reply = None
            else:
                raise TimeoutError("Baikai Codex hook review exceeded 15 seconds")
            return process.wait(timeout=5), output.decode()
        finally:
            if process.poll() is None:
                process.terminate()
            os.close(master)


def exercise_cli(binary, root, model):
    model.requests = 0
    model.require_single_thread = True
    work, user_config = root / "workspace", root / "codex"
    work.mkdir()
    user_config.mkdir()
    config = user_config / "config.toml"
    initial = f'''model = "gpt-5.4"
model_provider = "fixture"
[model_providers.fixture]
name = "loopback"
base_url = "http://127.0.0.1:{model.server_port}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
'''
    config.write_text(initial)
    env = {"PATH": os.environ["PATH"], "CODEX_HOME": str(user_config),
           "HOME": str(root), "TMPDIR": str(root)}
    jobs = root / "agents.kdl"
    jobs.write_text('''jobs {
  policy {
    provider "codex"
    working-dir "."
    safety {
      capability "edit-workspace"
    }
  }
}
''')
    hooks = work / "caller hooks.json"

    def set_hook(command):
        hooks.write_text(json.dumps({"hooks": {"PreToolUse": [
            {"matcher": "^Bash$", "hooks": [{"type": "command", "command": command}]}]}}))

    def run_job(*extra):
        args = ["agent", "run", "policy", "--config", str(jobs), "--prompt", "Run the fixture.",
                "--codex-hooks", str(hooks), "--json", *extra]
        return subprocess.run([binary, *args], cwd=work, env=env, check=False,
                              text=True, capture_output=True, timeout=15)

    set_hook(GATE)
    blocked = run_job()
    check(blocked.returncode == 77 and "review-codex-hooks" in blocked.stdout
          and model.requests == 0 and config.read_text() == initial,
          f"fresh policy should require review: {blocked.stdout} {blocked.stderr}")
    refused, preview = confirm_review(binary, work, hooks, env, b"no")
    check(refused == 77 and "Command" in preview and config.read_text() == initial,
          f"review decline did not preserve trust state: {preview}")
    reviewed, preview = confirm_review(binary, work, hooks, env, b"yes")
    check(reviewed == 0 and "Command" in preview and "trusted_hash" in config.read_text()
          and model.requests == 0, f"first review failed: {preview}")
    saved = config.read_bytes()

    for requests in (2, 4):
        result = run_job()
        check(result.returncode == 0, f"reviewed run failed: {result.stdout} {result.stderr}")
        envelope = json.loads(result.stdout)
        check(envelope["stdout"] == "Finished.\n" and len(envelope["blockedHooks"]) == 1
              and model.requests == requests and not (work / "marker").exists()
              and config.read_bytes() == saved, "reviewed run lost enforcement or evidence")
    set_hook(GATE + " ")
    changed = run_job()
    check(changed.returncode == 77 and "review-codex-hooks" in changed.stdout
          and model.requests == 4 and config.read_bytes() == saved,
          "changed policy should require review again")

    set_hook(GATE)
    codex = shutil.which("codex")
    proxy = root / "codex-missing-evidence"
    proxy.write_text(f'''#!{sys.executable}
import json
import subprocess
import sys

with subprocess.Popen([{codex!r}, *sys.argv[1:]], stdin=sys.stdin,
                      stdout=subprocess.PIPE, stderr=sys.stderr) as app:
    for frame in app.stdout:
        if json.loads(frame).get("method") != "hook/completed":
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()
    sys.exit(app.wait())
''')
    proxy.chmod(0o755)
    incomplete = run_job("--set", f"executable={proxy}")
    check(incomplete.returncode == 77 and "without complete hook evidence" in incomplete.stdout
          and model.requests == 6 and not (work / "marker").exists()
          and config.read_bytes() == saved,
          f"missing completion event was treated as success: {incomplete.stdout} {incomplete.stderr}")

    with ThreadPoolExecutor(max_workers=2) as concurrent:
        results = [concurrent.submit(run_job) for _ in range(2)]
        parallel = [future.result() for future in results]
    check(all(result.returncode == 0 for result in parallel), "concurrent reviewed runs failed")
    streams = [json.loads(result.stdout)["blockedHooks"] for result in parallel]
    check(all(len(stream) == 1 for stream in streams)
          and len({stream[0]["threadId"] for stream in streams}) == 2
          and config.read_bytes() == saved and not (work / "marker").exists(),
          "concurrent reviewed runs lost thread attribution")

    set_hook(":")
    reviewed, preview = confirm_review(binary, work, hooks, env, b"yes")
    check(reviewed == 0, f"control review failed: {preview}")
    result = run_job()
    check(result.returncode == 0 and json.loads(result.stdout)["blockedHooks"] == []
          and (work / "marker").read_text() == "ran",
          f"ordinary command exit was confused with refusal: {result.stdout} {result.stderr}")
    model.delay = 3
    try:
        timed = run_job("--set", "timeout=1s")
    finally:
        model.delay = 0
    check(timed.returncode == 75 and "timed out" in timed.stdout,
          f"reviewed run did not preserve the job timeout: {timed.stdout} {timed.stderr}")
    check(json.loads(timed.stdout)["outcome"] == "failed", "timeout was represented as success")
    print("Baikai CLI passed review, repeat, modified hook rejection, incomplete evidence, concurrent attribution, exit-7 control and timeout.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baikai", type=Path, help="also exercise this Baikai executable")
    args = parser.parse_args()
    subprocess.run(["codex", "--version"], check=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
        server.requests = 0
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for reviewed in (False, True):
                with tempfile.TemporaryDirectory() as directory:
                    asyncio.run(asyncio.wait_for(exercise(Path(directory), server, reviewed), 45))
            if args.baikai:
                with tempfile.TemporaryDirectory() as directory:
                    exercise_cli(str(args.baikai.resolve()), Path(directory).resolve(), server)
        finally:
            server.shutdown()
            worker.join()

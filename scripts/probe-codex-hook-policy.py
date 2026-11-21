"""Exercise Codex app-server policy on POSIX with a local Responses fixture.

Run with python3 scripts/probe-codex-hook-policy.py. Requires codex on PATH.
Each server gets a fresh config directory, no credentials and a fixed local model.
"""

import asyncio
import json
import os
import subprocess
import tempfile
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
        self.rfile.read(int(self.headers["Content-Length"]))
        self.server.requests += 1
        number = self.server.requests
        response_id = f"response-{number}"
        if number % 2:
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
        self.wfile.write(body)


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


if __name__ == "__main__":
    subprocess.run(["codex", "--version"], check=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
        server.requests = 0
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for reviewed in (False, True):
                with tempfile.TemporaryDirectory() as directory:
                    asyncio.run(asyncio.wait_for(exercise(Path(directory), server, reviewed), 45))
        finally:
            server.shutdown()
            worker.join()

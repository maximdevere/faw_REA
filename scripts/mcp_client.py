"""Small stdio MCP client shared by the CLI test and local web workbench."""
from collections import deque
import json
import queue
import subprocess
import threading
import time

class Client:
    def __init__(self, command, timeout):
        self.timeout = timeout
        self.sequence = 0
        self.messages = queue.Queue()
        self.errors = deque(maxlen=60)
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1)
        threading.Thread(target=self._stdout, daemon=True).start()
        threading.Thread(target=self._stderr, daemon=True).start()

    def _stdout(self):
        try:
            for line in self.process.stdout:
                if not line.strip():
                    continue
                try:
                    self.messages.put(json.loads(line))
                except json.JSONDecodeError:
                    self.messages.put(RuntimeError("Non-JSON output on MCP stdout"))
        finally:
            self.messages.put(EOFError("MCP process stdout closed"))

    def _stderr(self):
        for line in self.process.stderr:
            self.errors.append(line.rstrip())

    def send(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def request(self, method, parameters):
        self.sequence += 1
        identity = self.sequence
        self.send({"jsonrpc": "2.0", "id": identity, "method": method, "params": parameters})
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(method + " timed out")
            try:
                message = self.messages.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError(method + " timed out") from None
            if isinstance(message, Exception):
                raise message
            if message.get("id") == identity and ("result" in message or "error" in message):
                if "error" in message:
                    raise RuntimeError(method + ": " + json.dumps(message["error"]))
                return message["result"]
            if "method" in message and "id" in message:
                if message["method"] == "ping":
                    self.send({"jsonrpc": "2.0", "id": message["id"], "result": {}})
                else:
                    self.send({"jsonrpc": "2.0", "id": message["id"], "error":
                               {"code": -32601, "message": "Client capability not enabled"}})

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(name + ": " + json.dumps(result.get("content", []))[:4000])
        data = result.get("structuredContent")
        if data is None:
            for content in result.get("content", []):
                if content.get("type") == "text":
                    try:
                        data = json.loads(content["text"])
                        break
                    except json.JSONDecodeError:
                        continue
        if data is None:
            raise RuntimeError(name + " returned no structured JSON")
        return data

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)


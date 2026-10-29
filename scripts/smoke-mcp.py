#!/usr/bin/env python3
"""Real stdio MCP test: handshake, tool discovery, static native/APK analysis."""
import argparse
from collections import deque
import json
from pathlib import Path
import queue
import subprocess
import sys
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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="rea-toolbox")
    parser.add_argument("--inside", action="store_true", help="Run rea directly inside this container")
    parser.add_argument("--timeout", type=float, default=1200)
    parser.add_argument("--apk", help="Container path to an optional APK fixture")
    parser.add_argument("--apk-class", default="io.appium.android.apis.ApiDemos")
    parser.add_argument("--apk-method", default="onCreate")
    parser.add_argument("--report", type=Path, default=Path("results/smoke-mcp.json"))
    args = parser.parse_args()
    command = ["rea", "mcp"] if args.inside else ["docker", "exec", "-i", "-w", "/work", args.container, "rea", "mcp"]
    client = Client(command, args.timeout)
    report = {"status": "running", "scope": "static-only", "checks": []}
    opened = False
    try:
        info = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "faw-rea-smoke", "version": "0.1.0"}})
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        report["server"] = info.get("serverInfo")
        names = set()
        cursor = None
        while True:
            page = client.request("tools/list", {} if cursor is None else {"cursor": cursor})
            names.update(tool["name"] for tool in page.get("tools", []))
            cursor = page.get("nextCursor")
            if not cursor:
                break
        required = {"binary_session", "open_binary", "close_binary", "search_strings",
                    "procedure_pseudo_code", "export_evidence_bundle", "inspect_android_package",
                    "inspect_android_method", "decode_android_resources"}
        if not required <= names:
            raise RuntimeError("Missing MCP tools: " + ", ".join(sorted(required - names)))
        report["tool_count"] = len(names)
        report["checks"].append("initialize_and_paginated_tools_list")
        client.tool("binary_session", {"expected_package_version": "6.8.0"})
        client.tool("open_binary", {"path": "/opt/toolbox/fixtures/native-fixture", "provider_id": "ghidra"})
        opened = True
        evidence = client.tool("search_strings", {"pattern": "REA_STATIC_FIXTURE_MARKER_2026", "mode": "literal"})
        rows = evidence.get("normalized_result")
        if not isinstance(rows, list) or not any(row.get("value") == "REA_STATIC_FIXTURE_MARKER_2026" for row in rows):
            raise RuntimeError("Static fixture marker not found in the actual string result rows")
        report["checks"].append("ghidra_known_string")
        pseudocode = client.tool("procedure_pseudo_code", {"procedure": "fixture_marker"})
        if "REA_STATIC_FIXTURE_MARKER_2026" not in json.dumps(pseudocode.get("normalized_result")):
            raise RuntimeError("Known function pseudocode does not contain the independent marker")
        report["checks"].append("ghidra_known_function_pseudocode")
        if args.apk:
            package = client.tool("inspect_android_package", {"path": args.apk})
            if "io.appium.android.apis" not in json.dumps(package.get("normalized_result")):
                raise RuntimeError("APK fixture package identity not found")
            report["checks"].append("jadx_package")
            method = client.tool("inspect_android_method", {"path": args.apk, "class_name": args.apk_class,
                                                         "method_name": args.apk_method})
            if args.apk_method not in json.dumps(method.get("normalized_result")):
                raise RuntimeError("APK fixture method not found")
            report["checks"].append("jadx_method")
            client.tool("decode_android_resources", {"path": args.apk, "include_strings": True})
            report["checks"].append("apktool_resources")
        else:
            report["android"] = "not_run_no_apk_fixture"
        export_path = "/results/smoke-evidence-" + str(time.time_ns()) + ".json"
        client.tool("export_evidence_bundle", {"path": export_path})
        report["evidence_container_path"] = export_path
        client.tool("close_binary", {})
        opened = False
        report["checks"].append("evidence_export_and_close")
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        report["stderr_tail"] = list(client.errors)
    finally:
        if opened:
            try:
                client.tool("close_binary", {})
            except Exception:
                pass
        client.close()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=True, indent=2))
    return 0 if report["status"] == "passed" else 1

if __name__ == "__main__":
    raise SystemExit(main())

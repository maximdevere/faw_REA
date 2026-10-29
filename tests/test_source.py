#!/usr/bin/env python3
"""Validate release inputs without running any target or requiring Docker."""
import fnmatch
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fetch_artifacts", ROOT / "scripts/fetch-artifacts.py")
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)

class SourceTests(unittest.TestCase):
    def test_artifact_pins(self):
        manifest = json.loads((ROOT / "versions.lock.json").read_text())
        self.assertIn("@sha256:", manifest["base_image"])
        self.assertIn(manifest["base_image"], (ROOT / "Dockerfile").read_text())
        for item in manifest["artifacts"] + manifest.get("fixtures", []):
            self.assertRegex(item["sha256"], r"^[a-f0-9]{64}$")
            self.assertTrue(item["url"].startswith("https://"))
            self.assertEqual(Path(item["filename"]).name, item["filename"])

    def test_npm_lock_identity(self):
        manifest = json.loads((ROOT / "versions.lock.json").read_text())
        lock = json.loads((ROOT / "package-lock.json").read_text())
        rea = lock["packages"]["node_modules/rea-agents"]
        self.assertEqual(rea["version"], manifest["npm"]["rea"])
        self.assertEqual(rea["integrity"], manifest["npm"]["rea_integrity"])
        pty = lock["packages"]["node_modules/@lydell/node-pty-linux-x64"]
        self.assertEqual(pty["version"], "1.1.0")
        self.assertFalse(pty.get("optional", False))

    def test_mcp_command(self):
        config = json.loads((ROOT / "config/opencode.example.json").read_text())
        command = config["mcp"]["rea"]["command"]
        self.assertEqual(command, ["docker","exec","-i","-w","/work","rea-toolbox","rea","mcp"])
        self.assertNotIn("-t", command)
        for tool in ("start_frida_session","start_gdb_session","start_adb_app",
                     "capture_process_scenario","observe_javascript_runtime"):
            self.assertTrue(any(fnmatch.fnmatchcase("rea_" + tool, pattern)
                                for pattern, value in config["tools"].items() if value is False))
        for tool in ("open_binary","search_strings","procedure_pseudo_code","inspect_android_method"):
            self.assertFalse(any(fnmatch.fnmatchcase("rea_" + tool, pattern)
                                 for pattern, value in config["tools"].items() if value is False))

    def test_file_download_checksums(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "source"
            source.write_bytes(b"not a target; download-integrity fixture")
            item = {"filename":"test.bin","url":source.as_uri(),
                    "sha256":hashlib.sha256(source.read_bytes()).hexdigest()}
            destination = directory / "download"
            out = fetch.download(item, destination)
            self.assertEqual(out.read_bytes(), source.read_bytes())
            out.write_bytes(b"corrupted cache")
            with self.assertRaises(ValueError):
                fetch.download(item, destination)

    def test_scripts_lf_and_utf8(self):
        for pattern in ("docker/*","scripts/*.sh","scripts/*.py"):
            for path in ROOT.glob(pattern):
                body = path.read_bytes()
                self.assertNotIn(b"\r", body, str(path))
                self.assertFalse(body.startswith(b"\xef\xbb\xbf"), str(path))

    def test_compose_scope(self):
        text=(ROOT/"compose.yaml").read_text()
        self.assertIn("127.0.0.1:",text)
        self.assertIn("REA_WEB_PORT",text)
        self.assertIn("read_only: true",text)
        self.assertNotIn("docker.sock",text)
        self.assertNotIn("privileged:",text)

    def test_truncated_http_download_resumes(self):
        import http.server
        import threading
        data=b"static download resume fixture" * 200
        calls=[]
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requested=self.headers.get("Range")
                calls.append(requested)
                if requested is None:
                    self.send_response(200)
                    self.send_header("Content-Length",str(len(data)))
                    self.end_headers()
                    self.wfile.write(data[:137])
                    self.close_connection=True
                else:
                    offset=int(requested.split("=")[1].split("-")[0])
                    self.send_response(206)
                    self.send_header("Content-Length",str(len(data)-offset))
                    self.send_header("Content-Range",f"bytes {offset}-{len(data)-1}/{len(data)}")
                    self.end_headers()
                    self.wfile.write(data[offset:])
            def log_message(self,*args):
                pass
        server=http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                item={"filename":"resumed.bin",
                      "url":"http://127.0.0.1:"+str(server.server_port)+"/fixture",
                      "sha256":hashlib.sha256(data).hexdigest()}
                path=fetch.download(item,Path(temporary))
                self.assertEqual(path.read_bytes(),data)
                self.assertEqual(calls,[None,"bytes=137-"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Exercise the running web workbench with real static-analysis engines."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import time
from urllib.parse import quote
import urllib.request
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8787")
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    # Local workbench requests should never inherit an outbound HTTP proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    token = ""
    report = {"ok": False, "checks": [], "jobs": []}

    def request(path, body=None, headers=None):
        headers = dict(headers or {})
        if isinstance(body, dict):
            body = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if body is not None:
            headers["X-REA-CSRF"] = token
        req = urllib.request.Request(base + path, data=body, headers=headers)
        with opener.open(req, timeout=60) as response:
            return response.read()

    def api(path, body=None, headers=None):
        return json.loads(request(path, body, headers))

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        report["checks"].append(name)
        print("PASS " + name, flush=True)

    def analyze(artifact, profile, words, expected_tools, marker=None):
        job = api("/api/jobs", {"artifact_id": artifact["id"], "profile": profile,
                                "keywords": words})
        identity = job["id"]
        deadline = time.monotonic() + args.timeout
        previous = None
        while job["status"] in ("queued", "running"):
            if time.monotonic() >= deadline:
                raise TimeoutError("Web analysis did not complete: " + identity)
            if previous != job["progress"]:
                print("Web " + identity[:8] + " " + str(job["progress"]) + "%", flush=True)
                previous = job["progress"]
            time.sleep(1)
            job = api("/api/jobs/" + identity)
        report["jobs"].append({"id": identity, "profile": job["profile"],
                               "status": job["status"], "finding_count": job["finding_count"]})
        if job["status"] != "completed":
            raise AssertionError("Web analysis failed: " + str(job.get("error", job["stage"])))
        check("web_" + job["profile"] + "_completed", job["progress"] == 100)
        raw = api("/api/jobs/" + identity + "/raw")
        check("web_" + job["profile"] + "_real_tools", set(expected_tools).issubset(raw))
        if marker:
            check("web_native_known_string", any(marker in row["value"] for row in job["findings"]))
        with zipfile.ZipFile(io.BytesIO(request("/api/jobs/" + identity + "/download"))) as archive:
            check("web_" + job["profile"] + "_download", {"summary.json", "raw.json", "evidence.json"}.issubset(archive.namelist()))
            check("web_" + job["profile"] + "_summary", json.loads(archive.read("summary.json"))["id"] == identity)

    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                if api("/health")["ok"]:
                    break
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)
        token = api("/api/session")["token"]
        check("web_tools_ready", api("/api/status")["ready"])
        check("web_page_and_signature", b"dyushine" in request("/"))
        demo = api("/api/demo", {})
        analyze(demo, "native", "REA_STATIC_FIXTURE_MARKER_2026",
                ["open_binary", "binary_overview", "search_strings"], "REA_STATIC_FIXTURE_MARKER_2026")
        if args.apk:
            body = args.apk.read_bytes()
            artifact = api("/api/uploads", body, {"Content-Type": "application/octet-stream",
                            "X-Filename": quote(args.apk.name)})
            check("web_upload_integrity", artifact["sha256"] == hashlib.sha256(body).hexdigest())
            analyze(artifact, "auto", "ApiDemos", ["inspect_android_package", "decode_android_resources"])
        report["ok"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

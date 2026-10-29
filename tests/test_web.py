#!/usr/bin/env python3
"""Test local web API boundaries and static job orchestration."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile
from http.server import ThreadingHTTPServer

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("web_server",ROOT/"web/server.py")
web=importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)

class FakeClient:
    def __init__(self):
        self.calls=[]
    def request(self,*args): return {}
    def send(self,*args): pass
    def close(self): pass
    def tool(self,name,args):
        self.calls.append(name)
        if name=="search_strings":
            return {"normalized_result":[{"value":"fixture_api_key","address":"0x1000"}]}
        if name=="export_evidence_bundle":
            Path(args["path"]).write_text('{"test_fixture":true}',encoding="utf-8")
        return {"normalized_result":{}}

class WebTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.root=Path(self.temporary.name)
        self.client=FakeClient()
        self.app=web.Workbench(self.root/"uploads",self.root/"results",
                               client_factory=lambda:self.client,start_worker=False)
        self.server=ThreadingHTTPServer(("127.0.0.1",0),web.Handler)
        self.server.workbench=self.app
        self.server.allowed_hosts={"localhost","127.0.0.1"}
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.base="http://127.0.0.1:"+str(self.server.server_port)
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=5)
        self.temporary.cleanup()
    def request(self,path,body=None,headers=None):
        request=urllib.request.Request(self.base+path,data=body,headers=headers or {})
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request,timeout=5) as response:
            return response.status,response.headers,response.read()
    def upload(self):
        data=b"static fixture; api_key"
        status,headers,body=self.request("/api/uploads",data,{
            "Content-Type":"application/octet-stream","X-Filename":"..%2F..%2Ffixture.bin",
            "X-REA-CSRF":self.app.token})
        self.assertEqual(status,201)
        artifact=json.loads(body)
        self.assertEqual(Path(artifact["container_path"]).parent,self.app.uploads)
        self.assertEqual(artifact["sha256"],hashlib.sha256(data).hexdigest())
        return artifact
    def test_upload_csrf_and_origin(self):
        for headers in ({},{"X-REA-CSRF":self.app.token,"Origin":"https://untrusted.invalid"}):
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request("/api/uploads",b"test",headers)
            self.assertEqual(error.exception.code,403)
        self.assertEqual(self.app.list_files(),[])
    def test_upload_traversal_is_a_generated_basename(self):
        artifact=self.upload()
        self.assertTrue(Path(artifact["container_path"]).is_file())
        self.assertEqual(artifact["filename"],"fixture.bin")
    def test_job_uses_static_mcp_and_exports_zip(self):
        artifact=self.upload()
        job=self.app.create_job(artifact["id"],"native","api_key")
        self.app.run_job(job["id"])
        finished=self.app.get_job(job["id"])
        self.assertEqual(finished["status"],"completed")
        self.assertEqual(finished["finding_count"],1)
        self.assertEqual(set(self.client.calls),{"open_binary","binary_overview","search_strings",
                                               "xrefs","export_evidence_bundle","close_binary"})
        status,headers,body=self.request("/api/jobs/"+job["id"]+"/download")
        self.assertEqual(headers["Content-Type"],"application/zip")
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            self.assertEqual(set(archive.namelist()),{"summary.json","raw.json","evidence.json"})
    def test_profile_and_artifact_id_are_not_arbitrary_commands(self):
        artifact=self.upload()
        for identity,profile in (("../../etc/passwd","native"),([], "native"),(artifact["id"],"shell")):
            with self.assertRaises(ValueError):
                self.app.create_job(identity,profile,"")
        with self.assertRaises(KeyError):
            self.app.get_job("../../etc/passwd")
    def test_keyword_search_does_not_treat_queries_as_findings(self):
        value={"text":"nothing sensitive here","other":"a token-like candidate"}
        findings=web.scan_strings(value,["token"],"resources")
        self.assertEqual(len(findings),1)
        self.assertIn("other",findings[0]["location"])
    def test_pending_task_is_not_silently_reexecuted_after_restart(self):
        artifact=self.upload()
        job=self.app.create_job(artifact["id"],"native","api_key")
        reopened=web.Workbench(self.app.uploads,self.app.results,start_worker=False)
        self.assertEqual(reopened.get_job(job["id"])["status"],"interrupted")
    def test_static_page_and_no_arbitrary_file_route(self):
        status,headers,body=self.request("/")
        self.assertIn(b"FAW REA",body)
        self.assertIn(b"dyushine",body)
        self.assertIn("nosniff",headers["X-Content-Type-Options"])
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/../../etc/passwd")
        self.assertEqual(error.exception.code,404)

if __name__=="__main__":
    unittest.main(verbosity=2)

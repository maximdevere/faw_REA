#!/usr/bin/env python3
"""Local static-analysis workbench. No target execution or generic shell API."""
import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import mimetypes
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import sys
import threading
import time
import unicodedata
from urllib.parse import unquote, urlsplit
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from mcp_client import Client

STATIC = Path(__file__).parent / "static"
ID = re.compile(r"^[a-f0-9]{32}$")
PROFILES = {"auto", "native", "android", "javascript", "managed", "artifact"}
DEFAULT_WORDS = ["api_key", "secret", "token", "password"]
MAX_UPLOAD = 512 * 1024 * 1024

def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=True, indent=2), encoding="utf-8")
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()

def safe_name(value):
    value = unicodedata.normalize("NFC", value.replace("\\", "/").split("/")[-1])
    value = "".join(c for c in value if c.isprintable() and c not in '/\\:*?"<>|').strip(" .")
    return value[:120] or "sample.bin"

def keywords(value):
    values = [v.strip()[:64] for v in re.split(r"[,，\n]", str(value)) if v.strip()]
    return list(dict.fromkeys(values[:20])) or DEFAULT_WORDS

def scan_strings(value, words, source, maximum=150):
    found = []
    seen = set()
    visits = 0
    pending = [(value, source, 0)]
    while pending and len(found) < maximum and visits < 50000:
        current, location, depth = pending.pop()
        visits += 1
        if depth > 25:
            continue
        if isinstance(current, str):
            if any(word.casefold() in current.casefold() for word in words) and current not in seen:
                seen.add(current)
                found.append({"value":current[:4000], "location":location})
        elif isinstance(current, dict):
            pending.extend((v, location + "." + str(k), depth + 1) for k,v in reversed(list(current.items())[:5000]))
        elif isinstance(current, list):
            pending.extend((v, location + "[" + str(i) + "]", depth + 1) for i,v in reversed(list(enumerate(current[:5000]))))
    return found

class Workbench:
    def __init__(self, uploads, results, client_factory=None, start_worker=True):
        self.uploads = Path(uploads).resolve()
        self.results = Path(results).resolve()
        self.state = self.results / "web"
        self.jobs_root = self.state / "jobs"
        self.uploads.mkdir(parents=True, exist_ok=True)
        self.jobs_root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.token = secrets.token_urlsafe(32)
        self.client_factory = client_factory or (lambda: Client(["rea", "mcp"], 1200))
        self.files = {}
        self.jobs = {}
        self.pending = queue.Queue(maxsize=8)
        index = self.state / "uploads.json"
        if index.exists():
            for artifact in json.loads(index.read_text(encoding="utf-8")):
                if ID.fullmatch(artifact.get("id","")) and Path(artifact.get("container_path","")).is_file():
                    self.files[artifact["id"]] = artifact
        for path in sorted(self.jobs_root.glob("*/job.json"))[-300:]:
            try:
                job = json.loads(path.read_text(encoding="utf-8"))
                if not ID.fullmatch(job.get("id","")):
                    continue
                if job["status"] in ("queued","running"):
                    job.update(status="interrupted", stage="服务重启，任务已中断", error="任务未自动重跑，请重新发起分析。")
                    atomic_json(path, job)
                self.jobs[job["id"]] = job
            except (OSError, ValueError, KeyError):
                continue
        if start_worker:
            threading.Thread(target=self.worker, name="rea-static-worker", daemon=True).start()

    def register(self, path, filename, sha256, demo=False):
        artifact = {"id":uuid.uuid4().hex, "filename":filename, "container_path":str(path),
                    "size":Path(path).stat().st_size, "sha256":sha256, "created":time.time(), "demo":demo}
        with self.lock:
            self.files[artifact["id"]] = artifact
            atomic_json(self.state / "uploads.json", list(self.files.values()))
        return artifact

    def list_files(self):
        with self.lock:
            return sorted(self.files.values(), key=lambda x:x["created"], reverse=True)

    def list_jobs(self):
        with self.lock:
            return [{k:v for k,v in job.items() if k not in ("findings","logs","error")}
                    for job in sorted(self.jobs.values(),key=lambda x:x["created"],reverse=True)[:150]]

    def get_job(self, identity):
        if not ID.fullmatch(identity):
            raise KeyError("任务不存在")
        with self.lock:
            if identity not in self.jobs:
                raise KeyError("任务不存在")
            return json.loads(json.dumps(self.jobs[identity]))

    def update(self, identity, **changes):
        with self.lock:
            job = self.jobs[identity]
            job.update(changes)
            job["updated"] = time.time()
            atomic_json(self.jobs_root / identity / "job.json", job)

    def log(self, identity, message, progress=None):
        with self.lock:
            self.jobs[identity]["logs"].append({"time":time.time(), "message":message})
            fields={"stage":message}
            if progress is not None:
                fields["progress"]=progress
            self.update(identity, **fields)

    def create_job(self, artifact_id, profile, terms):
        if not isinstance(profile,str) or profile not in PROFILES:
            raise ValueError("不支持的分析类型")
        if not isinstance(artifact_id,str) or not ID.fullmatch(artifact_id):
            raise ValueError("请先选择一个已上传的样本")
        with self.lock:
            artifact = self.files.get(artifact_id)
            if artifact is None:
                raise ValueError("请先选择一个已上传的样本")
            if self.pending.full():
                raise ValueError("分析队列已满，请稍后再试")
            identity = uuid.uuid4().hex
            path = Path(artifact["container_path"])
            if profile == "auto":
                extension=path.suffix.lower()
                if extension==".apk": profile="android"
                elif extension in (".js",".mjs",".cjs",".asar"): profile="javascript"
                elif extension in (".zip",".ipa",".msix"): profile="artifact"
                else: profile="native"
            words=keywords(terms)
            job={"id":identity,"artifact_id":artifact_id,"filename":artifact["filename"],
                 "container_path":str(path),"profile":profile,"keywords":", ".join(words),
                 "created":time.time(),"updated":time.time(),"status":"queued","progress":0,
                 "stage":"等待静态分析","logs":[],"findings":[],"finding_count":0,"evidence_path":None}
            self.jobs[identity]=job
            atomic_json(self.jobs_root/identity/"job.json",job)
            self.pending.put_nowait(identity)
            return self.get_job(identity)

    def worker(self):
        while True:
            identity=self.pending.get()
            try:
                self.run_job(identity)
            except Exception as error:
                self.update(identity,status="failed",error=str(error),stage="分析未完成")
            finally:
                self.pending.task_done()

    def run_job(self, identity):
        job=self.get_job(identity)
        directory=self.jobs_root/identity
        directory.mkdir(parents=True,exist_ok=True)
        records={}
        client=None
        opened=False
        findings=[]
        self.update(identity,status="running",progress=3)
        self.log(identity,"正在连接本地 REA MCP",5)
        try:
            client=self.client_factory()
            client.request("initialize",{"protocolVersion":"2025-06-18","capabilities":{},
                                        "clientInfo":{"name":"faw-rea-web","version":"0.1.0"}})
            client.send({"jsonrpc":"2.0","method":"notifications/initialized"})
            def call(name,args):
                result=client.tool(name,args)
                records[name]=result
                atomic_json(directory/"raw.json",records)
                return result
            path=job["container_path"]
            words=keywords(job["keywords"])
            profile=job["profile"]
            if profile=="native":
                self.log(identity,"正在读取原生程序，使用 Ghidra 静态分析",12)
                call("open_binary",{"path":path,"provider_id":"ghidra"})
                opened=True
                call("binary_overview",{})
                self.log(identity,"正在搜索字符串与关键词线索",40)
                result=call("search_strings",{"pattern":"|".join(re.escape(w) for w in words),
                                             "mode":"regex","case_sensitive":False})
                rows=result.get("normalized_result") or []
                if not isinstance(rows,list):
                    raise ValueError("REA 返回的字符串清单格式不符合预期")
                for row in rows[:150]:
                    value=row.get("value")
                    if isinstance(value,str):
                        findings.append({"value":value[:4000],"location":"字符串 · "+str(row.get("address","未知地址"))})
                self.log(identity,"正在补充前几条线索的静态交叉引用",70)
                for i,row in enumerate(rows[:3]):
                    if row.get("address"):
                        try:
                            records["xrefs_"+str(i)]=client.tool("xrefs",{"address":row["address"]})
                        except Exception as error:
                            records["xrefs_"+str(i)]={"unavailable":str(error)}
            elif profile=="android":
                self.log(identity,"正在用 JADX 读取 APK 与 Manifest",15)
                call("inspect_android_package",{"path":path})
                self.log(identity,"正在用 Apktool 解码资源字符串",50)
                result=call("decode_android_resources",{"path":path,"include_strings":True})
                findings=scan_strings(result.get("normalized_result"),words,"资源")
                self.log(identity,"正在整理 Android 静态证据",78)
            elif profile=="javascript":
                self.log(identity,"正在静态读取 JavaScript / ASAR，不执行代码",20)
                result=call("analyze_javascript_application",{"input_path":path})
                findings=scan_strings(result.get("normalized_result"),words,"JavaScript")
                self.log(identity,"正在整理模块与关键词线索",78)
            elif profile=="managed":
                self.log(identity,"正在读取 .NET 元数据，不加载程序集",20)
                result=call("inspect_managed_artifact",{"path":path})
                findings=scan_strings(result.get("normalized_result"),words,".NET")
                self.log(identity,"正在整理托管程序集静态证据",78)
            else:
                self.log(identity,"正在建立静态文件清单",15)
                call("open_binary",{"path":path})
                opened=True
                result=call("inspect_artifact",{})
                findings=scan_strings(result.get("normalized_result"),words,"文件")
                self.log(identity,"正在整理文件与资源清单",78)
            self.update(identity,findings=findings,finding_count=len(findings))
            atomic_json(directory/"raw.json",records)
            self.log(identity,"正在导出分析证据",90)
            evidence=directory/"evidence.json"
            try:
                call("export_evidence_bundle",{"path":str(evidence)})
                if evidence.is_file():
                    self.update(identity,evidence_path=str(evidence))
            except Exception as error:
                self.log(identity,"REA 证据包未导出；结构化结果已保留")
                records["export_warning"]=str(error)
            atomic_json(directory/"raw.json",records)
            self.log(identity,"静态分析完成，候选线索仍需核实",100)
            self.update(identity,status="completed")
        except Exception as error:
            atomic_json(directory/"raw.json",records)
            self.update(identity,status="failed",error=str(error),stage="分析未完成，已保留现有结果")
            self.log(identity,"可以查看错误详情，或复制提示词交给 OpenCode")
        finally:
            if client is not None:
                if opened:
                    try: client.tool("close_binary",{})
                    except Exception: pass
                client.close()

    def status(self):
        tools=[
            {"name":"REA","initial":"R","description":"统一 CLI / MCP · 6.8.0","ready":bool(shutil.which("rea"))},
            {"name":"Ghidra","initial":"G","description":"原生程序静态分析 · 12.1.4","ready":os.access(os.environ.get("GHIDRA_INSTALL_DIR","/opt/ghidra")+"/support/analyzeHeadless",os.X_OK)},
            {"name":"JADX","initial":"J","description":"Android 代码与引用 · 0.7.1","ready":os.access(os.environ.get("REA_JADX_MCP_JAR","/opt/jadx/jadx-headless-mcp-0.7.1-all.jar"),os.R_OK)},
            {"name":"Apktool","initial":"A","description":"Manifest 与资源 · 3.0.3","ready":bool(shutil.which("apktool"))}]
        return {"ready":all(t["ready"] for t in tools),"tools":tools,"scope":"static-only"}

class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    server_version="FAW-REA/0.1"
    def setup(self):
        super().setup()
        self.connection.settimeout(180)
    def log_message(self,*args):
        return
    @property
    def app(self): return self.server.workbench
    def check_host(self):
        host=urlsplit("//"+self.headers.get("Host","")).hostname
        if host not in self.server.allowed_hosts:
            raise PermissionError("仅允许本地工作台访问")
    def check_write(self):
        self.check_host()
        origin=self.headers.get("Origin")
        if origin and origin!=("http://"+self.headers.get("Host")) and origin!=("https://"+self.headers.get("Host")):
            raise PermissionError("请求来源不匹配")
        if not hmac.compare_digest(self.headers.get("X-REA-CSRF",""),self.app.token):
            raise PermissionError("页面会话已过期，请刷新页面")
    def headers_common(self):
        self.send_header("X-Content-Type-Options","nosniff")
        self.send_header("X-Frame-Options","DENY")
        self.send_header("Referrer-Policy","no-referrer")
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
    def send(self,body,status=200,content_type="application/json; charset=utf-8",download=None):
        if not isinstance(body,bytes): body=json.dumps(body,ensure_ascii=True).encode()
        self.send_response(status)
        self.headers_common()
        self.send_header("Content-Type",content_type)
        self.send_header("Content-Length",str(len(body)))
        self.send_header("Connection","close")
        if download: self.send_header("Content-Disposition",'attachment; filename="'+download+'"')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection=True
    def body_json(self):
        length=int(self.headers.get("Content-Length","0"))
        if length<0 or length>65536: raise ValueError("请求内容过大")
        value=json.loads(self.rfile.read(length) or b"{}")
        if not isinstance(value,dict): raise ValueError("请求必须为 JSON 对象")
        return value
    def discard_small_rejected_body(self):
        # Avoid a connection reset hiding the HTTP rejection on small requests.
        # Never drain an untrusted large upload just to reject its credentials.
        try: length=int(self.headers.get("Content-Length","0"))
        except ValueError: return
        if 0<length<=65536:
            timeout=self.connection.gettimeout()
            try:
                self.connection.settimeout(1)
                self.rfile.read(length)
            except OSError:
                pass
            finally:
                self.connection.settimeout(timeout)
    def do_GET(self):
        try:
            self.check_host()
            route=urlsplit(self.path).path
            if route=="/health": return self.send({"ok":True})
            if route=="/api/session": return self.send({"token":self.app.token})
            if route=="/api/status": return self.send(self.app.status())
            if route=="/api/uploads": return self.send(self.app.list_files())
            if route=="/api/jobs": return self.send(self.app.list_jobs())
            if route=="/api/config":
                path=Path(__file__).parent/"opencode.example.json"
                if not path.is_file():
                    path=Path(__file__).resolve().parents[1]/"config/opencode.example.json"
                return self.send(json.loads(path.read_text(encoding="utf-8")))
            match=re.fullmatch(r"/api/jobs/([a-f0-9]{32})(?:/(raw|download))?",route)
            if match:
                identity,action=match.groups()
                job=self.app.get_job(identity)
                directory=self.app.jobs_root/identity
                if action=="raw":
                    path=directory/"raw.json"
                    return self.send(json.loads(path.read_text(encoding="utf-8")) if path.exists() else {})
                if action=="download":
                    archive=io.BytesIO()
                    with zipfile.ZipFile(archive,"w",zipfile.ZIP_DEFLATED) as output:
                        output.writestr("summary.json",json.dumps(job,ensure_ascii=False,indent=2))
                        for name in ("raw.json","evidence.json"):
                            if (directory/name).is_file(): output.write(directory/name,name)
                    return self.send(archive.getvalue(),content_type="application/zip",download="rea-"+identity[:8]+".zip")
                return self.send(job)
            routes={"/":"index.html","/style.css":"style.css","/app.js":"app.js"}
            if route in routes:
                path=STATIC/routes[route]
                return self.send(path.read_bytes(),content_type=mimetypes.guess_type(path.name)[0]+"; charset=utf-8")
            return self.send({"error":"页面不存在"},404)
        except PermissionError as error: self.send({"error":str(error)},403)
        except KeyError as error: self.send({"error":str(error)},404)
        except (OSError,ValueError) as error: self.send({"error":str(error)},400)
    def do_POST(self):
        try:
            try:
                self.check_write()
            except PermissionError as error:
                self.discard_small_rejected_body()
                return self.send({"error":str(error)},403)
            route=urlsplit(self.path).path
            if route=="/api/uploads":
                length=int(self.headers.get("Content-Length","0"))
                if length<=0 or length>MAX_UPLOAD: raise ValueError("文件必须大于 0 且不超过 512 MiB")
                filename=safe_name(unquote(self.headers.get("X-Filename","sample.bin")))
                path=self.app.uploads/(uuid.uuid4().hex+"_"+filename)
                temporary=path.with_suffix(path.suffix+".part")
                digest=hashlib.sha256()
                try:
                    with temporary.open("xb") as output:
                        remaining=length
                        while remaining:
                            block=self.rfile.read(min(1024*1024,remaining))
                            if not block: raise ValueError("上传中断，请重试")
                            output.write(block); digest.update(block); remaining-=len(block)
                    temporary.replace(path)
                    return self.send(self.app.register(path,filename,digest.hexdigest()),201)
                finally:
                    if temporary.exists(): temporary.unlink()
            if route=="/api/jobs":
                body=self.body_json()
                return self.send(self.app.create_job(body.get("artifact_id"),body.get("profile","auto"),body.get("keywords","")),201)
            if route=="/api/demo":
                self.body_json()
                path=Path(os.environ.get("REA_WEB_DEMO","/opt/toolbox/fixtures/native-fixture"))
                if not path.is_file(): raise ValueError("演示样本尚未准备好，请先构建完整镜像")
                digest=hashlib.sha256(path.read_bytes()).hexdigest()
                return self.send(self.app.register(path,"REA 演示程序 · 不会被执行",digest,True),201)
            return self.send({"error":"接口不存在"},404)
        except PermissionError as error: self.send({"error":str(error)},403)
        except KeyError as error: self.send({"error":str(error)},404)
        except (OSError,ValueError) as error: self.send({"error":str(error)},400)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host",default="0.0.0.0")
    parser.add_argument("--port",type=int,default=8787)
    parser.add_argument("--uploads",default=os.environ.get("REA_WEB_UPLOAD_DIR","/uploads"))
    parser.add_argument("--results",default=os.environ.get("REA_WEB_RESULTS_DIR","/results"))
    args=parser.parse_args()
    app=Workbench(args.uploads,args.results)
    server=ThreadingHTTPServer((args.host,args.port),Handler)
    server.workbench=app
    server.allowed_hosts={"localhost","127.0.0.1","::1"}
    print("FAW REA web workbench listening on port "+str(args.port),flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()

if __name__=="__main__":
    main()

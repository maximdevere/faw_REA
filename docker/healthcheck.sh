#!/bin/sh
set -eu
node --version >/dev/null
command -v rea >/dev/null
test -x /opt/ghidra/support/analyzeHeadless
test -r "$REA_JADX_MCP_JAR"
test -r /opt/apktool/apktool_3.0.3.jar
test -w /work
test -w /results
test -w /uploads
python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8787/health", timeout=3).read()'

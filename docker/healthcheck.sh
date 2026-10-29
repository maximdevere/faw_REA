#!/bin/sh
set -eu
node --version >/dev/null
command -v rea >/dev/null
test -x /opt/ghidra/support/analyzeHeadless
test -f "$REA_JADX_MCP_JAR"
test -f /opt/apktool/apktool_3.0.3.jar
test -w /work
test -w /results

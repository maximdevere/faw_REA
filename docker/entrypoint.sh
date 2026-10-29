#!/bin/sh
set -eu
if [ "$#" -eq 0 ]; then
    set -- sleep infinity
fi
# stdout is reserved for MCP when invoked as: docker run -i IMAGE rea mcp
exec "$@"

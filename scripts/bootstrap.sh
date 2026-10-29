#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-build}"
if ! command -v docker >/dev/null; then
  printf '%s\n' "Docker is missing. Install/start a Linux container engine first." >&2
  exit 1
fi
docker info --format '{{.OSType}}'
docker compose version
mkdir -p "$repo_root/targets" "$repo_root/workspace" "$repo_root/results"
compose=(docker compose --project-directory "$repo_root" -f "$repo_root/compose.yaml")
"${compose[@]}" config --quiet
if [ "$mode" = pull ]; then
  "${compose[@]}" pull toolbox
  "${compose[@]}" up -d --no-build --wait toolbox
elif [ "$mode" = build ]; then
  "${compose[@]}" up -d --build --wait toolbox
elif [ "$mode" = local ]; then
  "${compose[@]}" up -d --no-build --wait toolbox
else
  printf '%s\n' "Usage: scripts/bootstrap.sh [build|pull|local]" >&2
  exit 2
fi
docker exec rea-toolbox rea doctor --provider jadx --json
docker exec rea-toolbox python3 /opt/toolbox/smoke-mcp.py --inside --report /results/smoke-mcp.json
mkdir -p "$repo_root/.opencode/skills"
skill="$repo_root/.opencode/skills/reverse-engineer-anything"
if [ -e "$skill" ]; then
  backup="$repo_root/.opencode/rea-backups/$(date +%Y%m%dT%H%M%S)-$$"
  mkdir -p "$backup"
  mv -- "$skill" "$backup/"
fi
docker cp rea-toolbox:/opt/rea/node_modules/rea-agents/skills/reverse-engineer-anything "$repo_root/.opencode/skills/"
if [ ! -e "$repo_root/opencode.json" ] && [ ! -e "$repo_root/opencode.jsonc" ]; then
  cp "$repo_root/config/opencode.example.json" "$repo_root/opencode.json"
else
  printf '%s\n' "Existing OpenCode config preserved. Merge config/opencode.example.json into it."
fi
printf '%s\n' "Restart OpenCode in $repo_root. Use /targets/... for REA input paths."

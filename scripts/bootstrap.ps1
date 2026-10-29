[CmdletBinding()]
param(
    [switch]$Pull,
    [switch]$UseLocalImage,
    [switch]$SkipSmoke,
    [string]$OpenCodeProject = (Join-Path $PSScriptRoot "..")
)
$ErrorActionPreference = "Stop"
if ($Pull -and $UseLocalImage) { throw "Choose either -Pull or -UseLocalImage" }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI is missing. Install/start Docker Desktop with Linux containers and WSL2 support first."
}
function Run-Docker([string[]]$DockerArgs) {
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) { throw ("Docker failed: " + ($DockerArgs -join " ")) }
}
Run-Docker -DockerArgs @("info", "--format", "{{.OSType}}")
Run-Docker -DockerArgs @("compose", "version")
foreach ($name in @("targets", "uploads", "workspace", "results")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot $name) | Out-Null
}
$compose = @("compose", "--project-directory", $repoRoot, "-f", (Join-Path $repoRoot "compose.yaml"))
Run-Docker -DockerArgs ($compose + @("config", "--quiet"))
if ($Pull) {
    Run-Docker -DockerArgs ($compose + @("pull", "toolbox"))
    Run-Docker -DockerArgs ($compose + @("up", "-d", "--no-build", "--wait", "toolbox"))
} elseif ($UseLocalImage) {
    Run-Docker -DockerArgs ($compose + @("up", "-d", "--no-build", "--wait", "toolbox"))
} else {
    Run-Docker -DockerArgs ($compose + @("up", "-d", "--build", "--wait", "toolbox"))
}
Run-Docker -DockerArgs @("exec", "rea-toolbox", "rea", "doctor", "--provider", "jadx", "--json")
if (-not $SkipSmoke) {
    Run-Docker -DockerArgs @("exec", "rea-toolbox", "python3", "/opt/toolbox/smoke-mcp.py",
                 "--inside", "--report", "/results/smoke-mcp.json")
}
& (Join-Path $PSScriptRoot "configure-opencode.ps1") -ProjectPath $OpenCodeProject
Write-Host "Web workbench: http://127.0.0.1:8787 (see .env if the port is overridden)."
Write-Host "OpenCode uses /uploads, /targets, /work and /results."

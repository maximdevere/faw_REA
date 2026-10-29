[CmdletBinding()]
param(
    [string]$ProjectPath = $PSScriptRoot,
    [string]$Model,
    [switch]$NonInteractive,
    [switch]$InstallOpenCode,
    [switch]$Pull,
    [switch]$UseLocalImage,
    [switch]$SkipSmoke,
    [ValidateSet("Auto", "Native", "Wsl")][string]$DockerBackend = "Auto",
    [string]$WslDistro,
    [switch]$NoLaunch,
    [switch]$Web
)
$ErrorActionPreference = "Stop"
if ($Pull -and $UseLocalImage) { throw "Choose either -Pull or -UseLocalImage." }
if ($NonInteractive -and -not $Model) { throw "Unattended setup requires an explicit -Model provider/model. It never picks a provider automatically." }
if (-not (Test-Path -LiteralPath $ProjectPath)) { New-Item -ItemType Directory -Path $ProjectPath | Out-Null }
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
. (Join-Path $PSScriptRoot "scripts/docker-host.ps1")
. (Join-Path $PSScriptRoot "scripts/model-setup.ps1")
Write-Host "FAW REA - first-run setup"
Write-Host "[1/4] Check the Docker Linux engine and Compose"
$dockerHost = Resolve-ReaDockerHost -Backend $DockerBackend -WslDistro $WslDistro
Invoke-ReaDocker -DockerHost $dockerHost -DockerArgs @("compose", "version")

Write-Host "[2/4] Check OpenCode"
if (-not (Get-Command opencode -ErrorAction SilentlyContinue) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    $prefix = @(& npm prefix --global 2>$null)
    if ($LASTEXITCODE -eq 0 -and $prefix.Count -eq 1) {
        $candidate = [string]$prefix[0]
        if ($env:OS -ne "Windows_NT") { $candidate = Join-Path $candidate "bin" }
        $env:PATH = $candidate + [IO.Path]::PathSeparator + $env:PATH
    }
}
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    $client = Get-Content -LiteralPath (Join-Path $PSScriptRoot "config/opencode-client.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $install = $InstallOpenCode
    if (-not $install -and -not $NonInteractive) {
        $answer = Read-Host "Install OpenCode $($client.install_version) with npm now? [y/N]"
        $install = $answer -match '^y(es)?$'
    }
    if (-not $install) { throw "Install OpenCode CLI, then rerun setup.ps1. Or use -InstallOpenCode with npm available." }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw "Install Node.js/npm or OpenCode CLI first, then rerun setup.ps1." }
    & npm install --global "$($client.package)@$($client.install_version)" --no-fund --no-audit
    if ($LASTEXITCODE -ne 0) { throw "OpenCode installation failed." }
    $prefix = @(& npm prefix --global)
    if ($LASTEXITCODE -eq 0 -and $prefix.Count -eq 1) {
        $candidate = [string]$prefix[0]
        if ($env:OS -ne "Windows_NT") { $candidate = Join-Path $candidate "bin" }
        $env:PATH = $candidate + [IO.Path]::PathSeparator + $env:PATH
    }
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { throw "OpenCode was installed but is not on PATH. Open a new terminal and rerun setup.ps1." }
}

Push-Location -LiteralPath $project
try {
    Write-Host "[3/4] Configure YOUR model account"
    if ($Model) {
        $available = @(Get-ReaAvailableModels)
        if ($available -notcontains $Model) {
            throw "The requested provider/model is not available in your OpenCode configuration. Rerun interactively to sign in or add your own API."
        }
        Save-ReaProjectModel -ProjectPath $project -Model $Model
        $selected = $Model
    } else {
        $selected = Select-ReaUserModel -ProjectPath $project
    }
    Write-Host "Selected model: $selected"
    Write-Host "[4/4] Start the toolbox, install REA MCP + skill, and check the connection"
    & (Join-Path $PSScriptRoot "scripts/bootstrap.ps1") -OpenCodeProject $project -DockerBackend $dockerHost.Backend -WslDistro $dockerHost.WslDistro -Pull:$Pull -UseLocalImage:$UseLocalImage -SkipSmoke:$SkipSmoke -VerifyOpenCode
    Write-Host ""
    Write-Host "Ready. Your project is $project"
    Write-Host "The model configuration is saved. Setup has not sent a model request; your first conversation uses your selected account."
    Write-Host "REA workbench: http://127.0.0.1:8787 (or your configured port)."
    if (-not $NoLaunch -and -not $NonInteractive) {
        if ($Web) { & opencode web --hostname 127.0.0.1 --port 0 }
        else { & opencode $project }
    }
} finally { Pop-Location }

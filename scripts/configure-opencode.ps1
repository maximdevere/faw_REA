[CmdletBinding()]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot ".."),
    [string]$ContainerName = "rea-toolbox",
    [ValidateSet("Auto", "Native", "Wsl")][string]$DockerBackend = "Auto",
    [string]$WslDistro,
    [switch]$Verify
)
$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$configPath = Join-Path $project "opencode.json"
$jsoncPath = Join-Path $project "opencode.jsonc"
if (Test-Path -LiteralPath $jsoncPath) {
    throw "opencode.jsonc exists. Merge config/opencode.example.json manually; no user config was modified."
}
$template = Get-Content -LiteralPath (Join-Path $repoRoot "config/opencode.example.json") -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot "docker-host.ps1")
$dockerHost = Resolve-ReaDockerHost -Backend $DockerBackend -WslDistro $WslDistro
$template.mcp.rea.command = @($dockerHost.Program) + @($dockerHost.Prefix) + @("exec", "-i", "-w", "/work", $ContainerName, "rea", "mcp")
$utf8 = New-Object System.Text.UTF8Encoding($false)
$backupRoot = Join-Path $project (".opencode/rea-backups/" + [guid]::NewGuid().ToString("N"))
function Put-Property($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config -isnot [pscustomobject]) { throw "Expected a JSON object in opencode.json" }
} else {
    $config = [pscustomobject]@{}
    Put-Property $config '$schema' 'https://opencode.ai/config.json'
}
if (-not $config.PSObject.Properties["mcp"]) { Put-Property $config "mcp" ([pscustomobject]@{}) }
if ($config.mcp -isnot [pscustomobject]) { throw "Invalid mcp object in existing config" }
$mcpTable = $config.mcp
if ($config.mcp.PSObject.Properties["servers"]) {
    throw "OpenCode expects a flat mcp map. Merge the REA entry manually into this legacy mcp.servers configuration."
}
Put-Property $mcpTable "rea" $template.mcp.rea
if (-not $config.PSObject.Properties["tools"]) { Put-Property $config "tools" ([pscustomobject]@{}) }
if ($config.tools -isnot [pscustomobject]) { throw "Invalid tools object in existing config" }
foreach ($property in $template.tools.PSObject.Properties) {
    Put-Property $config.tools $property.Name $property.Value
}
$serialized = $config | ConvertTo-Json -Depth 100
$null = $serialized | ConvertFrom-Json
$skillRoot = Join-Path $project ".opencode/skills"
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
$stage = Join-Path $project (".opencode/rea-stage-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$stageForDocker = ConvertTo-ReaDockerHostPath -DockerHost $dockerHost -Path $stage
Invoke-ReaDocker -DockerHost $dockerHost -DockerArgs @("cp", "${ContainerName}:/opt/rea/node_modules/rea-agents/skills/reverse-engineer-anything", $stageForDocker)
$stagedSkill = Join-Path $stage "reverse-engineer-anything"
if (-not (Test-Path -LiteralPath (Join-Path $stagedSkill "SKILL.md"))) { throw "Exported skill is missing SKILL.md" }
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$skillDestination = Join-Path $skillRoot "reverse-engineer-anything"
if (Test-Path -LiteralPath $skillDestination) {
    Move-Item -LiteralPath $skillDestination -Destination (Join-Path $backupRoot "reverse-engineer-anything")
}
Move-Item -LiteralPath $stagedSkill -Destination $skillDestination
$stagedConfig = Join-Path $stage "opencode.json"
[IO.File]::WriteAllText($stagedConfig, $serialized + [Environment]::NewLine, $utf8)
if (Test-Path -LiteralPath $configPath) {
    [IO.File]::Replace($stagedConfig, $configPath, (Join-Path $backupRoot "opencode.json"))
} else {
    [IO.File]::Move($stagedConfig, $configPath)
}
Remove-Item -LiteralPath $stage
Write-Host "REA MCP configured in: $configPath"
Write-Host "Matching skill exported to: $skillDestination"
Write-Host "Docker backend: $($dockerHost.Backend) $($dockerHost.WslDistro)"
if ($Verify) {
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { throw "Configuration saved. Install OpenCode CLI, then rerun with -Verify." }
    Push-Location -LiteralPath $project
    try {
        $output = @(& opencode mcp list 2>&1)
        $code = $LASTEXITCODE
        $text = ($output -join "`n") -replace "$([char]27)\[[0-?]*[ -/]*[@-~]", ""
        Write-Host $text
        if ($code -ne 0 -or $text -notmatch '(?m)\brea\b[^\r\n]*\bconnected\b') {
            throw "OpenCode did not report rea connected. Configuration and backup were kept; check the container and Docker command."
        }
    } finally { Pop-Location }
    Write-Host "OpenCode MCP connection verified. No model request was sent."
}
Write-Host "Restart existing OpenCode sessions. Use /uploads/... or /targets/... paths. Model/provider settings were preserved."

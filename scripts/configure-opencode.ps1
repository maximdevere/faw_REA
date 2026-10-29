[CmdletBinding()]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot ".."),
    [string]$ContainerName = "rea-toolbox"
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
$template.mcp.rea.command[5] = $ContainerName
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
    if ($null -eq $config -or $config -is [array]) { throw "Expected a JSON object in opencode.json" }
} else {
    $config = [pscustomobject]@{}
    Put-Property $config '$schema' 'https://opencode.ai/config.json'
}
if (-not $config.PSObject.Properties["mcp"]) { Put-Property $config "mcp" ([pscustomobject]@{}) }
if ($null -eq $config.mcp -or $config.mcp -is [array]) { throw "Invalid mcp object in existing config" }
$mcpTable = $config.mcp
if ($config.mcp.PSObject.Properties["servers"]) {
    if ($null -eq $config.mcp.servers) { throw "Invalid mcp.servers object" }
    $mcpTable = $config.mcp.servers
}
Put-Property $mcpTable "rea" $template.mcp.rea
if (-not $config.PSObject.Properties["tools"]) { Put-Property $config "tools" ([pscustomobject]@{}) }
foreach ($property in $template.tools.PSObject.Properties) {
    Put-Property $config.tools $property.Name $property.Value
}
$serialized = $config | ConvertTo-Json -Depth 100
$null = $serialized | ConvertFrom-Json
$skillRoot = Join-Path $project ".opencode/skills"
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
$stage = Join-Path $project (".opencode/rea-stage-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
& docker cp "${ContainerName}:/opt/rea/node_modules/rea-agents/skills/reverse-engineer-anything" $stage
if ($LASTEXITCODE -ne 0) { throw "Cannot export the image-matched REA skill; existing config was not changed" }
$stagedSkill = Join-Path $stage "reverse-engineer-anything"
if (-not (Test-Path -LiteralPath (Join-Path $stagedSkill "SKILL.md"))) { throw "Exported skill is missing SKILL.md" }
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupRoot "opencode.json") }
$skillDestination = Join-Path $skillRoot "reverse-engineer-anything"
if (Test-Path -LiteralPath $skillDestination) {
    Move-Item -LiteralPath $skillDestination -Destination (Join-Path $backupRoot "reverse-engineer-anything")
}
Move-Item -LiteralPath $stagedSkill -Destination $skillDestination
[IO.File]::WriteAllText($configPath, $serialized + [Environment]::NewLine, $utf8)
Remove-Item -LiteralPath $stage
Write-Host "REA MCP configured in: $configPath"
Write-Host "Matching skill exported to: $skillDestination"
Write-Host "Restart OpenCode. Give REA /targets/... paths."

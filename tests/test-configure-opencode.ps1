$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("faw-rea-config-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function global:docker {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs)
    if ($DockerArgs[0] -ne "cp") { throw "Unexpected mocked Docker command" }
    $destination = $DockerArgs[2]
    $skill = Join-Path $destination "reverse-engineer-anything"
    New-Item -ItemType Directory -Force -Path $skill | Out-Null
    [IO.File]::WriteAllText((Join-Path $skill "SKILL.md"), "---" + [Environment]::NewLine + "name: reverse-engineer-anything")
    $global:LASTEXITCODE = 0
}
try {
    $configPath = Join-Path $testRoot "opencode.json"
    [IO.File]::WriteAllText($configPath, '{"model":"keep/me","mcp":{"other":{"type":"local","command":["keep"]}}}')
    & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -ContainerName "custom-container"
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.model -ne "keep/me") { throw "Existing model was overwritten" }
    if ($config.mcp.other.command[0] -ne "keep") { throw "Other MCP was overwritten" }
    if ($config.mcp.rea.command[5] -ne "custom-container") { throw "Container name is in wrong argument position" }
    if ($config.mcp.rea.command[6] -ne "rea") { throw "REA executable was overwritten" }
    if (-not (Test-Path (Join-Path $testRoot ".opencode/skills/reverse-engineer-anything/SKILL.md"))) { throw "Skill was not exported" }
    if (-not (Get-ChildItem -Path (Join-Path $testRoot ".opencode/rea-backups") -Recurse -Filter opencode.json)) { throw "Backup missing" }
    $before = [IO.File]::ReadAllText($configPath)
    [IO.File]::WriteAllText((Join-Path $testRoot "opencode.jsonc"), "{}")
    $refused = $false
    try { & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot } catch { $refused = $true }
    if (-not $refused) { throw "JSONC config was not protected" }
    if ([IO.File]::ReadAllText($configPath) -ne $before) { throw "Config changed after JSONC refusal" }
    Write-Host "OpenCode configuration tests passed"
} finally {
    Remove-Item function:docker
    if ($testRoot.StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

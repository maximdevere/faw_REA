$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("faw-rea-config-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$global:reaFailCopy = $false
$global:reaVerifyFails = $false
$global:reaPathMap = @{}
function global:docker {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs)
    if ($DockerArgs[0] -eq "info") { $global:LASTEXITCODE = 0; Write-Output "linux"; return }
    if ($DockerArgs[0] -ne "cp") { throw "Unexpected mocked Docker command" }
    if ($global:reaFailCopy) { $global:LASTEXITCODE = 1; return }
    $destination = $DockerArgs[2]
    $skill = Join-Path $destination "reverse-engineer-anything"
    New-Item -ItemType Directory -Force -Path $skill | Out-Null
    [IO.File]::WriteAllText((Join-Path $skill "SKILL.md"), "---" + [Environment]::NewLine + "name: reverse-engineer-anything")
    $global:LASTEXITCODE = 0
}
function global:opencode {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArgs)
    if (($CliArgs -join " ") -ne "mcp list") { throw "Verification must not send a model request" }
    $global:LASTEXITCODE = 0
    if ($global:reaVerifyFails) { Write-Output "rea disconnected" } else { Write-Output "rea connected" }
}
function global:wsl.exe {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArgs)
    $index = [Array]::IndexOf($CliArgs, "--exec")
    if ($index -lt 0) { throw "Expected WSL --exec" }
    $tail = @($CliArgs[($index + 1)..($CliArgs.Length - 1)])
    $global:LASTEXITCODE = 0
    if ($tail[0] -eq "printenv") { Write-Output "Test Linux"; return }
    if ($tail[0] -eq "sh") { Write-Output "/usr/local/bin/docker"; return }
    if ($tail[0] -eq "wslpath") {
        $mapped = "/mnt/c/mock project/" + [guid]::NewGuid().ToString("N")
        $global:reaPathMap[$mapped] = $tail[-1]
        Write-Output $mapped
        return
    }
    $withSudo = $tail[0] -eq "sudo"
    if ($withSudo) { $tail = @($tail[2..($tail.Length - 1)]) }
    if ($tail[0] -ne "/usr/local/bin/docker") { throw "Unexpected WSL Docker path" }
    if ($tail[1] -eq "info") {
        if ($withSudo) { Write-Output "linux" } else { $global:LASTEXITCODE = 1 }
        return
    }
    if ($tail[1] -ne "cp") { throw "Unexpected WSL Docker action" }
    if (-not $withSudo) { throw "Resolved sudo prefix was lost" }
    $destination = $global:reaPathMap[$tail[-1]]
    if (-not $destination) { throw "The Windows docker cp destination was not translated into WSL" }
    $skill = Join-Path $destination "reverse-engineer-anything"
    New-Item -ItemType Directory -Force -Path $skill | Out-Null
    [IO.File]::WriteAllText((Join-Path $skill "SKILL.md"), "matched fixture skill")
}
try {
    $configPath = Join-Path $testRoot "opencode.json"
    [IO.File]::WriteAllText($configPath, '{"model":"new-api/keep-me","small_model":"new-api/keep-small","disabled_providers":["glm"],"permission":{"bash":"deny"},"mcp":{"other":{"type":"local","command":["keep"]}}}')
    & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -ContainerName "custom-container" -DockerBackend Native -Verify
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.model -ne "new-api/keep-me") { throw "Existing model was overwritten" }
    if ($config.small_model -ne "new-api/keep-small") { throw "Existing auxiliary model was overwritten" }
    if ($config.disabled_providers[0] -ne "glm") { throw "Disabled provider was overwritten" }
    if ($config.permission.bash -ne "deny") { throw "Permission setting was overwritten" }
    if ($config.mcp.other.command[0] -ne "keep") { throw "Other MCP was overwritten" }
    if ($config.mcp.rea.command[5] -ne "custom-container") { throw "Container name is in wrong argument position" }
    if ($config.mcp.rea.command[6] -ne "rea") { throw "REA executable was overwritten" }
    if (-not (Test-Path (Join-Path $testRoot ".opencode/skills/reverse-engineer-anything/SKILL.md"))) { throw "Skill was not exported" }
    if (-not (Get-ChildItem -Path (Join-Path $testRoot ".opencode/rea-backups") -Recurse -Filter opencode.json)) { throw "Backup missing" }
    $before = [IO.File]::ReadAllText($configPath)
    & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -ContainerName "custom-container" -DockerBackend Native
    if ([IO.File]::ReadAllText($configPath) -ne $before) { throw "Repeated setup is not idempotent" }
    $global:reaFailCopy = $true
    $refused = $false
    try { & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -DockerBackend Native } catch { $refused = $true }
    $global:reaFailCopy = $false
    if (-not $refused -or [IO.File]::ReadAllText($configPath) -ne $before) { throw "Failed skill export changed the user configuration" }
    [IO.File]::WriteAllText((Join-Path $testRoot "opencode.jsonc"), "{}")
    $refused = $false
    try { & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -DockerBackend Native } catch { $refused = $true }
    if (-not $refused) { throw "JSONC config was not protected" }
    if ([IO.File]::ReadAllText($configPath) -ne $before) { throw "Config changed after JSONC refusal" }
    Remove-Item -LiteralPath (Join-Path $testRoot "opencode.jsonc")
    & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -DockerBackend Wsl -WslDistro "Test Linux" -Verify
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $expected = @("wsl.exe","-d","Test Linux","--exec","sudo","-n","/usr/local/bin/docker","exec","-i","-w","/work","rea-toolbox","rea","mcp")
    if (($config.mcp.rea.command -join "|") -ne ($expected -join "|")) { throw "Wrong WSL MCP argv" }
    if ($config.model -ne "new-api/keep-me" -or $config.small_model -ne "new-api/keep-small") { throw "WSL configuration overwrote model preferences" }
    $global:reaVerifyFails = $true
    $refused = $false
    try { & (Join-Path $repoRoot "scripts/configure-opencode.ps1") -ProjectPath $testRoot -DockerBackend Native -Verify } catch { $refused = $true }
    if (-not $refused) { throw "Disconnected MCP was reported as verified" }
    Write-Host "OpenCode configuration tests passed"
} finally {
    Remove-Item function:docker
    Remove-Item function:opencode
    Remove-Item function:wsl.exe
    $resolvedTest = (Resolve-Path -LiteralPath $testRoot).Path
    $resolvedTemp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedTest -Recurse -Force }
}

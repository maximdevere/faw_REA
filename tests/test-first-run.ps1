$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("faw-rea-first-run-" + [guid]::NewGuid().ToString("N"))
$project = Join-Path $testRoot "new user project"
$global:reaDemoData = Join-Path $testRoot "private opencode data"
New-Item -ItemType Directory -Force -Path $project,$global:reaDemoData | Out-Null
$global:reaDemoPrompts = New-Object Collections.Queue
$global:reaDemoConfig = [pscustomobject]@{disabled_providers=@("blocked");provider=[pscustomobject]@{company=[pscustomobject]@{options=[pscustomobject]@{apiKey="global-test-credential-must-not-be-copied"}}}}
function global:opencode {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArgs)
    $global:LASTEXITCODE=0
    switch ($CliArgs -join " ") {
        "debug config" { $global:reaDemoConfig | ConvertTo-Json -Depth 30; return }
        "debug paths" { Write-Output "data       $global:reaDemoData"; return }
        "models" { Write-Output "company/assistant"; Write-Output "opencode/demo-free"; return }
        "mcp list" { Write-Output "rea connected"; return }
        "auth login" { return }
        default { throw "Setup must not issue model requests or use someone else's account: $($CliArgs[0])" }
    }
}
function global:Read-Host {
    param([string]$Prompt,[switch]$AsSecureString)
    if (-not $global:reaDemoPrompts.Count) { throw "Unexpected setup prompt" }
    return $global:reaDemoPrompts.Dequeue()
}
function global:docker {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArgs)
    $global:LASTEXITCODE=0
    if ($DockerArgs[0] -eq "info") { Write-Output "linux"; return }
    if ($DockerArgs[0] -eq "compose") { return }
    if ($DockerArgs[0] -eq "exec") {
        if ($DockerArgs -contains "/opt/toolbox/smoke-mcp.py") { throw "-SkipSmoke was not forwarded" }
        Write-Output '{"healthy":true}'
        return
    }
    if ($DockerArgs[0] -eq "cp") {
        $skill=Join-Path $DockerArgs[2] "reverse-engineer-anything"
        New-Item -ItemType Directory -Force -Path $skill | Out-Null
        [IO.File]::WriteAllText((Join-Path $skill "SKILL.md"), "matched fixture skill")
        return
    }
    throw "Unexpected Docker action"
}
. (Join-Path $repo "scripts/model-setup.ps1")
try {
    Push-Location -LiteralPath $project
    try {
        # A fresh user's own API is configured through the real interactive branch.
        $global:reaDemoPrompts.Enqueue("2")
        $global:reaDemoPrompts.Enqueue("https://models.example.invalid/v1")
        $global:reaDemoPrompts.Enqueue("demo-model")
        $global:reaDemoPrompts.Enqueue((ConvertTo-SecureString "not-a-real-credential-for-setup-tests" -AsPlainText -Force))
        $route=Select-ReaUserModel -ProjectPath $project
        if ($route -notmatch '^rea-api-[a-f0-9]{8}/demo-model$') { throw "Custom user model was not selected" }
        $raw=[IO.File]::ReadAllText((Join-Path $project "opencode.json"))
        $config=$raw | ConvertFrom-Json
        if ($config.model -ne $route -or $config.small_model -ne $route) { throw "Model routes are not pinned to the selected user account" }
        if ($raw -match 'not-a-real-credential|global-test-credential') { throw "Credential leaked into the project" }
        $id=$route.Split('/')[0]
        if ($config.provider.$id.options.apiKey -notmatch '^\{file:.+\}$') { throw "Expected an external file reference" }
        $keyPath=Join-Path $global:reaDemoData ("faw-rea-secrets/" + $id + ".key")
        if ([IO.File]::ReadAllText($keyPath) -ne "not-a-real-credential-for-setup-tests") { throw "User credential was not saved outside the checkout" }
        $snapshot=$raw
        $refused=$false
        try { Save-ReaProjectModel -ProjectPath $project -Model "blocked/model" } catch { $refused=$true }
        if (-not $refused -or [IO.File]::ReadAllText((Join-Path $project "opencode.json")) -ne $snapshot) { throw "Setup re-enabled a disabled account" }
        $refused=$false
        $key=ConvertTo-SecureString "fake-private-key" -AsPlainText -Force
        try { Add-ReaCompatibleProvider -ProjectPath $project -BaseUrl "https://models.example.invalid/v1" -ModelId "demo-model" -ApiKey $key -SecretDirectory (Join-Path $project "unsafe-secrets") } catch { $refused=$true }
        finally { $key.Dispose() }
        if (-not $refused -or (Test-Path (Join-Path $project "unsafe-secrets"))) { throw "Setup allowed credentials inside the Docker context" }
        $refused=$false
        try { & (Join-Path $repo "setup.ps1") -ProjectPath $project -NonInteractive -NoLaunch -DockerBackend Native } catch { $refused=$true }
        if (-not $refused) { throw "Unattended setup picked a default account without user input" }
        # Native-model selection and official account login are both public paths.
        $selectionProject=Join-Path $testRoot "choose model project"
        New-Item -ItemType Directory -Path $selectionProject | Out-Null
        $global:reaDemoPrompts.Enqueue("1")
        $global:reaDemoPrompts.Enqueue("1")
        $selected=Select-ReaUserModel -ProjectPath $selectionProject
        if ($selected -ne "company/assistant") { throw "Existing provider selection did not use the user's choice" }
        $global:reaDemoConfig | Add-Member -NotePropertyName model -NotePropertyValue "company/assistant"
        $global:reaDemoConfig | Add-Member -NotePropertyName small_model -NotePropertyValue "company/assistant-small"
        $global:reaDemoPrompts.Enqueue("3")
        $global:reaDemoPrompts.Enqueue("0")
        $selected=Select-ReaUserModel -ProjectPath $selectionProject
        $selectedConfig=Get-Content -LiteralPath (Join-Path $selectionProject "opencode.json") -Raw | ConvertFrom-Json
        if ($selected -ne "company/assistant" -or $selectedConfig.small_model -ne "company/assistant-small") { throw "Explicit existing setup selection was not preserved" }
    } finally { Pop-Location }

    # Generic setup also works for an existing account, without any personal IDs.
    $existing=Join-Path $testRoot "existing account project"
    New-Item -ItemType Directory -Path $existing | Out-Null
    & (Join-Path $repo "setup.ps1") -ProjectPath $existing -NonInteractive -Model "company/assistant" -UseLocalImage -SkipSmoke -NoLaunch -DockerBackend Native
    $config=Get-Content -LiteralPath (Join-Path $existing "opencode.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.model -ne "company/assistant" -or $config.small_model -ne "company/assistant") { throw "First-run setup did not use the chosen account" }
    if ($config.mcp.rea.command[0] -ne "docker") { throw "First-run setup did not install the REA MCP entry" }
    if ($config.PSObject.Properties["provider"]) { throw "Global provider credentials were copied into the project" }
    if (-not (Test-Path (Join-Path $existing ".opencode/skills/reverse-engineer-anything/SKILL.md"))) { throw "First-run setup did not export the REA skill" }
    foreach ($relative in @("setup.ps1","scripts/model-setup.ps1","config/opencode-client.json")) {
        $source=Get-Content -LiteralPath (Join-Path $repo $relative) -Raw
        if ($source -match 'new-api|glm|actc_2|C:\\Users') { throw "Personal machine/account data was hardcoded in the public setup" }
    }
    Write-Host "Generic first-run onboarding tests passed"
} finally {
    Remove-Item function:opencode
    Remove-Item function:Read-Host
    Remove-Item function:docker
    $resolvedTest=(Resolve-Path -LiteralPath $testRoot).Path
    $resolvedTemp=(Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if ($resolvedTest.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedTest -Recurse -Force }
}

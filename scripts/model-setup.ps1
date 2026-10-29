# User-owned model onboarding. Credentials are never written into the checkout.
function Get-ReaSetting {
    param($Object, [string]$Name)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $null
}

function Set-ReaSetting {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

function Get-ReaOpenCodeSettings {
    $raw = @(& opencode debug config)
    if ($LASTEXITCODE -ne 0) { throw "OpenCode could not resolve its configuration." }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Get-ReaAvailableModels {
    $raw = @(& opencode models)
    if ($LASTEXITCODE -ne 0) { throw "OpenCode could not list available models." }
    return @($raw | ForEach-Object {
        $line = ([string]$_ -replace "$([char]27)\[[0-?]*[ -/]*[@-~]", "").Trim()
        if ($line -match '^[A-Za-z0-9_.-]+/\S+$') { $line }
    } | Sort-Object -Unique)
}

function Read-ReaProjectSettings {
    param([string]$ProjectPath)
    if (Test-Path -LiteralPath (Join-Path $ProjectPath "opencode.jsonc")) {
        throw "Project opencode.jsonc is preserved. Merge the model and MCP entries manually, or use a separate REA project directory."
    }
    $path = Join-Path $ProjectPath "opencode.json"
    if (Test-Path -LiteralPath $path) {
        $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config -isnot [pscustomobject]) { throw "Expected a JSON object in project opencode.json." }
        return $config
    }
    return [pscustomobject]@{'$schema'="https://opencode.ai/config.json"}
}

function Save-ReaProjectModel {
    param([string]$ProjectPath, [string]$Model, [string]$SmallModel, [string]$ProviderId, $ProviderDefinition)
    if ($Model -notmatch '^[A-Za-z0-9_.-]+/\S+$') { throw "Use a complete provider/model identifier." }
    if (-not $SmallModel) { $SmallModel = $Model }
    if ($SmallModel -notmatch '^[A-Za-z0-9_.-]+/\S+$') { throw "Use a complete auxiliary provider/model identifier." }
    $resolved = Get-ReaOpenCodeSettings
    foreach ($route in @($Model, $SmallModel)) {
        if (@(Get-ReaSetting $resolved "disabled_providers") -contains $route.Split('/')[0]) {
            throw "The selected provider is disabled. Choose a different provider; setup will not re-enable it."
        }
    }
    $config = Read-ReaProjectSettings -ProjectPath $ProjectPath
    if ($ProviderDefinition) {
        if (-not $config.PSObject.Properties["provider"]) { Set-ReaSetting $config "provider" ([pscustomobject]@{}) }
        if ($config.provider -isnot [pscustomobject]) { throw "Invalid project provider map." }
        $resolvedProviders = Get-ReaSetting $resolved "provider"
        if ($config.provider.PSObject.Properties[$ProviderId] -or ($resolvedProviders -and $resolvedProviders.PSObject.Properties[$ProviderId])) {
            throw "Provider ID already exists. Choose a new connection name."
        }
        Set-ReaSetting $config.provider $ProviderId $ProviderDefinition
    }
    Set-ReaSetting $config "model" $Model
    Set-ReaSetting $config "small_model" $SmallModel
    $path = Join-Path $ProjectPath "opencode.json"
    $stage = Join-Path $ProjectPath (".opencode/rea-stage-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $temporary = Join-Path $stage "opencode.json"
    [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) {
        $backup = Join-Path $ProjectPath (".opencode/rea-backups/" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        [IO.File]::Replace($temporary, $path, (Join-Path $backup "opencode.json"))
    } else { [IO.File]::Move($temporary, $path) }
    Remove-Item -LiteralPath $stage -ErrorAction SilentlyContinue
}

function Add-ReaCompatibleProvider {
    param([string]$ProjectPath, [string]$BaseUrl, [string]$ModelId, [Security.SecureString]$ApiKey,
          [string]$ProviderId = ("rea-api-" + [guid]::NewGuid().ToString("N").Substring(0,8)),
          [string]$SecretDirectory)
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @("https","http") -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw "Enter an HTTP(S) API base URL without credentials, query parameters or fragments."
    }
    if ($ModelId -notmatch '^\S+$' -or $ProviderId -notmatch '^rea-[a-z0-9_-]+$') { throw "Invalid model or generated provider ID." }
    $null = Read-ReaProjectSettings -ProjectPath $ProjectPath
    $options = [pscustomobject]@{baseURL=$BaseUrl.TrimEnd('/')}
    $keyPath = $null
    if ($ApiKey -and $ApiKey.Length) {
        if (-not $SecretDirectory) {
            $paths = @(& opencode debug paths)
            if ($LASTEXITCODE -ne 0) { throw "Cannot locate the OpenCode data directory." }
            $dataPath = $null
            foreach ($line in $paths) { if ([string]$line -match '^data\s+(.+)$') { $dataPath = $Matches[1].Trim() } }
            if (-not $dataPath) { throw "Cannot locate the OpenCode data directory." }
            $SecretDirectory = Join-Path $dataPath "faw-rea-secrets"
        }
        $secretRoot = [IO.Path]::GetFullPath($SecretDirectory)
        $projectRoot = [IO.Path]::GetFullPath($ProjectPath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (($secretRoot + [IO.Path]::DirectorySeparatorChar).StartsWith($projectRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Credential storage must be outside the project and Docker build context."
        }
        New-Item -ItemType Directory -Force -Path $secretRoot | Out-Null
        if ($env:OS -ne "Windows_NT") {
            & chmod 700 $secretRoot
            if ($LASTEXITCODE -ne 0) { throw "Cannot protect the credential directory." }
        }
        $keyPath = Join-Path $secretRoot ($ProviderId + ".key")
        if (Test-Path -LiteralPath $keyPath) { throw "A credential file with this ID already exists." }
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKey)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim()
            if (-not $plain) { throw "API key contains only whitespace." }
            if ($plain -match '[\r\n]') { throw "API keys must not contain line breaks." }
            [IO.File]::WriteAllText($keyPath, $plain, (New-Object Text.UTF8Encoding($false)))
        } finally { $plain=$null; [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($env:OS -ne "Windows_NT") {
            & chmod 600 $keyPath
            if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $keyPath; throw "Cannot protect the credential file." }
        }
        Set-ReaSetting $options "apiKey" ("{file:" + ($keyPath -replace '\\','/') + "}")
    }
    $models = [pscustomobject]@{}
    Set-ReaSetting $models $ModelId ([pscustomobject]@{name=$ModelId})
    $definition = [pscustomobject]@{npm="@ai-sdk/openai-compatible";name="My API";options=$options;models=$models}
    $route = $ProviderId + "/" + $ModelId
    try { Save-ReaProjectModel -ProjectPath $ProjectPath -Model $route -ProviderId $ProviderId -ProviderDefinition $definition }
    catch {
        if ($keyPath -and (Test-Path -LiteralPath $keyPath)) { Remove-Item -LiteralPath $keyPath }
        throw
    }
    return $route
}

function Select-ReaUserModel {
    param([string]$ProjectPath)
    while ($true) {
        $config = Get-ReaOpenCodeSettings
        $currentModel = Get-ReaSetting $config "model"
        $currentSmallModel = Get-ReaSetting $config "small_model"
        Write-Host ""
        Write-Host "Choose YOUR model connection (full provider/model IDs are shown):"
        if ($currentModel) {
            $auxiliary = $currentSmallModel
            if (-not $auxiliary) { $auxiliary = $currentModel }
            Write-Host "0. Use current selection: $currentModel (auxiliary: $auxiliary)"
        }
        Write-Host "1. Select a model already available in OpenCode"
        Write-Host "2. Add my own OpenAI-compatible API / local model endpoint"
        Write-Host "3. Sign in to a provider using OpenCode's login flow"
        $choice = Read-Host "Selection"
        if ($choice -eq "0" -and $currentModel) {
            Save-ReaProjectModel -ProjectPath $ProjectPath -Model $currentModel -SmallModel $currentSmallModel
            return $currentModel
        }
        if ($choice -eq "1") {
            $models = @(Get-ReaAvailableModels)
            if (-not $models.Count) { Write-Host "No models detected. Add an API or sign in first."; continue }
            for ($i=0; $i -lt $models.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1), $models[$i]) }
            $number = 0
            if (-not [int]::TryParse((Read-Host "Model number"), [ref]$number) -or $number -lt 1 -or $number -gt $models.Count) { continue }
            $selected = $models[$number-1]
            Save-ReaProjectModel -ProjectPath $ProjectPath -Model $selected
            return $selected
        }
        if ($choice -eq "2") {
            $url = Read-Host "API base URL (include /v1 if required)"
            $model = Read-Host "Model ID supplied by your provider"
            $key = Read-Host "Your API key (masked; leave empty for a local endpoint without authentication)" -AsSecureString
            try { return (Add-ReaCompatibleProvider -ProjectPath $ProjectPath -BaseUrl $url -ModelId $model -ApiKey $key) }
            finally { if ($key) { $key.Dispose() } }
        }
        if ($choice -eq "3") {
            & opencode auth login
            if ($LASTEXITCODE -ne 0) { throw "OpenCode provider login did not finish." }
        }
    }
}

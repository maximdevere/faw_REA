# Shared Docker transport for native Docker and Windows -> WSL Docker Engine.
function Read-ReaCommandOutput {
    param([string]$Program, [string[]]$CommandArgs)
    try {
        $lines = @(& $Program @CommandArgs 2>$null)
        if ($LASTEXITCODE -eq 0) {
            return (($lines -join "`n") -replace "`0", "").Trim()
        }
    } catch { }
    return $null
}

function Resolve-ReaDockerHost {
    param(
        [ValidateSet("Auto", "Native", "Wsl")][string]$Backend = "Auto",
        [string]$WslDistro
    )
    if ($WslDistro -and $Backend -eq "Native") {
        throw "-WslDistro cannot be combined with the Native Docker backend."
    }
    if ($Backend -ne "Wsl" -and -not $WslDistro) {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $os = Read-ReaCommandOutput -Program "docker" -CommandArgs @("info", "--format", "{{.OSType}}")
            if ($os -eq "linux") {
                return [pscustomobject]@{Backend="Native"; Program="docker"; Prefix=@(); WslDistro=$null}
            }
            if ($os -eq "windows") { throw "Switch Docker Desktop to Linux containers first." }
        }
        if ($Backend -eq "Native") { throw "A running native Docker Linux engine is required." }
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "Start Docker Desktop, or install/start a WSL Docker Engine and specify -WslDistro."
    }
    if (-not $WslDistro) {
        $WslDistro = Read-ReaCommandOutput -Program "wsl.exe" -CommandArgs @("--exec", "printenv", "WSL_DISTRO_NAME")
    }
    if (-not $WslDistro -or $WslDistro -match "[\r\n]") {
        throw "Cannot select a WSL distribution. Specify -WslDistro with a running Docker Engine."
    }
    $wslPrefix = @("-d", $WslDistro, "--exec")
    $dockerPath = Read-ReaCommandOutput -Program "wsl.exe" -CommandArgs ($wslPrefix + @("sh", "-lc", "command -v docker"))
    if (-not $dockerPath -or -not $dockerPath.StartsWith("/") -or $dockerPath -match "[\r\n]") {
        throw "Docker CLI was not found in WSL distribution '$WslDistro'."
    }
    foreach ($sudoPrefix in @(@(), @("sudo", "-n"))) {
        $prefix = $wslPrefix + @($sudoPrefix) + @($dockerPath)
        $os = Read-ReaCommandOutput -Program "wsl.exe" -CommandArgs ($prefix + @("info", "--format", "{{.OSType}}"))
        if ($os -eq "linux") {
            return [pscustomobject]@{Backend="Wsl"; Program="wsl.exe"; Prefix=$prefix; WslDistro=$WslDistro}
        }
    }
    throw "Docker is not reachable in '$WslDistro'. Start its engine and grant Docker access; this script does not change sudo or group permissions."
}

function Invoke-ReaDocker {
    param($DockerHost, [string[]]$DockerArgs)
    $program = $DockerHost.Program
    $prefix = @($DockerHost.Prefix)
    & $program @prefix @DockerArgs
    if ($LASTEXITCODE -ne 0) { throw ("Docker failed: " + ($DockerArgs -join " ")) }
}

function ConvertTo-ReaDockerHostPath {
    param($DockerHost, [string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    if ($DockerHost.Backend -ne "Wsl") { return $fullPath }
    $converted = Read-ReaCommandOutput -Program "wsl.exe" -CommandArgs @("-d", $DockerHost.WslDistro, "--exec", "wslpath", "-a", $fullPath)
    if (-not $converted -or -not $converted.StartsWith("/") -or $converted -match "[\r\n]") {
        throw "Cannot map the host path into WSL: $fullPath"
    }
    return $converted
}

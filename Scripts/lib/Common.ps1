# Common.ps1 - shared helpers for the PalHost server project.
# Dot-source this file from every entry script:  . "$PSScriptRoot\lib\Common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Common.ps1 lives in Scripts\lib: go up lib -> Scripts -> project root
$script:PalRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

function Get-PalPath {
    param([string]$Child)
    if ($Child) { return (Join-Path $script:PalRoot $Child) }
    return $script:PalRoot
}

$script:Paths = @{
    SteamCmd   = Get-PalPath 'SteamCMD'
    Server     = Get-PalPath 'Server'
    Mods       = Get-PalPath 'Mods'
    Config     = Get-PalPath 'Config'
    Saves      = Get-PalPath 'Saves'
    Backups    = Get-PalPath 'Backups'
    Logs       = Get-PalPath 'Logs'
    Scripts    = Get-PalPath 'Scripts'
}

function New-PalDirectoryTree {
    # Idempotent: creates the full project directory tree.
    $dirs = @(
        $script:Paths.SteamCmd, $script:Paths.Server, $script:Paths.Config,
        $script:Paths.Backups, $script:Paths.Logs,
        (Join-Path $script:Paths.Logs 'Mods'),
        (Join-Path $script:Paths.Mods 'Installed'),
        (Join-Path $script:Paths.Mods 'Downloads'),
        (Join-Path $script:Paths.Mods 'Cache'),
        (Join-Path $script:Paths.Mods 'Cache\Staging'),
        (Join-Path $script:Paths.Mods 'Cache\Backups'),
        (Join-Path $script:Paths.Mods 'Workshop'),
        (Join-Path $script:Paths.Mods 'Nexus'),
        (Join-Path $script:Paths.Mods 'GitHub'),
        (Join-Path $script:Paths.Mods 'Local')
    )
    foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-PalLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Category = 'Server'
    )
    $dir = Join-Path $script:Paths.Logs $Category
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(5), $Message
    Add-Content -Path (Join-Path $dir ('{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))) -Value $line -Encoding UTF8
    $colors = @{ DEBUG = 'DarkGray'; INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }
    Write-Host $line -ForegroundColor $colors[$Level]
}

function Clear-OldLogs {
    # Removes log files older than logs.retentionDays.
    $cfg = Get-PalConfig
    $cutoff = (Get-Date).AddDays(-1 * [int]$cfg.logs.retentionDays)
    Get-ChildItem -Path $script:Paths.Logs -Filter '*.log' -Recurse -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:ConfigCache = $null

function Get-PalConfig {
    param([switch]$Reload)
    if ($null -eq $script:ConfigCache -or $Reload) {
        $file = Join-Path $script:Paths.Config 'server.config.json'
        $script:ConfigCache = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:ConfigCache
}

function Save-PalConfig {
    param([Parameter(Mandatory)]$Config)
    $file = Join-Path $script:Paths.Config 'server.config.json'
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
    $script:ConfigCache = $Config
}

function New-RandomPassword {
    param([int]$Length = 20)
    # Alphanumeric only: Palworld ini values and Basic-auth are picky about special chars.
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Count] })
}

function Initialize-PalPasswords {
    # Replaces CHANGE_ME placeholders with strong random passwords (idempotent).
    $cfg = Get-PalConfig
    $changed = $false
    if ($cfg.server.serverPassword -eq 'CHANGE_ME') {
        $cfg.server.serverPassword = New-RandomPassword -Length 12
        $changed = $true
    }
    if ($cfg.server.adminPassword -eq 'CHANGE_ME') {
        $cfg.server.adminPassword = New-RandomPassword -Length 20
        $changed = $true
    }
    if ($changed) {
        Save-PalConfig -Config $cfg
        Write-PalLog -Message 'Generated random server/admin passwords in Config/server.config.json' -Category 'Install'
    }
}

# ---------------------------------------------------------------------------
# PalWorldSettings.ini rendering
# ---------------------------------------------------------------------------

function Split-OptionSettings {
    # Splits the inside of OptionSettings=(...) on top-level commas only: values can be
    # quoted strings or parenthesized lists such as CrossplayPlatforms=(Steam,Xbox,PS5,Mac).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Inner)
    $parts = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $inQuote = $false
    $start = 0
    for ($i = 0; $i -lt $Inner.Length; $i++) {
        $ch = $Inner[$i]
        if ($ch -eq '"') { $inQuote = -not $inQuote }
        elseif (-not $inQuote) {
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') { $depth-- }
            elseif ($ch -eq ',' -and $depth -eq 0) {
                $parts.Add($Inner.Substring($start, $i - $start))
                $start = $i + 1
            }
        }
    }
    $parts.Add($Inner.Substring($start))
    return $parts
}

function ConvertFrom-OptionSettings {
    # Parses "OptionSettings=(Key=Val,...)" into an ordered dictionary.
    param([Parameter(Mandatory)][string]$Line)
    $result = [ordered]@{}
    if ($Line -match 'OptionSettings=\((.*)\)\s*$') {
        foreach ($pair in (Split-OptionSettings -Inner $Matches[1])) {
            $idx = $pair.IndexOf('=')
            if ($idx -gt 0) {
                $result[$pair.Substring(0, $idx).Trim()] = $pair.Substring($idx + 1)
            }
        }
    }
    return $result
}

function Test-OptionValue {
    # A value must have balanced parentheses and quotes, or the server hangs at boot
    # without any error (seen with a split CrossplayPlatforms list on 1.0.5).
    param([AllowEmptyString()][string]$Value)
    $depth = 0
    $quotes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '"') { $quotes++ }
        elseif ($quotes % 2 -eq 0) {
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') { $depth--; if ($depth -lt 0) { return $false } }
        }
    }
    return ($depth -eq 0 -and $quotes % 2 -eq 0)
}

function Build-PalWorldSettings {
    # Merges DefaultPalWorldSettings.ini + Config/world.settings.json + server.config.json
    # and writes the live PalWorldSettings.ini used by the dedicated server.
    $cfg = Get-PalConfig
    $defaultIni = Join-Path $script:Paths.Server 'DefaultPalWorldSettings.ini'
    $liveDir = Join-Path $script:Paths.Server 'Pal\Saved\Config\WindowsServer'
    $liveIni = Join-Path $liveDir 'PalWorldSettings.ini'

    $options = [ordered]@{}
    if (Test-Path $defaultIni) {
        foreach ($line in (Get-Content $defaultIni)) {
            if ($line -match '^OptionSettings=') { $options = ConvertFrom-OptionSettings -Line $line }
        }
    } else {
        Write-PalLog -Message 'DefaultPalWorldSettings.ini not found; writing overrides only.' -Level 'WARN' -Category 'Install'
    }

    # World overrides (verbatim values)
    $worldFile = Join-Path $script:Paths.Config 'world.settings.json'
    if (Test-Path $worldFile) {
        $world = Get-Content $worldFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $world.PSObject.Properties) {
            if ($prop.Name -notlike '_*') { $options[$prop.Name] = [string]$prop.Value }
        }
    }

    # Identity / network settings come from server.config.json (single source of truth)
    $options['ServerName']        = '"{0}"' -f $cfg.server.name
    $options['ServerDescription'] = '"{0}"' -f $cfg.server.description
    $options['ServerPassword']    = '"{0}"' -f $cfg.server.serverPassword
    $options['AdminPassword']     = '"{0}"' -f $cfg.server.adminPassword
    $options['ServerPlayerMaxNum'] = [string]$cfg.server.maxPlayers
    $options['PublicPort']        = [string]$cfg.server.publicPort
    $options['RCONPort']          = [string]$cfg.server.rconPort
    $options['RESTAPIPort']       = [string]$cfg.server.restApiPort

    $bad = @($options.Keys | Where-Object { -not (Test-OptionValue -Value $options[$_]) })
    if ($bad) {
        throw "Refusing to write PalWorldSettings.ini: malformed value(s) for $($bad -join ', '). Check Config\world.settings.json."
    }
    $pairs = foreach ($key in $options.Keys) { '{0}={1}' -f $key, $options[$key] }
    New-Item -ItemType Directory -Force -Path $liveDir | Out-Null
    $content = "[/Script/Pal.PalGameWorldSettings]`r`nOptionSettings=({0})" -f ($pairs -join ',')
    Set-Content -Path $liveIni -Value $content -Encoding UTF8
    Write-PalLog -Message "Rendered PalWorldSettings.ini ($($options.Count) options)" -Category 'Server'
}

# ---------------------------------------------------------------------------
# Server process control
# ---------------------------------------------------------------------------

function Get-PalServerProcess {
    # PalServer.exe is a launcher; the real server is PalServer-Win64-Shipping-Cmd.exe.
    Get-Process -Name 'PalServer', 'PalServer-Win64-Shipping-Cmd', 'PalServer-Win64-Shipping' -ErrorAction SilentlyContinue
}

function Test-PalServerRunning {
    return [bool](Get-PalServerProcess)
}

function Invoke-PalApi {
    # Calls the official Palworld REST API (requires RESTAPIEnabled=True + AdminPassword).
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [hashtable]$Body
    )
    $cfg = Get-PalConfig
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$($cfg.server.adminPassword)"))
    $params = @{
        Uri        = 'http://127.0.0.1:{0}/v1/api/{1}' -f $cfg.server.restApiPort, $Endpoint
        Method     = $Method
        Headers    = @{ Authorization = "Basic $auth"; Accept = 'application/json' }
        TimeoutSec = 10
    }
    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Compress
        $params.ContentType = 'application/json'
    }
    Invoke-RestMethod @params
}

function Send-PalAnnounce {
    param([Parameter(Mandatory)][string]$Message)
    try {
        Invoke-PalApi -Endpoint 'announce' -Method POST -Body @{ message = $Message } | Out-Null
        Write-PalLog -Message "Announce: $Message" -Category 'Server'
    } catch {
        Write-PalLog -Message "Announce failed (REST API down?): $_" -Level 'WARN' -Category 'Server'
    }
}

function Save-PalWorld {
    try {
        Invoke-PalApi -Endpoint 'save' -Method POST | Out-Null
        Write-PalLog -Message 'World save requested via REST API' -Category 'Server'
        return $true
    } catch {
        Write-PalLog -Message "REST save failed: $_" -Level 'WARN' -Category 'Server'
        return $false
    }
}

function Stop-PalServerGraceful {
    param(
        [int]$WaitSeconds = 15,
        [string]$Message = 'Server is shutting down'
    )
    if (-not (Test-PalServerRunning)) { return }
    Save-PalWorld | Out-Null
    $graceful = $false
    try {
        Invoke-PalApi -Endpoint 'shutdown' -Method POST -Body @{ waittime = $WaitSeconds; message = $Message } | Out-Null
        $graceful = $true
        Write-PalLog -Message "Graceful shutdown requested (wait: ${WaitSeconds}s)" -Category 'Server'
    } catch {
        Write-PalLog -Message "REST shutdown failed, will force-stop: $_" -Level 'WARN' -Category 'Server'
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds + 30)
    while ((Test-PalServerRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (Test-PalServerRunning) {
        if ($graceful) { Write-PalLog -Message 'Server did not exit in time; forcing stop.' -Level 'WARN' -Category 'Server' }
        Get-PalServerProcess | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
    Write-PalLog -Message 'Server stopped.' -Category 'Server'
}

# ---------------------------------------------------------------------------
# Lifecycle helpers (watchdog, health check, maintenance windows)
# ---------------------------------------------------------------------------

function Start-PalWatchdogProcess {
    # Launches Start.ps1 (server + watchdog) detached from the caller.
    $startScript = Join-Path $script:Paths.Scripts 'Start.ps1'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Minimized `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$startScript`""
}

function Get-PalWatchdogProcess {
    # Returns the live watchdog process recorded in .watchdog.pid, or $null.
    $lock = Get-PalPath '.watchdog.pid'
    if (-not (Test-Path $lock)) { return $null }
    $watchdogId = Get-Content -Path $lock -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $watchdogId) { return $null }
    $proc = Get-Process -Id $watchdogId -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.Id -eq $PID) { return $null }
    # PIDs get reused after a reboot: make sure it really is a Start.ps1 instance
    $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
    if ($cim -and $cim.CommandLine -match 'Start\.ps1') { return $proc }
    return $null
}

function Wait-PalWatchdogExit {
    # The watchdog exits by itself once it sees .stop-requested with the server down
    # (it polls every 20s). Wait for that so it can't resurrect the server mid-maintenance.
    param([int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-PalWatchdogProcess) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    $left = Get-PalWatchdogProcess
    if ($left) {
        Write-PalLog -Message "Watchdog PID $($left.Id) did not exit in time; stopping it." -Level 'WARN' -Category 'Server'
        Stop-Process -Id $left.Id -Force
    }
}

function Wait-PalServerHealthy {
    # True once the REST API answers; false if the process dies or the timeout expires.
    param([int]$TimeoutSeconds = 240)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PalServerRunning)) { return $false }
        try {
            Invoke-PalApi -Endpoint 'info' | Out-Null
            return $true
        } catch {
            Start-Sleep -Seconds 5
        }
    }
    return $false
}

function Invoke-WithServerStopped {
    # Runs $Action with the server offline, then brings server + watchdog back
    # if they were running. Returns whatever $Action outputs.
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Reason = 'Server maintenance',
        [int]$WarnSeconds = 60
    )
    $wasRunning = Test-PalServerRunning
    $flag = Get-PalPath '.stop-requested'
    if ($wasRunning) {
        if ($WarnSeconds -gt 0) {
            Send-PalAnnounce -Message "$Reason - server restarting in $WarnSeconds seconds!"
            Start-Sleep -Seconds $WarnSeconds
        }
        Set-Content -Path $flag -Value 'maintenance' -Encoding ASCII
        Stop-PalServerGraceful -WaitSeconds 15 -Message $Reason
        Wait-PalWatchdogExit
    }
    try {
        & $Action
    } finally {
        if ($wasRunning) {
            Remove-Item -Path $flag -Force -ErrorAction SilentlyContinue
            Start-PalWatchdogProcess
            Write-PalLog -Message "Server restarting after: $Reason" -Category 'Server'
        }
    }
}

# ---------------------------------------------------------------------------
# SteamCMD
# ---------------------------------------------------------------------------

function Invoke-SteamCmd {
    # Runs steamcmd.exe with the given arguments; returns captured output lines.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Join-Path $script:Paths.SteamCmd 'steamcmd.exe'
    if (-not (Test-Path $exe)) { throw "steamcmd.exe not found at $exe. Run Install.ps1 first." }
    $output = & $exe @Arguments
    return $output
}

function Update-PalServerBuild {
    # Runs SteamCMD app_update with validate (one retry). The server must be stopped.
    # 'validate' only checks Steam depot files, so mod files (dwmapi.dll, ~mods) survive.
    # Returns @{ Success; Before; After; Changed }.
    $cfg = Get-PalConfig
    $before = Get-ServerBuildId
    $logFile = Join-Path $script:Paths.Logs 'Update\steamcmd-last-run.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $logFile -Parent) | Out-Null
    $success = $false
    foreach ($attempt in 1, 2) {
        $output = Invoke-SteamCmd -Arguments @(
            '+force_install_dir', $script:Paths.Server,
            '+login', 'anonymous',
            '+app_update', $cfg.steam.appId, 'validate',
            '+quit'
        )
        $output | Add-Content -Path $logFile -Encoding UTF8
        if (($output | Select-String -Pattern 'fully installed' -SimpleMatch -Quiet) -and
            (Test-Path (Join-Path $script:Paths.Server 'PalServer.exe'))) {
            $success = $true
            break
        }
        Write-PalLog -Message "SteamCMD attempt $attempt did not finish cleanly." -Level 'WARN' -Category 'Update'
    }
    $after = Get-ServerBuildId
    return @{ Success = $success; Before = $before; After = $after; Changed = ($success -and $before -ne $after) }
}

function Get-ServerBuildId {
    # Reads the installed build id from the Steam app manifest (empty string if unknown).
    $manifest = Join-Path $script:Paths.Server 'steamapps\appmanifest_2394010.acf'
    if (Test-Path $manifest) {
        $match = Select-String -Path $manifest -Pattern '"buildid"\s+"(\d+)"'
        if ($match) { return $match.Matches[0].Groups[1].Value }
    }
    return ''
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

function Get-ContentHash {
    # SHA256 of a file, or an aggregate SHA256 for a folder (stable across copies).
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path -PathType Leaf) {
        return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    }
    $entries = Get-ChildItem -Path $Path -Recurse -File | Sort-Object FullName | ForEach-Object {
        (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash + $_.FullName.Substring($Path.Length)
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
}

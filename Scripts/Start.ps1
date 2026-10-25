<#
.SYNOPSIS
    Starts the Palworld server with a watchdog loop:
      - automatic backups every N minutes (backup.intervalMinutes)
      - daily restart at restart.dailyAt with in-game warnings
      - optional server + mod auto-update during the daily restart (restart.autoUpdate)
      - automatic restart if the server crashes
      - safe mode: after 3 crashes in 10 minutes UE4SS (all Lua/PalSchema mods) is disabled
.EXAMPLE
    .\Start.ps1               # start + watchdog (recommended; keep the window open)
    .\Start.ps1 -NoWatchdog   # just launch the server process and exit
#>
[CmdletBinding()]
param(
    [switch]$NoWatchdog
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

$cfg = Get-PalConfig
$serverExe = Join-Path $script:Paths.Server 'PalServer.exe'
$stopFlag = Get-PalPath '.stop-requested'
$watchdogLock = Get-PalPath '.watchdog.pid'

if (-not (Test-Path $serverExe)) {
    Write-PalLog -Message 'PalServer.exe not found. Run Install.ps1 first.' -Level 'ERROR' -Category 'Server'
    exit 1
}

# Single watchdog instance: take the lock before touching the server so two
# launches (e.g. a double click in the panel) can't both start it.
if (-not $NoWatchdog) {
    $other = Get-PalWatchdogProcess
    if ($other) {
        Write-PalLog -Message "Another watchdog is already active (PID $($other.Id)) - exiting to avoid duplicates." -Level 'WARN' -Category 'Server'
        exit 0
    }
    Set-Content -Path $watchdogLock -Value $PID -Encoding ASCII
}
Remove-Item -Path $stopFlag -Force -ErrorAction SilentlyContinue

function Start-PalServerProcess {
    if (Test-PalServerRunning) { return $true }
    Build-PalWorldSettings
    $launchArgs = @("-port=$($cfg.server.port)", "-publicport=$($cfg.server.publicPort)") + @($cfg.server.launchArgs)
    Start-Process -FilePath $serverExe -ArgumentList $launchArgs -WorkingDirectory $script:Paths.Server -WindowStyle Minimized
    $script:lastAliveAt = Get-Date
    $script:answeredSinceStart = $false
    Write-PalLog -Message "Server starting (port $($cfg.server.port), args: $($launchArgs -join ' '))" -Category 'Server'
    Start-Sleep -Seconds 10
    if (-not (Test-PalServerRunning)) {
        Write-PalLog -Message 'Server process exited immediately after launch. Check Server\Pal\Saved\Crashes.' -Level 'ERROR' -Category 'Server'
        return $false
    }
    return $true
}

if (Test-PalServerRunning) {
    if ($NoWatchdog) {
        Write-PalLog -Message 'Server is already running.' -Level 'WARN' -Category 'Server'
        exit 0
    }
    Write-PalLog -Message 'Server already running - watchdog attaching to it.' -Category 'Server'
} elseif (-not (Start-PalServerProcess)) {
    if ($NoWatchdog) { exit 1 }
    # The watchdog loop below retries and counts this towards the crash-loop limit
}
if ($NoWatchdog) {
    Write-PalLog -Message 'Started without watchdog: no auto-backup / auto-restart in this mode.' -Level 'WARN' -Category 'Server'
    exit 0
}

# ---------------------------------------------------------------------------
# Watchdog helpers
# ---------------------------------------------------------------------------

function Get-NextDailyRestart {
    $time = [TimeSpan]::Parse($cfg.restart.dailyAt)
    $candidate = (Get-Date).Date + $time
    if ((Get-Date) -ge $candidate) { $candidate = $candidate.AddDays(1) }
    return $candidate
}

function Enable-PalSafeMode {
    # A game patch or a bad mod usually crash-loops through UE4SS. Turning it off
    # keeps the vanilla server (and pak mods) playable until someone looks at it.
    $ue4ss = Get-RegistryEntry -Name 'UE4SS'
    if (-not $ue4ss -or $ue4ss.state -ne 'enabled') {
        Write-PalLog -Message 'Crash loop detected, but UE4SS is already off - nothing left to disable.' -Level 'ERROR' -Category 'Server'
        return
    }
    Write-PalLog -Message 'Crash loop detected (3 crashes in 10 min): SAFE MODE - disabling UE4SS and all Lua/PalSchema mods. Re-enable with Scripts\EnableMod.ps1 -Name UE4SS once fixed.' -Level 'ERROR' -Category 'Server'
    try { Set-PalModEnabled -Name 'UE4SS' -Enabled $false }
    catch { Write-PalLog -Message "Could not enter safe mode: $_" -Level 'ERROR' -Category 'Server' }
}

function Invoke-PalAutoUpdate {
    # Runs with the server stopped, during the daily restart window.
    try {
        $result = Update-PalServerBuild
        if (-not $result.Success) {
            Write-PalLog -Message 'Auto-update: SteamCMD failed - keeping the current build (see Logs\Update\steamcmd-last-run.log).' -Level 'ERROR' -Category 'Update'
        } elseif ($result.Changed) {
            Write-PalLog -Message "Auto-update: server build $($result.Before) -> $($result.After)" -Category 'Update'
        } else {
            Write-PalLog -Message "Auto-update: server already on build $($result.After)" -Category 'Update'
        }
        $changed = Sync-PalMods
        Write-PalLog -Message "Auto-update: $changed mod(s) updated" -Category 'Update'
    } catch {
        Write-PalLog -Message "Auto-update failed: $_" -Level 'ERROR' -Category 'Update'
    }
}

# ---------------------------------------------------------------------------
# Watchdog loop
# ---------------------------------------------------------------------------

$autoUpdate = [bool](Get-ModProp $cfg.restart 'autoUpdate' $false)
# Hang detection needs the REST API; a server that is alive but has not answered
# for this long (boot included) is killed and treated as a crash.
$liveIni = Join-Path $script:Paths.Server 'Pal\Saved\Config\WindowsServer\PalWorldSettings.ini'
$hangDetection = (Get-Content $liveIni -Raw -ErrorAction SilentlyContinue) -match 'RESTAPIEnabled=True'
$hangLimit = [TimeSpan]::FromMinutes(10)
$script:lastAliveAt = Get-Date
$script:answeredSinceStart = $false
$bootHangs = 0
$nextBackup = (Get-Date).AddMinutes([int]$cfg.backup.intervalMinutes)
$nextRestart = Get-NextDailyRestart
$warned = @{}
$crashTimes = New-Object System.Collections.Generic.List[datetime]
Write-PalLog -Message "Watchdog active. Backups every $($cfg.backup.intervalMinutes) min; daily restart at $($cfg.restart.dailyAt) (next: $nextRestart, auto-update: $autoUpdate)." -Category 'Server'

while ($true) {
    Start-Sleep -Seconds 20

    # Stop requested via Stop.ps1 / maintenance: exit once the server is down
    if (Test-Path $stopFlag) {
        if (-not (Test-PalServerRunning)) {
            Write-PalLog -Message 'Stop requested - watchdog exiting.' -Category 'Server'
            Remove-Item -Path $watchdogLock -Force -ErrorAction SilentlyContinue
            break
        }
        continue
    }

    # Crash detection + crash-loop protection
    if (-not (Test-PalServerRunning)) {
        $crashTimes.Add((Get-Date))
        $recent = @($crashTimes | Where-Object { $_ -gt (Get-Date).AddMinutes(-10) })
        if ($recent.Count -ge 3) {
            Enable-PalSafeMode
            $crashTimes.Clear()
        }
        Write-PalLog -Message 'Server process is gone (crash?). Restarting...' -Level 'WARN' -Category 'Server'
        if (-not (Start-PalServerProcess)) {
            Write-PalLog -Message 'Restart failed; retrying in 60s.' -Level 'ERROR' -Category 'Server'
            Start-Sleep -Seconds 60
        }
        continue
    }

    # Hang detection: process alive but unresponsive
    if ($hangDetection) {
        try {
            Invoke-PalApi -Endpoint 'info' | Out-Null
            $script:lastAliveAt = Get-Date
            $script:answeredSinceStart = $true
            $bootHangs = 0
        } catch {
            if (((Get-Date) - $script:lastAliveAt) -gt $hangLimit) {
                Write-PalLog -Message "Server unresponsive for $([int]$hangLimit.TotalMinutes) min (hung) - killing it." -Level 'ERROR' -Category 'Server'
                if (-not $script:answeredSinceStart) {
                    # Hung during boot; two in a row means it will never come up as configured
                    $bootHangs++
                    if ($bootHangs -ge 2) { Enable-PalSafeMode; $bootHangs = 0 }
                }
                Get-PalServerProcess | Stop-Process -Force
                continue
            }
        }
    }

    # Periodic backup
    if ((Get-Date) -ge $nextBackup) {
        try { & "$PSScriptRoot\Backup.ps1" -Reason 'auto' -Quiet }
        catch { Write-PalLog -Message "Auto-backup failed: $_" -Level 'ERROR' -Category 'Backup' }
        $nextBackup = (Get-Date).AddMinutes([int]$cfg.backup.intervalMinutes)
    }

    # Daily restart warnings + restart (+ auto-update)
    $minutesLeft = ($nextRestart - (Get-Date)).TotalMinutes
    foreach ($w in @($cfg.restart.warningMinutes)) {
        if ($minutesLeft -le $w -and $minutesLeft -gt 0 -and -not $warned.ContainsKey($w)) {
            Send-PalAnnounce -Message "Scheduled server restart in $w minute(s)."
            $warned[$w] = $true
        }
    }
    if ((Get-Date) -ge $nextRestart) {
        Write-PalLog -Message 'Daily restart triggered.' -Category 'Server'
        Send-PalAnnounce -Message 'Restarting now. Back in a few minutes!'
        try { & "$PSScriptRoot\Backup.ps1" -Reason 'restart' -Quiet }
        catch { Write-PalLog -Message "Pre-restart backup failed: $_" -Level 'ERROR' -Category 'Backup' }
        Stop-PalServerGraceful -WaitSeconds 15 -Message 'Daily restart'
        if ($autoUpdate) { Invoke-PalAutoUpdate }
        Start-PalServerProcess | Out-Null
        $nextRestart = Get-NextDailyRestart
        $warned = @{}
        Write-PalLog -Message "Daily restart complete. Next: $nextRestart" -Category 'Server'
    }
}

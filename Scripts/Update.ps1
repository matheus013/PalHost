<#
.SYNOPSIS
    Updates the Palworld dedicated server via SteamCMD, then updates the mods
    (UE4SS/PalSchema usually need a matching release after a game patch).
    Backs up saves first; if the server was running it is stopped with an in-game
    warning, updated, restarted and health-checked.
.EXAMPLE
    .\Update.ps1
    .\Update.ps1 -SkipBackup -SkipMods
#>
[CmdletBinding()]
param(
    [switch]$SkipBackup,
    [switch]$SkipMods
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

$cfg = Get-PalConfig
Write-PalLog -Message '=== Server update started ===' -Category 'Update'

if (-not $SkipBackup -and $cfg.backup.beforeUpdate -and (Test-Path (Join-Path $script:Paths.Server 'Pal\Saved'))) {
    & "$PSScriptRoot\Backup.ps1" -Reason 'preupdate' -Quiet
}

$wasRunning = Test-PalServerRunning
$result = Invoke-WithServerStopped -Reason 'Server update' -WarnSeconds 60 -Action {
    $r = Update-PalServerBuild
    if ($r.Success -and -not $SkipMods) {
        $changed = Sync-PalMods
        Write-PalLog -Message "$changed mod(s) updated" -Category 'Update'
    }
    $r
}

if (-not $result.Success) {
    Write-PalLog -Message 'Update FAILED - saves untouched, previous build kept. See Logs\Update\steamcmd-last-run.log.' -Level 'ERROR' -Category 'Update'
    exit 1
}
if ($result.Changed) {
    Write-PalLog -Message "Server updated: build $($result.Before) -> $($result.After)" -Category 'Update'
} else {
    Write-PalLog -Message "Server already up to date (build $($result.After))." -Category 'Update'
}

if ($wasRunning) {
    if (Wait-PalServerHealthy -TimeoutSeconds 300) {
        Write-PalLog -Message 'Server is up and answering after the update.' -Category 'Update'
    } else {
        Write-PalLog -Message 'Server did not answer within 5 min after the update. The watchdog enters safe mode (UE4SS off) if it keeps crashing; check Server\Pal\Saved\Crashes.' -Level 'ERROR' -Category 'Update'
    }
}
Write-PalLog -Message '=== Server update finished ===' -Category 'Update'

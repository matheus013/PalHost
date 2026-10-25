<#
.SYNOPSIS
    Checks every mod for updates (Nexus API, GitHub releases, local files) and,
    only when something changed, stops the server with an in-game warning,
    applies the updates (with automatic backup/rollback) and restarts it.
.EXAMPLE
    .\UpdateMods.ps1
    .\UpdateMods.ps1 -Name PalSchema
    .\UpdateMods.ps1 -NoRestart     # download only while the server is running
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [switch]$NoRestart
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

Write-PalLog -Message '=== Mod update check started ===' -Category 'Mods'

$pending = @(Get-PalModPendingChanges -Name $Name)
if (-not $pending) {
    Write-PalLog -Message 'All mods are up to date - no restart needed.' -Category 'Mods'
    exit 0
}
if ($NoRestart -and (Test-PalServerRunning)) {
    Write-PalLog -Message "Updates downloaded but NOT applied (server running, -NoRestart): $($pending -join ', ')" -Level 'WARN' -Category 'Mods'
    exit 0
}

$changed = Invoke-WithServerStopped -Reason 'Mod updates' -WarnSeconds 60 -Action { Sync-PalMods -Name $pending }
Write-PalLog -Message "=== Mod update finished: $changed mod(s) changed ===" -Category 'Mods'
Get-PalModList | Format-Table -AutoSize

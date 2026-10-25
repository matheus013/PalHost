<#
.SYNOPSIS
    Installs every enabled mod from Config/mods.json (or a subset). Idempotent.
    If the server is running and something needs to change, it is stopped with an
    in-game warning and restarted afterwards.
.EXAMPLE
    .\InstallMods.ps1                    # sync everything
    .\InstallMods.ps1 -Name MapUnlocker  # single mod
    .\InstallMods.ps1 -Force             # reinstall even if unchanged
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [switch]$Force
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

Write-PalLog -Message '=== Mod sync started ===' -Category 'Mods'
if (-not $Force -and -not @(Get-PalModPendingChanges -Name $Name)) {
    Write-PalLog -Message '=== Mod sync finished: everything already up to date ===' -Category 'Mods'
} else {
    $changed = Invoke-WithServerStopped -Reason 'Installing mods' -WarnSeconds 30 -Action { Sync-PalMods -Name $Name -Force:$Force }
    Write-PalLog -Message "=== Mod sync finished: $changed mod(s) changed ===" -Category 'Mods'
}
Get-PalModList | Format-Table -AutoSize

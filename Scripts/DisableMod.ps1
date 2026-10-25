<#
.SYNOPSIS
    Disables a mod: sets enabled=false in Config/mods.json and removes its
    deployed files (the canonical copy is kept for quick re-enable).
    Restarts the server with a warning if it is running.
.EXAMPLE
    .\DisableMod.ps1 -Name MapUnlocker
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

$mod = Get-ModDefinition -Name $Name
$entry = Get-RegistryEntry -Name $Name
if (-not (Get-ModProp $mod 'enabled' $true) -and (-not $entry -or $entry.state -ne 'enabled')) {
    Write-PalLog -Message "[$Name] already disabled - nothing to do" -Category 'Mods'
    exit 0
}

Invoke-WithServerStopped -Reason "Disabling mod $Name" -WarnSeconds 30 -Action {
    Set-PalModEnabled -Name $Name -Enabled $false
}

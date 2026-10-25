<#
.SYNOPSIS
    Enables a mod: sets enabled=true in Config/mods.json and deploys its files
    (restarting the server with a warning if it is running).
.EXAMPLE
    .\EnableMod.ps1 -Name BetterPalbox
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

$mod = Get-ModDefinition -Name $Name
$entry = Get-RegistryEntry -Name $Name
if ((Get-ModProp $mod 'enabled' $true) -and $entry -and $entry.state -eq 'enabled') {
    Write-PalLog -Message "[$Name] already enabled - nothing to do" -Category 'Mods'
    exit 0
}

Invoke-WithServerStopped -Reason "Enabling mod $Name" -WarnSeconds 30 -Action {
    Set-PalModEnabled -Name $Name -Enabled $true
    if (-not (Get-RegistryEntry -Name $Name)) {
        Write-PalLog -Message "[$Name] enabled but not installed yet - running installer." -Category 'Mods'
        Sync-PalMods -Name @($Name) | Out-Null
    }
}

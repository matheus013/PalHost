<#
.SYNOPSIS
    Uninstalls a mod (undeploys files, deletes the canonical copy, keeps a backup).
    Refuses to remove a mod that others depend on unless -Force is used.
    Restarts the server with a warning if it is running.
.EXAMPLE
    .\RemoveMod.ps1 -Name MapUnlocker
    .\RemoveMod.ps1 -Name UE4SS -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [switch]$Force
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

if (-not (Get-RegistryEntry -Name $Name)) {
    Write-PalLog -Message "[$Name] not installed - nothing to do" -Category 'Mods'
    exit 0
}
$dependents = @(Get-ModDependents -Name $Name)
if ($dependents -and -not $Force) {
    Write-PalLog -Message "Cannot remove '$Name': required by $($dependents -join ', '). Remove those first or use -Force." -Level 'ERROR' -Category 'Mods'
    exit 1
}

Invoke-WithServerStopped -Reason "Removing mod $Name" -WarnSeconds 30 -Action {
    Uninstall-PalMod -Name $Name -Force:$Force
}

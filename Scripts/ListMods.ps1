<#
.SYNOPSIS
    Lists all mods: desired state (mods.json) joined with installed state (registry).
.EXAMPLE
    .\ListMods.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

Get-PalModList | Format-Table -AutoSize

<#
.SYNOPSIS
    Creates (or refreshes) the "PalHost Server" desktop shortcut that opens the
    control panel (Launcher.ps1). Paths are resolved from this script's location,
    so it works wherever the project is cloned.
.EXAMPLE
    .\CreateShortcut.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib\Common.ps1"

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop 'PalHost Server.lnk'
$launcher = Join-Path $script:Paths.Scripts 'Launcher.ps1'
$icon = Join-Path $script:Paths.Server 'PalServer.exe'

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($lnkPath)
# Absolute powershell.exe path: never rely on the .ps1 file association (it opens an editor)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
$lnk.WorkingDirectory = $script:Paths.Scripts
if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
$lnk.Description = 'Painel do servidor Palworld'
$lnk.Save()
Write-PalLog -Message "Desktop shortcut ready: $lnkPath" -Category 'Install'

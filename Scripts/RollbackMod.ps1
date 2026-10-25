<#
.SYNOPSIS
    Rolls a mod back to a previous version (backups are created automatically
    before every update; the last 10 are kept in Mods\Cache\Backups\<Name>).
    Restarts the server with a warning if it is running.
.EXAMPLE
    .\RollbackMod.ps1 -Name PalSchema            # roll back to the newest backup
    .\RollbackMod.ps1 -Name PalSchema -List      # show available backups
    .\RollbackMod.ps1 -Name PalSchema -BackupFile PalSchema_20260730_120000.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$BackupFile,
    [switch]$List
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

$dir = Join-Path $script:ModPaths.ModBackups $Name
if ($List) {
    $files = Get-ChildItem -Path $dir -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $files) { Write-Host "No backups for '$Name'."; exit 0 }
    $files | ForEach-Object { '{0,-45} {1}' -f $_.Name, $_.LastWriteTime } | Write-Host
    exit 0
}

$full = $null
if ($BackupFile) { $full = Join-Path $dir $BackupFile }
Invoke-WithServerStopped -Reason "Rolling back mod $Name" -WarnSeconds 30 -Action {
    Restore-ModBackup -Name $Name -BackupFile $full
}

<#
.SYNOPSIS
    Restores a save backup from Backups\ into the server.
    With no arguments it lists the available backups.
.EXAMPLE
    .\Restore.ps1                          # list backups
    .\Restore.ps1 -Latest                  # restore the newest backup
    .\Restore.ps1 -BackupFile PalSaves_20260731_050000_auto.zip
#>
[CmdletBinding()]
param(
    [string]$BackupFile,
    [switch]$Latest,
    [switch]$Force
)

. "$PSScriptRoot\lib\Common.ps1"

$backups = Get-ChildItem -Path $script:Paths.Backups -Filter 'PalSaves_*.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if (-not $BackupFile -and -not $Latest) {
    if (-not $backups) { Write-Host 'No backups found in Backups\.'; exit 0 }
    Write-Host "`nAvailable backups (newest first):`n"
    $backups | ForEach-Object {
        '{0,-55} {1,8:N1} MB  {2}' -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime
    } | Write-Host
    Write-Host "`nRestore with:  .\Restore.ps1 -BackupFile <name>   or   .\Restore.ps1 -Latest"
    exit 0
}

if ($Latest) {
    if (-not $backups) { Write-PalLog -Message 'No backups available.' -Level 'ERROR' -Category 'Backup'; exit 1 }
    $target = $backups[0].FullName
} else {
    $target = $BackupFile
    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $script:Paths.Backups $target }
    if (-not (Test-Path $target)) { Write-PalLog -Message "Backup not found: $target" -Level 'ERROR' -Category 'Backup'; exit 1 }
}

if (Test-PalServerRunning) {
    if (-not $Force) {
        Write-PalLog -Message 'Server is running. Stop it first (Stop.ps1) or use -Force.' -Level 'ERROR' -Category 'Backup'
        exit 1
    }
    & "$PSScriptRoot\Stop.ps1" -Message 'Restoring a backup'
}

# Safety net: snapshot the current state before overwriting it
& "$PSScriptRoot\Backup.ps1" -Reason 'prerestore' -Quiet

$saved = Join-Path $script:Paths.Server 'Pal\Saved'
$saveGames = Join-Path $saved 'SaveGames'
Write-PalLog -Message "Restoring $(Split-Path $target -Leaf)..." -Category 'Backup'
if (Test-Path $saveGames) { Remove-Item -Path $saveGames -Recurse -Force }
Expand-Archive -Path $target -DestinationPath $saved -Force
Write-PalLog -Message 'Restore complete. Start the server with Start.ps1.' -Category 'Backup'

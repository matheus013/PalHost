<#
.SYNOPSIS
    Backs up the whole Server\Pal\Saved folder (world, players, config) to Backups\.
    Safe to run while the server is online (asks the server to save first,
    then snapshots via robocopy to avoid file locks).
.EXAMPLE
    .\Backup.ps1
    .\Backup.ps1 -Reason 'before-mod-test'
#>
[CmdletBinding()]
param(
    [string]$Reason = 'manual',
    [switch]$Quiet
)

. "$PSScriptRoot\lib\Common.ps1"

$cfg = Get-PalConfig
$source = Join-Path $script:Paths.Server 'Pal\Saved'
if (-not (Test-Path $source)) {
    Write-PalLog -Message 'Nothing to back up yet (Server\Pal\Saved does not exist).' -Level 'WARN' -Category 'Backup'
    exit 0
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (Test-PalServerRunning) {
    if (-not $Quiet) { Send-PalAnnounce -Message 'Saving world (backup)...' }
    Save-PalWorld | Out-Null
    Start-Sleep -Seconds 5   # give the server time to flush .sav files
}

# Snapshot to a temp folder first: robocopy retries around transient locks
$safeReason = ($Reason -replace '[^\w\-]', '_')
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$staging = Join-Path $env:TEMP "palhost-backup-$stamp"
& robocopy $source $staging /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-PalLog -Message "Backup FAILED: robocopy exit code $LASTEXITCODE" -Level 'ERROR' -Category 'Backup'
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

New-Item -ItemType Directory -Force -Path $script:Paths.Backups | Out-Null
$zip = Join-Path $script:Paths.Backups "PalSaves_${stamp}_${safeReason}.zip"
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item -Path $staging -Recurse -Force

# Rotation: keep the newest backup.retention archives
Get-ChildItem -Path $script:Paths.Backups -Filter 'PalSaves_*.zip' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip ([int]$cfg.backup.retention) |
    Remove-Item -Force

$sw.Stop()
$sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-PalLog -Message "Backup created: $(Split-Path $zip -Leaf) (${sizeMb} MB, $([int]$sw.Elapsed.TotalSeconds)s, reason: $Reason)" -Category 'Backup'

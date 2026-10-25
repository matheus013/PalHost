<#
.SYNOPSIS
    Creates a migration package with everything that is NOT in git:
      - a fresh backup of the world (Server\Pal\Saved, incl. the world id mapping)
      - Config\*.json as they are now (incl. server.config.json with the secrets)
      - manually downloaded mod archives (newest per mod in Mods\Nexus) and Mods\Local
    Safe to run while the server is online. Restore it with Import.ps1 on the new PC.
.NOTES
    The package contains the admin password and the Nexus API key: keep it private
    and never commit it.
.EXAMPLE
    .\Export.ps1
    .\Export.ps1 -OutFile D:\PalHost-Migration.zip
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not $OutFile) { $OutFile = Join-Path $script:Paths.Backups "Migration\PalHost-Migration_$stamp.zip" }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-PalLog -Message '=== Migration export started ===' -Category 'Migration'

# --- 1. Fresh world backup (asks a running server to save first) -----------
& "$PSScriptRoot\Backup.ps1" -Reason 'migration' -Quiet
$world = Get-ChildItem -Path $script:Paths.Backups -Filter 'PalSaves_*_migration.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $world -or $world.LastWriteTime -lt (Get-Date).AddMinutes(-10)) {
    Write-PalLog -Message 'World backup failed - nothing exported.' -Level 'ERROR' -Category 'Migration'
    exit 1
}

$staging = Join-Path $script:ModPaths.Staging "export-$stamp"
foreach ($dir in 'Config', 'World', 'Mods\Nexus', 'Mods\Local') {
    New-Item -ItemType Directory -Force -Path (Join-Path $staging $dir) | Out-Null
}
Copy-Item -Path $world.FullName -Destination (Join-Path $staging 'World')

# --- 2. Live configuration (the repo only has the example with no secrets) -
Copy-Item -Path (Join-Path $script:Paths.Config '*.json') -Destination (Join-Path $staging 'Config')

# --- 3. Mod archives that can't be re-downloaded automatically -------------
# Newest file per mod = exactly what the installer picks on the other side.
$archives = @()
foreach ($modDir in (Get-ChildItem -Path $script:ModPaths.Nexus -Directory -ErrorAction SilentlyContinue)) {
    $newest = Get-ChildItem -Path $modDir.FullName -File |
        Where-Object { $_.Extension -in '.zip', '.rar', '.7z', '.pak' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) {
        $dest = Join-Path $staging "Mods\Nexus\$($modDir.Name)"
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Path $newest.FullName -Destination $dest
        $archives += "$($modDir.Name)/$($newest.Name)"
    }
}
$localMods = Join-Path $script:Paths.Mods 'Local'
if (Get-ChildItem -Path $localMods -Recurse -File -ErrorAction SilentlyContinue) {
    Copy-Item -Path (Join-Path $localMods '*') -Destination (Join-Path $staging 'Mods\Local') -Recurse
}

# --- 4. Manifest -------------------------------------------------------------
$manifest = [ordered]@{
    format        = 1
    createdAt     = (Get-Date -Format 's')
    sourceMachine = $env:COMPUTERNAME
    serverBuildId = Get-ServerBuildId
    worldBackup   = $world.Name
    modArchives   = $archives
    installedMods = @(Get-ModRegistry | ForEach-Object { [ordered]@{ name = $_.name; version = $_.version; state = $_.state } })
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $staging 'manifest.json') -Encoding UTF8

New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutFile -CompressionLevel Optimal -Force
Remove-Item -Path $staging -Recurse -Force

$sw.Stop()
$sizeMb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
Write-PalLog -Message "Migration package created: $OutFile ($sizeMb MB, $($archives.Count) mod archives, $([int]$sw.Elapsed.TotalSeconds)s)" -Category 'Migration'
Write-Host ''
Write-Host '  Migration package ready:' -ForegroundColor Green
Write-Host "  $OutFile"
Write-Host '  It contains the admin password and the Nexus API key - keep it private (USB drive, private cloud folder).'
Write-Host '  On the new PC: git clone the repo, then run Scripts\Import.ps1 -Package <this zip> as Administrator.'

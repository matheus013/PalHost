<#
.SYNOPSIS
    Sets up this machine from a migration package made by Export.ps1:
    restores the configuration and mod archives, runs the full installer
    (VC++ runtime, SteamCMD, server, mods, firewall, shortcut) and restores the world.
    Run it as Administrator from a fresh `git clone` of the project.
.EXAMPLE
    .\Import.ps1 -Package D:\PalHost-Migration_20261025_120000.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Package,
    [switch]$SkipFirewall,
    [switch]$SkipShortcut,
    [switch]$RegisterAutoStart
)

. "$PSScriptRoot\lib\Common.ps1"

if (-not (Test-Path $Package)) {
    Write-PalLog -Message "Package not found: $Package" -Level 'ERROR' -Category 'Migration'
    exit 1
}
if (Test-PalServerRunning) {
    Write-PalLog -Message 'A Palworld server is running on this machine - stop it first (Scripts\Stop.ps1).' -Level 'ERROR' -Category 'Migration'
    exit 1
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-PalLog -Message "=== Migration import started: $Package ===" -Category 'Migration'
New-PalDirectoryTree
$staging = Join-Path $script:Paths.Mods ("Cache\Staging\import-{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Expand-Archive -Path $Package -DestinationPath $staging -Force

$manifestFile = Join-Path $staging 'manifest.json'
if (-not (Test-Path $manifestFile)) {
    Write-PalLog -Message 'Not a PalHost migration package (manifest.json missing).' -Level 'ERROR' -Category 'Migration'
    exit 1
}
$manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
Write-PalLog -Message "Package from '$($manifest.sourceMachine)' created $($manifest.createdAt) (server build $($manifest.serverBuildId))" -Category 'Migration'

# --- 1. Configuration: the package holds the live state at export time -----
foreach ($file in (Get-ChildItem -Path (Join-Path $staging 'Config') -Filter '*.json')) {
    $target = Join-Path $script:Paths.Config $file.Name
    if ((Test-Path $target) -and ((Get-FileHash $target).Hash -ne (Get-FileHash $file.FullName).Hash)) {
        Copy-Item -Path $target -Destination "$target.bak" -Force
        Write-PalLog -Message "Config\$($file.Name) replaced (previous copy kept as $($file.Name).bak)" -Category 'Migration'
    }
    Copy-Item -Path $file.FullName -Destination $target -Force
}
# Configuration loaded by Common.ps1 earlier is stale now
Get-PalConfig -Reload | Out-Null

# --- 2. Mod archives -------------------------------------------------------
foreach ($sub in 'Nexus', 'Local') {
    $src = Join-Path $staging "Mods\$sub"
    if (Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue) {
        Copy-Item -Path (Join-Path $src '*') -Destination (Join-Path $script:Paths.Mods $sub) -Recurse -Force
    }
}
Write-PalLog -Message "Restored $(@($manifest.modArchives).Count) mod archive(s)" -Category 'Migration'

# --- 3. Full install (prereqs, SteamCMD, server, mods, firewall, shortcut) -
& "$PSScriptRoot\Install.ps1" -SkipFirewall:$SkipFirewall -SkipShortcut:$SkipShortcut -RegisterAutoStart:$RegisterAutoStart
if (-not (Test-Path (Join-Path $script:Paths.Server 'PalServer.exe'))) {
    Write-PalLog -Message 'Install did not complete - fix the error above and run Import.ps1 again (it is safe to repeat).' -Level 'ERROR' -Category 'Migration'
    exit 1
}

# --- 4. World ----------------------------------------------------------------
$world = Get-ChildItem -Path (Join-Path $staging 'World') -Filter '*.zip' | Select-Object -First 1
if ($world) {
    Copy-Item -Path $world.FullName -Destination $script:Paths.Backups -Force
    & "$PSScriptRoot\Restore.ps1" -BackupFile $world.Name
} else {
    Write-PalLog -Message 'Package has no world backup - starting with a new world.' -Level 'WARN' -Category 'Migration'
}
Remove-Item -Path $staging -Recurse -Force

$sw.Stop()
Write-PalLog -Message "=== Migration import finished ($([int]$sw.Elapsed.TotalMinutes) min) ===" -Category 'Migration'
Write-Host ''
Write-Host '  Migration complete!' -ForegroundColor Green
Write-Host '  Next steps:'
Write-Host '    1. Start the server: desktop shortcut "PalHost Server" or Scripts\Start.ps1'
Write-Host '    2. Forward UDP 8211 on the router to THIS machine (the old PC no longer needs it)'
Write-Host '    3. If you also play on this PC: Scripts\BuildClientMods.ps1 -InstallToLocalGame'
Write-Host '    4. Do not run the old server anymore - two copies of the world would diverge.'

# ModManager.ps1 - package-manager-style mod handling for the Palworld server.
# Requires Common.ps1 to be dot-sourced first.
#
# Design:
#   Config/mods.json          -> desired state (edited by the user)
#   Mods/Installed/<Name>/    -> canonical copy of each installed mod payload
#   Mods/Installed/registry.json -> installed state (version, hash, deployed files)
#   Server/...                -> deployed files (copied from the canonical copy)
#
# All operations are idempotent: running them twice is safe.

Set-StrictMode -Version Latest

$script:ModPaths = @{
    ModsFile   = Join-Path $script:Paths.Config 'mods.json'
    Registry   = Join-Path $script:Paths.Mods 'Installed\registry.json'
    Installed  = Join-Path $script:Paths.Mods 'Installed'
    Staging    = Join-Path $script:Paths.Mods 'Cache\Staging'
    ModBackups = Join-Path $script:Paths.Mods 'Cache\Backups'
    Nexus      = Join-Path $script:Paths.Mods 'Nexus'
    GitHub     = Join-Path $script:Paths.Mods 'GitHub'
    Downloads  = Join-Path $script:Paths.Mods 'Downloads'
}

$script:ModBackupKeep = 10

function Assert-PalServerStopped {
    # Deployed paks/dlls are locked while the server runs; changing them mid-run leaves
    # half-installed mods. Entry scripts stop the server via Invoke-WithServerStopped.
    if (Test-PalServerRunning) {
        throw 'The server is running - stop it first (the Scripts\*Mod*.ps1 commands do this automatically).'
    }
}

# Safe property access under StrictMode (PSCustomObject may lack optional keys).
function Get-ModProp {
    param($Object, [string]$Name, $Default = $null)
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

# ---------------------------------------------------------------------------
# Desired state (mods.json) and installed state (registry.json)
# ---------------------------------------------------------------------------

function Get-ModsFile {
    Get-Content -Path $script:ModPaths.ModsFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-ModsFile {
    param([Parameter(Mandatory)]$Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ModPaths.ModsFile -Encoding UTF8
}

function Get-ModRegistry {
    if (Test-Path $script:ModPaths.Registry) {
        $data = Get-Content -Path $script:ModPaths.Registry -Raw -Encoding UTF8 | ConvertFrom-Json
        # Force array semantics even for 0/1 entries
        return @($data)
    }
    return @()
}

function Save-ModRegistry {
    param($Registry)
    New-Item -ItemType Directory -Force -Path $script:ModPaths.Installed | Out-Null
    ConvertTo-Json -InputObject @($Registry) -Depth 10 |
        Set-Content -Path $script:ModPaths.Registry -Encoding UTF8
}

function Get-RegistryEntry {
    param([Parameter(Mandatory)][string]$Name)
    return (Get-ModRegistry | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Set-RegistryEntry {
    param([Parameter(Mandatory)]$Entry)
    $registry = @(Get-ModRegistry | Where-Object { $_.name -ne $Entry.name })
    $registry += $Entry
    Save-ModRegistry -Registry $registry
}

function Remove-RegistryEntry {
    param([Parameter(Mandatory)][string]$Name)
    Save-ModRegistry -Registry @(Get-ModRegistry | Where-Object { $_.name -ne $Name })
}

function Get-ModDefinition {
    param([Parameter(Mandatory)][string]$Name)
    $mod = Get-ModsFile | Select-Object -ExpandProperty mods | Where-Object { $_.name -eq $Name }
    if (-not $mod) { throw "Mod '$Name' not found in Config/mods.json" }
    return $mod
}

function Resolve-ModInstallOrder {
    # Topological sort so dependencies install before dependents.
    param([Parameter(Mandatory)][object[]]$Mods)
    $byName = @{}
    foreach ($m in $Mods) { $byName[$m.name] = $m }
    $ordered = New-Object System.Collections.ArrayList
    $visited = @{}
    function Visit-Node {
        param($Mod)
        if ($visited.ContainsKey($Mod.name)) {
            if ($visited[$Mod.name] -eq 'visiting') { throw "Circular mod dependency involving '$($Mod.name)'" }
            return
        }
        $visited[$Mod.name] = 'visiting'
        foreach ($dep in @(Get-ModProp $Mod 'dependsOn' @())) {
            if ($byName.ContainsKey($dep)) { Visit-Node -Mod $byName[$dep] }
        }
        $visited[$Mod.name] = 'done'
        [void]$ordered.Add($Mod)
    }
    foreach ($m in $Mods) { Visit-Node -Mod $m }
    return $ordered.ToArray()
}

function Get-ModDependents {
    # Returns names of installed mods that depend on $Name.
    param([Parameter(Mandatory)][string]$Name)
    $installed = Get-ModRegistry | ForEach-Object { $_.name }
    $result = @()
    foreach ($mod in (Get-ModsFile).mods) {
        if ((@(Get-ModProp $mod 'dependsOn' @()) -contains $Name) -and ($installed -contains $mod.name)) {
            $result += $mod.name
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Providers: locate/fetch the mod payload
# ---------------------------------------------------------------------------

function Get-VersionFromFileName {
    # Extracts "1.2.3"-style version from a filename; falls back to file date.
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    if ($File.BaseName -match '(\d+(?:\.\d+)+)') { return $Matches[1] }
    return $File.LastWriteTime.ToString('yyyy.MM.dd')
}

function Get-SteamWorkshopPayload {
    param([Parameter(Mandatory)]$Mod)
    # NOTE: Palworld has no Steam Workshop as of 1.0. Kept functional for the future.
    $cfg = Get-PalConfig
    $wsId = Get-ModProp $Mod 'workshopId'
    if (-not $wsId) { throw "Mod '$($Mod.name)': provider=steam requires 'workshopId'" }
    Write-PalLog -Message "[$($Mod.name)] downloading Workshop item $wsId via SteamCMD..." -Category 'Mods'
    Invoke-SteamCmd -Arguments @(
        '+login', 'anonymous',
        '+workshop_download_item', $cfg.steam.appId, "$wsId", 'validate',
        '+quit'
    ) | Out-Null
    $path = Join-Path $script:Paths.SteamCmd ("steamapps\workshop\content\{0}\{1}" -f $cfg.steam.appId, $wsId)
    if (-not (Test-Path $path)) { throw "Workshop download failed for '$($Mod.name)' (item $wsId)" }
    return @{ Path = $path; Version = (Get-Date -Format 'yyyy.MM.dd'); Hash = (Get-ContentHash -Path $path) }
}

function Get-NexusApiKey {
    $cfg = Get-PalConfig
    return [string](Get-ModProp $cfg.nexus 'apiKey' '')
}

function Get-NexusLatestFile {
    # Returns @{ FileId; Version; FileName } for the newest MAIN file of a mod, or $null.
    param([Parameter(Mandatory)]$Mod)
    $apiKey = Get-NexusApiKey
    $modId = Get-ModProp $Mod 'modId'
    if (-not $apiKey -or -not $modId) { return $null }
    try {
        $uri = "https://api.nexusmods.com/v1/games/palworld/mods/$modId/files.json"
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ apikey = $apiKey } -TimeoutSec 20
        # Optional 'fileId' in mods.json pins a specific variant (e.g. x5 instead of x10);
        # otherwise take the newest MAIN file.
        $wantId = Get-ModProp $Mod 'fileId'
        if ($wantId) {
            $latest = @($resp.files) | Where-Object { $_.file_id -eq $wantId } | Select-Object -First 1
            if (-not $latest) { Write-PalLog -Message "[$($Mod.name)] fileId $wantId not found on Nexus" -Level 'WARN' -Category 'Mods' }
        } else {
            $latest = @($resp.files) | Where-Object { $_.category_name -eq 'MAIN' } |
                Sort-Object uploaded_timestamp -Descending | Select-Object -First 1
        }
        if (-not $latest) { return $null }
        return @{ FileId = $latest.file_id; Version = [string]$latest.version; FileName = [string]$latest.file_name }
    } catch {
        Write-PalLog -Message "[$($Mod.name)] Nexus file listing failed: $_" -Level 'WARN' -Category 'Mods'
        return $null
    }
}

function Invoke-NexusDownload {
    # Downloads a mod file via the official Nexus API (Premium accounts only).
    # Returns the local file path, or $null when download is not possible.
    param([Parameter(Mandatory)]$Mod, [Parameter(Mandatory)][hashtable]$FileInfo)
    $apiKey = Get-NexusApiKey
    $modId = Get-ModProp $Mod 'modId'
    $dest = Join-Path (Join-Path $script:ModPaths.Nexus $Mod.name) $FileInfo.FileName
    if (Test-Path $dest) { return $dest }   # already downloaded
    try {
        $uri = "https://api.nexusmods.com/v1/games/palworld/mods/$modId/files/$($FileInfo.FileId)/download_link.json"
        $links = Invoke-RestMethod -Uri $uri -Headers @{ apikey = $apiKey } -TimeoutSec 20
        $url = (@($links) | Select-Object -First 1).URI
        if (-not $url) { return $null }
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Write-PalLog -Message "[$($Mod.name)] downloading $($FileInfo.FileName) (v$($FileInfo.Version)) from Nexus..." -Category 'Mods'
        # Download to .part first so an interrupted transfer is never picked up as a payload
        Invoke-WebRequest -Uri $url -OutFile "$dest.part" -UseBasicParsing
        Move-Item -Path "$dest.part" -Destination $dest -Force
        Write-PalLog -Message "[$($Mod.name)] download complete: $($FileInfo.FileName)" -Category 'Mods'
        return $dest
    } catch {
        $msg = "$_"
        if ($msg -match '403|Forbidden|premium') {
            Write-PalLog -Message "[$($Mod.name)] Nexus has v$($FileInfo.Version) ($($FileInfo.FileName)). Auto-download needs Premium - download it manually into Mods\Nexus\$($Mod.name)\" -Level 'WARN' -Category 'Mods'
        } else {
            Write-PalLog -Message "[$($Mod.name)] Nexus download failed: $msg" -Level 'WARN' -Category 'Mods'
        }
        Remove-Item -Path "$dest.part" -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Get-NexusPayload {
    # Nexus provider: tries the official API first (auto-download, Premium only),
    # then falls back to archives the user dropped into Mods/Nexus/<Name>/
    # (or Mods/Downloads/ with the mod name in the filename). Newest file wins.
    param([Parameter(Mandatory)]$Mod)
    $remote = Get-NexusLatestFile -Mod $Mod
    if ($remote) { Invoke-NexusDownload -Mod $Mod -FileInfo $remote | Out-Null }

    $candidates = @()
    $modDir = Join-Path $script:ModPaths.Nexus $Mod.name
    if (Test-Path $modDir) {
        $candidates += Get-ChildItem -Path $modDir -File -Recurse |
            Where-Object { $_.Extension -in '.zip', '.rar', '.7z', '.pak' }
    }
    if (Test-Path $script:ModPaths.Downloads) {
        $candidates += Get-ChildItem -Path $script:ModPaths.Downloads -File |
            Where-Object { $_.BaseName -like "*$($Mod.name)*" -and $_.Extension -in '.zip', '.rar', '.7z', '.pak' }
    }
    $newest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { return $null }
    # Prefer the exact version reported by the Nexus API when this is the API-downloaded file
    $version = Get-VersionFromFileName -File $newest
    if ($remote -and $newest.Name -eq $remote.FileName -and $remote.Version) { $version = $remote.Version }
    return @{
        Path    = $newest.FullName
        Version = $version
        Hash    = (Get-FileHash -Path $newest.FullName -Algorithm SHA256).Hash
    }
}

function Get-LocalPayload {
    param([Parameter(Mandatory)]$Mod)
    $path = Get-ModProp $Mod 'path'
    if (-not $path) { throw "Mod '$($Mod.name)': provider=local requires 'path'" }
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Get-PalPath $path }
    if (-not (Test-Path $path)) { return $null }
    $version = ''
    if (Test-Path $path -PathType Leaf) {
        $version = Get-VersionFromFileName -File (Get-Item $path)
    } else {
        $version = (Get-Item $path).LastWriteTime.ToString('yyyy.MM.dd')
    }
    return @{ Path = $path; Version = $version; Hash = (Get-ContentHash -Path $path) }
}

function Get-GitHubPayload {
    # GitHub provider: an asset from the repo's latest release. mods.json fields:
    #   "repo": "owner/name", "assetPattern": "*.zip", "assetExclude": "*zDev*" (optional)
    # Each release tag is downloaded once into Mods/GitHub/<Name>/<tag>/; the tag is the version.
    # If GitHub is unreachable, the newest cached release is used.
    param([Parameter(Mandatory)]$Mod)
    $repo = Get-ModProp $Mod 'repo'
    if (-not $repo) { throw "Mod '$($Mod.name)': provider=github requires 'repo' (owner/name)" }
    $pattern = Get-ModProp $Mod 'assetPattern' '*.zip'
    $exclude = Get-ModProp $Mod 'assetExclude' ''
    $modDir = Join-Path $script:ModPaths.GitHub $Mod.name
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'PalHost'; Accept = 'application/vnd.github+json' } -TimeoutSec 20
        $asset = @($rel.assets) | Where-Object { $_.name -like $pattern -and -not ($exclude -and $_.name -like $exclude) } |
            Select-Object -First 1
        if (-not $asset) { throw "no asset matching '$pattern' in release $($rel.tag_name)" }
        $tagDir = Join-Path $modDir $rel.tag_name
        $dest = Join-Path $tagDir $asset.name
        if (-not (Test-Path $dest)) {
            New-Item -ItemType Directory -Force -Path $tagDir | Out-Null
            Write-PalLog -Message "[$($Mod.name)] downloading $($asset.name) (release $($rel.tag_name)) from github.com/$repo..." -Category 'Mods'
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$dest.part" -UseBasicParsing
            Move-Item -Path "$dest.part" -Destination $dest -Force
            Write-PalLog -Message "[$($Mod.name)] download complete: $($asset.name)" -Category 'Mods'
        }
    } catch {
        Write-PalLog -Message "[$($Mod.name)] GitHub release check failed ($_) - using cached release if any" -Level 'WARN' -Category 'Mods'
    }
    $cached = Get-ChildItem -Path $modDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $pattern -and -not ($exclude -and $_.Name -like $exclude) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cached) { return $null }
    return @{
        Path    = $cached.FullName
        Version = $cached.Directory.Name
        Hash    = (Get-FileHash -Path $cached.FullName -Algorithm SHA256).Hash
    }
}

function Get-ModPayload {
    # Returns @{ Path; Version; Hash } for the newest available payload, or $null.
    param([Parameter(Mandatory)]$Mod)
    switch ($Mod.provider) {
        'steam'  { return Get-SteamWorkshopPayload -Mod $Mod }
        'nexus'  { return Get-NexusPayload -Mod $Mod }
        'github' { return Get-GitHubPayload -Mod $Mod }
        'local'  { return Get-LocalPayload -Mod $Mod }
        default  { throw "Mod '$($Mod.name)': unknown provider '$($Mod.provider)'" }
    }
}

# ---------------------------------------------------------------------------
# Staging and install-type detection
# ---------------------------------------------------------------------------

function Expand-ModPayload {
    # Extracts/copies a payload into a clean staging directory and returns its path.
    param([Parameter(Mandatory)]$Mod, [Parameter(Mandatory)][hashtable]$Payload)
    $staging = Join-Path $script:ModPaths.Staging $Mod.name
    if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    $src = $Payload.Path
    if (Test-Path $src -PathType Container) {
        Copy-Item -Path (Join-Path $src '*') -Destination $staging -Recurse -Force
    } elseif ($src -match '\.zip$') {
        Expand-Archive -Path $src -DestinationPath $staging -Force
    } elseif ($src -match '\.(rar|7z)$') {
        # Windows built-in tar (bsdtar/libarchive) handles most rar/7z archives;
        # fall back to 7-Zip when it can't.
        & tar -xf $src -C $staging 2>$null
        if ($LASTEXITCODE -ne 0) {
            $sevenZip = Get-Command '7z.exe' -ErrorAction SilentlyContinue
            if (-not $sevenZip) { throw "Mod '$($Mod.name)': could not extract archive (tar failed, 7z.exe not found). Install 7-Zip or repack as .zip." }
            & $sevenZip.Source x $src "-o$staging" -y | Out-Null
        }
    } else {
        # Single file (e.g. a bare .pak)
        Copy-Item -Path $src -Destination $staging -Force
    }

    # Flatten single-folder wrappers (zip-inside-folder is common on Nexus),
    # but never flatten structural folders that mods rely on (UE4SS/pak layout).
    $structural = @('scripts', 'mods', 'ue4ss', 'pal', 'content', 'paks', 'logicmods', 'binaries', 'win64', 'dlls')
    while ($true) {
        $items = @(Get-ChildItem -Path $staging)
        if ($items.Count -eq 1 -and $items[0].PSIsContainer -and
            $structural -notcontains $items[0].Name.ToLower()) {
            $inner = $items[0].FullName
            Get-ChildItem -Path $inner -Force | Move-Item -Destination $staging -Force
            Remove-Item -Path $inner -Recurse -Force
        } else { break }
    }
    return $staging
}

function Get-ModInstallType {
    # Explicit installType wins; otherwise detect from staged content.
    # Exception: payloads rooted at the game directory (a top-level Pal\ folder)
    # are always 'gameroot' overlays, regardless of the declared type.
    param([Parameter(Mandatory)]$Mod, [Parameter(Mandatory)][string]$StagingDir)
    if ((Test-Path (Join-Path $StagingDir 'Pal\Binaries')) -or
        (Test-Path (Join-Path $StagingDir 'Pal\Content'))) { return 'gameroot' }
    $explicit = Get-ModProp $Mod 'installType'
    if ($explicit) { return $explicit }

    if ((Test-Path (Join-Path $StagingDir 'ue4ss')) -or
        (Test-Path (Join-Path $StagingDir 'dwmapi.dll')) -or
        (Test-Path (Join-Path $StagingDir 'UE4SS.dll'))) { return 'ue4ss' }

    $paks = Get-ChildItem -Path $StagingDir -Recurse -Filter '*.pak'
    if ($paks) {
        if ($paks | Where-Object { $_.FullName -match 'LogicMods' }) { return 'logicmods' }
        return 'pak'
    }
    if (Get-ChildItem -Path $StagingDir -Recurse -Filter 'main.lua') { return 'ue4ss-mod' }
    $jsons = Get-ChildItem -Path $StagingDir -Recurse -Filter '*.json'
    if ($jsons) { return 'palschema' }
    throw "Mod '$($Mod.name)': could not auto-detect install type. Set 'installType' in mods.json."
}

function Get-UE4SSModsRoot {
    # UE4SS 3.x keeps everything under Win64\ue4ss\; older/prepackaged builds put
    # UE4SS.dll at the Win64 root and load mods from Win64\Mods. Detect by dll location.
    if (Test-Path (Join-Path $script:Paths.Server 'Pal\Binaries\Win64\ue4ss\UE4SS.dll')) {
        return 'Pal\Binaries\Win64\ue4ss\Mods'
    }
    return 'Pal\Binaries\Win64\Mods'
}

function Get-ModTargetRoot {
    # Deployment root (relative to Server/) for each install type.
    param([Parameter(Mandatory)][string]$InstallType, [Parameter(Mandatory)][string]$Name)
    switch ($InstallType) {
        'gameroot'  { return '.' }
        'ue4ss'     { return 'Pal\Binaries\Win64' }
        'ue4ss-mod' { return (Join-Path (Get-UE4SSModsRoot) $Name) }
        'palschema' { return (Join-Path (Get-UE4SSModsRoot) "PalSchema\mods\$Name") }
        'pak'       { return "Pal\Content\Paks\~mods\$Name" }
        'logicmods' { return 'Pal\Content\Paks\LogicMods' }
        default     { throw "Unknown installType '$InstallType'" }
    }
}

# ---------------------------------------------------------------------------
# Backup / rollback of installed mods
# ---------------------------------------------------------------------------

function Backup-InstalledMod {
    # Zips the current canonical copy before it is replaced. Keeps the last N backups.
    param([Parameter(Mandatory)][string]$Name)
    $canonical = Join-Path $script:ModPaths.Installed $Name
    if (-not (Test-Path $canonical)) { return }
    $dir = Join-Path $script:ModPaths.ModBackups $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir ('{0}_{1}.zip' -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Compress-Archive -Path (Join-Path $canonical '*') -DestinationPath $zip -Force
    Get-ChildItem -Path $dir -Filter '*.zip' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $script:ModBackupKeep | Remove-Item -Force
    Write-PalLog -Message "[$Name] backup created: $(Split-Path $zip -Leaf)" -Category 'Mods'
}

function Restore-ModBackup {
    # Rolls the canonical copy back to a previous backup and redeploys it.
    param([Parameter(Mandatory)][string]$Name, [string]$BackupFile)
    Assert-PalServerStopped
    $dir = Join-Path $script:ModPaths.ModBackups $Name
    if (-not $BackupFile) {
        $latest = Get-ChildItem -Path $dir -Filter '*.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "No backups found for mod '$Name'" }
        $BackupFile = $latest.FullName
    }
    $entry = Get-RegistryEntry -Name $Name
    if (-not $entry) { throw "Mod '$Name' is not installed" }

    Undeploy-ModFiles -Name $Name
    $canonical = Join-Path $script:ModPaths.Installed $Name
    if (Test-Path $canonical) { Remove-Item -Path $canonical -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $canonical | Out-Null
    Expand-Archive -Path $BackupFile -DestinationPath $canonical -Force

    $entry.hash = Get-ContentHash -Path $canonical
    $entry.version = "$($entry.version)-rollback"
    $entry.updatedAt = (Get-Date -Format 's')
    if ($entry.state -eq 'enabled') {
        $entry.files = @(Deploy-ModFiles -Name $Name -InstallType $entry.installType)
    }
    Set-RegistryEntry -Entry $entry
    Write-PalLog -Message "[$Name] rolled back to $(Split-Path $BackupFile -Leaf)" -Category 'Mods'
}

# ---------------------------------------------------------------------------
# Deploy / undeploy (canonical copy <-> Server files)
# ---------------------------------------------------------------------------

function Deploy-ModFiles {
    # Copies the canonical mod files into the server tree.
    # Returns the list of deployed paths (relative to Server/) for the registry.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$InstallType)
    $canonical = Join-Path $script:ModPaths.Installed $Name
    # GetFullPath normalizes the '.' root used by gameroot overlays
    $targetRoot = [System.IO.Path]::GetFullPath((Join-Path $script:Paths.Server (Get-ModTargetRoot -InstallType $InstallType -Name $Name)))
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

    $deployed = @()
    $files = Get-ChildItem -Path $canonical -Recurse -File
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($canonical.Length).TrimStart('\')
        $dest = Join-Path $targetRoot $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Copy-Item -Path $file.FullName -Destination $dest -Force
        $deployed += $dest.Substring($script:Paths.Server.Length).TrimStart('\')
    }

    # UE4SS Lua mods need an enabled.txt marker to load
    if ($InstallType -eq 'ue4ss-mod') {
        $marker = Join-Path $targetRoot 'enabled.txt'
        if (-not (Test-Path $marker)) {
            Set-Content -Path $marker -Value '' -Encoding ASCII
            $deployed += $marker.Substring($script:Paths.Server.Length).TrimStart('\')
        }
    }
    return $deployed
}

function Undeploy-ModFiles {
    # Removes previously deployed files from the server tree (uses the registry list).
    param([Parameter(Mandatory)][string]$Name)
    $entry = Get-RegistryEntry -Name $Name
    if (-not $entry) { return }
    foreach ($rel in @(Get-ModProp $entry 'files' @())) {
        $full = Join-Path $script:Paths.Server $rel
        if (Test-Path $full) { Remove-Item -Path $full -Force }
    }
    # Prune now-empty mod directories
    foreach ($rel in @(Get-ModProp $entry 'files' @())) {
        $dir = Split-Path (Join-Path $script:Paths.Server $rel) -Parent
        while ($dir -and $dir.StartsWith($script:Paths.Server) -and (Test-Path $dir) -and
               -not (Get-ChildItem -Path $dir -Force | Select-Object -First 1)) {
            Remove-Item -Path $dir -Force
            $dir = Split-Path $dir -Parent
        }
    }
}

# ---------------------------------------------------------------------------
# High-level operations
# ---------------------------------------------------------------------------

function Install-PalMod {
    # Installs or updates a single mod. Idempotent: skips when hash is unchanged.
    # Returns $true when something was installed/updated.
    param([Parameter(Mandatory)]$Mod, [switch]$Force)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Ensure dependencies are installed first
    foreach ($dep in @(Get-ModProp $Mod 'dependsOn' @())) {
        if (-not (Get-RegistryEntry -Name $dep)) {
            Write-PalLog -Message "[$($Mod.name)] installing dependency '$dep' first" -Category 'Mods'
            Install-PalMod -Mod (Get-ModDefinition -Name $dep) -Force:$Force | Out-Null
            if (-not (Get-RegistryEntry -Name $dep)) {
                Write-PalLog -Message "[$($Mod.name)] SKIPPED: dependency '$dep' is not available" -Level 'WARN' -Category 'Mods'
                return $false
            }
        }
    }

    $payload = Get-ModPayload -Mod $Mod
    if (-not $payload) {
        $hint = ''
        if ($Mod.provider -eq 'nexus') {
            $hint = " Download it from $(Get-ModProp $Mod 'page' 'Nexus') and drop the archive into Mods\Nexus\$($Mod.name)\"
        }
        Write-PalLog -Message "[$($Mod.name)] no payload found - skipped.$hint" -Level 'WARN' -Category 'Mods'
        return $false
    }

    $entry = Get-RegistryEntry -Name $Mod.name
    if ($entry -and -not $Force -and $entry.sourceHash -eq $payload.Hash) {
        Write-PalLog -Message "[$($Mod.name)] up to date (v$($entry.version))" -Level 'DEBUG' -Category 'Mods'
        # Still reconcile enable/disable state
        Sync-ModEnabledState -Mod $Mod
        return $false
    }

    Assert-PalServerStopped
    Write-PalLog -Message "[$($Mod.name)] installing v$($payload.Version) from $($Mod.provider)..." -Category 'Mods'
    if ($entry) { Backup-InstalledMod -Name $Mod.name }

    $staging = Expand-ModPayload -Mod $Mod -Payload $payload
    $installType = Get-ModInstallType -Mod $Mod -StagingDir $staging

    # UE4SS Lua mods must have Scripts\main.lua at the mod root. Some archives
    # wrap it in a named subfolder (e.g. AutoLootNearbyItems\Scripts\main.lua):
    # re-root the staging dir so UE4SS can find the entry point.
    if ($installType -eq 'ue4ss-mod' -and -not (Test-Path (Join-Path $staging 'Scripts\main.lua'))) {
        $wrappers = @(Get-ChildItem -Path $staging -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'Scripts\main.lua') })
        if ($wrappers.Count -eq 1) {
            Write-PalLog -Message "[$($Mod.name)] re-rooting payload from subfolder '$($wrappers[0].Name)'" -Level 'DEBUG' -Category 'Mods'
            Get-ChildItem -Path $wrappers[0].FullName -Force | Move-Item -Destination $staging -Force
            Remove-Item -Path $wrappers[0].FullName -Recurse -Force
        }
    }

    $enabled = [bool](Get-ModProp $Mod 'enabled' $true)
    $files = @()
    $canonical = Join-Path $script:ModPaths.Installed $Mod.name
    try {
        # Replace canonical copy, then deploy it
        if ($entry) { Undeploy-ModFiles -Name $Mod.name }
        if (Test-Path $canonical) { Remove-Item -Path $canonical -Recurse -Force }
        Move-Item -Path $staging -Destination $canonical
        if ($enabled) { $files = @(Deploy-ModFiles -Name $Mod.name -InstallType $installType) }
    } catch {
        if ($entry) {
            Write-PalLog -Message "[$($Mod.name)] install failed ($_) - rolling back to the previous version" -Level 'ERROR' -Category 'Mods'
            try { Restore-ModBackup -Name $Mod.name }
            catch { Write-PalLog -Message "[$($Mod.name)] rollback failed: $_" -Level 'ERROR' -Category 'Mods' }
        }
        throw
    }

    $now = Get-Date -Format 's'
    $installedAt = $now
    if ($entry) { $installedAt = Get-ModProp $entry 'installedAt' $now }
    Set-RegistryEntry -Entry ([pscustomobject]@{
        name          = $Mod.name
        provider      = $Mod.provider
        version       = $payload.Version
        installType   = $installType
        sourceHash    = $payload.Hash
        hash          = Get-ContentHash -Path $canonical
        installedAt   = $installedAt
        updatedAt     = $now
        state         = @('disabled', 'enabled')[[int]$enabled]
        files         = $files
        serverBuildId = Get-ServerBuildId
    })
    $sw.Stop()
    Write-PalLog -Message "[$($Mod.name)] installed v$($payload.Version) ($installType, $($files.Count) files, $([int]$sw.Elapsed.TotalSeconds)s)" -Category 'Mods'
    return $true
}

function Sync-ModEnabledState {
    # Reconciles deployed files with the 'enabled' flag in mods.json.
    param([Parameter(Mandatory)]$Mod)
    $entry = Get-RegistryEntry -Name $Mod.name
    if (-not $entry) { return }
    $wantEnabled = [bool](Get-ModProp $Mod 'enabled' $true)
    $isEnabled = ($entry.state -eq 'enabled')
    if ($wantEnabled -ne $isEnabled) { Assert-PalServerStopped }
    if ($wantEnabled -and -not $isEnabled) {
        $entry.files = @(Deploy-ModFiles -Name $Mod.name -InstallType $entry.installType)
        $entry.state = 'enabled'
        Set-RegistryEntry -Entry $entry
        Write-PalLog -Message "[$($Mod.name)] enabled" -Category 'Mods'
    } elseif (-not $wantEnabled -and $isEnabled) {
        Undeploy-ModFiles -Name $Mod.name
        $entry.files = @()
        $entry.state = 'disabled'
        Set-RegistryEntry -Entry $entry
        Write-PalLog -Message "[$($Mod.name)] disabled" -Category 'Mods'
    }
}

function Set-PalModEnabled {
    # Flips the enabled flag in mods.json and reconciles deployment.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Enabled)
    $data = Get-ModsFile
    $mod = $data.mods | Where-Object { $_.name -eq $Name }
    if (-not $mod) { throw "Mod '$Name' not found in Config/mods.json" }
    if ($mod.PSObject.Properties['enabled']) { $mod.enabled = $Enabled }
    else { $mod | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $Enabled }
    Save-ModsFile -Data $data
    Sync-ModEnabledState -Mod $mod
}

function Uninstall-PalMod {
    param([Parameter(Mandatory)][string]$Name, [switch]$Force)
    $entry = Get-RegistryEntry -Name $Name
    if (-not $entry) {
        Write-PalLog -Message "[$Name] not installed - nothing to do" -Category 'Mods'
        return
    }
    $dependents = @(Get-ModDependents -Name $Name)
    if ($dependents -and -not $Force) {
        throw "Cannot remove '$Name': required by $($dependents -join ', '). Remove those first or use -Force."
    }
    Assert-PalServerStopped
    Backup-InstalledMod -Name $Name
    Undeploy-ModFiles -Name $Name
    $canonical = Join-Path $script:ModPaths.Installed $Name
    if (Test-Path $canonical) { Remove-Item -Path $canonical -Recurse -Force }
    Remove-RegistryEntry -Name $Name
    Write-PalLog -Message "[$Name] removed (backup kept in Mods\Cache\Backups\$Name)" -Category 'Mods'
}

function Select-PalMods {
    # All mods from mods.json, or the subset named in $Name.
    param([string[]]$Name)
    $mods = @((Get-ModsFile).mods)
    if (-not $Name) { return $mods }
    # Tolerate a single comma-separated string (how `powershell -File` passes arrays)
    $names = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $selected = @($mods | Where-Object { $names -contains $_.name })
    if (-not $selected) {
        Write-PalLog -Message "No mods in mods.json match: $($names -join ', ')" -Level 'WARN' -Category 'Mods'
    }
    return $selected
}

function Get-PalModPendingChanges {
    # Names of mods whose deployed state differs from mods.json or whose newest payload
    # differs from the installed one. Downloads new payloads into the cache but never
    # touches server files, so it is safe while the server runs.
    param([string[]]$Name)
    New-PalDirectoryTree
    $pending = @()
    foreach ($mod in (Select-PalMods -Name $Name)) {
        $entry = Get-RegistryEntry -Name $mod.name
        $wantEnabled = [bool](Get-ModProp $mod 'enabled' $true)
        if (-not $wantEnabled) {
            if ($entry -and $entry.state -eq 'enabled') { $pending += $mod.name }
            continue
        }
        if ($entry -and $entry.state -ne 'enabled') { $pending += $mod.name; continue }
        try {
            $payload = Get-ModPayload -Mod $mod
        } catch {
            Write-PalLog -Message "[$($mod.name)] update check failed: $_" -Level 'WARN' -Category 'Mods'
            continue
        }
        if ($payload -and (-not $entry -or $entry.sourceHash -ne $payload.Hash)) {
            Write-PalLog -Message "[$($mod.name)] change pending: $(if ($entry) { "v$($entry.version) -> v$($payload.Version)" } else { "install v$($payload.Version)" })" -Category 'Mods'
            $pending += $mod.name
        }
    }
    return $pending
}

function Sync-PalMods {
    # Main entry point: installs/updates/reconciles all mods (or a subset).
    # The server must be stopped. Returns the number of mods that changed.
    param([string[]]$Name, [switch]$Force)
    New-PalDirectoryTree
    $mods = @(Select-PalMods -Name $Name)
    if (-not $mods) { return 0 }
    $ordered = Resolve-ModInstallOrder -Mods $mods
    $changed = 0
    foreach ($mod in $ordered) {
        try {
            if (-not (Get-ModProp $mod 'enabled' $true)) {
                # Disabled mods: keep canonical copy but ensure files are undeployed
                Sync-ModEnabledState -Mod $mod
                continue
            }
            if (Install-PalMod -Mod $mod -Force:$Force) { $changed++ }
        } catch {
            Write-PalLog -Message "[$($mod.name)] ERROR: $_" -Level 'ERROR' -Category 'Mods'
        }
    }
    return $changed
}

function Get-PalModList {
    # Joined view of desired state (mods.json) + installed state (registry).
    $registry = Get-ModRegistry
    foreach ($mod in (Get-ModsFile).mods) {
        $entry = $registry | Where-Object { $_.name -eq $mod.name } | Select-Object -First 1
        $status = 'not installed'
        $version = '-'
        $updated = '-'
        if ($entry) {
            $status = $entry.state
            $version = $entry.version
            $updated = $entry.updatedAt
        }
        [pscustomobject]@{
            Name      = $mod.name
            Provider  = $mod.provider
            Enabled   = [bool](Get-ModProp $mod 'enabled' $true)
            Status    = $status
            Version   = $version
            UpdatedAt = $updated
            DependsOn = (@(Get-ModProp $mod 'dependsOn' @()) -join ', ')
        }
    }
}

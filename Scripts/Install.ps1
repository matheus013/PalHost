<#
.SYNOPSIS
    One-shot installer for a fresh machine: prerequisites (VC++ runtime), config,
    SteamCMD, Palworld dedicated server, settings, firewall, mods and desktop shortcut.
    Idempotent: safe to re-run at any time.
.EXAMPLE
    .\Install.ps1                     # full install (run as Administrator)
    .\Install.ps1 -SkipMods           # server only
    .\Install.ps1 -RegisterAutoStart  # also start the server at user logon
#>
[CmdletBinding()]
param(
    [switch]$SkipMods,
    [switch]$SkipFirewall,
    [switch]$SkipPrereqs,
    [switch]$SkipShortcut,
    [switch]$RegisterAutoStart
)

. "$PSScriptRoot\lib\Common.ps1"

Write-PalLog -Message '=== Palworld server installation started ===' -Category 'Install'
New-PalDirectoryTree
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- 0. Config file (secrets are not in git: start from the example) -------
$configFile = Join-Path $script:Paths.Config 'server.config.json'
if (-not (Test-Path $configFile)) {
    Copy-Item -Path (Join-Path $script:Paths.Config 'server.config.example.json') -Destination $configFile
    Write-PalLog -Message 'Created Config\server.config.json from server.config.example.json' -Category 'Install'
}

# --- 1. Prerequisites: VC++ 2015-2022 x64 runtime --------------------------
# Without it the server process exits instantly with no log at all.
$vcRuntime = Join-Path $env:SystemRoot 'System32\vcruntime140_1.dll'
if (-not $SkipPrereqs -and -not (Test-Path $vcRuntime)) {
    if ($isAdmin) {
        $vcInstaller = Join-Path $env:TEMP 'vc_redist.x64.exe'
        Write-PalLog -Message 'Installing Visual C++ Redistributable x64 (required by the server)...' -Category 'Install'
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vcInstaller -UseBasicParsing
        Start-Process -FilePath $vcInstaller -ArgumentList '/install', '/quiet', '/norestart' -Wait
        Remove-Item $vcInstaller -Force -ErrorAction SilentlyContinue
        if (Test-Path $vcRuntime) { Write-PalLog -Message 'VC++ runtime installed.' -Category 'Install' }
        else { Write-PalLog -Message 'VC++ runtime install did not complete - install it manually (see README).' -Level 'WARN' -Category 'Install' }
    } else {
        Write-PalLog -Message 'VC++ runtime missing and not elevated - re-run as Administrator or install vc_redist.x64.exe manually.' -Level 'WARN' -Category 'Install'
    }
}

# --- 2. SteamCMD -----------------------------------------------------------
$steamCmdExe = Join-Path $script:Paths.SteamCmd 'steamcmd.exe'
if (-not (Test-Path $steamCmdExe)) {
    $cfg = Get-PalConfig
    $zip = Join-Path $env:TEMP 'steamcmd.zip'
    Write-PalLog -Message "Downloading SteamCMD from $($cfg.steam.steamCmdUrl)..." -Category 'Install'
    Invoke-WebRequest -Uri $cfg.steam.steamCmdUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $script:Paths.SteamCmd -Force
    Remove-Item $zip -Force
    # First run only self-updates and relaunches, dropping any +commands.
    # Bootstrap it once so the real install below runs reliably.
    Write-PalLog -Message 'Bootstrapping SteamCMD (first-run self-update)...' -Category 'Install'
    Invoke-SteamCmd -Arguments @('+quit') | Out-Null
    Write-PalLog -Message 'SteamCMD installed.' -Category 'Install'
} else {
    Write-PalLog -Message 'SteamCMD already present - skipping download.' -Category 'Install'
}

# --- 3. Palworld dedicated server (app 2394010) ----------------------------
$cfg = Get-PalConfig
Write-PalLog -Message "Installing/validating Palworld Dedicated Server (app $($cfg.steam.appId))... this can take a while." -Category 'Install'
$result = Update-PalServerBuild
if (-not $result.Success) {
    if (-not (Test-Path (Join-Path $script:Paths.Server 'PalServer.exe'))) {
        Write-PalLog -Message 'SteamCMD did not report success and PalServer.exe is missing. Check Logs\Update\steamcmd-last-run.log' -Level 'ERROR' -Category 'Install'
        exit 1
    }
    Write-PalLog -Message 'SteamCMD success line not found, but PalServer.exe exists - continuing.' -Level 'WARN' -Category 'Install'
}
Write-PalLog -Message "Server installed (build $(Get-ServerBuildId))." -Category 'Install'

# --- 4. Passwords + settings ----------------------------------------------
Initialize-PalPasswords
Build-PalWorldSettings

# First run creates Pal\Saved; make sure the tree exists for the Saves junction
$saveGames = Join-Path $script:Paths.Server 'Pal\Saved\SaveGames'
New-Item -ItemType Directory -Force -Path $saveGames | Out-Null

# --- 5. Saves/ junction (top-level shortcut to the real save folder) -------
$savesLink = $script:Paths.Saves
if (-not (Test-Path $savesLink)) {
    New-Item -ItemType Junction -Path $savesLink -Target $saveGames | Out-Null
    Write-PalLog -Message 'Created Saves\ junction -> Server\Pal\Saved\SaveGames' -Category 'Install'
}

# --- 6. Firewall (game port only; RCON/REST stay local) --------------------
if (-not $SkipFirewall) {
    if ($isAdmin) {
        $ruleName = "Palworld Server (UDP $($cfg.server.port))"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol UDP `
                -LocalPort $cfg.server.port -Action Allow | Out-Null
            Write-PalLog -Message "Firewall rule created: inbound UDP $($cfg.server.port)" -Category 'Install'
        }
    } else {
        Write-PalLog -Message 'Not elevated - firewall rule NOT created. Re-run as Administrator or add it manually (see README).' -Level 'WARN' -Category 'Install'
    }
}

# --- 7. Mods ---------------------------------------------------------------
if (-not $SkipMods) {
    & "$PSScriptRoot\InstallMods.ps1"
}

# --- 8. Desktop shortcut to the control panel ------------------------------
if (-not $SkipShortcut) {
    & "$PSScriptRoot\CreateShortcut.ps1"
}

# --- 9. Optional auto-start scheduled task ---------------------------------
if ($RegisterAutoStart) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\Start.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'PalHost Server AutoStart' -Action $action -Trigger $trigger -Force | Out-Null
    Write-PalLog -Message "Scheduled task 'PalHost Server AutoStart' registered (at logon)." -Category 'Install'
}

$cfg = Get-PalConfig -Reload
$serverPasswordText = if ($cfg.server.serverPassword) { $cfg.server.serverPassword } else { '(none - open to anyone with the address)' }
Write-PalLog -Message '=== Installation finished ===' -Category 'Install'
Write-Host ''
Write-Host '  Palworld server installed successfully!' -ForegroundColor Green
Write-Host "  Server password : $serverPasswordText"
Write-Host '  Admin password  : see Config\server.config.json'
Write-Host "  Game port       : UDP $($cfg.server.port)  (forward this on your router)"
Write-Host ''
Write-Host '  Next steps:'
Write-Host '    1. Mods without auto-download: drop the archive into Mods\Nexus\<ModName>\ and run Scripts\InstallMods.ps1'
Write-Host '    2. Start the server: desktop shortcut "PalHost Server" or Scripts\Start.ps1'

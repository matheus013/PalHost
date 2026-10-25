<#
.SYNOPSIS
    Builds ClientMods-PalHost.zip with every enabled "client" mod (mods.json
    "client": true), so players run the same pak versions as the server.
    Optionally installs them into the local Steam copy of Palworld.
.EXAMPLE
    .\BuildClientMods.ps1                     # rebuild the zip for friends
    .\BuildClientMods.ps1 -InstallToLocalGame # also sync this PC's game (close it first)
#>
[CmdletBinding()]
param(
    [switch]$InstallToLocalGame
)

. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\ModManager.ps1"

function Find-PalworldClient {
    # Locates the Steam client install through the Steam library list.
    $steam = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if (-not $steam) { return $null }
    $vdf = Join-Path ($steam.SteamPath -replace '/', '\') 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path $vdf)) { return $null }
    $libraries = Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
    foreach ($lib in $libraries) {
        $game = Join-Path $lib 'steamapps\common\Palworld'
        if (Test-Path (Join-Path $game 'Palworld.exe')) { return $game }
    }
    return $null
}

$clientMods = @((Get-ModsFile).mods | Where-Object {
    (Get-ModProp $_ 'client' $false) -and (Get-ModProp $_ 'enabled' $true)
})
$clientMods = @($clientMods | Where-Object { Test-Path (Join-Path $script:ModPaths.Installed $_.name) })
if (-not $clientMods) {
    Write-PalLog -Message 'No enabled + installed client mods ("client": true in mods.json) - nothing to build.' -Level 'WARN' -Category 'Mods'
    exit 0
}

# --- Zip for friends --------------------------------------------------------
$staging = Join-Path $script:ModPaths.Staging 'clientmods'
if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $staging '~mods') | Out-Null
$lines = foreach ($mod in $clientMods) {
    Copy-Item -Path (Join-Path $script:ModPaths.Installed $mod.name) -Destination (Join-Path $staging '~mods') -Recurse -Force
    $entry = Get-RegistryEntry -Name $mod.name
    "  - $($mod.name) v$($entry.version)"
}
$build = Get-ServerBuildId
$readme = @"
INSTALACAO (jogadores) - gerado em $(Get-Date -Format 'dd/MM/yyyy') para o build do servidor $build
1. Abra a pasta do Palworld no Steam (botao direito > Gerenciar > Ver arquivos locais)
2. Va em Palworld\Pal\Content\Paks\ e APAGUE a pasta '~mods' antiga, se existir
   (versoes antigas de mods PAK podem travar o jogo apos um patch)
3. Copie a pasta '~mods' deste zip para Palworld\Pal\Content\Paks\
4. Atualize o jogo no Steam e conecte no servidor pelo IP.

Conteudo:
$($lines -join "`r`n")
"@
Set-Content -Path (Join-Path $staging 'LEIA-ME.txt') -Value $readme -Encoding UTF8
$zip = Get-PalPath 'ClientMods-PalHost.zip'
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
Remove-Item -Path $staging -Recurse -Force
Write-PalLog -Message "Built $zip with: $(($clientMods | ForEach-Object { $_.name }) -join ', ')" -Category 'Mods'

# --- This PC's game ---------------------------------------------------------
if ($InstallToLocalGame) {
    $game = Find-PalworldClient
    if (-not $game) { Write-PalLog -Message 'Palworld (Steam) not found on this PC.' -Level 'WARN' -Category 'Mods'; exit 0 }
    if (Get-Process -Name 'Palworld*' -ErrorAction SilentlyContinue) {
        Write-PalLog -Message 'Palworld is running - close the game and run this again (paks are locked).' -Level 'ERROR' -Category 'Mods'
        exit 1
    }
    $target = Join-Path $game 'Pal\Content\Paks\~mods'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($mod in $clientMods) {
        $dest = Join-Path $target $mod.name
        if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
        Copy-Item -Path (Join-Path $script:ModPaths.Installed $mod.name) -Destination $target -Recurse -Force
    }
    Write-PalLog -Message "Client mods installed into $target" -Category 'Mods'
}

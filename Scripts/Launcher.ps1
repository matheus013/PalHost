<#
.SYNOPSIS
    PalHost Server Panel - small GUI to start/stop/backup the server.
    Launch via the desktop shortcut or:  powershell -STA -File Launcher.ps1
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. "$PSScriptRoot\lib\Common.ps1"

$serverExe = Join-Path $script:Paths.Server 'PalServer.exe'

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PalHost Server'
$form.Size = New-Object System.Drawing.Size(420, 320)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 32, 40)
if (Test-Path $serverExe) {
    try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($serverExe) } catch {}
}

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 20)
$statusLabel.Size = New-Object System.Drawing.Size(370, 30)
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::Gray
$statusLabel.Text = 'Verificando...'
$form.Controls.Add($statusLabel)

$infoLabel = New-Object System.Windows.Forms.Label
$infoLabel.Location = New-Object System.Drawing.Point(20, 55)
$infoLabel.Size = New-Object System.Drawing.Size(370, 40)
$infoLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$infoLabel.ForeColor = [System.Drawing.Color]::LightGray
$infoLabel.Text = ''
$form.Controls.Add($infoLabel)

function New-PanelButton {
    param([string]$Text, [int]$X, [int]$Y, [System.Drawing.Color]$Color)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size(175, 50)
    $btn.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.BackColor = $Color
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btn)
    return $btn
}

$btnStart  = New-PanelButton -Text 'INICIAR'        -X 20  -Y 110 -Color ([System.Drawing.Color]::FromArgb(46, 160, 67))
$btnStop   = New-PanelButton -Text 'PARAR'          -X 215 -Y 110 -Color ([System.Drawing.Color]::FromArgb(190, 60, 60))
$btnBackup = New-PanelButton -Text 'BACKUP AGORA'   -X 20  -Y 175 -Color ([System.Drawing.Color]::FromArgb(60, 90, 170))
$btnMods   = New-PanelButton -Text 'ATUALIZAR MODS' -X 215 -Y 175 -Color ([System.Drawing.Color]::FromArgb(120, 80, 170))

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Location = New-Object System.Drawing.Point(20, 245)
$hintLabel.Size = New-Object System.Drawing.Size(370, 30)
$hintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$hintLabel.ForeColor = [System.Drawing.Color]::DimGray
$hintLabel.Text = 'Conectar: 127.0.0.1:8211 (local) - amigos usam seu IP publico'
$form.Controls.Add($hintLabel)

# ---------------------------------------------------------------------------
# Actions (run scripts detached so the GUI never freezes)
# ---------------------------------------------------------------------------

function Invoke-PalScript {
    param([string]$Script, [string[]]$Arguments = @())
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $Script)) + $Arguments
    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Minimized
}

$btnStart.Add_Click({
    if (Test-PalServerRunning) { return }
    $statusLabel.Text = 'Iniciando...'
    $statusLabel.ForeColor = [System.Drawing.Color]::Orange
    Invoke-PalScript -Script 'Start.ps1'
})

$btnStop.Add_Click({
    if (-not (Test-PalServerRunning)) { return }
    $statusLabel.Text = 'Parando...'
    $statusLabel.ForeColor = [System.Drawing.Color]::Orange
    Invoke-PalScript -Script 'Stop.ps1'
})

$btnBackup.Add_Click({ Invoke-PalScript -Script 'Backup.ps1' -Arguments @('-Reason', 'painel') })
$btnMods.Add_Click({ Invoke-PalScript -Script 'UpdateMods.ps1' })

# ---------------------------------------------------------------------------
# Status refresh
# ---------------------------------------------------------------------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    if (Test-PalServerRunning) {
        $statusLabel.Text = 'ONLINE'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(46, 200, 80)
        try {
            $m = Invoke-PalApi -Endpoint 'metrics'
            $upMin = [int]($m.uptime / 60)
            $infoLabel.Text = "Jogadores: $($m.currentplayernum)/$($m.maxplayernum)   FPS: $($m.serverfps)   Uptime: ${upMin} min   Dia: $($m.days)"
        } catch {
            $infoLabel.Text = 'Servidor subindo... (API ainda nao respondeu)'
        }
    } else {
        $statusLabel.Text = 'OFFLINE'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 70, 70)
        $infoLabel.Text = 'Clique em Iniciar para subir o servidor.'
    }

    # Safe mode = the watchdog disabled UE4SS after a crash loop
    $safeMode = $false
    try {
        $ue4ss = (Get-Content (Join-Path $script:Paths.Config 'mods.json') -Raw | ConvertFrom-Json).mods |
            Where-Object { $_.name -eq 'UE4SS' }
        $safeMode = [bool]($ue4ss -and -not $ue4ss.enabled)
    } catch {}
    if ($safeMode) {
        $hintLabel.Text = 'MODO SEGURO: mods Lua desligados apos crashes. Veja Logs\Server.'
        $hintLabel.ForeColor = [System.Drawing.Color]::Orange
    } else {
        $hintLabel.Text = 'Conectar: 127.0.0.1:8211 (local) - amigos usam seu IP publico'
        $hintLabel.ForeColor = [System.Drawing.Color]::DimGray
    }
})
$timer.Start()

# First paint immediately, then show
$form.Add_Shown({ $timer.Stop(); $timer.Interval = 500; $timer.Start() })
$timer.Add_Tick({ if ($timer.Interval -eq 500) { $timer.Interval = 5000 } })

[void]$form.ShowDialog()

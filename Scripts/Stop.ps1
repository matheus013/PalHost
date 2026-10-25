<#
.SYNOPSIS
    Stops the Palworld server gracefully (save + announce + shutdown) and
    tells the Start.ps1 watchdog not to restart it.
.EXAMPLE
    .\Stop.ps1
    .\Stop.ps1 -WaitSeconds 60 -Message 'Maintenance, back soon'
    .\Stop.ps1 -Force          # immediate kill, no announce
#>
[CmdletBinding()]
param(
    [int]$WaitSeconds = 15,
    [string]$Message = 'Server is shutting down',
    [switch]$Force
)

. "$PSScriptRoot\lib\Common.ps1"

# Signal the watchdog first so it doesn't resurrect the server
Set-Content -Path (Get-PalPath '.stop-requested') -Value 'stop' -Encoding ASCII

if (-not (Test-PalServerRunning)) {
    Write-PalLog -Message 'Server is not running.' -Category 'Server'
    exit 0
}

if ($Force) {
    Get-PalServerProcess | Stop-Process -Force
    Write-PalLog -Message 'Server force-stopped.' -Level 'WARN' -Category 'Server'
} else {
    Send-PalAnnounce -Message $Message
    Stop-PalServerGraceful -WaitSeconds $WaitSeconds -Message $Message
}

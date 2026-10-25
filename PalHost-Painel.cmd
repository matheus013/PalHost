@echo off
rem Opens the PalHost control panel. %~dp0 = folder of this file, so it works from any clone location.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Scripts\Launcher.ps1"

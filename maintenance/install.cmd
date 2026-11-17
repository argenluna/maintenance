@echo off
rem Auto Maintenance installer launcher (double-click this file)
rem Keep this file ASCII-only: cmd.exe reads .cmd with the OEM code page.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 pause

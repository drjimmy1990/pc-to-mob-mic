@echo off
title MicStream - Configure Remote Access (Cloudflare + VPS coturn)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Configure-Remote.ps1"
echo.
pause

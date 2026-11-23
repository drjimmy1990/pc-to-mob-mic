@echo off
title MicStream - Status and URLs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Show-Status.ps1"
echo.
pause

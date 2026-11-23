@echo off
title MicStream - Stop Everything
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Stop-MicStream.ps1"
echo.
pause

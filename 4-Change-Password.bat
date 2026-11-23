@echo off
title MicStream - Change Stream Password
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Set-StreamPassword.ps1"
echo.
pause

#Requires -Version 5.1
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$stopped = 0

$trayProcs = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and
    ($_.Name -match '^powershell|^pwsh') -and
    $_.CommandLine -like '*tray.ps1*' -and
    $_.CommandLine -like "*$repoRoot*"
})

foreach ($p in $trayProcs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $stopped++
}

if ($stopped -gt 0) {
    Start-Sleep -Milliseconds 400
}

$childProcs = @(Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -eq 'mediamtx.exe' -and $_.ExecutablePath -like "$repoRoot*") -or
    ($_.Name -eq 'cloudflared.exe' -and ($_.ExecutablePath -like "$repoRoot*" -or $_.CommandLine -like '*--no-autoupdate*run*--token*')) -or
    ($_.Name -eq 'node.exe' -and $_.CommandLine -like "*$repoRoot\dashboard\server.js*") -or
    ($_.Name -eq 'ffmpeg.exe' -and ($_.CommandLine -like '*127.0.0.1:8554*' -or $_.CommandLine -like "*$repoRoot\recordings*"))
})

foreach ($p in $childProcs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $stopped++
}

if ($stopped -gt 0) {
    Write-Host "[OK] Stopped $stopped MicStream process(es). Microphone, recorder, tunnel, and server are completely OFF." -ForegroundColor Green
}
else {
    Write-Host '[OK] Nothing from MicStream was running. Everything is already OFF.' -ForegroundColor Cyan
}

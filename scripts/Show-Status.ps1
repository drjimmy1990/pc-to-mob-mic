#Requires -Version 5.1
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

$tray = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and
    ($_.Name -match '^powershell|^pwsh') -and
    $_.CommandLine -like '*tray.ps1*' -and
    $_.CommandLine -like "*$repoRoot*"
})
$mtx = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'mediamtx.exe' -and $_.ExecutablePath -like "$repoRoot*"
})
$ffStream = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'ffmpeg.exe' -and $_.CommandLine -like '*127.0.0.1:8554*'
})
$ffRec = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'ffmpeg.exe' -and $_.CommandLine -like "*$repoRoot\recordings*"
})
$cf = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'cloudflared.exe' -and ($_.ExecutablePath -like "$repoRoot*" -or $_.CommandLine -like '*--no-autoupdate*run*--token*')
})
$dash = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'node.exe' -and $_.CommandLine -like "*$repoRoot\dashboard\server.js*"
})

Write-Host '=== Live Process Status ===' -ForegroundColor White
$trayText = if ($tray.Count -gt 0) { 'RUNNING (PID ' + (($tray.ProcessId) -join ',') + ')' } else { 'STOPPED' }
$dashText = if ($dash.Count -gt 0) { 'RUNNING (PID ' + (($dash.ProcessId) -join ',') + ', http://127.0.0.1:8890)' } else { 'STOPPED' }
$mtxText  = if ($mtx.Count -gt 0) { 'LIVE (PID ' + (($mtx.ProcessId) -join ',') + ')' } else { 'STOPPED' }
$ffText   = if ($ffStream.Count -gt 0) { 'LIVE (PID ' + (($ffStream.ProcessId) -join ',') + ')' } else { 'STOPPED' }
$recText  = if ($ffRec.Count -gt 0) { 'RECORDING (PID ' + (($ffRec.ProcessId) -join ',') + ')' } else { 'IDLE' }
$cfText   = if ($cf.Count -gt 0) { 'CONNECTED (PID ' + (($cf.ProcessId) -join ',') + ')' } else { 'OFF' }

Write-Host "  Tray Daemon : $trayText" -ForegroundColor $(if ($tray.Count -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  Dashboard   : $dashText" -ForegroundColor $(if ($dash.Count -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  MediaMTX    : $mtxText" -ForegroundColor $(if ($mtx.Count -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  FFmpeg Mic  : $ffText" -ForegroundColor $(if ($ffStream.Count -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  Recorder    : $recText" -ForegroundColor $(if ($ffRec.Count -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Cloudflared : $cfText" -ForegroundColor $(if ($cf.Count -gt 0) { 'Cyan' } else { 'Gray' })
Write-Host ''

& (Join-Path $repoRoot 'scripts\Check-Environment.ps1')

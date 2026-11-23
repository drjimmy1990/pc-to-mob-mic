#Requires -Version 5.1
# Read-only host & multi-transport diagnostic checker for d:\DEV\mic

Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\MicStream.Core.psm1') -Force

$configPath = Join-Path $repoRoot 'config.json'
$templatePath = Join-Path $repoRoot 'config.example.json'
$config = Get-MicStreamConfig -ConfigPath $configPath -FallbackTemplatePath $templatePath

$passCount = 0
$warnCount = 0
$failCount = 0

function Write-CheckResult {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,
        [string]$Label,
        [string]$Detail
    )
    $color = switch ($Status) {
        'PASS' { $script:passCount++; 'Green' }
        'WARN' { $script:warnCount++; 'Yellow' }
        'FAIL' { $script:failCount++; 'Red' }
        'INFO' { 'Cyan' }
    }
    Write-Host ("[{0,-4}] {1}: {2}" -f $Status, $Label, $Detail) -ForegroundColor $color
}

Write-Host '=== MicStream Environment Check (Read-Only) ===' -ForegroundColor White
Write-Host "Workspace: $repoRoot`n"

# 1. FFmpeg & libopus
$ffmpegExe = Resolve-ExecutablePath -ConfiguredPath ([string]$config.paths.ffmpegPath) -BaseDir $repoRoot
if ($ffmpegExe) {
    $verLine = (& $ffmpegExe -version 2>&1 | Select-Object -First 1)
    Write-CheckResult -Status 'PASS' -Label 'FFmpeg' -Detail "$verLine ($ffmpegExe)"
    $encOut = (& $ffmpegExe -hide_banner -encoders 2>&1 | Select-String -Pattern '\blibopus\b')
    if ($encOut) {
        Write-CheckResult -Status 'PASS' -Label 'Opus Encoder' -Detail 'libopus available'
    }
    else {
        Write-CheckResult -Status 'FAIL' -Label 'Opus Encoder' -Detail 'libopus not compiled into FFmpeg'
    }
}
else {
    Write-CheckResult -Status 'FAIL' -Label 'FFmpeg' -Detail 'ffmpeg not found in PATH or config.json'
}

# 2. DirectShow Microphone
$configuredMic = [string]$config.audio.microphoneName
if ($ffmpegExe) {
    $devices = @(Get-DShowAudioDevices -FfmpegPath $ffmpegExe -BaseDir $repoRoot)
    if ($devices.Count -eq 0) {
        Write-CheckResult -Status 'FAIL' -Label 'Microphone' -Detail 'No DirectShow audio input devices detected'
    }
    elseif (($devices | Where-Object { $_.Name -eq $configuredMic })) {
        Write-CheckResult -Status 'PASS' -Label 'Microphone' -Detail "Matched configured device: `"$configuredMic`""
    }
    else {
        $avail = ($devices | ForEach-Object { "`"$($_.Name)`"" }) -join ', '
        Write-CheckResult -Status 'WARN' -Label 'Microphone' -Detail "Configured `"$configuredMic`" not found. Available: $avail"
    }
}

# 3. Windows Microphone Privacy
$micConsent = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone' -Name Value -ErrorAction SilentlyContinue
$micNonPkg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged' -Name Value -ErrorAction SilentlyContinue
if ($micConsent -and $micNonPkg -and $micConsent.Value -eq 'Allow' -and $micNonPkg.Value -eq 'Allow') {
    Write-CheckResult -Status 'PASS' -Label 'Mic Privacy' -Detail 'Windows desktop app microphone access is Allow'
}
else {
    Write-CheckResult -Status 'WARN' -Label 'Mic Privacy' -Detail 'Verify Settings -> Privacy & security -> Microphone -> Let desktop apps access your microphone'
}

# 4. MediaMTX binary
$mtxExe = Resolve-ExecutablePath -ConfiguredPath ([string]$config.paths.mediamtxExe) -BaseDir $repoRoot
if ($mtxExe) {
    $mtxVer = (& $mtxExe --version 2>&1 | Select-Object -First 1)
    Write-CheckResult -Status 'PASS' -Label 'MediaMTX' -Detail "$mtxVer ($mtxExe)"
}
else {
    Write-CheckResult -Status 'FAIL' -Label 'MediaMTX' -Detail 'mediamtx.exe missing. Run .\scripts\Install-MediaMTX.ps1'
}

# 5. MediaMTX config & password readiness
$mtxCfg = [string]$config.paths.mediamtxConfig
if (-not [System.IO.Path]::IsPathRooted($mtxCfg)) { $mtxCfg = Join-Path $repoRoot $mtxCfg }
$ready = Test-MediaMtxConfigReady -YamlPath $mtxCfg
if ($ready.Ready) {
    Write-CheckResult -Status 'PASS' -Label 'mediamtx.yml' -Detail 'Config present and stream password initialized'
}
else {
    Write-CheckResult -Status 'WARN' -Label 'mediamtx.yml' -Detail $ready.Reason
}

# 6. Ports check
$rtspPort = [int]$config.stream.rtspPort
$webrtcPort = [int]$config.stream.webrtcPort
$udpPort = [int]$config.stream.webrtcUdpPort

$tcpBusy = Get-NetTCPConnection -LocalPort $rtspPort, $webrtcPort -State Listen -ErrorAction SilentlyContinue
$udpBusy = Get-NetUDPEndpoint -LocalPort $udpPort -ErrorAction SilentlyContinue
if (-not $tcpBusy -and -not $udpBusy) {
    Write-CheckResult -Status 'PASS' -Label 'Ports' -Detail "TCP $rtspPort, TCP $webrtcPort, and UDP $udpPort are free"
}
else {
    $busyList = @()
    foreach ($c in $tcpBusy) { $busyList += "TCP:$($c.LocalPort) (PID $($c.OwningProcess))" }
    foreach ($u in $udpBusy) { $busyList += "UDP:$($u.LocalPort) (PID $($u.OwningProcess))" }
    Write-CheckResult -Status 'WARN' -Label 'Ports' -Detail ("Currently bound: " + ($busyList -join ', '))
}

# 7. Firewall rules (read-only)
$fwRules = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'MediaMTX|MicStream' }
$hasTcpRule = $false
$hasUdpRule = $false
foreach ($r in $fwRules) {
    $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    if ($pf) {
        if ($pf.Protocol -eq 'TCP' -and ($pf.LocalPort -contains [string]$webrtcPort)) { $hasTcpRule = $true }
        if ($pf.Protocol -eq 'UDP' -and ($pf.LocalPort -contains [string]$udpPort)) { $hasUdpRule = $true }
    }
}
if ($hasTcpRule -and $hasUdpRule) {
    Write-CheckResult -Status 'PASS' -Label 'Firewall' -Detail "Inbound Allow rules found for TCP $webrtcPort and UDP $udpPort"
}
else {
    Write-CheckResult -Status 'WARN' -Label 'Firewall' -Detail "Inbound Allow rules not detected for TCP $webrtcPort / UDP $udpPort (manual admin setup in ARCHITECTURE.md)"
}

# 8. Startup shortcut & Power Settings (read-only)
$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = Get-ChildItem -Path $startupDir -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'MicTray|MicStream' }
if ($startupShortcut) {
    Write-CheckResult -Status 'PASS' -Label 'Auto-Start' -Detail "Found in shell:startup: $($startupShortcut.Name -join ', ')"
}
else {
    Write-CheckResult -Status 'INFO' -Label 'Auto-Start' -Detail 'Not configured in shell:startup (optional manual step in ARCHITECTURE.md)'
}

$sleepQuery = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1) -join "`n"
if ($sleepQuery -match 'Current AC Power Setting Index:\s*0x00000000') {
    Write-CheckResult -Status 'PASS' -Label 'AC Sleep' -Detail 'Standby timeout on AC power is 0 (Never)'
}
else {
    Write-CheckResult -Status 'WARN' -Label 'AC Sleep' -Detail 'AC sleep timeout is non-zero; see ARCHITECTURE.md for powercfg command'
}

# 9. Multi-Transport Network Summary
Write-Host "`n--- Multi-Transport Network Summary ---" -ForegroundColor White
$adapters = @(Get-HostIpv4Adapters)
$preferred = @(Get-PreferredNetworkInterfaces -Adapters $adapters -ExcludePatterns @($config.network.excludeInterfacePatterns))
$ifaceDetail = if ($preferred.Count -gt 0) { $preferred -join ', ' } else { '(none matched; MediaMTX will scan all)' }
Write-CheckResult -Status 'INFO' -Label 'ICE Interfaces' -Detail $ifaceDetail

$ts = Get-TailscaleInfo
if ($ts.Installed -and $ts.Connected) {
    Write-CheckResult -Status 'PASS' -Label 'Tailscale' -Detail "Connected (IP=$($ts.IPv4), DNS=$($ts.DnsName))"
}
elseif ($ts.Installed) {
    Write-CheckResult -Status 'WARN' -Label 'Tailscale' -Detail 'Installed but not connected'
}
else {
    Write-CheckResult -Status 'INFO' -Label 'Tailscale' -Detail 'Not installed (optional remote WireGuard mesh)'
}

$protonActive = $adapters | Where-Object { $_.InterfaceAlias -like '*ProtonVPN*' -and $_.Status -eq 'Up' }
if ($protonActive) {
    Write-CheckResult -Status 'INFO' -Label 'ProtonVPN' -Detail 'Active WireGuard tunnel detected; excluded from ICE candidates. If using Tailscale simultaneously, allow 100.64.0.0/10 in ProtonVPN split tunneling.'
}

$cfExe = Resolve-ExecutablePath -ConfiguredPath ([string]$config.network.cloudflared.exePath) -BaseDir $repoRoot
if (-not $cfExe) { $cfExe = Resolve-ExecutablePath -ConfiguredPath 'cloudflared' -BaseDir $repoRoot }
$tokFile = [string]$config.network.cloudflared.tokenFile
if (-not [System.IO.Path]::IsPathRooted($tokFile)) { $tokFile = Join-Path $repoRoot $tokFile }
$hasCfToken = -not [string]::IsNullOrWhiteSpace((Get-CloudflaredToken -TokenPath $tokFile))
$cfEnabled = [bool]$config.network.cloudflared.enabled
$pubUrl = [string]$config.network.publicUrl
if ($pubUrl) {
    $cfDetail = "Configured: $pubUrl (cloudflared=$(if ($cfExe) { 'installed' } else { 'missing' }), token=$(if ($hasCfToken) { 'saved' } else { 'missing' }), startWithStream=$cfEnabled)"
    Write-CheckResult -Status 'PASS' -Label 'Tunnel URL' -Detail $cfDetail
}
else {
    $cfDetail = "Not configured (optional; run 5-Configure-Remote.bat; cloudflared=$(if ($cfExe) { 'installed' } else { 'not installed' }))"
    Write-CheckResult -Status 'INFO' -Label 'Tunnel URL' -Detail $cfDetail
}

if (Test-Path -LiteralPath $mtxCfg) {
    $mtxRaw = Get-Content -LiteralPath $mtxCfg -Raw -Encoding UTF8
    if ($mtxRaw -match '(?m)^\s*-\s+url\s*:\s*[''"]?(turns?:[^''"\r\n]+)') {
        Write-CheckResult -Status 'PASS' -Label 'TURN Relay' -Detail "Configured: $($Matches[1])"
    }
    else {
        Write-CheckResult -Status 'INFO' -Label 'TURN Relay' -Detail 'Not configured in mediamtx.yml (optional; needed for Cloudflare Tunnel over 4G/5G)'
    }
}

Write-CheckResult -Status 'INFO' -Label 'Hotkeys' -Detail "Stream=$($config.hotkey.label), Record=$($config.recording.hotkey.label)"

Write-Host "`n--- Reachable Stream URLs ---" -ForegroundColor White
$endpoints = Get-StreamEndpoints -Config $config -Adapters $adapters
foreach ($ep in $endpoints) {
    Write-Host ("  [{0,-15}] {1}" -f $ep.Transport, $ep.Url)
}

Write-Host "`nSummary: $passCount passed, $warnCount warnings, $failCount failed." -ForegroundColor White
if ($failCount -gt 0) { exit 1 } else { exit 0 }

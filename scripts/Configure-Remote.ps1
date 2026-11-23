#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PublicUrl = '',
    [string]$TunnelToken = '',
    [string]$TurnUrl = '',
    [string]$TurnSecret = '',
    [switch]$EnableTunnelByDefault,
    [switch]$SkipCloudflaredInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\MicStream.Core.psm1') -Force

$configPath = Join-Path $repoRoot 'config.json'
$templatePath = Join-Path $repoRoot 'config.example.json'
$mtxYaml = Join-Path $repoRoot 'mediamtx.yml'
$config = Get-MicStreamConfig -ConfigPath $configPath -FallbackTemplatePath $templatePath

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Write-Host '=== MicStream Remote Access Wizard (Cloudflare Tunnel + VPS coturn) ===' -ForegroundColor White
Write-Host 'Press Enter on any prompt to keep the existing value.' -ForegroundColor DarkGray
Write-Host ''

# 1. Public Tunnel URL
if ([string]::IsNullOrWhiteSpace($PublicUrl)) {
    $currentUrl = [string]$config.network.publicUrl
    $promptLabel = if ($currentUrl) { "Public Tunnel URL [$currentUrl]" } else { 'Public Tunnel URL (e.g. https://mic.yourdomain.com)' }
    $inputUrl = Read-Host -Prompt $promptLabel
    if (-not [string]::IsNullOrWhiteSpace($inputUrl)) {
        $PublicUrl = $inputUrl.Trim()
    }
    else {
        $PublicUrl = $currentUrl
    }
}
$config.network.publicUrl = $PublicUrl

# 2. Cloudflare Tunnel Token
$tokenFile = [string]$config.network.cloudflared.tokenFile
if (-not [System.IO.Path]::IsPathRooted($tokenFile)) {
    $tokenFile = Join-Path $repoRoot $tokenFile
}
$hasToken = -not [string]::IsNullOrWhiteSpace((Get-CloudflaredToken -TokenPath $tokenFile))

if ([string]::IsNullOrWhiteSpace($TunnelToken)) {
    $tokPrompt = if ($hasToken) { 'Cloudflare Tunnel Token [already saved; press Enter to keep]' } else { 'Paste Cloudflare Tunnel Token (input hidden; press Enter to skip)' }
    $secTok = Read-Host -Prompt $tokPrompt -AsSecureString
    $plainTok = ConvertFrom-SecureStringPlain -Secure $secTok
    if (-not [string]::IsNullOrWhiteSpace($plainTok)) {
        $TunnelToken = $plainTok.Trim()
    }
}

if (-not [string]::IsNullOrWhiteSpace($TunnelToken)) {
    # Strip accidental "cloudflared service install " or "--token " prefix if user pasted full command
    if ($TunnelToken -match '--token\s+(\S+)') {
        $TunnelToken = $Matches[1]
    }
    elseif ($TunnelToken -match 'install\s+(\S+)$') {
        $TunnelToken = $Matches[1]
    }
    [System.IO.File]::WriteAllText($tokenFile, $TunnelToken.Trim(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[OK] Saved Cloudflare Tunnel token to $tokenFile (gitignored)." -ForegroundColor Green
}

# 3. Default Cloudflare Tunnel behavior when stream starts (optional toggle)
if ($EnableTunnelByDefault) {
    $config.network.cloudflared.enabled = $true
}
elseif ([string]::IsNullOrWhiteSpace($TurnUrl) -and [string]::IsNullOrWhiteSpace($TurnSecret)) {
    $curEn = if ([bool]$config.network.cloudflared.enabled) { 'Y' } else { 'N' }
    $ans = Read-Host -Prompt "Start Cloudflare Tunnel automatically when stream starts? (Y/N, currently $curEn - always toggleable in tray)"
    if ($ans -match '^[Yy]') { $config.network.cloudflared.enabled = $true }
    elseif ($ans -match '^[Nn]') { $config.network.cloudflared.enabled = $false }
}

Save-MicStreamConfig -Config $config -ConfigPath $configPath
Write-Host "[OK] Updated $configPath." -ForegroundColor Green

# 4. VPS coturn TURN Server (AUTH_SECRET)
if ([string]::IsNullOrWhiteSpace($TurnUrl) -and [string]::IsNullOrWhiteSpace($TurnSecret)) {
    Write-Host ''
    Write-Host '--- VPS coturn TURN Server (for 4G/5G WebRTC audio) ---' -ForegroundColor Cyan
    $inputTurnUrl = Read-Host -Prompt 'TURN URL (e.g. turn:YOUR_VPS_IP:3478, or press Enter to skip)'
    if (-not [string]::IsNullOrWhiteSpace($inputTurnUrl)) {
        $TurnUrl = $inputTurnUrl.Trim()
        $secTurn = Read-Host -Prompt 'coturn static-auth-secret (from your VPS turnserver.conf, hidden)' -AsSecureString
        $TurnSecret = (ConvertFrom-SecureStringPlain -Secure $secTurn).Trim()
    }
}

if (-not [string]::IsNullOrWhiteSpace($TurnUrl)) {
    if ([string]::IsNullOrWhiteSpace($TurnSecret)) {
        throw 'TurnSecret is required when TurnUrl is provided.'
    }
    Update-MediaMtxTurnConfig -YamlPath $mtxYaml -TurnUrl $TurnUrl -Username 'AUTH_SECRET' -Password $TurnSecret -ClientOnly $false
    Write-Host "[OK] Updated webrtcICEServers2 in $mtxYaml (AUTH_SECRET -> $TurnUrl)." -ForegroundColor Green
}

# 5. Offer to install cloudflared.exe locally into d:\DEV\mic
if (-not $SkipCloudflaredInstall) {
    $cfExe = Resolve-ExecutablePath -ConfiguredPath ([string]$config.network.cloudflared.exePath) -BaseDir $repoRoot
    if (-not $cfExe) {
        $installAns = Read-Host -Prompt 'cloudflared.exe is not installed yet. Download official cloudflared.exe into d:\DEV\mic now? (Y/n)'
        if ([string]::IsNullOrWhiteSpace($installAns) -or $installAns -match '^[Yy]') {
            & (Join-Path $repoRoot 'scripts\Install-Cloudflared.ps1')
        }
    }
    else {
        Write-Host "[OK] cloudflared found at $cfExe" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Done! Restart the stream (or click Reload Config in the tray) to apply changes.' -ForegroundColor Cyan

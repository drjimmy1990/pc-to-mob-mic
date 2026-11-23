#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$User = 'admin',
    [string]$Password = '',
    [string]$YamlPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\MicStream.Core.psm1') -Force

if ([string]::IsNullOrWhiteSpace($YamlPath)) {
    $YamlPath = Join-Path $repoRoot 'mediamtx.yml'
}

$exampleYaml = Join-Path $repoRoot 'mediamtx.example.yml'
if (-not (Test-Path -LiteralPath $YamlPath)) {
    if (Test-Path -LiteralPath $exampleYaml) {
        Copy-Item -LiteralPath $exampleYaml -Destination $YamlPath
        Write-Host "[SEED] Created $YamlPath from mediamtx.example.yml" -ForegroundColor Cyan
    }
    else {
        throw "mediamtx.yml not found at $YamlPath and mediamtx.example.yml is missing."
    }
}

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

$plain = $Password
if ([string]::IsNullOrEmpty($plain)) {
    Write-Host "Configure MediaMTX SHA-256 password for user '$User'" -ForegroundColor Cyan
    $s1 = Read-Host -Prompt 'Enter new stream password (12+ chars recommended)' -AsSecureString
    $s2 = Read-Host -Prompt 'Confirm new stream password' -AsSecureString

    $p1 = ConvertFrom-SecureStringPlain -Secure $s1
    $p2 = ConvertFrom-SecureStringPlain -Secure $s2
    if ($p1 -cne $p2) {
        throw 'Passwords do not match. No changes were written.'
    }
    $plain = $p1
}

if ([string]::IsNullOrWhiteSpace($plain)) {
    throw 'Password cannot be empty or whitespace.'
}

if ($plain.Length -lt 12) {
    Write-Warning 'Password is shorter than 12 characters. Consider using a stronger passphrase for remote access.'
}

$hash = ConvertTo-MediaMtxSha256Hash -PlainText $plain
Update-MediaMtxUserPassword -YamlPath $YamlPath -User $User -PasswordHash $hash

Write-Host "[OK] Updated SHA-256 password hash for user '$User' in $YamlPath." -ForegroundColor Green
Write-Host 'Note: Restart the stream in the Control Panel or System Tray (Ctrl+Shift+F9 twice) if currently LIVE.' -ForegroundColor Yellow

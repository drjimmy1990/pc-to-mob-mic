#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetExe = Join-Path $repoRoot 'cloudflared.exe'

if ((Test-Path -LiteralPath $targetExe) -and -not $Force) {
    $verOut = (& $targetExe --version 2>&1 | Select-Object -First 1)
    Write-Host "[SKIP] cloudflared.exe already exists ($verOut). Use -Force to upgrade." -ForegroundColor Yellow
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$apiUrl = if ($Version -eq 'latest') {
    'https://api.github.com/repos/cloudflare/cloudflared/releases/latest'
}
else {
    "https://api.github.com/repos/cloudflare/cloudflared/releases/tags/$Version"
}

Write-Host "[FETCH] Querying Cloudflare cloudflared release ($apiUrl)..." -ForegroundColor Cyan
$headers = @{ 'User-Agent' = 'MicStream-Installer/1.0' }
$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get

$asset = $release.assets | Where-Object { $_.name -eq 'cloudflared-windows-amd64.exe' } | Select-Object -First 1
if (-not $asset) {
    throw "Could not find cloudflared-windows-amd64.exe in release $($release.tag_name)."
}

$tmpExe = "$targetExe.download"
try {
    Write-Host "[DOWNLOAD] $($asset.name) ($($release.tag_name))..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpExe -Headers $headers -UseBasicParsing

    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $tmpExe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 mismatch! Expected $expected, got $actual."
        }
        Write-Host "[VERIFY] SHA-256 digest verified ($actual)." -ForegroundColor Green
    }

    Move-Item -LiteralPath $tmpExe -Destination $targetExe -Force
    $installedVer = (& $targetExe --version 2>&1 | Select-Object -First 1)
    Write-Host "[OK] Installed cloudflared.exe ($installedVer) to $targetExe" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tmpExe) {
        Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
    }
}

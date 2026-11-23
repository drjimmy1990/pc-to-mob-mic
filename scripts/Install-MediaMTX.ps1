#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetExe = Join-Path $repoRoot 'mediamtx.exe'
$configPath = Join-Path $repoRoot 'config.json'
$configExample = Join-Path $repoRoot 'config.example.json'
$mtxYaml = Join-Path $repoRoot 'mediamtx.yml'
$mtxYamlExample = Join-Path $repoRoot 'mediamtx.example.yml'
$logsDir = Join-Path $repoRoot 'logs'

# Seed local config files from templates without overwriting existing user configs
if (-not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $configExample)) {
    Copy-Item -LiteralPath $configExample -Destination $configPath
    Write-Host "[SEED] Created config.json from config.example.json" -ForegroundColor Cyan
}

if (-not (Test-Path -LiteralPath $mtxYaml) -and (Test-Path -LiteralPath $mtxYamlExample)) {
    Copy-Item -LiteralPath $mtxYamlExample -Destination $mtxYaml
    Write-Host "[SEED] Created mediamtx.yml from mediamtx.example.yml" -ForegroundColor Cyan
}

if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

if ((Test-Path -LiteralPath $targetExe) -and -not $Force) {
    $verOut = & $targetExe --version 2>&1
    Write-Host "[SKIP] mediamtx.exe already exists ($verOut). Use -Force to reinstall/upgrade." -ForegroundColor Yellow
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$apiUrl = if ($Version -eq 'latest') {
    'https://api.github.com/repos/bluenviron/mediamtx/releases/latest'
}
else {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    "https://api.github.com/repos/bluenviron/mediamtx/releases/tags/$tag"
}

Write-Host "[FETCH] Querying GitHub release metadata ($apiUrl)..." -ForegroundColor Cyan
$headers = @{ 'User-Agent' = 'MicStream-Installer/1.0' }
$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get

$zipAsset = $release.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
if (-not $zipAsset) {
    throw "Could not locate a windows_amd64.zip asset in release $($release.tag_name)."
}

$checksumAsset = $release.assets | Where-Object { $_.name -match 'checksums|sha256' } | Select-Object -First 1

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mediamtx_install_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    $zipPath = Join-Path $tmpDir $zipAsset.name
    Write-Host "[DOWNLOAD] $($zipAsset.name) ($($release.tag_name))..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing

    if ($checksumAsset) {
        $csPath = Join-Path $tmpDir $checksumAsset.name
        Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $csPath -Headers $headers -UseBasicParsing
        $csLines = Get-Content -LiteralPath $csPath
        $matchLine = $csLines | Where-Object { $_ -match ([regex]::Escape($zipAsset.name)) } | Select-Object -First 1
        if ($matchLine -and ($matchLine -match '^([0-9a-fA-F]{64})\s+')) {
            $expectedHash = $Matches[1].ToLowerInvariant()
            $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                throw "SHA-256 verification failed! Expected $expectedHash, got $actualHash."
            }
            Write-Host "[VERIFY] SHA-256 checksum verified ($actualHash)." -ForegroundColor Green
        }
    }
    elseif ($zipAsset.PSObject.Properties['digest'] -and $zipAsset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expectedHash = $Matches[1].ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 digest verification failed! Expected $expectedHash, got $actualHash."
        }
        Write-Host "[VERIFY] GitHub release SHA-256 digest verified ($actualHash)." -ForegroundColor Green
    }

    $extractDir = Join-Path $tmpDir 'extracted'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $extractedExe = Get-ChildItem -Path $extractDir -Filter 'mediamtx.exe' -Recurse | Select-Object -First 1
    if (-not $extractedExe) {
        throw "mediamtx.exe was not found inside $($zipAsset.name)."
    }

    Copy-Item -LiteralPath $extractedExe.FullName -Destination $targetExe -Force
    $installedVer = & $targetExe --version 2>&1
    Write-Host "[OK] Installed mediamtx.exe ($installedVer) to $targetExe" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Set your stream password:  .\scripts\Set-StreamPassword.ps1"
    Write-Host "  2. Run environment check:     .\scripts\Check-Environment.ps1"
    Write-Host "  3. Launch headless daemon:    wscript.exe .\Start-MicTray.vbs"
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('bd', 'sh', 'cb')]
    [string]$Model = 'bd',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modelsDir = Join-Path $repoRoot 'models'
if (-not (Test-Path -LiteralPath $modelsDir)) {
    New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
}

$modelMap = @{
    'bd' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/beguiling-drafter-2018-08-30/bd.rnnn'
    'sh' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn'
    'cb' = 'https://raw.githubusercontent.com/GregorR/rnnoise-models/master/conjoined-burgers-2018-08-28/cb.rnnn'
}

$targetFile = Join-Path $modelsDir "${Model}.rnnn"
if ((Test-Path -LiteralPath $targetFile) -and -not $Force) {
    $kb = [Math]::Round(((Get-Item -LiteralPath $targetFile).Length / 1KB), 1)
    Write-Host "[SKIP] RNNoise model already exists at $targetFile ($kb KB). Use -Force to redownload." -ForegroundColor Yellow
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = $modelMap[$Model]
$tmpFile = "$targetFile.download"

try {
    Write-Host "[DOWNLOAD] Fetching RNNoise model '$Model' from GregorR/rnnoise-models..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $tmpFile -Headers @{ 'User-Agent' = 'MicStream-Installer/1.0' } -UseBasicParsing

    $head = Get-Content -LiteralPath $tmpFile -TotalCount 1
    if ($head -notmatch '^rnnoise-nu model file') {
        throw "Downloaded file does not appear to be a valid RNNoise model header (got: $head)"
    }

    Move-Item -LiteralPath $tmpFile -Destination $targetFile -Force
    $kb = [Math]::Round(((Get-Item -LiteralPath $targetFile).Length / 1KB), 1)
    Write-Host "[OK] Installed RNNoise model to $targetFile ($kb KB)." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tmpFile) {
        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

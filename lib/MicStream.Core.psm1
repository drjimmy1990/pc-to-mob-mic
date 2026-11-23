#Requires -Version 5.1
Set-StrictMode -Version Latest

function Format-NativeArgument {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    # Win32 CommandLineToArgvW quoting rules:
    # Double backslashes before double quotes, escape double quotes,
    # and double trailing backslashes before closing quote.
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Join-NativeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $formatted = foreach ($arg in $Arguments) {
        Format-NativeArgument -Value $arg
    }
    return ($formatted -join ' ')
}

function ConvertTo-MediaMtxSha256Hash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PlainText
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $hashBytes = $sha.ComputeHash($bytes)
        $b64 = [Convert]::ToBase64String($hashBytes)
        return "sha256:$b64"
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertFrom-DShowDeviceOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Lines
    )

    $devices = New-Object System.Collections.Generic.List[object]
    $inLegacyAudioSection = $false
    $lastAudioDevice = $null
    $pendingAltName = $false

    foreach ($rawLine in $Lines) {
        if ($null -eq $rawLine) { continue }
        $line = $rawLine.TrimEnd("`r", "`n")

        # Handle wrapped Alternative name value on the line following "Alternative name"
        if ($pendingAltName) {
            if ($line -match '"([^"]+)"') {
                if ($null -ne $lastAudioDevice) {
                    $lastAudioDevice.AlternativeName = $Matches[1]
                }
                $pendingAltName = $false
                continue
            }
            $pendingAltName = $false
        }

        # Legacy FFmpeg section markers
        if ($line -match 'DirectShow video devices') {
            $inLegacyAudioSection = $false
            $lastAudioDevice = $null
            continue
        }
        if ($line -match 'DirectShow audio devices') {
            $inLegacyAudioSection = $true
            $lastAudioDevice = $null
            continue
        }

        # Alternative name for the most recent device
        if ($line -match 'Alternative name\s+"([^"]+)"') {
            if ($null -ne $lastAudioDevice) {
                $lastAudioDevice.AlternativeName = $Matches[1]
            }
            continue
        }
        if ($line -match 'Alternative name\s*$') {
            $pendingAltName = $true
            continue
        }

        # Modern FFmpeg (5.x - 9.x): [in#0 @ ...] "Device Name" (audio) or (video)
        if ($line -match '"([^"]+)"\s+\((audio|video|none)\)\s*$') {
            $devName = $Matches[1]
            $devType = $Matches[2]
            if ($devType -eq 'audio') {
                $entry = [PSCustomObject]@{
                    Name            = $devName
                    AlternativeName = ''
                }
                $devices.Add($entry)
                $lastAudioDevice = $entry
            }
            else {
                $lastAudioDevice = $null
            }
            continue
        }

        # Legacy FFmpeg: [dshow @ ...]  "Device Name" under DirectShow audio devices
        if ($inLegacyAudioSection -and ($line -match '\[dshow\s+@[^\]]+\]\s+"([^"]+)"\s*$')) {
            $entry = [PSCustomObject]@{
                Name            = $Matches[1]
                AlternativeName = ''
            }
            $devices.Add($entry)
            $lastAudioDevice = $entry
        }
    }

    return $devices.ToArray()
}

function Get-DShowAudioDevices {
    [CmdletBinding()]
    param(
        [string]$FfmpegPath = 'ffmpeg',
        [string]$BaseDir = ''
    )

    $resolved = Resolve-ExecutablePath -ConfiguredPath $FfmpegPath -BaseDir $BaseDir
    if (-not $resolved) {
        return @()
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolved
    $psi.Arguments = '-hide_banner -list_devices true -f dshow -i dummy'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stderr = $proc.StandardError.ReadToEnd()
        $stdout = $proc.StandardOutput.ReadToEnd()
        [void]$proc.WaitForExit(5000)
        $combined = @()
        if ($stderr) { $combined += ($stderr -split "`r?`n") }
        if ($stdout) { $combined += ($stdout -split "`r?`n") }
        return @(ConvertFrom-DShowDeviceOutput -Lines $combined)
    }
    finally {
        $proc.Dispose()
    }
}

function Get-DefaultMicStreamConfig {
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        audio = [PSCustomObject]@{
            microphoneName      = 'Microphone Array (Realtek(R) Audio)'
            enableAmbientBoost  = $true
            audioBufferSizeMs   = 50
            highpassHz          = 100
            dynaudnormFrameMs   = 50
            dynaudnormGaussSize = 5
            dynaudnormMaxGain   = 10
            sampleRate          = 48000
            channels            = 1
            bitrateKbps         = 48
            opusApplication     = 'lowdelay'
            opusFrameDurationMs = 20
            noiseReduction      = 'off'
            rnnoiseModelPath    = 'models/bd.rnnn'
        }
        recording = [PSCustomObject]@{
            recordingsDir          = 'recordings'
            format                 = 'mp3'
            bitrateKbps            = 96
            applyAmbientBoost      = $true
            defaultAutoStopMinutes = 0
            hotkey                 = [PSCustomObject]@{
                modifiers  = 6
                virtualKey = 121
                label      = 'Ctrl+Shift+F10'
            }
        }
        paths = [PSCustomObject]@{
            ffmpegPath      = 'ffmpeg'
            mediamtxExe     = 'mediamtx.exe'
            mediamtxConfig  = 'mediamtx.yml'
            logDir          = 'logs'
            maxLogSizeBytes = 2097152
        }
        stream = [PSCustomObject]@{
            rtspHost      = '127.0.0.1'
            rtspPort      = 8554
            webrtcPort    = 8889
            webrtcUdpPort = 8189
            streamPath    = 'mic'
        }
        dashboard = [PSCustomObject]@{
            enabled  = $true
            host     = '0.0.0.0'
            port     = 8890
            nodePath = 'node'
        }
        network = [PSCustomObject]@{
            autoFilterInterfaces     = $true
            excludeInterfacePatterns = @(
                '*VMware*',
                '*vEthernet*',
                '*WSL*',
                '*Hyper-V*',
                '*ProtonVPN*',
                '*Surfshark*',
                '*OpenVPN*',
                '*VeePN*',
                '*Loopback*',
                '*Bluetooth*'
            )
            publicUrl                = ''
            cloudflared              = [PSCustomObject]@{
                enabled   = $false
                exePath   = 'cloudflared.exe'
                tokenFile = 'cloudflared.token'
            }
        }
        hotkey = [PSCustomObject]@{
            modifiers  = 6
            virtualKey = 120
            label      = 'Ctrl+Shift+F9'
        }
        watchdog = [PSCustomObject]@{
            intervalMs             = 5000
            rtspReadyTimeoutMs     = 5000
            startupVerifyMs        = 1200
            maxConsecutiveFailures = 5
            backoffSeconds         = @(2, 5, 15, 30, 60)
        }
    }
}

function Merge-ConfigObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Base,
        [Parameter(Mandatory = $true)]
        $Override
    )

    if ($null -eq $Override) { return $Base }

    foreach ($prop in $Override.PSObject.Properties) {
        $name = $prop.Name
        $val = $prop.Value
        $hasBaseProp = $null -ne $Base.PSObject.Properties[$name]
        if ($hasBaseProp -and ($Base.$name -is [PSCustomObject]) -and ($val -is [PSCustomObject])) {
            [void](Merge-ConfigObjects -Base $Base.$name -Override $val)
        }
        elseif ($hasBaseProp) {
            $Base.$name = $val
        }
        else {
            $Base | Add-Member -NotePropertyName $name -NotePropertyValue $val -Force
        }
    }

    return $Base
}

function Get-MicStreamConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [string]$FallbackTemplatePath = ''
    )

    $cfg = Get-DefaultMicStreamConfig

    if ($FallbackTemplatePath -and (Test-Path -LiteralPath $FallbackTemplatePath)) {
        $rawTemplate = Get-Content -LiteralPath $FallbackTemplatePath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($rawTemplate)) {
            $tplObj = $rawTemplate | ConvertFrom-Json
            $cfg = Merge-ConfigObjects -Base $cfg -Override $tplObj
        }
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $userObj = $raw | ConvertFrom-Json
            $cfg = Merge-ConfigObjects -Base $cfg -Override $userObj
        }
    }

    return $cfg
}

function Save-MicStreamConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $parent = Split-Path -Parent $ConfigPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 10
    $tmpPath = "$ConfigPath.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $json + [Environment]::NewLine, $utf8NoBom)
    Move-Item -LiteralPath $tmpPath -Destination $ConfigPath -Force
}

function Get-AudioFilterChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [bool]$ApplyBoost = $true,
        [string]$BaseDir = ''
    )

    $mode = 'off'
    if ($null -ne $Config.audio.PSObject.Properties['noiseReduction'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.audio.noiseReduction)) {
        $mode = ([string]$Config.audio.noiseReduction).Trim().ToLowerInvariant()
    }
    if ($mode -notin @('off', 'light', 'clean', 'voice_ai')) {
        $mode = 'off'
    }

    $modelRel = 'models/bd.rnnn'
    if ($null -ne $Config.audio.PSObject.Properties['rnnoiseModelPath'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.audio.rnnoiseModelPath)) {
        $modelRel = ([string]$Config.audio.rnnoiseModelPath).Trim().Replace('\', '/')
    }

    # Safely degrade voice_ai -> clean (FFT) if BaseDir is known and RNNoise model file is absent
    if ($mode -eq 'voice_ai' -and -not [string]::IsNullOrWhiteSpace($BaseDir)) {
        $fullModel = if ([System.IO.Path]::IsPathRooted($modelRel)) { $modelRel } else { Join-Path $BaseDir ($modelRel.Replace('/', '\')) }
        if (-not (Test-Path -LiteralPath $fullModel)) {
            $mode = 'clean'
        }
    }

    $hp = [int]$Config.audio.highpassHz
    $fMs = [int]$Config.audio.dynaudnormFrameMs
    $gSize = [int]$Config.audio.dynaudnormGaussSize
    $mGain = [int]$Config.audio.dynaudnormMaxGain
    $gentleGain = [Math]::Min(4, $mGain)

    $chain = New-Object System.Collections.Generic.List[string]

    switch ($mode) {
        'light' {
            $chain.Add('highpass=f=130')
            $chain.Add('lowpass=f=7500')
            if ($ApplyBoost) {
                $chain.Add("dynaudnorm=f=$($fMs):g=$($gSize):m=$($gentleGain):t=0.02")
            }
        }
        'clean' {
            $chain.Add('highpass=f=130')
            $chain.Add('lowpass=f=7800')
            $chain.Add('afftdn=nr=12:nf=-40:tn=1')
            if ($ApplyBoost) {
                $chain.Add("dynaudnorm=f=$($fMs):g=$($gSize):m=$($gentleGain):t=0.02")
            }
        }
        'voice_ai' {
            $chain.Add('aresample=48000')
            $chain.Add('highpass=f=120')
            $chain.Add("arnndn=m=$($modelRel):mix=0.9")
            $chain.Add('lowpass=f=8000')
            if ($ApplyBoost) {
                $chain.Add("dynaudnorm=f=$($fMs):g=$($gSize):m=$($gentleGain):t=0.02")
            }
        }
        default {
            if ($ApplyBoost) {
                $chain.Add("highpass=f=$hp")
                $chain.Add("dynaudnorm=f=$($fMs):g=$($gSize):m=$($mGain)")
            }
        }
    }

    return ($chain.ToArray() -join ',')
}

function Get-FfmpegArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$BaseDir = ''
    )

    $micName = [string]$Config.audio.microphoneName
    if ([string]::IsNullOrWhiteSpace($micName)) {
        throw 'Config audio.microphoneName must not be empty.'
    }

    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add('-hide_banner')
    $argsList.Add('-loglevel')
    $argsList.Add('warning')
    $argsList.Add('-f')
    $argsList.Add('dshow')
    $argsList.Add('-audio_buffer_size')
    $argsList.Add([string]$Config.audio.audioBufferSizeMs)
    $argsList.Add('-i')
    $argsList.Add("audio=$micName")

    $filterChain = Get-AudioFilterChain -Config $Config -ApplyBoost ([bool]$Config.audio.enableAmbientBoost) -BaseDir $BaseDir
    if (-not [string]::IsNullOrWhiteSpace($filterChain)) {
        $argsList.Add('-af')
        $argsList.Add($filterChain)
    }

    $argsList.Add('-c:a')
    $argsList.Add('libopus')
    $argsList.Add('-application')
    $argsList.Add([string]$Config.audio.opusApplication)
    $argsList.Add('-frame_duration')
    $argsList.Add([string]$Config.audio.opusFrameDurationMs)
    $argsList.Add('-ar')
    $argsList.Add([string]$Config.audio.sampleRate)
    $argsList.Add('-ac')
    $argsList.Add([string]$Config.audio.channels)
    $argsList.Add('-b:a')
    $argsList.Add("$($Config.audio.bitrateKbps)k")
    $argsList.Add('-f')
    $argsList.Add('rtsp')
    $argsList.Add('-rtsp_transport')
    $argsList.Add('tcp')
    $argsList.Add("rtsp://$($Config.stream.rtspHost):$($Config.stream.rtspPort)/$($Config.stream.streamPath)")

    return $argsList.ToArray()
}

function New-RecordingFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RecordingsDir,
        [string]$Format = 'mp3',
        [datetime]$Timestamp = (Get-Date)
    )

    $ext = $Format.TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = 'mp3' }
    $stamp = $Timestamp.ToString('yyyy-MM-dd_HH-mm-ss')
    return Join-Path $RecordingsDir "mic_${stamp}.$ext"
}

function Get-RecordingArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputFilePath,
        [int]$AutoStopMinutes = 0,
        [string]$BaseDir = ''
    )

    $micName = [string]$Config.audio.microphoneName
    if ([string]::IsNullOrWhiteSpace($micName)) {
        throw 'Config audio.microphoneName must not be empty.'
    }

    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add('-hide_banner')
    $argsList.Add('-loglevel')
    $argsList.Add('warning')
    $argsList.Add('-y')
    $argsList.Add('-f')
    $argsList.Add('dshow')
    $argsList.Add('-audio_buffer_size')
    $argsList.Add([string]$Config.audio.audioBufferSizeMs)
    $argsList.Add('-i')
    $argsList.Add("audio=$micName")

    if ($AutoStopMinutes -gt 0) {
        $argsList.Add('-t')
        $argsList.Add([string]($AutoStopMinutes * 60))
    }

    $recFilter = Get-AudioFilterChain -Config $Config -ApplyBoost ([bool]$Config.recording.applyAmbientBoost) -BaseDir $BaseDir
    if (-not [string]::IsNullOrWhiteSpace($recFilter)) {
        $argsList.Add('-af')
        $argsList.Add($recFilter)
    }

    $fmt = ([string]$Config.recording.format).TrimStart('.').ToLowerInvariant()
    $bitrate = [int]$Config.recording.bitrateKbps
    if ($bitrate -le 0) { $bitrate = 96 }

    switch ($fmt) {
        'ogg' {
            $argsList.Add('-c:a'); $argsList.Add('libopus')
            $argsList.Add('-b:a'); $argsList.Add("${bitrate}k")
        }
        'm4a' {
            $argsList.Add('-c:a'); $argsList.Add('aac')
            $argsList.Add('-b:a'); $argsList.Add("${bitrate}k")
            $argsList.Add('-movflags'); $argsList.Add('+frag_keyframe+empty_moov')
        }
        'wav' {
            $argsList.Add('-c:a'); $argsList.Add('pcm_s16le')
        }
        default {
            # MP3 is crash-safe (frame-based) and universally playable across Windows/iOS/Android
            $argsList.Add('-c:a'); $argsList.Add('libmp3lame')
            $argsList.Add('-b:a'); $argsList.Add("${bitrate}k")
        }
    }

    $argsList.Add('-ar')
    $argsList.Add([string]$Config.audio.sampleRate)
    $argsList.Add('-ac')
    $argsList.Add([string]$Config.audio.channels)
    $argsList.Add($OutputFilePath)

    return $argsList.ToArray()
}

function Format-RecordingTimer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Elapsed,
        [int]$AutoStopMinutes = 0
    )

    $elStr = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds
    if ($AutoStopMinutes -le 0) {
        return "$elStr (Manual)"
    }

    $limit = [TimeSpan]::FromMinutes($AutoStopMinutes)
    $rem = $limit - $Elapsed
    if ($rem.TotalSeconds -lt 0) { $rem = [TimeSpan]::Zero }
    $remStr = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($rem.TotalHours), $rem.Minutes, $rem.Seconds
    return "$elStr / ${AutoStopMinutes}m ($remStr left)"
}

function Get-CloudflaredArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Token
    )

    return @('tunnel', '--no-autoupdate', 'run', '--token', $Token.Trim())
}

function Get-CloudflaredToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TokenPath
    )

    if (-not (Test-Path -LiteralPath $TokenPath)) {
        return ''
    }
    $raw = Get-Content -LiteralPath $TokenPath -Raw -Encoding UTF8
    if ($null -eq $raw) { return '' }
    return $raw.Trim()
}

function Test-MediaMtxConfigReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        return [PSCustomObject]@{
            Ready  = $false
            Reason = "MediaMTX config not found at $YamlPath. Run scripts\Install-MediaMTX.ps1 first."
        }
    }

    $content = Get-Content -LiteralPath $YamlPath -Raw -Encoding UTF8
    if ($content -match 'REPLACE_BY_RUNNING_Set-StreamPassword\.ps1' -or $content -match 'CHANGE_THIS_STRONG_PASSWORD') {
        return [PSCustomObject]@{
            Ready  = $false
            Reason = 'Stream password is still a placeholder. Run .\scripts\Set-StreamPassword.ps1 first.'
        }
    }

    if ($content -notmatch '(?m)^\s*authInternalUsers\s*:') {
        return [PSCustomObject]@{
            Ready  = $false
            Reason = 'authInternalUsers section is missing from mediamtx.yml.'
        }
    }

    return [PSCustomObject]@{
        Ready  = $true
        Reason = 'OK'
    }
}

function Update-MediaMtxUserPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath,
        [string]$User = 'admin',
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PasswordHash
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw "MediaMTX YAML file not found: $YamlPath"
    }

    $lines = [System.IO.File]::ReadAllLines($YamlPath, [System.Text.Encoding]::UTF8)
    $inAuthSection = $false
    $inTargetUser = $false
    $updated = $false

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]

        if ($line -match '^authInternalUsers\s*:') {
            $inAuthSection = $true
            $inTargetUser = $false
            continue
        }

        if ($inAuthSection -and ($line -match '^[A-Za-z0-9_]+\s*:')) {
            $inAuthSection = $false
            $inTargetUser = $false
            continue
        }

        if (-not $inAuthSection) { continue }

        if ($line -match '^\s*-\s+user\s*:\s*["'']?([^"''\s#]+)["'']?') {
            $foundUser = $Matches[1]
            $inTargetUser = ($foundUser -eq $User)
            continue
        }

        if ($inTargetUser -and ($line -match '^(\s*)pass\s*:')) {
            $indent = $Matches[1]
            $lines[$i] = "${indent}pass: '$PasswordHash'"
            $updated = $true
            $inTargetUser = $false
            break
        }
    }

    if (-not $updated) {
        throw "User '$User' with a 'pass:' field was not found inside authInternalUsers in $YamlPath."
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($YamlPath, ($lines -join "`r`n") + "`r`n", $utf8NoBom)
}

function Update-MediaMtxTurnConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath,
        [AllowEmptyString()]
        [string]$TurnUrl = '',
        [string]$Username = 'AUTH_SECRET',
        [AllowEmptyString()]
        [string]$Password = '',
        [bool]$ClientOnly = $false
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw "MediaMTX YAML file not found: $YamlPath"
    }

    $lines = [System.IO.File]::ReadAllLines($YamlPath, [System.Text.Encoding]::UTF8)
    $out = New-Object System.Collections.Generic.List[string]
    $found = $false
    $skipBlock = $false

    $clientOnlyLiteral = if ($ClientOnly) { 'yes' } else { 'no' }

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]

        if ($skipBlock) {
            # Stop skipping once we hit a top-level key, comment, or blank line
            if ($line -match '^[A-Za-z0-9_]+\s*:' -or $line -match '^#' -or [string]::IsNullOrWhiteSpace($line)) {
                $skipBlock = $false
            }
            else {
                continue
            }
        }

        if ($line -match '^webrtcICEServers2\s*:') {
            $found = $true
            $skipBlock = $true
            if ([string]::IsNullOrWhiteSpace($TurnUrl)) {
                $out.Add('webrtcICEServers2: []')
            }
            else {
                $safeUrl = $TurnUrl.Trim().Replace("'", "''")
                $safeUser = $Username.Trim().Replace("'", "''")
                $safePass = $Password.Trim().Replace("'", "''")
                $out.Add('webrtcICEServers2:')
                $out.Add("  - url: '$safeUrl'")
                $out.Add("    username: '$safeUser'")
                $out.Add("    password: '$safePass'")
                $out.Add("    clientOnly: $clientOnlyLiteral")
            }
            continue
        }

        $out.Add($line)
    }

    if (-not $found) {
        if ([string]::IsNullOrWhiteSpace($TurnUrl)) {
            $out.Add('webrtcICEServers2: []')
        }
        else {
            $safeUrl = $TurnUrl.Trim().Replace("'", "''")
            $safeUser = $Username.Trim().Replace("'", "''")
            $safePass = $Password.Trim().Replace("'", "''")
            $out.Add('')
            $out.Add('webrtcICEServers2:')
            $out.Add("  - url: '$safeUrl'")
            $out.Add("    username: '$safeUser'")
            $out.Add("    password: '$safePass'")
            $out.Add("    clientOnly: $clientOnlyLiteral")
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($YamlPath, ($out.ToArray() -join "`r`n") + "`r`n", $utf8NoBom)
}

function Resolve-ExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfiguredPath,
        [string]$BaseDir = ''
    )

    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        if (Test-Path -LiteralPath $ConfiguredPath) { return $ConfiguredPath }
        return $null
    }

    if ($BaseDir) {
        $candidate = Join-Path $BaseDir $ConfiguredPath
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $cmd = Get-Command -Name $ConfiguredPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    return $null
}

function Get-HostIpv4Adapters {
    [CmdletBinding()]
    param()

    $adapters = @{}
    try {
        Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
            $adapters[$_.Name] = $_.Status.ToString()
        }
    }
    catch {
        # Fallback if Get-NetAdapter unavailable
    }

    $results = New-Object System.Collections.Generic.List[object]
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($ip in $ips) {
        $alias = [string]$ip.InterfaceAlias
        $status = if ($adapters.ContainsKey($alias)) { $adapters[$alias] } else { 'Up' }
        $results.Add([PSCustomObject]@{
            InterfaceAlias = $alias
            IPAddress      = [string]$ip.IPAddress
            Status         = $status
        })
    }
    return $results.ToArray()
}

function Test-IsTailscaleInterface {
    [CmdletBinding()]
    param(
        [string]$InterfaceAlias,
        [string]$IPAddress
    )

    if ($InterfaceAlias -like '*Tailscale*') {
        return $true
    }
    if ($IPAddress -match '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.') {
        return $true
    }
    return $false
}

function Get-PreferredNetworkInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Adapters,
        [string[]]$ExcludePatterns = @()
    )

    $tailscaleNames = New-Object System.Collections.Generic.List[string]
    $otherNames = New-Object System.Collections.Generic.List[string]

    foreach ($adapter in $Adapters) {
        if ($null -eq $adapter) { continue }
        $alias = [string]$adapter.InterfaceAlias
        $ip = [string]$adapter.IPAddress
        $status = if ($null -ne $adapter.PSObject.Properties['Status']) { [string]$adapter.Status } else { 'Up' }

        if ([string]::IsNullOrWhiteSpace($alias) -or [string]::IsNullOrWhiteSpace($ip)) { continue }
        if ($status -ne 'Up') { continue }
        if ($ip -like '127.*' -or $ip -like '169.254.*') { continue }

        if (Test-IsTailscaleInterface -InterfaceAlias $alias -IPAddress $ip) {
            if (-not $tailscaleNames.Contains($alias)) {
                $tailscaleNames.Add($alias)
            }
            continue
        }

        $excluded = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($alias -like $pattern) {
                $excluded = $true
                break
            }
        }
        if ($excluded) { continue }

        if (-not $otherNames.Contains($alias)) {
            $otherNames.Add($alias)
        }
    }

    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($n in $tailscaleNames) { $ordered.Add($n) }
    foreach ($n in $otherNames) { $ordered.Add($n) }
    return $ordered.ToArray()
}

function Get-TailscaleInfo {
    [CmdletBinding()]
    param()

    $tsExe = Resolve-ExecutablePath -ConfiguredPath 'tailscale'
    if (-not $tsExe -and (Test-Path -LiteralPath 'C:\Program Files\Tailscale\tailscale.exe')) {
        $tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
    }

    if (-not $tsExe) {
        return [PSCustomObject]@{
            Installed = $false
            Connected = $false
            IPv4      = ''
            DnsName   = ''
        }
    }

    $ipv4 = ''
    $dnsName = ''
    $connected = $false

    try {
        $statusRaw = & $tsExe status --json 2>$null
        if ($statusRaw) {
            $statusObj = ($statusRaw -join "`n") | ConvertFrom-Json
            if ($statusObj.BackendState -eq 'Running' -and $statusObj.Self) {
                $connected = $true
                if ($statusObj.Self.TailscaleIPs) {
                    $ipv4 = ($statusObj.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
                }
                if ($statusObj.Self.DNSName) {
                    $dnsName = ([string]$statusObj.Self.DNSName).TrimEnd('.')
                }
            }
        }
    }
    catch {
        # Ignore CLI parse errors
    }

    return [PSCustomObject]@{
        Installed = $true
        Connected = $connected
        IPv4      = [string]$ipv4
        DnsName   = [string]$dnsName
    }
}

function Get-StreamEndpoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [object[]]$Adapters = $null,
        [string]$TailscaleIpv4 = '',
        [string]$TailscaleDnsName = '',
        [switch]$SkipLiveTailscaleProbe
    )

    if ($null -eq $Adapters) {
        $Adapters = @(Get-HostIpv4Adapters)
    }

    $port = [int]$Config.stream.webrtcPort
    $path = ([string]$Config.stream.streamPath).TrimStart('/')
    $excludePatterns = @($Config.network.excludeInterfacePatterns)

    if (-not $SkipLiveTailscaleProbe -and [string]::IsNullOrWhiteSpace($TailscaleIpv4)) {
        $tsInfo = Get-TailscaleInfo
        if ($tsInfo.Connected) {
            $TailscaleIpv4 = $tsInfo.IPv4
            if ([string]::IsNullOrWhiteSpace($TailscaleDnsName)) {
                $TailscaleDnsName = $tsInfo.DnsName
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($TailscaleIpv4)) {
        foreach ($a in $Adapters) {
            if ($null -eq $a) { continue }
            $status = if ($null -ne $a.PSObject.Properties['Status']) { [string]$a.Status } else { 'Up' }
            if ($status -eq 'Up' -and (Test-IsTailscaleInterface -InterfaceAlias $a.InterfaceAlias -IPAddress $a.IPAddress)) {
                $TailscaleIpv4 = [string]$a.IPAddress
                break
            }
        }
    }

    $endpoints = New-Object System.Collections.Generic.List[object]

    $publicUrl = [string]$Config.network.publicUrl
    if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
        $trimmed = $publicUrl.Trim().TrimEnd('/')
        $suffix = "/$path"
        $fullPublic = if ($trimmed.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { $trimmed } else { "$trimmed$suffix" }
        $endpoints.Add([PSCustomObject]@{
            Label     = "Public / Tunnel ($fullPublic)"
            Url       = $fullPublic
            Transport = 'Tunnel'
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($TailscaleDnsName)) {
        $cleanDns = $TailscaleDnsName.TrimEnd('.')
        $endpoints.Add([PSCustomObject]@{
            Label     = "Tailscale HTTPS ($cleanDns)"
            Url       = "https://$cleanDns/$path"
            Transport = 'Tailscale-HTTPS'
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($TailscaleIpv4)) {
        $endpoints.Add([PSCustomObject]@{
            Label     = "Tailscale Direct ($TailscaleIpv4)"
            Url       = "http://${TailscaleIpv4}:$port/$path"
            Transport = 'Tailscale'
        })
    }

    $preferredNames = @(Get-PreferredNetworkInterfaces -Adapters $Adapters -ExcludePatterns $excludePatterns)
    $seenLanIps = New-Object System.Collections.Generic.HashSet[string]
    foreach ($name in $preferredNames) {
        $matching = $Adapters | Where-Object {
            $_.InterfaceAlias -eq $name -and
            (-not (Test-IsTailscaleInterface -InterfaceAlias $_.InterfaceAlias -IPAddress $_.IPAddress)) -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*'
        } | Select-Object -First 1

        if ($matching -and $seenLanIps.Add([string]$matching.IPAddress)) {
            $ip = [string]$matching.IPAddress
            $endpoints.Add([PSCustomObject]@{
                Label     = "LAN - $name ($ip)"
                Url       = "http://${ip}:$port/$path"
                Transport = 'LAN'
            })
        }
    }

    $endpoints.Add([PSCustomObject]@{
        Label     = "Localhost (127.0.0.1:$port)"
        Url       = "http://127.0.0.1:$port/$path"
        Transport = 'Localhost'
    })

    return $endpoints.ToArray()
}

function Test-TcpPortOpen {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [int]$TimeoutMs = 250
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($ar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Invoke-LogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [long]$MaxBytes = 2097152
    )

    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $LogPath) {
        $fileInfo = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -ge $MaxBytes) {
            $prevPath = "$LogPath.prev"
            Move-Item -LiteralPath $LogPath -Destination $prevPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-TrayLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [long]$MaxBytes = 2097152
    )

    try {
        Invoke-LogRotation -LogPath $LogPath -MaxBytes $MaxBytes
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $line = "[$ts] [$Level] $Message"
        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        # Never crash the tray UI if logging fails
    }
}

Export-ModuleMember -Function @(
    'Format-NativeArgument',
    'Join-NativeArguments',
    'ConvertTo-MediaMtxSha256Hash',
    'ConvertFrom-DShowDeviceOutput',
    'Get-DShowAudioDevices',
    'Get-DefaultMicStreamConfig',
    'Merge-ConfigObjects',
    'Get-MicStreamConfig',
    'Save-MicStreamConfig',
    'Get-AudioFilterChain',
    'Get-FfmpegArguments',
    'New-RecordingFilePath',
    'Get-RecordingArguments',
    'Format-RecordingTimer',
    'Get-CloudflaredArguments',
    'Get-CloudflaredToken',
    'Test-MediaMtxConfigReady',
    'Update-MediaMtxUserPassword',
    'Update-MediaMtxTurnConfig',
    'Resolve-ExecutablePath',
    'Get-HostIpv4Adapters',
    'Test-IsTailscaleInterface',
    'Get-PreferredNetworkInterfaces',
    'Get-TailscaleInfo',
    'Get-StreamEndpoints',
    'Test-TcpPortOpen',
    'Invoke-LogRotation',
    'Write-TrayLog'
)

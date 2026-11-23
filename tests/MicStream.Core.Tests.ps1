#Requires -Version 5.1
# Pester 3.4-compatible unit test suite for MicStream.Core.psm1

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'lib\MicStream.Core.psm1'
Import-Module $modulePath -Force

Describe 'Native Argument Quoting (PS 5.1 Start-Process fix)' {
    It 'leaves simple tokens unquoted' {
        Format-NativeArgument -Value '-f' | Should Be '-f'
        Format-NativeArgument -Value 'libopus' | Should Be 'libopus'
    }

    It 'quotes arguments with spaces and parentheses such as Realtek DirectShow mic names' {
        $arg = 'audio=Microphone Array (Realtek(R) Audio)'
        Format-NativeArgument -Value $arg | Should Be '"audio=Microphone Array (Realtek(R) Audio)"'
    }

    It 'quotes empty strings properly' {
        Format-NativeArgument -Value '' | Should Be '""'
    }

    It 'escapes embedded double quotes and trailing backslashes' {
        Format-NativeArgument -Value 'C:\My Folder\' | Should Be '"C:\My Folder\\"'
        Format-NativeArgument -Value 'say "hello"' | Should Be '"say \"hello\""'
    }

    It 'joins full FFmpeg argument lists safely' {
        $joined = Join-NativeArguments -Arguments @('-f', 'dshow', '-i', 'audio=Microphone Array (Realtek(R) Audio)')
        $joined | Should Be '-f dshow -i "audio=Microphone Array (Realtek(R) Audio)"'
    }
}

Describe 'MediaMTX SHA-256 Password Hashing' {
    It 'matches OpenSSL base64 SHA-256 digest for mypass' {
        ConvertTo-MediaMtxSha256Hash -PlainText 'mypass' | Should Be 'sha256:6nHCWnpgIka0w5gkuFVniJSpb0O7m3ExnDlwCh4EUiI='
    }

    It 'produces distinct hashes for distinct passwords' {
        $h1 = ConvertTo-MediaMtxSha256Hash -PlainText 'AlphaPassword123!'
        $h2 = ConvertTo-MediaMtxSha256Hash -PlainText 'BetaPassword456!'
        $h1 | Should Not Be $h2
        $h1 | Should Match '^sha256:[A-Za-z0-9+/]+={0,2}$'
    }
}

Describe 'FFmpeg DirectShow Audio Device Parsing' {
    It 'parses FFmpeg 9.x [in#0] device listing including wrapped alternative names' {
        $lines = @(
            '[in#0 @ 0000025b770f4180] "Integrated Camera" (video)',
            '[in#0 @ 0000025b770f4180]   Alternative name "@device_pnp_video"',
            '[in#0 @ 0000025b770f4180] "Microphone Array (Realtek(R) Audio)" (audio)',
            '[in#0 @ 0000025b770f4180]   Alternative name ',
            '"@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{AA62B8FF}"',
            '[in#0 @ 0000025b770f4180] "USB Condenser Mic" (audio)',
            '[in#0 @ 0000025b770f4180]   Alternative name "@device_cm_usb"'
        )
        $devices = ConvertFrom-DShowDeviceOutput -Lines $lines
        $devices.Count | Should Be 2
        $devices[0].Name | Should Be 'Microphone Array (Realtek(R) Audio)'
        $devices[0].AlternativeName | Should Be '@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{AA62B8FF}'
        $devices[1].Name | Should Be 'USB Condenser Mic'
        $devices[1].AlternativeName | Should Be '@device_cm_usb'
    }

    It 'parses legacy FFmpeg [dshow] device listing' {
        $lines = @(
            '[dshow @ 000001] DirectShow video devices',
            '[dshow @ 000001]  "Integrated Camera"',
            '[dshow @ 000001] DirectShow audio devices',
            '[dshow @ 000001]  "Headset Microphone"',
            '[dshow @ 000001]     Alternative name "@device_cm_headset"'
        )
        $devices = @(ConvertFrom-DShowDeviceOutput -Lines $lines)
        $devices.Count | Should Be 1
        $devices[0].Name | Should Be 'Headset Microphone'
        $devices[0].AlternativeName | Should Be '@device_cm_headset'
    }

    It 'tolerates empty lines from split stderr output' {
        $lines = @(
            '[in#0 @ 000001] "Microphone Array (Realtek(R) Audio)" (audio)',
            ''
        )
        $devices = @(ConvertFrom-DShowDeviceOutput -Lines $lines)
        $devices.Count | Should Be 1
        $devices[0].Name | Should Be 'Microphone Array (Realtek(R) Audio)'
    }
}

Describe 'FFmpeg Low-Latency Argument Builder' {
    It 'includes low-latency dynaudnorm filter when ambient boost is enabled' {
        $cfg = Get-DefaultMicStreamConfig
        $args = Get-FfmpegArguments -Config $cfg
        ($args -contains '-af') | Should Be $true
        ($args -contains 'highpass=f=100,dynaudnorm=f=50:g=5:m=10') | Should Be $true
        ($args -contains 'lowdelay') | Should Be $true
        ($args -contains '20') | Should Be $true
        ($args -contains 'rtsp://127.0.0.1:8554/mic') | Should Be $true
    }

    It 'omits -af when ambient boost is disabled' {
        $cfg = Get-DefaultMicStreamConfig
        $cfg.audio.enableAmbientBoost = $false
        $args = Get-FfmpegArguments -Config $cfg
        ($args -contains '-af') | Should Be $false
    }
}

Describe 'Config Load, Merge, and Atomic Save' {
    It 'merges partial user overrides onto defaults and round-trips cleanly' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("micstream_test_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmpDir 'config.json'
            $partial = '{"audio":{"enableAmbientBoost":false},"network":{"publicUrl":"https://mic.example.com"}}'
            [System.IO.File]::WriteAllText($cfgPath, $partial, (New-Object System.Text.UTF8Encoding($false)))

            $loaded = Get-MicStreamConfig -ConfigPath $cfgPath
            $loaded.audio.enableAmbientBoost | Should Be $false
            $loaded.audio.microphoneName | Should Be 'Microphone Array (Realtek(R) Audio)'
            $loaded.stream.webrtcPort | Should Be 8889
            $loaded.network.publicUrl | Should Be 'https://mic.example.com'

            $loaded.audio.microphoneName = 'USB Mic'
            Save-MicStreamConfig -Config $loaded -ConfigPath $cfgPath

            $reloaded = Get-MicStreamConfig -ConfigPath $cfgPath
            $reloaded.audio.microphoneName | Should Be 'USB Mic'
            $reloaded.audio.enableAmbientBoost | Should Be $false
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'MediaMTX YAML Readiness and Password Updates' {
    It 'detects placeholder password and updates admin hash without touching loopback publisher' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("micstream_yml_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $ymlPath = Join-Path $tmpDir 'mediamtx.yml'
            Copy-Item -LiteralPath (Join-Path $repoRoot 'mediamtx.example.yml') -Destination $ymlPath

            $before = Test-MediaMtxConfigReady -YamlPath $ymlPath
            $before.Ready | Should Be $false

            $hash = ConvertTo-MediaMtxSha256Hash -PlainText 'mypass'
            Update-MediaMtxUserPassword -YamlPath $ymlPath -User 'admin' -PasswordHash $hash

            $after = Test-MediaMtxConfigReady -YamlPath $ymlPath
            $after.Ready | Should Be $true

            $raw = Get-Content -LiteralPath $ymlPath -Raw
            ($raw -match "pass: 'sha256:6nHCWnpgIka0w5gkuFVniJSpb0O7m3ExnDlwCh4EUiI='") | Should Be $true
            # Ensure loopback 'any' user still has empty pass
            ($raw -match "(?ms)- user: any\s+pass: ''") | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Multi-Transport Interface Filtering & Endpoint Discovery' {
    It 'filters virtual, VPN, and APIPA adapters while retaining Tailscale and Wi-Fi' {
        $cfg = Get-DefaultMicStreamConfig
        $mockAdapters = @(
            [PSCustomObject]@{ InterfaceAlias = 'vEthernet (WSL (Hyper-V firewall))'; IPAddress = '172.23.224.1'; Status = 'Up' },
            [PSCustomObject]@{ InterfaceAlias = 'VMware Network Adapter VMnet8'; IPAddress = '192.168.192.1'; Status = 'Up' },
            [PSCustomObject]@{ InterfaceAlias = 'ProtonVPN'; IPAddress = '10.2.0.2'; Status = 'Up' },
            [PSCustomObject]@{ InterfaceAlias = 'OpenVPN Data Channel Offload for Surfshark'; IPAddress = '10.11.11.5'; Status = 'Up' },
            [PSCustomObject]@{ InterfaceAlias = 'Ethernet'; IPAddress = '169.254.187.137'; Status = 'Up' },
            [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPAddress = '192.168.1.233'; Status = 'Up' },
            [PSCustomObject]@{ InterfaceAlias = 'Tailscale'; IPAddress = '100.88.12.34'; Status = 'Up' }
        )

        $preferred = @(Get-PreferredNetworkInterfaces -Adapters $mockAdapters -ExcludePatterns $cfg.network.excludeInterfacePatterns)
        $preferred.Count | Should Be 2
        $preferred[0] | Should Be 'Tailscale'
        $preferred[1] | Should Be 'Wi-Fi'

        $cfg.network.publicUrl = 'https://mic.example.com'
        $endpoints = @(Get-StreamEndpoints -Config $cfg -Adapters $mockAdapters -TailscaleIpv4 '100.88.12.34' -TailscaleDnsName 'laptop.tailnet.ts.net' -SkipLiveTailscaleProbe)
        ($endpoints | Where-Object { $_.Transport -eq 'Tailscale-HTTPS' }).Url | Should Be 'https://laptop.tailnet.ts.net/mic'
        ($endpoints | Where-Object { $_.Transport -eq 'Tailscale' }).Url | Should Be 'http://100.88.12.34:8889/mic'
        ($endpoints | Where-Object { $_.Transport -eq 'Tunnel' }).Url | Should Be 'https://mic.example.com/mic'
        ($endpoints | Where-Object { $_.Transport -eq 'LAN' }).Url | Should Be 'http://192.168.1.233:8889/mic'
        ($endpoints | Where-Object { $_.Transport -eq 'Localhost' }).Url | Should Be 'http://127.0.0.1:8889/mic'
    }

    It 'returns a flat string array when only a single preferred interface exists' {
        $cfg = Get-DefaultMicStreamConfig
        $singleAdapter = @(
            [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPAddress = '192.168.1.233'; Status = 'Up' }
        )
        $preferred = @(Get-PreferredNetworkInterfaces -Adapters $singleAdapter -ExcludePatterns $cfg.network.excludeInterfacePatterns)
        $preferred.Count | Should Be 1
        ($preferred -join ',') | Should Be 'Wi-Fi'
    }
}

Describe 'Log Rotation' {
    It 'rotates log files exceeding MaxBytes to .prev' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("micstream_log_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $logPath = Join-Path $tmpDir 'tray.log'
            [System.IO.File]::WriteAllText($logPath, ('A' * 200))
            Invoke-LogRotation -LogPath $logPath -MaxBytes 100
            (Test-Path -LiteralPath $logPath) | Should Be $false
            (Test-Path -LiteralPath "$logPath.prev") | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Audio Recording & Auto-Stop Helpers' {
    It 'uses conflict-free default hotkeys Ctrl+Shift+F9 and Ctrl+Shift+F10' {
        $cfg = Get-DefaultMicStreamConfig
        $cfg.hotkey.label | Should Be 'Ctrl+Shift+F9'
        $cfg.hotkey.modifiers | Should Be 6
        $cfg.hotkey.virtualKey | Should Be 120
        $cfg.recording.hotkey.label | Should Be 'Ctrl+Shift+F10'
        $cfg.recording.hotkey.modifiers | Should Be 6
        $cfg.recording.hotkey.virtualKey | Should Be 121
    }

    It 'builds timestamped recording output paths' {
        $dt = [datetime]'2026-11-23T22:05:10'
        $p = New-RecordingFilePath -RecordingsDir 'd:\DEV\mic\recordings' -Format 'mp3' -Timestamp $dt
        $p | Should Be 'd:\DEV\mic\recordings\mic_2026-11-23_22-05-10.mp3'
    }

    It 'omits -t for manual recordings and adds -t seconds for auto-stop recordings' {
        $cfg = Get-DefaultMicStreamConfig
        $manualArgs = @(Get-RecordingArguments -Config $cfg -OutputFilePath 'd:\rec\out.mp3' -AutoStopMinutes 0)
        ($manualArgs -contains '-t') | Should Be $false
        ($manualArgs -contains 'libmp3lame') | Should Be $true
        ($manualArgs -contains 'd:\rec\out.mp3') | Should Be $true

        $timedArgs = @(Get-RecordingArguments -Config $cfg -OutputFilePath 'd:\rec\out.mp3' -AutoStopMinutes 15)
        ($timedArgs -contains '-t') | Should Be $true
        ($timedArgs -contains '900') | Should Be $true
    }

    It 'formats manual and auto-stop countdown timers cleanly' {
        Format-RecordingTimer -Elapsed ([TimeSpan]::FromSeconds(75)) -AutoStopMinutes 0 | Should Be '00:01:15 (Manual)'
        Format-RecordingTimer -Elapsed ([TimeSpan]::FromSeconds(75)) -AutoStopMinutes 15 | Should Be '00:01:15 / 15m (00:13:45 left)'
    }
}

Describe 'Optional Cloudflare Tunnel & VPS coturn YAML Helpers' {
    It 'builds cloudflared tunnel run arguments and reads saved tokens' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("micstream_cf_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $tokPath = Join-Path $tmpDir 'cloudflared.token'
            [System.IO.File]::WriteAllText($tokPath, "  eyTestToken123  `r`n")
            $tok = Get-CloudflaredToken -TokenPath $tokPath
            $tok | Should Be 'eyTestToken123'

            $cfArgs = @(Get-CloudflaredArguments -Token $tok)
            ($cfArgs -join ' ') | Should Be 'tunnel --no-autoupdate run --token eyTestToken123'
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'updates, replaces, and clears webrtcICEServers2 cleanly in mediamtx.yml' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("micstream_turn_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $ymlPath = Join-Path $tmpDir 'mediamtx.yml'
            Copy-Item -LiteralPath (Join-Path $repoRoot 'mediamtx.example.yml') -Destination $ymlPath

            Update-MediaMtxTurnConfig -YamlPath $ymlPath -TurnUrl 'turn:203.0.113.10:3478' -Username 'AUTH_SECRET' -Password 'supersecret123'
            $raw1 = Get-Content -LiteralPath $ymlPath -Raw
            ($raw1 -match "url: 'turn:203\.0\.113\.10:3478'") | Should Be $true
            ($raw1 -match "username: 'AUTH_SECRET'") | Should Be $true
            ($raw1 -match "password: 'supersecret123'") | Should Be $true
            ($raw1 -match 'authMethod: internal') | Should Be $true

            # Replace existing entry without duplicating
            Update-MediaMtxTurnConfig -YamlPath $ymlPath -TurnUrl 'turns:turn.example.com:5349?transport=tcp' -Username 'AUTH_SECRET' -Password 'newsecret456'
            $raw2 = Get-Content -LiteralPath $ymlPath -Raw
            ($raw2 -match '203\.0\.113\.10') | Should Be $false
            ($raw2 -match "password: 'newsecret456'") | Should Be $true

            # Clear back to empty list
            Update-MediaMtxTurnConfig -YamlPath $ymlPath -TurnUrl ''
            $raw3 = Get-Content -LiteralPath $ymlPath -Raw
            ($raw3 -match '(?m)^webrtcICEServers2: \[\]') | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

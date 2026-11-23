#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$ShowPanel
)

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'lib\MicStream.Core.psm1') -Force

# ==================== WIN32 INTEROP & MANAGED PROCESS ====================
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace MicStreamNative {
    public sealed class GlobalHotkeyManager : NativeWindow, IDisposable {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        private const int WM_HOTKEY = 0x0312;
        private readonly HashSet<int> _registeredIds = new HashSet<int>();
        private bool _disposed;

        public int LastError { get; private set; }
        public event Action<int> HotkeyPressed;

        public GlobalHotkeyManager() {
            CreateHandle(new CreateParams());
        }

        public bool Register(int id, uint modifiers, uint key) {
            if (_disposed || this.Handle == IntPtr.Zero) return false;
            bool ok = RegisterHotKey(this.Handle, id, modifiers, key);
            if (ok) {
                _registeredIds.Add(id);
                LastError = 0;
            } else {
                LastError = Marshal.GetLastWin32Error();
            }
            return ok;
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_HOTKEY && HotkeyPressed != null) {
                HotkeyPressed(m.WParam.ToInt32());
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            if (_disposed) return;
            _disposed = true;
            if (this.Handle != IntPtr.Zero) {
                foreach (int id in _registeredIds) {
                    UnregisterHotKey(this.Handle, id);
                }
                _registeredIds.Clear();
                DestroyHandle();
            }
        }
    }

    public sealed class ProcessJob : IDisposable {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr hJob,
            int infoType,
            IntPtr lpJobObjectInfo,
            uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private const int JobObjectExtendedLimitInformation = 9;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        private IntPtr _handle;
        public bool IsActive { get; private set; }
        public int LastError { get; private set; }

        public ProcessJob() {
            _handle = CreateJobObject(IntPtr.Zero, null);
            if (_handle == IntPtr.Zero) {
                LastError = Marshal.GetLastWin32Error();
                return;
            }

            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr ptr = Marshal.AllocHGlobal(length);
            try {
                Marshal.StructureToPtr(info, ptr, false);
                IsActive = SetInformationJobObject(_handle, JobObjectExtendedLimitInformation, ptr, (uint)length);
                if (!IsActive) {
                    LastError = Marshal.GetLastWin32Error();
                }
            }
            finally {
                Marshal.FreeHGlobal(ptr);
            }
        }

        public bool AddProcess(IntPtr processHandle) {
            if (!IsActive || _handle == IntPtr.Zero || processHandle == IntPtr.Zero) {
                return false;
            }
            bool ok = AssignProcessToJobObject(_handle, processHandle);
            if (!ok) {
                LastError = Marshal.GetLastWin32Error();
            }
            return ok;
        }

        public void Dispose() {
            if (_handle != IntPtr.Zero) {
                CloseHandle(_handle);
                _handle = IntPtr.Zero;
                IsActive = false;
            }
        }
    }

    public sealed class ManagedLogProcess : IDisposable {
        private readonly object _logLock = new object();
        private readonly string _logFilePath;
        public Process Process { get; private set; }
        public int Id { get { return Process != null ? Process.Id : 0; } }
        public IntPtr Handle { get { return Process != null ? Process.Handle : IntPtr.Zero; } }
        public bool HasExited {
            get {
                if (Process == null) return true;
                try { return Process.HasExited; } catch { return true; }
            }
        }
        public int ExitCode {
            get {
                if (Process == null) return -1;
                try { return Process.ExitCode; } catch { return -1; }
            }
        }

        private ManagedLogProcess(Process proc, string logFilePath) {
            Process = proc;
            _logFilePath = logFilePath;
        }

        public static ManagedLogProcess Start(string fileName, string arguments, string workingDirectory, string logFilePath, bool redirectStdIn) {
            var psi = new ProcessStartInfo();
            psi.FileName = fileName;
            psi.Arguments = arguments;
            psi.WorkingDirectory = workingDirectory;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = redirectStdIn;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;

            var proc = new Process();
            proc.StartInfo = psi;
            proc.Start();

            var wrapper = new ManagedLogProcess(proc, logFilePath);
            wrapper.StartDrainThread(proc.StandardError);
            wrapper.StartDrainThread(proc.StandardOutput);
            return wrapper;
        }

        private void StartDrainThread(StreamReader reader) {
            var t = new Thread(() => {
                try {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        if (!string.IsNullOrEmpty(_logFilePath)) {
                            lock (_logLock) {
                                File.AppendAllText(_logFilePath, line + Environment.NewLine, new UTF8Encoding(false));
                            }
                        }
                    }
                }
                catch { }
            });
            t.IsBackground = true;
            t.Start();
        }

        public void StopGracefully(int gracefulWaitMs) {
            if (Process == null) return;
            try {
                if (!Process.HasExited) {
                    if (Process.StartInfo.RedirectStandardInput) {
                        try {
                            Process.StandardInput.WriteLine("q");
                            Process.StandardInput.Flush();
                            Process.WaitForExit(gracefulWaitMs);
                        }
                        catch { }
                    }
                    if (!Process.HasExited) {
                        Process.Kill();
                        Process.WaitForExit(2000);
                    }
                }
            }
            catch { }
        }

        public void Dispose() {
            if (Process != null) {
                try { Process.Dispose(); } catch { }
                Process = null;
            }
        }
    }

    public static class IconHelper {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }

    public static class WindowHelper {
        private const int SW_SHOWNORMAL = 1;
        private const int SW_RESTORE = 9;

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        public static void ForceShow(IntPtr hWnd) {
            if (hWnd == IntPtr.Zero) return;
            ShowWindow(hWnd, IsIconic(hWnd) ? SW_RESTORE : SW_SHOWNORMAL);
            SetForegroundWindow(hWnd);
        }
    }
}
"@

# ==================== SINGLE INSTANCE GUARD & PANEL WAKEUP ====================
$panelEventName = 'Local\MicStreamShowPanelEvent_v1'
$createdNew = $false
$script:singleInstanceMutex = New-Object System.Threading.Mutex($true, 'Local\MicStreamTrayDaemon_v1', [ref]$createdNew)
if (-not $createdNew) {
    if ($ShowPanel) {
        try {
            $evt = [System.Threading.EventWaitHandle]::OpenExisting($panelEventName)
            [void]$evt.Set()
            $evt.Dispose()
        }
        catch { }
    }
    $script:singleInstanceMutex.Dispose()
    exit 0
}

$script:showPanelEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $panelEventName)

# ==================== CONFIGURATION & LOGGING ====================
$script:configPath = Join-Path $scriptDir 'config.json'
$script:templateConfigPath = Join-Path $scriptDir 'config.example.json'
$script:config = Get-MicStreamConfig -ConfigPath $script:configPath -FallbackTemplatePath $script:templateConfigPath
if (-not (Test-Path -LiteralPath $script:configPath)) {
    Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
}

function Get-LogDirPath {
    $dir = [string]$script:config.paths.logDir
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $dir = Join-Path $scriptDir $dir
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-RecordingsDirPath {
    $dir = [string]$script:config.recording.recordingsDir
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $dir = Join-Path $scriptDir $dir
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-IpcDirPath {
    $dir = Join-Path (Get-LogDirPath) '.ipc'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-DaemonLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $trayLog = Join-Path (Get-LogDirPath) 'tray.log'
    Write-TrayLog -LogPath $trayLog -Level $Level -Message $Message -MaxBytes ([long]$script:config.paths.maxLogSizeBytes)
}

Write-DaemonLog -Level 'INFO' -Message "Starting MicStream Tray Daemon from $scriptDir"

# ==================== RUNTIME STATE ====================
$script:job = New-Object MicStreamNative.ProcessJob
if (-not $script:job.IsActive) {
    Write-DaemonLog -Level 'WARN' -Message "Win32 ProcessJob initialization failed (Win32Error=$($script:job.LastError)); relying on explicit stop handlers."
}

$script:mtxProc = $null
$script:ffProc = $null
$script:cfProc = $null
$script:recProc = $null
$script:dashProc = $null
$script:cachedMicrophones = @([string]$script:config.audio.microphoneName)
$script:lastIpcWrite = [DateTime]::MinValue

$script:desiredRunning = $false
$script:streamState = 'Stopped'
$script:streamDetail = ''
$script:isTransitioning = $false
$script:isShuttingDown = $false
$script:consecutiveFailures = 0
$script:healthyTicks = 0
$script:nextRetryAt = [DateTime]::MinValue

$script:isRecording = $false
$script:recStartTime = [DateTime]::MinValue
$script:recAutoStopMinutes = [int]$script:config.recording.defaultAutoStopMinutes
$script:recActiveLimitMinutes = 0
$script:recOutputFile = ''

# ==================== TRAY ICONS ====================
$script:iconHandles = New-Object System.Collections.Generic.List[IntPtr]

function New-StatusIcon {
    param(
        [System.Drawing.Color]$Color,
        [bool]$RecordingBadge = $false
    )
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 20, 20, 20), 1)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.FillEllipse($brush, 2, 2, 12, 12)
        $g.DrawEllipse($pen, 2, 2, 12, 12)
        if ($RecordingBadge) {
            $innerBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1)
            try {
                $g.FillEllipse($innerBrush, 5, 5, 6, 6)
                $g.DrawEllipse($ringPen, 5, 5, 6, 6)
            }
            finally {
                $ringPen.Dispose()
                $innerBrush.Dispose()
            }
        }
        $hIcon = $bmp.GetHicon()
        $script:iconHandles.Add($hIcon)
        return [System.Drawing.Icon]::FromHandle($hIcon)
    }
    finally {
        $pen.Dispose()
        $brush.Dispose()
        $g.Dispose()
        $bmp.Dispose()
    }
}

$script:iconStopped     = New-StatusIcon -Color ([System.Drawing.Color]::Gray)
$script:iconRunning     = New-StatusIcon -Color ([System.Drawing.Color]::LimeGreen)
$script:iconLiveRec     = New-StatusIcon -Color ([System.Drawing.Color]::LimeGreen) -RecordingBadge $true
$script:iconRecOnly     = New-StatusIcon -Color ([System.Drawing.Color]::Crimson)
$script:iconWarning     = New-StatusIcon -Color ([System.Drawing.Color]::Orange)
$script:iconError       = New-StatusIcon -Color ([System.Drawing.Color]::DarkRed)

$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:trayIcon.Icon = $script:iconStopped
$script:trayIcon.Visible = $true

function Show-TrayNotification {
    param(
        [string]$Title,
        [string]$Text,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info,
        [int]$TimeoutMs = 3000
    )
    try {
        $script:trayIcon.ShowBalloonTip($TimeoutMs, $Title, $Text, $Icon)
    }
    catch { }
}

function Update-AllUiState {
    $streamKey = [string]$script:config.hotkey.label
    $recKey = [string]$script:config.recording.hotkey.label
    $cfOn = ($null -ne $script:cfProc -and -not $script:cfProc.HasExited)

    # Pick combined tray icon
    if ($script:streamState -eq 'LIVE' -and $script:isRecording) {
        $script:trayIcon.Icon = $script:iconLiveRec
    }
    elseif ($script:streamState -eq 'LIVE') {
        $script:trayIcon.Icon = $script:iconRunning
    }
    elseif ($script:streamState -eq 'Starting' -or $script:streamState -eq 'Recovering') {
        $script:trayIcon.Icon = $script:iconWarning
    }
    elseif ($script:streamState -eq 'Error') {
        $script:trayIcon.Icon = $script:iconError
    }
    elseif ($script:isRecording) {
        $script:trayIcon.Icon = $script:iconRecOnly
    }
    else {
        $script:trayIcon.Icon = $script:iconStopped
    }

    # Tray tooltip (max 63 chars)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($script:streamState -eq 'LIVE') {
        $parts.Add($(if ($cfOn) { 'LIVE+Tunnel' } else { 'LIVE' }))
    }
    elseif ($script:streamState -ne 'Stopped') {
        $parts.Add($script:streamState)
    }
    if ($script:isRecording) {
        $parts.Add('REC')
    }
    if ($parts.Count -eq 0) {
        $tip = "MicStream: Stopped ($streamKey)"
    }
    else {
        $tip = 'MicStream: ' + ($parts -join ' | ')
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:trayIcon.Text = $tip

    # Menu items
    $detailSuffix = if ($script:streamDetail) { " ($($script:streamDetail))" } else { '' }
    $script:statusItem.Text = "Stream: $($script:streamState)$detailSuffix"
    $script:startItem.Enabled = ($script:streamState -eq 'Stopped' -or $script:streamState -eq 'Error')
    $script:stopItem.Enabled  = ($script:streamState -ne 'Stopped' -and $script:streamState -ne 'Error')

    $script:cfToggleItem.Checked = [bool]$script:config.network.cloudflared.enabled

    if ($script:isRecording) {
        $elapsed = (Get-Date) - $script:recStartTime
        $timerTxt = Format-RecordingTimer -Elapsed $elapsed -AutoStopMinutes $script:recActiveLimitMinutes
        $script:recToggleItem.Text = "Stop Recording ($recKey) [$timerTxt]"
    }
    else {
        $autoLbl = if ($script:recAutoStopMinutes -gt 0) { "Auto-stop $($script:recAutoStopMinutes)m" } else { 'Manual' }
        $script:recToggleItem.Text = "Start Recording ($recKey) [$autoLbl]"
    }

    # Control Panel sync (if created)
    if ($null -ne $script:panelForm -and -not $script:panelForm.IsDisposed) {
        $script:lblStreamStatus.Text = "Stream: $($script:streamState)$detailSuffix"
        $script:lblStreamStatus.ForeColor = switch ($script:streamState) {
            'LIVE'       { [System.Drawing.Color]::ForestGreen }
            'Starting'   { [System.Drawing.Color]::DarkOrange }
            'Recovering' { [System.Drawing.Color]::DarkOrange }
            'Error'      { [System.Drawing.Color]::Firebrick }
            default      { [System.Drawing.Color]::DimGray }
        }

        if ($script:desiredRunning) {
            $script:btnStreamToggle.Text = "Stop Stream ($streamKey)"
            $script:btnStreamToggle.BackColor = [System.Drawing.Color]::MistyRose
        }
        else {
            $script:btnStreamToggle.Text = "Start Stream ($streamKey)"
            $script:btnStreamToggle.BackColor = [System.Drawing.Color]::Honeydew
        }

        $script:suppressPanelEvents = $true
        try {
            $script:chkCloudflared.Checked = [bool]$script:config.network.cloudflared.enabled
        }
        finally {
            $script:suppressPanelEvents = $false
        }

        if ($cfOn) {
            $pubUrl = [string]$script:config.network.publicUrl
            $script:lblTunnelStatus.Text = if ($pubUrl) { "Tunnel: Online ($pubUrl)" } else { 'Tunnel: Online' }
            $script:lblTunnelStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        }
        elseif ([bool]$script:config.network.cloudflared.enabled) {
            $script:lblTunnelStatus.Text = 'Tunnel: Connecting (check 5-Configure-Remote.bat if needed)'
            $script:lblTunnelStatus.ForeColor = [System.Drawing.Color]::SteelBlue
        }
        else {
            $script:lblTunnelStatus.Text = 'Tunnel: Off (Local / LAN / Tailscale only)'
            $script:lblTunnelStatus.ForeColor = [System.Drawing.Color]::DimGray
        }

        if ($script:isRecording) {
            $elapsed = (Get-Date) - $script:recStartTime
            $timerTxt = Format-RecordingTimer -Elapsed $elapsed -AutoStopMinutes $script:recActiveLimitMinutes
            $script:lblRecStatus.Text = "REC: $timerTxt"
            $script:lblRecStatus.ForeColor = [System.Drawing.Color]::Crimson
            $script:btnRecToggle.Text = "Stop Recording ($recKey)"
            $script:btnRecToggle.BackColor = [System.Drawing.Color]::MistyRose
            $script:cmbAutoStop.Enabled = $false
            $script:numCustomMin.Enabled = $false
        }
        else {
            $autoInfo = if ($script:recAutoStopMinutes -gt 0) { "Idle (Auto-stop: $($script:recAutoStopMinutes) min)" } else { 'Idle (Auto-stop: Manual)' }
            $script:lblRecStatus.Text = $autoInfo
            $script:lblRecStatus.ForeColor = [System.Drawing.Color]::DimGray
            $script:btnRecToggle.Text = "Start Recording ($recKey)"
            $script:btnRecToggle.BackColor = [System.Drawing.Color]::AliceBlue
            $script:cmbAutoStop.Enabled = $true
            $script:numCustomMin.Enabled = ($script:cmbAutoStop.SelectedIndex -eq ($script:cmbAutoStop.Items.Count - 1))
        }
    }
}

function Write-IpcState {
    try {
        $ipcDir = Get-IpcDirPath
        $stateFile = Join-Path $ipcDir 'state.json'
        $tmpFile = "$stateFile.tmp"
        $cfOn = ($null -ne $script:cfProc -and -not $script:cfProc.HasExited)
        $dashOn = ($null -ne $script:dashProc -and -not $script:dashProc.HasExited)

        $rnModelRel = if ($null -ne $script:config.audio.PSObject.Properties['rnnoiseModelPath']) { [string]$script:config.audio.rnnoiseModelPath } else { 'models/bd.rnnn' }
        $rnFull = if ([System.IO.Path]::IsPathRooted($rnModelRel)) { $rnModelRel } else { Join-Path $scriptDir ($rnModelRel.Replace('/', '\')) }
        $rnAvail = Test-Path -LiteralPath $rnFull
        $nrMode = if ($null -ne $script:config.audio.PSObject.Properties['noiseReduction']) { [string]$script:config.audio.noiseReduction } else { 'off' }

        $payload = [ordered]@{
            updatedAt             = (Get-Date).ToUniversalTime().ToString('o')
            streamState           = $script:streamState
            streamDetail          = $script:streamDetail
            desiredRunning        = [bool]$script:desiredRunning
            isRecording           = [bool]$script:isRecording
            recStartTimeUtc       = if ($script:isRecording -and $script:recStartTime -gt [DateTime]::MinValue) { $script:recStartTime.ToUniversalTime().ToString('o') } else { $null }
            recAutoStopMinutes    = [int]$script:recAutoStopMinutes
            recActiveLimitMinutes = [int]$script:recActiveLimitMinutes
            recOutputFile         = [string]$script:recOutputFile
            ambientBoost          = [bool]$script:config.audio.enableAmbientBoost
            noiseReduction        = $nrMode
            opusApplication       = [string]$script:config.audio.opusApplication
            rnnoiseAvailable      = [bool]$rnAvail
            microphoneName        = [string]$script:config.audio.microphoneName
            microphones           = @($script:cachedMicrophones)
            cloudflaredEnabled    = [bool]$script:config.network.cloudflared.enabled
            cloudflaredActive     = [bool]$cfOn
            dashboardActive       = [bool]$dashOn
            publicUrl             = [string]$script:config.network.publicUrl
            streamPath            = [string]$script:config.stream.streamPath
        }

        $json = $payload | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($tmpFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmpFile -Destination $stateFile -Force
        $script:lastIpcWrite = Get-Date
    }
    catch { }
}

function Update-CachedMicrophones {
    try {
        $devs = @(Get-DShowAudioDevices -FfmpegPath ([string]$script:config.paths.ffmpegPath) -BaseDir $scriptDir)
        if ($devs.Count -gt 0) {
            $script:cachedMicrophones = @($devs | ForEach-Object { [string]$_.Name })
        }
    }
    catch { }
}

function Set-StreamState {
    param(
        [ValidateSet('Stopped', 'Starting', 'LIVE', 'Recovering', 'Error')]
        [string]$State,
        [string]$Detail = ''
    )
    $script:streamState = $State
    $script:streamDetail = $Detail
    Update-AllUiState
    Write-IpcState
}

# ==================== PROCESS SUPERVISION ====================
function Stop-ChildProcessSafe {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name
    )
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            [void]$Process.WaitForExit(2000)
            Write-DaemonLog -Level 'INFO' -Message "Stopped $Name (PID=$($Process.Id))."
        }
    }
    catch {
        Write-DaemonLog -Level 'WARN' -Message "Warning while stopping ${Name}: $($_.Exception.Message)"
    }
    finally {
        try { $Process.Dispose() } catch { }
    }
}

function Stop-FfmpegProcess {
    Stop-ChildProcessSafe -Process $script:ffProc -Name 'ffmpeg-stream'
    $script:ffProc = $null
}

function Stop-MtxProcess {
    Stop-ChildProcessSafe -Process $script:mtxProc -Name 'mediamtx'
    $script:mtxProc = $null
}

function Stop-CloudflaredProcess {
    if ($null -eq $script:cfProc) { return }
    try {
        $cfPid = $script:cfProc.Id
        $script:cfProc.StopGracefully(1000)
        Write-DaemonLog -Level 'INFO' -Message "Stopped cloudflared (PID=$cfPid)."
    }
    catch {
        Write-DaemonLog -Level 'WARN' -Message "Warning while stopping cloudflared: $($_.Exception.Message)"
    }
    finally {
        try { $script:cfProc.Dispose() } catch { }
        $script:cfProc = $null
    }
}

function Stop-DashboardProcess {
    if ($null -eq $script:dashProc) { return }
    try {
        $dPid = $script:dashProc.Id
        $script:dashProc.StopGracefully(1000)
        Write-DaemonLog -Level 'INFO' -Message "Stopped Web Dashboard server (PID=$dPid)."
    }
    catch {
        Write-DaemonLog -Level 'WARN' -Message "Warning while stopping dashboard server: $($_.Exception.Message)"
    }
    finally {
        try { $script:dashProc.Dispose() } catch { }
        $script:dashProc = $null
    }
}

function Start-DashboardProcess {
    if (-not [bool]$script:config.dashboard.enabled) { return $false }
    if ($null -ne $script:dashProc -and -not $script:dashProc.HasExited) { return $true }

    $serverJs = Join-Path $scriptDir 'dashboard\server.js'
    if (-not (Test-Path -LiteralPath $serverJs)) {
        Write-DaemonLog -Level 'WARN' -Message "Dashboard server script not found at $serverJs."
        return $false
    }

    $nodeExe = Resolve-ExecutablePath -ConfiguredPath ([string]$script:config.dashboard.nodePath) -BaseDir $scriptDir
    if (-not $nodeExe) {
        Write-DaemonLog -Level 'WARN' -Message 'Node.js not found; Web Dashboard will not start.'
        return $false
    }

    $dashLog = Join-Path (Get-LogDirPath) 'dashboard.log'
    Invoke-LogRotation -LogPath $dashLog -MaxBytes ([long]$script:config.paths.maxLogSizeBytes)

    try {
        $proc = [MicStreamNative.ManagedLogProcess]::Start($nodeExe, (Format-NativeArgument -Value $serverJs), $scriptDir, $dashLog, $false)
        [void]$script:job.AddProcess($proc.Handle)
        $script:dashProc = $proc
        Write-DaemonLog -Level 'INFO' -Message "Started Web Dashboard server (PID=$($proc.Id), port=$($script:config.dashboard.port))."
        return $true
    }
    catch {
        Write-DaemonLog -Level 'ERROR' -Message "Failed to launch Web Dashboard server: $($_.Exception.Message)"
        return $false
    }
}

function Start-CloudflaredProcess {
    if (-not [bool]$script:config.network.cloudflared.enabled) {
        return $false
    }
    if ($null -ne $script:cfProc -and -not $script:cfProc.HasExited) {
        return $true
    }

    $cfExe = Resolve-ExecutablePath -ConfiguredPath ([string]$script:config.network.cloudflared.exePath) -BaseDir $scriptDir
    if (-not $cfExe) {
        $cfExe = Resolve-ExecutablePath -ConfiguredPath 'cloudflared' -BaseDir $scriptDir
    }
    if (-not $cfExe) {
        Write-DaemonLog -Level 'WARN' -Message 'Cloudflare Tunnel is enabled, but cloudflared.exe is not installed. Run 5-Configure-Remote.bat or scripts\Install-Cloudflared.ps1.'
        Show-TrayNotification -Title 'cloudflared Not Installed' -Text 'Run 5-Configure-Remote.bat to download cloudflared and configure your tunnel. Local stream is still LIVE.' -Icon ([System.Windows.Forms.ToolTipIcon]::Warning) -TimeoutMs 5000
        return $false
    }

    $tokenFile = [string]$script:config.network.cloudflared.tokenFile
    if (-not [System.IO.Path]::IsPathRooted($tokenFile)) {
        $tokenFile = Join-Path $scriptDir $tokenFile
    }
    $token = Get-CloudflaredToken -TokenPath $tokenFile
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-DaemonLog -Level 'WARN' -Message "Cloudflare Tunnel is enabled, but $tokenFile is missing or empty. Run 5-Configure-Remote.bat."
        Show-TrayNotification -Title 'Tunnel Token Missing' -Text 'Run 5-Configure-Remote.bat to save your Cloudflare Tunnel token. Local stream is still LIVE.' -Icon ([System.Windows.Forms.ToolTipIcon]::Warning) -TimeoutMs 5000
        return $false
    }

    $cfLog = Join-Path (Get-LogDirPath) 'cloudflared.log'
    Invoke-LogRotation -LogPath $cfLog -MaxBytes ([long]$script:config.paths.maxLogSizeBytes)

    try {
        $cfArgArray = @(Get-CloudflaredArguments -Token $token)
        $cfArgString = Join-NativeArguments -Arguments $cfArgArray
        $proc = [MicStreamNative.ManagedLogProcess]::Start($cfExe, $cfArgString, $scriptDir, $cfLog, $false)
        [void]$script:job.AddProcess($proc.Handle)
        $script:cfProc = $proc
        Write-DaemonLog -Level 'INFO' -Message "Started optional cloudflared tunnel (PID=$($proc.Id))."
        return $true
    }
    catch {
        Write-DaemonLog -Level 'ERROR' -Message "Failed to launch cloudflared: $($_.Exception.Message)"
        return $false
    }
}

function Start-MtxProcess {
    if ($null -ne $script:mtxProc -and -not $script:mtxProc.HasExited) {
        return $true
    }

    $mtxExe = Resolve-ExecutablePath -ConfiguredPath ([string]$script:config.paths.mediamtxExe) -BaseDir $scriptDir
    if (-not $mtxExe) {
        Write-DaemonLog -Level 'ERROR' -Message 'mediamtx.exe not found. Run scripts\Install-MediaMTX.ps1.'
        Show-TrayNotification -Title 'MediaMTX Missing' -Text 'Run scripts\Install-MediaMTX.ps1 to download mediamtx.exe.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return $false
    }

    $mtxCfg = [string]$script:config.paths.mediamtxConfig
    if (-not [System.IO.Path]::IsPathRooted($mtxCfg)) {
        $mtxCfg = Join-Path $scriptDir $mtxCfg
    }

    $readiness = Test-MediaMtxConfigReady -YamlPath $mtxCfg
    if (-not $readiness.Ready) {
        Write-DaemonLog -Level 'ERROR' -Message "MediaMTX config check failed: $($readiness.Reason)"
        Show-TrayNotification -Title 'Configuration Required' -Text $readiness.Reason -Icon ([System.Windows.Forms.ToolTipIcon]::Warning) -TimeoutMs 5000
        return $false
    }

    $mtxLogPath = Join-Path (Get-LogDirPath) 'mediamtx.log'
    Invoke-LogRotation -LogPath $mtxLogPath -MaxBytes ([long]$script:config.paths.maxLogSizeBytes)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $mtxExe
    $psi.Arguments = Format-NativeArgument -Value $mtxCfg
    $psi.WorkingDirectory = $scriptDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    if ([bool]$script:config.network.autoFilterInterfaces) {
        $preferredIfaces = @(Get-PreferredNetworkInterfaces -Adapters @(Get-HostIpv4Adapters) -ExcludePatterns @($script:config.network.excludeInterfacePatterns))
        if ($preferredIfaces.Count -gt 0) {
            $ifaceCsv = ($preferredIfaces -join ',')
            $psi.EnvironmentVariables['MTX_WEBRTCIPSFROMINTERFACESLIST'] = $ifaceCsv
            Write-DaemonLog -Level 'INFO' -Message "Auto-filtered WebRTC ICE interfaces: $ifaceCsv"
        }
    }

    try {
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        [void]$script:job.AddProcess($proc.Handle)
        $script:mtxProc = $proc
        Write-DaemonLog -Level 'INFO' -Message "Started mediamtx.exe (PID=$($proc.Id))."
    }
    catch {
        Write-DaemonLog -Level 'ERROR' -Message "Failed to launch mediamtx.exe: $($_.Exception.Message)"
        return $false
    }

    $rtspHost = [string]$script:config.stream.rtspHost
    $rtspPort = [int]$script:config.stream.rtspPort
    $timeoutMs = [int]$script:config.watchdog.rtspReadyTimeoutMs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($script:mtxProc.HasExited) {
            Write-DaemonLog -Level 'ERROR' -Message "mediamtx.exe exited immediately with code $($script:mtxProc.ExitCode). Check logs\mediamtx.log."
            return $false
        }
        if (Test-TcpPortOpen -HostName $rtspHost -Port $rtspPort -TimeoutMs 150) {
            Write-DaemonLog -Level 'INFO' -Message "MediaMTX RTSP listener ready at ${rtspHost}:$rtspPort ($($sw.ElapsedMilliseconds) ms)."
            return $true
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    Write-DaemonLog -Level 'ERROR' -Message "Timed out waiting for MediaMTX RTSP listener on ${rtspHost}:$rtspPort."
    return $false
}

function Start-FfmpegProcess {
    if ($null -ne $script:ffProc -and -not $script:ffProc.HasExited) {
        return $true
    }

    $ffmpegExe = Resolve-ExecutablePath -ConfiguredPath ([string]$script:config.paths.ffmpegPath) -BaseDir $scriptDir
    if (-not $ffmpegExe) {
        Write-DaemonLog -Level 'ERROR' -Message 'ffmpeg executable not found in PATH or config.'
        Show-TrayNotification -Title 'FFmpeg Missing' -Text 'FFmpeg was not found. Verify PATH or paths.ffmpegPath in config.json.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return $false
    }

    $ffLogPath = Join-Path (Get-LogDirPath) 'ffmpeg.log'
    Invoke-LogRotation -LogPath $ffLogPath -MaxBytes ([long]$script:config.paths.maxLogSizeBytes)

    try {
        $argArray = @(Get-FfmpegArguments -Config $script:config -BaseDir $scriptDir)
        $argString = Join-NativeArguments -Arguments $argArray
        Write-DaemonLog -Level 'INFO' -Message "Starting ffmpeg stream: $argString"

        $proc = Start-Process -FilePath $ffmpegExe `
            -ArgumentList $argString `
            -WorkingDirectory $scriptDir `
            -RedirectStandardError $ffLogPath `
            -WindowStyle Hidden `
            -PassThru
        [void]$script:job.AddProcess($proc.Handle)
        $script:ffProc = $proc
        Write-DaemonLog -Level 'INFO' -Message "Started ffmpeg.exe stream (PID=$($proc.Id))."
    }
    catch {
        Write-DaemonLog -Level 'ERROR' -Message "Failed to launch ffmpeg.exe: $($_.Exception.Message)"
        return $false
    }

    $verifyMs = [int]$script:config.watchdog.startupVerifyMs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $verifyMs) {
        if ($script:ffProc.HasExited) {
            Write-DaemonLog -Level 'ERROR' -Message "ffmpeg.exe exited during startup with code $($script:ffProc.ExitCode). Check logs\ffmpeg.log."
            return $false
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    return $true
}

function Start-Stream {
    if ($script:isTransitioning) { return }
    $script:isTransitioning = $true
    try {
        $script:desiredRunning = $true
        $script:consecutiveFailures = 0
        $script:healthyTicks = 0
        $script:nextRetryAt = [DateTime]::MinValue

        Set-StreamState -State 'Starting'

        if (-not (Start-MtxProcess)) {
            $script:desiredRunning = $false
            Stop-FfmpegProcess
            Stop-MtxProcess
            Set-StreamState -State 'Error' -Detail 'MediaMTX failed'
            return
        }

        if (-not (Start-FfmpegProcess)) {
            $script:desiredRunning = $false
            Stop-FfmpegProcess
            Stop-MtxProcess
            Set-StreamState -State 'Error' -Detail 'FFmpeg failed'
            Show-TrayNotification -Title 'Audio Capture Failed' -Text 'FFmpeg could not start. Check Microphone selection or logs\ffmpeg.log.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
            return
        }

        if ([bool]$script:config.network.cloudflared.enabled) {
            [void](Start-CloudflaredProcess)
        }

        Set-StreamState -State 'LIVE'
        Write-DaemonLog -Level 'INFO' -Message 'Audio stream is LIVE.'
    }
    finally {
        $script:isTransitioning = $false
    }
}

function Stop-Stream {
    if ($script:isTransitioning) { return }
    $script:isTransitioning = $true
    try {
        $script:desiredRunning = $false
        $script:consecutiveFailures = 0
        $script:healthyTicks = 0
        $script:nextRetryAt = [DateTime]::MinValue

        Stop-FfmpegProcess
        Stop-MtxProcess
        Set-StreamState -State 'Stopped'
        Write-DaemonLog -Level 'INFO' -Message 'Audio stream stopped (dashboard remains available).'
    }
    finally {
        $script:isTransitioning = $false
    }
}

function Restart-FfmpegOnly {
    if (-not $script:desiredRunning -or $script:isTransitioning) { return }
    $script:isTransitioning = $true
    try {
        Set-StreamState -State 'Recovering' -Detail 'Applying audio settings...'
        Stop-FfmpegProcess
        if (Start-FfmpegProcess) {
            Set-StreamState -State 'LIVE'
        }
        else {
            Set-StreamState -State 'Error' -Detail 'FFmpeg restart failed'
            Show-TrayNotification -Title 'Audio Restart Failed' -Text 'Check logs\ffmpeg.log for details.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        }
    }
    finally {
        $script:isTransitioning = $false
    }
}

function Toggle-Stream {
    if ($script:desiredRunning) { Stop-Stream } else { Start-Stream }
}

function Set-CloudflaredEnabled {
    param([bool]$Enabled)
    $script:config.network.cloudflared.enabled = $Enabled
    Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
    Write-DaemonLog -Level 'INFO' -Message "Optional Cloudflare Tunnel set to $Enabled."
    if ($Enabled) {
        [void](Start-CloudflaredProcess)
    }
    else {
        Stop-CloudflaredProcess
    }
    Update-AllUiState
    Write-IpcState
}

# ==================== INDEPENDENT AUDIO RECORDING ====================
function Start-AudioRecording {
    param([int]$OverrideAutoStopMinutes = -1)

    if ($script:isRecording) { return }

    $ffmpegExe = Resolve-ExecutablePath -ConfiguredPath ([string]$script:config.paths.ffmpegPath) -BaseDir $scriptDir
    if (-not $ffmpegExe) {
        Write-DaemonLog -Level 'ERROR' -Message 'Cannot start recording: ffmpeg not found.'
        Show-TrayNotification -Title 'FFmpeg Missing' -Text 'FFmpeg was not found. Cannot start recording.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }

    $limitMinutes = if ($OverrideAutoStopMinutes -ge 0) { $OverrideAutoStopMinutes } else { $script:recAutoStopMinutes }
    $recDir = Get-RecordingsDirPath
    $outFile = New-RecordingFilePath -RecordingsDir $recDir -Format ([string]$script:config.recording.format)
    $recLog = Join-Path (Get-LogDirPath) 'recorder.log'
    Invoke-LogRotation -LogPath $recLog -MaxBytes ([long]$script:config.paths.maxLogSizeBytes)

    try {
        $argArray = @(Get-RecordingArguments -Config $script:config -OutputFilePath $outFile -AutoStopMinutes $limitMinutes -BaseDir $scriptDir)
        $argString = Join-NativeArguments -Arguments $argArray
        Write-DaemonLog -Level 'INFO' -Message "Starting recording -> $outFile (autoStopMin=$limitMinutes)"

        $proc = [MicStreamNative.ManagedLogProcess]::Start($ffmpegExe, $argString, $scriptDir, $recLog, $true)
        [void]$script:job.AddProcess($proc.Handle)

        # Quick verify it didn't fail instantly on device open
        Start-Sleep -Milliseconds 350
        if ($proc.HasExited) {
            $code = $proc.ExitCode
            $proc.Dispose()
            Write-DaemonLog -Level 'ERROR' -Message "Recording FFmpeg exited immediately (code=$code). Check logs\recorder.log."
            Show-TrayNotification -Title 'Recording Failed' -Text 'Could not start recording. Check logs\recorder.log.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
            return
        }

        $script:recProc = $proc
        $script:isRecording = $true
        $script:recStartTime = Get-Date
        $script:recActiveLimitMinutes = $limitMinutes
        $script:recOutputFile = $outFile

        $limitMsg = if ($limitMinutes -gt 0) { "Auto-stop in $limitMinutes min." } else { 'Manual stop.' }
        Show-TrayNotification -Title 'Recording Started' -Text "$(Split-Path -Leaf $outFile)`n$limitMsg" -Icon ([System.Windows.Forms.ToolTipIcon]::Info) -TimeoutMs 2500
        Update-AllUiState
        Write-IpcState
    }
    catch {
        Write-DaemonLog -Level 'ERROR' -Message "Failed to start recording: $($_.Exception.Message)"
        Show-TrayNotification -Title 'Recording Error' -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-AudioRecording {
    param([string]$Reason = 'Manual')

    if (-not $script:isRecording -and $null -eq $script:recProc) { return }

    $savedFile = $script:recOutputFile
    if ($null -ne $script:recProc) {
        try {
            $script:recProc.StopGracefully(2500)
        }
        catch {
            Write-DaemonLog -Level 'WARN' -Message "Warning stopping recorder: $($_.Exception.Message)"
        }
        finally {
            try { $script:recProc.Dispose() } catch { }
            $script:recProc = $null
        }
    }

    $script:isRecording = $false
    $script:recActiveLimitMinutes = 0
    $script:recOutputFile = ''

    $leaf = if ($savedFile) { Split-Path -Leaf $savedFile } else { 'recording' }
    $sizeInfo = ''
    if ($savedFile -and (Test-Path -LiteralPath $savedFile)) {
        $kb = [Math]::Round(((Get-Item -LiteralPath $savedFile).Length / 1KB), 1)
        $sizeInfo = " ($kb KB)"
    }
    Write-DaemonLog -Level 'INFO' -Message "Recording stopped ($Reason): $savedFile$sizeInfo"
    if (-not $script:isShuttingDown) {
        Show-TrayNotification -Title "Recording Saved ($Reason)" -Text "$leaf$sizeInfo" -Icon ([System.Windows.Forms.ToolTipIcon]::Info) -TimeoutMs 3500
    }
    Update-AllUiState
    Write-IpcState
}

function Toggle-AudioRecording {
    if ($script:isRecording) {
        Stop-AudioRecording -Reason 'Manual'
    }
    else {
        Start-AudioRecording
    }
}

function Set-DefaultAutoStopMinutes {
    param([int]$Minutes)
    if ($Minutes -lt 0) { $Minutes = 0 }
    if ($Minutes -gt 1440) { $Minutes = 1440 }
    $script:recAutoStopMinutes = $Minutes
    $script:config.recording.defaultAutoStopMinutes = $Minutes
    Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
    Write-DaemonLog -Level 'INFO' -Message "Recording auto-stop set to $Minutes minute(s)."
    Sync-PanelAutoStopSelection
    Update-AllUiState
    Write-IpcState
}

function Invoke-IpcCommands {
    $ipcDir = Get-IpcDirPath
    $cmdFiles = @(Get-ChildItem -LiteralPath $ipcDir -Filter 'cmd_*.json' -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc)
    if ($cmdFiles.Count -eq 0) { return }

    foreach ($file in $cmdFiles) {
        $cmdObj = $null
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $cmdObj = $raw | ConvertFrom-Json
        }
        catch {
            continue
        }

        $resId = [string]$cmdObj.id
        $action = [string]$cmdObj.action
        $payload = $cmdObj.payload
        $ok = $true
        $errMsg = ''

        try {
            switch ($action) {
                'start_stream' {
                    Start-Stream
                    if ($script:streamState -ne 'LIVE') {
                        $ok = $false
                        $errMsg = "Stream failed to start ($($script:streamDetail)). Check logs."
                    }
                }
                'stop_stream' {
                    Stop-Stream
                }
                'start_record' {
                    $mins = $script:recAutoStopMinutes
                    if ($null -ne $payload -and $null -ne $payload.PSObject.Properties['autoStopMinutes']) {
                        $mins = [int]$payload.autoStopMinutes
                        Set-DefaultAutoStopMinutes -Minutes $mins
                    }
                    Start-AudioRecording -OverrideAutoStopMinutes $mins
                    if (-not $script:isRecording) {
                        $ok = $false
                        $errMsg = 'Recording failed to start. Check logs\recorder.log.'
                    }
                }
                'stop_record' {
                    Stop-AudioRecording -Reason 'Remote'
                }
                'set_autostop' {
                    if ($null -ne $payload -and $null -ne $payload.PSObject.Properties['minutes']) {
                        Set-DefaultAutoStopMinutes -Minutes ([int]$payload.minutes)
                    }
                }
                'set_boost' {
                    if ($null -ne $payload -and $null -ne $payload.PSObject.Properties['enabled']) {
                        $en = [bool]$payload.enabled
                        $script:config.audio.enableAmbientBoost = $en
                        $script:boostItem.Checked = $en
                        Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
                        Write-DaemonLog -Level 'INFO' -Message "Remote Ambient Boost set to $en."
                        if ($script:desiredRunning) { Restart-FfmpegOnly }
                    }
                }
                'set_noise_reduction' {
                    if ($null -ne $payload -and $null -ne $payload.PSObject.Properties['mode']) {
                        $mode = ([string]$payload.mode).Trim().ToLowerInvariant()
                        if ($mode -in @('off', 'light', 'clean', 'voice_ai')) {
                            $script:config.audio.noiseReduction = $mode
                            Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
                            Write-DaemonLog -Level 'INFO' -Message "Remote Noise Reduction set to $mode."
                            if ($script:desiredRunning) { Restart-FfmpegOnly }
                        }
                        else {
                            $ok = $false
                            $errMsg = "Invalid noiseReduction mode: $mode"
                        }
                    }
                }
                'set_opus_mode' {
                    if ($null -ne $payload -and $null -ne $payload.PSObject.Properties['application']) {
                        $appMode = ([string]$payload.application).Trim().ToLowerInvariant()
                        if ($appMode -in @('lowdelay', 'voip')) {
                            $script:config.audio.opusApplication = $appMode
                            $script:voipItem.Checked = ($appMode -eq 'voip')
                            Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
                            Write-DaemonLog -Level 'INFO' -Message "Remote Opus application set to $appMode."
                            if ($script:desiredRunning) { Restart-FfmpegOnly }
                        }
                        else {
                            $ok = $false
                            $errMsg = "Invalid opusApplication mode: $appMode"
                        }
                    }
                }
                'set_microphone' {
                    if ($null -ne $payload -and $null -ne $payload.PSObject.Properties['microphoneName']) {
                        $mic = [string]$payload.microphoneName
                        if (-not [string]::IsNullOrWhiteSpace($mic)) {
                            $script:config.audio.microphoneName = $mic
                            Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
                            Write-DaemonLog -Level 'INFO' -Message "Remote microphone switch to: $mic"
                            if ($script:desiredRunning) { Restart-FfmpegOnly }
                        }
                    }
                }
                default {
                    $ok = $false
                    $errMsg = "Unknown IPC action: $action"
                }
            }
        }
        catch {
            $ok = $false
            $errMsg = $_.Exception.Message
        }

        Update-AllUiState
        Write-IpcState

        if (-not [string]::IsNullOrWhiteSpace($resId)) {
            $resPath = Join-Path $ipcDir "res_${resId}.json"
            $resTmp = "$resPath.tmp"
            $resObj = [ordered]@{ ok = $ok; error = $errMsg }
            try {
                [System.IO.File]::WriteAllText($resTmp, ($resObj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $resTmp -Destination $resPath -Force
            }
            catch { }
        }
    }
}

function Copy-BestStreamUrl {
    $endpoints = @(Get-StreamEndpoints -Config $script:config)
    if ($endpoints.Count -eq 0) { return }

    $chosen = $null
    if ([bool]$script:config.network.cloudflared.enabled) {
        $chosen = $endpoints | Where-Object { $_.Transport -eq 'Tunnel' } | Select-Object -First 1
    }
    if ($null -eq $chosen) {
        $chosen = $endpoints | Where-Object { $_.Transport -match 'Tailscale|LAN' } | Select-Object -First 1
    }
    if ($null -eq $chosen) {
        $chosen = $endpoints[0]
    }
    try {
        [System.Windows.Forms.Clipboard]::SetText([string]$chosen.Url)
        Show-TrayNotification -Title 'Stream URL Copied' -Text ([string]$chosen.Url) -TimeoutMs 2500
    }
    catch { }
}

# ==================== CONTROL PANEL WINDOW ====================
$script:panelForm = $null
$script:suppressPanelEvents = $false
$script:autoStopPresets = @(
    @{ Label = 'Manual (No Auto-Stop)'; Minutes = 0 },
    @{ Label = '5 minutes';             Minutes = 5 },
    @{ Label = '10 minutes';            Minutes = 10 },
    @{ Label = '15 minutes';            Minutes = 15 },
    @{ Label = '30 minutes';            Minutes = 30 },
    @{ Label = '60 minutes (1 hour)';   Minutes = 60 },
    @{ Label = '120 minutes (2 hours)'; Minutes = 120 },
    @{ Label = 'Custom (minutes)...';   Minutes = -1 }
)

function Sync-PanelAutoStopSelection {
    if ($null -eq $script:panelForm -or $script:panelForm.IsDisposed) { return }
    $script:suppressPanelEvents = $true
    try {
        $matchedIdx = -1
        for ($i = 0; $i -lt ($script:autoStopPresets.Count - 1); $i++) {
            if ($script:autoStopPresets[$i].Minutes -eq $script:recAutoStopMinutes) {
                $matchedIdx = $i
                break
            }
        }
        if ($matchedIdx -ge 0) {
            $script:cmbAutoStop.SelectedIndex = $matchedIdx
            $script:numCustomMin.Enabled = $false
        }
        else {
            $script:cmbAutoStop.SelectedIndex = $script:autoStopPresets.Count - 1
            $val = [Math]::Max(1, [Math]::Min(1440, $script:recAutoStopMinutes))
            $script:numCustomMin.Value = $val
            $script:numCustomMin.Enabled = (-not $script:isRecording)
        }
    }
    finally {
        $script:suppressPanelEvents = $false
    }
}

function Initialize-ControlPanel {
    if ($null -ne $script:panelForm -and -not $script:panelForm.IsDisposed) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'MicStream Control Panel'
    $form.Size = New-Object System.Drawing.Size(420, 415)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $form.Icon = $script:iconRunning

    # --- Group 1: Live Stream ---
    $grpStream = New-Object System.Windows.Forms.GroupBox
    $grpStream.Text = 'Live WebRTC Stream'
    $grpStream.Location = New-Object System.Drawing.Point(14, 12)
    $grpStream.Size = New-Object System.Drawing.Size(376, 148)

    $script:lblStreamStatus = New-Object System.Windows.Forms.Label
    $script:lblStreamStatus.Location = New-Object System.Drawing.Point(14, 24)
    $script:lblStreamStatus.Size = New-Object System.Drawing.Size(346, 22)
    $script:lblStreamStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $script:btnStreamToggle = New-Object System.Windows.Forms.Button
    $script:btnStreamToggle.Location = New-Object System.Drawing.Point(14, 52)
    $script:btnStreamToggle.Size = New-Object System.Drawing.Size(222, 34)
    $script:btnStreamToggle.Add_Click({ Toggle-Stream })

    $btnCopyUrl = New-Object System.Windows.Forms.Button
    $btnCopyUrl.Text = 'Copy Stream URL'
    $btnCopyUrl.Location = New-Object System.Drawing.Point(244, 52)
    $btnCopyUrl.Size = New-Object System.Drawing.Size(118, 34)
    $btnCopyUrl.Add_Click({ Copy-BestStreamUrl })

    $script:chkCloudflared = New-Object System.Windows.Forms.CheckBox
    $script:chkCloudflared.Text = 'Enable Cloudflare Tunnel (Remote Dashboard Access)'
    $script:chkCloudflared.Location = New-Object System.Drawing.Point(16, 94)
    $script:chkCloudflared.Size = New-Object System.Drawing.Size(346, 22)
    $script:chkCloudflared.Add_CheckedChanged({
        if (-not $script:suppressPanelEvents) {
            Set-CloudflaredEnabled -Enabled ([bool]$script:chkCloudflared.Checked)
        }
    })

    $script:lblTunnelStatus = New-Object System.Windows.Forms.Label
    $script:lblTunnelStatus.Location = New-Object System.Drawing.Point(16, 118)
    $script:lblTunnelStatus.Size = New-Object System.Drawing.Size(346, 20)
    $script:lblTunnelStatus.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)

    $grpStream.Controls.AddRange(@($script:lblStreamStatus, $script:btnStreamToggle, $btnCopyUrl, $script:chkCloudflared, $script:lblTunnelStatus))

    # --- Group 2: Audio Recording ---
    $grpRec = New-Object System.Windows.Forms.GroupBox
    $grpRec.Text = 'Audio Recording (Works Anytime - Stream ON or OFF)'
    $grpRec.Location = New-Object System.Drawing.Point(14, 170)
    $grpRec.Size = New-Object System.Drawing.Size(376, 152)

    $script:lblRecStatus = New-Object System.Windows.Forms.Label
    $script:lblRecStatus.Location = New-Object System.Drawing.Point(14, 24)
    $script:lblRecStatus.Size = New-Object System.Drawing.Size(348, 22)
    $script:lblRecStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    $lblAuto = New-Object System.Windows.Forms.Label
    $lblAuto.Text = 'Auto-Stop:'
    $lblAuto.Location = New-Object System.Drawing.Point(14, 56)
    $lblAuto.Size = New-Object System.Drawing.Size(72, 22)

    $script:cmbAutoStop = New-Object System.Windows.Forms.ComboBox
    $script:cmbAutoStop.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:cmbAutoStop.Location = New-Object System.Drawing.Point(88, 53)
    $script:cmbAutoStop.Size = New-Object System.Drawing.Size(172, 24)
    foreach ($p in $script:autoStopPresets) {
        [void]$script:cmbAutoStop.Items.Add($p.Label)
    }

    $script:numCustomMin = New-Object System.Windows.Forms.NumericUpDown
    $script:numCustomMin.Location = New-Object System.Drawing.Point(268, 53)
    $script:numCustomMin.Size = New-Object System.Drawing.Size(64, 24)
    $script:numCustomMin.Minimum = 1
    $script:numCustomMin.Maximum = 1440
    $script:numCustomMin.Value = 20
    $script:numCustomMin.Enabled = $false

    $lblMinUnit = New-Object System.Windows.Forms.Label
    $lblMinUnit.Text = 'min'
    $lblMinUnit.Location = New-Object System.Drawing.Point(335, 56)
    $lblMinUnit.Size = New-Object System.Drawing.Size(30, 22)

    $script:cmbAutoStop.Add_SelectedIndexChanged({
        if ($script:suppressPanelEvents) { return }
        $idx = $script:cmbAutoStop.SelectedIndex
        if ($idx -lt 0) { return }
        $preset = $script:autoStopPresets[$idx]
        if ($preset.Minutes -ge 0) {
            $script:numCustomMin.Enabled = $false
            Set-DefaultAutoStopMinutes -Minutes $preset.Minutes
        }
        else {
            $script:numCustomMin.Enabled = (-not $script:isRecording)
            Set-DefaultAutoStopMinutes -Minutes ([int]$script:numCustomMin.Value)
        }
    })

    $script:numCustomMin.Add_ValueChanged({
        if ($script:suppressPanelEvents) { return }
        if ($script:cmbAutoStop.SelectedIndex -eq ($script:autoStopPresets.Count - 1)) {
            Set-DefaultAutoStopMinutes -Minutes ([int]$script:numCustomMin.Value)
        }
    })

    $script:btnRecToggle = New-Object System.Windows.Forms.Button
    $script:btnRecToggle.Location = New-Object System.Drawing.Point(14, 92)
    $script:btnRecToggle.Size = New-Object System.Drawing.Size(222, 38)
    $script:btnRecToggle.Add_Click({ Toggle-AudioRecording })

    $btnOpenRecs = New-Object System.Windows.Forms.Button
    $btnOpenRecs.Text = 'Open Recordings'
    $btnOpenRecs.Location = New-Object System.Drawing.Point(244, 92)
    $btnOpenRecs.Size = New-Object System.Drawing.Size(118, 38)
    $btnOpenRecs.Add_Click({
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-NativeArgument -Value (Get-RecordingsDirPath))
    })

    $grpRec.Controls.AddRange(@($script:lblRecStatus, $lblAuto, $script:cmbAutoStop, $script:numCustomMin, $lblMinUnit, $script:btnRecToggle, $btnOpenRecs))

    # --- Bottom Bar ---
    $btnWebUi = New-Object System.Windows.Forms.Button
    $btnWebUi.Text = 'Web UI'
    $btnWebUi.Location = New-Object System.Drawing.Point(14, 334)
    $btnWebUi.Size = New-Object System.Drawing.Size(80, 30)
    $btnWebUi.Add_Click({
        $dashPort = [int]$script:config.dashboard.port
        Start-Process "http://127.0.0.1:$dashPort"
    })

    $btnLogs = New-Object System.Windows.Forms.Button
    $btnLogs.Text = 'Logs'
    $btnLogs.Location = New-Object System.Drawing.Point(100, 334)
    $btnLogs.Size = New-Object System.Drawing.Size(64, 30)
    $btnLogs.Add_Click({
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-NativeArgument -Value (Get-LogDirPath))
    })

    $btnHide = New-Object System.Windows.Forms.Button
    $btnHide.Text = 'Hide to Tray'
    $btnHide.Location = New-Object System.Drawing.Point(170, 334)
    $btnHide.Size = New-Object System.Drawing.Size(96, 30)
    $btnHide.Add_Click({ $script:panelForm.Hide() })

    $btnExitAll = New-Object System.Windows.Forms.Button
    $btnExitAll.Text = 'Exit Completely'
    $btnExitAll.Location = New-Object System.Drawing.Point(272, 334)
    $btnExitAll.Size = New-Object System.Drawing.Size(118, 30)
    $btnExitAll.BackColor = [System.Drawing.Color]::MistyRose
    $btnExitAll.Add_Click({ Invoke-DaemonShutdown })

    $form.Controls.AddRange(@($grpStream, $grpRec, $btnWebUi, $btnLogs, $btnHide, $btnExitAll))

    $form.Add_FormClosing({
        param($sender, $e)
        if (-not $script:isShuttingDown -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $script:panelForm.Hide()
        }
    })

    $script:panelForm = $form
    Sync-PanelAutoStopSelection
    Update-AllUiState
}

function Show-ControlPanel {
    Initialize-ControlPanel
    Sync-PanelAutoStopSelection
    Update-AllUiState
    if (-not $script:panelForm.Visible) {
        $script:panelForm.Show()
    }
    if ($script:panelForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:panelForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    # Explicitly override STARTUPINFO SW_HIDE inherited from wscript.exe / -WindowStyle Hidden
    [MicStreamNative.WindowHelper]::ForceShow($script:panelForm.Handle)
    $script:panelForm.TopMost = $true
    $script:panelForm.Activate()
    $script:panelForm.BringToFront()
    $script:panelForm.TopMost = $false
}

# ==================== CONTEXT MENU ====================
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip

$script:statusItem = $script:menu.Items.Add('Stream: Stopped')
$script:statusItem.Enabled = $false

$script:openPanelItem = $script:menu.Items.Add('Open Control Panel...')
$script:openPanelItem.Font = New-Object System.Drawing.Font($script:openPanelItem.Font, [System.Drawing.FontStyle]::Bold)

$script:openWebUiItem = $script:menu.Items.Add('Open Web Dashboard (Browser)')

[void]$script:menu.Items.Add('-')

$streamKeyText = [string]$script:config.hotkey.label
$recKeyText    = [string]$script:config.recording.hotkey.label

$script:startItem = $script:menu.Items.Add("Start Stream ($streamKeyText)")
$script:stopItem  = $script:menu.Items.Add("Stop Stream ($streamKeyText)")
$script:stopItem.Enabled = $false

$script:cfToggleItem = New-Object System.Windows.Forms.ToolStripMenuItem('Cloudflare Tunnel (Optional)')
$script:cfToggleItem.CheckOnClick = $true
$script:cfToggleItem.Checked = [bool]$script:config.network.cloudflared.enabled
[void]$script:menu.Items.Add($script:cfToggleItem)

[void]$script:menu.Items.Add('-')

$script:recToggleItem = $script:menu.Items.Add("Start Recording ($recKeyText)")
$script:autoStopMenu  = New-Object System.Windows.Forms.ToolStripMenuItem('Recording Auto-Stop')
[void]$script:menu.Items.Add($script:autoStopMenu)
$script:openRecsItem  = $script:menu.Items.Add('Open Recordings Folder')

[void]$script:menu.Items.Add('-')

$script:boostItem = New-Object System.Windows.Forms.ToolStripMenuItem('Ambient Boost (Low-Latency Gain)')
$script:boostItem.CheckOnClick = $true
$script:boostItem.Checked = [bool]$script:config.audio.enableAmbientBoost
[void]$script:menu.Items.Add($script:boostItem)

$script:noiseMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Noise Reduction (Optional)')
[void]$script:menu.Items.Add($script:noiseMenu)

$script:voipItem = New-Object System.Windows.Forms.ToolStripMenuItem('Voice-Tuned Opus (VoIP Mode)')
$script:voipItem.CheckOnClick = $true
$script:voipItem.Checked = ([string]$script:config.audio.opusApplication -eq 'voip')
[void]$script:menu.Items.Add($script:voipItem)

$script:micMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Microphone')
[void]$script:menu.Items.Add($script:micMenu)

$script:urlMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Copy Stream URL')
[void]$script:menu.Items.Add($script:urlMenu)

[void]$script:menu.Items.Add('-')

$script:logsItem   = $script:menu.Items.Add('Open Logs Folder')
$script:reloadItem = $script:menu.Items.Add('Reload Config')

[void]$script:menu.Items.Add('-')

$script:exitItem = $script:menu.Items.Add('Exit Completely')

function Update-AutoStopSubmenu {
    $script:autoStopMenu.DropDownItems.Clear()
    $options = @(
        @{ Label = 'Manual (No Auto-Stop)'; Minutes = 0 },
        @{ Label = '5 minutes';             Minutes = 5 },
        @{ Label = '10 minutes';            Minutes = 10 },
        @{ Label = '15 minutes';            Minutes = 15 },
        @{ Label = '30 minutes';            Minutes = 30 },
        @{ Label = '60 minutes (1 hour)';   Minutes = 60 },
        @{ Label = '120 minutes (2 hours)'; Minutes = 120 }
    )
    foreach ($opt in $options) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($opt.Label)
        $item.Checked = ($script:recAutoStopMinutes -eq $opt.Minutes)
        $item.Tag = [int]$opt.Minutes
        $item.Add_Click({
            param($sender, $e)
            Set-DefaultAutoStopMinutes -Minutes ([int]$sender.Tag)
        })
        [void]$script:autoStopMenu.DropDownItems.Add($item)
    }
    [void]$script:autoStopMenu.DropDownItems.Add('-')
    $customItem = New-Object System.Windows.Forms.ToolStripMenuItem('Custom Duration (Open Control Panel)...')
    $customItem.Add_Click({ Show-ControlPanel })
    [void]$script:autoStopMenu.DropDownItems.Add($customItem)
}

function Update-MicrophoneSubmenu {
    $script:micMenu.DropDownItems.Clear()
    $devices = @(Get-DShowAudioDevices -FfmpegPath ([string]$script:config.paths.ffmpegPath) -BaseDir $scriptDir)
    $currentMic = [string]$script:config.audio.microphoneName

    if ($devices.Count -eq 0) {
        $empty = $script:micMenu.DropDownItems.Add('(No DirectShow microphones detected)')
        $empty.Enabled = $false
        return
    }

    foreach ($dev in $devices) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem([string]$dev.Name)
        $item.Checked = ($dev.Name -eq $currentMic)
        $item.Tag = [string]$dev.Name
        $item.Add_Click({
            param($sender, $e)
            $selectedMic = [string]$sender.Tag
            if ($selectedMic -ne $script:config.audio.microphoneName) {
                $script:config.audio.microphoneName = $selectedMic
                Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
                Write-DaemonLog -Level 'INFO' -Message "Switched microphone to: $selectedMic"
                Write-IpcState
                if ($script:desiredRunning) {
                    Restart-FfmpegOnly
                }
            }
        })
        [void]$script:micMenu.DropDownItems.Add($item)
    }
}

function Update-EndpointsSubmenu {
    $script:urlMenu.DropDownItems.Clear()
    $endpoints = @(Get-StreamEndpoints -Config $script:config)
    foreach ($ep in $endpoints) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem([string]$ep.Label)
        $item.Tag = [string]$ep.Url
        $item.Add_Click({
            param($sender, $e)
            $url = [string]$sender.Tag
            try {
                [System.Windows.Forms.Clipboard]::SetText($url)
                Show-TrayNotification -Title 'Stream URL Copied' -Text $url -TimeoutMs 2500
            }
            catch {
                Write-DaemonLog -Level 'WARN' -Message "Clipboard copy failed: $($_.Exception.Message)"
            }
        })
        [void]$script:urlMenu.DropDownItems.Add($item)
    }
}

function Update-NoiseReductionSubmenu {
    $script:noiseMenu.DropDownItems.Clear()
    $curMode = if ($null -ne $script:config.audio.PSObject.Properties['noiseReduction']) { ([string]$script:config.audio.noiseReduction).ToLowerInvariant() } else { 'off' }
    $presets = @(
        @{ Label = 'Off (Original)';                  Mode = 'off' },
        @{ Label = 'Light (Bandpass + Anti-Hiss)';    Mode = 'light' },
        @{ Label = 'Clean (FFT Adaptive Denoise)';    Mode = 'clean' },
        @{ Label = 'Voice AI (RNNoise Neural)';       Mode = 'voice_ai' }
    )
    foreach ($p in $presets) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($p.Label)
        $item.Checked = ($curMode -eq $p.Mode)
        $item.Tag = $p.Mode
        $item.Add_Click({
            param($sender, $e)
            $sel = [string]$sender.Tag
            if ($sel -ne [string]$script:config.audio.noiseReduction) {
                $script:config.audio.noiseReduction = $sel
                Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
                Write-DaemonLog -Level 'INFO' -Message "Noise Reduction set to: $sel"
                Write-IpcState
                if ($script:desiredRunning) { Restart-FfmpegOnly }
            }
        })
        [void]$script:noiseMenu.DropDownItems.Add($item)
    }
}

$script:menu.Add_Opening({
    try {
        Update-AutoStopSubmenu
        Update-NoiseReductionSubmenu
        Update-MicrophoneSubmenu
        Update-EndpointsSubmenu
        Update-AllUiState
    }
    catch {
        Write-DaemonLog -Level 'WARN' -Message "Menu refresh warning: $($_.Exception.Message)"
    }
})

$script:openPanelItem.Add_Click({ Show-ControlPanel })
$script:openWebUiItem.Add_Click({
    $dashPort = [int]$script:config.dashboard.port
    Start-Process "http://127.0.0.1:$dashPort"
})
$script:startItem.Add_Click({ Start-Stream })
$script:stopItem.Add_Click({ Stop-Stream })
$script:cfToggleItem.Add_Click({ Set-CloudflaredEnabled -Enabled ([bool]$script:cfToggleItem.Checked) })
$script:recToggleItem.Add_Click({ Toggle-AudioRecording })
$script:openRecsItem.Add_Click({
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-NativeArgument -Value (Get-RecordingsDirPath))
})

$script:boostItem.Add_Click({
    $script:config.audio.enableAmbientBoost = [bool]$script:boostItem.Checked
    Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
    Write-DaemonLog -Level 'INFO' -Message "Ambient Boost set to $($script:config.audio.enableAmbientBoost)."
    Write-IpcState
    if ($script:desiredRunning) {
        Restart-FfmpegOnly
    }
})

$script:voipItem.Add_Click({
    $script:config.audio.opusApplication = if ([bool]$script:voipItem.Checked) { 'voip' } else { 'lowdelay' }
    Save-MicStreamConfig -Config $script:config -ConfigPath $script:configPath
    Write-DaemonLog -Level 'INFO' -Message "Opus application set to $($script:config.audio.opusApplication)."
    Write-IpcState
    if ($script:desiredRunning) {
        Restart-FfmpegOnly
    }
})

$script:logsItem.Add_Click({
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-NativeArgument -Value (Get-LogDirPath))
})

$script:reloadItem.Add_Click({
    $wasRunning = $script:desiredRunning
    $script:config = Get-MicStreamConfig -ConfigPath $script:configPath -FallbackTemplatePath $script:templateConfigPath
    $script:boostItem.Checked = [bool]$script:config.audio.enableAmbientBoost
    $script:recAutoStopMinutes = [int]$script:config.recording.defaultAutoStopMinutes
    Sync-PanelAutoStopSelection
    Update-AllUiState
    Write-DaemonLog -Level 'INFO' -Message 'Reloaded config.json.'
    if ($wasRunning) {
        Stop-Stream
        Start-Stream
    }
    else {
        Show-TrayNotification -Title 'Config Reloaded' -Text 'Updated settings from config.json.' -TimeoutMs 2000
    }
})

# Left-clicking the tray icon opens the Control Panel window
$script:trayIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-ControlPanel
    }
})

$script:trayIcon.ContextMenuStrip = $script:menu
Set-StreamState -State 'Stopped'

# ==================== 250ms IPC, RECORDING & PANEL WAKEUP TIMER ====================
$script:uiTickTimer = New-Object System.Windows.Forms.Timer
$script:uiTickTimer.Interval = 250
$script:uiTickTimer.Add_Tick({
    if ($script:isShuttingDown) { return }

    # Check if another launch requested showing the Control Panel
    try {
        if ($script:showPanelEvent.WaitOne(0)) {
            Show-ControlPanel
        }
    }
    catch { }

    # Process any queued Web Dashboard remote control commands
    Invoke-IpcCommands

    # Keep IPC state fresh every 5 seconds
    if (((Get-Date) - $script:lastIpcWrite).TotalSeconds -ge 5) {
        Write-IpcState
    }

    # Monitor active recording process & auto-stop countdown
    if ($script:isRecording) {
        $elapsed = (Get-Date) - $script:recStartTime
        if ($null -eq $script:recProc -or $script:recProc.HasExited) {
            $reason = if ($script:recActiveLimitMinutes -gt 0 -and $elapsed.TotalSeconds -ge (($script:recActiveLimitMinutes * 60) - 3)) {
                "Auto-Stopped after $($script:recActiveLimitMinutes)m"
            }
            else {
                'Finished'
            }
            Stop-AudioRecording -Reason $reason
        }
        elseif ($script:recActiveLimitMinutes -gt 0 -and $elapsed.TotalMinutes -ge ($script:recActiveLimitMinutes + 0.05)) {
            Stop-AudioRecording -Reason "Auto-Stopped after $($script:recActiveLimitMinutes)m"
        }
        else {
            Update-AllUiState
        }
    }
})
$script:uiTickTimer.Start()

# ==================== STREAM, DASHBOARD & TUNNEL WATCHDOG ====================
$script:watchdog = New-Object System.Windows.Forms.Timer
$script:watchdog.Interval = [int]$script:config.watchdog.intervalMs
$script:watchdog.Add_Tick({
    if ($script:isShuttingDown) { return }

    # Always keep Web Dashboard alive if enabled
    if ([bool]$script:config.dashboard.enabled -and ($null -eq $script:dashProc -or $script:dashProc.HasExited)) {
        Write-DaemonLog -Level 'WARN' -Message 'Web Dashboard server exited unexpectedly; restarting.'
        Stop-DashboardProcess
        [void](Start-DashboardProcess)
        Write-IpcState
    }

    # Always keep optional Cloudflare Tunnel alive when enabled (so phone can control stream remotely anytime)
    if ([bool]$script:config.network.cloudflared.enabled -and ($null -ne $script:cfProc) -and $script:cfProc.HasExited) {
        Write-DaemonLog -Level 'WARN' -Message 'Optional cloudflared exited unexpectedly; attempting restart.'
        Stop-CloudflaredProcess
        [void](Start-CloudflaredProcess)
        Update-AllUiState
        Write-IpcState
    }

    if (-not $script:desiredRunning -or $script:isTransitioning) {
        return
    }

    $mtxDead = ($null -eq $script:mtxProc -or $script:mtxProc.HasExited)
    $ffDead  = ($null -eq $script:ffProc -or $script:ffProc.HasExited)

    if (-not $mtxDead -and -not $ffDead) {
        $script:healthyTicks++
        if ($script:healthyTicks -ge 2 -and $script:consecutiveFailures -gt 0) {
            $script:consecutiveFailures = 0
            Write-DaemonLog -Level 'INFO' -Message 'Stream stabilized; reset watchdog failure counter.'
        }
        return
    }

    $script:healthyTicks = 0
    if ((Get-Date) -lt $script:nextRetryAt) {
        return
    }

    $script:isTransitioning = $true
    try {
        $script:consecutiveFailures++
        $maxFailures = [int]$script:config.watchdog.maxConsecutiveFailures

        if ($script:consecutiveFailures -gt $maxFailures) {
            Write-DaemonLog -Level 'ERROR' -Message "Watchdog exceeded max consecutive failures ($maxFailures). Pausing auto-recovery."
            $script:desiredRunning = $false
            Stop-FfmpegProcess
            Stop-MtxProcess
            Set-StreamState -State 'Error' -Detail 'Check Logs'
            Show-TrayNotification -Title 'Audio Stream Stopped' -Text 'Auto-recovery paused after repeated failures. Open Logs Folder to inspect errors.' -Icon ([System.Windows.Forms.ToolTipIcon]::Error) -TimeoutMs 5000
            return
        }

        Write-DaemonLog -Level 'WARN' -Message "Watchdog detected process exit (mtxDead=$mtxDead, ffDead=$ffDead). Recovery attempt $($script:consecutiveFailures)/$maxFailures."
        Set-StreamState -State 'Recovering' -Detail "Recovering ($($script:consecutiveFailures)/$maxFailures)..."

        $recovered = $false
        if ($mtxDead) {
            Stop-FfmpegProcess
            Stop-MtxProcess
            if (Start-MtxProcess) {
                $recovered = Start-FfmpegProcess
            }
        }
        else {
            Stop-FfmpegProcess
            $recovered = Start-FfmpegProcess
        }

        if ($recovered) {
            Set-StreamState -State 'LIVE'
            Write-DaemonLog -Level 'INFO' -Message 'Watchdog recovery succeeded.'
        }
        else {
            $schedule = @($script:config.watchdog.backoffSeconds)
            $idx = [Math]::Min($script:consecutiveFailures - 1, $schedule.Count - 1)
            $delaySec = if ($schedule.Count -gt 0) { [int]$schedule[$idx] } else { 5 }
            $script:nextRetryAt = (Get-Date).AddSeconds($delaySec)
            Set-StreamState -State 'Recovering' -Detail "Retry in ${delaySec}s"
            Write-DaemonLog -Level 'WARN' -Message "Recovery attempt failed; next retry in ${delaySec}s."
        }
    }
    finally {
        $script:isTransitioning = $false
    }
})
$script:watchdog.Start()

# ==================== GLOBAL HOTKEYS ====================
$script:hotkeyMgr = New-Object MicStreamNative.GlobalHotkeyManager
$streamHkOk = $script:hotkeyMgr.Register(1, [uint32]$script:config.hotkey.modifiers, [uint32]$script:config.hotkey.virtualKey)
$recHkOk    = $script:hotkeyMgr.Register(2, [uint32]$script:config.recording.hotkey.modifiers, [uint32]$script:config.recording.hotkey.virtualKey)

$script:hotkeyMgr.add_HotkeyPressed({
    param($id)
    if ($id -eq 1) { Toggle-Stream }
    elseif ($id -eq 2) { Toggle-AudioRecording }
})

if ($streamHkOk) {
    Write-DaemonLog -Level 'INFO' -Message "Registered Stream hotkey: $($script:config.hotkey.label)"
}
else {
    Write-DaemonLog -Level 'WARN' -Message "Stream hotkey $($script:config.hotkey.label) already in use (Win32Error=$($script:hotkeyMgr.LastError))."
    Show-TrayNotification -Title 'Stream Hotkey Unavailable' -Text "$($script:config.hotkey.label) is used by another app. Use the Control Panel or edit config.json." -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
}

if ($recHkOk) {
    Write-DaemonLog -Level 'INFO' -Message "Registered Recording hotkey: $($script:config.recording.hotkey.label)"
}
else {
    Write-DaemonLog -Level 'WARN' -Message "Recording hotkey $($script:config.recording.hotkey.label) already in use."
}

# ==================== CLEAN TEARDOWN ====================
function Invoke-DaemonShutdown {
    if ($script:isShuttingDown) { return }
    $script:isShuttingDown = $true
    Write-DaemonLog -Level 'INFO' -Message 'Shutting down MicStream Tray Daemon.'

    try { $script:uiTickTimer.Stop(); $script:uiTickTimer.Dispose() } catch { }
    try { $script:watchdog.Stop(); $script:watchdog.Dispose() } catch { }

    Stop-AudioRecording -Reason 'Shutdown'
    $script:isTransitioning = $false
    Stop-Stream
    Stop-CloudflaredProcess
    Stop-DashboardProcess
    try {
        $stFile = Join-Path (Get-IpcDirPath) 'state.json'
        if (Test-Path -LiteralPath $stFile) { Remove-Item -LiteralPath $stFile -Force -ErrorAction SilentlyContinue }
    }
    catch { }

    try { [Microsoft.Win32.SystemEvents]::remove_SessionEnding($script:sessionEndingHandler) } catch { }
    try { $script:hotkeyMgr.Dispose() } catch { }

    if ($null -ne $script:panelForm -and -not $script:panelForm.IsDisposed) {
        try { $script:panelForm.Close(); $script:panelForm.Dispose() } catch { }
    }

    try {
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
    }
    catch { }
    try { $script:menu.Dispose() } catch { }

    foreach ($h in $script:iconHandles) {
        if ($h -ne [IntPtr]::Zero) {
            [void][MicStreamNative.IconHelper]::DestroyIcon($h)
        }
    }

    try { $script:job.Dispose() } catch { }
    try { $script:showPanelEvent.Dispose() } catch { }
    try {
        $script:singleInstanceMutex.ReleaseMutex()
        $script:singleInstanceMutex.Dispose()
    }
    catch { }

    [System.Windows.Forms.Application]::Exit()
}

$script:sessionEndingHandler = [Microsoft.Win32.SessionEndingEventHandler]{
    param($sender, $e)
    Invoke-DaemonShutdown
}
[Microsoft.Win32.SystemEvents]::add_SessionEnding($script:sessionEndingHandler)
$script:exitItem.Add_Click({ Invoke-DaemonShutdown })

# Start Web Dashboard & Optional Cloudflare Tunnel on daemon boot for anytime remote control
Update-CachedMicrophones
if ([bool]$script:config.dashboard.enabled) {
    [void](Start-DashboardProcess)
}
if ([bool]$script:config.network.cloudflared.enabled) {
    [void](Start-CloudflaredProcess)
}
Update-AllUiState
Write-IpcState

if ($ShowPanel) {
    Show-ControlPanel
}

# ==================== MESSAGE LOOP ====================
[System.Windows.Forms.Application]::Run()

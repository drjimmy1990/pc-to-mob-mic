# PC-to-Mobile Headless WebRTC Mic Streamer & Recorder

Low-latency (< 500 ms), zero-footprint Windows microphone streaming and recording system powered by **FFmpeg**, **MediaMTX (WebRTC/WHEP)**, a headless **Windows System Tray daemon + Control Panel**, optional **Cloudflare Named Tunnel**, and a self-hosted **Ubuntu Docker `coturn` TURN relay**.

## Features
- **Zero-Footprint Headless Operation:** Runs quietly in the Windows System Tray (`Start-MicTray.vbs`) with an optional clickable **Control Panel** (`0-Open-Control-Panel.bat`).
- **Low-Latency Audio Pipeline:** DirectShow 50 ms buffer -> `highpass=f=100` -> low-latency `dynaudnorm=f=50:g=5:m=10` -> `libopus` (`lowdelay`, 20 ms frames, 48 kHz mono).
- **Independent MP3 Recording + Auto-Stop:** Record anytime (whether the live stream is ON or OFF) with configurable auto-stop (`Manual`, `5–120 min`, or `Custom 1–1440 min`) and graceful MP3 flushing to `recordings/`.
- **Conflict-Free Global Hotkeys:** `Ctrl + Shift + F9` (Toggle Live Stream) and `Ctrl + Shift + F10` (Toggle Recording), customizable in `config.json`.
- **Zero-Trust Auth & Multi-Transport Ready:** Loopback-only TCP RTSP ingest (`127.0.0.1:8554`), SHA-256 hashed listener credentials (`authInternalUsers`), dynamic WebRTC ICE interface filtering, and full support for **Local Wi-Fi/LAN**, **Tailscale**, and **Cloudflare Named Tunnel + VPS `coturn`**.
- **Self-Healing & Zero Orphans:** Kernel-enforced Win32 `ProcessJob` (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`), single-instance mutex, exponential watchdog backoff, and rotating file logs in `logs/`.

---

## Quickstart (Windows Laptop)

1. **Install FFmpeg** (must include `libopus` and `libmp3lame`, e.g., `winget install Gyan.FFmpeg`).
2. **Download MediaMTX & seed local configs:**
   ```powershell
   .\scripts\Install-MediaMTX.ps1
   ```
3. **Set your stream password** (double-click **`4-Change-Password.bat`** or run `.\scripts\Set-StreamPassword.ps1`).
4. **Launch the Control Panel:** Double-click **`0-Open-Control-Panel.bat`** (or **`1-Start-MicTray.bat`** for tray-only mode).

### Clickable Control Scripts
| Script | Action |
| :--- | :--- |
| `0-Open-Control-Panel.bat` | Opens the clickable Control Panel (Stream, Optional Cloudflare Tunnel checkbox, Record button, Auto-Stop timer) |
| `1-Start-MicTray.bat` | Launches silently in the System Tray (no window) |
| `2-Stop-Everything.bat` | Kill switch — stops tray daemon, MediaMTX, FFmpeg stream, recorder, and `cloudflared` |
| `3-Check-Status.bat` | Prints live process status, environment diagnostics, and reachable stream URLs |
| `4-Change-Password.bat` | Sets/updates your SHA-256 hashed `admin` password in `mediamtx.yml` |
| `5-Configure-Remote.bat` | Interactive wizard for Cloudflare Named Tunnel + VPS `coturn` TURN + `cloudflared.exe` download |

---

## Remote Listening Setup (Ubuntu Docker VPS `coturn` + Cloudflare Named Tunnel)

### 1. Deploy `coturn` on Your Ubuntu VPS
```bash
git clone https://github.com/drjimmy1990/pc-to-mob-mic.git
cd pc-to-mob-mic/vps/coturn

SECRET=$(openssl rand -hex 32)
VPS_IP=$(curl -s4 ifconfig.me)
echo "SAVE THIS SECRET: $SECRET"
echo "YOUR VPS IP:      $VPS_IP"

cp turnserver.conf.example turnserver.conf
sed -i "s|REPLACE_WITH_OPENSSL_RAND_HEX_32|$SECRET|g" turnserver.conf
sed -i "s|YOUR_VPS_PUBLIC_IP|$VPS_IP|g" turnserver.conf
sed -i "s|turn.yourdomain.com|turn.YOURDOMAIN.com|g" turnserver.conf

sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 49152:49252/udp
docker compose up -d
docker compose logs -f
```
See [`vps/coturn/README.md`](vps/coturn/README.md) for full details and Cloudflare DNS notes.

### 2. Create a Cloudflare Named Tunnel
In **Cloudflare Zero Trust -> Networks -> Tunnels -> Create a tunnel (Cloudflared)**:
- Copy the tunnel token.
- Add a **Public Hostname** route: `https://mic.yourdomain.com` -> `HTTP` -> `http://localhost:8890` *(serves the Mobile Field-Recorder Web Dashboard, login screen, live WebRTC WHEP audio, remote recording + auto-stop, and laptop Recordings Vault)*.

### 3. Link Your Laptop
Run **`5-Configure-Remote.bat`**, enter your tunnel URL, tunnel token, `turn:<VPS_IP>:3478`, and `$SECRET`, and let it install `cloudflared.exe`. Then check **Enable Cloudflare Tunnel (Remote Dashboard Access)** in the Control Panel whenever you want remote access.

---

## Testing & Documentation
- Run PowerShell unit tests:
  ```powershell
  Invoke-Pester -Path ".\tests\MicStream.Core.Tests.ps1" -EnableExit
  ```
- Run Web Dashboard & WHEP proxy tests:
  ```powershell
  node --test .\dashboard\server.test.mjs
  ```
- Full architecture diagrams, Tailscale guide, manual Windows Firewall / `shell:startup` / `powercfg` provisioning commands, and troubleshooting live in [`ARCHITECTURE.md`](ARCHITECTURE.md).

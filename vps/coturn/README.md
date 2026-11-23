# Self-Hosted `coturn` TURN Relay (Ubuntu + Docker)

This lightweight container relays WebRTC audio between your Windows laptop (behind Cloudflare Tunnel / ProtonVPN) and your phone on 4G/5G with unlimited 24/7 hours and zero expiring tokens.

## 1. Prepare Directory & Config on Your Ubuntu VPS

SSH into your Ubuntu VPS and run:

```bash
mkdir -p ~/micstream-coturn && cd ~/micstream-coturn
```

Copy `docker-compose.yml` and `turnserver.conf.example` from `d:\DEV\mic\vps\coturn\` to `~/micstream-coturn/` (or paste them directly), then generate a strong shared secret:

```bash
SECRET=$(openssl rand -hex 32)
echo "SAVE THIS SECRET FOR YOUR LAPTOP: $SECRET"
VPS_IP=$(curl -s4 ifconfig.me)
echo "YOUR VPS IP: $VPS_IP"
```

Create `turnserver.conf` from `turnserver.conf.example` and replace:
- `REPLACE_WITH_OPENSSL_RAND_HEX_32` with `$SECRET`
- `YOUR_VPS_PUBLIC_IP` with `$VPS_IP`
- `turn.yourdomain.com` with your domain (or subdomain)

## 2. Open TURN Ports on Your VPS Firewall

If using Ubuntu `ufw` (also allow these in your cloud provider firewall panel if applicable):

```bash
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 49152:49252/udp
```

## 3. Start `coturn`

```bash
docker compose up -d
docker compose logs -f
```

You should see `coturn` listening on `3478` (UDP & TCP) with no errors.

## 4. Connect Your Laptop (`d:\DEV\mic`)

Double-click **`5-Configure-Remote.bat`** in `d:\DEV\mic` and enter:
- **Public Tunnel URL:** `https://mic.yourdomain.com`
- **Cloudflare Tunnel Token:** (from Cloudflare Zero Trust -> Networks -> Tunnels)
- **TURN URL:** `turn:<YOUR_VPS_IP>:3478` *(or `turn:turn.yourdomain.com:3478` with an unproxied DNS-only A record in Cloudflare!)*
- **TURN Auth Secret:** the `$SECRET` you generated above.

> **Important DNS Note:** If you create a DNS record `turn.yourdomain.com` in Cloudflare pointing to your VPS IP, set the Cloudflare cloud icon to **DNS only (Gray cloud)**—never Orange-proxied, because Cloudflare Proxy does not pass TURN port 3478!

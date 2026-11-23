'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const SESSION_COOKIE = 'micstream_sid';
const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_MAX_ATTEMPTS = 12;
const SAFE_RECORDING_RE = /^[A-Za-z0-9._-]+\.(mp3|ogg|m4a|wav)$/i;

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.mp3': 'audio/mpeg',
  '.ogg': 'audio/ogg',
  '.m4a': 'audio/mp4',
  '.wav': 'audio/wav',
};

function computeMediaMtxSha256(plainText) {
  const b64 = crypto.createHash('sha256').update(plainText, 'utf8').digest('base64');
  return `sha256:${b64}`;
}

function timingSafeStringEqual(a, b) {
  const bufA = Buffer.from(String(a || ''), 'utf8');
  const bufB = Buffer.from(String(b || ''), 'utf8');
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

/**
 * Parses `authInternalUsers` from mediamtx.yml so the dashboard uses the
 * exact same credentials (supporting both sha256:<base64> and plain passwords).
 */
function parseMediaMtxUsers(yamlText) {
  const users = [];
  const lines = String(yamlText || '').split(/\r?\n/);
  let inAuth = false;
  let current = null;

  for (const rawLine of lines) {
    const line = rawLine.replace(/\r$/, '');
    if (/^authInternalUsers\s*:/.test(line)) {
      inAuth = true;
      current = null;
      continue;
    }
    if (inAuth && /^[A-Za-z0-9_]+\s*:/.test(line)) {
      inAuth = false;
      current = null;
      continue;
    }
    if (!inAuth) continue;

    const userMatch = line.match(/^\s*-\s+user\s*:\s*['"]?([^'"\s#]+)['"]?/);
    if (userMatch) {
      current = { user: userMatch[1], pass: '', hasRead: false };
      users.push(current);
      continue;
    }
    if (!current) continue;

    const passMatch = line.match(/^\s*pass\s*:\s*(.*)$/);
    if (passMatch) {
      let val = passMatch[1].trim();
      if ((val.startsWith("'") && val.endsWith("'")) || (val.startsWith('"') && val.endsWith('"'))) {
        val = val.slice(1, -1);
      }
      current.pass = val;
      continue;
    }
    if (/^\s*-\s+action\s*:\s*read\b/.test(line)) {
      current.hasRead = true;
    }
  }
  return users;
}

function verifyCredentials(yamlPath, username, password) {
  if (!username || !password) return false;
  if (!fs.existsSync(yamlPath)) return false;

  const yamlText = fs.readFileSync(yamlPath, 'utf8');
  const users = parseMediaMtxUsers(yamlText);
  const candidate = users.find((u) => u.user !== 'any' && timingSafeStringEqual(u.user, username));
  if (!candidate || !candidate.pass) return false;
  if (candidate.pass === 'REPLACE_BY_RUNNING_Set-StreamPassword.ps1' || candidate.pass === 'CHANGE_THIS_STRONG_PASSWORD') {
    return false;
  }

  if (candidate.pass.startsWith('sha256:')) {
    const actual = computeMediaMtxSha256(password);
    return timingSafeStringEqual(candidate.pass, actual);
  }
  return timingSafeStringEqual(candidate.pass, password);
}

function parseCookies(cookieHeader) {
  const map = {};
  if (!cookieHeader) return map;
  for (const part of cookieHeader.split(';')) {
    const idx = part.indexOf('=');
    if (idx <= 0) continue;
    const key = part.slice(0, idx).trim();
    const val = part.slice(idx + 1).trim();
    if (key) map[key] = decodeURIComponent(val);
  }
  return map;
}

function getClientIp(req) {
  const cfIp = req.headers['cf-connecting-ip'];
  if (cfIp && typeof cfIp === 'string') return cfIp.trim();
  const xff = req.headers['x-forwarded-for'];
  if (xff && typeof xff === 'string') return xff.split(',')[0].trim();
  return req.socket?.remoteAddress || 'unknown';
}

function readJsonBody(req, maxBytes = 65536) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new Error('PAYLOAD_TOO_LARGE'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw.trim()) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('INVALID_JSON'));
      }
    });
    req.on('error', reject);
  });
}

function readRawBody(req, maxBytes = 262144) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new Error('PAYLOAD_TOO_LARGE'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    ...extraHeaders,
  });
  res.end(body);
}

function isSafeRecordingName(name) {
  if (!name || typeof name !== 'string') return false;
  if (name.includes('/') || name.includes('\\') || name.includes('..')) return false;
  return SAFE_RECORDING_RE.test(name);
}

function listRecordings(recordingsDir) {
  if (!fs.existsSync(recordingsDir)) return [];
  const entries = fs.readdirSync(recordingsDir, { withFileTypes: true });
  const items = [];
  for (const ent of entries) {
    if (!ent.isFile() || !isSafeRecordingName(ent.name)) continue;
    const full = path.join(recordingsDir, ent.name);
    try {
      const st = fs.statSync(full);
      items.push({
        name: ent.name,
        sizeBytes: st.size,
        modifiedAt: st.mtime.toISOString(),
        createdAt: st.birthtime ? st.birthtime.toISOString() : st.mtime.toISOString(),
      });
    } catch {
      // Skip files mid-rotation/removal
    }
  }
  items.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt));
  return items;
}

function createAppServer(options = {}) {
  const repoRoot = options.repoRoot || path.resolve(__dirname, '..');
  const publicDir = options.publicDir || path.join(__dirname, 'public');
  const yamlPath = options.yamlPath || path.join(repoRoot, 'mediamtx.yml');
  const configPath = options.configPath || path.join(repoRoot, 'config.json');
  const recordingsDir = options.recordingsDir || path.join(repoRoot, 'recordings');
  const ipcDir = options.ipcDir || path.join(repoRoot, 'logs', '.ipc');
  const mediamtxHost = options.mediamtxHost || '127.0.0.1';
  const mediamtxPort = options.mediamtxPort || 8889;
  const streamPath = (options.streamPath || 'mic').replace(/^\/+/, '');
  const ipcTimeoutMs = options.ipcTimeoutMs || 9000;

  fs.mkdirSync(ipcDir, { recursive: true });
  fs.mkdirSync(recordingsDir, { recursive: true });

  const sessions = new Map();
  const loginAttempts = new Map();

  function cleanExpiredSessions() {
    const now = Date.now();
    for (const [sid, sess] of sessions.entries()) {
      if (sess.expiresAt <= now) sessions.delete(sid);
    }
  }

  function getSession(req) {
    cleanExpiredSessions();
    const cookies = parseCookies(req.headers.cookie);
    const sid = cookies[SESSION_COOKIE];
    if (!sid) return null;
    const sess = sessions.get(sid);
    if (!sess) return null;
    sess.expiresAt = Date.now() + SESSION_TTL_MS;
    return { sid, ...sess };
  }

  function checkRateLimit(ip) {
    const now = Date.now();
    const bucket = loginAttempts.get(ip) || [];
    const recent = bucket.filter((ts) => now - ts < LOGIN_WINDOW_MS);
    loginAttempts.set(ip, recent);
    return recent.length < LOGIN_MAX_ATTEMPTS;
  }

  function recordFailedLogin(ip) {
    const now = Date.now();
    const bucket = (loginAttempts.get(ip) || []).filter((ts) => now - ts < LOGIN_WINDOW_MS);
    bucket.push(now);
    loginAttempts.set(ip, bucket);
  }

  function readDaemonState() {
    const stateFile = path.join(ipcDir, 'state.json');
    if (fs.existsSync(stateFile)) {
      try {
        const raw = fs.readFileSync(stateFile, 'utf8');
        const parsed = JSON.parse(raw);
        return { daemonConnected: true, ...parsed };
      } catch {
        // Fallback below
      }
    }
    let cfg = {};
    try {
      if (fs.existsSync(configPath)) cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } catch { }
    return {
      daemonConnected: false,
      streamState: 'Stopped',
      streamDetail: 'Waiting for tray daemon',
      desiredRunning: false,
      isRecording: false,
      recStartTimeUtc: null,
      recAutoStopMinutes: cfg?.recording?.defaultAutoStopMinutes || 0,
      recActiveLimitMinutes: 0,
      recOutputFile: '',
      ambientBoost: cfg?.audio?.enableAmbientBoost !== false,
      microphoneName: cfg?.audio?.microphoneName || '',
      microphones: cfg?.audio?.microphoneName ? [cfg.audio.microphoneName] : [],
      cloudflaredEnabled: Boolean(cfg?.network?.cloudflared?.enabled),
      cloudflaredActive: false,
      publicUrl: cfg?.network?.publicUrl || '',
      streamPath,
    };
  }

  function sendTrayCommand(action, payload = {}) {
    return new Promise((resolve, reject) => {
      const id = crypto.randomUUID().replace(/-/g, '');
      const cmdTmp = path.join(ipcDir, `cmd_${id}.json.tmp`);
      const cmdFile = path.join(ipcDir, `cmd_${id}.json`);
      const resFile = path.join(ipcDir, `res_${id}.json`);

      const msg = {
        id,
        action,
        payload,
        createdAt: new Date().toISOString(),
      };

      try {
        fs.mkdirSync(ipcDir, { recursive: true });
        fs.writeFileSync(cmdTmp, JSON.stringify(msg), 'utf8');
        fs.renameSync(cmdTmp, cmdFile);
      } catch (err) {
        return reject(new Error(`Failed to dispatch tray command: ${err.message}`));
      }

      const deadline = Date.now() + ipcTimeoutMs;
      const poll = setInterval(() => {
        if (fs.existsSync(resFile)) {
          clearInterval(poll);
          let parsed = { ok: true };
          try {
            parsed = JSON.parse(fs.readFileSync(resFile, 'utf8'));
          } catch {
            parsed = { ok: true };
          }
          try { fs.unlinkSync(resFile); } catch { }
          return resolve(parsed);
        }
        if (Date.now() >= deadline) {
          clearInterval(poll);
          try { if (fs.existsSync(cmdFile)) fs.unlinkSync(cmdFile); } catch { }
          return reject(new Error('Tray daemon did not respond in time. Ensure MicStream Tray is running.'));
        }
      }, 80);
    });
  }

  async function proxyWhep(req, res, session, suffixPath) {
    const bodyBuf = (req.method === 'POST' || req.method === 'PATCH') ? await readRawBody(req) : null;
    const targetPath = `/${streamPath}/whep${suffixPath || ''}`;

    const forwardHeaders = {
      Authorization: session.basicAuthHeader,
    };
    if (req.headers['content-type']) forwardHeaders['Content-Type'] = req.headers['content-type'];
    if (req.headers['accept']) forwardHeaders['Accept'] = req.headers['accept'];
    if (req.headers['if-match']) forwardHeaders['If-Match'] = req.headers['if-match'];
    if (bodyBuf) forwardHeaders['Content-Length'] = bodyBuf.length;
    forwardHeaders['X-Forwarded-For'] = getClientIp(req);

    return new Promise((resolve) => {
      const upstream = http.request(
        {
          hostname: mediamtxHost,
          port: mediamtxPort,
          path: targetPath,
          method: req.method,
          headers: forwardHeaders,
          timeout: 10000,
        },
        (upRes) => {
          const respHeaders = {
            'Cache-Control': 'no-store',
          };
          const passList = ['content-type', 'etag', 'accept-patch', 'link'];
          for (const h of passList) {
            if (upRes.headers[h] !== undefined) {
              respHeaders[h] = upRes.headers[h];
            }
          }
          if (upRes.headers.location) {
            // Rewrite /mic/whep/<id> -> /api/whep/<id>
            const loc = String(upRes.headers.location);
            const prefix = `/${streamPath}/whep`;
            respHeaders.location = loc.startsWith(prefix) ? `/api/whep${loc.slice(prefix.length)}` : loc;
          }

          res.writeHead(upRes.statusCode || 502, respHeaders);
          upRes.pipe(res);
          upRes.on('end', resolve);
        }
      );

      upstream.on('timeout', () => {
        upstream.destroy();
        if (!res.headersSent) {
          sendJson(res, 504, { error: 'MediaMTX WHEP timeout' });
        }
        resolve();
      });

      upstream.on('error', () => {
        if (!res.headersSent) {
          sendJson(res, 503, { error: 'Stream is currently offline. Turn the laptop stream ON first.' });
        }
        resolve();
      });

      if (bodyBuf && bodyBuf.length > 0) upstream.write(bodyBuf);
      upstream.end();
    });
  }

  function serveStatic(res, fileName) {
    const safeName = path.basename(fileName);
    const full = path.join(publicDir, safeName);
    if (!fs.existsSync(full)) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not found');
      return;
    }
    const ext = path.extname(safeName).toLowerCase();
    const content = fs.readFileSync(full);
    res.writeHead(200, {
      'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
      'Cache-Control': ext === '.html' ? 'no-store' : 'public, max-age=300',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    });
    res.end(content);
  }

  function serveRecording(req, res, fileName, forceDownload) {
    if (!isSafeRecordingName(fileName)) {
      return sendJson(res, 400, { error: 'Invalid recording filename' });
    }
    const resolvedBase = path.resolve(recordingsDir);
    const resolvedFile = path.resolve(recordingsDir, fileName);
    if (!resolvedFile.startsWith(resolvedBase + path.sep) || !fs.existsSync(resolvedFile)) {
      return sendJson(res, 404, { error: 'Recording not found' });
    }

    const stat = fs.statSync(resolvedFile);
    const fileSize = stat.size;
    const ext = path.extname(fileName).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';
    const baseHeaders = {
      'Content-Type': contentType,
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    };
    if (forceDownload) {
      baseHeaders['Content-Disposition'] = `attachment; filename="${fileName}"`;
    }

    const range = req.headers.range;
    if (range) {
      const match = String(range).match(/^bytes=(\d*)-(\d*)$/);
      if (!match) {
        res.writeHead(416, { 'Content-Range': `bytes */${fileSize}` });
        return res.end();
      }
      const start = match[1] ? parseInt(match[1], 10) : 0;
      const end = match[2] ? Math.min(parseInt(match[2], 10), fileSize - 1) : fileSize - 1;
      if (Number.isNaN(start) || Number.isNaN(end) || start > end || start >= fileSize) {
        res.writeHead(416, { 'Content-Range': `bytes */${fileSize}` });
        return res.end();
      }
      const chunkSize = end - start + 1;
      res.writeHead(206, {
        ...baseHeaders,
        'Content-Range': `bytes ${start}-${end}/${fileSize}`,
        'Content-Length': chunkSize,
      });
      fs.createReadStream(resolvedFile, { start, end }).pipe(res);
      return;
    }

    res.writeHead(200, {
      ...baseHeaders,
      'Content-Length': fileSize,
    });
    fs.createReadStream(resolvedFile).pipe(res);
  }

  function requireCsrf(req, res) {
    if (req.headers['x-requested-with'] !== 'MicStream') {
      sendJson(res, 403, { error: 'Missing required X-Requested-With header' });
      return false;
    }
    return true;
  }

  const server = http.createServer(async (req, res) => {
    try {
      const urlObj = new URL(req.url || '/', 'http://localhost');
      const pathname = urlObj.pathname;

      // Public static shell (app checks /api/auth/me and renders login screen when unauthenticated)
      if (req.method === 'GET' && (pathname === '/' || pathname === `/${streamPath}` || pathname === `/${streamPath}/`)) {
        return serveStatic(res, 'index.html');
      }
      if (req.method === 'GET' && (pathname === '/styles.css' || pathname === '/app.js' || pathname === '/favicon.svg')) {
        return serveStatic(res, pathname.slice(1));
      }

      if (req.method === 'GET' && pathname === '/api/health') {
        return sendJson(res, 200, { ok: true, service: 'micstream-dashboard' });
      }

      // Auth endpoints
      if (req.method === 'GET' && pathname === '/api/auth/me') {
        const sess = getSession(req);
        if (!sess) return sendJson(res, 401, { authenticated: false });
        return sendJson(res, 200, { authenticated: true, user: sess.user });
      }

      if (req.method === 'POST' && pathname === '/api/login') {
        if (!requireCsrf(req, res)) return;
        const ip = getClientIp(req);
        if (!checkRateLimit(ip)) {
          return sendJson(res, 429, { error: 'Too many login attempts. Please wait 15 minutes.' });
        }
        const body = await readJsonBody(req);
        const user = String(body.username || '').trim();
        const pass = String(body.password || '');
        if (!verifyCredentials(yamlPath, user, pass)) {
          recordFailedLogin(ip);
          return sendJson(res, 401, { error: 'Invalid username or password.' });
        }

        const sid = crypto.randomBytes(32).toString('hex');
        const basicAuthHeader = 'Basic ' + Buffer.from(`${user}:${pass}`, 'utf8').toString('base64');
        sessions.set(sid, {
          user,
          basicAuthHeader,
          expiresAt: Date.now() + SESSION_TTL_MS,
        });

        const isHttps = req.headers['x-forwarded-proto'] === 'https' || Boolean(req.socket.encrypted);
        const cookieParts = [
          `${SESSION_COOKIE}=${sid}`,
          'Path=/',
          'HttpOnly',
          'SameSite=Lax',
          `Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`,
        ];
        if (isHttps) cookieParts.push('Secure');

        return sendJson(
          res,
          200,
          { authenticated: true, user },
          { 'Set-Cookie': cookieParts.join('; ') }
        );
      }

      if (req.method === 'POST' && pathname === '/api/logout') {
        if (!requireCsrf(req, res)) return;
        const sess = getSession(req);
        if (sess) sessions.delete(sess.sid);
        return sendJson(
          res,
          200,
          { ok: true },
          { 'Set-Cookie': `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0` }
        );
      }

      // All remaining /api/* endpoints require a valid session
      const session = getSession(req);
      if (!session) {
        return sendJson(res, 401, { error: 'Authentication required' });
      }

      // WHEP WebRTC Proxy (OPTIONS, POST, PATCH, DELETE)
      if (pathname === '/api/whep' || pathname.startsWith('/api/whep/')) {
        const suffix = pathname.slice('/api/whep'.length);
        return await proxyWhep(req, res, session, suffix);
      }

      // Live Status + Recordings Snapshot
      if (req.method === 'GET' && pathname === '/api/status') {
        const state = readDaemonState();
        return sendJson(res, 200, {
          ...state,
          serverTimeUtc: new Date().toISOString(),
          recordingsCount: listRecordings(recordingsDir).length,
        });
      }

      // Stream & Audio Control Endpoints
      if (req.method === 'POST' && pathname === '/api/stream/start') {
        if (!requireCsrf(req, res)) return;
        const r = await sendTrayCommand('start_stream');
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      if (req.method === 'POST' && pathname === '/api/stream/stop') {
        if (!requireCsrf(req, res)) return;
        const r = await sendTrayCommand('stop_stream');
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      if (req.method === 'POST' && pathname === '/api/audio/boost') {
        if (!requireCsrf(req, res)) return;
        const body = await readJsonBody(req);
        const enabled = Boolean(body.enabled);
        const r = await sendTrayCommand('set_boost', { enabled });
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      if (req.method === 'POST' && pathname === '/api/audio/microphone') {
        if (!requireCsrf(req, res)) return;
        const body = await readJsonBody(req);
        const name = String(body.microphoneName || '').trim();
        if (!name) return sendJson(res, 400, { error: 'microphoneName is required' });
        const r = await sendTrayCommand('set_microphone', { microphoneName: name });
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      // Recording Control Endpoints
      if (req.method === 'POST' && pathname === '/api/record/start') {
        if (!requireCsrf(req, res)) return;
        const body = await readJsonBody(req);
        let autoStopMinutes = parseInt(body.autoStopMinutes, 10);
        if (Number.isNaN(autoStopMinutes) || autoStopMinutes < 0) autoStopMinutes = 0;
        if (autoStopMinutes > 1440) autoStopMinutes = 1440;
        const r = await sendTrayCommand('start_record', { autoStopMinutes });
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      if (req.method === 'POST' && pathname === '/api/record/stop') {
        if (!requireCsrf(req, res)) return;
        const r = await sendTrayCommand('stop_record');
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      if (req.method === 'POST' && pathname === '/api/record/autostop') {
        if (!requireCsrf(req, res)) return;
        const body = await readJsonBody(req);
        let minutes = parseInt(body.minutes, 10);
        if (Number.isNaN(minutes) || minutes < 0) minutes = 0;
        if (minutes > 1440) minutes = 1440;
        const r = await sendTrayCommand('set_autostop', { minutes });
        return sendJson(res, r.ok === false ? 500 : 200, { ...r, state: readDaemonState() });
      }

      // Recordings Library Endpoints
      if (req.method === 'GET' && pathname === '/api/recordings') {
        return sendJson(res, 200, { recordings: listRecordings(recordingsDir) });
      }

      if (pathname.startsWith('/api/recordings/')) {
        const rawName = decodeURIComponent(pathname.slice('/api/recordings/'.length));
        if (req.method === 'GET') {
          const forceDownload = urlObj.searchParams.get('download') === '1';
          return serveRecording(req, res, rawName, forceDownload);
        }
        if (req.method === 'DELETE') {
          if (!requireCsrf(req, res)) return;
          if (!isSafeRecordingName(rawName)) {
            return sendJson(res, 400, { error: 'Invalid recording filename' });
          }
          const resolvedBase = path.resolve(recordingsDir);
          const resolvedFile = path.resolve(recordingsDir, rawName);
          if (!resolvedFile.startsWith(resolvedBase + path.sep) || !fs.existsSync(resolvedFile)) {
            return sendJson(res, 404, { error: 'Recording not found' });
          }
          const state = readDaemonState();
          if (state.isRecording && state.recOutputFile && path.basename(state.recOutputFile) === rawName) {
            return sendJson(res, 409, { error: 'Cannot delete the active recording while it is in progress.' });
          }
          fs.unlinkSync(resolvedFile);
          return sendJson(res, 200, { ok: true, deleted: rawName });
        }
      }

      sendJson(res, 404, { error: 'Not found' });
    } catch (err) {
      if (err.message === 'PAYLOAD_TOO_LARGE') {
        return sendJson(res, 413, { error: 'Payload too large' });
      }
      if (err.message === 'INVALID_JSON') {
        return sendJson(res, 400, { error: 'Invalid JSON body' });
      }
      if (!res.headersSent) {
        sendJson(res, 500, { error: err.message || 'Internal server error' });
      }
    }
  });

  return server;
}

if (require.main === module) {
  const repoRoot = path.resolve(__dirname, '..');
  const configPath = path.join(repoRoot, 'config.json');
  let cfg = {};
  try {
    if (fs.existsSync(configPath)) cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch { }

  const host = process.env.MICSTREAM_DASHBOARD_HOST || cfg?.dashboard?.host || '0.0.0.0';
  const port = Number(process.env.MICSTREAM_DASHBOARD_PORT || cfg?.dashboard?.port || 8890);
  const mediamtxPort = Number(cfg?.stream?.webrtcPort || 8889);
  const streamPath = cfg?.stream?.streamPath || 'mic';
  const recordingsDir = path.isAbsolute(cfg?.recording?.recordingsDir || '')
    ? cfg.recording.recordingsDir
    : path.join(repoRoot, cfg?.recording?.recordingsDir || 'recordings');

  const server = createAppServer({
    repoRoot,
    mediamtxPort,
    streamPath,
    recordingsDir,
  });

  server.listen(port, host, () => {
    console.log(`[${new Date().toISOString()}] MicStream Dashboard listening on http://${host}:${port} (WHEP -> 127.0.0.1:${mediamtxPort}/${streamPath})`);
  });
}

module.exports = {
  createAppServer,
  computeMediaMtxSha256,
  parseMediaMtxUsers,
  verifyCredentials,
  isSafeRecordingName,
  listRecordings,
};

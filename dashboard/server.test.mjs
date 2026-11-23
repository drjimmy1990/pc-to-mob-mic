import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  createAppServer,
  computeMediaMtxSha256,
  verifyCredentials,
  isSafeRecordingName,
} = require('./server.js');

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      resolve(addr.port);
    });
  });
}

function closeServer(server) {
  return new Promise((resolve) => server.close(() => resolve()));
}

test('computeMediaMtxSha256 matches MediaMTX OpenSSL base64 vector', () => {
  assert.equal(
    computeMediaMtxSha256('mypass'),
    'sha256:6nHCWnpgIka0w5gkuFVniJSpb0O7m3ExnDlwCh4EUiI='
  );
});

test('isSafeRecordingName blocks path traversal and non-audio extensions', () => {
  assert.equal(isSafeRecordingName('mic_2026-11-24_00-04-29.mp3'), true);
  assert.equal(isSafeRecordingName('clip-1.m4a'), true);
  assert.equal(isSafeRecordingName('../mediamtx.yml'), false);
  assert.equal(isSafeRecordingName('..\\config.json'), false);
  assert.equal(isSafeRecordingName('shell.ps1'), false);
});

test('Dashboard server end-to-end: auth, CSRF, recordings Range/download/delete, IPC, and WHEP proxy', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'micstream-dash-'));
  const yamlPath = path.join(tmpDir, 'mediamtx.yml');
  const recordingsDir = path.join(tmpDir, 'recordings');
  const ipcDir = path.join(tmpDir, 'ipc');
  fs.mkdirSync(recordingsDir, { recursive: true });
  fs.mkdirSync(ipcDir, { recursive: true });

  const passHash = computeMediaMtxSha256('TestSecret_2026!');
  fs.writeFileSync(
    yamlPath,
    [
      'authMethod: internal',
      'authInternalUsers:',
      '  - user: any',
      "    pass: ''",
      "    ips: ['127.0.0.1', '::1']",
      '    permissions:',
      '      - action: publish',
      '        path: mic',
      '  - user: admin',
      `    pass: '${passHash}'`,
      '    ips: []',
      '    permissions:',
      '      - action: read',
      '        path: mic',
    ].join('\n'),
    'utf8'
  );

  assert.equal(verifyCredentials(yamlPath, 'admin', 'TestSecret_2026!'), true);
  assert.equal(verifyCredentials(yamlPath, 'admin', 'wrong'), false);
  assert.equal(verifyCredentials(yamlPath, 'any', ''), false);

  // Seed a sample MP3 file for recordings API tests
  const sampleMp3 = Buffer.from('ID3_FAKE_MP3_PAYLOAD_0123456789ABCDEF');
  fs.writeFileSync(path.join(recordingsDir, 'mic_2026-11-24_00-10-00.mp3'), sampleMp3);

  // Mock MediaMTX WHEP upstream verifying Basic Auth injection & Link/Location forwarding
  const mockMtx = http.createServer((req, res) => {
    const expectedAuth = 'Basic ' + Buffer.from('admin:TestSecret_2026!').toString('base64');
    if (req.headers.authorization !== expectedAuth) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="mediamtx"' });
      return res.end();
    }
    if (req.method === 'OPTIONS' && req.url === '/mic/whep') {
      res.writeHead(204, {
        Link: '<turn:152.53.146.113:3478>; rel="ice-server"; username="1795:user"; credential="hmac123"; credential-type="password"',
      });
      return res.end();
    }
    if (req.method === 'POST' && req.url === '/mic/whep') {
      res.writeHead(201, {
        'Content-Type': 'application/sdp',
        Location: '/mic/whep/sess-42',
        ETag: '"etag-1"',
      });
      return res.end('v=0\r\ns=mock-answer\r\n');
    }
    res.writeHead(404);
    res.end();
  });

  const mtxPort = await listen(mockMtx);
  const app = createAppServer({
    repoRoot: tmpDir,
    publicDir: path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), 'public'),
    yamlPath,
    recordingsDir,
    ipcDir,
    mediamtxPort: mtxPort,
    streamPath: 'mic',
    ipcTimeoutMs: 3000,
  });
  const port = await listen(app);
  const baseUrl = `http://127.0.0.1:${port}`;

  // Background mock tray IPC responder
  const ipcWatcher = setInterval(() => {
    const files = fs.readdirSync(ipcDir).filter((f) => f.startsWith('cmd_') && f.endsWith('.json'));
    for (const f of files) {
      const full = path.join(ipcDir, f);
      const cmd = JSON.parse(fs.readFileSync(full, 'utf8'));
      fs.unlinkSync(full);
      fs.writeFileSync(
        path.join(ipcDir, 'state.json'),
        JSON.stringify({
          streamState: 'LIVE',
          isRecording: cmd.action === 'start_record',
          recAutoStopMinutes: cmd.payload?.autoStopMinutes || 0,
          noiseReduction: cmd.action === 'set_noise_reduction' ? cmd.payload?.mode : 'off',
          opusApplication: cmd.action === 'set_opus_mode' ? cmd.payload?.application : 'lowdelay',
        })
      );
      fs.writeFileSync(path.join(ipcDir, `res_${cmd.id}.json`), JSON.stringify({ ok: true }));
    }
  }, 40);

  try {
    // 1. Both / and /mic serve the dashboard HTML
    const homeRes = await fetch(`${baseUrl}/mic`);
    assert.equal(homeRes.status, 200);
    const html = await homeRes.text();
    assert.match(html, /MICSTREAM/);

    // 2. Unauthenticated API rejected
    const unauthStatus = await fetch(`${baseUrl}/api/status`);
    assert.equal(unauthStatus.status, 401);

    // 3. Missing CSRF header rejected on POST /api/login
    const noCsrf = await fetch(`${baseUrl}/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'TestSecret_2026!' }),
    });
    assert.equal(noCsrf.status, 403);

    // 4. Valid login returns HttpOnly session cookie
    const loginRes = await fetch(`${baseUrl}/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'MicStream' },
      body: JSON.stringify({ username: 'admin', password: 'TestSecret_2026!' }),
    });
    assert.equal(loginRes.status, 200);
    const setCookie = loginRes.headers.get('set-cookie');
    assert.match(setCookie, /micstream_sid=/);
    assert.match(setCookie, /HttpOnly/);
    const cookie = setCookie.split(';')[0];

    // 5. WHEP OPTIONS forwards Link header with coturn credentials
    const optRes = await fetch(`${baseUrl}/api/whep`, {
      method: 'OPTIONS',
      headers: { Cookie: cookie },
    });
    assert.equal(optRes.status, 204);
    assert.match(optRes.headers.get('link') || '', /turn:152\.53\.146\.113:3478/);

    // 6. WHEP POST proxies SDP & rewrites Location header
    const postRes = await fetch(`${baseUrl}/api/whep`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/sdp' },
      body: 'v=0\r\ns=mock-offer\r\n',
    });
    assert.equal(postRes.status, 201);
    assert.equal(postRes.headers.get('location'), '/api/whep/sess-42');
    assert.match(await postRes.text(), /mock-answer/);

    // 7. IPC remote start recording with autoStopMinutes=15 round-trip
    const recRes = await fetch(`${baseUrl}/api/record/start`, {
      method: 'POST',
      headers: {
        Cookie: cookie,
        'Content-Type': 'application/json',
        'X-Requested-With': 'MicStream',
      },
      body: JSON.stringify({ autoStopMinutes: 15 }),
    });
    assert.equal(recRes.status, 200);
    const recJson = await recRes.json();
    assert.equal(recJson.ok, true);
    assert.equal(recJson.state.isRecording, true);
    assert.equal(recJson.state.recAutoStopMinutes, 15);

    // 7b. Optional Noise Reduction & Opus VoIP endpoints validate & round-trip via IPC
    const badNoise = await fetch(`${baseUrl}/api/audio/noise`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json', 'X-Requested-With': 'MicStream' },
      body: JSON.stringify({ mode: 'invalid_mode' }),
    });
    assert.equal(badNoise.status, 400);

    const goodNoise = await fetch(`${baseUrl}/api/audio/noise`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json', 'X-Requested-With': 'MicStream' },
      body: JSON.stringify({ mode: 'voice_ai' }),
    });
    assert.equal(goodNoise.status, 200);
    assert.equal((await goodNoise.json()).state.noiseReduction, 'voice_ai');

    const opusRes = await fetch(`${baseUrl}/api/audio/opus`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json', 'X-Requested-With': 'MicStream' },
      body: JSON.stringify({ application: 'voip' }),
    });
    assert.equal(opusRes.status, 200);
    assert.equal((await opusRes.json()).state.opusApplication, 'voip');

    // 8. Recordings list + HTTP 206 Range + download header + delete
    const listRes = await fetch(`${baseUrl}/api/recordings`, { headers: { Cookie: cookie } });
    assert.equal(listRes.status, 200);
    const listData = await listRes.json();
    assert.equal(listData.recordings.length, 1);

    const rangeRes = await fetch(`${baseUrl}/api/recordings/mic_2026-11-24_00-10-00.mp3`, {
      headers: { Cookie: cookie, Range: 'bytes=0-9' },
    });
    assert.equal(rangeRes.status, 206);
    assert.equal(rangeRes.headers.get('content-range'), `bytes 0-9/${sampleMp3.length}`);
    assert.equal((await rangeRes.text()).length, 10);

    const dlRes = await fetch(`${baseUrl}/api/recordings/mic_2026-11-24_00-10-00.mp3?download=1`, {
      headers: { Cookie: cookie },
    });
    assert.equal(dlRes.status, 200);
    assert.match(dlRes.headers.get('content-disposition') || '', /attachment/);

    const delRes = await fetch(`${baseUrl}/api/recordings/mic_2026-11-24_00-10-00.mp3`, {
      method: 'DELETE',
      headers: { Cookie: cookie, 'X-Requested-With': 'MicStream' },
    });
    assert.equal(delRes.status, 200);
    assert.equal(fs.existsSync(path.join(recordingsDir, 'mic_2026-11-24_00-10-00.mp3')), false);
  } finally {
    clearInterval(ipcWatcher);
    await closeServer(app);
    await closeServer(mockMtx);
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

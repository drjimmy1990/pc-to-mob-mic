(() => {
  'use strict';

  const CSRF_HEADER = { 'X-Requested-With': 'MicStream' };

  const el = {
    loginView: document.getElementById('loginView'),
    consoleView: document.getElementById('consoleView'),
    loginForm: document.getElementById('loginForm'),
    loginUser: document.getElementById('loginUser'),
    loginPass: document.getElementById('loginPass'),
    loginError: document.getElementById('loginError'),
    loginBtn: document.getElementById('loginBtn'),

    masterLed: document.getElementById('masterLed'),
    hostSubtitle: document.getElementById('hostSubtitle'),
    iceBadge: document.getElementById('iceBadge'),
    btnLogout: document.getElementById('btnLogout'),

    streamStatePill: document.getElementById('streamStatePill'),
    linkStatusText: document.getElementById('linkStatusText'),
    dbReadout: document.getElementById('dbReadout'),
    vuCanvas: document.getElementById('vuCanvas'),
    recOledStatus: document.getElementById('recOledStatus'),
    liveAudio: document.getElementById('liveAudio'),

    btnListen: document.getElementById('btnListen'),
    btnListenLabel: document.getElementById('btnListenLabel'),
    btnHostStream: document.getElementById('btnHostStream'),
    btnHostStreamLabel: document.getElementById('btnHostStreamLabel'),
    btnMute: document.getElementById('btnMute'),
    btnReconnect: document.getElementById('btnReconnect'),
    gainSlider: document.getElementById('gainSlider'),
    gainValue: document.getElementById('gainValue'),

    recTimerChip: document.getElementById('recTimerChip'),
    btnRecord: document.getElementById('btnRecord'),
    btnRecordLabel: document.getElementById('btnRecordLabel'),
    autoStopSummary: document.getElementById('autoStopSummary'),
    autoStopPills: document.getElementById('autoStopPills'),
    customMinWrap: document.getElementById('customMinWrap'),
    customMinutesInput: document.getElementById('customMinutesInput'),
    btnApplyCustomMin: document.getElementById('btnApplyCustomMin'),

    daemonPill: document.getElementById('daemonPill'),
    btnBoostToggle: document.getElementById('btnBoostToggle'),
    micSelect: document.getElementById('micSelect'),

    vaultMeta: document.getElementById('vaultMeta'),
    btnRefreshVault: document.getElementById('btnRefreshVault'),
    vaultPlayerBar: document.getElementById('vaultPlayerBar'),
    vaultPlayingName: document.getElementById('vaultPlayingName'),
    vaultAudio: document.getElementById('vaultAudio'),
    btnCloseVaultPlayer: document.getElementById('btnCloseVaultPlayer'),
    recordingsList: document.getElementById('recordingsList'),
    toast: document.getElementById('toast'),
  };

  let appState = null;
  let statusPollHandle = null;
  let clockTickHandle = null;
  let toastHandle = null;
  let selectedAutoStopMinutes = 0;
  let prevWasRecording = false;
  let deleteConfirmTarget = null;
  let deleteConfirmTimer = null;

  // WebRTC & Web Audio runtime
  let pc = null;
  let whepResourceUrl = null;
  let isListening = false;
  let isMuted = false;
  let audioCtx = null;
  let gainNode = null;
  let analyserNode = null;
  let mediaSourceNode = null;
  let useWebAudioGain = false;
  let vuRafId = null;
  let vuPeaks = new Float32Array(36);

  function showToast(msg, durationMs = 2800) {
    el.toast.textContent = msg;
    el.toast.classList.remove('hidden');
    clearTimeout(toastHandle);
    toastHandle = setTimeout(() => el.toast.classList.add('hidden'), durationMs);
  }

  async function apiFetch(url, options = {}) {
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== 'GET' && options.method !== 'HEAD') {
      Object.assign(headers, CSRF_HEADER);
    }
    const res = await fetch(url, { credentials: 'same-origin', ...options, headers });
    if (res.status === 401 && url !== '/api/login' && url !== '/api/auth/me') {
      enterLoginView();
      throw new Error('Session expired');
    }
    return res;
  }

  function formatHms(totalSeconds) {
    const s = Math.max(0, Math.floor(totalSeconds));
    const hrs = Math.floor(s / 3600);
    const mins = Math.floor((s % 3600) / 60);
    const secs = s % 60;
    return [hrs, mins, secs].map((n) => String(n).padStart(2, '0')).join(':');
  }

  function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
  }

  // Parse RFC 8288 Link headers returned by MediaMTX WHEP for STUN/TURN servers
  function parseIceServersFromLinks(linkHeader) {
    const servers = [];
    if (!linkHeader) return servers;
    // Split on comma followed by '<'
    const parts = linkHeader.split(/,\s*(?=<)/);
    for (const part of parts) {
      if (!/rel="?ice-server"?/i.test(part)) continue;
      const urlMatch = part.match(/<([^>]+)>/);
      if (!urlMatch) continue;
      const server = { urls: urlMatch[1] };
      const userMatch = part.match(/username="([^"]*)"/i);
      const credMatch = part.match(/credential="([^"]*)"/i);
      if (userMatch) server.username = userMatch[1];
      if (credMatch) server.credential = credMatch[1];
      servers.push(server);
    }
    return servers;
  }

  // ==================== WEB AUDIO VU METER & GAIN ====================
  function drawVuIdle() {
    const canvas = el.vuCanvas;
    const ctx = canvas.getContext('2d');
    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);

    const bars = vuPeaks.length;
    const gap = 4;
    const barW = (w - gap * (bars + 1)) / bars;

    for (let i = 0; i < bars; i++) {
      vuPeaks[i] *= 0.88;
      const x = gap + i * (barW + gap);
      const bh = Math.max(3, vuPeaks[i] * (h - 16));
      ctx.fillStyle = '#18241C';
      ctx.fillRect(x, h - 8 - bh, barW, bh);
    }
  }

  function startVuLoop() {
    if (vuRafId) cancelAnimationFrame(vuRafId);
    const canvas = el.vuCanvas;
    const ctx = canvas.getContext('2d');
    const freqData = analyserNode ? new Uint8Array(analyserNode.frequencyBinCount) : null;
    const timeData = analyserNode ? new Uint8Array(analyserNode.fftSize) : null;

    const render = () => {
      const w = canvas.width;
      const h = canvas.height;
      ctx.clearRect(0, 0, w, h);

      const bars = vuPeaks.length;
      const gap = 4;
      const barW = (w - gap * (bars + 1)) / bars;

      if (analyserNode && isListening && !isMuted) {
        analyserNode.getByteFrequencyData(freqData);
        analyserNode.getByteTimeDomainData(timeData);

        // Compute RMS dBFS
        let sumSq = 0;
        for (let i = 0; i < timeData.length; i++) {
          const norm = (timeData[i] - 128) / 128;
          sumSq += norm * norm;
        }
        const rms = Math.sqrt(sumSq / timeData.length);
        const db = rms > 0.0001 ? Math.max(-60, 20 * Math.log10(rms)) : -60;
        el.dbReadout.textContent = db <= -59 ? '-∞ dB' : `${db.toFixed(1)} dB`;

        const usableBins = Math.min(freqData.length, 96);
        const step = Math.max(1, Math.floor(usableBins / bars));

        for (let i = 0; i < bars; i++) {
          let sum = 0;
          for (let j = 0; j < step; j++) sum += freqData[i * step + j] || 0;
          const level = Math.min(1, (sum / step) / 215);
          vuPeaks[i] = Math.max(level, vuPeaks[i] * 0.86);

          const x = gap + i * (barW + gap);
          const bh = Math.max(4, level * (h - 14));
          const y = h - 7 - bh;

          if (level > 0.82) ctx.fillStyle = '#FF3B30';
          else if (level > 0.62) ctx.fillStyle = '#FFB020';
          else ctx.fillStyle = '#2CE68B';
          ctx.fillRect(x, y, barW, bh);

          // Peak hold cap
          const py = h - 7 - Math.max(4, vuPeaks[i] * (h - 14));
          ctx.fillStyle = 'rgba(236, 239, 233, 0.72)';
          ctx.fillRect(x, py - 2, barW, 2);
        }
      } else {
        el.dbReadout.textContent = isMuted ? 'MUTED' : '-∞ dB';
        drawVuIdle();
      }

      vuRafId = requestAnimationFrame(render);
    };
    vuRafId = requestAnimationFrame(render);
  }

  function applyGainSettings() {
    const pct = Number(el.gainSlider.value);
    el.gainValue.textContent = `${pct}%`;
    const gainScalar = isMuted ? 0 : pct / 100;

    if (useWebAudioGain && gainNode && audioCtx) {
      gainNode.gain.setTargetAtTime(gainScalar, audioCtx.currentTime, 0.02);
      el.liveAudio.muted = true;
    } else {
      el.liveAudio.muted = isMuted;
      el.liveAudio.volume = Math.min(1, gainScalar);
    }

    el.btnMute.classList.toggle('active-warn', isMuted);
    el.btnMute.setAttribute('aria-pressed', String(isMuted));
    el.btnMute.textContent = isMuted ? 'UNMUTE' : 'MUTE';
  }

  function attachStreamToAudioPipeline(remoteStream) {
    el.liveAudio.srcObject = remoteStream;
    el.liveAudio.play().catch(() => {});

    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) throw new Error('No AudioContext');
      if (!audioCtx) audioCtx = new AC();
      if (audioCtx.state === 'suspended') audioCtx.resume().catch(() => {});

      if (mediaSourceNode) {
        try { mediaSourceNode.disconnect(); } catch {}
      }
      mediaSourceNode = audioCtx.createMediaStreamSource(remoteStream);
      gainNode = audioCtx.createGain();
      analyserNode = audioCtx.createAnalyser();
      analyserNode.fftSize = 256;
      analyserNode.smoothingTimeConstant = 0.72;

      mediaSourceNode.connect(gainNode);
      gainNode.connect(analyserNode);
      analyserNode.connect(audioCtx.destination);
      useWebAudioGain = true;
    } catch {
      useWebAudioGain = false;
      el.liveAudio.muted = isMuted;
    }
    applyGainSettings();
  }

  // ==================== WHEP WEBRTC CONNECTION ====================
  async function disconnectWhep(quiet = false) {
    isListening = false;
    const oldRes = whepResourceUrl;
    whepResourceUrl = null;

    if (pc) {
      try { pc.close(); } catch {}
      pc = null;
    }
    if (mediaSourceNode) {
      try { mediaSourceNode.disconnect(); } catch {}
      mediaSourceNode = null;
    }
    el.liveAudio.srcObject = null;

    if (oldRes) {
      apiFetch(oldRes, { method: 'DELETE' }).catch(() => {});
    }

    el.btnListen.classList.remove('listening');
    el.btnListenLabel.textContent = 'TAP TO LISTEN';
    el.linkStatusText.textContent = 'DISCONNECTED';
    el.iceBadge.textContent = 'STANDBY';
    if (!quiet) showToast('Monitor disconnected');
  }

  async function connectWhep() {
    // Prepare AudioContext synchronously inside user click gesture (iOS Safari requirement)
    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (AC) {
        if (!audioCtx) audioCtx = new AC();
        if (audioCtx.state === 'suspended') await audioCtx.resume();
      }
    } catch {}

    // If laptop mic is currently OFF, turn it ON automatically first!
    if (!appState || appState.streamState !== 'LIVE') {
      el.linkStatusText.textContent = 'WAKING LAPTOP MIC...';
      el.btnListen.disabled = true;
      try {
        const res = await apiFetch('/api/stream/start', { method: 'POST' });
        const data = await res.json();
        if (!res.ok || data.ok === false) {
          throw new Error(data.error || 'Could not start laptop stream');
        }
        if (data.state) applyStatus(data.state);
      } catch (err) {
        el.btnListen.disabled = false;
        el.linkStatusText.textContent = 'HOST START FAILED';
        showToast(err.message);
        return;
      } finally {
        el.btnListen.disabled = false;
      }
    }

    await disconnectWhep(true);
    el.linkStatusText.textContent = 'NEGOTIATING ICE...';
    el.iceBadge.textContent = 'CONNECTING';
    el.btnListen.disabled = true;

    try {
      // 1. OPTIONS /api/whep to retrieve MediaMTX dynamic coturn ICE servers
      let iceServers = [];
      try {
        const optRes = await apiFetch('/api/whep', { method: 'OPTIONS' });
        const linkHdr = optRes.headers.get('Link');
        iceServers = parseIceServersFromLinks(linkHdr);
      } catch {}

      pc = new RTCPeerConnection({
        iceServers,
        bundlePolicy: 'max-bundle',
      });

      const pendingCandidates = [];
      let whepEtag = '*';
      let offerUfrag = '';
      let offerPwd = '';

      pc.onicecandidate = (ev) => {
        if (!ev.candidate) return;
        const candStr = ev.candidate.candidate;
        if (!candStr) return;
        if (!whepResourceUrl) {
          pendingCandidates.push(candStr);
          return;
        }
        sendTrickleCandidate(whepResourceUrl, whepEtag, offerUfrag, offerPwd, [candStr]);
      };

      pc.oniceconnectionstatechange = () => {
        if (!pc) return;
        const st = pc.iceConnectionState;
        el.iceBadge.textContent = `ICE:${st.toUpperCase()}`;
        if (st === 'connected' || st === 'completed') {
          el.linkStatusText.textContent = 'LIVE AUDIO STREAM';
        } else if (st === 'failed' || st === 'disconnected') {
          el.linkStatusText.textContent = 'LINK INTERRUPTED';
        }
      };

      pc.ontrack = (ev) => {
        const stream = ev.streams && ev.streams[0] ? ev.streams[0] : new MediaStream([ev.track]);
        attachStreamToAudioPipeline(stream);
      };

      pc.addTransceiver('audio', { direction: 'recvonly' });
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      const ufragM = offer.sdp.match(/a=ice-ufrag:([^\r\n]+)/);
      const pwdM = offer.sdp.match(/a=ice-pwd:([^\r\n]+)/);
      offerUfrag = ufragM ? ufragM[1] : '';
      offerPwd = pwdM ? pwdM[1] : '';

      const postRes = await apiFetch('/api/whep', {
        method: 'POST',
        headers: { 'Content-Type': 'application/sdp' },
        body: offer.sdp,
      });

      if (!postRes.ok) {
        let errMsg = `WHEP error (${postRes.status})`;
        try {
          const j = await postRes.json();
          if (j.error) errMsg = j.error;
        } catch {}
        throw new Error(errMsg);
      }

      const answerSdp = await postRes.text();
      whepResourceUrl = postRes.headers.get('Location');
      whepEtag = postRes.headers.get('ETag') || '*';

      await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });

      if (whepResourceUrl && pendingCandidates.length > 0) {
        sendTrickleCandidate(whepResourceUrl, whepEtag, offerUfrag, offerPwd, pendingCandidates.splice(0));
      }

      isListening = true;
      el.btnListen.classList.add('listening');
      el.btnListenLabel.textContent = 'STOP LISTENING';
      el.linkStatusText.textContent = 'CONNECTING MEDIA...';
    } catch (err) {
      await disconnectWhep(true);
      el.linkStatusText.textContent = 'ERROR';
      showToast(err.message || 'WebRTC connection failed', 4000);
    } finally {
      el.btnListen.disabled = false;
    }
  }

  function sendTrickleCandidate(resourceUrl, etag, ufrag, pwd, candidates) {
    if (!resourceUrl || !ufrag || !pwd || !candidates.length) return;
    const lines = [
      `a=ice-ufrag:${ufrag}`,
      `a=ice-pwd:${pwd}`,
      'm=audio 9 RTP/SAVPF 0',
      'a=mid:0',
      ...candidates.map((c) => `a=${c}`),
      '',
    ];
    apiFetch(resourceUrl, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/trickle-ice-sdpfrag',
        'If-Match': etag || '*',
      },
      body: lines.join('\r\n'),
    }).catch(() => {});
  }

  // ==================== STATUS & UI SYNC ====================
  function setActiveAutoStopUi(minutes) {
    selectedAutoStopMinutes = minutes;
    const presetValues = [0, 5, 10, 15, 30, 60, 120];
    const isPreset = presetValues.includes(minutes);
    const pills = el.autoStopPills.querySelectorAll('.pill-btn');
    pills.forEach((btn) => {
      const val = btn.dataset.min;
      if (isPreset) {
        btn.classList.toggle('active', Number(val) === minutes);
      } else {
        btn.classList.toggle('active', val === 'custom');
      }
    });
    if (!isPreset && minutes > 0) {
      el.customMinutesInput.value = String(minutes);
      el.customMinWrap.classList.remove('hidden');
    }
    el.autoStopSummary.textContent = minutes > 0 ? `${minutes} MIN` : 'MANUAL';
  }

  function updateLiveRecClock() {
    if (!appState || !appState.isRecording || !appState.recStartTimeUtc) {
      el.recTimerChip.textContent = 'IDLE';
      el.recTimerChip.className = 'state-chip chip-off';
      el.recOledStatus.textContent = 'REC IDLE';
      el.recOledStatus.className = 'rec-oled-idle';
      return;
    }
    const startMs = Date.parse(appState.recStartTimeUtc);
    const elapsedSec = Math.max(0, (Date.now() - startMs) / 1000);
    const limitMin = Number(appState.recActiveLimitMinutes || 0);
    if (limitMin > 0) {
      const remSec = Math.max(0, limitMin * 60 - elapsedSec);
      const txt = `${formatHms(elapsedSec)} · ${formatHms(remSec)} LEFT`;
      el.recTimerChip.textContent = txt;
      el.recOledStatus.textContent = `● REC ${formatHms(remSec)} LEFT`;
    } else {
      const txt = `REC ${formatHms(elapsedSec)}`;
      el.recTimerChip.textContent = txt;
      el.recOledStatus.textContent = `● ${txt}`;
    }
    el.recTimerChip.className = 'state-chip chip-rec';
    el.recOledStatus.className = 'rec-oled-active';
  }

  function applyStatus(state) {
    appState = state;
    const streamLive = state.streamState === 'LIVE';
    const isRec = Boolean(state.isRecording);

    // Master LED
    if (isRec) el.masterLed.className = 'status-led led-rec';
    else if (streamLive) el.masterLed.className = 'status-led led-live';
    else if (state.streamState === 'Starting' || state.streamState === 'Recovering') el.masterLed.className = 'status-led led-warn';
    else el.masterLed.className = 'status-led led-idle';

    // Stream pill & host button
    if (streamLive) {
      el.streamStatePill.textContent = 'HOST LIVE';
      el.streamStatePill.className = 'state-chip chip-live';
      el.btnHostStream.classList.add('host-live');
      el.btnHostStreamLabel.textContent = 'STOP HOST MIC';
    } else if (state.streamState === 'Starting' || state.streamState === 'Recovering') {
      el.streamStatePill.textContent = state.streamState.toUpperCase();
      el.streamStatePill.className = 'state-chip chip-warn';
      el.btnHostStream.classList.remove('host-live');
      el.btnHostStreamLabel.textContent = 'STARTING...';
    } else {
      el.streamStatePill.textContent = 'HOST OFF';
      el.streamStatePill.className = 'state-chip chip-off';
      el.btnHostStream.classList.remove('host-live');
      el.btnHostStreamLabel.textContent = 'TURN HOST MIC ON';
      if (isListening) disconnectWhep(true);
    }

    // Recording button & pills lock while recording
    el.btnRecord.classList.toggle('recording', isRec);
    el.btnRecordLabel.textContent = isRec ? 'STOP RECORDING' : 'START RECORDING';
    el.autoStopPills.querySelectorAll('.pill-btn').forEach((b) => { b.disabled = isRec; });
    el.customMinutesInput.disabled = isRec;
    el.btnApplyCustomMin.disabled = isRec;

    if (!isRec && typeof state.recAutoStopMinutes === 'number' && !el.customMinWrap.classList.contains('user-editing')) {
      setActiveAutoStopUi(state.recAutoStopMinutes);
    }

    // Auto-refresh vault whenever a recording finishes
    if (prevWasRecording && !isRec) {
      loadRecordings();
      showToast('Recording saved to laptop vault');
    }
    prevWasRecording = isRec;

    // Daemon sync pill
    el.daemonPill.textContent = state.daemonConnected ? 'LAPTOP SYNCED' : 'TRAY OFFLINE';
    el.daemonPill.className = state.daemonConnected ? 'state-chip chip-live' : 'state-chip chip-warn';

    // Ambient Boost switch
    el.btnBoostToggle.setAttribute('aria-checked', String(Boolean(state.ambientBoost)));

    // Microphone dropdown (only rebuild if list changed)
    const mics = Array.isArray(state.microphones) && state.microphones.length
      ? state.microphones
      : (state.microphoneName ? [state.microphoneName] : []);
    const sig = mics.join('||');
    if (el.micSelect.dataset.sig !== sig) {
      el.micSelect.dataset.sig = sig;
      el.micSelect.innerHTML = '';
      for (const m of mics) {
        const opt = document.createElement('option');
        opt.value = m;
        opt.textContent = m;
        el.micSelect.appendChild(opt);
      }
    }
    if (state.microphoneName && el.micSelect.value !== state.microphoneName) {
      el.micSelect.value = state.microphoneName;
    }

    updateLiveRecClock();
  }

  async function pollStatus() {
    try {
      const res = await apiFetch('/api/status');
      if (!res.ok) return;
      const data = await res.json();
      applyStatus(data);
    } catch {}
  }

  // ==================== RECORDINGS VAULT ====================
  async function loadRecordings() {
    try {
      const res = await apiFetch('/api/recordings');
      if (!res.ok) return;
      const data = await res.json();
      const list = data.recordings || [];

      const totalBytes = list.reduce((acc, item) => acc + (item.sizeBytes || 0), 0);
      el.vaultMeta.textContent = `${list.length} FILE${list.length === 1 ? '' : 'S'} · ${formatBytes(totalBytes)}`;

      if (list.length === 0) {
        el.recordingsList.innerHTML = '<div class="empty-vault">No recordings yet. Press START RECORDING above to capture an MP3 on your laptop.</div>';
        return;
      }

      el.recordingsList.innerHTML = '';
      for (const item of list) {
        const card = document.createElement('div');
        card.className = 'rec-item';

        const top = document.createElement('div');
        top.className = 'rec-item-top';

        const nameSpan = document.createElement('span');
        nameSpan.className = 'rec-name';
        nameSpan.textContent = item.name;

        const sizeSpan = document.createElement('span');
        sizeSpan.className = 'rec-size';
        sizeSpan.textContent = formatBytes(item.sizeBytes);

        top.append(nameSpan, sizeSpan);

        const actions = document.createElement('div');
        actions.className = 'rec-actions';

        const encoded = encodeURIComponent(item.name);

        const btnPlay = document.createElement('button');
        btnPlay.type = 'button';
        btnPlay.className = 'btn-play-rec';
        btnPlay.textContent = 'PLAY';
        btnPlay.addEventListener('click', () => {
          el.vaultPlayingName.textContent = item.name;
          el.vaultPlayerBar.classList.remove('hidden');
          el.vaultAudio.src = `/api/recordings/${encoded}`;
          el.vaultAudio.play().catch(() => {});
        });

        const dlLink = document.createElement('a');
        dlLink.href = `/api/recordings/${encoded}?download=1`;
        dlLink.download = item.name;
        dlLink.textContent = 'DOWNLOAD';

        const btnDel = document.createElement('button');
        btnDel.type = 'button';
        btnDel.className = 'btn-del-rec';
        btnDel.textContent = 'DELETE';
        btnDel.addEventListener('click', async () => {
          if (deleteConfirmTarget !== item.name) {
            deleteConfirmTarget = item.name;
            btnDel.textContent = 'CONFIRM?';
            btnDel.classList.add('confirming');
            clearTimeout(deleteConfirmTimer);
            deleteConfirmTimer = setTimeout(() => {
              deleteConfirmTarget = null;
              btnDel.textContent = 'DELETE';
              btnDel.classList.remove('confirming');
            }, 3500);
            return;
          }
          deleteConfirmTarget = null;
          clearTimeout(deleteConfirmTimer);
          btnDel.disabled = true;
          try {
            const delRes = await apiFetch(`/api/recordings/${encoded}`, { method: 'DELETE' });
            const delData = await delRes.json();
            if (!delRes.ok) throw new Error(delData.error || 'Delete failed');
            if (el.vaultPlayingName.textContent === item.name) {
              el.vaultAudio.pause();
              el.vaultAudio.src = '';
              el.vaultPlayerBar.classList.add('hidden');
            }
            showToast(`Deleted ${item.name}`);
            loadRecordings();
          } catch (err) {
            showToast(err.message);
            btnDel.disabled = false;
          }
        });

        actions.append(btnPlay, dlLink, btnDel);
        card.append(top, actions);
        el.recordingsList.appendChild(card);
      }
    } catch {}
  }

  // ==================== VIEW SWITCHING & EVENTS ====================
  function enterLoginView() {
    disconnectWhep(true);
    clearInterval(statusPollHandle);
    clearInterval(clockTickHandle);
    if (vuRafId) cancelAnimationFrame(vuRafId);
    el.consoleView.classList.add('hidden');
    el.loginView.classList.remove('hidden');
    el.loginPass.value = '';
    el.loginPass.focus();
  }

  async function enterConsoleView() {
    el.loginView.classList.add('hidden');
    el.consoleView.classList.remove('hidden');
    el.hostSubtitle.textContent = window.location.host.toUpperCase();
    startVuLoop();
    await Promise.all([pollStatus(), loadRecordings()]);
    clearInterval(statusPollHandle);
    clearInterval(clockTickHandle);
    statusPollHandle = setInterval(pollStatus, 2500);
    clockTickHandle = setInterval(updateLiveRecClock, 1000);
  }

  el.loginForm.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    el.loginError.classList.add('hidden');
    el.loginBtn.disabled = true;
    try {
      const res = await apiFetch('/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: el.loginUser.value.trim(),
          password: el.loginPass.value,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        el.loginError.textContent = data.error || 'Login failed';
        el.loginError.classList.remove('hidden');
        return;
      }
      enterConsoleView();
    } catch {
      el.loginError.textContent = 'Unable to reach dashboard server.';
      el.loginError.classList.remove('hidden');
    } finally {
      el.loginBtn.disabled = false;
    }
  });

  el.btnLogout.addEventListener('click', async () => {
    await apiFetch('/api/logout', { method: 'POST' }).catch(() => {});
    enterLoginView();
  });

  el.btnListen.addEventListener('click', () => {
    if (isListening) disconnectWhep();
    else connectWhep();
  });

  el.btnReconnect.addEventListener('click', () => {
    if (isListening || (appState && appState.streamState === 'LIVE')) {
      connectWhep();
    } else {
      pollStatus();
      showToast('Status refreshed');
    }
  });

  el.btnMute.addEventListener('click', () => {
    isMuted = !isMuted;
    applyGainSettings();
  });

  el.gainSlider.addEventListener('input', () => {
    if (isMuted && Number(el.gainSlider.value) > 0) isMuted = false;
    applyGainSettings();
  });

  el.btnHostStream.addEventListener('click', async () => {
    const isLive = appState && appState.streamState === 'LIVE';
    el.btnHostStream.disabled = true;
    try {
      if (isLive && isListening) await disconnectWhep(true);
      const endpoint = isLive ? '/api/stream/stop' : '/api/stream/start';
      const res = await apiFetch(endpoint, { method: 'POST' });
      const data = await res.json();
      if (!res.ok || data.ok === false) throw new Error(data.error || 'Command failed');
      if (data.state) applyStatus(data.state);
      showToast(isLive ? 'Laptop microphone stopped' : 'Laptop microphone is LIVE');
    } catch (err) {
      showToast(err.message);
    } finally {
      el.btnHostStream.disabled = false;
    }
  });

  el.btnRecord.addEventListener('click', async () => {
    const isRec = appState && appState.isRecording;
    el.btnRecord.disabled = true;
    try {
      const res = isRec
        ? await apiFetch('/api/record/stop', { method: 'POST' })
        : await apiFetch('/api/record/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ autoStopMinutes: selectedAutoStopMinutes }),
          });
      const data = await res.json();
      if (!res.ok || data.ok === false) throw new Error(data.error || 'Recording command failed');
      if (data.state) applyStatus(data.state);
      if (isRec) {
        loadRecordings();
        showToast('Recording stopped & saved');
      } else {
        showToast(selectedAutoStopMinutes > 0
          ? `Recording started (auto-stop ${selectedAutoStopMinutes}m)`
          : 'Recording started (manual stop)');
      }
    } catch (err) {
      showToast(err.message);
    } finally {
      el.btnRecord.disabled = false;
    }
  });

  el.autoStopPills.addEventListener('click', async (ev) => {
    const btn = ev.target.closest('.pill-btn');
    if (!btn || btn.disabled) return;
    const raw = btn.dataset.min;
    if (raw === 'custom') {
      el.customMinWrap.classList.remove('hidden');
      el.customMinWrap.classList.add('user-editing');
      el.autoStopPills.querySelectorAll('.pill-btn').forEach((b) => b.classList.toggle('active', b === btn));
      el.customMinutesInput.focus();
      return;
    }
    el.customMinWrap.classList.add('hidden');
    el.customMinWrap.classList.remove('user-editing');
    const mins = Number(raw);
    setActiveAutoStopUi(mins);
    try {
      await apiFetch('/api/record/autostop', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ minutes: mins }),
      });
    } catch {}
  });

  el.btnApplyCustomMin.addEventListener('click', async () => {
    let mins = parseInt(el.customMinutesInput.value, 10);
    if (Number.isNaN(mins) || mins < 1) mins = 1;
    if (mins > 1440) mins = 1440;
    el.customMinutesInput.value = String(mins);
    el.customMinWrap.classList.remove('user-editing');
    setActiveAutoStopUi(mins);
    try {
      await apiFetch('/api/record/autostop', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ minutes: mins }),
      });
      showToast(`Auto-stop set to ${mins} minutes`);
    } catch {}
  });

  el.btnBoostToggle.addEventListener('click', async () => {
    const next = el.btnBoostToggle.getAttribute('aria-checked') !== 'true';
    el.btnBoostToggle.disabled = true;
    try {
      const res = await apiFetch('/api/audio/boost', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: next }),
      });
      const data = await res.json();
      if (!res.ok || data.ok === false) throw new Error(data.error || 'Boost toggle failed');
      if (data.state) applyStatus(data.state);
      showToast(`Ambient boost ${next ? 'enabled' : 'disabled'}`);
    } catch (err) {
      showToast(err.message);
    } finally {
      el.btnBoostToggle.disabled = false;
    }
  });

  el.micSelect.addEventListener('change', async () => {
    const selected = el.micSelect.value;
    if (!selected) return;
    try {
      const res = await apiFetch('/api/audio/microphone', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ microphoneName: selected }),
      });
      const data = await res.json();
      if (!res.ok || data.ok === false) throw new Error(data.error || 'Mic switch failed');
      if (data.state) applyStatus(data.state);
      showToast(`Input switched to ${selected}`);
    } catch (err) {
      showToast(err.message);
    }
  });

  el.btnRefreshVault.addEventListener('click', () => {
    loadRecordings();
    showToast('Recordings refreshed');
  });

  el.btnCloseVaultPlayer.addEventListener('click', () => {
    el.vaultAudio.pause();
    el.vaultAudio.src = '';
    el.vaultPlayerBar.classList.add('hidden');
  });

  // Boot check
  (async function init() {
    try {
      const res = await apiFetch('/api/auth/me');
      if (res.ok) {
        enterConsoleView();
        return;
      }
    } catch {}
    enterLoginView();
  })();
})();

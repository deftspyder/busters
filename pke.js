/* Busters: PKE meter.
   Opens from Proton Pack Diagnostics with the PACK | ECU | PKE switch (the pack is always the default), or on its
   own from pke.html (public demo). Crew agnostic: it only uses the crew's short name.
   A phone has no arms, so the meter's arm lights are two bands that run from the centre across the top of the
   screen and spread wider as the signal gets stronger. Under them is the meter's display screen, and under that a
   sweep bar: slide a finger along it to build energy (lights, sound, buzz). LAMP pulses the phone's flashlight
   with the signal where the phone allows it, and flashes the screen where it doesn't.
   Lamp and screen flashes never go faster than about 2.5 a second.
   Everything is simulated; nothing is read from or written to the database.
   window.BustersPKE.mount(ctx, api) -> { tone(audio), destroy() }
     ctx: { S, esc, demo }
     api: { back() (to the pack, optional), ecu() (to the ECU, optional), exit(), sound() -> bool, setSound(on),
            audioCtx (standalone only) } */
(function () {
  const CLS = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];
  const STATE = [[0, 'AMBIENT'], [.18, 'TRACE'], [.36, 'ACTIVE'], [.56, 'STRONG'], [.76, 'SEVERE'], [.92, 'FULL SPECTRUM']];
  const TECH = ['SCAN: BACKGROUND WITHIN LIMITS', 'ANTENNA: GAIN NOMINAL', 'FILTER: VALENCE BAND CLEAN', 'CAL: ZERO POINT HOLDING',
    'SCAN: NO DIRECTIONAL LOCK', 'BATTERY: CELLS OK', 'SCAN: SWEEPING', 'SENSOR: PSYCHOKINETIC BAND QUIET'];
  const LORE = ['DO NOT POINT AT COWORKERS', 'READINGS ARE NOT A DIAGNOSIS', 'COLD SPOTS ARE NOT ALWAYS THE AIR CONDITIONING',
    'IF IT PEGS, CALL FOR A TRAP', 'KEEP AWAY FROM MAGNETS AND SNACKS', 'A QUIET METER IS A GOOD DAY'];
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const rnd = (a, b) => a + Math.random() * (b - a);
  const clock = () => new Date().toLocaleTimeString('en-US', { hour12: false });
  const classOf = l => CLS[clamp(Math.floor(l * 7), 0, 6)];
  const stateOf = l => { let s = STATE[0][1]; for (const [t, n] of STATE) if (l >= t) s = n; return s; };

  const CSS = `
.pke{position:fixed;inset:0;z-index:101;color:#ffd77a;font-family:"Share Tech Mono",ui-monospace,Menlo,monospace;font-size:clamp(11px,1.6vh,15px);
  background:radial-gradient(ellipse at 50% 0%,#2b2b2e,#151517 60%,#0b0b0c);display:flex;flex-direction:column;overflow:hidden;
  -webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
.pke *{box-sizing:border-box}
.pke .ph{display:flex;align-items:center;gap:9px;margin:6px;padding:7px 9px;border-radius:8px;background:#0006;box-shadow:inset 0 0 0 1px #ffffff26}
.pke .pt{min-width:0;flex:1}
.pke .t1{font-size:1.05em;letter-spacing:.12em;color:#fff;text-shadow:0 0 6px #ffb000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pke .t2{font-size:.74em;letter-spacing:.14em;opacity:.8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pke .seg{display:inline-flex;border:1px solid #ffffff55;border-radius:6px;overflow:hidden;background:#0008;flex:0 0 auto}
.pke .seg button{font:inherit;font-size:.72em;letter-spacing:.1em;padding:4px 8px;min-height:28px;background:transparent;color:#ffd77a;border:0;cursor:pointer}
.pke .seg button.on{background:#ffb00033;color:#fff}
.pke .ib{font:inherit;width:32px;height:32px;border-radius:50%;border:1px solid #ffffff55;background:#0008;color:#ffd77a;cursor:pointer;flex:0 0 auto;font-size:.9em}
.pke .ib.on{color:#fff;border-color:#ffb000;box-shadow:0 0 8px #ffb00066}
.pke .wing{display:block;width:100%;height:clamp(64px,13vh,120px);flex:0 0 auto}
.pke .body{flex:1;min-height:0;display:flex;flex-direction:column;gap:8px;padding:0 8px 8px;width:min(560px,100%);margin:0 auto}
.pke .scr{position:relative;flex:1;min-height:150px;background:#030805;border-radius:8px;overflow:hidden;box-shadow:inset 0 2px 14px #000,inset 0 0 0 1px #000,0 0 0 2px #2c2c2f,0 0 0 3px #000}
.pke .scr canvas{position:absolute;inset:0;width:100%;height:100%}
.pke .scr::after{content:"";position:absolute;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,#0000 0 2px,#0005 2px 3px)}
.pke .ro{position:absolute;left:10px;top:8px;right:10px;display:flex;justify-content:space-between;align-items:flex-start;color:#7dffa0;text-shadow:0 0 6px #2bff6a;pointer-events:none;z-index:1}
.pke .ro .big{font-size:3.2em;line-height:1;color:#d8ffe2}
.pke .ro .big small{font-size:.3em;letter-spacing:.14em;margin-left:5px;color:#7dffa0}
.pke .ro .lb{font-size:.74em;letter-spacing:.16em;opacity:.8}
.pke .ro .cl{text-align:right}
.pke .ro .cl b{display:block;font-size:1.9em;font-weight:400;line-height:1.1;color:#d8ffe2}
.pke .st{position:absolute;left:10px;right:10px;bottom:7px;display:flex;justify-content:space-between;font-size:.8em;letter-spacing:.14em;color:#7dffa0;text-shadow:0 0 6px #2bff6a;pointer-events:none;z-index:1}
.pke.hot .ro,.pke.hot .st{color:#ffd24a;text-shadow:0 0 6px #ff9a00}.pke.hot .ro .big,.pke.hot .ro .cl b{color:#fff3c9}
.pke.max .ro,.pke.max .st{color:#ff7a5a;text-shadow:0 0 8px #ff2a1a}.pke.max .ro .big,.pke.max .ro .cl b{color:#fff}
.pke .sw{position:relative;flex:0 0 auto;height:clamp(64px,11vh,96px);border-radius:12px;background:#0a0a0b;box-shadow:inset 0 2px 10px #000,0 0 0 1px #ffffff2e;overflow:hidden;touch-action:none;cursor:ew-resize}
.pke .sw .tk{position:absolute;inset:0;background:repeating-linear-gradient(90deg,#ffffff1c 0 2px,#0000 2px 14px);opacity:.6}
.pke .sw .fill{position:absolute;left:0;top:0;bottom:0;width:0;background:linear-gradient(90deg,#ffb00022,#ffb00088);box-shadow:0 0 18px #ffb000aa}
.pke .sw .fg{position:absolute;top:0;bottom:0;width:90px;margin-left:-45px;left:-200px;background:radial-gradient(ellipse at center,#fff8,#ffb00077 35%,#0000 70%);pointer-events:none}
.pke .sw .tx{position:absolute;inset:0;display:grid;place-items:center;letter-spacing:.22em;font-size:.95em;color:#ffe9b0;text-shadow:0 0 6px #000,0 0 10px #ffb000;pointer-events:none}
.pke .row{display:flex;gap:8px;flex:0 0 auto}
.pke .btn{font:inherit;flex:1;min-height:40px;border-radius:8px;border:1px solid #ffffff44;background:#0009;color:#ffd77a;letter-spacing:.16em;cursor:pointer}
.pke .btn.on{background:#ffb000;color:#140a02;border-color:#ffb000;box-shadow:0 0 14px #ffb000aa}
.pke .log{flex:0 0 auto;height:calc(5 * 1.45em + 14px);font-size:.85em;line-height:1.45;background:#060606;border-radius:6px;padding:7px 9px;overflow:hidden;box-shadow:inset 0 2px 10px #000}
.pke .log div{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pke .log div:nth-child(n+3){opacity:.8}.pke .log div:nth-child(n+5){opacity:.55}
.pke .lc-routine{color:#b98f4a}.pke .lc-boot{color:#ffe9d0;text-shadow:0 0 6px #ff8a00}.pke .lc-advisory{color:#5fe3ff;text-shadow:0 0 6px #35b2e8}
.pke .lc-warn{color:#ffc24a;text-shadow:0 0 6px #ff9a00}.pke .lc-fail{color:#ff5a46;text-shadow:0 0 8px #ff2a1a}.pke .lc-recover{color:#b6ff6a;text-shadow:0 0 6px #7dff3a}
.pke .fl{position:absolute;inset:0;background:#fff;opacity:0;pointer-events:none;z-index:9;transition:opacity .08s}
@media (min-aspect-ratio:1/1) and (max-height:520px){.pke .wing{height:54px}.pke .log{display:none}.pke .scr{min-height:90px}.pke .sw{height:56px}.pke .ro .big{font-size:2.2em}}`;

  function lineClass(t) {
    if (/^PEAK|^SIGNAL: FULL|^WARN/.test(t)) return 'warn';
    if (/^CRITICAL/.test(t)) return 'fail';
    if (/^OK:|SETTLED|^LAMP: ON/.test(t)) return 'recover';
    if (/^(LINK|BOOT)/.test(t)) return 'boot';
    if (LORE.includes(t)) return 'advisory';
    return 'routine';
  }

  window.BustersPKE = { mount(ctx, api) {
    const { S, esc } = ctx;
    if (!document.getElementById('pke-css')) { const s = document.createElement('style'); s.id = 'pke-css'; s.textContent = CSS; document.head.appendChild(s); }
    if (!document.getElementById('pk-font')) { const l = document.createElement('link'); l.id = 'pk-font'; l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap'; document.head.appendChild(l); }
    const short = String((S.crew && S.crew.short) || 'CREW').toUpperCase();
    const buzz = p => { try { navigator.vibrate && navigator.vibrate(p); } catch (e) { /* ignore */ } };
    const st = { amb: .08, ambT: .08, energy: 0, lvl: 0, peak: 0, peakAt: 0, spikeEnd: 0, nextSpike: rnd(14, 30), lamp: false, lampMode: '', lit: false, band: 0, down: false };
    let timers = [], raf = 0, logLines = [], lastLine = '', pack = null, own = null, nextChirp = 0, nextFlash = 0, last = performance.now(), phase = 0, chase = 0;
    let track = null, lock = null, lastBand = -1, maxLogged = false;

    const el = document.createElement('div'); el.className = 'pke'; document.body.appendChild(el);
    const $ = s => el.querySelector(s);
    el.innerHTML = `<div class="ph">
        <div class="pt"><div class="t1">${esc(short)} // PKE METER</div><div class="t2" id="psub">PSYCHOKINETIC ENERGY // SCANNING</div></div>
        ${api.back ? `<div class="seg"><button id="pbk">PACK</button>${api.ecu ? '<button id="pec">ECU</button>' : ''}<button class="on">PKE</button></div>` : ''}
        <button class="ib" id="psnd" aria-label="Sound">&#9835;</button><button class="ib" id="px" aria-label="Exit">&#10005;</button></div>
      <canvas class="wing" id="pwing"></canvas>
      <div class="body">
        <div class="scr"><canvas id="pscr"></canvas>
          <div class="ro"><div><div class="lb">PKE VALENCE</div><div class="big"><span id="pval">0.0</span><small>GeV</small></div></div>
            <div class="cl"><div class="lb">CLASS</div><b id="pcl">I</b></div></div>
          <div class="st"><span id="pstt">AMBIENT</span><span id="ppk">PEAK 0.0</span></div></div>
        <div class="sw" id="psw"><div class="tk"></div><div class="fill" id="pfill"></div><div class="fg" id="pfg"></div><div class="tx" id="ptx">&#9664; SLIDE TO SWEEP &#9654;</div></div>
        <div class="row"><button class="btn" id="plamp">LAMP OFF</button><button class="btn" id="pzero">ZERO PEAK</button></div>
        <div class="log" id="plog"></div>
      </div><div class="fl" id="pfl"></div>`;

    function log(t) { logLines.unshift({ t: clock() + '  ' + t, c: lineClass(t) }); logLines = logLines.slice(0, 40);
      const k = $('#plog'); if (k) k.innerHTML = logLines.slice(0, 6).map(x => `<div class="lc-${x.c}">&gt; ${esc(x.t)}</div>`).join(''); }

    // ---- sweep bar: the faster and farther the finger slides, the more energy
    const sw = $('#psw'); let lastX = null;
    const at = e => { const r = sw.getBoundingClientRect(); return clamp((e.clientX - r.left) / r.width, 0, 1); };
    sw.addEventListener('pointerdown', e => { try { sw.setPointerCapture(e.pointerId); } catch (x) { /* ignore */ } st.down = true; lastX = at(e); st.energy = Math.min(1, st.energy + .04); $('#pfg').style.left = lastX * 100 + '%'; $('#ptx').style.opacity = .25; e.preventDefault(); });
    sw.addEventListener('pointermove', e => { if (!st.down) return; const x = at(e); st.energy = Math.min(1, st.energy + Math.abs(x - lastX) * .55); lastX = x; $('#pfg').style.left = x * 100 + '%'; });
    const up = () => { st.down = false; lastX = null; $('#pfg').style.left = '-200px'; $('#ptx').style.opacity = 1; };
    sw.addEventListener('pointerup', up); sw.addEventListener('pointercancel', up);

    // ---- drawing
    function fit(cv) { const r = cv.getBoundingClientRect(), d = Math.min(2, window.devicePixelRatio || 1); const w = Math.round(r.width * d), h = Math.round(r.height * d);
      if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; } return [cv.getContext('2d'), r.width, r.height, d]; }
    function drawWing() {
      const [g, w, h, d] = fit($('#pwing')); if (!w) return; g.setTransform(d, 0, 0, d, 0, 0); g.clearRect(0, 0, w, h);
      const l = st.lvl, cx = w / 2, n = Math.max(8, Math.min(18, Math.floor(w / 26))), reach = (w / 2 - 14);
      // the bands hang folded at rest and lift and spread as the signal climbs, like the meter's arms
      const gap = 5 + 13 * l, rad = 3.2 + 2.2 * l, lit = l * n, y0 = h - 20, lift = (h - 34 - gap) * l;
      // centre hub
      g.fillStyle = '#1b1b1d'; g.strokeStyle = '#000'; g.beginPath(); g.arc(cx, y0, 13, 0, 7); g.fill(); g.stroke();
      g.fillStyle = `rgba(255,${Math.round(176 - 110 * l)},${Math.round(40 * (1 - l))},${.35 + .65 * l})`; g.shadowColor = '#ffb000'; g.shadowBlur = 6 + 18 * l; g.beginPath(); g.arc(cx, y0, 6 + 2 * l, 0, 7); g.fill(); g.shadowBlur = 0;
      for (const side of [-1, 1]) for (let i = 0; i < n; i++) {
        const t = (i + 1) / n, x = cx + side * (16 + t * (reach - 16)), y = y0 - lift * Math.pow(t, 1.25);
        const on = i < lit, head = on && Math.abs(((chase % n) + n) % n - i) < 1.2, part = clamp(lit - i, 0, 1);
        for (const row of [-1, 1]) {
          const yy = y + row * gap * (.35 + .65 * t);
          g.beginPath(); g.arc(x, yy, rad, 0, 7);
          if (on) { const hot = t > .8 && l > .8; g.fillStyle = head ? '#fff' : hot ? `rgba(255,90,60,${part})` : `rgba(255,${200 - Math.round(60 * t)},40,${.55 + .45 * part})`;
            g.shadowColor = hot ? '#ff2a1a' : '#ffb000'; g.shadowBlur = head ? 16 : 9; }
          else { g.fillStyle = '#3a2c10'; g.shadowBlur = 0; }
          g.fill();
        }
      }
      g.shadowBlur = 0;
    }
    function drawScreen() {
      const [g, w, h, d] = fit($('#pscr')); if (!w) return; g.setTransform(d, 0, 0, d, 0, 0); g.clearRect(0, 0, w, h);
      const l = st.lvl, col = l > .92 ? '#ff5a46' : l > .56 ? '#ffd24a' : '#4dff88';
      g.strokeStyle = '#1d5a33'; g.globalAlpha = .45; g.lineWidth = 1; g.beginPath();
      for (let x = 0; x <= w; x += w / 10) { g.moveTo(x, 0); g.lineTo(x, h); } for (let y = 0; y <= h; y += h / 6) { g.moveTo(0, y); g.lineTo(w, y); } g.stroke(); g.globalAlpha = 1;
      // bar graph down the left side, like the meter's level column
      const segs = 14, bx = 10, bw = 16, top = h * .34, bh = (h * .86 - top) / segs;
      for (let i = 0; i < segs; i++) { const on = i < Math.round(l * segs); g.fillStyle = on ? (i > 11 ? '#ff5a46' : i > 8 ? '#ffd24a' : '#4dff88') : '#10301c'; g.fillRect(bx, top + (segs - 1 - i) * bh + 1, bw, bh - 2); }
      // waveform: flat and slow at rest, tall and jagged when the signal is strong
      const mid = h * .62, amp = h * (.03 + .26 * l); g.strokeStyle = col; g.lineWidth = 2; g.shadowColor = col; g.shadowBlur = 8; g.beginPath();
      for (let x = bx + bw + 10; x <= w - 8; x += 3) { const u = x / w;
        const y = mid + amp * (Math.sin(u * (8 + 30 * l) + phase) * .6 + Math.sin(u * (21 + 55 * l) - phase * 1.7) * .3 + (Math.random() - .5) * .5 * l) * (0.4 + 0.6 * Math.sin(u * 3.14));
        x === bx + bw + 10 ? g.moveTo(x, y) : g.lineTo(x, y); }
      g.stroke(); g.shadowBlur = 0;
    }

    // ---- sound: a chirp that gets faster and higher with the signal, over a quiet whine
    const ac = () => { const a = own || (api.sound && api.sound() ? pack : null); return a && a.ac && a.ac.state !== 'closed' ? a.ac : null; };
    function chirp(l) { const c = ac(); if (!c) return; try { const o = c.createOscillator(), g = c.createGain(), t = c.currentTime, f = 850 + l * 1900;
      o.type = 'square'; o.frequency.setValueAtTime(f, t); o.frequency.exponentialRampToValueAtTime(f * (1.15 + l * .5), t + .05);
      g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(.035 + l * .04, t + .005); g.gain.exponentialRampToValueAtTime(.0001, t + .07);
      o.connect(g); g.connect(c.destination); o.start(t); o.stop(t + .08); } catch (e) { /* ignore */ } }
    // the pack's hum is reused as the meter's whine while the meter is open
    function tone(a) { if (!a) return; pack = a; const now = a.ac.currentTime, l = st.lvl;
      a.o1.frequency.setTargetAtTime(110 + l * 520, now, .12); a.o2.frequency.setTargetAtTime(220 + l * 1040, now, .12);
      a.f.frequency.setTargetAtTime(500 + l * 2600, now, .12); a.g.gain.setTargetAtTime(.012 + l * .04, now, .15); }
    function startOwn() { try { const c = api.audioCtx && api.audioCtx.state !== 'closed' ? api.audioCtx : new (window.AudioContext || window.webkitAudioContext)(); api.audioCtx = null; if (c.state === 'suspended') c.resume().catch(() => {});
      const g = c.createGain(), f = c.createBiquadFilter(), o1 = c.createOscillator(), o2 = c.createOscillator();
      o1.type = 'sawtooth'; o2.type = 'sine'; f.type = 'lowpass'; g.gain.value = 0; o1.connect(f); o2.connect(f); f.connect(g); g.connect(c.destination); o1.start(); o2.start();
      own = { ac: c, g, f, o1, o2 }; } catch (e) { /* no sound */ } }
    function stopOwn() { if (!own) return; try { own.o1.stop(); own.o2.stop(); own.ac.close(); } catch (e) { /* ignore */ } own = null; }
    const soundOn = () => api.sound ? api.sound() : !!own;
    const paintSnd = () => { const b = $('#psnd'); b.classList.toggle('on', soundOn()); b.title = soundOn() ? 'Sound on' : 'Sound off'; };

    // ---- lamp: the phone's flashlight where the browser allows it, a screen flash where it doesn't
    const torch = on => { if (track) track.applyConstraints({ advanced: [{ torch: on }] }).catch(() => {}); };
    const lampOff = () => { st.lamp = false; st.lit = false; if (track) { torch(false); const t = track; track = null; setTimeout(() => { try { t.stop(); } catch (e) { /* ignore */ } }, 150); } $('#pfl').style.opacity = 0; paintLamp(); };
    const paintLamp = () => { const b = $('#plamp'); b.classList.toggle('on', st.lamp); b.textContent = st.lamp ? (st.lampMode === 'torch' ? 'LAMP ON' : 'FLASH ON') : 'LAMP OFF'; };
    async function lampOn() {
      st.lamp = true; st.lampMode = 'screen'; paintLamp();
      try { if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('none');
        const ms = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } } }), t = ms.getVideoTracks()[0];
        if (!st.lamp || !el.isConnected) { t.stop(); return; }
        const caps = t.getCapabilities ? t.getCapabilities() : {};
        if (!caps.torch) { t.stop(); throw new Error('no torch'); }
        track = t; st.lampMode = 'torch'; log('LAMP: ON // FLASHLIGHT PULSING WITH SIGNAL');
      } catch (e) { if (st.lamp) log('LAMP: FLASHLIGHT NOT AVAILABLE // FLASHING SCREEN INSTEAD'); }
      paintLamp();
    }
    $('#plamp').onclick = () => { if (st.lamp) { lampOff(); log('LAMP: OFF'); } else lampOn(); };
    $('#pzero').onclick = () => { st.peak = 0; maxLogged = false; log('OK: PEAK ZEROED'); buzz(10); };

    // ---- the loop
    function frame(now) {
      raf = requestAnimationFrame(frame);
      const dt = Math.min(.1, (now - last) / 1000); last = now; const t = now / 1000;
      // ambient background drifts, with the odd passing spike
      if (t > st.nextSpike) { st.spikeEnd = t + rnd(1.5, 4); st.ambT = rnd(.3, .55); st.nextSpike = t + rnd(18, 45); log('SCAN: TRANSIENT READING // SOURCE UNKNOWN'); }
      if (st.spikeEnd && t > st.spikeEnd) { st.spikeEnd = 0; st.ambT = rnd(.05, .14); log('SCAN: TRANSIENT SETTLED'); }
      if (!st.spikeEnd && Math.random() < dt * .4) st.ambT = rnd(.04, .16);
      st.amb += (st.ambT - st.amb) * Math.min(1, dt * 1.5);
      st.energy *= Math.pow(.5, dt / (st.down ? 2.2 : 1.1));
      const target = clamp(st.amb + st.energy * (1 - st.amb) + Math.sin(t * 7) * .01, 0, 1);
      st.lvl += (target - st.lvl) * Math.min(1, dt * 9);
      const l = st.lvl; phase += dt * (2 + l * 16); chase += dt * (3 + l * 26);
      if (l > st.peak) { st.peak = l; st.peakAt = t; }
      // readouts
      $('#pval').textContent = (l * 100).toFixed(1); $('#pcl').textContent = classOf(l); $('#pstt').textContent = stateOf(l); $('#ppk').textContent = 'PEAK ' + (st.peak * 100).toFixed(1);
      $('#pfill').style.width = st.energy * 100 + '%';
      el.classList.toggle('hot', l > .56 && l <= .92); el.classList.toggle('max', l > .92);
      const band = STATE.filter(s => l >= s[0]).length - 1;
      if (band !== lastBand) { if (band > lastBand && band >= 2) log('SIGNAL: ' + STATE[band][1] + ' // CLASS ' + classOf(l) + ' // ' + (l * 100).toFixed(1)); lastBand = band; $('#psub').textContent = 'PSYCHOKINETIC ENERGY // ' + STATE[band][1]; }
      if (l > .97 && !maxLogged) { maxLogged = true; log('PEAK: METER PEGGED // CALL FOR A TRAP'); buzz([40, 40, 40, 40, 80]); }
      // chirps and buzz
      if (now >= nextChirp) { nextChirp = now + (760 - 690 * Math.pow(l, .8)); if (soundOn()) chirp(l); if (l > .3) buzz(l > .8 ? 18 : 8); }
      // lamp pulses: capped at about 2.5 a second
      if (st.lamp && now >= nextFlash) { const gapMs = Math.max(200, 900 - 760 * l); nextFlash = now + gapMs; st.lit = !st.lit;
        if (st.lampMode === 'torch') torch(st.lit); else $('#pfl').style.opacity = st.lit ? .1 + .5 * l : 0; }
      if (pack && soundOn() && !own) tone(pack); else if (own) tone(own);
      drawWing(); drawScreen();
    }

    $('#px').onclick = () => api.exit();
    if (api.back) $('#pbk').onclick = () => api.back();
    if (api.back && api.ecu) $('#pec').onclick = () => api.ecu();
    $('#psnd').onclick = () => { const on = !soundOn(); if (api.setSound) api.setSound(on); else if (on) startOwn(); else stopOwn(); try { on ? localStorage.removeItem('pk-sound') : localStorage.setItem('pk-sound', 'off'); } catch (e) { /* ignore */ } paintSnd(); };
    if (!api.sound) { let off = false; try { off = localStorage.getItem('pk-sound') === 'off'; } catch (e) { /* ignore */ } if (!off) startOwn();
      const wake = () => { if (own && own.ac.state === 'suspended') own.ac.resume().catch(() => {}); }; ['pointerdown', 'click', 'keydown'].forEach(t => el.addEventListener(t, wake, { capture: true })); }
    if (!api.back && navigator.wakeLock) navigator.wakeLock.request('screen').then(x => { lock = x; }).catch(() => {});
    const onVis = () => { if (document.hidden && st.lamp) lampOff(); }; document.addEventListener('visibilitychange', onVis);

    const BOOT = ['LINK: ' + short + ' PKE METER', 'BOOT: ANTENNA BANDS DEPLOYED', 'BOOT: VALENCE SENSOR ZEROED', 'BOOT: SWEEP BAR ARMED', 'BOOT: METER READY // SLIDE TO SWEEP'];
    let bi = 0; const boot = setInterval(() => { if (bi < BOOT.length) log(BOOT[bi++]); else clearInterval(boot); }, 220); timers.push(boot);
    timers.push(setInterval(() => { if (st.lvl > .3 || st.down) return; let line; if (Math.random() < .25) line = LORE[Math.floor(Math.random() * LORE.length)];
      else do { line = TECH[Math.floor(Math.random() * TECH.length)]; } while (line === lastLine); lastLine = line; log(line); }, 6500));
    paintSnd(); paintLamp(); raf = requestAnimationFrame(frame);
    const pke = {
      tone,
      test: { state: st, pump: v => { st.energy = v; } },
      destroy() { timers.forEach(clearInterval); cancelAnimationFrame(raf); document.removeEventListener('visibilitychange', onVis); lampOff(); stopOwn(); if (lock) lock.release().catch(() => {}); el.remove(); }
    };
    window.__pke = pke;
    return pke;
  } };
})();

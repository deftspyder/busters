/* Busters: PKE meter.
   Opens from Proton Pack Diagnostics with the PACK | ECU | PKE switch (the pack is always the default), or on its
   own from pke.html (public demo). Crew agnostic: it only uses the crew's short name.
   A phone has no arms, so the meter's arm lights are two bands that run flat from the centre across the top and
   then wrap down both edges of the meter: a full signal lights them all the way to the bottom. Inside them is the
   meter's display screen, and under that a sweep bar: slide a finger along it to build energy (lights, sound,
   buzz). LAMP pulses the phone's flashlight with the signal where the phone allows it; where it doesn't, the
   lamp just stays off. Lamp pulses never go faster than about 2.5 a second.
   Sound: snd/pke-meter.mp3 is one recording of the meter (start-up, steady scanning, a burst of strong reading).
   It is cut up in the browser: the start-up plays once on opening, the scanning part loops and speeds up with the
   signal, and the burst plays when the signal turns strong. If the file can't load, a built-in whine stands in.
   SET SCAN: a row of icons picks the kind of ghost the meter is tuned for (GHOSTS). The
   ghostly light is a plain wisp at low energy and takes the chosen shape above about half energy.
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
  // light colour along the bands: green at the centre, through yellow and orange to red, then deep red at the far end
  const LED = [[0, 60, 255, 110], [.3, 190, 255, 60], [.5, 255, 210, 40], [.68, 255, 130, 30], [.84, 255, 45, 30], [1, 150, 0, 12]];
  const ledRGB = t => { let i = 1; while (i < LED.length - 1 && t > LED[i][0]) i++; const a = LED[i - 1], b = LED[i], m = clamp((t - a[0]) / (b[0] - a[0]), 0, 1);
    return [1, 2, 3].map(k => Math.round(a[k] + (b[k] - a[k]) * m)); };
  // Ghost types a Buster can set the scan for. [id, button label, log name]
  const GHOSTS = [['wisp', 'WISP', 'FREE-FLOATING VAPOR'], ['friendly', 'FRIENDLY', 'FRIENDLY HAUNT'], ['library', 'LIBRARY', 'LIBRARY APPARITION'], ['polter', 'POLTER', 'POLTERGEIST'], ['eyes', 'EYES', 'UNSEEN WATCHER']];
  // how big each type is drawn on the scanner, next to the others
  const SIZE = { friendly: .5, polter: .6, eyes: 1.25 };
  // Types shown from art Bill supplied (cut out of their backgrounds and tinted for the scanner). The others are drawn in code.
  const ART = { library: 'img/pke/librarian.png?v=1' }, art = {};
  function artLoad(id, cb) { if (!ART[id]) return; let a = art[id]; if (!a) { a = art[id] = { img: new Image(), ok: false, cbs: [] }; a.img.onload = () => { a.ok = true; a.cbs.forEach(f => f()); a.cbs = []; }; a.img.src = ART[id]; }
    if (cb) { if (a.ok) cb(); else a.cbs.push(cb); } }
  // One drawing per type, used for both the menu icon and the shape on the scanner. (cx, cy) centre, R size, al opacity, t seconds.
  function ghostShape(g, type, cx, cy, R, al, t) {
    if (al <= .01) return; const c = a => `rgba(205,255,235,${clamp(a, 0, 1)})`;
    const el = (x, y, rx, ry, rot) => { g.beginPath(); g.ellipse(x, y, rx, ry, rot || 0, 0, 7); g.fill(); };
    g.save(); g.translate(cx, cy); g.fillStyle = c(al); g.strokeStyle = c(al * .6); g.lineCap = 'round'; g.shadowColor = `rgba(110,255,200,${clamp(al, 0, 1)})`; g.shadowBlur = R * .5;
    if (ART[type] && art[type] && art[type].ok) {
      const im = art[type].img, hh = R * 3.3, ww = hh * im.width / im.height; g.globalAlpha = clamp(al * (.92 + .08 * Math.sin(t * 7)), 0, 1); g.shadowBlur = R * .35;
      g.rotate(Math.sin(t * 1.1) * .035); g.drawImage(im, -ww / 2 + Math.sin(t * 1.6) * R * .05, -hh * .46, ww, hh);
    } else if (ART[type]) { artLoad(type); // art still loading: nothing yet
    } else if (type === 'wisp') {
      for (let i = 0; i < 5; i++) { const k = i / 4, x = Math.sin(t * 2 + i) * R * .25 * k + k * R * .5, y = -R * .5 + k * R * 1.2, r = R * (.6 - k * .38), gr = g.createRadialGradient(x, y, 0, x, y, r);
        gr.addColorStop(0, c(al * (.9 - k * .5))); gr.addColorStop(1, c(0)); g.fillStyle = gr; g.shadowBlur = 0; el(x, y, r, r); }
    } else if (type === 'friendly') {
      // a small round bedsheet ghost with a scalloped hem and stubby arms. It is drawn crisp on a hidden canvas and only its
      // blurred shadow is shown, so every edge is soft (this way of blurring also works on iPhones).
      const tr = g.getTransform(), d = Math.hypot(tr.a, tr.b) || 1, th = Math.atan2(tr.b, tr.a), S = Math.max(8, Math.ceil(R * 3.2 * d)), fc = ghostShape._c || (ghostShape._c = document.createElement('canvas')); if (fc.width !== S) fc.width = fc.height = S;
      const f = fc.getContext('2d'); f.setTransform(1, 0, 0, 1, 0, 0); f.clearRect(0, 0, S, S); f.setTransform(d, 0, 0, d, S / 2, S / 2); f.globalCompositeOperation = 'source-over'; f.fillStyle = '#fff';
      const fe = (x, y, rx, ry, rot) => { f.beginPath(); f.ellipse(x, y, rx, ry, rot || 0, 0, 7); f.fill(); };
      const w = R * .9, bot = R * 1.05, sway = Math.sin(t * 2) * R * .08;
      f.beginPath(); f.moveTo(-w, bot); f.lineTo(-w, -R * .2); f.bezierCurveTo(-w, -R * 1.45, w, -R * 1.45, w, -R * .2); f.lineTo(w, bot);
      for (let i = 0; i < 4; i++) f.quadraticCurveTo(w - (i + .5) * w / 2 + sway, bot - R * .38, w - (i + 1) * w / 2, bot);
      f.closePath(); f.fill();
      fe(-w * 1.08, R * .05, R * .24, R * .14, -.6 + Math.sin(t * 3) * .25); fe(w * 1.08, R * .05, R * .24, R * .14, .6 - Math.sin(t * 3) * .25);
      f.globalCompositeOperation = 'destination-out'; f.strokeStyle = '#000'; f.lineCap = 'round';
      fe(-R * .3, -R * .5, R * .12, R * .18); fe(R * .3, -R * .5, R * .12, R * .18);
      f.lineWidth = R * .09; f.beginPath(); f.arc(0, -R * .28, R * .2, .2 * Math.PI, .8 * Math.PI); f.stroke();
      const OFF = 6000; g.shadowColor = c(al * .85); g.shadowBlur = R * .1 * d; g.shadowOffsetX = OFF; g.drawImage(fc, -S / (2 * d) - OFF / d * Math.cos(th), -S / (2 * d) + OFF / d * Math.sin(th), S / d, S / d);
    } else if (type === 'polter') {
      // chaos without hard edges: a big restless wisp at the centre with smaller wisps whipping around it, each trailing a tail
      g.shadowBlur = 0; const soft = (x, y, r, a2) => { if (r <= 0) return; const gr = g.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, c(a2)); gr.addColorStop(.5, c(a2 * .45)); gr.addColorStop(1, c(0)); g.fillStyle = gr; el(x, y, r, r); };
      for (let i = 0; i < 3; i++) soft(Math.sin(t * 2.3 + i * 2.1) * R * .16, Math.cos(t * 1.9 + i * 2.1) * R * .14, R * (.62 + .1 * Math.sin(t * 3.1 + i)), al * .5);
      for (let i = 0; i < 7; i++) { const dir = i % 2 ? -1 : 1, sp = 1.3 + (i % 3) * .7, ph = i * 2.4, rx = R * (.75 + (i % 4) * .2), ry = rx * (.55 + (i % 3) * .2), tilt = i * .9;
        for (let k = 7; k >= 0; k--) { const an = dir * (t * sp - k * .11) + ph, wob = 1 + .18 * Math.sin(t * 2.7 + i + k * .2), ox = Math.cos(an) * rx * wob, oy = Math.sin(an) * ry * wob;
          soft(ox * Math.cos(tilt) - oy * Math.sin(tilt), ox * Math.sin(tilt) + oy * Math.cos(tilt), R * (.15 + (i % 3) * .04) * (1 - k * .1), al * (k ? .34 * (1 - k / 8) : .95)); } }
    } else if (type === 'eyes') {
      // nothing but a pair of eyes in the dark: soft, slanted, slowly looking around, and blinking now and then
      g.shadowBlur = 0; const ph = t % 5.3, blink = ph < .22 ? Math.abs(ph - .11) / .11 : 1, look = Math.sin(t * .7) * R * .1, flick = .85 + .15 * Math.sin(t * 6.3);
      for (const sx of [-1, 1]) { g.save(); g.translate(sx * R * .95, 0); g.rotate(sx * -.24); g.scale(1, .46 * blink + .02);
        const gr = g.createRadialGradient(0, 0, 0, 0, 0, R * .52); gr.addColorStop(0, c(al * flick)); gr.addColorStop(.4, c(al * .6 * flick)); gr.addColorStop(1, c(0)); g.fillStyle = gr; el(0, 0, R * .52, R * .52);
        g.globalCompositeOperation = 'destination-out'; const pg = g.createRadialGradient(look, 0, 0, look, 0, R * .34); pg.addColorStop(0, `rgba(0,0,0,${clamp(al * 1.5, 0, 1)})`); pg.addColorStop(1, 'rgba(0,0,0,0)'); g.fillStyle = pg;
        g.beginPath(); g.ellipse(look, 0, R * .1, R * .34, 0, 0, 7); g.fill(); g.restore(); }
    }
    g.restore();
  }
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
.pke .frm{position:relative;flex:1;min-height:0;display:flex;flex-direction:column;width:min(620px,100%);margin:0 auto}
.pke .wing{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
.pke .hub{position:absolute;left:50%;top:-6px;width:44px;height:42px;margin-left:-22px;background:none;border:0;z-index:2;cursor:pointer}
.pke .body{flex:1;min-height:0;display:flex;flex-direction:column;gap:8px;padding:36px 34px 10px}
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
.pke .btn.lamp{flex:0 0 62px;min-height:0;font-size:.78em;letter-spacing:.08em;line-height:1.25;padding:2px}
.pke .btn.on{background:#ffb000;color:#140a02;border-color:#ffb000;box-shadow:0 0 14px #ffb000aa}
.pke .scan{display:flex;gap:5px;flex:1;min-width:0}
.pke .scan button{font:inherit;font-size:.58em;letter-spacing:.03em;flex:1;min-width:0;display:flex;flex-direction:column;align-items:center;gap:2px;padding:4px 1px 3px;border-radius:8px;border:1px solid #ffffff33;background:#0009;color:#ffd77a;cursor:pointer;overflow:hidden}
.pke .scan button canvas{width:36px;height:36px;display:block}
.pke .scan button.on{border-color:#7dffc8;color:#d8ffe2;box-shadow:0 0 10px #2bff6a66,inset 0 0 12px #2bff6a22}
.pke .log{flex:0 0 auto;height:calc(5 * 1.45em + 14px);font-size:.85em;line-height:1.45;background:#060606;border-radius:6px;padding:7px 9px;overflow:hidden;box-shadow:inset 0 2px 10px #000}
.pke .log div{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pke .log div:nth-child(n+3){opacity:.8}.pke .log div:nth-child(n+5){opacity:.55}
.pke .lc-routine{color:#b98f4a}.pke .lc-boot{color:#ffe9d0;text-shadow:0 0 6px #ff8a00}.pke .lc-advisory{color:#5fe3ff;text-shadow:0 0 6px #35b2e8}
.pke .lc-warn{color:#ffc24a;text-shadow:0 0 6px #ff9a00}.pke .lc-fail{color:#ff5a46;text-shadow:0 0 8px #ff2a1a}.pke .lc-recover{color:#b6ff6a;text-shadow:0 0 6px #7dff3a}
@media (min-aspect-ratio:1/1) and (max-height:520px){.pke .log{display:none}.pke .scan button span{display:none}.pke .scan button canvas{width:28px;height:28px}.pke .scr{min-height:90px}.pke .sw{height:56px}.pke .ro .big{font-size:2.2em}}`;

  function lineClass(t) {
    if (/^PEAK|^SIGNAL: FULL|^WARN|RESOLVED/.test(t)) return 'warn';
    if (/^SCAN SET/.test(t)) return 'advisory';
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
    const st = { amb: .08, ambT: .08, energy: 0, lvl: 0, peak: 0, peakAt: 0, spikeEnd: 0, nextSpike: rnd(14, 30), lamp: false, lampMode: '', lit: false, band: 0, down: false, gh: 0 };
    let timers = [], raf = 0, logLines = [], lastLine = '', pack = null, own = null, nextChirp = 0, nextFlash = 0, last = performance.now(), phase = 0, chase = 0;
    let track = null, lock = null, lastBand = -1, maxLogged = false;

    const el = document.createElement('div'); el.className = 'pke'; document.body.appendChild(el);
    const $ = s => el.querySelector(s);
    el.innerHTML = `<div class="ph">
        <div class="pt"><div class="t1">${esc(short)} // PKE METER</div><div class="t2" id="psub">PSYCHOKINETIC ENERGY // SCANNING</div></div>
        ${api.back ? `<div class="seg"><button id="pbk">PACK</button>${api.ecu ? '<button id="pec">ECU</button>' : ''}<button class="on">PKE</button></div>` : ''}
        <button class="ib" id="psnd" aria-label="Sound">&#9835;</button><button class="ib" id="px" aria-label="Exit">&#10005;</button></div>
      <div class="frm"><canvas class="wing" id="pwing"></canvas><button class="hub" id="phub" aria-label="Switch light style"></button>
      <div class="body">
        <div class="scr"><canvas id="pscr"></canvas>
          <div class="ro"><div><div class="lb">PKE VALENCE</div><div class="big"><span id="pval">0.0</span><small>GeV</small></div></div>
            <div class="cl"><div class="lb">CLASS</div><b id="pcl">I</b></div></div>
          <div class="st"><span id="pstt">AMBIENT</span><span id="ppk">PEAK 0.0</span></div></div>
        <div class="sw" id="psw"><div class="tk"></div><div class="fill" id="pfill"></div><div class="fg" id="pfg"></div><div class="tx" id="ptx">&#9664; SLIDE TO SWEEP &#9654;</div></div>
        <div class="row"><button class="btn lamp" id="plamp">LAMP OFF</button>
        <div class="scan" id="pscan">${GHOSTS.map(([id, lb]) => `<button data-g="${id}" aria-label="Scan for ${lb}"><canvas width="72" height="72"></canvas><span>${lb}</span></button>`).join('')}</div></div>
        <div class="log" id="plog"></div>
      </div></div>`;

    function log(t) { logLines.unshift({ t: clock() + '  ' + t, c: lineClass(t) }); logLines = logLines.slice(0, 40);
      const k = $('#plog'); if (k) k.innerHTML = logLines.slice(0, 6).map(x => `<div class="lc-${x.c}">&gt; ${esc(x.t)}</div>`).join(''); }

    // ---- set scan: which kind of ghost the meter is tuned for
    let scan = 'wisp', resolved = false; try { const v = localStorage.getItem('pke-scan'); if (GHOSTS.some(x => x[0] === v)) scan = v; } catch (e) { /* ignore */ }
    const scanName = () => GHOSTS.find(x => x[0] === scan)[2];
    const paintScan = () => el.querySelectorAll('#pscan button').forEach(b => b.classList.toggle('on', b.dataset.g === scan));
    function setScan(id, quiet) { if (!GHOSTS.some(x => x[0] === id)) return; scan = id; resolved = false; try { localStorage.setItem('pke-scan', id); } catch (e) { /* ignore */ } paintScan(); if (!quiet) { log('SCAN SET: ' + scanName()); buzz(10); } }
    el.querySelectorAll('#pscan button').forEach(b => { const cv = b.querySelector('canvas'), g = cv.getContext('2d'), id = b.dataset.g;
      const icon = () => { g.clearRect(0, 0, 72, 72); ghostShape(g, id, 36, ART[id] ? 33 : 36, ART[id] ? 20 : id === 'polter' ? 21 : id === 'eyes' ? 19 : 22, 1, ART[id] ? 0 : .6); };
      icon(); artLoad(id, icon); b.onclick = () => setScan(id); });
    paintScan();

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
    let ledStyle = 'seg'; try { if (localStorage.getItem('pke-led') === 'dot') ledStyle = 'dot'; } catch (e) { /* ignore */ }
    // Lights per side: flat from the centre hub to the corner, then down the edge to the bottom.
    function drawWing() {
      const [g, w, h, d] = fit($('#pwing')); if (!w) return; g.setTransform(d, 0, 0, d, 0, 0); g.clearRect(0, 0, w, h);
      const l = st.lvl, cx = w / 2, rad = 4.2, hubY = 15;
      g.fillStyle = '#1b1b1d'; g.strokeStyle = '#000'; g.beginPath(); g.arc(cx, hubY, 12, 0, 7); g.fill(); g.stroke();
      const hc = ledRGB(l).join(','); g.fillStyle = `rgba(${hc},${.4 + .6 * l})`; g.shadowColor = `rgb(${hc})`; g.shadowBlur = 6 + 18 * l; g.beginPath(); g.arc(cx, hubY, 6 + 2 * l, 0, 7); g.fill(); g.shadowBlur = 0;
      // two looks for the bands: 'seg' is one row of bar segments (like a segmented LED bar), 'dot' is two rows of round lights
      const seg = ledStyle === 'seg';
      for (const inset of seg ? [15] : [9, 21]) {
        const top = cx - 20 - inset, y1 = seg ? 31 : inset, len = top + (h - 8 - inset - y1), n = Math.max(6, Math.round(len / (seg ? 12.5 : 15))), lit = l * n, hd = ((chase % (n + 6)) + n + 6) % (n + 6);
        for (let i = 0; i < n; i++) {
          const s = (i + .5) / n * len, t = (i + 1) / n, across = s <= top;
          const dx = across ? 20 + s : cx - inset, y = across ? inset : y1 + (s - top);
          const on = i < lit, head = on && Math.abs(hd - i) < 1.2, part = clamp(lit - i, 0, 1), [cr, cg, cb] = ledRGB(t);
          for (const side of [-1, 1]) {
            g.beginPath(); const x = cx + side * dx;
            if (seg) { const sw = across ? 8 : 22, sh = across ? 22 : 8; g.rect(Math.round((x - sw / 2) * d) / d, Math.round((y - sh / 2) * d) / d, sw, sh); } // square corners on whole pixels, so every edge is crisp
            else g.arc(x, y, rad, 0, 7);
            if (on) { g.fillStyle = head ? `rgb(${Math.round(cr + (255 - cr) * .7)},${Math.round(cg + (255 - cg) * .7)},${Math.round(cb + (255 - cb) * .7)})` : `rgba(${cr},${cg},${cb},${.55 + .45 * part})`;
              g.shadowColor = `rgb(${cr},${cg},${cb})`; g.shadowBlur = seg ? (head ? 6 : 2.5) : head ? 16 : 9; }
            else { g.fillStyle = `rgb(${Math.round(cr * .16 + 10)},${Math.round(cg * .16 + 10)},${Math.round(cb * .16 + 8)})`; g.shadowBlur = 0; }
            g.fill();
          }
        }
      }
      g.shadowBlur = 0;
    }
    // A ghostly light forms on the display while the Buster works the sweep bar: faint at low energy, bright and
    // larger at high energy, and it fades when they stop. It never sits still: it drifts around the screen, and
    // every so often it sweeps off the left side trailing a tail, waits a moment out of sight, then comes back in
    // from that same side.
    // Drawn first, so the grid and waveform sit over it.
    const gh = { x: -.4, y: .46, vx: 0, res: 0, tm: 0, z: 1, rot: 0, spin: 0, nextSpin: 0, mode: 'in', next: 0, until: 0, trail: [], last: 0, n: 0 };
    function drawGhost(g, w, h) {
      const now = performance.now() / 1000, dt = Math.min(.1, now - (gh.last || now)); gh.last = now;
      st.gh += (clamp(st.energy * 1.15, 0, 1) - st.gh) * .07; const a = st.gh;
      if (a < .02) { gh.trail.length = 0; gh.res = 0; if (gh.mode === 'hover') gh.next = Math.max(gh.next, now + 2); return; }
      // the more energy, the wilder it gets: its own clock runs faster, it roams wider, and it rushes toward the glass and away again
      const calm = scan === 'friendly' ? .3 : 1, wild = clamp((a - .12) * 1.6, 0, 1) * calm; gh.tm += dt * ((calm < 1 ? .9 : 1.5) + 4.5 * wild); const tm = gh.tm; // the friendly one is for kids, so it stays gentle
      const hx = .54 + (.2 + .14 * wild) * Math.sin(tm * .55) + .06 * Math.sin(tm * 1.7), hy = .46 + (.1 + .1 * wild) * Math.cos(tm * .43) + .03 * Math.sin(tm * 2.3);
      gh.z += ((1 + (.12 + .88 * wild) * (.6 * Math.sin(tm * .8) + .3 * Math.sin(tm * 1.9 + 1))) - gh.z) * Math.min(1, dt * 4);
      // spins: every so often it whips round in a full turn, looping the loop as it goes (more often the more energy there is)
      if (!gh.spin && now > gh.nextSpin && a > .12 && gh.mode === 'hover') { gh.spin = (Math.random() < .5 ? -1 : 1) * 2 * Math.PI * (Math.random() < .3 ? 2 : 1); gh.nextSpin = now + rnd(2.2, 5) / (1 + 1.5 * wild); }
      if (gh.spin) { const stp = Math.sign(gh.spin) * Math.min(Math.abs(gh.spin), dt * (5 + 6 * wild)); gh.rot += stp; gh.spin -= stp; }
      const loop = .07 + .06 * wild, px = gh.x + loop * Math.sin(gh.rot), py = gh.y + loop * (1 - Math.cos(gh.rot)) * (w / h), lean = gh.rot + (.1 + .3 * wild) * Math.sin(tm * 1.7);
      // every move eases: it gathers speed gently on the way out and glides to a stop on the way back, never a jump
      if (gh.mode === 'hover') { const fl = Math.min(1, dt * (1.6 + 3 * wild)), nx = gh.x + (hx - gh.x) * fl; gh.vx = (nx - gh.x) / Math.max(dt, .001); gh.x = nx; gh.y += (hy - gh.y) * fl; if (now > gh.next && !gh.spin) gh.mode = 'out'; }
      else if (gh.mode === 'out') { gh.vx += (-.5 - .5 * wild - gh.vx) * Math.min(1, dt * .9); gh.x += gh.vx * dt; gh.y += (hy - .04 - gh.y) * Math.min(1, dt * .8); if (gh.x < -.55) { gh.mode = 'away'; gh.vx = 0; gh.until = now + rnd(.2, .7); } }
      else if (gh.mode === 'away') { if (now > gh.until) gh.mode = 'in'; }
      else { gh.vx += (Math.max(.08, (hx - gh.x) * 1.1) - gh.vx) * Math.min(1, dt * 2.2); gh.x += gh.vx * dt; gh.y += (hy - gh.y) * Math.min(1, dt * 1.2); if (hx - gh.x < .03) { gh.mode = 'hover'; gh.next = now + rnd(4, 9) / (1 + wild); } }
      if (++gh.n % 3 === 0) { gh.trail.unshift([px, py]); if (gh.trail.length > 26) gh.trail.pop(); }
      const R = Math.min(w, h) * (.15 + .2 * a) * .65 * gh.z, far = clamp(.55 + .45 * gh.z, .5, 1), edge = x => { const e = clamp(Math.min(x + .5, 1.5 - x) / .62, 0, 1); return e * e * (3 - 2 * e); };
      const blob = (x, y, r, al) => { if (al <= .004) return; const gr = g.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, `rgba(190,255,228,${al})`); gr.addColorStop(.5, `rgba(120,255,200,${al * .5})`); gr.addColorStop(1, 'rgba(60,255,170,0)');
        g.fillStyle = gr; g.beginPath(); g.ellipse(x, y, r * .85, r * 1.2, 0, 0, 7); g.fill(); };
      const av = Math.pow(a, .6); // brighter at middling energy, so it shows well before the meter pegs
      g.save(); g.globalCompositeOperation = 'screen';
      // tail: where it has just been, thinning and fading, with a slow ripple
      for (let i = gh.trail.length - 1; i >= 1; i--) { const k = i / 26, [tx, ty] = gh.trail[i]; blob(tx * w, ty * h + Math.sin(now * 3 + i * .5) * R * .22 * k + k * R * .4, R * (.8 - k * .55), av * .3 * (1 - k) * edge(tx) * far * (scan === 'eyes' ? 0 : 1 - gh.res * .45)); }
      const cx = px * w, cy = py * h, res = (gh.res += ((scan === 'wisp' ? 0 : scan === 'eyes' ? clamp((a - .04) / .15, 0, 1) : clamp((a - .5) / .3, 0, 1)) - gh.res) * Math.min(1, dt * 2.5)), ea = scan === 'eyes' ? 0 : av * edge(gh.x) * far * (1 - res * .7); // the eyes hang in the dark with no ball of glow at all: they show from low energy and just get brighter
      blob(cx, cy, R * 2.4, ea * .14);
      // a loose, shifting head made of three soft lobes, never a hard ball
      for (let i = 0; i < 3; i++) blob(cx + Math.sin(now * 1.7 + i * 2.1) * R * .28, cy + Math.cos(now * 1.3 + i * 2.1) * R * .24, R * (.78 + .12 * Math.sin(now * 2.6 + i)), ea * (.26 + .05 * Math.sin(now * 9 + i)));
      for (let i = 1; i < 5; i++) { const k = i / 5, lx = Math.sin(now * 2.1 + i) * R * .3 * k, ly = k * R * 1.5; blob(cx + lx * Math.cos(lean) - ly * Math.sin(lean), cy + lx * Math.sin(lean) + ly * Math.cos(lean), R * (.9 - k * .55), ea * .2 * (1 - k)); }
      // above about half energy the wisp takes the shape the scan is set for, sharper the higher it goes
      if (res > .01) { g.save(); g.translate(cx, cy + R * .15); g.rotate(scan === 'eyes' || scan === 'library' ? Math.sin(tm * 1.1) * .16 : lean); /* the eyes and the library apparition stay upright and only sway; the others may flip */ ghostShape(g, scan, 0, 0, R * 1.05 * (SIZE[scan] || 1), av * edge(gh.x) * far * res * (scan === 'eyes' ? 1 : .8), now); g.restore(); }
      if (res > .6 && !resolved) { resolved = true; log('SCAN: ' + scanName() + ' RESOLVED // CLASS ' + classOf(st.lvl)); buzz([20, 30, 20]); } else if (res < .15 && resolved) { resolved = false; if (scan !== 'wisp') log('SCAN: ' + scanName() + ' LOST // SWEEP TO REACQUIRE'); }
      g.restore();
    }
    function drawScreen() {
      const [g, w, h, d] = fit($('#pscr')); if (!w) return; g.setTransform(d, 0, 0, d, 0, 0); g.clearRect(0, 0, w, h);
      const l = st.lvl, col = l > .92 ? '#ff5a46' : l > .56 ? '#ffd24a' : '#4dff88';
      drawGhost(g, w, h);
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

    // ---- recorded meter sounds, cut from one file (times in seconds)
    const CUT = { start: [0, 1.12], loop: [1.25, 3.95], hit: [4.12, 5.42] };
    let smp = null, booted = false, lastHit = -9;
    const SND = window.BustersPKE._snd || (window.BustersPKE._snd = fetch('snd/pke-meter.mp3?v=1').then(r => { if (!r.ok) throw new Error('no sound file'); return r.arrayBuffer(); }).catch(() => null));
    function cut(c, buf, a, b, xf) { const sr = buf.sampleRate, i0 = Math.floor(a * sr), n = Math.floor((b - a) * sr), out = c.createBuffer(buf.numberOfChannels, n, sr), N = Math.floor(xf * sr);
      for (let ch = 0; ch < buf.numberOfChannels; ch++) { const src = buf.getChannelData(ch), dst = out.getChannelData(ch); dst.set(src.subarray(i0, i0 + n));
        if (N) for (let k = 0; k < N; k++) { const m = k / N; dst[n - N + k] = dst[n - N + k] * (1 - m) + src[i0 - N + k] * m; } // blend the tail into what comes before the head, so the loop has no seam
        else for (let k = 0; k < 200 && k < n; k++) { dst[k] *= k / 200; dst[n - 1 - k] *= k / 200; } }
      return out; }
    function play(buf, vol, loop, when) { const c = smp.ac, s = c.createBufferSource(), g = c.createGain(); s.buffer = buf; s.loop = !!loop; g.gain.value = vol; s.connect(g); g.connect(c.destination); s.start(when || 0); return { s, g }; }
    function sampleStop() { if (!smp) return; try { if (smp.bed) smp.bed.s.stop(); } catch (e) { /* ignore */ } smp = null; }
    async function sampleSetup(c) { const me = smp = { ac: c, ready: false };
      try { const raw = await SND; if (!raw) return; const buf = await c.decodeAudioData(raw.slice(0)); if (smp !== me || c.state === 'closed') return;
        me.hit = cut(c, buf, CUT.hit[0], CUT.hit[1], 0); const lp = cut(c, buf, CUT.loop[0], CUT.loop[1], .12);
        let at = c.currentTime + .02; if (!booted) { booted = true; play(cut(c, buf, CUT.start[0], CUT.start[1], 0), 1.3, false, at); at += CUT.start[1] - CUT.start[0] - .05; }
        me.bed = play(lp, 0, true, at); me.bedAt = at; me.ready = true;
      } catch (e) { /* keep the built-in whine */ } }
    function sampleTick(l, band, rose) { const c = ac(); if (!c) return sampleStop(); if (!smp || smp.ac !== c) sampleSetup(c);
      if (!smp || !smp.ready) return; const now = c.currentTime; if (now < smp.bedAt) return;
      smp.bed.s.playbackRate.setTargetAtTime(1 + l * .55, now, .12); smp.bed.g.gain.setTargetAtTime(.9 + l * 1.1, now, .15);
      if (rose && band >= 3 && now - lastHit > 2.5) { lastHit = now; play(smp.hit, 1.1 + l * .5, false); } }
    const sampled = () => !!(smp && smp.ready);

    // ---- sound: a chirp that gets faster and higher with the signal, over a quiet whine
    const ac = () => { const a = own || (api.sound && api.sound() ? pack : null); return a && a.ac && a.ac.state !== 'closed' ? a.ac : null; };
    function chirp(l) { const c = ac(); if (!c) return; try { const o = c.createOscillator(), g = c.createGain(), t = c.currentTime, f = 850 + l * 1900;
      o.type = 'square'; o.frequency.setValueAtTime(f, t); o.frequency.exponentialRampToValueAtTime(f * (1.15 + l * .5), t + .05);
      g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime((.035 + l * .04) * (sampled() ? .45 : 1), t + .005); g.gain.exponentialRampToValueAtTime(.0001, t + .07);
      o.connect(g); g.connect(c.destination); o.start(t); o.stop(t + .08); } catch (e) { /* ignore */ } }
    // the pack's hum is reused as the meter's whine while the meter is open
    function tone(a) { if (!a) return; pack = a; const now = a.ac.currentTime, l = st.lvl;
      a.o1.frequency.setTargetAtTime(110 + l * 520, now, .12); a.o2.frequency.setTargetAtTime(220 + l * 1040, now, .12);
      a.f.frequency.setTargetAtTime(500 + l * 2600, now, .12); a.g.gain.setTargetAtTime(sampled() ? 0 : .012 + l * .04, now, .15); }
    function startOwn() { try { const c = api.audioCtx && api.audioCtx.state !== 'closed' ? api.audioCtx : new (window.AudioContext || window.webkitAudioContext)(); api.audioCtx = null; if (c.state === 'suspended') c.resume().catch(() => {});
      const g = c.createGain(), f = c.createBiquadFilter(), o1 = c.createOscillator(), o2 = c.createOscillator();
      o1.type = 'sawtooth'; o2.type = 'sine'; f.type = 'lowpass'; g.gain.value = 0; o1.connect(f); o2.connect(f); f.connect(g); g.connect(c.destination); o1.start(); o2.start();
      own = { ac: c, g, f, o1, o2 }; } catch (e) { /* no sound */ } }
    function stopOwn() { if (!own) return; try { own.o1.stop(); own.o2.stop(); own.ac.close(); } catch (e) { /* ignore */ } own = null; }
    const soundOn = () => api.sound ? api.sound() : !!own;
    const paintSnd = () => { const b = $('#psnd'); b.classList.toggle('on', soundOn()); b.title = soundOn() ? 'Sound on' : 'Sound off'; };

    // ---- lamp: the phone's flashlight. It works or it doesn't; there is no stand-in.
    const torch = on => { if (track) track.applyConstraints({ advanced: [{ torch: on }] }).catch(() => {}); };
    const lampOff = () => { st.lamp = false; st.lit = false; if (track) { torch(false); const t = track; track = null; setTimeout(() => { try { t.stop(); } catch (e) { /* ignore */ } }, 150); } paintLamp(); };
    const paintLamp = () => { const b = $('#plamp'); b.classList.toggle('on', st.lamp); b.textContent = st.lamp ? 'LAMP ON' : st.lampMode === 'none' ? 'NO LAMP' : 'LAMP OFF'; };
    let lampBusy = false;
    async function lampOn() {
      if (lampBusy) return; lampBusy = true;
      try { if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('none');
        const ms = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } } }), t = ms.getVideoTracks()[0];
        if (!el.isConnected) { t.stop(); return; }
        const caps = t.getCapabilities ? t.getCapabilities() : {};
        if (!caps.torch) { t.stop(); throw new Error('no torch'); }
        track = t; st.lamp = true; st.lampMode = 'torch'; log('LAMP: ON // FLASHLIGHT PULSING WITH SIGNAL');
      } catch (e) { st.lamp = false; st.lampMode = 'none'; log('LAMP: FLASHLIGHT NOT AVAILABLE ON THIS PHONE'); }
      finally { lampBusy = false; }
      paintLamp();
    }
    $('#plamp').onclick = () => { if (st.lamp) { lampOff(); log('LAMP: OFF'); } else lampOn(); };

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
      sampleTick(l, band, band > lastBand && lastBand >= 0);
      if (band !== lastBand) { if (band > lastBand && band >= 2) log('SIGNAL: ' + STATE[band][1] + ' // CLASS ' + classOf(l) + ' // ' + (l * 100).toFixed(1)); lastBand = band; $('#psub').textContent = 'PSYCHOKINETIC ENERGY // ' + STATE[band][1]; }
      if (l > .97 && !maxLogged) { maxLogged = true; log('PEAK: METER PEGGED // CALL FOR A TRAP'); buzz([40, 40, 40, 40, 80]); }
      // chirps and buzz
      if (now >= nextChirp) { nextChirp = now + (760 - 690 * Math.pow(l, .8)); if (soundOn()) chirp(l); if (l > .3) buzz(l > .8 ? 18 : 8); }
      // lamp pulses: capped at about 2.5 a second
      if (st.lamp && now >= nextFlash) { const gapMs = Math.max(200, 900 - 760 * l); nextFlash = now + gapMs; st.lit = !st.lit;
        torch(st.lit); }
      if (pack && soundOn() && !own) tone(pack); else if (own) tone(own);
      drawWing(); drawScreen();
    }

    $('#phub').onclick = () => { ledStyle = ledStyle === 'seg' ? 'dot' : 'seg'; try { localStorage.setItem('pke-led', ledStyle); } catch (e) { /* ignore */ } log('LIGHTS: ' + (ledStyle === 'seg' ? 'SEGMENT BARS' : 'ROUND LAMPS')); buzz(10); };
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
      test: { state: st, pump: v => { st.energy = v; }, sampled, scan: id => setScan(id, true), ghost: gh },
      destroy() { timers.forEach(clearInterval); cancelAnimationFrame(raf); document.removeEventListener('visibilitychange', onVis); lampOff(); sampleStop(); stopOwn(); if (lock) lock.release().catch(() => {}); el.remove(); }
    };
    window.__pke = pke;
    return pke;
  } };
})();

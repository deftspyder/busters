/* Busters: proton pack monitor.
   An in-world diagnostics screen: the crew's own pack photo with live readings for each system,
   assigned to a Buster. Loaded on demand from index.html (uses its globals: S, $, esc, toast, rpc,
   refresh, can, nameOf, upcoming, todayISO). */
(function () {
  const SYS = [
    { k: 'cyclotron', n: 'Cyclotron', u: 'RPM', b: 4200, r: 380, d: 0 },
    { k: 'power_cell', n: 'Power Cell', u: '%', b: 92, r: 6, d: 0 },
    { k: 'sync_gen', n: 'Synchronous Generator', u: 'MeV', b: 3.62, r: .4, d: 2 },
    { k: 'booster', n: 'Booster', u: 'kV', b: 48.5, r: 4, d: 1 },
    { k: 'ion_arm', n: 'Ion Arm', u: '\u00b5A', b: 712, r: 60, d: 0 },
    { k: 'ppd', n: 'Primary Power Distributor', u: 'GW', b: 1.21, r: .08, d: 2 },
    { k: 'injectors', n: 'Injectors', u: 'PSI', b: 118, r: 9, d: 0 },
    { k: 'hga', n: 'Hydrogen Gas Actuator', u: 'PSI', b: 64, r: 7, d: 0 },
    { k: 'crank', n: 'Crank Generator', u: 'Hz', b: 60, r: 1.5, d: 1 },
    { k: 'n_filter', n: 'N-Filter', u: 'PPM', b: 14, r: 10, d: 0, warn: 26 },
    { k: 'heatsink', n: 'Heat Sink', u: '\u00b0C', b: 71, r: 12, d: 0, warn: 84 },
    { k: 'ribbon', n: 'Ribbon Cable', u: 'Gb/s', b: 9.8, r: .6, d: 1 }
  ];
  const LOG = ['Cyclotron spin-up nominal', 'N-Filter venting complete', 'Ion arm alignment verified', 'Booster capacitor recharged',
    'Synchronous generator in phase', 'Heat sink fans engaged', 'Ribbon cable handshake OK', 'Injector pressure equalized',
    'Particle thrower safety: ON', 'Do not cross the streams', 'PKE background within limits', 'Containment link standing by'];

  const CSS = `
.pk{position:fixed;inset:0;z-index:100;background:#020a0d;color:#bdf3ff;font-family:"Share Tech Mono","DM Sans",ui-monospace,monospace;display:grid;grid-template-rows:auto 1fr auto;overflow:hidden;cursor:none}
.pk.cur{cursor:default}
.pk::after{content:"";position:absolute;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,#0000 0 2px,#00000038 2px 3px);mix-blend-mode:multiply}
.pk .hd{display:flex;align-items:center;gap:2vw;padding:1.4vh 2vw;border-bottom:1px solid #35b2e855;background:linear-gradient(#071a22,#020a0d)}
.pk .hd .t{font-family:"Bebas Neue",Impact,sans-serif;font-size:4.2vh;letter-spacing:.18em;color:#9be8ff;text-shadow:0 0 10px #35b2e8}
.pk .hd .u{font-size:1.8vh;color:#5fa9c2;letter-spacing:.12em}
.pk .hd .who{margin-left:auto;text-align:right}
.pk .hd .who .l{font-size:1.6vh;letter-spacing:.3em;color:#ff9a3c}
.pk .hd .who .nm{font-family:"Bebas Neue",Impact,sans-serif;font-size:4.6vh;letter-spacing:.06em;color:#fff;text-shadow:0 0 12px #ff9a3c,0 0 24px #ff6a1a88;line-height:1}
.pk .bd{display:grid;grid-template-columns:1fr minmax(0,1.25fr) 1fr;gap:1.4vw;padding:1.4vh 1.6vw;min-height:0}
.pk .col{display:flex;flex-direction:column;gap:1vh;min-height:0}
.pk .sys{flex:1;min-height:0;border:1px solid #35b2e844;border-left:4px solid var(--st);border-radius:8px;background:#04141bcc;padding:.8vh .8vw;display:grid;grid-template-columns:auto 1fr auto;grid-template-rows:auto auto;column-gap:.7vw;align-items:center}
.pk .sys .no{grid-row:1/3;width:3.4vh;height:3.4vh;border-radius:50%;border:1px solid var(--st);color:var(--st);display:grid;place-items:center;font-size:1.7vh}
.pk .sys .nm{font-size:1.75vh;letter-spacing:.06em;color:#9fd8ea;text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pk .sys .v{grid-row:1/3;grid-column:3;text-align:right;font-size:3.1vh;color:#fff;text-shadow:0 0 8px #35b2e8;white-space:nowrap}
.pk .sys .v small{font-size:1.5vh;color:#7fbfd4;margin-left:.3vw}
.pk .sys .st{font-size:1.45vh;letter-spacing:.2em;color:var(--st)}
.pk .sys .st i{display:inline-block;width:1vh;height:1vh;border-radius:50%;background:var(--st);box-shadow:0 0 8px var(--st);margin-right:.5vw;vertical-align:middle;animation:pkb 1.6s infinite}
.pk .sys.warn .st i{animation-duration:.5s}
@keyframes pkb{50%{opacity:.25}}
.pk .mid{position:relative;border:1px solid #35b2e855;border-radius:12px;background:radial-gradient(ellipse at 50% 45%,#0b2733,#020a0d 75%);display:grid;place-items:center;min-height:0;overflow:hidden}
.pk .mid .grid{position:absolute;inset:0;background-image:linear-gradient(#35b2e814 1px,transparent 1px),linear-gradient(90deg,#35b2e814 1px,transparent 1px);background-size:4vh 4vh}
.pk .ph{position:relative;height:100%;max-height:100%;max-width:100%}
.pk .ph img{display:block;height:100%;max-width:100%;object-fit:contain;filter:saturate(.75) contrast(1.08) drop-shadow(0 0 18px #35b2e855)}
.pk .mk{position:absolute;transform:translate(-50%,-50%);width:3.4vh;height:3.4vh;border-radius:50%;border:2px solid var(--st);color:#fff;background:#020a0dcc;display:grid;place-items:center;font-size:1.6vh;box-shadow:0 0 10px var(--st)}
.pk .mk::before{content:"";position:absolute;inset:-7px;border-radius:50%;border:1px solid var(--st);animation:pkp 2s infinite;opacity:0}
@keyframes pkp{0%{transform:scale(.7);opacity:.9}100%{transform:scale(1.6);opacity:0}}
.pk .empty{position:relative;text-align:center;color:#7fbfd4;font-size:2vh;padding:4vh;max-width:80%}
.pk .scan{position:absolute;left:0;right:0;height:12%;background:linear-gradient(#35b2e800,#35b2e822,#35b2e800);animation:pks 5s linear infinite;pointer-events:none}
@keyframes pks{from{top:-12%}to{top:100%}}
.pk .ft{display:grid;grid-template-columns:auto 1fr auto;gap:1.6vw;align-items:center;padding:1.2vh 2vw;border-top:1px solid #35b2e855;background:#04141b}
.pk .ft .lb{font-size:1.6vh;letter-spacing:.25em;color:#5fa9c2}
.pk .out{height:2.4vh;border:1px solid #35b2e866;border-radius:4px;display:flex;gap:2px;padding:2px}
.pk .out i{flex:1;background:#0b2230;border-radius:1px}.pk .out i.on{background:#35b2e8;box-shadow:0 0 6px #35b2e8}.pk .out i.on.hot{background:#ff9a3c;box-shadow:0 0 6px #ff9a3c}
.pk .log{font-size:1.7vh;color:#9fd8ea;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:34vw}
.pk .ctl{position:absolute;right:1.4vw;bottom:9vh;display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;opacity:0;transition:opacity .3s;z-index:3;font-family:"DM Sans",system-ui,sans-serif}
.pk.cur .ctl,.pk.edit .ctl{opacity:1}
.pk .ctl select,.pk .ctl button,.pk .ctl label{background:#0b1a22ee;border:1px solid #35b2e877;color:#e8f6ff;border-radius:10px;padding:7px 12px;font-size:14px;cursor:pointer}
.pk.edit{cursor:default}.pk.edit .ph{cursor:crosshair}
.pk .tip{position:absolute;left:50%;top:1.4vh;transform:translateX(-50%);background:#ff9a3c;color:#000;border-radius:8px;padding:6px 12px;font:600 14px "DM Sans",system-ui,sans-serif;z-index:3;white-space:nowrap}
@media (orientation:portrait){.pk .bd{grid-template-columns:1fr 1fr;grid-template-rows:42vh auto}.pk .mid{grid-column:1/3;grid-row:1}.pk .sys{flex:0 0 auto}}`;

  const hash = s => { let h = 7; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
  const fmt = (v, d) => v.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });

  window.openPackMonitor = function () {
    if (!document.getElementById('pk-css')) { const st = document.createElement('style'); st.id = 'pk-css'; st.textContent = CSS; document.head.appendChild(st); }
    if (!document.getElementById('pk-font')) { const l = document.createElement('link'); l.id = 'pk-font'; l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap'; document.head.appendChild(l); }
    const pack = () => (S.settings && S.settings.pack_monitor) || {};
    const crew = S.people.filter(p => ['active', 'rookie'].includes(p.status));
    const todays = () => { const t = todayISO(); const e = upcoming().find(x => x.event_date <= t && (x.end_date || x.event_date) >= t && x.status === 'scheduled'); return e ? S.rsvps.filter(r => r.event_id === e.id && r.answer === 'going').map(r => r.person_id) : []; };
    let saved = null; try { saved = localStorage.getItem('pk-who'); } catch (e) { /* no storage */ }
    let who = saved && (saved === 'cycle' || crew.some(p => p.id === saved)) ? saved : (S.me ? S.me.id : (crew[0] || {}).id);
    let cur = who === 'cycle' ? null : who, cycleIdx = 0, edit = null, timers = [], lock = null;

    const el = document.createElement('div'); el.className = 'pk';
    document.body.appendChild(el);
    const person = () => crew.find(p => p.id === cur) || S.me || crew[0];
    const unit = p => 'PK-' + String(hash(p ? p.id : 'x') % 9000 + 1000);
    const nameLine = p => p ? (p.callsign ? p.callsign : p.full_name) : 'Unassigned';
    const subLine = p => p && p.callsign ? p.full_name : (p && p.title ? p.title : (S.crew.short || 'LAGB'));

    function frame() {
      const p = person(), pk = pack(), marks = pk.marks || {};
      const left = SYS.slice(0, 6), right = SYS.slice(6);
      const card = (s, i) => `<div class="sys" data-k="${s.k}" style="--st:#4ade80"><div class="no">${i + 1}</div><div class="nm">${s.n}</div><div class="v"><span>--</span><small>${s.u}</small></div><div class="st"><i></i><b>ONLINE</b></div></div>`;
      el.innerHTML = `<div class="hd"><div><div class="t">Proton Pack Diagnostics</div><div class="u">UNIT ${unit(p)} &nbsp;//&nbsp; ${esc((S.crew.short || 'LAGB').toUpperCase())} EQUIPMENT DIVISION &nbsp;//&nbsp; <span id="pkclock"></span></div></div>
        <div class="who"><div class="l">PACK ASSIGNED TO</div><div class="nm">${esc(nameLine(p))}</div><div class="u">${esc(subLine(p))}</div></div></div>
      <div class="bd"><div class="col">${left.map((s, i) => card(s, i)).join('')}</div>
        <div class="mid"><div class="grid"></div><div class="scan"></div>${pk.img ? `<div class="ph" id="pkph"><img src="${esc(pk.img)}" alt="Proton pack">${SYS.map((s, i) => marks[s.k] ? `<div class="mk" data-m="${s.k}" style="left:${marks[s.k][0]}%;top:${marks[s.k][1]}%;--st:#4ade80">${i + 1}</div>` : '').join('')}</div>`
          : `<div class="empty">NO PACK IMAGE LOADED<br><br>${can('crew_admin') ? 'Move the mouse and choose "Set up pack" to add a photo of one of our packs.' : 'Ask a crew admin to add a photo of one of our packs.'}</div>`}</div>
        <div class="col">${right.map((s, i) => card(s, i + 6)).join('')}</div></div>
      <div class="ft"><div class="lb">TOTAL OUTPUT</div><div class="out" id="pkout">${'<i></i>'.repeat(40)}</div><div class="log" id="pklog">SYSTEM CHECK...</div></div>
      <div class="ctl"><select id="pkwho"><option value="cycle"${who === 'cycle' ? ' selected' : ''}>Cycle: Busters at today's event</option>${crew.map(c => `<option value="${c.id}"${who === c.id ? ' selected' : ''}>${esc(nameOf(c))}</option>`).join('')}</select>
        ${can('crew_admin') ? '<button id="pkset">Set up pack</button>' : ''}<button id="pkfs">Full screen</button><button id="pkx">Exit</button></div>
      ${edit ? `<div class="tip">${edit.i < SYS.length ? `Tap where the ${SYS[edit.i].n} is (${edit.i + 1} of ${SYS.length}). <u id="pkskip">Skip</u>` : 'Done. Saving...'}</div>` : ''}`;
      wire();
    }

    function wire() {
      $('#pkx', el).onclick = close;
      $('#pkfs', el).onclick = () => (document.fullscreenElement ? document.exitFullscreen() : el.requestFullscreen()).catch(() => {});
      $('#pkwho', el).onchange = e => { who = e.target.value; try { localStorage.setItem('pk-who', who); } catch (x) { /* ignore */ } cur = who === 'cycle' ? nextCycle() : who; frame(); };
      const set = $('#pkset', el); if (set) set.onclick = setup;
      const ph = $('#pkph', el);
      if (edit && ph) ph.onclick = ev => { const r = ph.getBoundingClientRect(); edit.marks[SYS[edit.i].k] = [+(100 * (ev.clientX - r.left) / r.width).toFixed(1), +(100 * (ev.clientY - r.top) / r.height).toFixed(1)]; advance(); };
      const sk = $('#pkskip', el); if (sk) sk.onclick = advance;
    }

    function setup() {
      const inp = document.createElement('input'); inp.type = 'file'; inp.accept = 'image/*';
      inp.onchange = async () => {
        const f = inp.files[0]; if (!f) return;
        const bmp = await createImageBitmap(f).catch(() => null); if (!bmp) return toast("That photo couldn't be opened.");
        const k = Math.min(1, 1100 / Math.max(bmp.width, bmp.height)); const c = document.createElement('canvas'); c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k); c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
        let img = c.toDataURL('image/jpeg', .85); if (img.length > 880000) img = c.toDataURL('image/jpeg', .7);
        S.settings.pack_monitor = { img, marks: {} }; edit = { i: 0, marks: {} }; el.classList.add('edit'); frame();
      };
      if (pack().img && !confirm('Use a new photo? Cancel keeps this photo and lets you re-place the markers.')) { edit = { i: 0, marks: {} }; el.classList.add('edit'); frame(); return; }
      inp.click();
    }
    async function advance() {
      edit.i++;
      if (edit.i < SYS.length) return frame();
      const pk = { img: pack().img, marks: edit.marks }; edit = null; el.classList.remove('edit');
      try { await rpc('set_pack_monitor', { p_crew: S.crew.id, p_pack: pk }); S.settings.pack_monitor = pk; toast('Pack saved'); } catch (e) { /* rpc shows the error */ }
      frame();
    }
    function nextCycle() { const ids = todays(); const list = ids.length ? ids : crew.map(c => c.id); if (!list.length) return null; cycleIdx = (cycleIdx + 1) % list.length; return list[cycleIdx]; }

    // live readings
    let t0 = Date.now();
    function tick() {
      const p = person(), seed = hash(p ? p.id : 'x'), t = (Date.now() - t0) / 1000;
      let total = 0;
      SYS.forEach((s, i) => {
        const ph = (seed % 97) / 10 + i * 1.7;
        const v = s.b + s.r * (Math.sin(t / (2.2 + i * .35) + ph) * .7 + Math.sin(t * 1.9 + ph * 2) * .3);
        const warn = s.warn != null && v >= s.warn;
        const col = warn ? '#ff9a3c' : '#4ade80';
        total += Math.max(0, Math.min(1, (v - (s.b - s.r)) / (2 * s.r)));
        const c = el.querySelector(`.sys[data-k="${s.k}"]`); if (!c) return;
        c.querySelector('.v span').textContent = fmt(v, s.d);
        c.style.setProperty('--st', col); c.classList.toggle('warn', warn);
        c.querySelector('.st b').textContent = warn ? (s.k === 'n_filter' ? 'VENT SOON' : 'RUNNING HOT') : 'ONLINE';
        const m = el.querySelector(`.mk[data-m="${s.k}"]`); if (m) m.style.setProperty('--st', col);
      });
      const n = Math.round(40 * total / SYS.length);
      el.querySelectorAll('#pkout i').forEach((x, k) => { x.classList.toggle('on', k < n); x.classList.toggle('hot', k >= 34); });
      const ck = $('#pkclock', el); if (ck) ck.textContent = new Date().toLocaleTimeString('en-US', { hour12: false });
    }
    let li = 0; const log = () => { const l = $('#pklog', el); if (l) l.textContent = new Date().toLocaleTimeString('en-US', { hour12: false }) + '  ' + LOG[li++ % LOG.length].toUpperCase(); };

    function close() { timers.forEach(clearInterval); if (lock) lock.release().catch(() => {}); if (document.fullscreenElement) document.exitFullscreen().catch(() => {}); el.remove(); document.removeEventListener('keydown', key); }
    const key = e => { if (e.key === 'Escape' && !document.fullscreenElement && !edit) close(); };
    document.addEventListener('keydown', key);
    let hide; el.onmousemove = el.ontouchstart = () => { el.classList.add('cur'); clearTimeout(hide); hide = setTimeout(() => el.classList.remove('cur'), 3000); };
    if (navigator.wakeLock) navigator.wakeLock.request('screen').then(l => { lock = l; }).catch(() => {});
    if (who === 'cycle') cur = nextCycle();
    frame(); tick(); log();
    timers.push(setInterval(tick, 250), setInterval(log, 4000));
    timers.push(setInterval(() => { if (who === 'cycle' && !edit) { cur = nextCycle(); frame(); } }, 20000));
  };
})();

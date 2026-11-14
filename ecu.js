/* Busters: ECU (ecto containment unit) monitor.
   Opens from Proton Pack Diagnostics with the PACK | ECU switch (the pack is always the default), or on its own
   from ecu.html (public demo). Crew agnostic: it uses the crew's short name, events and people, and nothing
   about any one charity. Trap drop-offs come from the crew's finished events: one drop-off per event, credited
   to a Buster who was Going. Hospital and children's visits never produce captures. Everything else
   (field, power, faults, the inspector) is simulated.
   window.BustersECU.mount(ctx, api) -> { tone(audio), destroy() }
     ctx: { S, esc, todayISO, demo }
     api: { back() (to the pack, optional), exit(), sound() -> bool, setSound(on), audioCtx (standalone only) } */
(function () {
  // Never any ghosts from these (category Hospital is checked too).
  const NO_GHOSTS = /hospital|child|kids|pediatric|patient|medical|clinic|hospice|ronald mcdonald|cancer|chla/i;
  const CLS = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];
  const CLS_W = [30, 28, 20, 11, 6, 3, 2]; // percent chance of each class
  const CLS_C = ['#8dffb8', '#5fe3ff', '#86a6ff', '#c58bff', '#ff6ad5', '#ffa14a', '#ff5a46'];
  const KINDS = ['FREE-FLOATING VAPOR', 'FOCUSED REPEATER', 'ROAMING VAPOR', 'PARTIAL APPARITION', 'FULL-TORSO APPARITION',
    'ECTO RESIDUE', 'POLTERGEIST', 'SHADOW FORM', 'COLD SPOT', 'ORB CLUSTER'];
  const FAULTS = [['COOLANT FLOW LOW', 'warn'], ['FIELD HARMONIC DRIFT', 'warn'], ['SEAL PRESSURE DIP // PORT GASKET', 'warn'],
    ['UNAUTHORIZED ACCESS ATTEMPT // PANEL 3', 'warn'], ['GRID COIL 4 RUNNING HOT', 'warn'], ['LAMP 2 FILAMENT FLICKER', 'fail'],
    ['ECTO CONDENSATE IN DRAIN LINE', 'warn'], ['RELAY CHATTER // BUS B', 'warn'], ['SENSOR 7 NOT REPORTING', 'fail']];
  const LORE = ['DO NOT SHUT OFF THIS UNIT', 'CONTAINMENT IS NOT A STORAGE CLOSET', 'NO FOOD OR DRINK NEAR THE TRAP PORT',
    'KEEP HANDS OFF THE GRID', 'DO NOT TAP ON THE GLASS', 'IF THE RED LIGHT IS ON, LEAVE IT ON', 'THIS UNIT IS NOT A MICROWAVE',
    'ENTITIES ARE NOT PETS // DO NOT NAME THEM', 'EMPTY TRAPS GO BACK ON THE RACK'];
  const TECH = ['PING: TELEMETRY REFRESHED', 'GRID: PHASE BALANCE OK', 'SEALS: PRESSURE HOLDING', 'COOLANT: LOOP NOMINAL',
    'FIELD: HARMONICS WITHIN LIMITS', 'BACKUP: CELLS ON STANDBY', 'PORT: INTERLOCK VERIFIED', 'SCRUBBER: PARTICULATE LOW'];
  const RATE = 0.31; // $ per kWh for the bill estimate

  const hash = s => { let h = 7; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; h ^= h >>> 16; h = Math.imul(h, 0x85ebca6b) >>> 0; h ^= h >>> 13; h = Math.imul(h, 0xc2b2ae35) >>> 0; return (h ^ (h >>> 16)) >>> 0; }; // mixed so ids that differ by one letter still spread out
  const fmt = (v, d = 0) => Number(v).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });
  const clock = () => new Date().toLocaleTimeString('en-US', { hour12: false });
  const day = d => new Date(d + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' }).toUpperCase().replace(',', '');
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const rnd = (a, b) => a + Math.random() * (b - a);
  const upName = p => String((p && p.full_name) || 'UNKNOWN').toUpperCase();

  function lineClass(t) {
    if (/^CRITICAL/.test(t)) return 'critical';
    if (/^FAULT/.test(t)) return 'fail';
    if (/^OK:|RESTORED|DENIED|CLEARED|SETTLED/.test(t)) return 'recover';
    if (/^WARN|^INSPECTOR|^GRID: VOLTAGE|^BACKUP: CELLS ENGAGED/.test(t)) return 'warn';
    if (/^(LINK|BOOT|CALM)/.test(t)) return 'boot';
    if (LORE.includes(t)) return 'advisory';
    return 'routine';
  }

  // Trap drop-offs from the crew's finished events (newest first). Codes number each month's spirits in order.
  function captures(S, today) {
    const short = String((S.crew && S.crew.short) || 'CREW').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6) || 'CREW';
    const person = id => S.people.find(p => p.id === id);
    const drops = [];
    (S.events || []).forEach(e => {
      const d = e.end_date || e.event_date;
      if (!d || d >= today || e.date_tbd || ['cancelled', 'proposed'].includes(e.status)) return;
      if (e.category === 'Hospital' || NO_GHOSTS.test((e.title || '') + ' ' + (e.category || ''))) return;
      const going = (S.rsvps || []).filter(r => r.event_id === e.id && r.answer === 'going').map(r => person(r.person_id)).filter(Boolean);
      if (!going.length) return; // nobody worked it, nobody dropped off a trap
      const h = hash(e.id), n = 1 + h % 3 + (going.length >= 8 ? 1 : 0);
      const spirits = [];
      for (let i = 0; i < n; i++) {
        const hi = hash(e.id + ':' + i); let r = hi % 100, c = 0;
        while (c < 6 && r >= CLS_W[c]) { r -= CLS_W[c]; c++; }
        spirits.push({ id: e.id + ':' + i, cls: c, kind: KINDS[(hi >>> 7) % KINDS.length], mj: +(Math.pow(c + 1, 1.4) * (0.8 + ((hi >>> 11) % 40) / 100)).toFixed(1) });
      }
      drops.push({ id: e.id, date: d, by: going[(h >>> 3) % going.length], event: e.title || 'Event', spirits });
    });
    drops.sort((a, b) => a.date.localeCompare(b.date) || String(a.id).localeCompare(String(b.id)));
    const seq = {};
    drops.forEach(dr => dr.spirits.forEach(s => { const ym = dr.date.slice(2, 4) + dr.date.slice(5, 7); seq[ym] = (seq[ym] || 0) + 1; s.code = `${short}-${ym}-${String(seq[ym]).padStart(3, '0')}`; s.date = dr.date; s.by = dr.by; s.event = dr.event; }));
    return drops.reverse();
  }

  const BOLTS = 'radial-gradient(circle at 50% 50%,#f0c7bd 0 1px,#8a3328 1.6px 2.7px,#0000 3px)';
  const CSS = `
.ecu{position:fixed;inset:0;z-index:101;color:#ffcf8a;font-family:"Share Tech Mono",ui-monospace,Menlo,monospace;font-size:clamp(11px,1.6vh,15px);
  background:#8c1a10;
  display:grid;grid-template-columns:minmax(0,1fr);grid-template-rows:auto auto minmax(0,1fr);-webkit-user-select:none;user-select:none;
  padding:env(safe-area-inset-top) env(safe-area-inset-right) 0 env(safe-area-inset-left)}
.ecu *{box-sizing:border-box}
.ecu .pl{position:relative;padding:9px;border-radius:8px;box-shadow:inset 0 0 0 1px #ffffff47,inset 0 0 0 2px #0003,0 1px 0 #ffffff14}
.ecu .pl::before{content:"";position:absolute;inset:2px;pointer-events:none;background:${BOLTS} 0 0/7px 7px no-repeat,${BOLTS} 100% 0/7px 7px no-repeat,${BOLTS} 0 100%/7px 7px no-repeat,${BOLTS} 100% 100%/7px 7px no-repeat}
.ecu .scr{position:relative;background:#0b0504;border-radius:5px;padding:7px 9px;box-shadow:inset 0 2px 12px #000,inset 0 0 0 1px #000;overflow:hidden}
.ecu .scr::after{content:"";position:absolute;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,#0000 0 2px,#0005 2px 3px)}
.ecu .lbl{font-size:.72em;letter-spacing:.18em;color:#ffe9d0;opacity:.85;margin:0 0 5px;text-shadow:0 1px 0 #0008;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ecu .g{color:#ffb347;text-shadow:0 0 6px #ff8a00aa}
.ecu .ok{color:#6dff9a;text-shadow:0 0 6px #2bff6a99}.ecu .wn{color:#ffc24a;text-shadow:0 0 6px #ff9a00}.ecu .bd{color:#ff5a46;text-shadow:0 0 8px #ff2a1a}
.ecu .haz{height:10px;background:repeating-linear-gradient(-45deg,#f2b705 0 10px,#141414 10px 20px);box-shadow:0 1px 0 #0009,0 -1px 0 #0009}
/* caged lamps */
.ecu .lamp{--lc:#ffb000;width:22px;height:22px;border-radius:50%;flex:0 0 auto;position:relative;background:radial-gradient(circle at 40% 35%,#fff6d8,var(--lc) 45%,color-mix(in srgb,var(--lc) 40%,#000) 78%);box-shadow:0 0 10px var(--lc),0 0 22px color-mix(in srgb,var(--lc) 55%,transparent)}
.ecu .lamp::after{content:"";position:absolute;inset:-3px;border-radius:50%;border:2px solid #262626;background:repeating-linear-gradient(0deg,#0000 0 4px,#1e1e1e 4px 5.5px),repeating-linear-gradient(90deg,#0000 0 4px,#1e1e1e 4px 5.5px);-webkit-mask:radial-gradient(circle,#000 68%,#0000 70%),linear-gradient(#000 0 0);mask:radial-gradient(circle,#000 68%,#0000 70%),linear-gradient(#000 0 0)}
.ecu .lamp.gr{--lc:#3dff7a}.ecu .lamp.rd{--lc:#ff2a1a}.ecu .lamp.dim{filter:brightness(.35) saturate(.6);box-shadow:none}
.ecu .lamp.bl{animation:ecbl .5s steps(2) infinite}
@keyframes ecbl{50%{filter:brightness(.3);box-shadow:none}}
/* header */
.ecu .eh{display:flex;align-items:center;gap:9px;margin:6px 6px 6px;padding:7px 9px}
.ecu .et{min-width:0;flex:1}
.ecu .t1{font-size:1.05em;letter-spacing:.12em;color:#fff;text-shadow:0 0 6px #ff6a3c,0 1px 0 #000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ecu .t1 .nr{display:none}@media (max-width:480px){.ecu .t1 .wd{display:none}.ecu .t1 .nr{display:inline}}
.ecu .t2{font-size:.74em;letter-spacing:.14em;color:#ffd9b0;opacity:.85;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ecu .seg{display:inline-flex;border:1px solid #ffffff55;border-radius:6px;overflow:hidden;background:#0008;flex:0 0 auto}
.ecu .seg button{font:inherit;font-size:.72em;letter-spacing:.1em;padding:4px 9px;min-height:28px;background:transparent;color:#ffcf8a;border:0;cursor:pointer}
.ecu .seg button.on{background:#ffb34733;color:#fff}
.ecu .ib{font:inherit;width:32px;height:32px;border-radius:50%;border:1px solid #ffffff55;background:#0008;color:#ffcf8a;cursor:pointer;flex:0 0 auto;font-size:.9em}
.ecu .ib.on{color:#fff;border-color:#ffb347;box-shadow:0 0 8px #ffb34766}
/* body: phone first, one scrolling column */
.ecu .eb{overflow-y:auto;overflow-x:hidden;padding:8px 8px calc(12px + env(safe-area-inset-bottom));display:grid;grid-template-columns:minmax(0,1fr);gap:9px;align-content:start;-webkit-overflow-scrolling:touch}
.ecu .col{display:grid;gap:9px;min-width:0;align-content:start}
.ecu .vpw{position:relative;width:100%;aspect-ratio:4/3;max-height:46vh;margin:0 auto;touch-action:manipulation;background:#030806;border-radius:5px;box-shadow:inset 0 2px 12px #000,inset 0 0 0 1px #000;overflow:hidden}
.ecu .vpw canvas{position:absolute;inset:0;width:100%;height:100%;display:block;cursor:pointer}
.ecu .vpl{text-align:center;font-size:.72em;letter-spacing:.16em;color:#ffe9d0;opacity:.85;margin-top:6px}
.ecu .elog{margin-top:7px;height:calc(8 * 1.45em + 14px);font-size:.85em;line-height:1.45}
.ecu .elog div{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;position:relative;z-index:1}
.ecu .elog div:nth-child(n+3){opacity:.85}.ecu .elog div:nth-child(n+6){opacity:.6}
.ecu .card{position:absolute;left:8%;right:8%;bottom:9%;z-index:2;background:#0b0504ee;border:1px solid var(--c,#ffb347);border-radius:6px;padding:7px 10px;font-size:.82em;line-height:1.45;box-shadow:0 0 14px color-mix(in srgb,var(--c,#ffb347) 45%,transparent);display:none}
.ecu .card.on{display:block}
.ecu .card b{color:#fff;font-weight:400;text-shadow:0 0 6px var(--c)}
.ecu .card .x{position:absolute;right:6px;top:4px;opacity:.7}
/* gauges */
.ecu .gg{display:grid;grid-template-columns:1fr 1fr;gap:6px 8px;align-items:end}
.ecu .gg .big{grid-column:1/-1}
.ecu .gg svg{width:100%;height:auto;display:block;overflow:visible}
.ecu svg .ar{fill:none;stroke-width:7}
.ecu svg .tk{stroke:#ffcf8a88;stroke-width:1}
.ecu svg .nd{stroke:#fff;stroke-width:2;stroke-linecap:round;filter:drop-shadow(0 0 3px #ff8a00)}
.ecu svg .hub{fill:#2a2a2a;stroke:#999;stroke-width:1}
.ecu svg .vt{fill:#ffb347;font:15px "Share Tech Mono",monospace;text-anchor:middle;filter:drop-shadow(0 0 4px #ff8a00)}
.ecu svg .vt.sm{font-size:12px}
.ecu svg .ut{fill:#ffcf8a;font:7px "Share Tech Mono",monospace;letter-spacing:.14em;text-anchor:middle;opacity:.8}
/* readouts */
.ecu .rw{display:flex;justify-content:space-between;align-items:baseline;gap:8px;line-height:1.6;white-space:nowrap}
.ecu .rw span{opacity:.75;overflow:hidden;text-overflow:ellipsis}
.ecu .rw b{font-weight:400}
.ecu .kw{font-size:2.1em;line-height:1.05;color:#fff;text-shadow:0 0 8px #ff8a00,0 0 18px #ff6a0088}
.ecu .kw small{font-size:.45em;letter-spacing:.12em;color:#ffcf8a;margin-left:4px}
.ecu .sp{width:100%;height:46px;display:block;margin:4px 0 2px}
.ecu .bar{height:10px;border:1px solid #ffcf8a66;border-radius:2px;padding:1px;margin-top:3px}
.ecu .bar u{display:block;height:100%;background:#6dff9a;box-shadow:0 0 8px #2bff6a;transition:width .3s}
.ecu .bar.lo u{background:#ffb000;box-shadow:0 0 8px #ffb000}
.ecu .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;background:currentColor;box-shadow:0 0 6px currentColor;vertical-align:1px}
/* lists */
.ecu .lst{min-height:220px;display:flex;flex-direction:column}
.ecu .lst .seg{align-self:flex-start;margin-bottom:7px}
.ecu .lb{overflow-y:auto;flex:1;min-height:0;font-size:.85em;line-height:1.45;position:relative;z-index:1}
.ecu .dr{padding:6px 0 7px;border-bottom:1px solid #ffcf8a22}
.ecu .dr .dh{display:flex;justify-content:space-between;gap:8px;color:#fff;letter-spacing:.06em}
.ecu .dr .ev{opacity:.6;font-size:.88em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ecu .chip{display:inline-block;margin:3px 4px 0 0;padding:1px 6px;border:1px solid color-mix(in srgb,var(--c) 70%,transparent);border-radius:3px;color:var(--c);text-shadow:0 0 5px color-mix(in srgb,var(--c) 70%,transparent);font-size:.88em;cursor:pointer;white-space:nowrap}
.ecu .lc-routine{color:#c98a4a}.ecu .lc-boot{color:#ffe9d0;text-shadow:0 0 6px #ff8a00}.ecu .lc-advisory{color:#5fe3ff;text-shadow:0 0 6px #35b2e8}
.ecu .lc-recover{color:#b6ff6a;text-shadow:0 0 6px #7dff3a}.ecu .lc-warn{color:#ffc24a;text-shadow:0 0 6px #ff9a00}
.ecu .lc-fail{color:#ff5a46;text-shadow:0 0 8px #ff2a1a}.ecu .lc-critical{color:#fff;background:#5a0b05;text-shadow:0 0 8px #ff2a1a;padding:0 4px;border-radius:2px}
/* inspector */
.ecu .insp{position:absolute;inset:0;z-index:8;display:none;place-items:center;padding:4vh 4vw;background:#000a}
.ecu .insp.on{display:grid}
.ecu .insp .bx{width:min(520px,94vw);border:1px solid #ffb000;border-radius:6px;background:#140a02;color:#ffb000;text-align:center;overflow:hidden;box-shadow:0 0 30px #ffb00055,inset 0 0 26px #ffb00033;animation:ecal 1s infinite}
@keyframes ecal{50%{box-shadow:0 0 50px #ffb00088,inset 0 0 40px #ffb00055}}
.ecu .insp .in{padding:18px 16px 20px}
.ecu .insp .h1{color:#fff;font-size:clamp(22px,4vh,40px);letter-spacing:.08em;line-height:1.1;text-shadow:0 0 10px #ffb000}
.ecu .insp p{margin:10px 0 0;letter-spacing:.12em;font-size:.95em}
.ecu .insp button{font:inherit;margin-top:16px;font-size:1.2em;letter-spacing:.2em;padding:12px 34px;border-radius:8px;background:#ffb000;color:#140a02;border:0;cursor:pointer;box-shadow:0 0 16px #ffb000aa}
.ecu .insp .cd{margin-top:10px;font-size:.8em;opacity:.8}
/* wide screens and phones turned sideways: a full control panel, three columns */
@media (min-aspect-ratio:1/1) and (min-width:700px){
  .ecu .eb{grid-template-columns:minmax(0,1fr) minmax(0,1.35fr) minmax(0,1fr);overflow:hidden;align-content:stretch}
  .ecu .col{overflow-y:auto;min-height:0}
  .ecu .c1{order:2}.ecu .c2{order:1}.ecu .c3{order:3}
  .ecu .c3 .lst{height:100%}
  .ecu .c1 .pl{display:flex;flex-direction:column;min-height:100%}.ecu .c1 .elog{flex:1;height:auto;min-height:calc(6 * 1.45em + 14px)}
  .ecu .vpw{max-height:calc(100vh - 190px)}
}
@media (min-aspect-ratio:1/1) and (min-width:700px) and (max-height:500px){.ecu .eh{margin:4px 6px;padding:4px 8px}.ecu .vpw{max-height:calc(100vh - 150px)}}`;

  // Gauges: angles in degrees, 0 is straight up, clockwise positive.
  const P = (cx, cy, r, a) => [cx + r * Math.sin(a * Math.PI / 180), cy - r * Math.cos(a * Math.PI / 180)];
  const arc = (cx, cy, r, a1, a2) => { const [x1, y1] = P(cx, cy, r, a1), [x2, y2] = P(cx, cy, r, a2); return `M${x1.toFixed(1)} ${y1.toFixed(1)}A${r} ${r} 0 ${a2 - a1 > 180 ? 1 : 0} 1 ${x2.toFixed(1)} ${y2.toFixed(1)}`; };
  function gauge(id, g) {
    const { min, max, a1, a2, zones, label, w, h, cx, cy, r } = g, ang = v => a1 + (a2 - a1) * (clamp(v, min, max) - min) / (max - min);
    let ticks = ''; for (let i = 0; i <= 10; i++) { const a = a1 + (a2 - a1) * i / 10, [x1, y1] = P(cx, cy, r - 8, a), [x2, y2] = P(cx, cy, r - (i % 5 ? 12 : 15), a); ticks += `<line class="tk" x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}"/>`; }
    return `<svg viewBox="0 0 ${w} ${h}" aria-label="${label}">
      ${zones.map(([z1, z2, c]) => `<path class="ar" stroke="${c}" opacity=".85" d="${arc(cx, cy, r, ang(z1), ang(z2))}"/>`).join('')}${ticks}
      <line class="nd" id="${id}n" x1="${cx}" y1="${cy}" x2="${cx}" y2="${cy - r + 9}" transform="rotate(${a1} ${cx} ${cy})"/><circle class="hub" cx="${cx}" cy="${cy}" r="4"/>
      <text class="vt${g.small ? ' sm' : ''}" id="${id}v" x="${cx}" y="${cy + (g.small ? 18 : -14)}">--</text><text class="ut" x="${cx}" y="${cy + (g.small ? 46 : -4)}">${label}</text></svg>`;
  }
  const G = {
    fld: { min: 70, max: 100, a1: -90, a2: 90, w: 120, h: 68, cx: 60, cy: 62, r: 54, label: 'CONTAINMENT FIELD %', zones: [[70, 88, '#ff3b2f'], [88, 95, '#ffb000'], [95, 100, '#3dff7a']] },
    tmp: { min: 0, max: 80, a1: -135, a2: 135, w: 120, h: 106, cx: 60, cy: 54, r: 46, label: 'CORE TEMP °C', small: 1, zones: [[0, 45, '#3dff7a'], [45, 60, '#ffb000'], [60, 80, '#ff3b2f']] },
    prs: { min: 0, max: 800, a1: -135, a2: 135, w: 120, h: 106, cx: 60, cy: 54, r: 46, label: 'PRESSURE kPa', small: 1, zones: [[0, 520, '#3dff7a'], [520, 640, '#ffb000'], [640, 800, '#ff3b2f']] }
  };
  const needle = (el, id, v, d) => { const g = G[id], a = g.a1 + (g.a2 - g.a1) * (clamp(v, g.min, g.max) - g.min) / (g.max - g.min);
    const n = el.querySelector('#e' + id + 'n'); if (n) n.setAttribute('transform', `rotate(${a.toFixed(1)} ${g.cx} ${g.cy})`);
    const t = el.querySelector('#e' + id + 'v'); if (t) t.textContent = fmt(v, d); };

  // Glowing sprite per class, drawn once.
  const sprites = CLS_C.map(c => { const s = document.createElement('canvas'); s.width = s.height = 64; const x = s.getContext('2d'), g = x.createRadialGradient(32, 32, 0, 32, 32, 32);
    g.addColorStop(0, '#ffffffee'); g.addColorStop(.22, c + 'dd'); g.addColorStop(.55, c + '44'); g.addColorStop(1, c + '00'); x.fillStyle = g; x.fillRect(0, 0, 64, 64); return s; });

  window.BustersECU = { mount(ctx, api) {
    const { S, esc } = ctx;
    if (!document.getElementById('ecu-css')) { const st = document.createElement('style'); st.id = 'ecu-css'; st.textContent = CSS; document.head.appendChild(st); }
    if (!document.getElementById('pk-font')) { const l = document.createElement('link'); l.id = 'pk-font'; l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap'; document.head.appendChild(l); }
    const today = ctx.todayISO ? ctx.todayISO() : new Date().toISOString().slice(0, 10);
    const short = String((S.crew && S.crew.short) || 'CREW').toUpperCase();
    const drops = captures(S, today), spirits = drops.flatMap(d => d.spirits);
    const totalMJ = spirits.reduce((a, s) => a + s.mj, 0);
    const crew = (S.people || []).filter(p => ['active', 'rookie'].includes(p.status));
    const buzz = p => { try { navigator.vibrate && navigator.vibrate(p); } catch (e) { /* ignore */ } };
    const t0 = performance.now(), secs = () => (performance.now() - t0) / 1000;

    // simulated state
    const st = { field: 99.2, temp: 31, kpa: 410, kw: 0, batt: 100, grid: true, brownEnd: 0, nextBrown: rnd(40, 80), agit: 0, calming: false,
      faults: {}, insp: null, nextInsp: ctx.demo ? rnd(55, 85) : rnd(150, 330), inspDone: false, lvl: 0 };
    let logLines = [], list = 'cap', sel = null, timers = [], raf = 0, lastEgg = -999, lastLine = '', ownAudio = null;

    // 24 hours of power history in 15 minute steps, the last point is now.
    const baseKW = 9.5 + Math.min(30, totalMJ * 0.12);
    const hist = []; { const now = new Date(); for (let i = 95; i >= 0; i--) { const t = new Date(now - i * 900000), hr = t.getHours() + t.getMinutes() / 60, h = hash(today + ':' + i) % 100 / 100;
      hist.push(baseKW + 2.2 * Math.sin((hr - 9) / 24 * 2 * Math.PI) + h * 1.6 + (h > .95 ? 3 : 0)); } }
    const mins = new Date().getHours() * 60 + new Date().getMinutes();
    const avgDaily = hist.reduce((a, v) => a + v, 0) / hist.length * 24;

    // service schedule (derived from the date so everyone sees the same thing)
    const now0 = new Date(), dom = now0.getDate();
    const nextInspection = new Date(now0.getFullYear(), now0.getMonth() + 1, 1);
    const filterIn = 30 - (Math.floor(now0 / 864e5) % 30);
    const lastSat = new Date(now0); lastSat.setDate(now0.getDate() - ((now0.getDay() + 1) % 7 || 7));
    const wk = Math.floor(lastSat / 6048e5), tech = crew.length ? crew[hash('svc' + wk) % crew.length] : null;
    const sealIn = 14 - (Math.floor(now0 / 864e5) % 14);

    const el = document.createElement('div'); el.className = 'ecu'; document.body.appendChild(el);
    const $ = s => el.querySelector(s);
    const last = drops[0];
    el.innerHTML = `<div class="eh pl">
        <span class="lamp gr" id="eL1"></span>
        <div class="et"><div class="t1">${esc(short)} // <span class="wd">CONTAINMENT UNIT</span><span class="nr">ECU</span></div><div class="t2" id="esub">ECU REMOTE LINK // ${spirits.length} ENTITIES</div></div>
        ${api.back ? '<div class="seg"><button id="ebk">PACK</button><button class="on">ECU</button></div>' : ''}
        <button class="ib" id="esnd" aria-label="Sound">&#9835;</button><button class="ib" id="ex" aria-label="Exit">&#10005;</button>
        <span class="lamp dim" id="eL2"></span></div>
      <div class="haz"></div>
      <div class="eb">
        <div class="col c1"><div class="pl">
          <div class="vpw" id="evw"><canvas id="evp"></canvas><div class="card" id="ecard"></div></div>
          <div class="vpl">CHAMBER FEED // TAP AN ENTITY // HOLD TO CALM</div>
          <div class="scr elog" id="etick"></div></div></div>
        <div class="col c2">
          <div class="pl"><div class="lbl">FIELD // CORE</div><div class="scr gg"><div class="big">${gauge('efld', G.fld)}</div><div>${gauge('etmp', G.tmp)}</div><div>${gauge('eprs', G.prs)}</div></div></div>
          <div class="pl"><div class="lbl">POWER // GRID FEED</div><div class="scr">
            <div class="rw"><span>GRID DRAW</span><b id="egs" class="ok">ONLINE</b></div>
            <div class="kw" id="ekw">--<small>kW</small></div>
            <svg class="sp" id="esp" viewBox="0 0 200 46" preserveAspectRatio="none"></svg>
            <div class="rw"><span>LAST 24 HOURS</span><b id="epk" class="g"></b></div>
            <div class="rw"><span>TODAY</span><b class="g" id="etd"></b></div>
            <div class="rw"><span>THIS MONTH</span><b class="g" id="emo"></b></div>
            <div class="rw"><span>EST. UTILITY BILL</span><b class="g" id="ebl"></b></div>
            <div class="rw" style="margin-top:4px"><span>BACKUP CELLS</span><b id="ebs" class="ok">STANDBY</b></div>
            <div class="bar" id="ebb"><u id="ebu" style="width:100%"></u></div></div></div>
          <div class="pl"><div class="lbl">TRAP PORT // LOCKS</div><div class="scr">
            <div class="rw"><span>TRAP PORT</span><b class="ok" id="eport"><i class="dot"></i>SEALED</b></div>
            <div class="rw"><span>INTERLOCK</span><b class="ok" id="eilk"><i class="dot"></i>ENGAGED</b></div>
            <div class="rw"><span>LAST TRAP LOADED</span><b class="g">${last ? day(last.date) : 'NONE YET'}</b></div>
            ${last ? `<div class="rw"><span>LOADED BY</span><b class="g">${esc(upName(last.by))}</b></div>` : ''}
            <div class="rw"><span>ENTITIES CONTAINED</span><b class="g">${spirits.length}</b></div>
            <div class="rw"><span>CONTAINED ENERGY</span><b class="g">${fmt(totalMJ, 1)} MJ</b></div></div></div>
        </div>
        <div class="col c3"><div class="pl lst"><div class="seg" id="eseg"><button data-l="cap">CAPTURES</button><button data-l="flt">FAULTS</button><button data-l="svc">SERVICE</button></div>
          <div class="scr lb" id="elist"></div></div></div>
      </div>
      <div class="insp" id="einsp"><div class="bx"><div class="haz"></div><div class="in">
        <div style="letter-spacing:.2em;font-size:.8em;opacity:.85">NOTICE // ${esc(short)} CONTAINMENT</div>
        <div class="h1" style="margin-top:10px">OUTSIDE INSPECTOR<br>ON SITE</div>
        <p>SHUTDOWN ORDER RECEIVED FOR THIS UNIT</p><p style="opacity:.8">FIELD IS DROPPING WHILE THE PANEL IS OPEN</p>
        <button id="edeny">DENY</button><div class="cd" id="einc"></div></div><div class="haz"></div></div></div>`;

    // sparkline
    function spark() {
      const sp = $('#esp'); if (!sp) return;
      const lo = Math.min(...hist) - 1, hi = Math.max(...hist) + 1, pts = hist.map((v, i) => `${(i / (hist.length - 1) * 200).toFixed(1)},${(44 - (v - lo) / (hi - lo) * 42).toFixed(1)}`).join(' ');
      sp.innerHTML = `<polyline points="0,46 ${pts} 200,46" fill="#ffb34722" stroke="none"/><polyline points="${pts}" fill="none" stroke="#ffb347" stroke-width="1.4" vector-effect="non-scaling-stroke" style="filter:drop-shadow(0 0 3px #ff8a00)"/>`;
      $('#epk').textContent = 'PEAK ' + fmt(Math.max(...hist), 1) + ' kW';
    }

    // lists
    function renderList() {
      el.querySelectorAll('#eseg button').forEach(b => b.classList.toggle('on', b.dataset.l === list));
      const box = $('#elist'); if (!box) return;
      if (list === 'cap') {
        box.innerHTML = `<div class="rw" style="margin-bottom:2px"><span>DROP-OFFS ${drops.length}</span><b class="g">ENTITIES ${spirits.length}</b></div>` + (drops.length ? drops.map(d => `<div class="dr">
          <div class="dh"><span>${day(d.date)}</span><span>${d.spirits.length} ${d.spirits.length === 1 ? 'SPIRIT' : 'SPIRITS'}</span></div>
          <div class="g">TRAP DROP-OFF // ${esc(upName(d.by))}</div><div class="ev">${esc(d.event)}</div>
          <div>${d.spirits.map(s => `<span class="chip" data-sp="${esc(s.id)}" style="--c:${CLS_C[s.cls]}">CL ${CLS[s.cls]} ${esc(s.kind)}</span>`).join('')}</div></div>`).join('')
          : '<div style="padding:10px 0;opacity:.75">NO TRAPS LOADED YET. CAPTURES APPEAR HERE AFTER THE CREW WORKS AN EVENT.</div>');
        box.querySelectorAll('[data-sp]').forEach(c => c.onclick = () => pick(c.dataset.sp));
      } else if (list === 'flt') {
        box.innerHTML = logLines.length ? logLines.map(x => `<div class="lc-${x.c}">&gt; ${esc(x.t)}</div>`).join('') : '<div style="opacity:.7">NO EVENTS LOGGED</div>';
      } else {
        const sd = d => d.toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' }).toUpperCase().replace(',', '');
        const row = (a, b, c = 'g') => `<div class="rw"><span>${a}</span><b class="${c}">${b}</b></div>`;
        box.innerHTML = row('NEXT INSPECTION', sd(nextInspection)) + row('GRID FILTER CHANGE', filterIn <= 2 ? 'DUE IN ' + filterIn + ' DAYS' : 'IN ' + filterIn + ' DAYS', filterIn <= 2 ? 'wn' : 'g') +
          row('SEAL CHECK', 'IN ' + sealIn + ' DAYS') + row('COOLANT TOP-OFF', dom <= 7 ? 'DONE THIS MONTH' : 'DUE ' + sd(new Date(now0.getFullYear(), now0.getMonth() + 1, 7))) +
          row('LAMP BULBS', 'CHECKED ' + sd(lastSat)) + row('LAST SERVICED', sd(lastSat)) + row('SERVICED BY', tech ? esc(upName(tech)) : 'UNASSIGNED') +
          row('UNIT HOURS', fmt(41000 + (hash(short) % 9000) + Math.floor(now0 / 36e5) % 9000)) + `<div style="margin-top:8px;opacity:.6;font-size:.9em">SERVICE NOTES: FILTERS ARE CHANGED FROM THE OUTSIDE PANEL ONLY. NEVER OPEN THE PORT TO CHECK ON AN ENTITY.</div>`;
      }
    }

    function log(t) { logLines.unshift({ t: clock() + '  ' + t, c: lineClass(t) }); logLines = logLines.slice(0, 80);
      const k = $('#etick'); if (k) { // rolling status log, newest first, as many lines as fit
        k.innerHTML = logLines.slice(0, 14).map(x => `<div class="lc-${x.c}">&gt; ${esc(x.t)}</div>`).join('');
        while (k.children.length > 1 && k.scrollHeight > k.clientHeight + 1) k.lastElementChild.remove(); }
      if (list === 'flt') renderList(); }

    // viewport: wisps for the newest 40 entities
    const shown = spirits.slice(0, 40);
    const W = shown.map((s, i) => { const h = hash(s.id); return { s, x: ((h % 100) / 100 - .5) * 1.2, y: (((h >>> 8) % 100) / 100 - .5) * 1.2, a: (h % 628) / 100, z: .7, ph: (h % 1000) / 160, f1: .3 + (h % 50) / 100, f2: .9 + ((h >>> 5) % 50) / 60, sp: .1 + (s.cls * .03) + ((h >>> 9) % 20) / 200, tr: [] }; });
    const cv = $('#evp');
    let geo = { cx: 0, cy: 0, Rg: 1 }, lastT = performance.now();
    function draw() {
      const nowT = performance.now(), dt = Math.min(.05, (nowT - lastT) / 1000); lastT = nowT;
      const r = cv.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1), w = Math.round(r.width * dpr), h = Math.round(r.height * dpr);
      if (!w || !h) { raf = requestAnimationFrame(draw); return; }
      if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
      const x = cv.getContext('2d'), cx = w / 2, cy = h / 2, hx = w / 2 * .9, hy = h / 2 * .86, U = Math.min(w, h) / 2, t = nowT / 1000; geo = { dpr };
      x.globalCompositeOperation = 'source-over';
      let g = x.createRadialGradient(cx, cy, 0, cx, cy, Math.max(w, h) * .6); g.addColorStop(0, '#0b1d18'); g.addColorStop(1, '#010403'); x.fillStyle = g; x.fillRect(0, 0, w, h);
      x.strokeStyle = '#7fffd412'; x.lineWidth = dpr; for (let k = 1; k < 8; k++) { x.beginPath(); x.moveTo(w * k / 8, 0); x.lineTo(w * k / 8, h); x.stroke(); } for (let k = 1; k < 6; k++) { x.beginPath(); x.moveTo(0, h * k / 6); x.lineTo(w, h * k / 6); x.stroke(); }
      if (!shown.length) { x.fillStyle = '#ffcf8a99'; x.font = `${Math.round(U * .09)}px "Share Tech Mono",monospace`; x.textAlign = 'center'; x.fillText('NO ENTITIES IN CONTAINMENT', cx, cy); }
      const ag = st.agit * (st.calming ? .25 : 1);
      x.globalCompositeOperation = 'lighter';
      W.forEach(p => {
        p.a += (Math.sin(t * p.f1 + p.ph) * 1.3 + Math.sin(t * p.f2 + p.ph * 2) * .7) * dt * (1 + ag * 2.5);
        const sp = p.sp * (1 + ag * 3) * (st.calming ? .35 : 1);
        p.x += Math.cos(p.a) * sp * dt; p.y += Math.sin(p.a) * sp * dt;
        if (ag > .3) { p.x += (Math.random() - .5) * ag * .012; p.y += (Math.random() - .5) * ag * .012; }
        if (Math.abs(p.x) > 1 || Math.abs(p.y) > 1) { p.a = Math.atan2(-p.y, -p.x) + (Math.random() - .5) * 1.4; p.x = clamp(p.x, -1, 1); p.y = clamp(p.y, -1, 1); }
        p.z += ((.62 + ag * .55 + .12 * Math.sin(t * p.f2 + p.ph)) - p.z) * dt * 2;
        const px = cx + p.x * hx, py = cy + p.y * hy, size = U * (.08 + p.s.cls * .016) * p.z * (1 + .08 * Math.sin(t * 5 + p.ph));
        p.tr.unshift([px, py]); if (p.tr.length > 9) p.tr.pop();
        p.tr.forEach(([tx, ty], i) => { if (!i) return; const k = 1 - i / 10; x.globalAlpha = .18 * k; const s2 = size * (.4 + .5 * k); x.drawImage(sprites[p.s.cls], tx - s2, ty - s2, s2 * 2, s2 * 2); });
        x.globalAlpha = clamp(.55 + .35 * p.z + (ag > .5 ? (Math.random() - .5) * .4 : 0), 0, 1); x.drawImage(sprites[p.s.cls], px - size, py - size, size * 2, size * 2);
        p.px = px; p.py = py; p.size = size;
      });
      x.globalAlpha = 1; x.globalCompositeOperation = 'source-over';
      const sw = sel && W.find(p => p.s.id === sel);
      if (sw) { x.strokeStyle = CLS_C[sw.s.cls]; x.lineWidth = 1.5 * dpr; x.setLineDash([4 * dpr, 4 * dpr]); x.beginPath(); x.arc(sw.px, sw.py, sw.size * 1.15 + 6 * dpr, 0, 7); x.stroke(); x.setLineDash([]); }
      if (st.field < 90 || st.insp) { x.fillStyle = `rgba(255,30,10,${.07 + .07 * Math.sin(t * 8)})`; x.fillRect(0, 0, w, h); }
      for (let yy = 0; yy < h; yy += 3 * dpr) { x.fillStyle = '#0000002a'; x.fillRect(0, yy, w, dpr); }
      g = x.createRadialGradient(cx, cy, U * .8, cx, cy, Math.max(w, h) * .75); g.addColorStop(0, '#0000'); g.addColorStop(1, '#0009'); x.fillStyle = g; x.fillRect(0, 0, w, h);
      x.fillStyle = '#ffcf8aaa'; x.font = `${Math.round(U * .065)}px "Share Tech Mono",monospace`; x.textAlign = 'left'; x.fillText(`CHAMBER FEED // ${spirits.length} ENTITIES`, 8 * dpr, 16 * dpr);
      if (shown.length < spirits.length) { x.textAlign = 'right'; x.fillText(`+${spirits.length - shown.length} IN DEEP STORAGE`, w - 8 * dpr, h - 8 * dpr); }
      raf = requestAnimationFrame(draw);
    }

    function pick(id) {
      sel = id; const s = spirits.find(z => z.id === id), c = $('#ecard'); if (!s || !c) return;
      c.style.setProperty('--c', CLS_C[s.cls]); c.classList.add('on');
      c.innerHTML = `<span class="x">&#10005;</span><b>CLASS ${CLS[s.cls]} // ${esc(s.kind)}</b><br>${esc(s.code)} &nbsp; ${fmt(s.mj, 1)} MJ<br>CAPTURED ${day(s.date)}<br>BY ${esc(upName(s.by))}<br><span style="opacity:.7">${esc(s.event)}</span>${W.some(p => p.s.id === id) ? '' : '<br><span style="opacity:.7">IN DEEP STORAGE</span>'}`;
      c.onclick = () => { c.classList.remove('on'); sel = null; };
      buzz(8);
    }
    // tap an entity for its record, hold the glass to calm them
    let downAt = 0, holdT = null, moved = 0, sx = 0, sy = 0;
    cv.onpointerdown = e => { e.preventDefault(); downAt = performance.now(); moved = 0; sx = e.clientX; sy = e.clientY;
      holdT = setTimeout(() => { st.calming = true; log('CALMING PULSE // ENTITIES SETTLING'); buzz(12); }, 320); };
    cv.onpointermove = e => { moved = Math.max(moved, Math.hypot(e.clientX - sx, e.clientY - sy)); };
    const up = e => { clearTimeout(holdT);
      if (st.calming) { st.calming = false; if (st.agit < .2) log('OK: ENTITIES SETTLED'); return; }
      if (e.type !== 'pointerup' || performance.now() - downAt > 320 || moved > 12) return;
      const r = cv.getBoundingClientRect(), px = (e.clientX - r.left) * geo.dpr, py = (e.clientY - r.top) * geo.dpr;
      let best = null, bd = 1e9; W.forEach(p => { const d = Math.hypot(p.px - px, p.py - py); if (d < p.size * 1.1 + 14 * geo.dpr && d < bd) { bd = d; best = p; } });
      if (best) pick(best.s.id); else { const c = $('#ecard'); if (c) c.classList.remove('on'); sel = null; } };
    cv.onpointerup = cv.onpointercancel = cv.onpointerleave = up; cv.oncontextmenu = e => e.preventDefault();

    // live values
    let lastTick = performance.now(), lastRoutine = 0;
    function tick() {
      const nowT = performance.now(), dt = (nowT - lastTick) / 1000, t = secs(); lastTick = nowT;
      // brownouts: the grid drops out now and then, backup cells carry the unit
      if (st.grid && t > st.nextBrown) { st.grid = false; st.brownEnd = t + rnd(10, 16); log('GRID: VOLTAGE DROP DETECTED'); log('BACKUP: CELLS ENGAGED'); buzz([60, 40, 60]); }
      if (!st.grid && t > st.brownEnd) { st.grid = true; st.nextBrown = t + rnd(180, 360); log('OK: GRID RESTORED'); log('BACKUP: CELLS RECHARGING'); buzz(20); }
      st.batt = clamp(st.batt + (st.grid ? .25 : -1.8) * dt, 0, 100);
      // the inspector shows up once
      if (!st.inspDone && !st.insp && t > st.nextInsp) { st.insp = { until: t + 20 }; st.inspDone = true; log('INSPECTOR: SHUTDOWN ORDER RECEIVED'); buzz([120, 60, 120, 60, 120]); }
      if (st.insp && t > st.insp.until) { st.insp = null; log('OK: ORDER EXPIRED // INSPECTOR LEFT THE PREMISES'); }
      const ip = $('#einsp'); if (ip) { ip.classList.toggle('on', !!st.insp); const c = $('#einc'); if (c && st.insp) c.textContent = 'ORDER EXPIRES IN ' + Math.ceil(st.insp.until - t) + 's'; }
      // random faults
      Object.keys(st.faults).forEach(k => { if (t > st.faults[k]) { delete st.faults[k]; log('OK: ' + k + ' CLEARED'); } });
      if (Math.random() < .0055 && Object.keys(st.faults).length < 2 && !st.insp) { const free = FAULTS.filter(f => !st.faults[f[0]]), f = free[Math.floor(Math.random() * free.length)];
        if (f) { st.faults[f[0]] = t + rnd(4, 9); log((f[1] === 'fail' ? 'FAULT: ' : 'WARN: ') + f[0]); buzz(15); } }
      // field
      const nf = Object.keys(st.faults).length, brown = st.grid ? 0 : clamp((st.brownEnd - t) < 3 ? 2 : 6, 0, 6);
      const target = 99.3 + .25 * Math.sin(t / 7) + .15 * Math.sin(t * 1.7) - nf * .9 - brown - (st.insp ? 13 : 0) + (st.calming ? .8 : 0);
      st.field += (clamp(target, 70, 99.9) - st.field) * (st.insp ? .02 : .05);
      st.agit = clamp((99 - st.field) / 10, 0, 1);
      const lvl = st.field < 90 ? 2 : st.field < 95 ? 1 : 0;
      if (lvl > st.lvl) { st.lvl = lvl; if (lvl === 2) { log('CRITICAL: FIELD BELOW 90% // HOLD FEED TO CALM'); buzz([200, 80, 200]); } else { log('WARN: CONTAINMENT FIELD ' + fmt(st.field, 1) + '%'); buzz(40); } }
      else if (lvl < st.lvl && (lvl > 0 || st.field > 96)) { st.lvl = lvl; if (!lvl) log('OK: CONTAINMENT FIELD STABLE'); } // calls it stable once back above 96
      const ag = st.agit * (st.calming ? .3 : 1);
      st.temp += ((31 + 22 * ag + .8 * Math.sin(t / 5)) - st.temp) * .08;
      st.kpa += ((410 + 260 * ag + 6 * Math.sin(t / 3)) - st.kpa) * .08;
      st.kw = baseKW + 1.3 * Math.sin(t / 9) + 5 * ag + (st.insp ? 3 : 0) + Math.random() * .25;
      hist[hist.length - 1] = st.kw;
      needle(el, 'fld', st.field, 1); needle(el, 'tmp', st.temp, 0); needle(el, 'prs', st.kpa, 0);
      const set = (id, txt, cls) => { const b = $('#' + id); if (b) { if (txt != null) b.innerHTML = txt; if (cls) b.className = cls; } };
      set('ekw', fmt(st.grid ? st.kw : 0, 1) + '<small>kW</small>');
      set('egs', st.grid ? 'ONLINE' : 'BROWNOUT', st.grid ? 'ok' : 'bd');
      const todayKWh = hist.slice(-Math.max(1, Math.floor(mins / 15))).reduce((a, v) => a + v * .25, 0), monthKWh = (dom - 1) * avgDaily + todayKWh;
      set('etd', fmt(todayKWh, 0) + ' kWh'); set('emo', fmt(monthKWh, 0) + ' kWh'); set('ebl', '$' + fmt(monthKWh * RATE, 2));
      set('ebs', st.grid ? (st.batt < 99.5 ? 'RECHARGING ' + fmt(st.batt, 0) + '%' : 'STANDBY 100%') : 'ON BACKUP ' + fmt(st.batt, 0) + '% // ' + fmt(st.kw, 1) + ' kW', st.grid ? 'ok' : 'wn');
      const bu = $('#ebu'); if (bu) bu.style.width = st.batt.toFixed(1) + '%'; const bb = $('#ebb'); if (bb) bb.classList.toggle('lo', !st.grid || st.batt < 60);
      set('eilk', '<i class="dot"></i>' + (st.insp ? 'PANEL OPEN' : 'ENGAGED'), st.insp ? 'wn' : 'ok');
      set('esub', `ECU REMOTE LINK // ${spirits.length} ENTITIES // ${clock()}`);
      const L1 = $('#eL1'), L2 = $('#eL2');
      if (L1) L1.className = 'lamp ' + (lvl === 2 || st.insp ? 'rd bl' : lvl === 1 ? '' : 'gr');
      if (L2) L2.className = 'lamp ' + (!st.grid ? 'bl' : nf ? '' : 'dim');
      // routine lines and the occasional sign on the wall
      if (t - lastRoutine > 4 && t > 2.5 && !st.insp) { lastRoutine = t; let line;
        if (Math.random() < 1 / 12 && t - lastEgg > 120) { line = LORE[Math.floor(Math.random() * LORE.length)]; lastEgg = t; }
        else { do { line = TECH[Math.floor(Math.random() * TECH.length)]; } while (line === lastLine); }
        lastLine = line; log(line); }
      if (ownAudio) tone(ownAudio);
    }

    // the unit's own hum: lower than the pack, wobbling when the entities are restless
    function tone(a) {
      if (!a) return; const now = a.ac.currentTime, ag = st.agit, base = st.grid ? 46 : 39;
      a.o1.frequency.setTargetAtTime(base + ag * 5 * Math.sin(now * 7), now, .3); a.o2.frequency.setTargetAtTime(base * 1.5 + (st.insp ? 30 * Math.sin(now * 5) : 0), now, .3);
      a.f.frequency.setTargetAtTime(300 + ag * 600 + (st.insp ? 500 : 0), now, .25); a.g.gain.setTargetAtTime(.05 + ag * .03, now, .3);
    }
    function startOwn() {
      try { const ac = api.audioCtx && api.audioCtx.state !== 'closed' ? api.audioCtx : new (window.AudioContext || window.webkitAudioContext)(); api.audioCtx = null; if (ac.state === 'suspended') ac.resume().catch(() => {});
        const g = ac.createGain(), f = ac.createBiquadFilter(), o1 = ac.createOscillator(), o2 = ac.createOscillator();
        o1.type = 'sawtooth'; o2.type = 'sine'; f.type = 'lowpass'; g.gain.value = 0; o1.connect(f); o2.connect(f); f.connect(g); g.connect(ac.destination); o1.start(); o2.start();
        ownAudio = { ac, g, f, o1, o2 }; } catch (e) { /* no sound */ }
    }
    function stopOwn() { if (!ownAudio) return; try { ownAudio.o1.stop(); ownAudio.o2.stop(); ownAudio.ac.close(); } catch (e) { /* ignore */ } ownAudio = null; }
    const soundOn = () => api.sound ? api.sound() : !!ownAudio;
    const paintSnd = () => { const b = $('#esnd'); if (b) { b.classList.toggle('on', soundOn()); b.title = soundOn() ? 'Sound on' : 'Sound off'; } };

    $('#ex').onclick = () => api.exit();
    if (api.back) $('#ebk').onclick = () => api.back();
    $('#esnd').onclick = () => { const on = !soundOn(); if (api.setSound) api.setSound(on); else if (on) startOwn(); else stopOwn(); try { on ? localStorage.removeItem('pk-sound') : localStorage.setItem('pk-sound', 'off'); } catch (e) { /* ignore */ } paintSnd(); };
    $('#edeny').onclick = () => { if (!st.insp) return; st.insp = null; log('OK: SHUTDOWN ORDER DENIED BY ' + (S.me ? upName(S.me) : 'OPERATOR')); buzz([30, 30, 30]); };
    el.querySelectorAll('#eseg button').forEach(b => b.onclick = () => { list = b.dataset.l; renderList(); });
    if (!api.sound) { let off = false; try { off = localStorage.getItem('pk-sound') === 'off'; } catch (e) { /* ignore */ } if (!off) startOwn();
      const wake = () => { if (ownAudio && ownAudio.ac.state === 'suspended') ownAudio.ac.resume().catch(() => {}); }; ['pointerdown', 'click', 'keydown'].forEach(t => el.addEventListener(t, wake, { capture: true })); }
    let lock = null; if (!api.back && navigator.wakeLock) navigator.wakeLock.request('screen').then(l => { lock = l; }).catch(() => {});

    const BOOT = ['LINK: ' + short + ' CONTAINMENT UNIT', 'BOOT: REMOTE LINK AUTHENTICATED', 'BOOT: GRID FEED ONLINE', 'BOOT: FIELD GENERATORS ONLINE', 'BOOT: COOLANT LOOP PRIMED',
      'BOOT: TRAP PORT SEALED // INTERLOCK ENGAGED', 'BOOT: BACKUP CELLS ON STANDBY', 'BOOT: ' + spirits.length + ' ENTITIES ACCOUNTED FOR', 'BOOT: UNIT READY'];
    let bi = 0; const boot = setInterval(() => { if (bi < BOOT.length) log(BOOT[bi++]); else clearInterval(boot); }, 220); timers.push(boot);
    spark(); renderList(); paintSnd(); draw();
    timers.push(setInterval(tick, 150), setInterval(spark, 5000));
    tick();
    const ecu = {
      tone,
      test: { brownout: () => { st.nextBrown = 0; }, inspector: () => { st.inspDone = false; st.nextInsp = 0; }, state: st },
      destroy() { timers.forEach(clearInterval); cancelAnimationFrame(raf); clearTimeout(holdT); stopOwn(); if (lock) lock.release().catch(() => {}); el.remove(); }
    };
    window.__ecu = ecu;
    return ecu;
  } };
})();

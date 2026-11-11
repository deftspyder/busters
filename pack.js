/* Busters: proton pack monitor (Los Angeles Ghostbusters).
   An in-world diagnostics screen built for phones first: the crew's own pack photo traced into
   glowing line art, live readings in four instrument panels, modes (off, idle, stream, overload,
   fire), a boot log, an oscilloscope, an 8-bit LAGB emblem, and the Buster the pack is assigned to.
   Loaded on demand from index.html, which passes in what it needs: S, $, esc, toast, rpc, can,
   nameOf, upcoming, todayISO. */
(function () {
  // Systems that can be marked on the pack photo (keys match saved markers).
  const DIAG = { cyclotron: 'CYCLOTRON', power_cell: 'POWER CELL', sync_gen: 'SYNC GEN', booster: 'BOOSTER', ion_arm: 'ION ARM', ppd: 'PPD',
    injectors: 'INJECTORS', hga: 'HGA', crank: 'CRANK GEN', n_filter: 'N-FILTER', heatsink: 'GUNBOX', ribbon: 'RIBBON' };
  const LEFT = { ion_arm: 1, power_cell: 1, injectors: 1, ribbon: 1, hga: 1, heatsink: 1, sync_gen: 1, crank: 1, cyclotron: 1 };
  const MARKS = [
    ['cyclotron', 'Cyclotron', 'CYC'], ['power_cell', 'Power Cell', 'PWR'], ['sync_gen', 'Synchronous Generator', 'SYN'],
    ['booster', 'Booster', 'BST'], ['ion_arm', 'Ion Arm', 'ION'], ['ppd', 'Primary Power Distributor', 'PPD'],
    ['injectors', 'Injectors', 'INJ'], ['hga', 'Hydrogen Gas Actuator', 'HGA'], ['crank', 'Crank Generator', 'CRK'],
    ['n_filter', 'N-Filter', 'N-F'], ['heatsink', 'Heat Sink', 'HS'], ['ribbon', 'Ribbon Cable', 'RIB']
  ];
  // Readings: idle value i, per-mode multipliers [off, idle, stream, overload], wobble w, decimals d.
  const R = {
    cell: { i: 92, m: [0, 1, .93, .81], w: 1.2, d: 0 },
    boost: { i: 48.5, m: [0, 1, 1.35, 1.9], w: 1.6, d: 1 },
    ion: { i: 712, m: [0, 1, 1.5, 2.3], w: 22, d: 0 },
    inj: { i: 64, m: [0, 1, 1.45, 2.1], w: 3, d: 0 },
    flow: { i: .04, m: [0, 1, 2.5, 5], w: .01, d: 2 },
    crank: { i: 60, m: [0, 1, 1, 1.02], w: .4, d: 1 },
    rpm: { i: 3230, m: [0, 1, 1.36, 2.3], w: 60, d: 0 },
    field: { i: 3.9, m: [0, 1, 1.46, 2.75], w: .15, d: 1 },
    stab: { i: 98.4, m: [0, 1, .99, .67], w: .5, d: 1 },
    heat: { i: 41, m: [0, 1, 1.6, 2.2], w: 1.5, d: 0 },
    syn: { i: 3.62, m: [0, 1, 1.3, 1.85], w: .06, d: 2 },
    rib: { i: 9.8, m: [0, 1, 1.05, .8], w: .25, d: 1 }
  };
  // Systems that can drift out of spec: reading key, diagram marker, map node, name, which way it drifts.
  const EX = [['cell', 'power_cell', 'PWR', 'POWER CELL', -1], ['boost', 'booster', 'BST', 'BOOSTER', 1], ['ion', 'ion_arm', 'ION', 'ION ARM', 1],
    ['inj', 'injectors', 'INJ', 'INJECTORS', 1], ['flow', 'hga', 'HGA', 'HGA FLOW', 1], ['crank', 'crank', 'CRK', 'CRANK GEN', -1],
    ['rpm', 'cyclotron', '', 'CYCLOTRON', 1], ['stab', 'cyclotron', '', 'FIELD STABILITY', -1], ['heat', 'heatsink', 'HS', 'HEAT SINK', 1],
    ['syn', 'sync_gen', 'SYN', 'SYNC GEN', 1], ['rib', 'ribbon', 'RIB', 'RIBBON CABLE', -1], ['ppd', 'ppd', 'PPD', 'POWER DISTRIBUTOR', 0], ['nf', 'n_filter', 'NF', 'N-FILTER', 0]];
  const MODES = ['OFF', 'IDLE', 'STREAM ACTIVE', 'TOTAL FAILURE'];
  // Order systems fail in once the stream has been held past 8 seconds (cyclotron last, at 18 seconds).
  const FAIL_ORDER = ['heat', 'rib', 'nf', 'inj', 'flow', 'boost', 'ion', 'syn', 'ppd', 'crank', 'cell', 'stab', 'rpm'];
  const PH = ['#2f7d58', '#4dff9a', '#5fe3ff', '#ff5a3c']; // phosphor colour per mode
  const BOOT = ['KERNEL LINK ESTABLISHED', 'LOS ANGELES DIVISION AUTHENTICATED', 'CARBON CELL ONLINE', 'CYCLOTRON ROTATION NOMINAL',
    'N-FILTER PURGE COMPLETE', 'SYNCHRONOUS GENERATOR IN PHASE', 'ION ARM ALIGNMENT VERIFIED', 'PARTICLE THROWER SAFETY: ON', 'PACK READY'];

  const CSS = `
.pk{--ph:#4dff9a;--md:#4dff9a;position:fixed;inset:0;z-index:100;background:#010806;color:var(--ph);font-family:"Share Tech Mono",ui-monospace,Menlo,monospace;
  display:grid;grid-template-rows:auto minmax(0,1fr) auto;overflow:hidden;transition:color .4s;-webkit-user-select:none;user-select:none;
  font-size:clamp(11px,1.55vh,16px);padding:env(safe-area-inset-top) env(safe-area-inset-right) 0 env(safe-area-inset-left)}
.pk *{box-sizing:border-box}
.pk::before{content:"";position:absolute;inset:0;pointer-events:none;z-index:5;background:repeating-linear-gradient(0deg,#0000 0 2px,#0006 2px 3px),radial-gradient(ellipse at center,#0000 70%,#0005)}
.pk.fire::after{content:"";position:absolute;inset:0;pointer-events:none;z-index:4;background:var(--md);opacity:.07;animation:pkfl .09s steps(2) infinite}
@keyframes pkfl{50%{opacity:.16}}
.pk .gl{text-shadow:0 0 6px var(--ph)}
.pk .box{border:1px solid color-mix(in srgb,var(--ph) 55%,transparent);border-radius:6px;background:color-mix(in srgb,var(--ph) 5%,#010806);box-shadow:inset 0 0 18px color-mix(in srgb,var(--ph) 12%,transparent)}
/* header */
.pk .hd{display:grid;grid-template-columns:auto 1fr auto;gap:10px;align-items:center;padding:8px 10px;margin:6px 6px 0}
.pk .emb{width:clamp(34px,6vh,64px);aspect-ratio:1;image-rendering:pixelated;filter:drop-shadow(0 0 4px var(--ph))}
.pk .ttl{font-size:1.25em;letter-spacing:.12em;line-height:1.15;color:#eafff4}
.pk .sub{opacity:.7;font-size:.8em;letter-spacing:.1em}
.pk .md{display:flex;align-items:center;gap:6px;justify-content:flex-end;font-size:.85em;letter-spacing:.08em;text-align:right}
.pk .md i{width:8px;height:8px;border-radius:50%;background:var(--ph);box-shadow:0 0 8px var(--ph);animation:pkb 1.4s infinite;flex:0 0 auto}
@keyframes pkb{50%{opacity:.2}}
.pk .who{grid-column:1/-1;display:flex;align-items:baseline;gap:10px;border-top:1px dashed color-mix(in srgb,var(--ph) 35%,transparent);padding-top:6px;min-width:0;justify-content:flex-end;text-align:right}
.pk .who .l{font-size:.75em;letter-spacing:.2em;opacity:.75;white-space:nowrap}
.pk .who .nm{font-size:1.6em;letter-spacing:.08em;font-weight:700;text-transform:uppercase;color:#fff;text-shadow:0 0 8px var(--ph),0 0 18px var(--ph);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.pk .x{position:absolute;top:calc(8px + env(safe-area-inset-top));right:calc(8px + env(safe-area-inset-right));z-index:6;background:#000a;border:1px solid var(--ph);color:var(--ph);border-radius:50%;width:30px;height:30px;font:inherit;cursor:pointer;display:none}
/* body: phone first */
.pk .bd{display:grid;grid-template-columns:1fr 1fr;grid-template-rows:minmax(0,1fr) auto auto auto;grid-template-areas:"sc sc" "os os" "p1 p2" "p3 p4";gap:6px;padding:6px;min-height:0;overflow:hidden}
.pk .sc{grid-area:sc;position:relative;min-height:0;overflow:hidden;display:grid;place-items:center}
.pk .sc .grid{position:absolute;inset:0;background-image:linear-gradient(color-mix(in srgb,var(--ph) 10%,transparent) 1px,transparent 1px),linear-gradient(90deg,color-mix(in srgb,var(--ph) 10%,transparent) 1px,transparent 1px);background-size:18px 18px}
.pk .os .warn{position:absolute;bottom:4px;left:50%;transform:translateX(-50%);white-space:nowrap;font-size:.85em;letter-spacing:.12em;padding:2px 8px;border:1px solid var(--ph);background:#000c;display:none;animation:pkb .6s infinite;z-index:2}
.pk.m3 .os .warn{display:block;color:#ff6a50;border-color:#ff5a3c;text-shadow:0 0 6px #ff3b2f}
.pk.m3 .md{color:#ff6a50;text-shadow:0 0 6px #ff3b2f}.pk.m3 .md i{background:#ff3b2f;box-shadow:0 0 10px #ff3b2f;animation-duration:.5s}
.pk.m3 .mk:not(.oos) b{border-color:#ff5a3c;box-shadow:0 0 8px #ff3b2f;animation:pkb .7s infinite}
.pk.m3 .map .lt.hot{fill:#ff3b2f;filter:drop-shadow(0 0 6px #ff3b2f)}.pk.m3 .map .core{fill:#ff3b2f}
.pk.m3 .cb .fire{color:#fff;border-color:#ff5a3c;background:#3a0d06;box-shadow:0 0 10px #ff3b2f88}
.pk .art{position:relative}
.pk .art .tr{position:absolute;inset:0;background:var(--md);-webkit-mask-size:100% 100%;mask-size:100% 100%;filter:drop-shadow(0 0 3px var(--md));transition:opacity .5s}
.pk.m0 .art .tr{opacity:.55}
.pk .mk{position:absolute;transform:translate(-50%,-50%);font-size:.7em;letter-spacing:.05em;color:#fff;display:flex;align-items:center;gap:3px;pointer-events:none;text-shadow:0 0 4px #000,0 0 4px #000}
.pk .mk b{width:8px;height:8px;border:1px solid var(--md);border-radius:50%;box-shadow:0 0 6px var(--md);flex:0 0 auto}
.pk .cl{position:absolute;width:7.5%;aspect-ratio:1;border-radius:50%;transform:translate(-50%,-50%);background:radial-gradient(#fff 0,#ff6a50 35%,#ff2a1a 60%,transparent 72%);box-shadow:0 0 12px #ff3b2f,0 0 26px #ff3b2f88;display:none}
.pk.on .cl{display:block}
.pk .nopk{position:relative;text-align:center;padding:12px;line-height:1.6}
.pk .sc .map{position:absolute;inset:0;padding:8px 6px 6px}
.pk .map svg{width:100%;height:100%;display:block;overflow:visible}
.pk .map .ed{fill:none;stroke:var(--md);stroke-width:1.4;opacity:.55;stroke-dasharray:4 5}
.pk.on .map .ed{animation:pkflow var(--fs,1.6s) linear infinite;opacity:.9}
@keyframes pkflow{to{stroke-dashoffset:-18}}
.pk .map .nd rect{fill:#010806;stroke:var(--md);stroke-width:1.2;filter:drop-shadow(0 0 3px var(--md))}
.pk .map .nd text{fill:#fff;font:9px "Share Tech Mono",monospace;letter-spacing:.06em;text-anchor:middle}
.pk .map .nd text.s{fill:var(--md);font-size:6px;opacity:.85}
.pk .map .ring{fill:none;stroke:var(--md);filter:drop-shadow(0 0 4px var(--md))}
.pk .map .lt{fill:#0b1a14;stroke:var(--md);stroke-width:1}
.pk .map .lt.hot{fill:var(--md);filter:drop-shadow(0 0 6px var(--md)) drop-shadow(0 0 12px var(--md))}
.pk .map .core{fill:var(--md);opacity:.25}.pk.on .map .core{opacity:.8;filter:drop-shadow(0 0 8px var(--md))}
.pk .map .cap{fill:var(--md);font:7px "Share Tech Mono",monospace;letter-spacing:.2em;text-anchor:middle;opacity:.8}
.pk .nopk img{width:min(40vw,22vh);image-rendering:pixelated;filter:drop-shadow(0 0 8px var(--ph));display:block;margin:0 auto 10px}
.pk .os{grid-area:os;height:clamp(38px,7vh,90px);position:relative;overflow:hidden}
.pk .os canvas{position:absolute;inset:0;width:100%;height:100%}
.pk .os .t{position:absolute;left:6px;top:3px;font-size:.7em;opacity:.8;letter-spacing:.1em;z-index:1}
.pk .pn{padding:6px 8px;min-width:0}
.pk .pn h4{margin:0 0 3px;font-weight:400;font-size:.95em;letter-spacing:.16em;border-bottom:1px solid color-mix(in srgb,var(--ph) 30%,transparent);padding-bottom:2px;white-space:nowrap;overflow:hidden}
.pk .rw{display:flex;justify-content:space-between;gap:6px;line-height:1.5;white-space:nowrap}
.pk .rw span{opacity:.75;overflow:hidden;text-overflow:ellipsis}
.pk .rw b{font-weight:400;color:color-mix(in srgb,var(--md) 55%,#fff);text-shadow:0 0 6px var(--md)}
.pk .rw b.bad{color:#ffb199;text-shadow:0 0 6px #ff5a3c;animation:pkb .7s infinite}
.pk .rw.fail span,.pk .rw.fail b{color:#ff4d3a!important;text-shadow:0 0 8px #ff2a1a!important;opacity:1;animation:pkb .35s infinite}
.pk .mk.fail b{border-color:#ff3b2f;background:#ff3b2f;box-shadow:0 0 10px #ff3b2f,0 0 20px #ff2a1a;animation:pkb .35s infinite}
.pk .art.dg .mk.fail span{border-color:#ff3b2f;color:#ff8a7a}
.pk .map .nd.fail rect{stroke:#ff3b2f;fill:#2a0603;filter:drop-shadow(0 0 6px #ff3b2f)}.pk .map .nd.fail text.s{fill:#ff8a7a}
.pk .boom{position:absolute;inset:0;z-index:9;display:none;place-items:center;background:radial-gradient(ellipse at center,#3a0000cc,#000c 75%);pointer-events:none}
.pk.crit .boom,.pk.vent .boom{display:grid}
.pk .boom .bx{border:3px solid #ff3b2f;border-radius:10px;background:#120000e6;padding:3vh 6vw;text-align:center;box-shadow:0 0 30px #ff2a1a,inset 0 0 30px #ff2a1a55;max-width:92vw}
.pk.crit .boom .bx{animation:pkb .5s infinite}
.pk .boom .b1{color:#ffb199;font-size:clamp(14px,2.4vh,26px);letter-spacing:.14em}
.pk .boom .b2{color:#fff;font-weight:700;font-size:clamp(34px,7vh,90px);line-height:1.05;letter-spacing:.06em;margin:1.2vh 0;text-shadow:0 0 12px #ff3b2f,0 0 30px #ff2a1a}
.pk .boom .b4{color:#fff;font-weight:700;font-size:clamp(16px,3vh,36px);letter-spacing:.12em;margin:-.4vh 0 1.4vh;text-shadow:0 0 10px #ff3b2f}
.pk .boom .b3{color:#ffcf66;font-size:clamp(12px,1.8vh,20px);letter-spacing:.16em}
.pk.vent .boom .b1{color:#ffcf66}.pk.vent .boom .bx{border-color:#ffb000;box-shadow:0 0 24px #ff9a00}
.pk.crit .cb,.pk.vent .cb{position:relative;z-index:10}
.pk .rw.oos span,.pk .rw.oos b{color:#ffc24a;text-shadow:0 0 6px #ff9a00;opacity:1}
.pk .rw.oos b{animation:pkb .8s infinite}
.pk .mk.oos{color:#ffd27a}.pk .mk.oos b{border-color:#ffb000;background:#ffb000;box-shadow:0 0 10px #ffb000,0 0 18px #ff9a00;animation:pkb .6s infinite}
.pk .map .nd.oos rect{stroke:#ffb000;fill:#241600;filter:drop-shadow(0 0 6px #ffb000)}.pk .map .nd.oos text.s{fill:#ffc24a}
.pk .vt{position:absolute;right:6px;top:6px;z-index:3;display:flex;border:1px solid color-mix(in srgb,var(--ph) 55%,transparent);border-radius:6px;overflow:hidden}
.pk .vt button{font:inherit;font-size:.66em;letter-spacing:.1em;padding:4px 8px;min-height:26px;background:#000c;color:var(--ph);border:0;cursor:pointer}
.pk .vt button.on{background:color-mix(in srgb,var(--ph) 25%,#000);color:#fff}
.pk .art.dg .mk{transform:translate(-5px,-50%);font-size:clamp(10px,1.45vh,15px);letter-spacing:.04em}
.pk .art.dg .mk.l{flex-direction:row-reverse;transform:translate(calc(-100% + 5px),-50%)}
.pk .art.dg .mk b{width:10px;height:10px;background:#010806}
.pk .art.dg .mk span{background:#000d;border:1px solid color-mix(in srgb,var(--ph) 45%,transparent);padding:1px 4px;border-radius:3px;color:#fff;white-space:nowrap}
.pk .art.dg .mk.oos span{border-color:#ffb000;color:#ffd27a}
.pk #pk1{grid-area:p1}.pk #pk2{grid-area:p2}.pk #pk3{grid-area:p3}.pk #pk4{grid-area:p4}
.pk .lg{display:none;grid-area:lg;padding:6px 8px;overflow:hidden;font-size:.8em;line-height:1.45}
.pk .tick{grid-column:1/-1;padding:3px 10px;font-size:.78em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;opacity:.85}
/* controls */
.pk .cb{display:grid;grid-template-columns:repeat(6,1fr);gap:5px;padding:6px 6px calc(6px + env(safe-area-inset-bottom));background:#010806;position:relative;z-index:6}
.pk .cb button{font:inherit;font-size:.78em;letter-spacing:.06em;color:var(--ph);background:#000;border:1px solid color-mix(in srgb,var(--ph) 50%,transparent);border-radius:8px;min-height:44px;padding:2px;cursor:pointer;touch-action:manipulation}
.pk .cb button.on{background:color-mix(in srgb,var(--ph) 22%,#000);color:#fff;border-color:var(--ph);box-shadow:0 0 10px color-mix(in srgb,var(--ph) 45%,transparent)}
.pk .cb .fire{color:#ffb199;border-color:#ff5a3c99}
.pk .more{position:absolute;right:6px;bottom:calc(60px + env(safe-area-inset-bottom));z-index:7;padding:8px;display:none;flex-direction:column;gap:6px;min-width:min(86vw,320px);background:#010806}
.pk .more.open{display:flex}
.pk .more select,.pk .more button{font:inherit;color:var(--ph);background:#000;border:1px solid color-mix(in srgb,var(--ph) 50%,transparent);border-radius:8px;min-height:42px;padding:6px 10px;text-align:left;cursor:pointer}
.pk .tip{position:absolute;left:50%;top:8px;transform:translateX(-50%);background:#ff9a3c;color:#000;border-radius:8px;padding:6px 10px;font:600 13px system-ui,sans-serif;z-index:8;max-width:92%;text-align:center}
.pk.edit .art{cursor:crosshair}
/* wide screens: three columns */
@media (min-aspect-ratio:1/1) and (min-width:700px){
  .pk{font-size:clamp(11px,1.7vh,20px)}
  .pk .hd{grid-template-columns:auto 1fr auto auto;padding-right:46px}
  .pk .who{grid-column:auto;border-top:0;padding-top:0;flex-direction:column;align-items:flex-end;gap:0;text-align:right}
  .pk .bd{grid-template-columns:minmax(0,1fr) minmax(0,1.5fr) minmax(0,1fr);grid-template-rows:auto auto minmax(0,1fr) auto;grid-template-areas:"p1 sc p3" "p2 sc p4" "lg sc lg2" "lg os lg2"}
  .pk .lg{display:block}.pk .lg2{grid-area:lg2;display:grid;place-items:center}
  .pk .tick{display:none}
  .pk .cb{grid-template-columns:repeat(6,minmax(0,140px));justify-content:center}
  .pk .x{display:block}
}
@media not ((min-aspect-ratio:1/1) and (min-width:700px)){.pk .lg2{display:none}}`;

  const hash = s => { let h = 7; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
  const fmt = (v, d) => v.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });
  const clock = () => new Date().toLocaleTimeString('en-US', { hour12: false });

  // 8-bit version of the LAGB emblem: shrink, posterize, scale up with hard pixels.
  let emblem8 = null;
  function makeEmblem(cb) {
    if (emblem8) return cb(emblem8);
    const im = new Image();
    im.onload = () => {
      const n = 40, c = document.createElement('canvas'); c.width = c.height = n;
      const x = c.getContext('2d'); x.imageSmoothingEnabled = true; x.drawImage(im, 0, 0, n, n);
      const d = x.getImageData(0, 0, n, n), p = d.data;
      for (let i = 0; i < p.length; i += 4) { for (let k = 0; k < 3; k++) p[i + k] = Math.round(p[i + k] / 64) * 64 - (p[i + k] > 224 ? 1 : 0); p[i + 3] = p[i + 3] > 110 ? 255 : 0; }
      x.putImageData(d, 0, 0); emblem8 = c.toDataURL(); cb(emblem8);
    };
    im.onerror = () => cb('');
    im.src = 'img/emblem.png';
  }

  // Trace a pack photo into line art (edge detection), cached per photo.
  const traceCache = {};
  function trace(src, cb) {
    if (traceCache[src]) return cb(traceCache[src]);
    const im = new Image();
    im.onload = () => {
      const k = Math.min(1, 720 / Math.max(im.width, im.height)), w = Math.round(im.width * k), h = Math.round(im.height * k);
      const c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d'); x.drawImage(im, 0, 0, w, h);
      const src2 = x.getImageData(0, 0, w, h).data, g = new Float32Array(w * h);
      for (let i = 0; i < w * h; i++) g[i] = .3 * src2[i * 4] + .59 * src2[i * 4 + 1] + .11 * src2[i * 4 + 2];
      const mag = new Float32Array(w * h); let sum = 0;
      for (let y = 1; y < h - 1; y++) for (let xx = 1; xx < w - 1; xx++) {
        const i = y * w + xx;
        const gx = -g[i - w - 1] - 2 * g[i - 1] - g[i + w - 1] + g[i - w + 1] + 2 * g[i + 1] + g[i + w + 1];
        const gy = -g[i - w - 1] - 2 * g[i - w] - g[i - w + 1] + g[i + w - 1] + 2 * g[i + w] + g[i + w + 1];
        mag[i] = Math.hypot(gx, gy); sum += mag[i];
      }
      const th = Math.max(40, 2.4 * sum / (w * h)), out = x.createImageData(w, h);
      for (let i = 0; i < w * h; i++) { const a = Math.min(255, Math.max(0, (mag[i] - th) * 3)); out.data[i * 4] = out.data[i * 4 + 1] = out.data[i * 4 + 2] = 255; out.data[i * 4 + 3] = a; }
      x.putImageData(out, 0, 0);
      traceCache[src] = { url: c.toDataURL(), w, h }; cb(traceCache[src]);
    };
    im.onerror = () => cb(null);
    im.src = src;
  }

  function lineArt(src, cb) {
    if (traceCache[src]) return cb(traceCache[src]);
    const im = new Image();
    im.onload = () => {
      const k = Math.min(1, 1000 / Math.max(im.width, im.height)), w = Math.round(im.width * k), h = Math.round(im.height * k);
      const c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, w, h); x.drawImage(im, 0, 0, w, h);
      const d = x.getImageData(0, 0, w, h), p = d.data;
      for (let i = 0; i < p.length; i += 4) { const l = .3 * p[i] + .59 * p[i + 1] + .11 * p[i + 2]; p[i] = p[i + 1] = p[i + 2] = 255; p[i + 3] = Math.max(0, Math.min(255, (255 - l) * 2.8 - 60)); }
      x.putImageData(d, 0, 0); traceCache[src] = { url: c.toDataURL(), w, h }; cb(traceCache[src]);
    };
    im.onerror = () => cb(null);
    im.src = src;
  }

  window.openPackMonitor = function (ctx) {
    const { S, $, esc, toast, rpc, can, nameOf, upcoming, todayISO } = ctx;
    if (!document.getElementById('pk-css')) { const st = document.createElement('style'); st.id = 'pk-css'; st.textContent = CSS; document.head.appendChild(st); }
    if (!document.getElementById('pk-font')) { const l = document.createElement('link'); l.id = 'pk-font'; l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap'; document.head.appendChild(l); }
    const pack = () => (S.settings && S.settings.pack_monitor) || {};
    const crew = S.people.filter(p => ['active', 'rookie'].includes(p.status));
    const todays = () => { const t = todayISO(); const e = upcoming().find(x => x.event_date <= t && (x.end_date || x.event_date) >= t && x.status === 'scheduled'); return e ? S.rsvps.filter(r => r.event_id === e.id && r.answer === 'going').map(r => r.person_id) : []; };
    let saved = null; try { saved = localStorage.getItem('pk-who'); } catch (e) { /* no storage */ }
    let who = saved && (saved === 'cycle' || crew.some(p => p.id === saved)) ? saved : (S.me ? S.me.id : (crew[0] || {}).id);
    let view = 'pack'; try { view = localStorage.getItem('pk-view') || 'pack'; } catch (e) { /* ignore */ }
    const oos = {};
    let cur = who, cycleIdx = -1, edit = null, timers = [], lock = null, mode = 0, firing = false, audio = null, logLines = [];
    const V = {}; Object.keys(R).forEach(k => { V[k] = 0; });

    const el = document.createElement('div'); el.className = 'pk m0'; document.body.appendChild(el);
    const person = () => crew.find(p => p.id === cur) || S.me || crew[0];
    // First initial and last name, like "B. Pernod".
    const shortName = p => { if (!p) return 'UNASSIGNED'; const w = String(p.full_name || '').trim().split(/\s+/); return w.length > 1 ? w[0][0].toUpperCase() + '. ' + w[w.length - 1] : (w[0] || 'UNASSIGNED'); };

    function frame() {
      const p = person();
      el.innerHTML = `<div class="hd box"><img class="emb" id="pkemb" alt="">
        <div style="min-width:0"><div class="ttl gl">LAGB // PROTON PACK</div><div class="sub">LOS ANGELES DIVISION</div></div>
        <div class="md gl"><i></i><div><div id="pkmode">${MODES[mode]}</div><div id="pkclk" style="opacity:.7">${clock()}</div></div></div>
        <div class="who"><span class="nm">${esc(shortName(p))}</span></div></div>
      <button class="x" id="pkx2" aria-label="Exit">&#10005;</button>
      <div class="bd">
        <div class="sc box" id="pksc"><div class="grid"></div><div class="vt" id="pkvt"></div><div id="pkart"></div></div>
        <div class="os box"><div class="warn">WARNING // CONTAINMENT FIELD UNSTABLE</div><div class="t" id="pkost">CYCL: STOP // FIELD: OFFLINE</div><canvas id="pkos"></canvas></div>
        <div class="pn box" id="pk1"><h4>POWER CORE</h4>${rw('Power Cell', 'cell', '%')}${rw('Booster', 'boost', 'kV')}${rw('Ion Arm', 'ion', '\u00b5A')}${rw('PPD', 'ppd')}</div>
        <div class="pn box" id="pk2"><h4>H\u2082 SYSTEM</h4>${rw('Injectors', 'inj', 'PSI')}${rw('Flow', 'flow', 'L/s')}${rw('HGA', 'hga')}${rw('Crank Gen', 'crank', 'Hz')}</div>
        <div class="pn box" id="pk3"><h4>CYCLOTRON</h4>${rw('Rotation', 'rpm', 'RPM')}${rw('Field', 'field', 'T')}${rw('Stability', 'stab', '%')}${rw('N-Filter', 'nf')}</div>
        <div class="pn box" id="pk4"><h4>THROWER</h4>${rw('Heat Sink', 'heat', '\u00b0C')}${rw('Sync Gen', 'syn', 'MeV')}${rw('Ribbon', 'rib', 'Gb/s')}${rw('Containment', 'cont')}</div>
        <div class="lg box" id="pklg"></div><div class="lg2 box" id="pklg2"></div>
      </div>
      <div class="tick" id="pktick"></div>
      <div class="boom"><div class="bx"><div class="b1">&#9888; IMMINENT PACK FAILURE &#9888;</div><div class="b2">STAND BACK<br>3 MILES</div><div class="b4">UPWIND FROM PACK</div><div class="b3" id="pkb3">RELEASE TRIGGER TO VENT</div></div></div>
      <div class="cb">
        <button id="b0">${mode ? 'PACK ON' : 'PACK OFF'}</button><button id="b1">IDLE</button><button id="b2">STREAM</button>
        <button id="bf" class="fire">FIRE</button><button id="ba">${audio ? 'SOUND ON' : 'SOUND'}</button><button id="bm">MORE</button></div>
      <div class="more box" id="pkmore"><select id="pkwho"><option value="cycle"${who === 'cycle' ? ' selected' : ''}>Cycle through today's Busters</option>${crew.map(c => `<option value="${c.id}"${who === c.id ? ' selected' : ''}>${esc(nameOf(c))}</option>`).join('')}</select>
        <button id="pkfs">Full screen</button>${can('crew_admin') ? '<button id="pkset">Set up pack photo</button>' : ''}<button id="pkx">Exit monitor</button></div>
      ${edit ? `<div class="tip">${edit.i < MARKS.length ? `Tap the ${MARKS[edit.i][1]} (${edit.i + 1} of ${MARKS.length}) &nbsp;<u id="pkskip">Skip</u>` : 'Saving...'}</div>` : ''}`;
      makeEmblem(u => { const e = $('#pkemb', el); if (e && u) e.src = u; const l2 = $('#pklg2', el); if (l2 && u) l2.innerHTML = `<div style="text-align:center"><img src="${u}" style="width:min(70%,18vh);image-rendering:pixelated;filter:drop-shadow(0 0 6px var(--ph))" alt=""><div class="sub" style="margin-top:6px">LOS ANGELES GHOSTBUSTERS</div></div>`; });
      drawArt(); paintButtons(); renderLog(); wire();
    }
    function systemsMap() {
      const N = { PWR: [55, 40, 'POWER CELL'], PPD: [150, 40, 'POWER DIST'], BST: [245, 40, 'BOOSTER'], ION: [55, 116, 'ION ARM'], INJ: [150, 116, 'INJECTORS'], HGA: [245, 116, 'H\u2082 ACTUATOR'],
        SYN: [40, 238, 'SYNC GEN'], NF: [260, 238, 'N-FILTER'], CRK: [55, 322, 'CRANK GEN'], HS: [150, 330, 'HEAT SINK'], RIB: [245, 322, 'RIBBON'] };
      const C = [150, 238], E = [['PWR', 'PPD'], ['PPD', 'BST'], ['ION', 'PWR'], ['PPD', 'INJ'], ['HGA', 'INJ'], ['BST', 'HGA'], ['ION', 'SYN'], ['CRK', 'SYN'], ['HS', 'RIB'], ['NF', 'RIB']];
      const line = (a, b) => `<path class="ed" d="M${a[0]} ${a[1]} L${b[0]} ${b[1]}"/>`;
      const toC = k => { const a = N[k]; return `<path class="ed" d="M${a[0]} ${a[1]} Q${(a[0] + C[0]) / 2} ${a[1] - 6} ${C[0]} ${C[1]}"/>`; };
      const lights = [[0, -40], [40, 0], [0, 40], [-40, 0]];
      return `<svg viewBox="0 6 300 368" preserveAspectRatio="xMidYMid meet" aria-label="Proton pack systems map">
        ${E.map(([a, b]) => line(N[a], N[b])).join('')}${['INJ', 'SYN', 'NF', 'HS'].map(toC).join('')}
        <circle class="ring" cx="${C[0]}" cy="${C[1]}" r="62" stroke-width="1.5"/><circle class="ring" cx="${C[0]}" cy="${C[1]}" r="54" stroke-width=".6" stroke-dasharray="2 4"/>
        ${lights.map(([dx, dy], i) => `<circle class="lt" id="pkL${i}" cx="${C[0] + dx}" cy="${C[1] + dy}" r="11"/>`).join('')}
        <circle class="core" cx="${C[0]}" cy="${C[1]}" r="14"/>
        <text class="cap" x="${C[0] + 74}" y="${C[1] - 58}">CYCLOTRON</text>
        ${Object.entries(N).map(([k, [x, y, sub]]) => `<g class="nd" data-nd="${k}"><rect x="${x - 34}" y="${y - 15}" width="68" height="30" rx="4"/><text x="${x}" y="${y + 1}">${k === 'NF' ? 'N-F' : k}</text><text class="s" x="${x}" y="${y + 10}">${sub}</text></g>`).join('')}
        <text class="cap" x="150" y="366">SYSTEMS MAP // LOS ANGELES DIVISION</text>
      </svg>`;
    }
    const rw = (label, k, u) => `<div class="rw" id="r-${k}"><span>${label}</span><b id="v-${k}" data-u="${u ? ' ' + u : ''}">--${u ? ' ' + u : ''}</b></div>`;

    function drawArt() {
      const box = $('#pkart', el), sc = $('#pksc', el); if (!box) return;
      const pk = pack(), src = pk.img || pk.diagram;
      const tg = $('#pkvt', el); if (tg) tg.innerHTML = src && !edit ? `<button data-v="pack" class="${view === 'pack' ? 'on' : ''}">PACK</button><button data-v="map" class="${view === 'map' ? 'on' : ''}">SYSTEMS</button>` : '';
      if (tg) tg.querySelectorAll('button').forEach(b => b.onclick = () => { view = b.dataset.v; try { localStorage.setItem('pk-view', view); } catch (e) { /* ignore */ } drawArt(); });
      if (!src || (view === 'map' && !edit)) { box.className = 'map'; box.style.width = box.style.height = ''; el._fit = null; box.innerHTML = systemsMap(); return; }
      (pk.img ? trace : lineArt)(src, t => {
        if (!t) return;
        const fit = () => { const r = sc.getBoundingClientRect(), k = Math.min((r.width - 12) / t.w, (r.height - 12) / t.h); box.style.width = Math.max(10, t.w * k) + 'px'; box.style.height = Math.max(10, t.h * k) + 'px'; };
        box.className = 'art' + (pk.img ? '' : ' dg');
        const marks = edit ? edit.marks : (pk.marks || {});
        box.innerHTML = `<div class="tr" style="-webkit-mask-image:url(${t.url});mask-image:url(${t.url})"></div>${MARKS.map(([k, , s]) => marks[k] ? `<div class="mk${!pk.img && LEFT[k] ? ' l' : ''}" data-mk="${k}" style="left:${marks[k][0]}%;top:${marks[k][1]}%"><b></b><span>${pk.img ? s : DIAG[k]}</span></div>` : '').join('')}<div class="cl" id="pkcl"></div>`;
        fit(); el._fit = fit;
        if (edit) box.onclick = ev => { const r = box.getBoundingClientRect(); edit.marks[MARKS[edit.i][0]] = [+(100 * (ev.clientX - r.left) / r.width).toFixed(1), +(100 * (ev.clientY - r.top) / r.height).toFixed(1)]; advance(); };
      });
    }

    function paintButtons() {
      el.className = 'pk m' + mode + (mode ? ' on' : '') + (firing ? ' fire' : '') + (edit ? ' edit' : '') + (mode === 3 ? (ventTimer ? ' vent' : ' crit') : '');
      el.style.setProperty('--ph', PH[1]); el.style.setProperty('--md', PH[mode]); // frame stays green; numbers and diagram take the mode colour
      ['b1', 'b2'].forEach((b, i) => { const x = $('#' + b, el); if (x) x.classList.toggle('on', mode === i + 1); });
      const b0 = $('#b0', el); if (b0) { b0.classList.toggle('on', mode > 0); b0.textContent = mode ? 'PACK ON' : 'PACK OFF'; }
      const b3 = $('#pkb3', el); if (b3) b3.textContent = ventTimer ? 'EMERGENCY VENT IN PROGRESS // DO NOT APPROACH' : 'RELEASE TRIGGER TO VENT';
      const m = $('#pkmode', el); if (m) m.textContent = mode === 3 ? (ventTimer ? 'EMERGENCY VENT' : 'TOTAL FAILURE') : firing ? (failed.length ? 'CASCADE FAILURE' : 'FIRING') : failed.length ? 'RECOVERING' : MODES[mode];
    }

    function log(t) { logLines.unshift(clock() + '  ' + t); logLines = logLines.slice(0, 14); renderLog(); }
    function renderLog() { const l = $('#pklg', el); if (l) l.innerHTML = '<div class="sub" style="margin-bottom:4px">BOOT SEQUENCE</div>' + logLines.map(x => '&gt; ' + esc(x)).join('<br>'); const t = $('#pktick', el); if (t) t.textContent = logLines[0] ? '> ' + logLines[0] : ''; }

    let booting = null;
    // Firing for more than 8 seconds overheats the pack (overload). Letting go vents it, then it settles back.
    // Firing: heat warning at 5 s, systems fail one after another from 8 s, total failure at 18 s.
    // Letting go stops the cascade; failed systems come back one by one (after a vent if it reached total failure).
    let fireStart = 0, prevMode = 1, ventTimer = null, warned = false, failed = [], lastRestore = 0;
    const exName = k => (EX.find(x => x[0] === k) || [, , , k.toUpperCase()])[3];
    function startFire() {
      if (!mode || firing) return;
      if (ventTimer) return log('STREAM: LOCKED OUT // VENTING');
      if (mode === 3) return;
      firing = true; fireStart = performance.now(); warned = false; log('STREAM: FIRING'); buzz(30); tone(); paintButtons();
    }
    function stopFire() {
      if (!firing) return;
      firing = false;
      if (mode === 3) {
        log('EMERGENCY VENT // STREAM LOCKED'); buzz([40, 40, 40]);
        ventTimer = setTimeout(() => { ventTimer = null; if (mode === 3) { mode = prevMode; log('VENT COMPLETE // CONTAINMENT STABLE'); tone(); paintButtons(); } }, 9000);
      } else log(failed.length ? 'STREAM: CEASE FIRE // CASCADE HALTED' : 'STREAM: CEASE FIRE');
      lastRestore = performance.now(); tone(); paintButtons();
    }
    function heatCheck() {
      const now = performance.now();
      if (firing && mode !== 3) {
        const held = now - fireStart;
        if (held > 5000 && !warned) { warned = true; log('HEAT SINK: TEMPERATURE CRITICAL'); buzz(20); }
        if (held > 8000) {
          const want = Math.min(FAIL_ORDER.length, 1 + Math.floor((held - 8000) / (10000 / FAIL_ORDER.length)));
          while (failed.length < want) { const k = FAIL_ORDER[failed.length]; failed.push(k); log('FAILURE: ' + exName(k)); buzz(25); if (failed.length === 1) log('WARNING: CASCADE FAILURE IN PROGRESS'); paintButtons(); }
        }
        if (held > 18000) { prevMode = mode; mode = 3; log('CRITICAL: TOTAL PACK FAILURE IMMINENT'); log('EMERGENCY PROCEDURE: STAND BACK 3 MILES UPWIND FROM PACK'); buzz([200, 80, 200, 80, 200]); tone(); paintButtons(); }
      }
      // recovery once the trigger is released (waits for the vent after a total failure)
      if (!firing && !ventTimer && failed.length && now - lastRestore > 600) { const k = failed.pop(); lastRestore = now; log('RESTORED: ' + exName(k)); paintButtons(); }
    }
    function setMode(m) {
      if (m === mode) return;
      const was = mode; mode = m; firing = false; failed = []; if (ventTimer) { clearTimeout(ventTimer); ventTimer = null; }
      if (was === 0 && m > 0) { // power-up boot sequence
        clearInterval(booting); let i = 0; booting = setInterval(() => { if (i < BOOT.length) log('BOOT: ' + BOOT[i++]); else clearInterval(booting); }, 260);
        buzz([20, 40, 20]);
      } else log('MODE: ' + (m ? MODES[m] : 'SHUTDOWN'));
      if (m === 3) buzz([60, 60, 60]);
      tone(); paintButtons();
    }

    function wire() {
      const on = (id, f) => { const b = $('#' + id, el); if (b) b.onclick = f; };
      on('b0', () => setMode(mode ? 0 : 1)); on('b1', () => setMode(1)); on('b2', () => setMode(2));
      on('ba', () => { if (audio) { stopAudio(); try { localStorage.setItem('pk-sound', 'off'); } catch (x) { /* ignore */ } } else { startAudio(); try { localStorage.removeItem('pk-sound'); } catch (x) { /* ignore */ } } frame(); });
      on('bm', () => $('#pkmore', el).classList.toggle('open'));
      on('pkx', close); on('pkx2', close);
      on('pkfs', () => (document.fullscreenElement ? document.exitFullscreen() : el.requestFullscreen()).catch(() => toast('Full screen is not available here. On iPhone, add Busters to your home screen.')));
      on('pkset', setup); on('pkskip', advance);
      const bf = $('#bf', el);
      bf.onpointerdown = e => { e.preventDefault(); startFire(); }; bf.onpointerup = bf.onpointerleave = bf.onpointercancel = () => stopFire();
      bf.oncontextmenu = e => e.preventDefault();
      $('#pkwho', el).onchange = e => { who = e.target.value; try { localStorage.setItem('pk-who', who); } catch (x) { /* ignore */ } cur = who === 'cycle' ? nextCycle() : who; frame(); };
    }

    function setup() {
      const inp = document.createElement('input'); inp.type = 'file'; inp.accept = 'image/*';
      inp.onchange = async () => {
        const f = inp.files[0]; if (!f) return;
        const bmp = await createImageBitmap(f).catch(() => null); if (!bmp) return toast("That photo couldn't be opened.");
        const k = Math.min(1, 1100 / Math.max(bmp.width, bmp.height)), c = document.createElement('canvas'); c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k); c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
        let img = c.toDataURL('image/jpeg', .85); if (img.length > 880000) img = c.toDataURL('image/jpeg', .7);
        S.settings.pack_monitor = { img, marks: {} }; edit = { i: 0, marks: {} }; frame();
      };
      if (pack().img && !confirm('Use a new pack photo? Cancel keeps this photo and lets you re-place the part labels.')) { edit = { i: 0, marks: {} }; frame(); return; }
      inp.click();
    }
    async function advance() {
      edit.i++;
      if (edit.i < MARKS.length) return frame();
      const pk = { ...pack(), marks: edit.marks }; edit = null;
      try { await rpc('set_pack_monitor', { p_crew: S.crew.id, p_pack: pk }); S.settings.pack_monitor = pk; toast('Pack saved'); } catch (e) { /* rpc shows the error */ }
      frame();
    }
    function nextCycle() { const ids = todays(); const list = ids.length ? ids : crew.map(c => c.id); if (!list.length) return null; cycleIdx = (cycleIdx + 1) % list.length; return list[cycleIdx]; }

    // live values
    const t0 = performance.now(); let step = 0;
    function tick() {
      heatCheck();
      const t = (performance.now() - t0) / 1000, seed = hash((person() || {}).id || 'x') % 97;
      const lvl = mode === 3 && ventTimer ? 2.3 : mode + (firing ? .6 : 0); // readings ease down while venting
      Object.entries(R).forEach(([k, r], i) => {
        const mi = Math.min(3, Math.floor(lvl)), mf = r.m[mi] + (r.m[Math.min(3, mi + 1)] - r.m[mi]) * (lvl - mi);
        const target = r.i * mf + (mode ? r.w * (Math.sin(t / (1.7 + i * .3) + seed + i) * .7 + Math.sin(t * 3.1 + i) * .3) * (mode === 3 ? 2.5 : 1) : 0);
        const o = oos[k], f = failed.includes(k), tgt = f ? target * (1.35 + Math.random() * .9) * (Math.random() < .15 ? .2 : 1) : o ? target * (1 + o.dir * o.amt) : target;
        V[k] += (tgt - V[k]) * (mode ? .12 : .06);
        const b = $('#v-' + k, el); if (b) b.textContent = fmt(Math.max(0, V[k]), r.d) + b.dataset.u;
      });
      const word = (id, txt, bad) => { const b = $('#v-' + id, el); if (b) { b.textContent = txt; b.classList.toggle('bad', !!bad); } };
      // systems drift out of spec now and then, then recover
      const now = performance.now();
      Object.keys(oos).forEach(k => { if (now > oos[k].until || !mode) { const e = EX.find(x => x[0] === k); delete oos[k]; if (mode) log('OK: ' + e[3] + ' BACK IN SPEC'); } });
      if (mode && Math.random() < [0, .012, .02, .045][mode] && Object.keys(oos).length < (mode === 3 ? 3 : 2)) {
        const free = EX.filter(e => !oos[e[0]]), e = free[Math.floor(Math.random() * free.length)];
        if (e) { oos[e[0]] = { until: now + 3500 + Math.random() * 5000, dir: e[4], amt: .18 + Math.random() * .2 }; log('WARN: ' + e[3] + ' OUT OF SPEC'); buzz(15); }
      }
      EX.forEach(([k, mk, nd]) => { const on = !!oos[k] || (mk === 'cyclotron' && EX.some(x => x[1] === 'cyclotron' && oos[x[0]]));
        const fl = failed.includes(k) || (mk === 'cyclotron' && (failed.includes('stab') || failed.includes('rpm')));
        const r0 = $('#r-' + k, el); if (r0) r0.classList.toggle('fail', failed.includes(k));
        const m0 = el.querySelector(`[data-mk="${mk}"]`); if (m0) m0.classList.toggle('fail', fl);
        if (nd) { const n0 = el.querySelector(`[data-nd="${nd}"]`); if (n0) n0.classList.toggle('fail', failed.includes(k)); }
        const r = $('#r-' + k, el); if (r) r.classList.toggle('oos', !!oos[k]);
        const m2 = el.querySelector(`[data-mk="${mk}"]`); if (m2) m2.classList.toggle('oos', on);
        if (nd) { const n = el.querySelector(`[data-nd="${nd}"]`); if (n) n.classList.toggle('oos', !!oos[k]); } });
      word('ppd', failed.includes('ppd') ? 'FAILED' : oos.ppd ? 'FLUCTUATING' : ['OFFLINE', 'STABLE', 'STABLE', 'FAILED'][mode], mode === 3 || failed.includes('ppd'));
      word('hga', failed.includes('flow') ? 'FAILED' : ventTimer ? 'VENTING' : mode ? (firing ? 'OPEN' : 'READY') : 'SEALED', failed.includes('flow'));
      word('nf', failed.includes('nf') ? 'FAILED' : oos.nf ? 'CLOGGED' : mode === 3 ? 'VENT NOW' : V.heat > 62 ? 'VENT SOON' : mode ? 'ONLINE' : 'STANDBY', mode === 3);
      word('cont', mode === 3 ? 'BREACH' : failed.length > 6 ? 'BREACH RISK' : failed.length ? 'DEGRADING' : mode ? 'STABLE' : 'IDLE', mode === 3 || failed.length > 6);
      const ost = $('#pkost', el); if (ost) ost.textContent = mode ? `CYCL: RUN // FIELD: ${mode === 3 ? 'WARNING' : 'NOMINAL'}${firing ? ' // STREAM: LIVE' : ''}` : 'CYCL: STOP // FIELD: OFFLINE';
      const ck = $('#pkclk', el); if (ck) ck.textContent = clock();
      // cyclotron light steps around the cyclotron marker
      const cl = $('#pkcl', el), m = (pack().marks || {}).cyclotron;
      if (view === 'map' || !(pack().img || pack().diagram)) { el.style.setProperty('--fs', [1.6, 1.6, .9, .45][mode] / (firing ? 2 : 1) + 's'); if (mode) step += mode === 3 ? 1 : (firing ? .7 : mode === 2 ? .5 : .25); const q = Math.floor(step) % 4; for (let i = 0; i < 4; i++) { const L = $('#pkL' + i, el); if (L) L.classList.toggle('hot', !!mode && i === q); } }
      const lts = pack().lights;
      if (cl && (m || lts) && mode) { step += mode === 3 ? 1 : (firing ? .7 : mode === 2 ? .5 : .25); const q = Math.floor(step) % 4;
        if (lts && lts[q]) { cl.style.left = lts[q][0] + '%'; cl.style.top = lts[q][1] + '%'; } else { const a = [-90, 0, 90, 180][q] * Math.PI / 180; cl.style.left = (m[0] + 7 * Math.cos(a)) + '%'; cl.style.top = (m[1] + 5 * Math.sin(a)) + '%'; } }
      if (audio) tone();
    }

    // oscilloscope
    function scope() {
      const c = $('#pkos', el); if (!c) return;
      const r = c.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
      if (c.width !== Math.round(r.width * dpr)) { c.width = Math.round(r.width * dpr); c.height = Math.round(r.height * dpr); }
      const x = c.getContext('2d'), w = c.width, h = c.height, t = performance.now() / 1000;
      x.clearRect(0, 0, w, h);
      const amp = [0.02, .25, .36, .44][mode], fr = [0, 1.2, 2.4, 4][mode];
      const wave = (cc, cycles, speed, a, ph, jit, lw, blur) => {
        x.beginPath(); x.lineWidth = lw * dpr; x.strokeStyle = cc; x.shadowColor = cc; x.shadowBlur = blur * dpr;
        for (let i = 0; i <= w; i += 2) { const u = i / w; let y = Math.sin(u * Math.PI * cycles + t * speed + ph) * a; if (jit) y += (Math.random() - .5) * jit; x.lineTo(i, h / 2 + y * h); }
        x.stroke();
      };
      if (firing) {
        // live stream: tight, fast blue waves wrapped by a slower orange one
        wave('#ff9a3c', 3.2, -7, .34, 1.7, .05, 2.2, 10);
        wave('#3fb6ff', 14, 26, .3, 0, .07, 2.4, 14);
        wave('#9fe0ff', 22, 34, .18, 2.1, .05, 1.4, 8);
        wave('#3fb6ff', 9, -21, .22, 4.2, .06, 1.6, 10);
      } else {
        const jit = mode === 3 ? .08 : 0;
        wave('#3fb6ff', 2, fr, amp, 0, jit, 2, 8);
        wave('#ff9a3c', 3, fr, amp, 1.7, jit, 2, 8);
      }
    }
    let raf = 0; const loop = () => { scope(); raf = requestAnimationFrame(loop); };

    // sound (off until tapped): a low hum that rises with the mode
    function startAudio() {
      try {
        const ac = new (window.AudioContext || window.webkitAudioContext)(), g = ac.createGain(), f = ac.createBiquadFilter(), o1 = ac.createOscillator(), o2 = ac.createOscillator();
        o1.type = 'sawtooth'; o2.type = 'sine'; f.type = 'lowpass'; f.frequency.value = 600; g.gain.value = 0;
        o1.connect(f); o2.connect(f); f.connect(g); g.connect(ac.destination); o1.start(); o2.start();
        audio = { ac, g, f, o1, o2 }; tone();
      } catch (e) { /* no sound on this device */ }
    }
    function stopAudio() { if (!audio) return; try { audio.ac.close(); } catch (e) { /* ignore */ } audio = null; }
    function tone() {
      if (!audio) return; const now = audio.ac.currentTime, base = [0, 55, 70, 92][mode] + (firing ? 40 : 0);
      audio.o1.frequency.setTargetAtTime(base || 40, now, .3); audio.o2.frequency.setTargetAtTime((base || 40) * 2.01 + (mode === 3 ? Math.sin(now * 9) * 20 : 0), now, .3);
      audio.f.frequency.setTargetAtTime(firing ? 2200 : 500 + mode * 200, now, .2); audio.g.gain.setTargetAtTime(mode ? (firing ? .12 : .06) : 0, now, .3);
    }
    const buzz = p => { try { navigator.vibrate && navigator.vibrate(p); } catch (e) { /* ignore */ } };

    function close() { timers.forEach(clearInterval); clearTimeout(ventTimer); clearInterval(booting); cancelAnimationFrame(raf); stopAudio(); if (lock) lock.release().catch(() => {}); if (document.fullscreenElement) document.exitFullscreen().catch(() => {}); el.remove(); document.removeEventListener('keydown', key); document.removeEventListener('keyup', keyUp); removeEventListener('resize', onResize); }
    const key = e => {
      if (e.repeat) return;
      const k = e.key.toLowerCase();
      if (k === 'escape' && !document.fullscreenElement && !edit) close();
      else if (k === 'p') setMode(mode ? 0 : 1); else if (k === '1') setMode(1); else if (k === '2') setMode(2);
      else if (k === 'f') startFire();
    };
    const keyUp = e => { if (e.key.toLowerCase() === 'f') stopFire(); };
    const onResize = () => el._fit && el._fit();
    document.addEventListener('keydown', key); document.addEventListener('keyup', keyUp); addEventListener('resize', onResize);
    if (navigator.wakeLock) navigator.wakeLock.request('screen').then(l => { lock = l; }).catch(() => {});

    if (who === 'cycle') cur = nextCycle();
    log('LINK: LOS ANGELES DIVISION');
    frame(); loop();
    // Sound is on by default (unless this person turned it off before). Phones only allow sound after a tap,
    // so it starts now if the browser allows it and otherwise wakes on the first touch.
    let soundOff = false; try { soundOff = localStorage.getItem('pk-sound') === 'off'; } catch (e) { /* ignore */ }
    if (!soundOff) {
      startAudio();
      const wake = () => { if (audio && audio.ac.state === 'suspended') audio.ac.resume().catch(() => {}); };
      el.addEventListener('pointerdown', wake, { capture: true });
      el.addEventListener('keydown', wake, { capture: true });
      if (audio) { const b = $('#ba', el); if (b) b.textContent = 'SOUND ON'; }
    }
    setTimeout(() => setMode(1), 400); // pack starts powered on, with its boot sequence
    timers.push(setInterval(tick, 120));
    timers.push(setInterval(() => { if (who === 'cycle' && !edit) { cur = nextCycle(); frame(); } }, 20000));
    timers.push(setInterval(() => { if (mode) log(['PING: TELEMETRY REFRESHED', 'SYS: FIELD LENS RECALIBRATED', 'N-FILTER: PARTICULATE ' + Math.round(10 + mode * 6) + ' PPM', 'ION ARM: ALIGNMENT HOLDING', 'DO NOT CROSS THE STREAMS'][Math.floor(Math.random() * 5)]); }, 5000));
  };
})();

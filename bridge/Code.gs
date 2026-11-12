/**
 * Busters Google bridge for the Los Angeles Ghostbusters.
 *
 * Runs in the Google account that owns the LAGB Calendar Ops calendar and can open the yearly
 * Master Events List. It never writes to the sheet.
 *   - Every 5 minutes: syncs LAGB Calendar Ops with Busters, both ways.
 *   - Every hour: copies sign-up names and new event tabs from the sheet into Busters.
 *
 * Setup: paste this file into a new Apps Script project, put the bridge key in BRIDGE_TOKEN,
 * then run setup() once and approve the permissions.
 */

const BRIDGE_TOKEN = 'PASTE_THE_BRIDGE_KEY_HERE';

const SUPABASE_URL = 'https://fwptdvoifkfljblyziva.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Cq_YmHplQQL1xqIE6HhCwg_JYSMIFKp';   // public app key; the bridge key above is what proves it is you
const CALENDAR_ID = '0d14ca2f6434b00fa9d10b4fdf801c6b295ae77d21d0692bdc1b2ee823e7c35b@group.calendar.google.com';
const SHEET_ID = '13vQjX7M1gBI049-3jwIj5dnJcnCL6lAsDnDLzXqP2oY';   // 2026 Master Events List (read only)
const TZ = 'America/Los_Angeles';

/** Run once. Creates the two timers and runs both syncs so you can see they work. */
function setup() {
  if (!BRIDGE_TOKEN || BRIDGE_TOKEN.indexOf('PASTE') === 0) throw new Error('Paste the bridge key into BRIDGE_TOKEN at the top first.');
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncCalendar').timeBased().everyMinutes(5).create();
  ScriptApp.newTrigger('syncSheet').timeBased().everyHours(1).create();
  const a = syncSheet();
  const b = syncCalendar();
  console.log('Setup done. Sheet: ' + JSON.stringify(a) + ' Calendar: ' + JSON.stringify(b));
}

/** Stops the bridge (removes the timers). */
function stop() {
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  console.log('Bridge stopped.');
}

/* ---------------- sheet ---------------- */

function syncSheet() {
  return withLock_(function () {
    const ss = SpreadsheetApp.openById(SHEET_ID);
    const year = Number((ss.getName().match(/(20\d\d)/) || [])[1]) || Number(Utilities.formatDate(new Date(), TZ, 'yyyy'));
    const today = Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd');
    const tabs = [];
    ss.getSheets().forEach(function (sh) {
      const name = sh.getName();
      const m = name.match(/^\s*(\d{1,2})\s*\/\s*(\d{1,2})/);
      // "12/XX" tabs: the month is known but not the day. Busters lists them under that month as "Date TBD".
      const tbd = !m && name.match(/^\s*(\d{1,2})\s*\/\s*XX\b\s*_?\s*(.*)$/i);
      if (!m && !tbd) return;   // template and other tabs
      const guess = tbd ? year + '-' + pad_(tbd[1]) + '-01' : year + '-' + pad_(m[1]) + '-' + pad_(m[2]);
      if (guess < (tbd ? today.slice(0, 8) + '01' : today)) return;
      try {
        const ev = parseEventTab_(sh.getDataRange().getDisplayValues(), name, year);
        if (ev && tbd) {
          ev.date = guess; ev.end_date = null; ev.tbd = true;
          if (!ev.title || ev.title === name) ev.title = String(tbd[2] || name).trim();
        }
        if (ev) tabs.push(ev);
      } catch (e) { console.error('Could not read tab ' + name + ': ' + e.message); }
    });
    return rpc_('bridge_sheet', { p_token: BRIDGE_TOKEN, p_tabs: tabs });
  });
}

/** One event tab to {tab, title, date, times, text fields, attendees[], reserve[]}. Works by header labels. */
function parseEventTab_(grid, tabName, year) {
  const norm = function (v) { return String(v == null ? '' : v).trim(); };
  let hr = -1;
  for (let r = 0; r < Math.min(grid.length, 30); r++) {
    const row = grid[r].map(function (c) { return norm(c).toLowerCase(); });
    if (row.indexOf('location') >= 0 && row.some(function (c) { return /^attendees?$/.test(c); })) { hr = r; break; }
  }
  if (hr < 0) return null;
  const labels = {
    location: /^location$/, time: /^time$/, parking: /^(driving\s*\/\s*)?parking$|^driving/, eventContact: /^event contact$/,
    lagbContact: /^lagb contact$/, notes: /^special notes$|^notes$/, attendees: /^attendees?$/, reserve: /^reserve$/
  };
  const col = {};
  grid[hr].forEach(function (c, i) {
    const v = norm(c).toLowerCase();
    Object.keys(labels).forEach(function (k) { if (col[k] == null && labels[k].test(v)) col[k] = i; });
  });
  let end = grid.length;
  for (let r = hr + 1; r < grid.length; r++) { if (/^submission/i.test(norm(grid[r][0]) || norm(grid[r][1]))) { end = r; break; } }
  const cells = function (k) {
    if (col[k] == null) return [];
    const out = [];
    for (let r = hr + 1; r < end; r++) { const v = norm(grid[r][col[k]]); if (v) out.push(v); }
    return out;
  };
  let dateText = '', title = '';
  for (let r = hr - 1; r >= 0 && r >= hr - 4; r--) {
    const row = grid[r].map(norm).filter(Boolean);
    const d = row.filter(function (c) { return /\d{1,2}\s*\/\s*\d{1,2}/.test(c); })[0];
    const t = row.filter(function (c) { return c !== d && !/master events list|los angeles ghostbusters|last updated/i.test(c); })[0];
    if (d && t) { dateText = d; title = t; break; }
  }
  const tb = tabName.match(/^\s*(\d{1,2})\s*\/\s*(\d{1,2})(?:\s*-\s*(?:(\d{1,2})\s*\/\s*)?(\d{1,2}))?\s*_?\s*(.*)$/) || [];
  if (!title) title = norm(tb[5]) || tabName;
  const dm = dateText.match(/(\d{1,2})\s*\/\s*(\d{1,2})(?:\s*\/\s*(\d{2,4}))?/) || [null, tb[1], tb[2]];
  let y = dm[3] ? Number(dm[3]) : year; if (y < 100) y += 2000;
  let conditions = '';
  for (let r = 0; r < hr; r++) for (let c = 0; c < grid[r].length; c++) {
    const v = norm(grid[r][c]);
    if (/indoors|outdoors|weather/i.test(v)) conditions = v.split('\n').filter(function (l) { return !/high\s*º\s*\/\s*low\s*º|X%/i.test(l); }).join(' ').replace(/\s+/g, ' ').trim();
  }
  const schedule = cells('time').join('\n');
  const times = parseTimes_(schedule);
  return {
    tab: tabName, title: title,
    date: y + '-' + pad_(dm[1]) + '-' + pad_(dm[2]),
    end_date: tb[4] ? y + '-' + pad_(tb[3] || tb[1]) + '-' + pad_(tb[4]) : null,
    call: times.call, start: times.start, wrap: times.wrap,
    schedule: schedule, location: cells('location').join('\n'), parking: cells('parking').join('\n'),
    event_contact: cells('eventContact').join('\n'), lagb_contact: cells('lagbContact').join('\n'),
    notes: cells('notes').join('\n'), conditions: conditions,
    attendees: cells('attendees'), reserve: cells('reserve')
  };
}

/** "Call: 4:30p  Event: 5-9p  Wrap: 9PM" to {call, start, wrap} as "HH:MM". */
function parseTimes_(text) {
  const t = String(text || '');
  const CLOCK = '(\\d{1,2}(?::\\d{2})?\\s*(?:[ap]\\.?\\s*m?\\.?)?)';
  const grab = function (re) { const m = t.match(re); return m ? m[1].trim() : ''; };
  const callText = grab(new RegExp('\\bcall(?:\\s*time)?\\s*[:\\-]?\\s*' + CLOCK, 'i'));
  let startText = grab(new RegExp('\\bstart(?:\\s*time)?\\s*[:\\-]?\\s*' + CLOCK, 'i'));
  let wrapText = grab(new RegExp('\\b(?:wrap|end)[a-z]*\\s*[:\\-]?\\s*' + CLOCK, 'i'));
  const range = t.match(/(\d{1,2}(?::\d{2})?)\s*([ap])?\.?\s*m?\.?\s*(?:-|to|–)\s*(\d{1,2}(?::\d{2})?)\s*([ap])\.?\s*m?/i);
  if (range) { if (!startText) startText = range[1] + (range[2] || range[4]); if (!wrapText) wrapText = range[3] + range[4]; }
  const call = toMinutes_(callText), wrap = toMinutes_(wrapText);
  let start = toMinutes_(startText);
  if (start != null && wrap != null && start > wrap && !/[ap]/i.test(startText)) start -= 720;
  return { call: hhmm_(call), start: hhmm_(start), wrap: hhmm_(wrap) };
}
function toMinutes_(txt) {
  const m = String(txt || '').match(/(\d{1,2})(?::(\d{2}))?\s*([ap])?/i);
  if (!m) return null;
  let h = Number(m[1]) % 12; const min = Number(m[2] || 0); const ap = (m[3] || '').toLowerCase();
  if (ap === 'p') h += 12;
  if (!ap && Number(m[1]) >= 1 && Number(m[1]) <= 7) h += 12;
  if (Number(m[1]) === 12 && ap !== 'a') h = 12;
  return h * 60 + min;
}
function hhmm_(v) { return v == null ? null : pad_(Math.floor(v / 60) % 24) + ':' + pad_(v % 60); }
function pad_(n) { return ('0' + Number(n)).slice(-2); }

/* ---------------- calendar ---------------- */

function syncCalendar() {
  return withLock_(function () {
    const cal = CalendarApp.getCalendarById(CALENDAR_ID);
    if (!cal) throw new Error('Calendar not found: ' + CALENDAR_ID);
    const now = new Date();
    const from = new Date(now.getTime() - 2 * 86400000), to = new Date(now.getTime() + 400 * 86400000);
    const list = [];
    cal.getEvents(from, to).forEach(function (ev) {
      if (ev.isRecurringEvent()) return;   // birthdays and other repeating entries stay calendar-only
      const allDay = ev.isAllDayEvent();
      list.push({
        id: ev.getId(), title: ev.getTitle(), all_day: allDay,
        start: allDay ? Utilities.formatDate(ev.getAllDayStartDate(), TZ, 'yyyy-MM-dd') : ev.getStartTime().toISOString(),
        end: allDay ? Utilities.formatDate(ev.getAllDayEndDate(), TZ, 'yyyy-MM-dd') : ev.getEndTime().toISOString(),
        location: ev.getLocation() || '', updated: ev.getLastUpdated().toISOString()
      });
    });

    const todo = rpc_('bridge_calendar', { p_token: BRIDGE_TOKEN, p_cal: list });
    const done = [], deleted = [];
    (todo.create || []).forEach(function (e) {
      try { const ev = createCal_(cal, e); done.push(ack_(e, ev, true)); } catch (err) { console.error('Create failed for ' + e.title + ': ' + err.message); }
    });
    (todo.update || []).forEach(function (e) {
      try {
        let ev = cal.getEventById(e.gcal_id);
        if (!ev) { ev = createCal_(cal, e); done.push(ack_(e, ev, true)); return; }   // removed from the calendar: put it back
        ev.setTitle(e.title);
        if (e.all_day) ev.setAllDayDates(dateOnly_(e.start), dateOnly_(e.end));
        else ev.setTime(new Date(e.start), new Date(e.end));
        ev.setLocation(e.location || '');
        if (e.managed) ev.setDescription(e.description || '');
        done.push(ack_(e, ev, false));
      } catch (err) { console.error('Update failed for ' + e.title + ': ' + err.message); }
    });
    (todo['delete'] || []).forEach(function (id) {
      try { const ev = cal.getEventById(id); if (ev) ev.deleteEvent(); deleted.push(id); } catch (err) { console.error('Delete failed: ' + err.message); }
    });
    if (done.length || deleted.length) rpc_('bridge_calendar_done', { p_token: BRIDGE_TOKEN, p_done: done, p_deleted: deleted });
    return { sent: list.length, created: (todo.create || []).length, updated: (todo.update || []).length, deleted: deleted.length };
  });
}

function createCal_(cal, e) {
  const opts = { location: e.location || '', description: e.description || '' };
  return e.all_day ? cal.createAllDayEvent(e.title, dateOnly_(e.start), dateOnly_(e.end), opts)
                   : cal.createEvent(e.title, new Date(e.start), new Date(e.end), opts);
}
function ack_(e, ev, created) { return { event_id: e.id, gcal_id: ev.getId(), updated_at: e.updated_at, cal_updated: ev.getLastUpdated().toISOString(), created: created }; }
function dateOnly_(s) { const p = String(s).slice(0, 10).split('-').map(Number); return new Date(p[0], p[1] - 1, p[2]); }

/* ---------------- plumbing ---------------- */

function rpc_(fn, body) {
  const res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY },
    payload: JSON.stringify(body)
  });
  const code = res.getResponseCode(), text = res.getContentText();
  if (code >= 300) throw new Error('Busters said ' + code + ': ' + text.slice(0, 300));
  return text ? JSON.parse(text) : null;
}

function withLock_(fn) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) return { skipped: 'another sync is running' };
  try { return fn(); } finally { lock.releaseLock(); }
}

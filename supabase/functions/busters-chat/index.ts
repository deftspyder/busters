// Busters chat. The Chat tab reads and writes the crew's Discord: the crew channel (#rookies) and each event's thread.
// Reading uses the bot. Sending uses a webhook in the crew channel, so a message written in Busters shows in Discord
// under the member's own name and Discord picture (Discord adds its APP tag). Mentions are never pinged from the app.
// Only approved members (active or rookie) of the crew can use it, and only for that crew's channel and threads.
//
// POST JSON {action:"overview", crew, events:[event ids]}  -> crew chat plus those events' chats, with last message and unread
// POST JSON {action:"messages", crew, channel, after?, before?} -> up to 50 messages, oldest first; marks the chat read
// POST multipart (action=send, crew, channel, text, files...)  -> posts as the member, returns the message
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "https://busters.app", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", ...CORS } });
const API = "https://discord.com/api/v10";
const UA = "DiscordBot (https://busters.app, 1)";
const big = (a?: string | null, b?: string | null) => BigInt(a || "0") > BigInt(b || "0");

type Ctx = {
  userId: string; crew: string; me: { id: string; full_name: string; discord_user_id: string | null };
  d: { bot_token: string; channel_id: string; chat_webhook_id: string | null; chat_webhook_token: string | null };
  H: Record<string, string>;
  threads: Map<string, { event_id: string; title: string }>; // thread id -> event
  byEvent: Map<string, string>;                              // event id -> thread id
};

async function context(req: Request, crew: string): Promise<Ctx | Response> {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await sb.auth.getUser(token);
  if (!u?.user) return json({ error: "Sign in first" }, 401);
  const { data: p } = await sb.from("people").select("id,full_name,status").eq("crew_id", crew).eq("user_id", u.user.id).maybeSingle();
  if (!p || !["active", "rookie"].includes(p.status)) return json({ error: "Chat is for approved members" }, 403);
  const { data: d } = await sb.from("crew_discord").select("bot_token,channel_id,chat_webhook_id,chat_webhook_token").eq("crew_id", crew).maybeSingle();
  if (!d?.bot_token || !d.channel_id) return json({ error: "Discord isn't set up for this crew" }, 400);
  const { data: pp } = await sb.from("people_private").select("discord_user_id").eq("person_id", p.id).maybeSingle();
  const { data: th } = await sb.from("discord_threads").select("event_id,thread_id,events(title)").eq("crew_id", crew);
  const threads = new Map<string, { event_id: string; title: string }>(), byEvent = new Map<string, string>();
  for (const t of (th || []) as unknown as { event_id: string; thread_id: string; events: { title: string } | null }[]) {
    threads.set(t.thread_id, { event_id: t.event_id, title: t.events?.title || "event" }); byEvent.set(t.event_id, t.thread_id);
  }
  return { userId: u.user.id, crew, me: { id: p.id, full_name: p.full_name, discord_user_id: pp?.discord_user_id ?? null }, d: d as Ctx["d"], H: { Authorization: "Bot " + d.bot_token, "User-Agent": UA }, threads, byEvent };
}
const allowed = (c: Ctx, ch: string) => ch === c.d.channel_id || c.threads.has(ch);

// Discord with one polite retry on rate limits.
async function dc(c: Ctx, path: string, init: RequestInit = {}): Promise<Response> {
  for (let i = 0; i < 2; i++) {
    const r = await fetch(API + path, { ...init, headers: { ...c.H, ...(init.headers || {}) } });
    if (r.status !== 429) return r;
    const wait = Number((await r.json().catch(() => ({}))).retry_after || 1);
    if (wait > 3) return r;
    await new Promise(res => setTimeout(res, wait * 1000 + 100));
  }
  return fetch(API + path, { ...init, headers: { ...c.H, ...(init.headers || {}) } });
}

// Short cache of each chat's latest page, so several members watching one chat don't each hit Discord.
const cache = new Map<string, { at: number; msgs: Msg[] }>();
type Msg = Record<string, any>;

// Who's who: Discord user id -> member, and app message id -> member.
async function people(c: Ctx, msgs: Msg[]) {
  const ids = [...new Set(msgs.map(m => m.author?.id).filter(Boolean))];
  const sent = msgs.filter(m => m.webhook_id).map(m => m.id);
  const byDiscord = new Map<string, { id: string; full_name: string }>(), bySent = new Map<string, { id: string; full_name: string }>();
  if (ids.length) {
    const { data } = await sb.from("people_private").select("discord_user_id,people(id,full_name)").eq("crew_id", c.crew).in("discord_user_id", ids);
    for (const r of (data || []) as any[]) if (r.people) byDiscord.set(r.discord_user_id, r.people);
  }
  if (sent.length) {
    const { data } = await sb.from("chat_sent").select("message_id,people(id,full_name)").in("message_id", sent);
    for (const r of (data || []) as any[]) if (r.people) bySent.set(r.message_id, r.people);
  }
  return { byDiscord, bySent };
}

function avatar(u: Msg | undefined): string | null {
  if (!u?.id) return null;
  return u.avatar ? `https://cdn.discordapp.com/avatars/${u.id}/${u.avatar}.png?size=64` : null;
}

// Turn Discord markup into plain text the app can show: mentions by name, channel links by event title.
function plain(c: Ctx, m: Msg, names: Map<string, string>): string {
  let t = String(m.content || "");
  t = t.replace(/<@!?(\d+)>/g, (_, id) => "@" + (names.get(id) || "someone"));
  t = t.replace(/<#(\d+)>/g, (_, id) => "#" + (c.threads.get(id)?.title || (id === c.d.channel_id ? "rookies" : "channel")));
  t = t.replace(/<@&\d+>/g, "@role").replace(/<a?:(\w+):\d+>/g, ":$1:");
  t = t.replace(/<t:(\d+)(?::\w)?>/g, (_, s) => new Date(Number(s) * 1000).toLocaleString("en-US", { timeZone: "America/Los_Angeles", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }));
  return t;
}

async function shape(c: Ctx, raw: Msg[]): Promise<Msg[]> {
  const { byDiscord, bySent } = await people(c, raw);
  const names = new Map<string, string>();
  for (const m of raw) for (const u of (m.mentions || [])) names.set(u.id, byDiscord.get(u.id)?.full_name || u.global_name || u.username);
  for (const [k, v] of byDiscord) names.set(k, v.full_name);
  return raw.filter(m => [0, 19, 20, 23].includes(m.type ?? 0)).map(m => {
    const app = m.webhook_id ? bySent.get(m.id) : null;
    const member = app || (!m.author?.bot ? byDiscord.get(m.author?.id) : null);
    const kind = app ? "app" : m.author?.bot || m.webhook_id ? "bot" : member ? "member" : "other";
    return {
      id: m.id, ts: m.timestamp, edited: !!m.edited_timestamp, kind,
      person_id: member?.id || null,
      name: member?.full_name || m.author?.global_name || m.author?.username || "Someone",
      avatar: avatar(m.author),
      text: plain(c, m, names),
      files: (m.attachments || []).map((a: Msg) => ({ url: a.url, thumb: a.proxy_url, name: a.filename, type: a.content_type || "", w: a.width || null, h: a.height || null })),
      cards: (m.embeds || []).filter((e: Msg) => e.title || e.description).slice(0, 2).map((e: Msg) => ({ title: plain(c, { content: e.title || "" }, names), text: plain(c, { content: (e.description || "").slice(0, 400) }, names) })),
    };
  });
}

async function latest(c: Ctx, ch: string, fresh = false): Promise<Msg[] | Response> {
  const hit = cache.get(ch);
  if (!fresh && hit && Date.now() - hit.at < 2500) return hit.msgs;
  const r = await dc(c, `/channels/${ch}/messages?limit=50`);
  if (r.status === 429) return json({ error: "busy", retry: true }, 429);
  if (!r.ok) return json({ error: "Discord said " + r.status }, 502);
  const msgs = ((await r.json()) as Msg[]).reverse();
  cache.set(ch, { at: Date.now(), msgs });
  return msgs;
}

async function markRead(c: Ctx, ch: string, id: string) {
  const { data } = await sb.from("chat_reads").select("last_read").eq("user_id", c.userId).eq("channel_id", ch).maybeSingle();
  if (!data || big(id, data.last_read)) await sb.from("chat_reads").upsert({ user_id: c.userId, channel_id: ch, last_read: id, updated_at: new Date().toISOString() });
}

async function overview(c: Ctx, events: string[]) {
  const list = [{ channel: c.d.channel_id, event_id: null as string | null }];
  for (const e of events) { const t = c.byEvent.get(e); if (t) list.push({ channel: t, event_id: e }); }
  const { data: reads } = await sb.from("chat_reads").select("channel_id,last_read").eq("user_id", c.userId).in("channel_id", list.map(l => l.channel));
  const readMap = new Map((reads || []).map(r => [r.channel_id, r.last_read]));
  const out = await Promise.all(list.map(async l => {
    const r = await dc(c, `/channels/${l.channel}/messages?limit=1`);
    const raw = r.ok ? (await r.json()) as Msg[] : [];
    const last = raw.length ? (await shape(c, raw))[0] || null : null;
    const lastId = raw[0]?.id || null;
    return { channel: l.channel, event_id: l.event_id, last, unread: !!lastId && big(lastId, readMap.get(l.channel) || "0") && !(last && last.person_id === c.me.id) };
  }));
  return { chats: out, crew_channel: c.d.channel_id };
}

async function webhook(c: Ctx): Promise<{ id: string; token: string } | null> {
  if (c.d.chat_webhook_id && c.d.chat_webhook_token) return { id: c.d.chat_webhook_id, token: c.d.chat_webhook_token };
  const r = await dc(c, `/channels/${c.d.channel_id}/webhooks`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Busters chat" }) });
  if (!r.ok) return null;
  const w = await r.json();
  await sb.from("crew_discord").update({ chat_webhook_id: w.id, chat_webhook_token: w.token }).eq("crew_id", c.crew);
  return { id: w.id, token: w.token };
}

const avatarCache = new Map<string, { at: number; url: string | null }>();
async function myAvatar(c: Ctx): Promise<string | null> {
  const id = c.me.discord_user_id; if (!id) return null;
  const hit = avatarCache.get(id); if (hit && Date.now() - hit.at < 3600_000) return hit.url;
  const r = await dc(c, `/users/${id}`);
  const url = r.ok ? avatar(await r.json()) : null;
  avatarCache.set(id, { at: Date.now(), url });
  return url;
}

async function send(c: Ctx, ch: string, text: string, files: File[]) {
  text = text.trim().slice(0, 2000);
  if (!text && !files.length) return json({ error: "Nothing to send" }, 400);
  if (files.length > 6) return json({ error: "Up to 6 photos at a time" }, 400);
  if (files.some(f => f.size > 10 * 1024 * 1024)) return json({ error: "Each photo has to be under 10 MB" }, 400);
  const w = await webhook(c);
  if (!w) return json({ error: "Busters can't post in Discord right now (webhook permission)" }, 502);
  const payload = { content: text, username: c.me.full_name.slice(0, 80), avatar_url: await myAvatar(c) || undefined, allowed_mentions: { parse: [] } };
  const q = "?wait=true" + (ch === c.d.channel_id ? "" : "&thread_id=" + ch);
  const post = () => {
    const fd = new FormData();
    fd.append("payload_json", JSON.stringify({ ...payload, attachments: files.map((f, i) => ({ id: i, filename: f.name || `photo-${i + 1}.jpg` })) }));
    files.forEach((f, i) => fd.append(`files[${i}]`, f, f.name || `photo-${i + 1}.jpg`));
    return fetch(`${API}/webhooks/${w.id}/${w.token}${q}`, { method: "POST", body: fd, headers: { "User-Agent": UA } });
  };
  let r = await post();
  if (!r.ok && ch !== c.d.channel_id) {
    // An archived event thread: wake it up and try once more.
    const err = await r.clone().json().catch(() => ({}));
    if (err.code === 50083 || r.status === 400) {
      await dc(c, `/channels/${ch}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ archived: false }) });
      r = await post();
    }
  }
  if (r.status === 404) { await sb.from("crew_discord").update({ chat_webhook_id: null, chat_webhook_token: null }).eq("crew_id", c.crew); return json({ error: "The Discord webhook was removed. Try again." }, 502); }
  if (!r.ok) return json({ error: "Discord said " + r.status }, 502);
  const m = await r.json();
  await sb.from("chat_sent").insert({ message_id: m.id, crew_id: c.crew, person_id: c.me.id, channel_id: ch });
  await markRead(c, ch, m.id);
  cache.delete(ch);
  return json({ message: (await shape(c, [m]))[0] });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  try {
    const multipart = (req.headers.get("content-type") || "").startsWith("multipart/form-data");
    if (multipart) {
      const fd = await req.formData();
      const c = await context(req, String(fd.get("crew") || ""));
      if (c instanceof Response) return c;
      const ch = String(fd.get("channel") || "");
      if (!allowed(c, ch)) return json({ error: "Not a chat you can use" }, 403);
      return await send(c, ch, String(fd.get("text") || ""), fd.getAll("files").filter(f => f instanceof File) as File[]);
    }
    const b = await req.json().catch(() => ({}));
    const c = await context(req, String(b.crew || ""));
    if (c instanceof Response) return c;
    if (b.action === "overview") return json(await overview(c, Array.isArray(b.events) ? b.events.slice(0, 40).map(String) : []));
    if (b.action === "messages") {
      const ch = String(b.channel || "");
      if (!allowed(c, ch)) return json({ error: "Not a chat you can use" }, 403);
      let raw: Msg[];
      if (b.before) {
        const r = await dc(c, `/channels/${ch}/messages?limit=50&before=${encodeURIComponent(b.before)}`);
        if (!r.ok) return json({ error: "Discord said " + r.status, retry: r.status === 429 }, r.status === 429 ? 429 : 502);
        raw = ((await r.json()) as Msg[]).reverse();
      } else {
        const l = await latest(c, ch);
        if (l instanceof Response) return l;
        raw = b.after ? l.filter(m => big(m.id, b.after)) : l;
      }
      const msgs = await shape(c, raw);
      if (!b.before && raw.length) await markRead(c, ch, raw[raw.length - 1].id);
      return json({ messages: msgs, me: c.me.id, more: !!b.before ? raw.length === 50 : (!b.after && raw.length === 50) });
    }
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});

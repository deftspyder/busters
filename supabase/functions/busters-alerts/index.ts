// Busters alerts sender, run every 15 minutes by pg_cron.
// Sends what public.alert_plan() says is due (short-staffed events and the 48-hour last call) to each
// person's phones, once per person, event and kind (alert_log). Running it extra times sends nothing new.
// POST with a member's sign-in token and {"mode":"test"} sends a test alert to that member's own devices.
// The push keys are created here on the first run and stay in push_config; the app reads only the public key.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SITE = "https://busters.app/";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "https://busters.app", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", ...CORS } });

type Sub = { id: string; user_id: string; endpoint: string; p256dh: string; auth: string };
let ready = false;
async function config() {
  if (ready) return;
  let { data } = await sb.from("push_config").select("vapid_public,vapid_private").eq("id", 1).maybeSingle();
  if (!data) {
    const k = webpush.generateVAPIDKeys();
    await sb.from("push_config").insert({ id: 1, vapid_public: k.publicKey, vapid_private: k.privateKey });
    ({ data } = await sb.from("push_config").select("vapid_public,vapid_private").eq("id", 1).maybeSingle());
  }
  if (!data) throw new Error("push config missing");
  webpush.setVapidDetails(SITE, data.vapid_public, data.vapid_private);
  ready = true;
}

async function send(sub: Sub, payload: unknown): Promise<string> {
  try {
    await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, JSON.stringify(payload), { TTL: 6 * 3600, urgency: "high" });
    await sb.from("push_subs").update({ last_ok_at: new Date().toISOString() }).eq("id", sub.id);
    return "ok";
  } catch (e) {
    const code = (e as { statusCode?: number }).statusCode;
    if (code === 404 || code === 410) { await sb.from("push_subs").delete().eq("id", sub.id); return "gone"; }
    return "error " + (code || (e as Error).message);
  }
}
async function subsOf(users: string[]) {
  const m = new Map<string, Sub[]>();
  if (!users.length) return m;
  const { data } = await sb.from("push_subs").select("id,user_id,endpoint,p256dh,auth").in("user_id", users);
  for (const s of (data || []) as Sub[]) { if (!m.has(s.user_id)) m.set(s.user_id, []); m.get(s.user_id)!.push(s); }
  return m;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  try {
    await config();
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};

    if (body && body.mode === "test") {
      const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u } = await sb.auth.getUser(token);
      if (!u || !u.user) return json({ error: "sign in first" }, 401);
      const subs = (await subsOf([u.user.id])).get(u.user.id) || [];
      if (!subs.length) return json({ sent: 0, note: "no devices with alerts on" });
      const r = await Promise.all(subs.map(s => send(s, { title: "Busters test alert", body: "Alerts are working on this device.", url: SITE, tag: "test" })));
      return json({ sent: r.filter(x => x === "ok").length, results: r });
    }

    // Everything past here is the scheduled run: only the database's timer, which sends the key, may start it.
    const { data: k } = await sb.from("app_keys").select("value").eq("name", "alerts_secret").maybeSingle();
    if (!k?.value || body?.secret !== k.value) return json({ error: "not allowed" }, 403);

    const { data: plan, error } = await sb.rpc("alert_plan");
    if (error) throw error;
    const rows = (plan || []) as { user_id: string; person_id: string; event_id: string; kind: string; title: string; body: string; url: string }[];
    const subs = await subsOf([...new Set(rows.map(r => r.user_id))]);
    let sent = 0, skipped = 0;
    for (const r of rows) {
      const list = subs.get(r.user_id) || [];
      if (!list.length) { skipped++; continue; }
      const res = await Promise.all(list.map(s => send(s, { title: r.title, body: r.body, url: r.url, tag: r.kind + "-" + r.event_id })));
      if (res.some(x => x === "ok") || res.every(x => x === "gone")) {
        await sb.from("alert_log").upsert({ person_id: r.person_id, event_id: r.event_id, kind: r.kind }, { onConflict: "person_id,event_id,kind", ignoreDuplicates: true });
        if (res.some(x => x === "ok")) sent++;
      }
    }
    return json({ due: rows.length, sent, no_device: skipped });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});

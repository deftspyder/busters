// Busters Discord bot check. A crew admin calls it (with their sign-in token) right after saving the bot token.
// It signs the bot in to Discord once (Discord asks every bot to do this before it can post), then looks up the
// bot's name and the channel's name so the Team tab can show them. The token never leaves the database.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const sb = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "https://busters.app", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", ...CORS } });
const API = "https://discord.com/api/v10";

function identifyOnce(token: string): Promise<string> {
  return new Promise((resolve) => {
    let done = false;
    const ws = new WebSocket("wss://gateway.discord.gg/?v=10&encoding=json");
    const finish = (r: string) => { if (done) return; done = true; try { ws.close(); } catch (_) { /* closed */ } resolve(r); };
    const timer = setTimeout(() => finish("timeout"), 12000);
    ws.onmessage = (m) => {
      const d = JSON.parse(String(m.data));
      if (d.op === 10) ws.send(JSON.stringify({ op: 2, d: { token, intents: 0, properties: { os: "linux", browser: "busters", device: "busters" } } }));
      else if (d.op === 0 && d.t === "READY") { clearTimeout(timer); finish("ok"); }
      else if (d.op === 9) { clearTimeout(timer); finish("invalid session"); }
    };
    ws.onclose = (e) => { clearTimeout(timer); finish(e.code === 4004 ? "bad token" : "closed " + e.code); };
    ws.onerror = () => { clearTimeout(timer); finish("error"); };
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { crew } = await req.json();
    const auth = req.headers.get("Authorization") || "";
    const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: settings } = await user.rpc("discord_settings", { p_crew: crew });
    if (!settings) return json({ error: "not allowed" }, 403);

    const { data: d } = await sb.from("crew_discord").select("bot_token,channel_id").eq("crew_id", crew).maybeSingle();
    if (!d?.bot_token) return json({ error: "No bot token saved yet" }, 400);
    const H = { Authorization: "Bot " + d.bot_token, "User-Agent": "DiscordBot (https://busters.app, 1)" };

    const me = await fetch(API + "/users/@me", { headers: H });
    if (me.status === 401) return json({ error: "Discord says the bot token is wrong. Reset it in the Developer Portal and paste the new one." }, 400);
    const bot = await me.json();
    const gateway = await identifyOnce(d.bot_token);

    let channel: { name?: string } | null = null, chErr = "";
    if (d.channel_id) {
      const c = await fetch(API + "/channels/" + d.channel_id, { headers: H });
      if (c.ok) channel = await c.json();
      else chErr = c.status === 403 || c.status === 404
        ? "The bot can't see that channel yet. Invite it to the server, and check it can view the channel."
        : "Discord said " + c.status + " for the channel.";
    }
    await sb.from("crew_discord").update({ bot_name: bot.username, app_id: bot.id, channel_name: channel?.name ?? null, bot_checked_at: new Date().toISOString() }).eq("crew_id", crew);
    return json({ bot: bot.username, app_id: bot.id, gateway, channel: channel?.name ?? null, channel_error: chErr || null });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});

// Busters Discord interactions: Discord calls this when someone taps Going / Maybe / Can't on a Busters card.
// Set as the app's Interactions Endpoint URL in the Discord Developer Portal. Every request is checked against
// the app's public key. The answer is saved in Busters, the tapper gets a private confirmation, and the card's
// Busters count is refreshed.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const API = "https://discord.com/api/v10";
const UA = "DiscordBot (https://deftspyder.github.io/busters, 1)";
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
const hex = (h: string) => new Uint8Array(h.match(/.{2}/g)!.map((x) => parseInt(x, 16)));
const reply = (content: string) => json({ type: 4, data: { content, flags: 64 } });

async function verify(publicKey: string, sig: string, ts: string, body: string) {
  try {
    const key = await crypto.subtle.importKey("raw", hex(publicKey), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, hex(sig), new TextEncoder().encode(ts + body));
  } catch (_) { return false; }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const body = await req.text();
  const sig = req.headers.get("X-Signature-Ed25519") || "", ts = req.headers.get("X-Signature-Timestamp") || "";
  let i: any;
  try { i = JSON.parse(body); } catch (_) { return new Response("bad request", { status: 400 }); }

  const { data: d } = await sb.from("crew_discord").select("crew_id,public_key,bot_token").eq("app_id", i.application_id).maybeSingle();
  if (!d) return new Response("unknown app", { status: 401 });
  let pk = d.public_key as string | null;
  if (!pk && d.bot_token) {
    const a = await fetch(API + "/applications/@me", { headers: { Authorization: "Bot " + d.bot_token, "User-Agent": UA } });
    if (a.ok) { pk = (await a.json()).verify_key; await sb.from("crew_discord").update({ public_key: pk }).eq("crew_id", d.crew_id); }
  }
  if (!pk || !(await verify(pk, sig, ts, body))) return new Response("invalid request signature", { status: 401 });

  if (i.type === 1) return json({ type: 1 });                       // Discord's check that this URL works
  if (i.type !== 3) return reply("Busters doesn't know that one yet.");

  const [kind, eventId, answer] = String(i.data?.custom_id || "").split(":");
  const u = i.member?.user || i.user || {};
  if (kind === "test") {                                              // test card: checks who you are, saves no answer
    const { data: m } = await sb.rpc("discord_match", { p_app: i.application_id, p_user: u.id, p_username: u.username || null, p_display: u.global_name || null, p_nick: i.member?.nick || null });
    const a = { going: "Going", maybe: "Maybe", no: "Can't" }[eventId] || eventId;
    if (m?.status === "ok") return reply(`✅ Test worked. Busters knows you as **${m.name}**, and would have marked you **${a}**. Nothing was saved.`);
    if (m?.status === "unlinked") return reply(`The tap reached Busters, but it couldn't match your Discord account to a member yet. You'll show up on the Team tab under "Who is this?" for linking. Nothing was saved.`);
    return reply("The tap reached Busters, but something's off with the setup.");
  }
  if (kind !== "rsvp") return reply("Busters doesn't know that button.");
  const { data: r, error } = await sb.rpc("discord_answer", {
    p_app: i.application_id, p_user: u.id, p_username: u.username || null, p_display: u.global_name || null,
    p_nick: i.member?.nick || null, p_event: eventId, p_answer: answer,
  });
  if (error || !r) return reply("Something went wrong saving that. Try again in a minute.");

  if (r.status === "unlinked") return reply(`I couldn't match your Discord account to a Busters member yet, so your answer for **${r.title}** is waiting. An admin will link you, and it'll count as soon as they do.`);
  if (r.status === "closed") return reply("That event isn't taking answers anymore.");
  if (r.status === "past") return reply("That event has already happened.");
  if (r.status !== "ok") return reply("Something went wrong saving that.");

  // Refresh the card's Busters count for everyone (in the background, after replying).
  const msg = i.message;
  if (msg?.embeds?.[0] && d.bot_token) {
    const emb = msg.embeds[0];
    emb.fields = (emb.fields || []).map((f: any) => f.name === "Busters" ? { ...f, value: r.count } : f);
    // @ts-ignore EdgeRuntime is provided by Supabase
    EdgeRuntime.waitUntil(fetch(`${API}/channels/${msg.channel_id}/messages/${msg.id}`, {
      method: "PATCH", headers: { Authorization: "Bot " + d.bot_token, "User-Agent": UA, "Content-Type": "application/json" },
      body: JSON.stringify({ embeds: msg.embeds, components: msg.components }),
    }).catch(() => {}));
  }
  const said = r.answer === "going" ? `You're **Going** to **${r.title}**. See you there, ${r.name}!`
    : r.answer === "maybe" ? `Marked you as **Maybe** for **${r.title}**.`
    : `Got it, you can't make **${r.title}**.`;
  return reply(`${said} (${r.count})`);
});

// Busters Discord interactions: Discord calls this when someone taps a button on a Busters card
// (Going / Maybe / Can't, or Details), or uses the /giveback command.
// Set as the app's Interactions Endpoint URL in the Discord Developer Portal. Every request is checked against
// the app's public key. The answer is saved in Busters, the tapper gets a private confirmation, and the card's
// Busters count is refreshed.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const API = "https://discord.com/api/v10";
const UA = "DiscordBot (https://busters.app, 1)";
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
  if (i.type === 2 && i.data?.name === "giveback") {                // /giveback: public once an hour, private after that
    const { data: g } = await sb.rpc("discord_giveback", { p_app: i.application_id });
    if (!g?.embed) return reply("Give Back numbers aren't in yet. Try again in a bit.");
    if (!g.public) {
      const when = g.mins != null ? (g.mins < 1 ? "just now" : `${g.mins} min ago`) : "a little while ago";
      return json({ type: 4, data: { content: g.last_url ? `Posted for everyone ${when}: ${g.last_url}` : `Posted for everyone ${when}, just up the channel.`, embeds: [g.embed], components: g.components, flags: 64 } });
    }
    // remember where the public post landed, so repeats within the hour can link to it
    // @ts-ignore EdgeRuntime is provided by Supabase
    EdgeRuntime.waitUntil((async () => {
      await new Promise((r) => setTimeout(r, 1500));
      const m = await fetch(`${API}/webhooks/${i.application_id}/${i.token}/messages/@original`, { headers: { "User-Agent": UA } }).then((r) => r.ok ? r.json() : null).catch(() => null);
      if (m?.id) await sb.rpc("discord_giveback_saved", { p_app: i.application_id, p_url: `https://discord.com/channels/${i.guild_id}/${m.channel_id || i.channel_id}/${m.id}` });
    })().catch(() => {}));
    return json({ type: 4, data: { embeds: [g.embed], components: g.components, allowed_mentions: { parse: [] } } });
  }
  if (i.type !== 3) return reply("Busters doesn't know that one yet.");

  const [kind, eventId, answer] = String(i.data?.custom_id || "").split(":");
  const u = i.member?.user || i.user || {};
  if (kind === "test") {                                              // test card: checks who you are, saves no answer
    const { data: m } = await sb.rpc("discord_match", { p_app: i.application_id, p_user: u.id, p_username: u.username || null, p_display: u.global_name || null, p_nick: i.member?.nick || null });
    const a = { going: "Going", maybe: "Maybe", no: "Can't" }[eventId] || eventId;
    if (m?.status === "ok") return reply(`✅ Test worked. Busters knows you as **${m.name}**, and would have marked you **${a}**. Nothing was saved.`);
    if (m?.status === "unlinked") return reply(`The tap reached Busters, but it couldn't match your Discord account to a member yet. You'll show up under Admin, then Crew, in "Who is this?" for linking. Nothing was saved.`);
    return reply("The tap reached Busters, but something's off with the setup.");
  }
  if (kind === "details") {                                           // private reply with the fuller event info
    const { data: emb } = await sb.rpc("discord_details", { p_app: i.application_id, p_event: eventId });
    if (!emb) return reply("Couldn't find that event anymore.");
    return json({ type: 4, data: { embeds: [emb], flags: 64 } });
  }
  if (kind === "photos") {                                            // "No photos from me" on the photo call
    const { data: r } = await sb.rpc("media_answer_discord", { p_app: i.application_id, p_user: u.id, p_username: u.username || null, p_display: u.global_name || null, p_nick: i.member?.nick || null, p_event: eventId });
    if (r?.status === "ok") return reply(`Thanks, noted: no photos from you for **${r.title}**. Find some later? Post them here anytime.`);
    if (r?.status === "unlinked") return reply(`Thanks! I couldn't match your Discord account to a Busters member yet, so an admin will need to link you before this counts.`);
    return reply("Couldn't find that event anymore.");
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

  // Refresh the card's counts for everyone (in the background, after replying). The card is rebuilt the way
  // Busters drew it (same kind and note), so the Going and Maybe numbers stay in the card's own layout.
  const msg = i.message;
  if (msg?.id && d.bot_token) {
    // @ts-ignore EdgeRuntime is provided by Supabase
    EdgeRuntime.waitUntil((async () => {
      const { data: l } = await sb.from("discord_log").select("id,card_kind,card_extra").eq("message_id", msg.id).maybeSingle();
      let embeds = msg.embeds;
      if (l?.card_kind) {
        const { data: emb } = await sb.rpc("dc_embed", { p_event: eventId, p_kind: l.card_kind, p_extra: l.card_extra });
        if (emb) embeds = [emb];
      } else if (embeds?.[0]) {
        embeds[0].fields = (embeds[0].fields || []).map((f: any) => f.name === "Busters" ? { ...f, value: r.count } : f);
      }
      const res = await fetch(`${API}/channels/${msg.channel_id}/messages/${msg.id}`, {
        method: "PATCH", headers: { Authorization: "Bot " + d.bot_token, "User-Agent": UA, "Content-Type": "application/json" },
        body: JSON.stringify({ embeds, components: msg.components }),
      }).catch(() => null);
      if (res?.ok && l?.id) {
        const { data: ev } = await sb.from("events_full").select("going").eq("id", eventId).maybeSingle();
        if (ev) await sb.from("discord_log").update({ going_shown: ev.going }).eq("id", l.id);
      }
    })().catch(() => {}));
  }
  const said = r.answer === "going" ? `You're **Going** to **${r.title}**. See you there, ${r.name}!`
    : r.answer === "maybe" ? `Marked you as **Maybe** for **${r.title}**.`
    : `Got it, you can't make **${r.title}**.`;
  return reply(`${said} (${r.count})`);
});

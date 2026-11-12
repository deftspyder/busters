// One-time Google Drive connect for event photos. No Busters account needed.
// busters.app/connect.html?t=LINK  ->  here with ?t=LINK  ->  Google's Allow screen  ->  back here with ?code
// -> the database swaps the code for a lasting connection (the Google secret lives there)  ->  connect.html says done.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const PAGE = "https://busters.app/connect.html";

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const go = (to: string) => new Response(null, { status: 302, headers: { Location: to } });
  const back = (flag: string) => go(`${PAGE}?done=${encodeURIComponent(flag)}`);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const link = u.searchParams.get("t");
  if (link) {
    const { data, error } = await sb.rpc("media_google_start", { p_token: link });
    if (error) { console.error(error); return back("error"); }
    return data ? go(data as string) : back("expired");
  }

  if (u.searchParams.get("error")) return back("cancelled");
  const code = u.searchParams.get("code"), state = u.searchParams.get("state");
  if (!code || !state) return back("missing");
  const { data, error } = await sb.rpc("media_google_finish", { p_state: state, p_code: code });
  if (error) { console.error(error); return back("error"); }
  if (data !== "ok") { console.error(data); return back(["expired", "noscope"].includes(data as string) ? (data as string) : "error"); }
  return back("ok");
});

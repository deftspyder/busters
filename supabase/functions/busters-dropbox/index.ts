// Dropbox sends people back here after they allow Busters. We swap the code for a lasting connection
// (done in the database, where the app secret lives) and send them back to the app's Media page.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const APP = "https://deftspyder.github.io/busters/";

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const code = u.searchParams.get("code");
  const state = u.searchParams.get("state");
  const back = (flag: string) => new Response(null, { status: 302, headers: { Location: `${APP}?dropbox=${encodeURIComponent(flag)}#media` } });
  if (u.searchParams.get("error")) return back("cancelled");
  if (!code || !state) return back("missing");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc("media_oauth_finish", { p_state: state, p_code: code });
  if (error) { console.error(error); return back("error"); }
  if (data !== "ok") { console.error(data); return back(data === "unknown" ? "expired" : "error"); }
  return back("connected");
});

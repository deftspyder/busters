// Copies queued event photos and videos into the crew's Google Drive, one folder per event inside
// "Busters Photo Drop". Sources: attachments posted in an event's Discord thread, and files people sent
// through the event's Dropbox upload link (those are deleted from Dropbox once they're safely in Drive).
// Files are streamed through in 8 MB pieces and never stored. Woken by media_kick_copy() in the database.
// Each event's folder is made as soon as its Discord thread exists, so the Drive mirrors the threads.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CHUNK = 8 * 1024 * 1024; // must be a multiple of 256 KB for Drive resumable uploads
const BUDGET_MS = 120_000;      // stop picking up new files after this, the next run carries on
const FOLDER = "application/vnd.google-apps.folder";

type Job = {
  id: string; crew_id: string; event_id: string; source: "discord" | "dropbox"; src_url: string | null; dbx_path: string | null;
  filename: string; size: number | null; tries: number; g_root_id: string | null; g_root_name: string; g_folder_id: string | null; folder_name: string;
};

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

async function gfetch(token: string, url: string, init: RequestInit = {}) {
  return fetch(url, { ...init, headers: { Authorization: `Bearer ${token}`, ...(init.headers || {}) } });
}

// A folder Busters made earlier still there? (drive.file only sees Busters' own files, which is what we want.)
async function folderAlive(token: string, id: string) {
  const r = await gfetch(token, `https://www.googleapis.com/drive/v3/files/${id}?fields=id,trashed`);
  if (!r.ok) return false;
  const j = await r.json();
  return !j.trashed;
}

async function makeFolder(token: string, name: string, parent?: string) {
  const r = await gfetch(token, "https://www.googleapis.com/drive/v3/files?fields=id", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, mimeType: FOLDER, ...(parent ? { parents: [parent] } : {}) }),
  });
  if (!r.ok) throw new Error(`folder ${r.status} ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).id as string;
}

async function openSource(job: Job, secret: string): Promise<{ body: ReadableStream<Uint8Array>; size: number | null; type: string }> {
  if (job.source === "discord") {
    const r = await fetch(job.src_url!);
    if (!r.ok || !r.body) throw new Error(`discord ${r.status}`);
    const len = Number(r.headers.get("content-length")) || job.size;
    return { body: r.body, size: len, type: r.headers.get("content-type") || "application/octet-stream" };
  }
  const t = await rpc<string | null>("media_copy_token", { p_secret: secret, p_crew: job.crew_id, p_which: "dropbox" });
  if (!t) throw new Error("dropbox not connected");
  const r = await fetch("https://content.dropboxapi.com/2/files/download", {
    method: "POST", headers: { Authorization: `Bearer ${t}`, "Dropbox-API-Arg": JSON.stringify({ path: job.dbx_path }) },
  });
  if (!r.ok || !r.body) throw new Error(`dropbox ${r.status} ${r.ok ? "" : (await r.text()).slice(0, 200)}`);
  return { body: r.body, size: job.size, type: "application/octet-stream" };
}

// Drive resumable upload, fed from the source stream piece by piece.
async function upload(token: string, folder: string, name: string, src: { body: ReadableStream<Uint8Array>; size: number | null; type: string }) {
  const init = await gfetch(token, "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": src.type, ...(src.size ? { "X-Upload-Content-Length": String(src.size) } : {}) },
    body: JSON.stringify({ name, parents: [folder] }),
  });
  if (!init.ok) throw new Error(`drive start ${init.status} ${(await init.text()).slice(0, 200)}`);
  const session = init.headers.get("location")!;
  const reader = src.body.getReader();
  // Pieces are gathered in a list and joined once per 8 MB, to keep CPU time low.
  let parts: Uint8Array[] = [], have = 0, sent = 0, done = false;
  while (true) {
    while (!done && have < CHUNK) {
      const { value, done: d } = await reader.read();
      if (d) { done = true; break; }
      parts.push(value); have += value.length;
    }
    const buf = new Uint8Array(have); let o = 0; for (const p of parts) { buf.set(p, o); o += p.length; }
    const last = done && buf.length <= CHUNK;
    const piece = last ? buf : buf.subarray(0, CHUNK);
    const total = last ? String(sent + piece.length) : "*";
    const range = piece.length ? `bytes ${sent}-${sent + piece.length - 1}/${total}` : `bytes */${total}`;
    const r = await fetch(session, { method: "PUT", headers: { "Content-Range": range }, body: piece });
    if (last) {
      if (!r.ok) throw new Error(`drive finish ${r.status} ${(await r.text()).slice(0, 200)}`);
      return (await r.json()).id as string;
    }
    if (r.status !== 308) throw new Error(`drive piece ${r.status} ${(await r.text()).slice(0, 200)}`);
    await r.body?.cancel();
    sent += piece.length;
    const rest = buf.slice(CHUNK); parts = rest.length ? [rest] : []; have = rest.length;
  }
}

async function run(secret: string) {
  const started = Date.now();
  const jobs = await rpc<Job[]>("media_copy_jobs", { p_secret: secret, p_limit: 40 });
  const tokens = new Map<string, string>();
  const roots = new Map<string, string>();
  const folders = new Map<string, string>();
  let ok = 0, failed = 0, made = 0;
  const getToken = async (crew: string) => {
    let token = tokens.get(crew);
    if (!token) {
      token = await rpc<string | null>("media_copy_token", { p_secret: secret, p_crew: crew, p_which: "google" }) || "";
      if (!token) throw new Error("google not connected");
      tokens.set(crew, token);
    }
    return token;
  };
  const getRoot = async (crew: string, token: string, known: string | null, name: string) => {
    let root = roots.get(crew) || known || "";
    if (!roots.has(crew)) {
      if (!root || !(await folderAlive(token, root))) {
        root = await makeFolder(token, name || "Busters Photo Drop");
        await rpc("media_copy_folder", { p_secret: secret, p_crew: crew, p_event: null, p_folder: root });
      }
      roots.set(crew, root);
    }
    return root;
  };
  // Folders for events that have a thread but no folder yet.
  type Need = { crew_id: string; event_id: string; g_root_id: string | null; g_root_name: string; folder_name: string };
  for (const n of await rpc<Need[]>("media_copy_folders_needed", { p_secret: secret }).catch(() => [] as Need[])) {
    try {
      const token = await getToken(n.crew_id);
      const root = await getRoot(n.crew_id, token, n.g_root_id, n.g_root_name);
      const folder = await makeFolder(token, n.folder_name, root);
      await rpc("media_copy_folder", { p_secret: secret, p_crew: n.crew_id, p_event: n.event_id, p_folder: folder });
      folders.set(n.event_id, folder);
      made++;
    } catch (e) { console.error("folder", n.event_id, String(e)); }
  }
  for (const job of jobs) {
    if (Date.now() - started > BUDGET_MS) break;
    try {
      const token = await getToken(job.crew_id);
      const root = await getRoot(job.crew_id, token, job.g_root_id, job.g_root_name);
      let folder = folders.get(job.event_id) || job.g_folder_id || "";
      if (!folders.has(job.event_id)) {
        if (!folder || !(await folderAlive(token, folder))) {
          folder = await makeFolder(token, job.folder_name, root);
          await rpc("media_copy_folder", { p_secret: secret, p_crew: job.crew_id, p_event: job.event_id, p_folder: folder });
        }
        folders.set(job.event_id, folder);
      }
      const src = await openSource(job, secret);
      const id = await upload(token, folder, job.filename, src);
      await rpc("media_copy_result", { p_secret: secret, p_id: job.id, p_dest_id: id, p_err: null });
      ok++;
      if (job.source === "dropbox") {
        // Safely in Drive: clear it out of the relay Dropbox. If this fails the file just stays there.
        const t = await rpc<string | null>("media_copy_token", { p_secret: secret, p_crew: job.crew_id, p_which: "dropbox" });
        if (t) {
          const d = await fetch("https://api.dropboxapi.com/2/files/delete_v2", {
            method: "POST", headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" }, body: JSON.stringify({ path: job.dbx_path }),
          });
          if (!d.ok) console.error("dropbox delete", d.status, (await d.text()).slice(0, 200));
        }
      }
    } catch (e) {
      failed++;
      console.error(job.id, String(e));
      await rpc("media_copy_result", { p_secret: secret, p_id: job.id, p_dest_id: null, p_err: String(e) }).catch(() => {});
    }
  }
  console.log(`made ${made} folders; copied ${ok}, failed ${failed}, of ${jobs.length}`);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("no", { status: 405 });
  let secret = "";
  try { secret = (await req.json()).secret || ""; } catch { /* */ }
  // Check the secret before doing anything in the background.
  try { await rpc("media_copy_jobs", { p_secret: secret, p_limit: 0 }); } catch { return new Response("no", { status: 403 }); }
  // @ts-ignore EdgeRuntime is provided by Supabase
  EdgeRuntime.waitUntil(run(secret).catch((e) => console.error(String(e))));
  return new Response("started", { status: 202 });
});

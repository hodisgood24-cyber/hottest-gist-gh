// Sends a phone notification for the newest story. Deploy with "Verify JWT" turned OFF.
// A schedule in Supabase (see push-schedule.sql) calls it every 15 minutes.
// Secrets needed: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, PUSH_CRON_SECRET (optional: SITE_URL).
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("PUSH_CRON_SECRET")!;
const SITE = (Deno.env.get("SITE_URL") || "https://hottest-gist-gh.hodisgood24.workers.dev").replace(/\/$/, "");
webpush.setVapidDetails(SITE, Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

const H = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" };
const MAX_AGE = 6 * 3600 * 1000; // only announce stories from the last 6 hours

type Post = { id: string; title: string; cat?: string; ts: number; images?: string[]; status?: string };

async function newestPost(): Promise<Post | null> {
  const now = Date.now();
  const list: Post[] = [];
  try {
    const code = await (await fetch(`${SITE}/posts.js?t=${now}`)).text();
    const win: { POSTS?: Post[] } = {};
    new Function("window", code)(win);
    if (Array.isArray(win.POSTS)) list.push(...win.POSTS);
  } catch (_) { /* ignore */ }
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/site_posts?select=id,title,cat,ts,images,status&status=eq.live&order=ts.desc&limit=5`, { headers: H });
    if (r.ok) list.push(...(await r.json()));
  } catch (_) { /* ignore */ }
  const ok = list.filter((p) => p && p.id && p.title && (p.status ?? "live") === "live" && p.ts <= now && now - p.ts < MAX_AGE);
  ok.sort((a, b) => b.ts - a.ts);
  return ok[0] || null;
}

Deno.serve(async (req) => {
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) return new Response("no", { status: 401 });
  const post = await newestPost();
  if (!post) return new Response("nothing new");

  const lr = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.push_last&select=value`, { headers: H });
  const last = (await lr.json())?.[0]?.value?.id;
  if (last === post.id) return new Response("already sent");
  await fetch(`${SUPABASE_URL}/rest/v1/site_settings?on_conflict=key`, {
    method: "POST", headers: { ...H, Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({ key: "push_last", value: { id: post.id, at: Date.now() } }),
  });

  const img = Array.isArray(post.images) && post.images[0] ? (post.images[0].startsWith("http") ? post.images[0] : SITE + "/" + post.images[0].replace(/^\//, "")) : undefined;
  const payload = JSON.stringify({ title: `🔥 ${post.cat || "Hottest Gist"}`, body: post.title, url: `${SITE}/#${encodeURIComponent(post.id)}`, tag: post.id, image: img });

  let sent = 0, gone = 0, from = 0;
  while (true) {
    const sr = await fetch(`${SUPABASE_URL}/rest/v1/push_subs?select=endpoint,p256dh,auth&order=created_at.asc`, { headers: { ...H, Range: `${from}-${from + 499}` } });
    const subs: { endpoint: string; p256dh: string; auth: string }[] = sr.ok ? await sr.json() : [];
    if (!subs.length) break;
    for (let i = 0; i < subs.length; i += 50) {
      const res = await Promise.allSettled(subs.slice(i, i + 50).map((s) =>
        webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 6 * 3600 })));
      for (let j = 0; j < res.length; j++) {
        const r = res[j];
        if (r.status === "fulfilled") sent++;
        else {
          const code = (r.reason as { statusCode?: number })?.statusCode;
          if (code === 404 || code === 410) {
            gone++;
            await fetch(`${SUPABASE_URL}/rest/v1/push_subs?endpoint=eq.${encodeURIComponent(subs[i + j].endpoint)}`, { method: "DELETE", headers: H });
          }
        }
      }
    }
    if (subs.length < 500) break;
    from += 500;
  }
  return new Response(JSON.stringify({ post: post.id, sent, removed: gone }), { headers: { "Content-Type": "application/json" } });
});

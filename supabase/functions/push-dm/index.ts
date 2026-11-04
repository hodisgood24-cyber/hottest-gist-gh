// Sends a phone notification when someone gets a chat message and is not on the site.
// Deploy with "Verify JWT" turned OFF. Called by a database trigger (see setup-push-dm.sql).
// Secrets needed (same ones push-news uses): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY. Optional: SITE_URL.
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE = (Deno.env.get("SITE_URL") || "https://hottest-gist-gh.hodisgood24.workers.dev").replace(/\/$/, "");
webpush.setVapidDetails(SITE, Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);
const H = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" };
const ONLINE_MS = 75 * 1000; // seen this recently = looking at the site, so no alert

async function sendTo(userId: string, payload: string, ttl: number) {
  const sr = await fetch(`${SUPABASE_URL}/rest/v1/push_subs?user_id=eq.${userId}&select=endpoint,p256dh,auth`, { headers: H });
  const subs: { endpoint: string; p256dh: string; auth: string }[] = sr.ok ? await sr.json() : [];
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: ttl, urgency: "high" });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number })?.statusCode;
      if (code === 404 || code === 410) await fetch(`${SUPABASE_URL}/rest/v1/push_subs?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: "DELETE", headers: H });
    }
  }));
  return sent;
}

// Rings the phone of someone who is being called and is not on the site.
async function ringPhone(cid: number) {
  if (!Number.isFinite(cid)) return new Response("bad", { status: 400 });
  const cr = await fetch(`${SUPABASE_URL}/rest/v1/calls?id=eq.${cid}&select=caller,callee,kind,status`, { headers: H });
  const c = (await cr.json())?.[0];
  if (!c || c.status !== "ringing") return new Response("not ringing");
  const pr = await fetch(`${SUPABASE_URL}/rest/v1/user_presence?user_id=eq.${c.callee}&select=seen_at`, { headers: H });
  const seen = pr.ok ? (await pr.json())?.[0]?.seen_at : null;
  if (seen && Date.now() - Date.parse(seen) < ONLINE_MS) return new Response("online");
  const nr = await fetch(`${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${c.caller}&select=name`, { headers: H });
  const name = (await nr.json())?.[0]?.name || "A friend";
  const payload = JSON.stringify({ title: `📞 ${name} is calling`, body: c.kind === "video" ? "Video call. Tap to answer." : "Voice call. Tap to answer.", url: `${SITE}/#calls`, tag: "call", ring: true });
  const sent = await sendTo(c.callee, payload, 30);
  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    if (body?.call !== undefined) return await ringPhone(Number(body.call));
    const { id } = body;
    const mid = Number(id);
    if (!Number.isFinite(mid)) return new Response("bad", { status: 400 });

    // Send each message at most once.
    const lg = await fetch(`${SUPABASE_URL}/rest/v1/push_dm_log?on_conflict=message_id`, {
      method: "POST", headers: { ...H, Prefer: "resolution=ignore-duplicates,return=representation" },
      body: JSON.stringify({ message_id: mid }),
    });
    const logged = lg.ok ? await lg.json() : [];
    if (!logged.length) return new Response("done already");

    const mr = await fetch(`${SUPABASE_URL}/rest/v1/messages?id=eq.${mid}&select=sender,recipient,body,kind`, { headers: H });
    const m = (await mr.json())?.[0];
    if (!m) return new Response("no message");

    const pr = await fetch(`${SUPABASE_URL}/rest/v1/user_presence?user_id=eq.${m.recipient}&select=seen_at`, { headers: H });
    const seen = pr.ok ? (await pr.json())?.[0]?.seen_at : null;
    if (seen && Date.now() - Date.parse(seen) < ONLINE_MS) return new Response("online");

    const sr = await fetch(`${SUPABASE_URL}/rest/v1/push_subs?user_id=eq.${m.recipient}&select=endpoint,p256dh,auth`, { headers: H });
    const subs: { endpoint: string; p256dh: string; auth: string }[] = sr.ok ? await sr.json() : [];
    if (!subs.length) return new Response("no devices");

    const nr = await fetch(`${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${m.sender}&select=name`, { headers: H });
    const name = (await nr.json())?.[0]?.name || "A friend";
    const text = m.kind === "image" ? "📷 Photo" : m.kind === "video" ? "🎬 Video" : m.kind === "voice" ? "🎙️ Voice note"
      : String(m.body || "").slice(0, 100) || "New message";
    const payload = JSON.stringify({ title: `💬 ${name}`, body: text, url: `${SITE}/#chat-${m.sender}`, tag: `dm-${m.sender}`, dm: true });

    let sent = 0;
    await Promise.all(subs.map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600, urgency: "high" });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number })?.statusCode;
        if (code === 404 || code === 410) {
          await fetch(`${SUPABASE_URL}/rest/v1/push_subs?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: "DELETE", headers: H });
        }
      }
    }));
    return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
  } catch (_) {
    return new Response("error", { status: 500 });
  }
});

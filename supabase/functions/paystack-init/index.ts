// Starts a Paystack payment for the gold tick. Deploy with "Verify JWT" turned OFF
// (this function checks the logged-in user itself).
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PAYSTACK_SECRET = Deno.env.get("PAYSTACK_SECRET_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  try {
    // 1. Who is logged in?
    const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (!bearer) return json({ error: "login required" }, 401);
    const ur = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${bearer}` },
    });
    if (!ur.ok) return json({ error: "login required" }, 401);
    const user = await ur.json();
    if (!user?.id || !user?.email) return json({ error: "login required" }, 401);

    let reqBody: any = {};
    try { reqBody = await req.json(); } catch (_) { /* no body */ }
    const gigId = reqBody?.gig_id ? Number(reqBody.gig_id) : 0;
    const songId = !gigId && reqBody?.song_id ? Number(reqBody.song_id) : 0;
    const planName = !gigId && !songId && ["standard", "premium", "star"].includes(String(reqBody?.plan)) ? String(reqBody.plan) : "";
    const settingKey = gigId ? "feature" : songId ? "spotlight" : planName ? "plans" : "verify";

    // 2. Price from the site settings (saved in the Admin page)
    const sr = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.${settingKey}&select=value`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    const rows = await sr.json();
    const v = rows?.[0]?.value || {};
    const amount = planName ? Number(v?.[planName]?.amount) : Number(v.amount);
    if (!v.auto || !(amount > 0)) return json({ error: "payments not open" }, 400);

    // 3a. A featured slot must be for the person's own, visible listing
    if (gigId) {
      const gr = await fetch(`${SUPABASE_URL}/rest/v1/gigs?id=eq.${gigId}&user_id=eq.${user.id}&hidden=eq.false&select=id`, {
        headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
      });
      if (!(await gr.json())?.length) return json({ error: "listing not found" }, 400);
    }

    // 3b. A spotlight must be for the person's own song submission
    if (songId) {
      const sr2 = await fetch(`${SUPABASE_URL}/rest/v1/song_submissions?id=eq.${songId}&user_id=eq.${user.id}&status=neq.rejected&select=id`, {
        headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
      });
      if (!(await sr2.json())?.length) return json({ error: "song not found" }, 400);
    }

    // 3. Make sure the person has a profile
    const pr = await fetch(`${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${user.id}&select=user_id`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    const prof = await pr.json();
    if (!prof?.length) return json({ error: "no profile" }, 400);

    // 4. Ask Paystack for a checkout page
    let origin = "";
    origin = String(reqBody?.origin || "");
    if (!/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(origin)) origin = "";
    const reference = `${gigId ? "feat" : songId ? "song" : planName ? "plan" : "gold"}_${user.id.slice(0, 8)}_${Date.now().toString(36)}`;
    const body: Record<string, unknown> = {
      email: user.email,
      amount: Math.round(amount * 100), // pesewas
      currency: "GHS",
      reference,
      metadata: gigId ? { user_id: user.id, purpose: "feature_gig", gig_id: gigId, days: Number(v.days) || 7 }
        : songId ? { user_id: user.id, purpose: "feature_song", song_id: songId, days: Number(v.days) || 7 }
        : planName ? { user_id: user.id, purpose: "seller_plan", plan: planName, days: Number(v.days) || 30 }
        : { user_id: user.id, purpose: "gold_tick", months: 1 },
    };
    if (origin) body.callback_url = `${origin}/?paid=${gigId ? "gig" : songId ? "song" : planName ? "plan" : "1"}`;
    const pk = await fetch("https://api.paystack.co/transaction/initialize", {
      method: "POST",
      headers: { Authorization: `Bearer ${PAYSTACK_SECRET}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const pj = await pk.json();
    if (!pk.ok || !pj?.status) return json({ error: "paystack", detail: pj?.message || "failed" }, 502);
    return json({ url: pj.data.authorization_url, reference });
  } catch (e) {
    return json({ error: "server", detail: String(e) }, 500);
  }
});

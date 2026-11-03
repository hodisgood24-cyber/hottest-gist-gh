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
    // --- Tips, ads and event tickets (new) ---
    const kind = String(reqBody?.kind || "");
    if (kind === "tip" || kind === "ad" || kind === "ticket") {
      const H = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };
      const setting = async (k: string) => {
        const r = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.${k}&select=value`, { headers: H });
        return (await r.json())?.[0]?.value || {};
      };
      let origin2 = String(reqBody?.origin || "");
      if (!/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(origin2)) origin2 = "";
      let amountGhs = 0;
      let meta: Record<string, unknown> = {};
      let paid = "";
      if (kind === "tip") {
        const tv = await setting("tips");
        const min = Number(tv.min) || 2, max = Number(tv.max) || 500;
        const to = String(reqBody?.to || "");
        amountGhs = Math.round(Number(reqBody?.amount) * 100) / 100;
        if (!tv.auto) return json({ error: "tips are not open" }, 400);
        if (!/^[0-9a-f-]{36}$/i.test(to) || to === user.id) return json({ error: "bad recipient" }, 400);
        if (!(amountGhs >= min && amountGhs <= max)) return json({ error: `tip must be between ${min} and ${max}` }, 400);
        const pr3 = await (await fetch(`${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${to}&select=user_id`, { headers: H })).json();
        if (!pr3?.length) return json({ error: "creator not found" }, 400);
        meta = { user_id: user.id, purpose: "tip", to, message: String(reqBody?.message || "").slice(0, 140) };
        paid = "tip";
      } else if (kind === "ad") {
        const av = await setting("ads");
        const adId = Number(reqBody?.ad_id) || 0;
        const ar = await (await fetch(`${SUPABASE_URL}/rest/v1/ads?id=eq.${adId}&owner=eq.${user.id}&status=eq.draft&select=id,kind`, { headers: H })).json();
        if (!ar?.length) return json({ error: "ad not found" }, 400);
        const pkg = av?.[ar[0].kind] || {};
        amountGhs = Number(pkg.amount);
        if (!av.auto || !(amountGhs > 0)) return json({ error: "payments not open" }, 400);
        meta = { user_id: user.id, purpose: "ad", ad_id: adId, days: Number(pkg.days) || 7 };
        paid = "ad";
      } else {
        const tk = await setting("tickets");
        const evId = Number(reqBody?.event_id) || 0;
        const qty = Math.min(5, Math.max(1, Math.floor(Number(reqBody?.qty) || 1)));
        if (!tk.auto) return json({ error: "ticket sales are not open" }, 400);
        const er = await (await fetch(`${SUPABASE_URL}/rest/v1/ticket_events?id=eq.${evId}&status=eq.live&select=id,price,capacity,sold,starts_at`, { headers: H })).json();
        const ev = er?.[0];
        if (!ev || new Date(ev.starts_at).getTime() < Date.now() - 6 * 3600 * 1000) return json({ error: "event not found" }, 400);
        if (ev.capacity - ev.sold < qty) return json({ error: "sold out" }, 400);
        amountGhs = (ev.price * qty) / 100;
        meta = { user_id: user.id, purpose: "ticket", event_id: evId, qty };
        paid = "ticket";
      }
      const prof2 = await (await fetch(`${SUPABASE_URL}/rest/v1/profiles?user_id=eq.${user.id}&select=user_id`, { headers: H })).json();
      if (!prof2?.length) return json({ error: "no profile" }, 400);
      const reference2 = `${paid}_${user.id.slice(0, 8)}_${Date.now().toString(36)}`;
      const body2: Record<string, unknown> = { email: user.email, amount: Math.round(amountGhs * 100), currency: "GHS", reference: reference2, metadata: meta };
      if (origin2) body2.callback_url = `${origin2}/?paid=${paid}`;
      const pk2 = await fetch("https://api.paystack.co/transaction/initialize", {
        method: "POST",
        headers: { Authorization: `Bearer ${PAYSTACK_SECRET}`, "Content-Type": "application/json" },
        body: JSON.stringify(body2),
      });
      const pj2 = await pk2.json();
      if (!pk2.ok || !pj2?.status) return json({ error: "paystack", detail: pj2?.message || "failed" }, 502);
      return json({ url: pj2.data.authorization_url, reference: reference2 });
    }
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

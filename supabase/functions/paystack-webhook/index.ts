// Paystack calls this after a payment. Deploy with "Verify JWT" turned OFF.
// It checks Paystack's signature, re-checks the payment with Paystack, then switches the gold tick on.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PAYSTACK_SECRET = Deno.env.get("PAYSTACK_SECRET_KEY")!;

async function hmacSha512Hex(key: string, text: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });
  const raw = await req.text();
  const sig = req.headers.get("x-paystack-signature") || "";
  const expected = await hmacSha512Hex(PAYSTACK_SECRET, raw);
  if (!sig || sig !== expected) return new Response("bad signature", { status: 401 });

  let evt: any;
  try { evt = JSON.parse(raw); } catch (_) { return new Response("bad body", { status: 400 }); }
  if (evt?.event !== "charge.success") return new Response("ignored", { status: 200 });

  const ref = String(evt?.data?.reference || "");
  if (!ref) return new Response("no reference", { status: 200 });

  // Re-check the payment directly with Paystack
  const vr = await fetch(`https://api.paystack.co/transaction/verify/${encodeURIComponent(ref)}`, {
    headers: { Authorization: `Bearer ${PAYSTACK_SECRET}` },
  });
  const vj = await vr.json();
  const d = vj?.data;
  if (!vr.ok || d?.status !== "success" || d?.currency !== "GHS") return new Response("not paid", { status: 200 });
  const purpose = d?.metadata?.purpose;
  // --- Tips, ads and event tickets (new) ---
  if (purpose === "tip" || purpose === "ad" || purpose === "ticket") {
    const H2 = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" };
    const getSetting = async (k: string) => (await (await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.${k}&select=value`, { headers: H2 })).json())?.[0]?.value || {};
    const rpc = (fn: string, args: unknown) => fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers: H2, body: JSON.stringify(args) });
    const uid = String(d?.metadata?.user_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(uid)) return new Response("bad user", { status: 200 });
    if (purpose === "tip") {
      const to = String(d.metadata.to || "");
      if (!/^[0-9a-f-]{36}$/i.test(to) || to === uid) return new Response("bad recipient", { status: 200 });
      const tv = await getSetting("tips");
      if (d.amount < Math.round((Number(tv.min) || 2) * 100)) return new Response("amount too low", { status: 200 });
      const r = await rpc("record_tip", { p_from: uid, p_to: to, p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_msg: String(d.metadata.message || "").slice(0, 140), p_cut: Number(tv.cut_pct ?? 10) });
      return new Response(r.ok ? "ok" : "grant failed", { status: r.ok ? 200 : 500 });
    }
    if (purpose === "ad") {
      const av = await getSetting("ads");
      const adId = Number(d.metadata.ad_id) || 0;
      const ar = await (await fetch(`${SUPABASE_URL}/rest/v1/ads?id=eq.${adId}&select=kind`, { headers: H2 })).json();
      const pkg = av?.[ar?.[0]?.kind] || {};
      if (!(Number(pkg.amount) > 0) || d.amount < Math.round(Number(pkg.amount) * 100)) return new Response("amount too low", { status: 200 });
      const r = await rpc("grant_ad", { p_ad: adId, p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_days: Number(pkg.days) || 7 });
      return new Response(r.ok ? "ok" : "grant failed", { status: r.ok ? 200 : 500 });
    }
    const evId = Number(d.metadata.event_id) || 0, qty = Math.min(5, Math.max(1, Number(d.metadata.qty) || 1));
    const er = await (await fetch(`${SUPABASE_URL}/rest/v1/ticket_events?id=eq.${evId}&select=price`, { headers: H2 })).json();
    const price = Number(er?.[0]?.price);
    if (!(price > 0) || d.amount < price * qty) return new Response("amount too low", { status: 200 });
    const tk = await getSetting("tickets");
    const r = await rpc("issue_tickets", { p_event: evId, p_buyer: uid, p_qty: qty, p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_fee_pct: Number(tk.fee_pct ?? 5) });
    return new Response(r.ok ? "ok" : "grant failed", { status: r.ok ? 200 : 500 });
  }
  if (purpose === "feature_gig" && d?.metadata?.gig_id) {
    const fr = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.feature&select=value`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    const fv = (await fr.json())?.[0]?.value || {};
    const fprice = Number(fv.amount);
    if (!(fprice > 0) || d.amount < Math.round(fprice * 100)) return new Response("amount too low", { status: 200 });
    const days = Number(fv.days) || 7;
    const fg = await fetch(`${SUPABASE_URL}/rest/v1/rpc/grant_feature`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_gig: Number(d.metadata.gig_id), p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_days: days }),
    });
    if (!fg.ok) return new Response("grant failed", { status: 500 });
    return new Response("ok", { status: 200 });
  }
  if (purpose === "feature_song" && d?.metadata?.song_id) {
    const sr3 = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.spotlight&select=value`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    const sv = (await sr3.json())?.[0]?.value || {};
    const sprice = Number(sv.amount);
    if (!(sprice > 0) || d.amount < Math.round(sprice * 100)) return new Response("amount too low", { status: 200 });
    const sg = await fetch(`${SUPABASE_URL}/rest/v1/rpc/grant_song_feature`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_song: Number(d.metadata.song_id), p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_days: Number(sv.days) || 7 }),
    });
    if (!sg.ok) return new Response("grant failed", { status: 500 });
    return new Response("ok", { status: 200 });
  }
  if (purpose === "seller_plan" && d?.metadata?.user_id && ["standard", "premium", "star"].includes(String(d?.metadata?.plan))) {
    const pr2 = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.plans&select=value`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    const pv = (await pr2.json())?.[0]?.value || {};
    const plan = String(d.metadata.plan);
    const pprice = Number(pv?.[plan]?.amount);
    if (!(pprice > 0) || d.amount < Math.round(pprice * 100)) return new Response("amount too low", { status: 200 });
    const pg = await fetch(`${SUPABASE_URL}/rest/v1/rpc/grant_plan`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_user: d.metadata.user_id, p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_plan: plan, p_days: Number(pv.days) || 30 }),
    });
    if (!pg.ok) return new Response("grant failed", { status: 500 });
    return new Response("ok", { status: 200 });
  }
  if (purpose !== "gold_tick" || !d?.metadata?.user_id) return new Response("not a gold tick", { status: 200 });

  // The amount must cover the current price
  const sr = await fetch(`${SUPABASE_URL}/rest/v1/site_settings?key=eq.verify&select=value`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  const price = Number((await sr.json())?.[0]?.value?.amount);
  if (!(price > 0) || d.amount < Math.round(price * 100)) return new Response("amount too low", { status: 200 });

  const gr = await fetch(`${SUPABASE_URL}/rest/v1/rpc/grant_verification`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_user: d.metadata.user_id, p_ref: ref, p_amount: d.amount, p_currency: d.currency, p_months: 1 }),
  });
  // A 5xx makes Paystack retry later
  if (!gr.ok) return new Response("grant failed", { status: 500 });
  return new Response("ok", { status: 200 });
});

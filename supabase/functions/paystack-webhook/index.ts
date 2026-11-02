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

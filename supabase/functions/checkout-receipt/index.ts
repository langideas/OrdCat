// OrdCat · Zahlungsbeleg für ordcat.de/thanks.html (Stripe Checkout success_url).
//   GET  /functions/v1/checkout-receipt?session_id=cs_…
//   POST /functions/v1/checkout-receipt   {"session_id":"cs_…"}
// Antwort (nur Belegfelder, keine fremden Daten):
//   bezahlt:        {"ok":true,"state":"complete","receipt":{…}} – E-Mail maskiert (m***@langgo.de)
//   nicht bezahlt:  {"ok":true,"state":"open"|"expired","receipt":{item, items, amount_total, …}} – nur Bestellinhalt,
//                   keine Zahlungsdaten (cancel_url = thanks.html?session_id=…&cancelled=1)
// Fehler: 400 invalid_session · 404 not_found · 429 rate_limited · 500 error
// Die Session-ID ist lang und zufällig; wer sie hat, hat auch die Stripe-Seite gesehen.
//
// Deploy: supabase functions deploy checkout-receipt --no-verify-jwt   (Webseite ohne Login; apikey-Header wird nicht gebraucht)
// Secrets: STRIPE_SECRET_KEY (schon gesetzt). Optional RECEIPT_ORIGINS="https://ordcat.de,https://www.ordcat.de" (CORS).

const ORIGINS = (Deno.env.get("RECEIPT_ORIGINS") ?? "https://ordcat.de,https://www.ordcat.de")
  .split(",").map((s) => s.trim()).filter(Boolean);

function corsFor(req: Request): Record<string, string> {
  const o = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

const SESSION_RE = /^cs_(test_|live_)?[A-Za-z0-9]{10,200}$/;

// Simple in-memory limiter (per isolate): 30 lookups / 10 min per IP, 20 / 10 min per session.
const hits = new Map<string, number[]>();
function limited(key: string, max: number, windowMs: number) {
  const now = Date.now();
  const arr = (hits.get(key) ?? []).filter((t) => now - t < windowMs);
  arr.push(now);
  hits.set(key, arr);
  if (hits.size > 5000) hits.clear();
  return arr.length > max;
}
// Short cache so a page that polls a still-processing payment doesn't hit Stripe every time.
const cache = new Map<string, { at: number; body: unknown; status: number }>();

// ---------- receipt (same block in checkout-receipt/index.ts and stripe-webhook/index.ts; keep them in sync) ----------
// Yearly plans: regular price = monthly × 12 (cents, VAT incl.). Same table as stripe-checkout PLAN_CENTS.
const PLAN_CENTS: Record<string, { month: number; year: number }> = {
  pro: { month: 990, year: 9500 },
  max: { month: 5900, year: 56600 },
};

async function stripeGetOk(path: string): Promise<any> {
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    headers: { Authorization: `Bearer ${Deno.env.get("STRIPE_SECRET_KEY")}` },
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error(j?.error?.message ?? `Stripe ${r.status}`) as Error & { status?: number; code?: string };
    e.status = r.status;
    e.code = j?.error?.code;
    throw e;
  }
  return j;
}

const idOf = (v: any): string | null => (typeof v === "string" ? v : v?.id ?? null);

function maskEmail(e?: string | null): string | null {
  if (!e || !e.includes("@")) return null;
  const [u, d] = [e.slice(0, e.lastIndexOf("@")), e.slice(e.lastIndexOf("@") + 1)];
  return (u.slice(0, 1) || "*") + "***@" + d;
}

// The charge behind an invoice, across Stripe API versions (invoice.charge / payment_intent were moved to invoice_payments).
async function invoiceCharge(inv: any): Promise<any | null> {
  try {
    if (inv?.charge && typeof inv.charge === "object") return inv.charge;
    const ch = idOf(inv?.charge);
    if (ch) return await stripeGetOk(`charges/${ch}`);
    const pi = idOf(inv?.payment_intent);
    if (pi) return (await stripeGetOk(`payment_intents/${pi}?expand[]=latest_charge`)).latest_charge ?? null;
    if (!inv?.id) return null;
    const ps = await stripeGetOk(`invoice_payments?invoice=${encodeURIComponent(inv.id)}&limit=3`);
    const p = (ps.data ?? []).find((x: any) => x.status === "paid") ?? ps.data?.[0];
    const c = idOf(p?.payment?.charge);
    if (c) return await stripeGetOk(`charges/${c}`);
    const pi2 = idOf(p?.payment?.payment_intent);
    if (pi2) return (await stripeGetOk(`payment_intents/${pi2}?expand[]=latest_charge`)).latest_charge ?? null;
  } catch (_) { /* receipt still works without the card line */ }
  return null;
}

function cardOf(charge: any, sub: any): { brand: string; last4: string | null; type: string; wallet: string | null } | null {
  const d = charge?.payment_method_details;
  if (d?.type) {
    const x = d[d.type] ?? {};
    return { type: d.type, brand: String(x.brand ?? x.bank_name ?? d.type), last4: x.last4 ?? null, wallet: x.wallet?.type ?? null };
  }
  const pm = sub?.default_payment_method;
  if (pm && typeof pm === "object" && pm.type) {
    const x = pm[pm.type] ?? {};
    return { type: pm.type, brand: String(x.brand ?? pm.type), last4: x.last4 ?? null, wallet: x.wallet?.type ?? null };
  }
  return null;
}

const subEnd = (sub: any): number | null => sub?.current_period_end ?? sub?.items?.data?.[0]?.current_period_end ?? null;

type Receipt = {
  kind: "checkout" | "renewal";
  id: string;                     // cs_… or in_…
  mode: string;                   // payment | subscription
  paid: boolean;                  // money arrived
  processing: boolean;            // e.g. SEPA still pending
  item: string | null;            // pro | max | x | agent | miao | fish | topup
  lang: "de" | "zh" | "en" | null;
  currency: string;
  amount_total: number;           // cents
  amount_subtotal: number;
  amount_tax: number | null;      // null = Stripe gives no tax split ("inkl. MwSt.")
  amount_discount: number;
  items: { name: string; quantity: number; amount: number; interval: string | null; interval_count: number }[];
  fish: number | null;
  yearly: { monthly: number; regular: number; discount: number; paid: number } | null;
  created: number;                // unix seconds (payment time)
  payment_method: { brand: string; last4: string | null; type: string; wallet: string | null } | null;
  email: string | null;           // full; callers mask it before it leaves the server
  renews_at: number | null;       // next automatic renewal (null when cancelled or one-off)
  ends_at: number | null;         // set when the subscription will end instead of renewing
  receipt_url: string | null;     // Stripe receipt (charge)
  invoice_url: string | null;     // hosted invoice page (subscriptions)
  invoice_pdf: string | null;
  invoice_number: string | null;
  consent_tos: boolean;           // ToS + immediate start box ticked on Stripe's page
  user_id: string | null;
};

function yearlyOf(item: string | null, interval: string | null, paid: number) {
  const p = item ? PLAN_CENTS[item] : undefined;
  if (!p || interval !== "year") return null;
  const regular = p.month * 12;
  return regular > paid ? { monthly: p.month, regular, discount: regular - paid, paid } : null;
}

async function receiptFromSession(sessionId: string): Promise<{ r: Receipt; status: string }> {
  const s = await stripeGetOk(
    `checkout/sessions/${encodeURIComponent(sessionId)}` +
      "?expand[]=line_items&expand[]=payment_intent.latest_charge&expand[]=invoice&expand[]=subscription.default_payment_method",
  );
  const sub = s.subscription && typeof s.subscription === "object" ? s.subscription : null;
  const inv = s.invoice && typeof s.invoice === "object" ? s.invoice : null;
  let charge = s.payment_intent?.latest_charge && typeof s.payment_intent.latest_charge === "object" ? s.payment_intent.latest_charge : null;
  if (!charge && inv) charge = await invoiceCharge(inv);
  const items = (s.line_items?.data ?? []).map((li: any) => ({
    name: String(li.description ?? li.price?.nickname ?? "OrdCat"),
    quantity: Number(li.quantity ?? 1),
    amount: Number(li.amount_total ?? 0),
    interval: li.price?.recurring?.interval ?? null,
    interval_count: Number(li.price?.recurring?.interval_count ?? 1),
  }));
  const item = s.metadata?.item ?? sub?.metadata?.item ?? null;
  const lang0 = String(s.metadata?.lang ?? s.locale ?? "");
  const lang = lang0.startsWith("zh") ? "zh" : lang0.startsWith("de") ? "de" : lang0.startsWith("en") ? "en" : null;
  const total = Number(s.amount_total ?? 0);
  const live = sub && ["active", "trialing", "past_due"].includes(sub.status);
  const r: Receipt = {
    kind: "checkout",
    id: s.id,
    mode: s.mode,
    paid: s.payment_status === "paid" || s.payment_status === "no_payment_required",
    processing: s.status === "complete" && s.payment_status === "unpaid",
    item,
    lang,
    currency: String(s.currency ?? "eur"),
    amount_total: total,
    amount_subtotal: Number(s.amount_subtotal ?? total),
    amount_tax: s.total_details && Number(s.total_details.amount_tax) > 0 ? Number(s.total_details.amount_tax) : null,
    amount_discount: Number(s.total_details?.amount_discount ?? 0),
    items,
    fish: s.metadata?.fish ? Number(s.metadata.fish) : null,
    yearly: yearlyOf(item, items[0]?.interval ?? null, total),
    created: Number(charge?.created ?? inv?.status_transitions?.paid_at ?? s.created),
    payment_method: cardOf(charge, sub),
    email: s.customer_details?.email ?? s.customer_email ?? null,
    renews_at: live && !sub.cancel_at_period_end && !sub.cancel_at ? subEnd(sub) : null,
    ends_at: sub ? (sub.cancel_at ?? (sub.cancel_at_period_end ? subEnd(sub) : null)) : null,
    receipt_url: charge?.receipt_url ?? null,
    invoice_url: inv?.hosted_invoice_url ?? null,
    invoice_pdf: inv?.invoice_pdf ?? null,
    invoice_number: inv?.number ?? null,
    consent_tos: s.consent?.terms_of_service === "accepted",
    user_id: s.metadata?.user_id ?? s.client_reference_id ?? null,
  };
  return { r, status: String(s.status ?? "") };
}

Deno.serve(async (req) => {
  const cors = corsFor(req);
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "GET" && req.method !== "POST") return json({ ok: false, error: "method" }, 405);

  let sid = new URL(req.url).searchParams.get("session_id") ?? "";
  if (!sid && req.method === "POST") {
    try { sid = String((await req.json())?.session_id ?? ""); } catch { /* empty */ }
  }
  sid = sid.trim();
  if (!SESSION_RE.test(sid)) return json({ ok: false, error: "invalid_session" }, 400);

  const ip = (req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for") ?? req.headers.get("x-real-ip") ?? "")
    .split(",")[0].trim();
  if (limited("ip:" + ip, 30, 600e3) || limited("s:" + sid, 20, 600e3)) return json({ ok: false, error: "rate_limited" }, 429);

  const c = cache.get(sid);
  if (c && Date.now() - c.at < ((c.body as any)?.state === "complete" && !(c.body as any)?.receipt?.processing ? 60e3 : 10e3)) return json(c.body, c.status);
  if (cache.size > 2000) cache.clear();

  let out: { body: unknown; status: number };
  try {
    const { r, status } = await receiptFromSession(sid);
    if (status !== "complete") {
      // Not paid (customer went back from Stripe, or the 24 h session expired): order context only, no payment details.
      const state = status === "expired" ? "expired" : "open";
      out = {
        body: { ok: true, state, receipt: {
          kind: r.kind, id: r.id, mode: r.mode, item: r.item, lang: r.lang, currency: r.currency,
          amount_total: r.amount_total, items: r.items, fish: r.fish, yearly: r.yearly,
        } },
        status: 200,
      };
    } else {
      const { user_id: _u, email, ...rest } = r;
      out = { body: { ok: true, state: "complete", receipt: { ...rest, email: maskEmail(email) } }, status: 200 };
    }
  } catch (e) {
    const err = e as Error & { status?: number; code?: string };
    out = err.status === 404 || err.code === "resource_missing"
      ? { body: { ok: false, error: "not_found" }, status: 404 }
      : { body: { ok: false, error: "error" }, status: 500 };
    if (out.status === 500) console.error("checkout-receipt", err.message);
  }
  if (out.status !== 500) cache.set(sid, { at: Date.now(), ...out });
  return json(out.body, out.status);
});

// Local stand-in for api.stripe.com and api.resend.com (tests only). Installs itself as globalThis.fetch.

type Obj = Record<string, any>;
export const stripe = {
  customers: new Map<string, Obj>(),
  subs: new Map<string, Obj>(),
  sessions: new Map<string, Obj>(),          // retrievable sessions (fixtures)
  charges: new Map<string, Obj>(),
  created: [] as Obj[],                      // checkout/sessions create params
  portals: [] as Obj[],                      // billing_portal/sessions create params
  posts: [] as { path: string; params: Obj }[],
  portalFlowsDisabled: false,
  searchDisabled: false,
  mails: [] as Obj[],
  schedules: new Map<string, Obj>(),        // subscription_schedules (plan changes booked for the period end)
  previews: [] as Obj[],                     // invoices/create_preview params
  previewAmount: 4410,                       // amount_due of the next create_preview
  upgradeInvoiceStatus: "paid",              // status of the invoice a plan upgrade creates ("open" = needs 3-D Secure / declined)
  resendStatus: 200,
  resendThrow: false,
  calls: 0,
  reset() {
    this.customers.clear(); this.subs.clear(); this.sessions.clear(); this.charges.clear();
    this.created = []; this.portals = []; this.posts = []; this.mails = [];
    this.schedules.clear(); this.previews = []; this.previewAmount = 4410; this.upgradeInvoiceStatus = "paid";
    this.portalFlowsDisabled = false; this.searchDisabled = false; this.resendStatus = 200; this.resendThrow = false; this.calls = 0;
  },
};

// Prices the tests use (unit_amount = VAT included).
const PRICE_BOOK: Record<string, Obj> = Object.fromEntries(
  [["price_pro_m", 990, "month"], ["price_pro_y", 9500, "year"], ["price_max_m", 5900, "month"], ["price_max_y", 56600, "year"]]
    .map(([id, c, iv]) => [id, { id, object: "price", unit_amount: c, currency: "eur", recurring: { interval: iv, interval_count: 1 } }]),
);

const ok = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const err = (status: number, message: string, code?: string) => ok({ error: { message, code } }, status);
let n = 0;

export function installFetch() {
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = (init?.method ?? "GET").toUpperCase();
    if (url.host === "api.resend.com") {
      if (stripe.resendThrow) throw new TypeError("network down");
      const body = JSON.parse(String(init?.body ?? "{}"));
      stripe.mails.push({ ...body, headers: init?.headers });
      const dump = Deno.env.get("DUMP_MAILS");          // DUMP_MAILS=/tmp/mails.txt to read every mail the tests send
      if (dump) Deno.writeTextFileSync(dump, `\n===== ${body.subject}\n${body.text}\n`, { append: true });
      return stripe.resendStatus === 200 ? ok({ id: "re_" + (++n) }) : err(stripe.resendStatus, "resend says no");
    }
    if (url.host !== "api.stripe.com") throw new Error("unexpected fetch " + url.href);
    stripe.calls++;
    const path = url.pathname.replace(/^\/v1\//, "");
    const params: Obj = {};
    if (method === "POST") for (const [k, v] of new URLSearchParams(String(init?.body ?? ""))) params[k] = v;
    if (method === "POST") stripe.posts.push({ path, params });
    const q = url.searchParams;

    if (path === "customers/search") {
      if (stripe.searchDisabled) return err(400, "search not available");
      const m = /metadata\['user_id'\]:'([^']+)'/.exec(q.get("query") ?? "");
      const hit = [...stripe.customers.values()].filter((c) => c.metadata?.user_id === m?.[1]);
      return ok({ data: hit });
    }
    if (path === "customers" && method === "POST") {
      const c = { id: "cus_" + (++n), email: params.email, metadata: { user_id: params["metadata[user_id]"] } };
      stripe.customers.set(c.id, c);
      return ok(c);
    }
    if (path === "customers" && method === "GET") {
      return ok({ data: [...stripe.customers.values()].filter((c) => c.email === q.get("email")) });
    }
    if (path.startsWith("customers/")) {
      const c = stripe.customers.get(path.split("/")[1]);
      return c ? ok(c) : err(404, "No such customer", "resource_missing");
    }
    if (path === "subscriptions" && method === "GET") {
      const cus = q.get("customer");
      return ok({ data: [...stripe.subs.values()].filter((s) => s.customer === cus) });
    }
    if (path.startsWith("prices/")) {
      const p = PRICE_BOOK[path.split("/")[1]];
      return p ? ok(p) : err(404, "No such price", "resource_missing");
    }
    if (path === "invoices/create_preview" && method === "POST") {
      stripe.previews.push(params);
      const end = Math.floor(Date.now() / 1000) + 365 * 86400;
      return ok({ object: "invoice", amount_due: stripe.previewAmount, total: stripe.previewAmount, currency: "eur",
        lines: { data: [{ amount: -1000, period: { end } }, { amount: stripe.previewAmount + 1000, period: { start: end - 365 * 86400, end } }] } });
    }
    if (path === "subscription_schedules" && method === "POST") {
      const sub = stripe.subs.get(params.from_subscription);
      if (!sub) return err(404, "No such subscription", "resource_missing");
      if (sub.schedule) return err(400, "already has a schedule");
      const it = sub.items?.data?.[0];
      const sc = { id: "sub_sched_" + (++n), object: "subscription_schedule", status: "active", subscription: sub.id, end_behavior: "release",
        phases: [{ start_date: 1790000000, end_date: it?.current_period_end ?? sub.current_period_end, items: [{ price: it?.price?.id, quantity: 1 }] }],
        params: [] as Obj[] };
      stripe.schedules.set(sc.id, sc);
      sub.schedule = sc.id;
      return ok(sc);
    }
    if (path.startsWith("subscription_schedules/")) {
      const [, id, action] = path.split("/");
      const sc = stripe.schedules.get(id);
      if (!sc) return err(404, "No such subscription_schedule", "resource_missing");
      if (method === "POST" && action === "release") {
        sc.status = "released"; sc.released_subscription = sc.subscription;
        const sub = stripe.subs.get(sc.subscription); if (sub) sub.schedule = null;
        sc.subscription = null;
        return ok(sc);
      }
      if (method === "POST") {
        sc.params.push(params);
        const ph: Obj[] = [];
        for (const [k, v] of Object.entries(params)) {
          const m = /^phases\[(\d+)\]\[(.+)\]$/.exec(k);
          if (!m) continue;
          const i = Number(m[1]); ph[i] = ph[i] ?? { items: [{}] };
          if (m[2] === "items][0][price") ph[i].items[0].price = v;
          else if (m[2] === "items][0][quantity") ph[i].items[0].quantity = Number(v);
          else ph[i][m[2]] = /^\d+$/.test(v) ? Number(v) : v;
        }
        if (ph.length) {
          if (ph[1] && !ph[1].start_date) ph[1].start_date = ph[0]?.end_date;
          sc.phases = ph;
        }
        if (params.end_behavior) sc.end_behavior = params.end_behavior;
      }
      return ok(sc);
    }
    if (path.startsWith("subscriptions/")) {
      const s = stripe.subs.get(path.split("/")[1]);
      if (!s) return err(404, "No such subscription", "resource_missing");
      if (method === "POST" && params["items[0][price]"]) {
        // Plan change via the API: with payment_behavior=pending_if_incomplete nothing changes until the invoice is paid.
        const inv = { id: "in_up_" + (++n), object: "invoice", status: stripe.upgradeInvoiceStatus, billing_reason: "subscription_update",
          hosted_invoice_url: "https://invoice.stripe.com/i/up" + n };
        if (inv.status === "paid") {
          const p = PRICE_BOOK[params["items[0][price]"]];
          s.items.data[0].price = { ...p };
          if (params.billing_cycle_anchor === "now") {
            s.items.data[0].current_period_end = Math.floor(Date.now() / 1000) + (p?.recurring?.interval === "year" ? 365 : 30) * 86400;
          }
          s.pending_update = null;
        } else s.pending_update = { subscription_items: [{ price: params["items[0][price]"] }] };
        return ok({ ...s, latest_invoice: inv });
      }
      if (method === "POST") Object.assign(s, Object.fromEntries(Object.entries(params).filter(([k]) => !k.includes("["))),
        params.cancel_at_period_end ? { cancel_at_period_end: params.cancel_at_period_end === "true" } : {});
      return ok(s);
    }
    if (path === "checkout/sessions" && method === "POST") {
      const id = "cs_test_" + "a".repeat(20) + (++n);
      stripe.created.push(params);
      return ok({ id, url: "https://checkout.stripe.com/c/pay/" + id });
    }
    if (path === "checkout/sessions" && method === "GET") {
      // List (customer / status / created[gte] filters), newest first, like Stripe.
      const cus = q.get("customer"), st = q.get("status"), gte = Number(q.get("created[gte]") ?? 0);
      const hit = [...stripe.sessions.values()].filter((x) =>
        (!cus || x.customer === cus) && (!st || x.status === st) && Number(x.created ?? 0) >= gte);
      return ok({ data: hit.sort((x, y) => Number(y.created ?? 0) - Number(x.created ?? 0)) });
    }
    if (path.startsWith("checkout/sessions/")) {
      const s = stripe.sessions.get(decodeURIComponent(path.split("/")[2]));
      return s ? ok(s) : err(404, "No such checkout.session", "resource_missing");
    }
    if (path === "billing_portal/sessions") {
      if (stripe.portalFlowsDisabled && Object.keys(params).some((k) => k.startsWith("flow_data"))) {
        return err(400, "This flow is not enabled in your portal configuration");
      }
      stripe.portals.push(params);
      return ok({ id: "bps_" + (++n), url: "https://billing.stripe.com/p/session/" + n });
    }
    if (path.startsWith("charges/")) {
      const c = stripe.charges.get(path.split("/")[1]);
      return c ? ok(c) : err(404, "No such charge", "resource_missing");
    }
    if (path === "invoice_payments") return ok({ data: [] });
    return err(404, "unhandled " + method + " " + path);
  }) as typeof fetch;
}

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
  resendStatus: 200,
  resendThrow: false,
  calls: 0,
  reset() {
    this.customers.clear(); this.subs.clear(); this.sessions.clear(); this.charges.clear();
    this.created = []; this.portals = []; this.posts = []; this.mails = [];
    this.portalFlowsDisabled = false; this.searchDisabled = false; this.resendStatus = 200; this.resendThrow = false; this.calls = 0;
  },
};

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
    if (path.startsWith("subscriptions/")) {
      const s = stripe.subs.get(path.split("/")[1]);
      if (!s) return err(404, "No such subscription", "resource_missing");
      if (method === "POST") Object.assign(s, Object.fromEntries(Object.entries(params).filter(([k]) => !k.includes("["))),
        params.cancel_at_period_end ? { cancel_at_period_end: params.cancel_at_period_end === "true" } : {});
      return ok(s);
    }
    if (path === "checkout/sessions" && method === "POST") {
      const id = "cs_test_" + "a".repeat(20) + (++n);
      stripe.created.push(params);
      return ok({ id, url: "https://checkout.stripe.com/c/pay/" + id });
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

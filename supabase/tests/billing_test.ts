// Billing Edge Functions against a local fake Stripe / Resend / Supabase. No network, no real keys.
//   cd app/OrdCat/supabase && deno test --import-map tests/import_map.json --allow-env --allow-read tests/
import { assert, assertEquals, assertMatch, assertStringIncludes } from "jsr:@std/assert@1";
import { db } from "./fake_supabase.ts";
import { installFetch, stripe } from "./fake_stripe.ts";

const PRICES = {
  "pro.month": "price_pro_m", "pro.year": "price_pro_y", "max.month": "price_max_m", "max.year": "price_max_y",
  "topup": "price_topup", "x.month": "price_x", "agent.month": "price_agent", "miao.month": "price_miao",
  "x.month.member": "price_x_mem", "agent.month.member": "price_agent_mem", "miao.month.member": "price_miao_mem",
  "fish.5": "price_f5", "fish.10": "price_f10", "fish.30": "price_f30", "fish.100": "price_f100",
};
const env: Record<string, string> = {
  SUPABASE_URL: "https://x.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "service", STRIPE_SECRET_KEY: "sk_test_fake",
  STRIPE_WEBHOOK_SECRET: "whsec_test", STRIPE_PRICES: JSON.stringify(PRICES), SITE_URL: "https://ordcat.de",
  RESEND_API_KEY: "re_test",
};
for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
installFetch();

const handlers: Record<string, (r: Request) => Promise<Response>> = {};
async function load(name: string) {
  let h: any = null;
  // @ts-ignore test stub
  Deno.serve = (fn: any) => { h = fn; return {} as any; };
  await import(`../functions/${name}/index.ts`);
  handlers[name] = h;
}
await load("stripe-checkout");
await load("stripe-webhook");
await load("checkout-receipt");
await load("cancel-contract");

const UID = "11111111-2222-3333-4444-555555555555";
// Mails are English only (v0.2.64): no Chinese characters, no parallel German version.
function assertNoForeign(m: Record<string, any>) {
  for (const part of [m.subject, m.text, m.html]) {
    assert(!/[\u3400-\u9fff\uff00-\uffef]/.test(part), "no CJK text in mail");
    assert(!/Deutsche Fassung|Guten Tag|Widerrufsbelehrung|Sehr geehrte/.test(part), "no German version in mail");
  }
}
function fresh() {
  db.reset(); stripe.reset();
  db.users.set("good", { id: UID, email: "mia@langgo.de" });
  db.rpc.set("ord_plan", () => "free");
}
const call = (body: unknown, token = "good") =>
  handlers["stripe-checkout"](new Request("https://x/functions/v1/stripe-checkout", {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body),
  }));
function sub(id: string, price: string, extra: Record<string, any> = {}) {
  const interval = price.endsWith("_y") ? "year" : "month";
  const s = {
    id, object: "subscription", customer: "cus_1", status: "active", cancel_at_period_end: false, cancel_at: null,
    metadata: { user_id: UID, item: "pro", lang: "zh" },
    items: { data: [{ id: "si_" + id, current_period_end: 1800000000,
      price: { id: price, unit_amount: 990, currency: "eur", recurring: { interval, interval_count: 1 } } }] },
    ...extra,
  };
  stripe.subs.set(id, s);
  return s;
}
function withCustomer() {
  stripe.customers.set("cus_1", { id: "cus_1", email: "mia@langgo.de", metadata: { user_id: UID } });
  db.t("subscriptions").push({ id: "sub_old", user_id: UID, customer_id: "cus_1", skill: "pro" });
}

// ---------------- stripe-checkout ----------------

Deno.test("checkout: needs sign-in", async () => {
  fresh();
  assertEquals((await call({ item: "pro" }, "bad")).status, 401);
});

Deno.test("checkout: new Pro monthly → subscription session with receipt / cancel pages, consent, no managed payments", async () => {
  fresh();
  const r = await call({ item: "pro", interval: "month", locale: "zh" });
  const j = await r.json();
  assertEquals(r.status, 200);
  assertMatch(j.id, /^cs_test_/);
  const p = stripe.created[0];
  assertEquals(p.mode, "subscription");
  assertEquals(p["line_items[0][price]"], "price_pro_m");
  assertEquals(p.success_url, "https://ordcat.de/thanks.html?session_id={CHECKOUT_SESSION_ID}");
  assertEquals(p.cancel_url, "https://ordcat.de/thanks.html?session_id={CHECKOUT_SESSION_ID}&cancelled=1");
  assertEquals(p["consent_collection[terms_of_service]"], "required");
  assertEquals(p["managed_payments[enabled]"], "false");
  assertEquals(p["metadata[lang]"], "zh");
  assertEquals(p["subscription_data[metadata][lang]"], "zh");
  assertEquals(p["custom_text[submit][message]"], undefined);         // monthly: no yearly note
  assert(stripe.customers.size === 1, "customer created once");
});

Deno.test("checkout: yearly plans show original price / discount / paid (no coupon)", async () => {
  fresh();
  await call({ item: "max", interval: "year", locale: "zh" });
  await call({ item: "pro", interval: "year", locale: "en" });
  await call({ item: "pro", interval: "year", locale: "de" });
  const [mx, pe, pd] = stripe.created;
  assertEquals(mx["line_items[0][price]"], "price_max_y");
  assertEquals(mx["custom_text[submit][message]"], "原价 €708/年（€59 × 12 个月），年付优惠 −€142（约 8 折），实付 €566/年。");
  assertEquals(pe["custom_text[submit][message]"], "Regular price €118.80/year (€9.90 × 12 months), yearly discount −€23.80 (about 20% off), you pay €95/year.");
  assertStringIncludes(pd["custom_text[submit][message]"], "Regulär €118,80/Jahr");
  assertStringIncludes(pd["custom_text[submit][message]"], "−€23,80");
  for (const p of [mx, pe, pd]) {
    assert(!Object.keys(p).some((k) => k.startsWith("discounts")), "no coupon");
    assert(p["custom_text[terms_of_service_acceptance][message]"], "consent text kept");
  }
});

Deno.test("checkout: Dried Fish pack and top-up are one-time payments", async () => {
  fresh();
  await call({ item: "fish", pack: "10", locale: "en" });
  await call({ item: "topup" });
  const [f, t] = stripe.created;
  assertEquals(f.mode, "payment");
  assertEquals(f["line_items[0][price]"], "price_f10");
  assertEquals(f["metadata[fish]"], "1050");
  assertEquals(t.mode, "payment");
  assertEquals(t["metadata[credits]"], "1500");
  assertEquals((await call({ item: "fish", pack: "7" })).status, 400);
});

Deno.test("checkout: skill gets member price for Pro / Max, monthly only", async () => {
  fresh();
  db.rpc.set("ord_plan", () => "pro");
  await call({ item: "x", interval: "year" });
  assertEquals(stripe.created[0]["line_items[0][price]"], "price_x_mem");
  db.rpc.set("ord_plan", () => "free");
  await call({ item: "agent" });
  assertEquals(stripe.created[1]["line_items[0][price]"], "price_agent");
});

Deno.test("checkout: same plan and interval → nothing to do; same skill → portal; never a 2nd subscription", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  const j = await (await call({ item: "pro", interval: "month" })).json();
  assertEquals(j.changed, "none");
  assertEquals(j.reason, "current");
  assertEquals(stripe.created.length, 0);
  assertEquals(stripe.portals.length, 0);
  // the same skill twice
  sub("sub_x", "price_x", { metadata: { item: "x", user_id: UID } });
  const k = await (await call({ item: "x" })).json();
  assertEquals(k.reason, "current");
  assertEquals(k.portal, true);
  assertEquals(stripe.created.length, 0);
});
Deno.test("checkout: plan not on Stripe (Dried Fish / old row) → no same or lower plan on top; higher still allowed", async () => {
  fresh();
  db.t("subscriptions").push({ id: "fish:max:u", user_id: UID, skill: "max", status: "active", provider: "fish",
                               ends_at: new Date(Date.now() + 86400000 * 20).toISOString() });
  const r = await call({ item: "pro", interval: "year" });
  assertEquals(r.status, 409);
  assertEquals((await r.json()).reason, "has_plan");
  assertEquals((await call({ item: "max", interval: "month" })).status, 409);
  assertEquals(stripe.created.length, 0);
  assertEquals((await call({ item: "pro", interval: "month", preview: true })).status, 409);   // the preview says so too
  assertEquals(stripe.schedules.size + stripe.previews.length, 0);
  // expired or cancelled rows don't count
  fresh();
  db.t("subscriptions").push({ id: "old", user_id: UID, skill: "max", status: "active", provider: "lemon",
                               ends_at: new Date(Date.now() - 86400000).toISOString() });
  db.t("subscriptions").push({ id: "old2", user_id: UID, skill: "max", status: "cancelled", provider: "lemon" });
  assertEquals((await call({ item: "pro", interval: "month" })).status, 200);
  // fish Pro → Max is an upgrade, still sold
  fresh();
  db.t("subscriptions").push({ id: "fish:pro:u", user_id: UID, skill: "pro", status: "active", provider: "fish",
                               ends_at: new Date(Date.now() + 86400000 * 20).toISOString() });
  assertEquals((await call({ item: "max", interval: "month" })).status, 200);
});

Deno.test("checkout: upgrade Pro → Max = now, new cycle today (anchor now + always_invoice, pending_if_incomplete), no portal", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  const r = await call({ item: "max", interval: "month" });
  assertEquals(r.status, 200);
  const j = await r.json();
  assertEquals(j.changed, "upgraded");
  assertEquals(j.kind, "upgrade");
  const p = stripe.posts.find((x) => x.path === "subscriptions/sub_1")!.params;
  assertEquals(p["items[0][id]"], "si_sub_1");
  assertEquals(p["items[0][price]"], "price_max_m");
  assertEquals(p.billing_cycle_anchor, "now");
  assertEquals(p.proration_behavior, "always_invoice");
  assertEquals(p.payment_behavior, "pending_if_incomplete");
  assertEquals(stripe.subs.get("sub_1")!.items.data[0].price.id, "price_max_m");
  assertEquals(stripe.portals.length, 0, "no portal switch flow any more");
  assertEquals(stripe.created.length, 0);
  // same tier monthly → yearly is an upgrade too
  const k = await (await call({ item: "max", interval: "year" })).json();
  assertEquals(k.changed, "upgraded");
  assertEquals(stripe.posts.filter((x) => x.path === "subscriptions/sub_1").at(-1)!.params["items[0][price]"], "price_max_y");
});

Deno.test("checkout: upgrade needing 3-D Secure / declined → invoice link, plan unchanged until paid", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  stripe.upgradeInvoiceStatus = "open";
  const j = await (await call({ item: "max", interval: "year" })).json();
  assertEquals(j.changed, "pending_payment");
  assertMatch(j.url, /^https:\/\/invoice\.stripe\.com\//);
  assertEquals(stripe.subs.get("sub_1")!.items.data[0].price.id, "price_pro_m", "tier not granted before payment");
  // the webhook keeps saving the old plan (rows follow the subscription's price, not the request)
  await hook("customer.subscription.updated", stripe.subs.get("sub_1"));
  assertEquals(db.t("subscriptions").find((x) => x.id === "sub_1")!.skill, "pro");
});

Deno.test("checkout: preview → today's amount from create_preview, then price per period; downgrade preview = period end", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  const j = await (await call({ item: "max", interval: "year", preview: true })).json();
  assertEquals(j.preview, true);
  assertEquals(j.kind, "upgrade");
  assertEquals(j.today_cents, 4410);
  assertEquals(j.next_cents, 56600);
  assert(j.next_at);
  const pv = stripe.previews[0];
  assertEquals(pv.subscription, "sub_1");
  assertEquals(pv["subscription_details[items][0][price]"], "price_max_y");
  assertEquals(pv["subscription_details[billing_cycle_anchor]"], "now");
  assertEquals(pv["subscription_details[proration_behavior]"], "always_invoice");
  assertEquals(stripe.subs.get("sub_1")!.items.data[0].price.id, "price_pro_m", "preview changes nothing");
  // downgrade preview
  fresh(); withCustomer();
  sub("sub_2", "price_max_y");
  const d = await (await call({ item: "pro", interval: "month", preview: true })).json();
  assertEquals(d.kind, "downgrade");
  assertEquals(d.today_cents, 0);
  assertEquals(d.next_cents, 990);
  assertEquals(d.effective_at, new Date(1800000000 * 1000).toISOString());
  assertEquals(stripe.schedules.size, 0);
  // no Stripe plan yet → normal checkout
  fresh();
  const c = await (await call({ item: "pro", interval: "month", preview: true })).json();
  assertEquals(c.kind, "checkout");
  assertEquals(stripe.created.length, 0);
});

Deno.test("checkout: downgrade Max yearly → Pro monthly = schedule (phase 1 current price to period end, phase 2 new), mail once, undo", async () => {
  fresh(); withCustomer();
  db.t("subscriptions").push({ id: "sub_1", user_id: UID, customer_id: "cus_1", skill: "max" });
  sub("sub_1", "price_max_y");
  const j = await (await call({ item: "pro", interval: "month" })).json();
  assertEquals(j.changed, "scheduled");
  assertEquals(j.effective_at, new Date(1800000000 * 1000).toISOString());
  const sc = stripe.schedules.get(j.schedule)!;
  assertEquals(sc.end_behavior, "release");
  assertEquals(sc.phases[0].items[0].price, "price_max_y");
  assertEquals(sc.phases[0].end_date, 1800000000);
  assertEquals(sc.phases[0].proration_behavior, "none");
  assertEquals(sc.phases[1].items[0].price, "price_pro_m");
  assertEquals(sc.phases[1].iterations, 1);
  assertEquals(stripe.subs.get("sub_1")!.items.data[0].price.id, "price_max_y", "keeps Max until then");
  assert(!stripe.posts.some((x) => x.path === "subscriptions/sub_1"), "no immediate change, no refund");
  const row = db.t("subscriptions").find((x) => x.id === "sub_1")!;
  assertEquals(row.pending_plan, "pro");
  assertEquals(row.pending_interval, "month");
  assertEquals(stripe.mails.length, 1);
  assertEquals(stripe.mails[0].subject, "Plan change scheduled · OrdCat");
  assertStringIncludes(stripe.mails[0].text, "Undo");
  assertNoForeign(stripe.mails[0]);
  assertEquals(db.t("receipt_emails")[0].id, "sched:" + j.schedule);
  assertEquals(db.t("receipt_emails")[0].kind, "scheduled");
  // a 2nd downgrade replaces the first (one pending change at a time)
  const k = await (await call({ item: "pro", interval: "year" })).json();
  assertEquals(k.changed, "scheduled");
  assertEquals(sc.status, "released");
  assertEquals(stripe.subs.get("sub_1")!.schedule, k.schedule);
  // undo
  const u = await (await call({ cancel_change: true })).json();
  assertEquals(u.changed, "cancelled_change");
  assertEquals(stripe.schedules.get(k.schedule)!.status, "released");
  assertEquals(stripe.subs.get("sub_1")!.schedule, null);
  assertEquals(db.t("subscriptions").find((x) => x.id === "sub_1")!.pending_plan, null);
  assertEquals((await (await call({ cancel_change: true })).json()).changed, "none");
});

Deno.test("checkout: an upgrade releases a booked downgrade first", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_max_y");
  const j = await (await call({ item: "pro", interval: "year" })).json();
  assertEquals(j.changed, "scheduled");
  const up = await (await call({ item: "max", interval: "year" })).json();
  assertEquals(up.changed, "none");                       // already Max yearly: the booked change stays until undone
  stripe.subs.get("sub_1")!.items.data[0].price = { id: "price_max_m", unit_amount: 5900, currency: "eur", recurring: { interval: "month", interval_count: 1 } };
  const u2 = await (await call({ item: "max", interval: "year" })).json();
  assertEquals(u2.changed, "upgraded");
  assertEquals(stripe.schedules.get(j.schedule)!.status, "released");
});

Deno.test("webhook: subscription_schedule events keep pending_* in sync", async () => {
  fresh();
  sub("sub_1", "price_max_y", { metadata: { user_id: UID, item: "max" } });
  stripe.schedules.set("sub_sched_9", { id: "sub_sched_9", status: "active", subscription: "sub_1",
    phases: [{ start_date: 1790000000, end_date: 1800000000, items: [{ price: "price_max_y" }] },
             { start_date: 1800000000, items: [{ price: "price_pro_m" }] }] });
  stripe.subs.get("sub_1")!.schedule = "sub_sched_9";
  await hook("subscription_schedule.created", stripe.schedules.get("sub_sched_9"));
  let row = db.t("subscriptions")[0];
  assertEquals(row.skill, "max");
  assertEquals(row.pending_plan, "pro");
  assertEquals(row.pending_interval, "month");
  assertEquals(row.pending_at, new Date(1800000000 * 1000).toISOString());
  stripe.subs.get("sub_1")!.schedule = null;
  await hook("subscription_schedule.released", { id: "sub_sched_9", subscription: null, released_subscription: "sub_1" });
  row = db.t("subscriptions")[0];
  assertEquals(row.pending_plan, null);
});
Deno.test("checkout: past_due → update-payment flow; portal flows", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m", { status: "past_due" });
  const j = await (await call({ item: "max", interval: "month" })).json();
  assertEquals(j.reason, "pay_first");
  assertEquals(stripe.portals[0]["flow_data[type]"], "payment_method_update");
  await call({ portal: true, flow: "cancel", item: "pro" });
  assertEquals(stripe.portals[1]["flow_data[type]"], "subscription_cancel");
  assertEquals(stripe.portals[1]["flow_data[subscription_cancel][subscription]"], "sub_1");
  await call({ portal: true });
  assertEquals(stripe.portals[2]["flow_data[type]"], undefined);
});

Deno.test("checkout: Dried Fish buyer keeps one Stripe customer (search by user id)", async () => {
  fresh();
  stripe.customers.set("cus_9", { id: "cus_9", email: "mia@langgo.de", metadata: { user_id: UID } });
  await call({ item: "fish", pack: "5" });
  assertEquals(stripe.created[0].customer, "cus_9");
  assertEquals(stripe.customers.size, 1);
});

// ---------------- stripe-webhook ----------------

async function sign(raw: string) {
  const t = Math.floor(Date.now() / 1000);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("whsec_test"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${raw}`));
  return `t=${t},v1=${[...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}
async function hook(type: string, object: any, previous_attributes?: any) {
  const raw = JSON.stringify({ id: "evt_" + crypto.randomUUID(), type, created: 1790000000, data: { object, previous_attributes } });
  return handlers["stripe-webhook"](new Request("https://x/functions/v1/stripe-webhook", {
    method: "POST", headers: { "Stripe-Signature": await sign(raw) }, body: raw,
  }));
}
function paidSession(id: string, over: Record<string, any> = {}) {
  const s: any = {
    id, object: "checkout.session", status: "complete", payment_status: "paid", mode: "subscription", currency: "eur",
    amount_total: 9500, amount_subtotal: 9500, total_details: { amount_tax: 1517, amount_discount: 0 }, created: 1790000000,
    customer: "cus_1", client_reference_id: UID, locale: "zh", subscription: "sub_1",
    customer_details: { email: "mia@langgo.de", address: { country: "DE" } },
    consent: { terms_of_service: "accepted" },
    metadata: { user_id: UID, item: "pro", lang: "zh" },
    line_items: { data: [{ description: "OrdCat Pro", quantity: 1, amount_total: 9500, price: { recurring: { interval: "year", interval_count: 1 } } }] },
    payment_intent: null,
    invoice: { id: "in_first", hosted_invoice_url: "https://invoice.stripe.com/i/1", invoice_pdf: "https://pay.stripe.com/invoice/1/pdf", number: "ORD-0001", charge: "ch_1" },
    ...over,
  };
  stripe.sessions.set(id, s);
  stripe.charges.set("ch_1", { id: "ch_1", created: 1790000100, receipt_url: "https://pay.stripe.com/receipts/1",
    payment_method_details: { type: "card", card: { brand: "visa", last4: "4242" } } });
  return s;
}

Deno.test("webhook: bad signature → 400", async () => {
  fresh();
  const r = await handlers["stripe-webhook"](new Request("https://x", { method: "POST", headers: { "Stripe-Signature": "t=1,v1=00" }, body: "{}" }));
  assertEquals(r.status, 400);
});

Deno.test("webhook: new subscription → row saved by price, confirmation mail once even on Stripe retries", async () => {
  fresh();
  sub("sub_1", "price_pro_y");
  const s = paidSession("cs_test_paid000000001");
  for (let i = 0; i < 3; i++) assertEquals((await hook("checkout.session.completed", s)).status, 200);
  const row = db.t("subscriptions").find((r) => r.id === "sub_1")!;
  assertEquals(row.skill, "pro");
  assertEquals(row.billing_interval, "year");
  assertEquals(row.status, "active");
  assert(db.rpcCalls.some((c) => c.name === "ord_wallet_sync"));
  assertEquals(stripe.mails.length, 1, "exactly one mail");
  const m = stripe.mails[0];
  assertEquals(m.to, ["mia@langgo.de"]);
  assertEquals(m.subject, "Order confirmation · OrdCat");    // English only, even for lang=zh buyers
  assertNoForeign(m);
  assertStringIncludes(m.text, "Axun Conor");
  assertStringIncludes(m.text, "Hedemannstraße 74");
  assertStringIncludes(m.text, "Regular price");               // yearly saving line
  assertStringIncludes(m.text, "Model withdrawal form");        // withdrawal information on a durable medium
  assertStringIncludes(m.text, "§ 357a(2) BGB");                // service consent (not digital content)
  assertStringIncludes(m.text, "widerruf.html#widerrufen");
  assertStringIncludes(m.html, "thanks.html?session_id=cs_test_paid000000001");
  assertStringIncludes(m.text, "kuendigen.html");
  assertStringIncludes(m.text, "Visa •••• 4242");
  assertStringIncludes(m.text, "https://pay.stripe.com/receipts/1");
  assertEquals(db.t("receipt_emails")[0].status, "sent");
});

Deno.test("webhook: Dried Fish pack → fish_topup + digital-content consent in mail", async () => {
  fresh();
  const s = paidSession("cs_test_fish000000001", {
    mode: "payment", subscription: null, invoice: null, amount_total: 1000, total_details: { amount_tax: 0 },
    metadata: { user_id: UID, item: "fish", fish: "1050", pack: "10", cents: "1000", lang: "en" },
    line_items: { data: [{ description: "OrdCat Dried Fish", quantity: 1, amount_total: 1000, price: {} }] },
    payment_intent: { latest_charge: { id: "ch_2", created: 1790000200, receipt_url: "https://pay.stripe.com/receipts/2",
      payment_method_details: { type: "card", card: { brand: "mastercard", last4: "4444" } } } },
  });
  assertEquals((await hook("checkout.session.completed", s)).status, 200);
  const top = db.rpcCalls.find((c) => c.name === "fish_topup")!;
  assertEquals(top.args.p_fish, 1050);
  const m = stripe.mails[0];
  assertEquals(m.subject, "Order confirmation · OrdCat");
  assertStringIncludes(m.text, "1050 Dried Fish");
  assertStringIncludes(m.text, "§ 356(6) BGB");
  assertStringIncludes(m.text, "VAT included");
  assertNoForeign(m);
});

Deno.test("webhook: unpaid SEPA session → no mail yet; async success → one mail", async () => {
  fresh();
  const s = paidSession("cs_test_sepa000000001", { mode: "payment", subscription: null, invoice: null,
    payment_status: "unpaid", metadata: { user_id: UID, item: "fish", fish: "500", pack: "5", cents: "500", lang: "de" } });
  await hook("checkout.session.completed", s);
  assertEquals(stripe.mails.length, 0);
  s.payment_status = "paid";
  await hook("checkout.session.async_payment_succeeded", s);
  await hook("checkout.session.async_payment_succeeded", s);
  assertEquals(stripe.mails.length, 1);
  assertEquals(stripe.mails[0].subject, "Order confirmation · OrdCat");   // lang=de buyer: English too
  assertNoForeign(stripe.mails[0]);
});

Deno.test("webhook: mail failure (Resend 500 or network) never breaks the webhook", async () => {
  fresh();
  sub("sub_1", "price_pro_m");
  stripe.resendStatus = 500;
  assertEquals((await hook("checkout.session.completed", paidSession("cs_test_fail000000001"))).status, 200);
  assertEquals(db.t("receipt_emails")[0].status, "failed");
  stripe.resendStatus = 200; stripe.resendThrow = true;
  assertEquals((await hook("checkout.session.completed", paidSession("cs_test_fail000000002"))).status, 200);
  assertEquals(db.t("receipt_emails")[1].status, "failed");
  // receipt_emails table missing (receipts.sql not run): membership still saved, no mail, 200
  stripe.resendThrow = false; db.missingTable.add("receipt_emails");
  assertEquals((await hook("checkout.session.completed", paidSession("cs_test_fail000000003"))).status, 200);
  assertEquals(stripe.mails.length, 1);   // only the Resend-500 attempt reached Resend
});

Deno.test("webhook: new columns missing → saves the old columns, membership still works", async () => {
  fresh();
  db.missingColumns.set("subscriptions", ["billing_interval", "cancel_at_period_end", "amount_cents", "currency"]);
  const r = await hook("customer.subscription.updated", sub("sub_1", "price_max_m"));
  assertEquals(r.status, 200);
  assertEquals(db.t("subscriptions")[0].skill, "max");
  assertEquals(db.t("subscriptions")[0].billing_interval, undefined);
});

Deno.test("webhook: DB error keeps Stripe retrying (500)", async () => {
  fresh();
  db.failUpsert.set("subscriptions", "connection lost");
  assertEquals((await hook("customer.subscription.updated", sub("sub_1", "price_pro_m"))).status, 500);
});

Deno.test("webhook: plan switch in the portal (metadata still says pro) → max by price", async () => {
  fresh();
  const s = sub("sub_1", "price_max_y");                  // metadata.item = "pro"
  await hook("customer.subscription.updated", s, { items: {} });
  const row = db.t("subscriptions")[0];
  assertEquals(row.skill, "max");
  assertEquals(row.billing_interval, "year");
  assertEquals(stripe.mails.length, 0);
});

Deno.test("webhook: renewal → credits + one renewal receipt; first invoice → nothing extra", async () => {
  fresh();
  sub("sub_1", "price_pro_m");
  stripe.customers.set("cus_1", { id: "cus_1", email: "mia@langgo.de" });
  const inv = { id: "in_renew1", object: "invoice", subscription: "sub_1", billing_reason: "subscription_cycle", status: "paid",
    amount_paid: 990, total: 990, currency: "eur", customer_email: "mia@langgo.de", number: "ORD-0002", charge: "ch_1",
    hosted_invoice_url: "https://invoice.stripe.com/i/2", status_transitions: { paid_at: 1792000000 }, lines: { data: [] } };
  stripe.charges.set("ch_1", { id: "ch_1", receipt_url: "https://pay.stripe.com/receipts/9", payment_method_details: { type: "card", card: { brand: "visa", last4: "4242" } } });
  await hook("invoice.paid", { ...inv, id: "in_first", billing_reason: "subscription_create" });
  assertEquals(stripe.mails.length, 0);
  await hook("invoice.paid", inv);
  await hook("invoice.paid", inv);
  assertEquals(db.rpcCalls.filter((c) => c.name === "credit_new_period").length, 2);   // credit_new_period is itself idempotent per period in SQL
  assertEquals(stripe.mails.length, 1);
  assertEquals(stripe.mails[0].subject, "Your OrdCat Pro renewal receipt");
  assertNoForeign(stripe.mails[0]);
  assertStringIncludes(stripe.mails[0].text, "ORD-0002");
  assert(!stripe.mails[0].text.includes("Model withdrawal form"), "no withdrawal form on renewals");
});

Deno.test("webhook: switch invoice paid (Pro → Max, Max monthly → yearly) → one 'Plan upgraded' mail each", async () => {
  fresh();
  sub("sub_1", "price_max_m", { metadata: { user_id: UID, item: "pro", lang: "zh" } });   // price already switched to Max
  stripe.customers.set("cus_1", { id: "cus_1", email: "mia@langgo.de" });
  stripe.charges.set("ch_u", { id: "ch_u", receipt_url: "https://pay.stripe.com/receipts/u1", payment_method_details: { type: "card", card: { brand: "visa", last4: "4242" } } });
  const inv = { id: "in_up1", object: "invoice", subscription: "sub_1", billing_reason: "subscription_update", status: "paid",
    amount_paid: 3510, total: 3510, tax: 560, currency: "eur", customer_email: "mia@langgo.de", number: "ORD-0050", charge: "ch_u",
    hosted_invoice_url: "https://invoice.stripe.com/i/u1", invoice_pdf: "https://pay.stripe.com/invoice/u1/pdf", status_transitions: { paid_at: 1792000000 },
    lines: { data: [
      { amount: -660, description: "Unused time on OrdCat Pro", price: { id: "price_pro_m", recurring: { interval: "month" } } },
      { amount: 4170, description: "Remaining time on OrdCat Max", price: { id: "price_max_m", unit_amount: 5900, recurring: { interval: "month" } } },
    ] } };
  for (let i = 0; i < 3; i++) assertEquals((await hook("invoice.paid", inv)).status, 200);
  assertEquals(stripe.mails.length, 1, "one mail even on retries");
  const m = stripe.mails[0];
  assertEquals(m.subject, "Plan upgraded · OrdCat");
  assertStringIncludes(m.text, "You're on OrdCat Max now");
  assertStringIncludes(m.text, "new billing cycle starts today");
  assertNoForeign(m);
  assertStringIncludes(m.text, "New plan: OrdCat Max (was OrdCat Pro (monthly))");
  assertStringIncludes(m.text, "Charged now: €35.10 (incl. €5.60 VAT");
  assertStringIncludes(m.text, "Next renewal:");
  assertStringIncludes(m.text, "€59.00 incl. VAT");                // price on the invoice's charge line
  assertStringIncludes(m.text, "Visa •••• 4242");
  assertStringIncludes(m.text, "https://pay.stripe.com/invoice/u1/pdf");
  assertStringIncludes(m.text, "kuendigen.html");
  const row = db.t("receipt_emails")[0];
  assertEquals(row.id, "upgrade:in_up1");
  assertEquals(row.kind, "upgrade");
  assertEquals(row.status, "sent");
  assertEquals(db.rpcCalls.filter((c) => c.name === "credit_new_period").length, 0, "a plan change is not a renewal");
  // same tier, other interval
  stripe.subs.get("sub_1")!.items.data[0].price = { id: "price_max_y", unit_amount: 56600, currency: "eur", recurring: { interval: "year", interval_count: 1 } };
  await hook("invoice.paid", { ...inv, id: "in_up2", number: "ORD-0051", lines: { data: [
    { amount: -4170, price: { id: "price_max_m", recurring: { interval: "month" } } },
    { amount: 56600, price: { id: "price_max_y", unit_amount: 56600, recurring: { interval: "year" } } }] } });
  assertEquals(stripe.mails.length, 2);
  assertEquals(stripe.mails[1].subject, "Plan upgraded · OrdCat");
  assertStringIncludes(stripe.mails[1].text, "You're on yearly billing now");
  assertStringIncludes(stripe.mails[1].text, "New plan: OrdCat Max (was OrdCat Max (monthly))");
  assertStringIncludes(stripe.mails[1].text, "Regular price €708.00/year");
});

Deno.test("webhook: payment failed → past_due saved, one notice per invoice", async () => {
  fresh();
  sub("sub_1", "price_pro_m", { status: "past_due" });
  const inv = { id: "in_fail1", object: "invoice", subscription: "sub_1", billing_reason: "subscription_cycle", amount_due: 990,
    currency: "eur", customer_email: "mia@langgo.de", hosted_invoice_url: "https://invoice.stripe.com/i/3" };
  assertEquals((await hook("invoice.payment_failed", inv)).status, 200);
  await hook("invoice.payment_failed", inv);              // Stripe's retry fails again
  assertEquals(db.t("subscriptions")[0].status, "past_due");
  assertEquals(stripe.mails.length, 1);
  assertEquals(stripe.mails[0].subject, "Payment failed · OrdCat");
  assertNoForeign(stripe.mails[0]);
  assertStringIncludes(stripe.mails[0].text, "https://invoice.stripe.com/i/3");
  // first invoice failing (customer still on Stripe's page) → no mail
  await hook("invoice.payment_failed", { ...inv, id: "in_fail2", billing_reason: "subscription_create" });
  assertEquals(stripe.mails.length, 1);
});

Deno.test("webhook: cancelled in the portal → ends_at + one cancellation mail; via kuendigen form → no 2nd mail", async () => {
  fresh();
  stripe.customers.set("cus_1", { id: "cus_1", email: "mia@langgo.de" });
  const s = sub("sub_1", "price_pro_m", { cancel_at_period_end: true, canceled_at: 1790000000 });
  await hook("customer.subscription.updated", s, { cancel_at_period_end: false });
  await hook("customer.subscription.updated", s, { cancel_at_period_end: false });   // retry
  await hook("customer.subscription.updated", s, { metadata: {} });                 // unrelated later update
  const row = db.t("subscriptions")[0];
  assertEquals(row.cancel_at_period_end, true);
  assertEquals(row.renews_at, null);
  assert(row.ends_at);
  assertEquals(stripe.mails.length, 1);
  assertEquals(stripe.mails[0].subject, "Subscription cancelled · OrdCat");
  assertStringIncludes(stripe.mails[0].text, "Your cancellation is confirmed");
  assertNoForeign(stripe.mails[0]);
  const t = sub("sub_2", "price_max_m", { cancel_at_period_end: true, metadata: { user_id: UID, cancel_request: "abc" } });
  await hook("customer.subscription.updated", t, { cancel_at_period_end: false });
  assertEquals(stripe.mails.length, 1);
});

Deno.test("webhook: deleted → canceled (back to Free)", async () => {
  fresh();
  const s = sub("sub_1", "price_pro_m", { status: "canceled", ended_at: 1790000000 });
  assertEquals((await hook("customer.subscription.deleted", s)).status, 200);
  const row = db.t("subscriptions")[0];
  assertEquals(row.status, "canceled");
  assertEquals(row.ends_at, new Date(1790000000 * 1000).toISOString());
});

// ---------------- checkout-receipt ----------------

const rc = (q: string, origin = "https://ordcat.de", ip = "1.2.3.4") =>
  handlers["checkout-receipt"](new Request("https://x/functions/v1/checkout-receipt" + q, { headers: { Origin: origin, "x-forwarded-for": ip } }));

Deno.test("receipt: paid session → receipt fields only, email masked, CORS for ordcat.de", async () => {
  fresh();
  sub("sub_1", "price_pro_y");
  const s = paidSession("cs_test_rcpt000000001");
  s.subscription = stripe.subs.get("sub_1");
  const r = await rc("?session_id=cs_test_rcpt000000001");
  assertEquals(r.status, 200);
  assertEquals(r.headers.get("Access-Control-Allow-Origin"), "https://ordcat.de");
  const j = await r.json();
  assertEquals(j.state, "complete");
  assertEquals(j.receipt.email, "m***@langgo.de");
  assertEquals(j.receipt.user_id, undefined);
  assertEquals(j.receipt.amount_tax, 1517);
  assertEquals(j.receipt.payment_method.last4, "4242");
  assertEquals(j.receipt.yearly, { monthly: 990, regular: 11880, discount: 2380, paid: 9500 });
  assertEquals(j.receipt.renews_at, 1800000000);
  assertEquals(j.receipt.receipt_url, "https://pay.stripe.com/receipts/1");
  assertEquals(j.receipt.invoice_pdf, "https://pay.stripe.com/invoice/1/pdf");
});

Deno.test("receipt: abandoned checkout → open, no payment details", async () => {
  fresh();
  paidSession("cs_test_open000000001", { status: "open", payment_status: "unpaid" });
  const j = await (await rc("?session_id=cs_test_open000000001", "https://evil.example", "5.5.5.5")).json();
  assertEquals(j.state, "open");
  assertEquals(j.receipt.email, undefined);
  assertEquals(j.receipt.payment_method, undefined);
  assertEquals(j.receipt.receipt_url, undefined);
  assertEquals(j.receipt.items[0].name, "OrdCat Pro");
});

Deno.test("receipt: invalid / unknown / CORS / rate limit", async () => {
  fresh();
  assertEquals((await rc("?session_id=hello", "https://ordcat.de", "6.6.6.6")).status, 400);
  assertEquals((await rc("?session_id={CHECKOUT_SESSION_ID}", "https://ordcat.de", "6.6.6.6")).status, 400);
  const nf = await rc("?session_id=cs_test_nothere00000001", "https://evil.example", "6.6.6.6");
  assertEquals(nf.status, 404);
  assertEquals(nf.headers.get("Access-Control-Allow-Origin"), "https://ordcat.de");   // not echoed for other sites
  let last = 0;
  for (let i = 0; i < 40; i++) last = (await rc("?session_id=cs_test_nothere00000002", "https://ordcat.de", "7.7.7.7")).status;
  assertEquals(last, 429);
});

// ---------------- cancel-contract ----------------

Deno.test("cancel-contract: Kündigung sets cancel_at_period_end and mails a confirmation", async () => {
  fresh();
  db.rpc.set("cancel_recent", () => ({ ip: 0, email: 0 }));
  db.rpc.set("cancel_find_user", () => UID);
  stripe.customers.set("cus_1", { id: "cus_1", email: "mia@langgo.de" });
  sub("sub_1", "price_pro_m");
  const r = await handlers["cancel-contract"](new Request("https://x", {
    method: "POST", headers: { "Content-Type": "application/json", "x-forwarded-for": "9.9.9.9" },
    body: JSON.stringify({ action: "cancel", kind: "ordinary", email: "mia@langgo.de", contract: "all", lang: "zh" }),
  }));
  const j = await r.json();
  assertEquals(j.ok, true);
  assertEquals(stripe.subs.get("sub_1")!.cancel_at_period_end, true);
  assert(stripe.posts.some((p) => p.path === "subscriptions/sub_1" && p.params["metadata[cancel_request]"]), "marks the form request");
  assertEquals(stripe.mails.length, 1);
  assertEquals(stripe.mails[0].subject, "Cancellation received · OrdCat");   // lang=zh form: mail in English
  assertNoForeign(stripe.mails[0]);
  assertEquals(db.t("cancel_requests")[0].status, "done");
  const bad = await handlers["cancel-contract"](new Request("https://x", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "cancel", email: "nope", contract: "pro" }),
  }));
  assertEquals(bad.status, 400);
});

// ---------------- custom Dried Fish amount (v0.2.64+) ----------------
import { customEur, fishForEur } from "../functions/_shared/fish.ts";

Deno.test("fish: tier math (1 € = 100, ≥ €10 +5 %, ≥ €30 +10 %, ≥ €100 +15 %, floor) and validation", () => {
  const want: [number, number][] = [[5, 500], [9, 900], [10, 1050], [29, 3045], [30, 3300], [99, 10890], [100, 11500], [500, 57500], [10000, 1150000]];
  for (const [eur, fish] of want) assertEquals(fishForEur(eur), fish, `€${eur}`);
  for (const bad of [4, 10001, 7.5, "7.5", "abc", "", null, -10, 0]) assertEquals(customEur(bad), null, String(bad));
  assertEquals(customEur(5), 5);
  assertEquals(customEur("500"), 500);
});

Deno.test("checkout: custom fish amount → price_data (VAT inclusive), fish computed on the server; bad amounts → 400", async () => {
  fresh();
  for (const bad of [4, 10001, 7.5, "7.5", "x"]) {
    const r = await call({ item: "fish", amount_eur: bad, fish: 999999 });
    assertEquals(r.status, 400, String(bad));
    assertEquals((await r.json()).reason, "bad_amount");
  }
  assertEquals(stripe.created.length, 0, "no session for a bad amount");
  const r = await call({ item: "fish", amount_eur: 29, fish: 999999, locale: "en" });   // a fish count from the app is ignored
  assertEquals(r.status, 200);
  const j = await r.json();
  assertEquals(j.fish, 3045);
  const p = stripe.created[0];
  assertEquals(p.mode, "payment");
  assertEquals(p["line_items[0][price]"], undefined);
  assertEquals(p["line_items[0][price_data][currency]"], "eur");
  assertEquals(p["line_items[0][price_data][unit_amount]"], "2900");
  assertEquals(p["line_items[0][price_data][tax_behavior]"], "inclusive");
  assertEquals(p["line_items[0][price_data][product_data][name]"], "OrdCat Dried Fish · 3045");
  assertEquals(p["metadata[item]"], "fish");
  assertEquals(p["metadata[pack]"], "custom");
  assertEquals(p["metadata[fish]"], "3045");
  assertEquals(p["metadata[cents]"], "2900");
  assertEquals(p["metadata[amount_eur]"], "29");
  assertEquals(p["consent_collection[terms_of_service]"], "required");
  await call({ item: "fish", amount_eur: 100, locale: "zh" });
  assertEquals(stripe.created[1]["line_items[0][price_data][product_data][name]"], "OrdCat 小鱼干 · 11500");
  assertEquals(stripe.created[1]["metadata[fish]"], "11500");
  // Quick packs unchanged: Stripe price, no price_data.
  await call({ item: "fish", pack: "30" });
  assertEquals(stripe.created[2]["line_items[0][price]"], "price_f30");
  assertEquals(stripe.created[2]["metadata[fish]"], "3300");
  assertEquals(stripe.created[2]["line_items[0][price_data][unit_amount]"], undefined);
});

Deno.test("checkout: every Checkout Session turns on after_expiration recovery", async () => {
  fresh();
  await call({ item: "pro", interval: "year" });
  await call({ item: "x" });
  await call({ item: "fish", pack: "5" });
  await call({ item: "fish", amount_eur: 12 });
  await call({ item: "topup" });
  assertEquals(stripe.created.length, 5);
  for (const p of stripe.created) assertEquals(p["after_expiration[recovery][enabled]"], "true");
  for (const p of stripe.created) assertEquals(p.expires_at, undefined, "Stripe's default expiry is kept");
});

function customSession(id: string, over: Record<string, any> = {}, meta: Record<string, any> = {}) {
  return paidSession(id, {
    mode: "payment", subscription: null, invoice: null, amount_total: 2900, amount_subtotal: 2900, total_details: { amount_tax: 463 },
    metadata: { user_id: UID, item: "fish", pack: "custom", fish: "3045", cents: "2900", amount_eur: "29", lang: "zh", ...meta },
    line_items: { data: [{ description: "OrdCat 小鱼干 · 3045", quantity: 1, amount_total: 2900, price: {} }] },
    payment_intent: { latest_charge: { id: "ch_3", created: 1790000300, receipt_url: "https://pay.stripe.com/receipts/3",
      payment_method_details: { type: "card", card: { brand: "visa", last4: "4242" } } } },
    ...over,
  });
}

Deno.test("webhook: custom fish amount credits the server-computed count (metadata.fish not trusted), English mail", async () => {
  fresh();
  const s = customSession("cs_test_custom00000001", {}, { fish: "999999" });     // tampered / wrong metadata count
  assertEquals((await hook("checkout.session.completed", s)).status, 200);
  const top = db.rpcCalls.find((c) => c.name === "fish_topup")!;
  assertEquals(top.args.p_fish, 3045);
  assertEquals(top.args.p_cents, 2900);
  assertEquals(top.args.p_pack, "custom:29");
  assertEquals(top.args.p_session, "cs_test_custom00000001");
  const m = stripe.mails[0];
  assertStringIncludes(m.text, "OrdCat Dried Fish");
  assertNoForeign(m);                                                              // the zh line-item name stays out of the mail
});

Deno.test("webhook: custom fish whose paid amount doesn't match → nothing credited, Stripe retries (500)", async () => {
  fresh();
  const s = customSession("cs_test_custom00000002", { amount_total: 500 });
  assertEquals((await hook("checkout.session.completed", s)).status, 500);
  assert(!db.rpcCalls.some((c) => c.name === "fish_topup"));
  const s2 = customSession("cs_test_custom00000003", { amount_total: 1500000 }, { amount_eur: "15000", cents: "1500000" });   // out of range
  assertEquals((await hook("checkout.session.completed", s2)).status, 500);
  assert(!db.rpcCalls.some((c) => c.name === "fish_topup"));
});

// ---------------- unpaid-order reminder (checkout.session.expired) ----------------

function expiredSession(id: string, over: Record<string, any> = {}) {
  const s: any = {
    id, object: "checkout.session", status: "expired", payment_status: "unpaid", mode: "subscription", currency: "eur",
    amount_total: 9500, amount_subtotal: 9500, created: 1790000000, customer: "cus_1", client_reference_id: UID,
    customer_details: null, customer_email: null, subscription: null, invoice: null, payment_intent: null,
    metadata: { user_id: UID, item: "pro", lang: "zh" },
    line_items: { data: [{ description: "OrdCat Pro", quantity: 1, amount_total: 9500, price: { recurring: { interval: "year", interval_count: 1 } } }] },
    after_expiration: { recovery: { enabled: true, url: "https://buy.stripe.com/r/live_recover123", expires_at: 1792592000 } },
    ...over,
  };
  stripe.sessions.set(id, s);
  return s;
}
function unpaidFresh() {
  fresh();
  stripe.customers.set("cus_1", { id: "cus_1", email: "mia@langgo.de", metadata: { user_id: UID } });
}

Deno.test("webhook: expired unpaid checkout → one 'order isn't complete' mail with Stripe's recovery link", async () => {
  unpaidFresh();
  const s = expiredSession("cs_test_expired000001");
  for (let i = 0; i < 3; i++) assertEquals((await hook("checkout.session.expired", s)).status, 200);
  assertEquals(stripe.mails.length, 1, "exactly one mail");
  const m = stripe.mails[0];
  assertEquals(m.subject, "Your OrdCat order isn't complete");
  assertEquals(m.to, ["mia@langgo.de"]);
  assertStringIncludes(m.html, 'href="https://buy.stripe.com/r/live_recover123"');
  assertStringIncludes(m.html, "Complete payment");
  assertStringIncludes(m.text, "OrdCat Pro");
  assertStringIncludes(m.text, "€95.00");
  assertStringIncludes(m.text, "No payment was taken. Ignore this email if you changed your mind.");
  assertStringIncludes(m.text, "Axun Conor");
  assert(!/promo|coupon|discount code|% off/i.test(m.text), "no marketing");
  assertNoForeign(m);
  const row = db.t("receipt_emails").find((r) => r.id === "unpaid:cs_test_expired000001")!;
  assertEquals(row.kind, "unpaid");
  assertEquals(row.status, "sent");
});

Deno.test("webhook: expired checkout without a recovery link → pricing page; fish shows the count", async () => {
  unpaidFresh();
  const s = expiredSession("cs_test_expired000002", {
    mode: "payment", amount_total: 2900, after_expiration: null,
    metadata: { user_id: UID, item: "fish", pack: "custom", fish: "3045", cents: "2900", amount_eur: "29" },
    line_items: { data: [{ description: "OrdCat 小鱼干 · 3045", quantity: 1, amount_total: 2900, price: {} }] },
  });
  await hook("checkout.session.expired", s);
  const m = stripe.mails[0];
  assertStringIncludes(m.html, 'href="https://ordcat.de/pricing.html"');
  assertStringIncludes(m.text, "3045 Dried Fish");
  assertNoForeign(m);
});

Deno.test("webhook: expired checkout → no reminder when paid, no user, or the same thing was bought since", async () => {
  // paid (e.g. async payment) → nothing
  unpaidFresh();
  await hook("checkout.session.expired", expiredSession("cs_test_expired000003", { payment_status: "paid" }));
  assertEquals(stripe.mails.length, 0);
  // no OrdCat user → skipped
  unpaidFresh();
  await hook("checkout.session.expired", expiredSession("cs_test_expired000004", { client_reference_id: null, metadata: { item: "pro" } }));
  assertEquals(stripe.mails.length, 0);
  // already has a live plan (bought Max in another checkout) → skipped
  unpaidFresh();
  db.t("subscriptions").push({ id: "sub_9", user_id: UID, customer_id: "cus_1", skill: "max", status: "active" });
  await hook("checkout.session.expired", expiredSession("cs_test_expired000005"));
  assertEquals(stripe.mails.length, 0);
  assertEquals(db.t("receipt_emails").find((r) => r.id === "unpaid:cs_test_expired000005")!.status, "skipped");
  // a skill: only that skill counts
  unpaidFresh();
  db.t("subscriptions").push({ id: "sub_8", user_id: UID, skill: "agent", status: "active" });
  await hook("checkout.session.expired", expiredSession("cs_test_expired000006", { metadata: { user_id: UID, item: "x" } }));
  assertEquals(stripe.mails.length, 1, "a different skill doesn't count");
  // fish: a top-up stored since → skipped
  unpaidFresh();
  db.t("fish_topups").push({ id: "cs_other", user_id: UID, fish: 500, at: new Date(1790000500 * 1000).toISOString() });
  await hook("checkout.session.expired", expiredSession("cs_test_expired000007", { mode: "payment", metadata: { user_id: UID, item: "fish", fish: "500", pack: "5" } }));
  assertEquals(stripe.mails.length, 0);
  // a later completed + paid session for the same customer and item (webhook not stored yet) → skipped
  unpaidFresh();
  stripe.sessions.set("cs_test_later", { id: "cs_test_later", status: "complete", payment_status: "paid", customer: "cus_1", created: 1790000900,
    metadata: { user_id: UID, item: "pro" } });
  await hook("checkout.session.expired", expiredSession("cs_test_expired000008"));
  assertEquals(stripe.mails.length, 0);
});

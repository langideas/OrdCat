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

Deno.test("checkout: same plan again → portal, never a 2nd subscription", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  const j = await (await call({ item: "pro", interval: "month" })).json();
  assertEquals(j.portal, true);
  assertEquals(j.reason, "current");
  assertEquals(stripe.created.length, 0);
  // the same skill twice too
  sub("sub_x", "price_x", { metadata: { item: "x", user_id: UID } });
  const k = await (await call({ item: "x" })).json();
  assertEquals(k.reason, "current");
  assertEquals(stripe.created.length, 0);
});

Deno.test("checkout: Pro → Max yearly opens the portal's update-confirm flow (proration in Stripe)", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  const j = await (await call({ item: "max", interval: "year" })).json();
  assertEquals(j.reason, "switch");
  const p = stripe.portals[0];
  assertEquals(p["flow_data[type]"], "subscription_update_confirm");
  assertEquals(p["flow_data[subscription_update_confirm][subscription]"], "sub_1");
  assertEquals(p["flow_data[subscription_update_confirm][items][0][id]"], "si_sub_1");
  assertEquals(p["flow_data[subscription_update_confirm][items][0][price]"], "price_max_y");
  assertEquals(stripe.created.length, 0);
});

Deno.test("checkout: portal without the update flow enabled → plain portal", async () => {
  fresh(); withCustomer();
  sub("sub_1", "price_pro_m");
  stripe.portalFlowsDisabled = true;
  const j = await (await call({ item: "max", interval: "month" })).json();
  assertEquals(j.portal, true);
  assert(j.url);
  assertEquals(Object.keys(stripe.portals[0]).filter((k) => k.startsWith("flow_data")).length, 0);
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
  assertStringIncludes(m.subject, "订单确认");
  assertStringIncludes(m.subject, "Vertragsbestätigung");
  assertStringIncludes(m.text, "Axun Conor");
  assertStringIncludes(m.text, "Hedemannstraße 74");
  assertStringIncludes(m.text, "原价");                        // yearly saving line
  assertStringIncludes(m.text, "Widerrufsbelehrung");
  assertStringIncludes(m.text, "§ 357a Abs. 2 BGB");            // service consent (not digital content)
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
  assertStringIncludes(m.subject, "Your order confirmation");
  assertStringIncludes(m.text, "1050 Dried Fish");
  assertStringIncludes(m.text, "§ 356 Abs. 6 BGB");
  assertStringIncludes(m.text, "VAT included (inkl. MwSt.)");
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
  assertStringIncludes(stripe.mails[0].subject, "Vertragsbestätigung Ihrer Bestellung · OrdCat");
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
  assertStringIncludes(stripe.mails[0].subject, "订阅已续费");
  assertStringIncludes(stripe.mails[0].text, "ORD-0002");
  assert(!stripe.mails[0].text.includes("Muster-Widerrufsformular"), "no withdrawal form on renewals");
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
  assertStringIncludes(stripe.mails[0].subject, "续费扣款没有成功");
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
  assertStringIncludes(stripe.mails[0].subject, "已取消订阅");
  assertStringIncludes(stripe.mails[0].text, "Bestätigung Ihrer Kündigung");
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
  assertEquals(db.t("cancel_requests")[0].status, "done");
  const bad = await handlers["cancel-contract"](new Request("https://x", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "cancel", email: "nope", contract: "pro" }),
  }));
  assertEquals(bad.status, 400);
});

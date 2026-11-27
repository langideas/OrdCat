// Stripe → 订阅 / 加油包 / 小鱼干充值写进 OrdCat 账号，并发我们自己的邮件。
// 小鱼干充值：fish_topup(session id) 只加一次（重复的 webhook 不会多加），只有这里用 service_role 能调。
// Stripe 后台 → Developers → Webhooks → Add endpoint：
//   URL = https://<project>.supabase.co/functions/v1/stripe-webhook
//   事件：checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.expired（未付款提醒）, customer.subscription.created, customer.subscription.updated,
//         customer.subscription.deleted, invoice.paid, invoice.payment_failed,
//         subscription_schedule.created / updated / released / canceled / completed / aborted（App 里预约的降级，v0.2.64）
// 部署：supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets：STRIPE_WEBHOOK_SECRET=whsec_…（同上 STRIPE_SECRET_KEY、STRIPE_PRICES）
//
// 订阅状态（subscriptions 表，App 读）：status = active | trialing | past_due（扣款失败，Stripe 自动重试中，会员照常）| canceled …；
//   cancel_at_period_end = true 表示已取消、当期结束；billing_interval = month | year；amount_cents / currency = 每期价格。
//   方案按价格 ID 认（STRIPE_PRICES），所以在 Portal 里 Pro ↔ Max、月付 ↔ 年付 换了以后也对；订阅删除（到期 / 扣款失败到底）→ canceled → 免费版。
//   新列在 receipts.sql 里；还没运行 receipts.sql 时自动只写旧列（会员照样生效）。
//
// 邮件（Resend，v0.2.64 起；全部只发英文，不看 metadata.lang；模板 ../_shared/mail.ts，深色卡片 + 琥珀色，和 thanks.html 一致）：
//   · 购买确认（BGB §312f Vertragsbestätigung）：checkout.session.completed / async_payment_succeeded，已付款时
//   · 续费收据：invoice.paid，billing_reason = subscription_cycle（首张发票 subscription_create 已由购买确认覆盖）
//   · 升级确认：invoice.paid，billing_reason = subscription_update（App 里升级 / 改年付，stripe-checkout 立即开新周期并收款）：
//     「Plan upgraded」；其它 subscription_update 发票（比如预约的降级生效）叫「Plan changed」。key = upgrade:in_…（需要 plan_change.sql）
//   · 降级预约确认（Plan change scheduled）由 stripe-checkout 建好 Subscription Schedule 后自己发，key = sched:sub_sched_…
//   · 扣款失败：invoice.payment_failed（每张发票只发一次，Stripe 重试不再发）
//   · 未付款提醒（v0.2.64+）：checkout.session.expired，没付款、有邮箱和 OrdCat 账号、之后也没买成同一样东西时，
//     发一封「Your OrdCat order isn't complete」+「Complete payment」（Stripe after_expiration 恢复链接，没有就 pricing.html）。
//     key = unpaid:cs_…，kind = unpaid（需要 unpaid_mail.sql）。Stripe webhook 要加事件 checkout.session.expired。
//   · 取消确认：customer.subscription.updated 里 cancel_at_period_end / cancel_at 刚被设上（Portal 里取消）；
//     cancel-contract（ordcat.de/kuendigen.html）取消的已经由它自己发确认，这里不重复。
//   幂等：先在 receipt_emails（receipts.sql）占位再发；邮件出错只记日志，webhook 照样回 200。
//   Secrets：RESEND_API_KEY（没设就不发）、可选 CANCEL_MAIL_BCC / CANCEL_MAIL_FROM（和 cancel-contract 共用）、SITE_URL。
import { createClient } from "npm:@supabase/supabase-js@2";
import { customEur, fishForEur } from "../_shared/fish.ts";
import { type Button, C, dayEn, escH, type MailSpec, money, render, type Row, type Section, SELLER_NAME, sendOnce, SUPPORT, whenEn } from "../_shared/mail.ts";

async function hmacHex(secret: string, msg: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Stripe-Signature: t=…,v1=…  (signed payload = "t.rawBody"; reject if older than 5 minutes)
async function verify(raw: string, header: string, secret: string) {
  const parts = Object.fromEntries(header.split(",").map((kv) => kv.split("=") as [string, string]));
  const t = Number(parts.t ?? 0);
  if (!t || Math.abs(Date.now() / 1000 - t) > 300) return false;
  const want = await hmacHex(secret, `${t}.${raw}`);
  return header.split(",").some((kv) => kv === `v1=${want}`);
}

async function stripeGet(path: string) {
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    headers: { Authorization: `Bearer ${Deno.env.get("STRIPE_SECRET_KEY")}` },
  });
  return await r.json();
}

const iso = (s?: number | null) => (s ? new Date(s * 1000).toISOString() : null);

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

// ---------- confirmation mail (BGB §312f Vertragsbestätigung) ----------
// Sent once per Checkout Session (first purchase) and once per renewal invoice. Idempotent via receipt_emails
// (receipts.sql): the row is claimed BEFORE sending, so Stripe retries / completed + async_payment_succeeded never
// send twice. Any failure here is logged and swallowed: the webhook still answers 200.

type Lang = "de" | "zh" | "en";
const SITE = () => Deno.env.get("SITE_URL") ?? "https://ordcat.de";

const ITEM_NAME: Record<string, string> = {
  pro: "OrdCat Pro", max: "OrdCat Max", topup: "OrdCat Top-up", x: "OrdCat X Companion",
  agent: "OrdCat Mac Agent", miao: "OrdCat Live Subtitles", fish: "OrdCat Dried Fish",
};
const isDigital = (item: string | null) => item === "fish" || item === "topup";

function payLine(r: Receipt): string | null {
  const p = r.payment_method;
  if (!p) return null;
  let b = (p.type === "paypal" ? "PayPal" : p.brand.replace(/_/g, " "));
  b = b.charAt(0).toUpperCase() + b.slice(1);
  if (b === "Amex") b = "American Express";
  const w = p.wallet === "apple_pay" ? "Apple Pay" : p.wallet === "google_pay" ? "Google Pay" : p.wallet?.replace(/_/g, " ");
  return (w ? `${w} · ` : "") + b + (p.last4 ? ` •••• ${p.last4}` : "");
}

const billingLine = (iv: string | null | undefined) =>
  iv === "year" ? "Yearly · renews automatically every year" : iv === "month" ? "Monthly · renews automatically every month" : "One-time payment";

// Withdrawal information as on ordcat.de/widerruf.html (as of 27 Nov 2026), in English, on a durable medium with the first confirmation.
const WITHDRAWAL_EN: Section[] = [
  {
    title: "Withdrawal information · Right of withdrawal",
    paras: [
      "You have the right to withdraw from this contract within fourteen days without giving any reason. The withdrawal period is fourteen days from the day the contract was concluded.",
      "To exercise your right of withdrawal, you must inform us (Axun Conor, Hedemannstraße 74, 78355 Hohenfels, Germany, email: support@ordcat.de) of your decision to withdraw from this contract by an unequivocal statement (e.g. a letter sent by post or an email). You may use the model withdrawal form below, but it is not obligatory.",
      "You can also withdraw online at https://ordcat.de/widerruf.html#widerrufen (“Withdraw from the contract”). If you use this online function, we will promptly send you a confirmation of receipt on a durable medium (e.g. by email) with the content of your withdrawal and the date and time it was received.",
      "To meet the withdrawal deadline, it is sufficient for you to send your communication concerning your exercise of the right of withdrawal before the withdrawal period has expired.",
    ],
  },
  {
    title: "Effects of withdrawal",
    paras: [
      "If you withdraw from this contract, we shall reimburse all payments received from you without undue delay and in any event not later than fourteen days from the day on which we are informed about your decision to withdraw from this contract. We will use the same means of payment as you used for the initial transaction, unless you have expressly agreed otherwise; in any event, you will not incur any fees as a result of such reimbursement.",
      "If you requested to begin the performance of services during the withdrawal period, you shall pay us an amount which is in proportion to what has been provided until you have communicated to us your withdrawal from this contract, in comparison with the full coverage of the contract.",
    ],
  },
  {
    title: "Early expiry of the right of withdrawal",
    paras: [
      "Digital content (Dried Fish packs, message top-ups): your right of withdrawal expires once we have begun performing the contract (the credit to your account), after you 1. expressly agreed that we begin performance before the withdrawal period ends, 2. confirmed your knowledge that by giving this consent you lose your right of withdrawal once performance begins, and 3. we provided you with a confirmation under § 312f BGB (§ 356(6) BGB).",
      "Services (Pro and Max memberships; X Companion, Mac Agent and Live Subtitles skill subscriptions): if you asked us to start the service immediately and you withdraw within 14 days, you pay the pro-rata amount for the days used until your withdrawal; we refund the rest (§ 357a(2) BGB). Your right of withdrawal expires once the service has been provided in full, if before it started you expressly agreed that we begin before the withdrawal period ends and confirmed your knowledge that your right of withdrawal expires once the contract has been fully performed (§ 356(5) BGB).",
      "Withdrawal and cancellation are different declarations. To stop a subscription from renewing, cancel it at https://ordcat.de/kuendigen.html.",
      "End of withdrawal information",
    ],
  },
  {
    title: "Model withdrawal form",
    paras: [
      "(Complete and return this form only if you wish to withdraw from the contract.)",
      "– To Axun Conor, Hedemannstraße 74, 78355 Hohenfels, Germany, email: support@ordcat.de:",
      "– I/We (*) hereby give notice that I/We (*) withdraw from my/our (*) contract of sale of the following goods (*)/for the provision of the following service (*)",
      "– Ordered on (*)/received on (*)",
      "– Name of consumer(s)",
      "– Address of consumer(s)",
      "– Signature of consumer(s) (only if this form is notified on paper)",
      "– Date",
      "(*) Delete as appropriate.",
    ],
  },
];

/** Order confirmation (BGB §312f) and renewal receipt: same card, English only. */
function buildMail(r: Receipt) {
  const renewal = r.kind === "renewal";
  const sub = r.mode === "subscription";
  const iv = r.items[0]?.interval ?? null;
  // Fish: always the English name (a Stripe product / custom-amount line can be named in Chinese; mails are English only).
  const name = r.item === "fish" ? ITEM_NAME.fish : (r.items[0]?.name ?? (r.item ? ITEM_NAME[r.item] : "OrdCat"));
  const price = money(r.amount_total, r.currency);
  const taxTxt = r.amount_tax != null ? `incl. ${money(r.amount_tax, r.currency)} VAT` : "VAT included";
  const site = SITE();

  const rows: Row[] = [{ k: "Product", v: name }];
  rows.push(r.fish ? { k: "Quantity", v: `${r.fish} Dried Fish`, sub: "One-time payment" } : { k: "Billing", v: billingLine(iv) });
  rows.push({ k: "Amount paid", v: price, sub: taxTxt });
  rows.push({ k: "Date", v: whenEn(r.created) });
  const pl = payLine(r);
  if (pl) rows.push({ k: "Payment method", v: pl });
  if (r.email) rows.push({ k: "Email", v: r.email });
  if (sub && r.renews_at) rows.push({ k: "Next renewal", v: dayEn(r.renews_at) });
  else if (sub && r.ends_at) rows.push({ k: "Ends on", v: dayEn(r.ends_at) });
  if (r.invoice_number) rows.push({ k: "Invoice no.", v: r.invoice_number });
  rows.push({ k: renewal ? "Invoice ID" : "Order no.", v: r.id, mono: true });

  const y = r.yearly;
  const save = y
    ? {
      html: `Regular price <s style="color:${C.mute}">${escH(money(y.regular, r.currency))}/year</s> (${escH(money(y.monthly, r.currency))} × 12 months) · ` +
        `yearly discount <b style="color:${C.amber}">−${escH(money(y.discount, r.currency))}</b> (${Math.round(y.discount / y.regular * 100)}% off) · ` +
        `you pay <b>${escH(money(y.paid, r.currency))}/year</b>.`,
      text: `Regular price ${money(y.regular, r.currency)}/year (${money(y.monthly, r.currency)} × 12 months), yearly discount −${money(y.discount, r.currency)} (${Math.round(y.discount / y.regular * 100)}% off), you pay ${money(y.paid, r.currency)}/year.`,
    }
    : undefined;

  const body: Section[] = [];
  if (sub) {
    const paras: string[] = [];
    if (r.renews_at) {
      paras.push(`Your subscription renews automatically every ${iv === "year" ? "year" : "month"} at ${price} (${taxTxt}) until you cancel. Next renewal: ${dayEn(r.renews_at)}.`);
    } else if (r.ends_at) paras.push(`Your subscription is cancelled and ends on ${dayEn(r.ends_at)}.`);
    paras.push(`You can cancel anytime, effective at the end of the current period: in OrdCat under Settings → User → Manage membership, or without signing in at ${site}/kuendigen.html.`);
    body.push({ title: "Renewal and cancellation", paras });
  }

  const buttons: Button[] = [];
  if (!renewal) buttons.push({ label: "View receipt", href: `${site}/thanks.html?session_id=${r.id}`, primary: true });
  if (r.receipt_url) buttons.push({ label: "Stripe receipt", href: r.receipt_url, primary: renewal && !buttons.length });
  if (r.invoice_pdf) buttons.push({ label: "Invoice PDF", href: r.invoice_pdf });
  else if (r.invoice_url) buttons.push({ label: "View invoice", href: r.invoice_url });
  if (sub) buttons.push({ label: "Cancel subscription", href: `${site}/kuendigen.html` });

  const legal: Section[] = [];
  if (!renewal) {
    legal.push({
      title: "Your consent at checkout",
      paras: [isDigital(r.item)
        ? "At checkout you accepted our Terms, expressly asked us to start performing the contract before the withdrawal period ends, and confirmed that you know you lose your right of withdrawal once performance begins (the credit to your account) (§ 356(6) BGB). The credit has been made."
        : "At checkout you accepted our Terms and expressly asked us to start the service before the withdrawal period ends. If you withdraw within 14 days, you pay pro rata for the days used (§ 357a(2) BGB); your right of withdrawal expires once the service has been provided in full (§ 356(5) BGB)."],
      links: [
        { label: "Terms", href: `${site}/terms.html` },
        { label: "Withdrawal information", href: `${site}/widerruf.html` },
        { label: "Withdraw from the contract", href: `${site}/widerruf.html#widerrufen` },
      ],
    });
    legal.push({
      title: "Seller",
      paras: [`${SELLER_NAME}, Hedemannstraße 74, 78355 Hohenfels, Germany · ${SUPPORT}. This email confirms the contract concluded on ${whenEn(r.created)} and is your copy on a durable medium.`],
    });
    legal.push(...WITHDRAWAL_EN);
  } else {
    legal.push({
      title: "Seller",
      paras: [`${SELLER_NAME}, Hedemannstraße 74, 78355 Hohenfels, Germany · ${SUPPORT}.`],
      links: [{ label: "Terms", href: `${site}/terms.html` }, { label: "Withdrawal information", href: `${site}/widerruf.html` }],
    });
  }

  const short = name.replace(/^OrdCat /, "");
  const spec: MailSpec = {
    subject: renewal ? `Your ${name.startsWith("OrdCat") ? name : "OrdCat " + name} renewal receipt` : "Order confirmation · OrdCat",
    preheader: renewal
      ? `${short} renewed · ${price}${r.renews_at ? ` · next renewal ${dayEn(r.renews_at)}` : ""}`
      : `Thank you! ${name} · ${price} · your contract confirmation and receipt`,
    badge: "ok", icon: "✓",
    title: renewal ? "Subscription renewed" : "Order confirmed",
    subtitle: renewal ? "Your subscription renewed as scheduled and we received your payment." : "Thank you! This email confirms your contract with OrdCat.",
    amount: { main: price, per: iv === "year" ? "year" : iv === "month" ? "month" : undefined },
    rows, save, body, buttons, legal,
  };
  return render(spec, site);
}

async function receiptFromInvoice(inv: any, sub: any, itemNow: string | null): Promise<Receipt> {
  const charge = await invoiceCharge(inv);
  const price = sub?.items?.data?.[0]?.price;
  const item = itemNow ?? sub?.metadata?.item ?? null;
  const lang0 = String(sub?.metadata?.lang ?? "");
  const lines = inv.lines?.data ?? [];
  const tax = Number(inv.tax ?? 0) ||
    (inv.total_taxes ?? []).reduce((a: number, t: any) => a + Number(t.amount ?? 0), 0) ||
    (inv.total_tax_amounts ?? []).reduce((a: number, t: any) => a + Number(t.amount ?? 0), 0);
  const total = Number(inv.amount_paid ?? inv.total ?? 0);
  const interval = price?.recurring?.interval ?? null;
  const live = sub && ["active", "trialing", "past_due"].includes(sub.status);
  return {
    kind: "renewal",
    id: inv.id,
    mode: "subscription",
    paid: inv.status === "paid",
    processing: false,
    item,
    lang: lang0 === "zh" || lang0 === "de" || lang0 === "en" ? lang0 : null,
    currency: String(inv.currency ?? "eur"),
    amount_total: total,
    amount_subtotal: Number(inv.subtotal ?? total),
    amount_tax: tax > 0 ? tax : null,
    amount_discount: 0,
    items: [{
      name: item && ITEM_NAME[item] ? ITEM_NAME[item] : String(lines[0]?.description ?? "OrdCat"),
      quantity: 1, amount: total, interval, interval_count: Number(price?.recurring?.interval_count ?? 1),
    }],
    fish: null,
    yearly: yearlyOf(item, interval, total),
    created: Number(inv.status_transitions?.paid_at ?? charge?.created ?? inv.created),
    payment_method: cardOf(charge, sub),
    email: inv.customer_email ?? null,
    renews_at: live && !sub.cancel_at_period_end && !sub.cancel_at ? subEnd(sub) : null,
    ends_at: sub ? (sub.cancel_at ?? (sub.cancel_at_period_end ? subEnd(sub) : null)) : null,
    receipt_url: charge?.receipt_url ?? null,
    invoice_url: inv.hosted_invoice_url ?? null,
    invoice_pdf: inv.invoice_pdf ?? null,
    invoice_number: inv.number ?? null,
    consent_tos: false,
    user_id: sub?.metadata?.user_id ?? null,
  };
}

type Mail = { to: string | null; lang: Lang; subject: string; html: string; text: string; item: string | null; user_id: string | null; skip?: string };

const nameFor = (item: string | null) => (item && ITEM_NAME[item] ? ITEM_NAME[item] : "OrdCat");

function failedMail(inv: any, sub: any, item: string | null): Mail {
  const amount = Number(inv.amount_due ?? inv.total ?? 0), cur = String(inv.currency ?? "eur");
  const payUrl = inv.hosted_invoice_url as string | undefined;
  const site = SITE();
  const rows: Row[] = [{ k: "Product", v: nameFor(item) }, { k: "Amount due", v: money(amount, cur), sub: "VAT included" }];
  if (inv.number) rows.push({ k: "Invoice no.", v: String(inv.number) });
  if (inv.customer_email) rows.push({ k: "Email", v: String(inv.customer_email) });
  const buttons: Button[] = [];
  if (payUrl) buttons.push({ label: "Pay invoice", href: payUrl, primary: true });
  buttons.push({ label: "Cancel subscription", href: `${site}/kuendigen.html` });
  const m = render({
    subject: "Payment failed · OrdCat",
    preheader: `We couldn't charge the renewal of ${nameFor(item)} (${money(amount, cur)}). Your plan stays active while we retry.`,
    badge: "wait", icon: "!",
    title: "Your payment didn't go through",
    subtitle: "Your plan stays active while we retry.",
    greeting: "Hello,",
    intro: [`We couldn't charge the renewal of ${nameFor(item)} (${money(amount, cur)}).`],
    amount: { main: money(amount, cur) },
    rows,
    body: [{
      title: "What happens next",
      paras: [
        "We'll retry automatically over the next few days, and your plan stays active in the meantime.",
        "Please update your payment method: in OrdCat, open Settings → User → Update payment method" + (payUrl ? `, or pay the invoice here: ${payUrl}` : "."),
        "If no payment succeeds, the subscription ends and your account goes back to Free.",
      ],
    }],
    buttons,
  }, site);
  return { to: inv.customer_email ?? null, lang: "en", ...m, item, user_id: sub?.metadata?.user_id ?? null };
}

function cancelMail(sub: any, item: string | null, email: string | null, at: number): Mail {
  const end = Number(sub.cancel_at ?? subEnd(sub) ?? 0);
  const recv = Number(sub.canceled_at ?? at);
  const site = SITE();
  const rows: Row[] = [{ k: "Product", v: nameFor(item) }, { k: "Received", v: whenEn(recv) }];
  if (end) rows.push({ k: "Ends on", v: dayEn(end) });
  if (email) rows.push({ k: "Email", v: email });
  rows.push({ k: "Reference", v: String(sub.id), mono: true });
  const m = render({
    subject: "Subscription cancelled · OrdCat",
    preheader: end ? `${nameFor(item)} ends on ${dayEn(end)} and won't renew.` : `${nameFor(item)} won't renew.`,
    badge: "no", icon: "✓",
    title: "Your cancellation is confirmed",
    subtitle: end ? `You can keep using ${nameFor(item)} until ${dayEn(end)}.` : "Your subscription won't renew.",
    greeting: "Hello,",
    intro: [`We received your cancellation of ${nameFor(item)} on ${whenEn(recv)}.`],
    rows,
    body: [{
      paras: [
        end ? `Your subscription ends on ${dayEn(end)}. You can keep using it until then; it won't renew.` : "Your subscription won't renew.",
        "Changed your mind? Before it ends, open OrdCat → Settings → User → Resume subscription.",
        "Didn't cancel this yourself? Just reply to this email.",
      ],
    }],
    legal: [{
      paras: [`Seller: ${SELLER_NAME}, Hedemannstraße 74, 78355 Hohenfels, Germany · ${SUPPORT}.`],
      links: [{ label: "Terms", href: `${site}/terms.html` }, { label: "Withdrawal information", href: `${site}/widerruf.html` }],
    }],
  }, site);
  return { to: email, lang: "en", ...m, item, user_id: sub?.metadata?.user_id ?? null };
}

// Plan upgrade made in the app (stripe-checkout "change"): Pro → Max, or monthly → yearly. The new billing cycle starts
// today (billing_cycle_anchor = now, proration_behavior = always_invoice), so Stripe charges the new price minus a credit
// for the unused part of the old plan right away: invoice.paid, billing_reason = subscription_update.
// Same layout titled "Plan changed" for any other subscription_update invoice (e.g. a scheduled downgrade taking effect).
const TIER: Record<string, number> = { pro: 1, max: 2 };
type PlanAt = { item: string | null; interval: string | null; unit: number | null };

/** Old plan = price on the credit line ("Unused time on …"), new plan = price on the charge line. */
function planLines(inv: any, itemOfPrice: (id: string) => string | undefined): { old: PlanAt; now: PlanAt } {
  const out = { old: { item: null, interval: null, unit: null } as PlanAt, now: { item: null, interval: null, unit: null } as PlanAt };
  for (const l of inv?.lines?.data ?? []) {
    const pid = idOf(l.price) ?? idOf(l.pricing?.price_details?.price) ?? null;
    const it = pid ? itemOfPrice(pid) : undefined;
    if (!it) continue;
    const pr = typeof l.price === "object" ? l.price : null;
    const at = { item: it, interval: pr?.recurring?.interval ?? null, unit: pr?.unit_amount != null ? Number(pr.unit_amount) : null };
    if (Number(l.amount ?? 0) < 0) { if (!out.old.item) out.old = at; } else if (!out.now.item) out.now = at;
  }
  return out;
}

function upgradeMail(r: Receipt, sub: any, old: PlanAt, now: PlanAt): Mail {
  const site = SITE();
  const item = now.item ?? r.item;
  const iv = now.interval ?? r.items[0]?.interval ?? null;
  const name = item && ITEM_NAME[item] ? ITEM_NAME[item] : (r.items[0]?.name ?? "OrdCat");
  const oldName = old.item && ITEM_NAME[old.item] ? ITEM_NAME[old.item] : null;
  const tierUp = !!(item && old.item && (TIER[item] ?? 0) > (TIER[old.item] ?? 0));
  const toYearly = !!(item && old.item && item === old.item && old.interval === "month" && iv === "year");
  const up = tierUp || toYearly;
  const per = iv === "year" ? "year" : "month";
  const subPrice = sub?.items?.data?.[0]?.price;
  const unit = Number(now.unit ?? (subPrice?.id && itemOfPriceId(subPrice.id) === item ? subPrice.unit_amount : null) ??
    (item && PLAN_CENTS[item] ? PLAN_CENTS[item][per] : 0));
  const charged = money(r.amount_total, r.currency);
  const taxTxt = r.amount_tax != null ? `incl. ${money(r.amount_tax, r.currency)} VAT` : "VAT included";
  const was = oldName ? `${oldName}${old.interval ? ` (${old.interval === "year" ? "yearly" : "monthly"})` : ""}` : null;

  const rows: Row[] = [{ k: "New plan", v: name, sub: was ? `was ${was}` : undefined }];
  rows.push({ k: "Billing", v: billingLine(iv) });
  rows.push({ k: "Charged now", v: charged, sub: `${taxTxt} · unused part of your previous plan credited` });
  rows.push({ k: "Date", v: whenEn(r.created) });
  const pl = payLine(r);
  if (pl) rows.push({ k: "Payment method", v: pl });
  if (r.email) rows.push({ k: "Email", v: r.email });
  if (r.renews_at) rows.push({ k: "Next renewal", v: dayEn(r.renews_at), sub: unit ? `${money(unit, r.currency)} incl. VAT` : undefined });
  else if (r.ends_at) rows.push({ k: "Ends on", v: dayEn(r.ends_at) });
  if (r.invoice_number) rows.push({ k: "Invoice no.", v: r.invoice_number });
  rows.push({ k: "Invoice ID", v: r.id, mono: true });

  const y = unit ? yearlyOf(item, iv, unit) : null;
  const save = y
    ? {
      html: `Regular price <s style="color:${C.mute}">${escH(money(y.regular, r.currency))}/year</s> (${escH(money(y.monthly, r.currency))} × 12 months) · ` +
        `yearly discount <b style="color:${C.amber}">−${escH(money(y.discount, r.currency))}</b> (${Math.round(y.discount / y.regular * 100)}% off) · ` +
        `you pay <b>${escH(money(y.paid, r.currency))}/year</b>.`,
      text: `Regular price ${money(y.regular, r.currency)}/year (${money(y.monthly, r.currency)} × 12 months), yearly discount −${money(y.discount, r.currency)} (${Math.round(y.discount / y.regular * 100)}% off), you pay ${money(y.paid, r.currency)}/year.`,
    }
    : undefined;

  const paras: string[] = [];
  paras.push(`${name}${iv ? ` (${per === "year" ? "yearly" : "monthly"})` : ""} is active right away and your new billing cycle starts today. ` +
    `Today's charge is the price of the new plan minus a credit for the unused part of your previous plan: ${charged} (${taxTxt}).`);
  if (r.renews_at && unit) paras.push(`From ${dayEn(r.renews_at)}, your subscription renews automatically every ${per} at ${money(unit, r.currency)} (VAT included) until you cancel.`);
  else if (r.ends_at) paras.push(`Your subscription is cancelled and ends on ${dayEn(r.ends_at)}.`);
  paras.push(`Manage it in OrdCat under Settings → User → Membership. You can cancel anytime, effective at the end of the current period, also without signing in at ${site}/kuendigen.html.`);

  const buttons: Button[] = [];
  if (r.invoice_pdf) buttons.push({ label: "Invoice PDF", href: r.invoice_pdf, primary: true });
  else if (r.invoice_url) buttons.push({ label: "View invoice", href: r.invoice_url, primary: true });
  if (r.receipt_url) buttons.push({ label: "Stripe receipt", href: r.receipt_url, primary: !buttons.length });
  if (r.invoice_pdf && r.invoice_url) buttons.push({ label: "View invoice", href: r.invoice_url });
  buttons.push({ label: "Cancel subscription", href: `${site}/kuendigen.html` });

  const title = tierUp ? `You're on ${name} now` : toYearly ? "You're on yearly billing now" : "Plan changed";
  const m = render({
    subject: up ? "Plan upgraded · OrdCat" : "Plan changed · OrdCat",
    preheader: `${name} (${per === "year" ? "yearly" : "monthly"}) is active · ${charged} charged today`,
    badge: "ok", icon: up ? "↑" : "✓",
    title,
    subtitle: up ? "Plan upgraded. Your new billing cycle starts today." : `Your plan is now ${name}, billed ${per === "year" ? "yearly" : "monthly"}.`,
    amount: { main: charged },
    rows, save,
    body: [{ title: "What changes", paras }],
    buttons,
    legal: [{
      title: "Seller",
      paras: [`${SELLER_NAME}, Hedemannstraße 74, 78355 Hohenfels, Germany · ${SUPPORT}. This email confirms the change to your contract.`],
      links: [
        { label: "Terms", href: `${site}/terms.html` },
        { label: "Withdrawal information", href: `${site}/widerruf.html` },
        { label: "Cancel contracts", href: `${site}/kuendigen.html` },
      ],
    }],
  }, site);
  return { to: r.email, lang: "en", ...m, item, user_id: r.user_id, skip: r.paid ? undefined : "not paid" };
}
const itemOfPriceId = (id: string) =>
  Object.entries(JSON.parse(Deno.env.get("STRIPE_PRICES") ?? "{}") as Record<string, string>).find(([, v]) => v === id)?.[0]?.split(".")[0];

async function receiptMail(load: () => Promise<Receipt>, _country?: string | null): Promise<Mail> {
  const r = await load();
  const m = buildMail(r);
  return { to: r.email, lang: "en", ...m, item: r.item, user_id: r.user_id, skip: r.paid ? undefined : "not paid" };
}


function withTimeout(p: Promise<unknown>, ms: number) {
  return Promise.race([p, new Promise((res) => setTimeout(res, ms))]);
}

/** Fish to credit for a paid fish session. Packs: metadata as before. Custom amount: recomputed here from the euros
 *  actually paid (metadata.amount_eur must match amount_total and metadata.cents); metadata.fish is only cross-checked. */
function fishCredit(obj: any): { fish: number; cents: number; pack: string } {
  if (obj.metadata?.pack === "custom") {
    const eur = customEur(obj.metadata?.amount_eur);
    if (eur === null) throw new Error("custom fish top-up: bad amount_eur");
    const cents = eur * 100;
    if (Number(obj.amount_total) !== cents || Number(obj.metadata?.cents ?? cents) !== cents) {
      throw new Error(`custom fish top-up: paid ${obj.amount_total} ≠ ${cents}`);
    }
    const fish = fishForEur(eur);
    if (Number(obj.metadata?.fish) !== fish) console.error("custom fish: metadata.fish", obj.metadata?.fish, "≠", fish, "→ using", fish);
    return { fish, cents, pack: `custom:${eur}` };
  }
  const fish = Number(obj.metadata?.fish ?? 0);
  if (!(fish > 0)) throw new Error("fish top-up without amount");
  return { fish, cents: Number(obj.metadata?.cents ?? obj.amount_subtotal ?? 0), pack: String(obj.metadata?.pack ?? "") };
}

// ---------- unpaid-order reminder (checkout.session.expired) ----------
const LIVE_SUB = ["active", "trialing", "past_due", "unpaid", "incomplete"];

/** Has the user bought the same thing since this session was opened? (plan: any Pro / Max; skill: that skill; fish: any top-up) */
async function boughtSince(admin: any, s: any, item: string, userId: string): Promise<boolean> {
  const since = Number(s.created ?? 0);
  const isPlan = item === "pro" || item === "max";
  try {
    if (item === "fish") {
      const { data } = await admin.from("fish_topups").select("id,at").eq("user_id", userId);
      if ((data ?? []).some((r: any) => r.id !== s.id && (!r.at || Date.parse(r.at) / 1000 >= since))) return true;
    } else {
      const { data } = await admin.from("subscriptions").select("skill,status,ends_at").eq("user_id", userId);
      const now = Date.now();
      if ((data ?? []).some((r: any) => (isPlan ? r.skill === "pro" || r.skill === "max" : r.skill === item) &&
          LIVE_SUB.includes(r.status) && !(r.ends_at && Date.parse(r.ends_at) < now))) return true;
    }
  } catch (_) { /* fall through to Stripe */ }
  // A later completed checkout for the same customer + item (covers a payment the webhook hasn't stored yet).
  const cus = idOf(s.customer);
  if (cus) {
    try {
      const l = await stripeGetOk(`checkout/sessions?customer=${encodeURIComponent(cus)}&status=complete&created[gte]=${since}&limit=20`);
      if ((l.data ?? []).some((x: any) => {
        if (x.id === s.id || !["paid", "no_payment_required"].includes(x.payment_status)) return false;
        const it = x.metadata?.item;
        return isPlan ? it === "pro" || it === "max" : it === item;
      })) return true;
    } catch (_) { /* ignore */ }
  }
  return false;
}

async function unpaidMail(admin: any, s: any): Promise<Mail> {
  const item: string | null = s.metadata?.item ?? null;
  const userId: string | null = s.metadata?.user_id ?? s.client_reference_id ?? null;
  const base = { lang: "en" as Lang, item, user_id: userId };
  const skip = (why: string): Mail => ({ to: null, subject: "", html: "", text: "", ...base, skip: why });
  if (s.payment_status === "paid" || s.payment_status === "no_payment_required") return skip("paid");
  if (!userId) return skip("no user");
  if (!item) return skip("no item");
  let full = s;
  try { full = await stripeGetOk(`checkout/sessions/${encodeURIComponent(s.id)}?expand[]=line_items`); } catch (_) { /* event copy */ }
  let email: string | null = full.customer_details?.email ?? full.customer_email ?? null;
  if (!email && idOf(full.customer)) {
    try { email = (await stripeGetOk(`customers/${idOf(full.customer)}`)).email ?? null; } catch (_) { /* none */ }
  }
  if (!email) return skip("no email");
  if (await boughtSince(admin, full, item, userId)) return skip("bought since");

  const site = SITE();
  const cur = String(full.currency ?? "eur");
  const li = full.line_items?.data?.[0];
  const iv: string | null = li?.price?.recurring?.interval ?? null;
  const fish = item === "fish" ? Number(full.metadata?.fish ?? 0) : 0;
  const amount = Number(full.amount_total ?? li?.amount_total ?? full.metadata?.cents ?? 0);
  const name = item === "fish" ? ITEM_NAME.fish : nameFor(item);
  const rec = full.after_expiration?.recovery;
  const url: string = rec?.url || `${site}/pricing.html`;
  const recExp = Number(rec?.expires_at ?? 0);

  const rows: Row[] = [{ k: "Product", v: name }];
  rows.push(fish > 0 ? { k: "Quantity", v: `${fish} Dried Fish`, sub: "One-time payment" } : { k: "Billing", v: billingLine(iv) });
  if (amount > 0) rows.push({ k: "Amount", v: money(amount, cur), sub: "VAT included · not charged" });
  rows.push({ k: "Started", v: whenEn(Number(full.created ?? Date.now() / 1000)) });
  rows.push({ k: "Email", v: email });
  rows.push({ k: "Reference", v: String(full.id), mono: true });

  const paras: string[] = [];
  paras.push(rec?.url
    ? `To finish your order, click Complete payment.${recExp ? ` The link works until ${dayEn(recExp)}.` : ""}`
    : `To finish your order, open ${site}/pricing.html or OrdCat → Settings → User → Membership.`);
  paras.push("No payment was taken. Ignore this email if you changed your mind.");

  const m = render({
    subject: "Your OrdCat order isn't complete",
    preheader: `${name}${amount > 0 ? ` · ${money(amount, cur)}` : ""} · no payment was taken`,
    badge: "wait", icon: "!",
    title: "Your order isn't complete",
    subtitle: "The checkout ended before the payment went through.",
    greeting: "Hello,",
    intro: [`You started an order for ${name} on ${dayEn(Number(full.created ?? Date.now() / 1000))}, but the payment wasn't completed.`],
    amount: amount > 0 ? { main: money(amount, cur), per: iv === "year" ? "year" : iv === "month" ? "month" : undefined } : undefined,
    rows,
    body: [{ paras }],
    buttons: [{ label: "Complete payment", href: url, primary: true }],
    legal: [{
      title: "Seller",
      paras: [`${SELLER_NAME}, Hedemannstraße 74, 78355 Hohenfels, Germany · ${SUPPORT}.`],
      links: [{ label: "Terms", href: `${site}/terms.html` }, { label: "Withdrawal information", href: `${site}/widerruf.html` }],
    }],
  }, site);
  return { to: email, ...m, ...base };
}

Deno.serve(async (req) => {
  const raw = await req.text();
  if (!(await verify(raw, req.headers.get("Stripe-Signature") ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET")!))) {
    return new Response("bad signature", { status: 400 });
  }
  const ev = JSON.parse(raw);
  const obj = ev.data?.object ?? {};
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const prices: Record<string, string> = JSON.parse(Deno.env.get("STRIPE_PRICES") ?? "{}");
  const itemOfPrice = (id: string) => Object.entries(prices).find(([, v]) => v === id)?.[0]?.split(".")[0];
  // The price decides the plan (metadata.item stays at the first purchase after a switch in the Portal).
  const itemOfSub = (sub: any) => {
    const priceId = sub?.items?.data?.[0]?.price?.id ?? "";
    return itemOfPrice(priceId) ?? sub?.metadata?.item ?? "pro";
  };

  // The phase after the current one of a subscription's schedule = the change the user booked in the app.
  const pendingOf = async (sub: any) => {
    const none = { pending_plan: null, pending_interval: null, pending_at: null };
    const sid = idOf(sub?.schedule);
    if (!sid || sub.status === "canceled") return none;
    try {
      const sc = typeof sub.schedule === "object" && sub.schedule?.phases ? sub.schedule : await stripeGetOk(`subscription_schedules/${sid}`);
      if (!["not_started", "active"].includes(sc.status)) return none;
      const t = Date.now() / 1000;
      const next = (sc.phases ?? []).find((p: any) => Number(p.start_date) > t);
      const pid = idOf(next?.items?.[0]?.price);
      const item = pid ? itemOfPrice(pid) : undefined;
      if (!next || !item) return none;
      const key = Object.entries(prices).find(([, v]) => v === pid)?.[0] ?? "";
      return { pending_plan: item, pending_interval: key.split(".")[1] ?? null, pending_at: iso(Number(next.start_date)) };
    } catch (_) { return none; }
  };
  const saveSub = async (sub: any) => {
    const userId = sub.metadata?.user_id ?? null;
    const it = sub.items?.data?.[0];
    const priceId = it?.price?.id ?? "";
    const item = itemOfSub(sub);
    const periodEnd = sub.current_period_end ?? it?.current_period_end ?? null;   // newer API versions keep it on the item
    const base = {
      id: sub.id,
      user_id: userId,
      skill: item,
      status: sub.status,                       // active | trialing | past_due | canceled | unpaid | incomplete…
      renews_at: sub.cancel_at_period_end || sub.cancel_at ? null : iso(periodEnd),
      ends_at: sub.status === "canceled" ? iso(sub.ended_at ?? sub.canceled_at)
        : (sub.cancel_at ? iso(sub.cancel_at) : (sub.cancel_at_period_end ? iso(periodEnd) : null)),
      provider: "stripe",
      customer_id: typeof sub.customer === "string" ? sub.customer : sub.customer?.id,
      price_id: priceId,
      updated_at: new Date().toISOString(),
    };
    const extra = {                              // receipts.sql columns (app shows them)
      billing_interval: it?.price?.recurring?.interval ?? null,
      cancel_at_period_end: !!(sub.cancel_at_period_end || sub.cancel_at),
      amount_cents: it?.price?.unit_amount ?? null,
      currency: it?.price?.currency ?? null,
    };
    // plan_change.sql columns: a downgrade / switch to monthly booked for the end of the period (Subscription Schedule).
    const pend = await pendingOf(sub);
    let { error } = await admin.from("subscriptions").upsert({ ...base, ...extra, ...pend });
    if (error && /column|schema cache/i.test(error.message)) ({ error } = await admin.from("subscriptions").upsert({ ...base, ...extra }));
    if (error && /column|schema cache/i.test(error.message)) ({ error } = await admin.from("subscriptions").upsert(base));
    if (error) throw new Error(error.message);
    if (userId && (item === "pro" || item === "max")) await admin.rpc("ord_wallet_sync", { p_user: userId });
    return userId;
  };

  let failedSub: any = null;
  try {
    switch (ev.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const userId = obj.metadata?.user_id ?? obj.client_reference_id;
        if (obj.mode === "payment" && obj.metadata?.item === "fish") {
          // Paid now (card) or later (SEPA etc. → async_payment_succeeded). Same session id never adds twice.
          if (obj.payment_status === "paid" && userId) {
            const c = fishCredit(obj);
            const { error } = await admin.rpc("fish_topup", {
              p_session: obj.id, p_user: userId, p_fish: c.fish, p_cents: c.cents, p_pack: c.pack,
            });
            if (error) throw new Error(error.message);
          }
        } else if (ev.type === "checkout.session.async_payment_succeeded") {
          // only fish top-ups are handled here
        } else if (obj.mode === "payment" && obj.metadata?.item === "topup" && obj.payment_status === "paid" && userId) {
          await admin.rpc("credit_topup", { p_session: obj.id, p_user: userId, p_credits: Number(obj.metadata?.credits ?? 1500) });
        } else if (obj.mode === "subscription" && obj.subscription) {
          await saveSub(await stripeGet(`subscriptions/${idOf(obj.subscription)}`));
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await saveSub(obj);
        break;
      case "subscription_schedule.created":
      case "subscription_schedule.updated":
      case "subscription_schedule.released":
      case "subscription_schedule.canceled":
      case "subscription_schedule.completed":
      case "subscription_schedule.aborted": {
        // A booked plan change appeared / went away: refresh the row's pending_* columns from the subscription.
        const subId = idOf(obj.subscription) ?? idOf(obj.released_subscription);
        if (subId) await saveSub(await stripeGet(`subscriptions/${subId}`));
        break;
      }
      case "invoice.paid": {
        // A renewal: fresh month of credits.
        const subId = idOf(obj.subscription) ?? idOf(obj.parent?.subscription_details?.subscription);
        if (subId && obj.billing_reason === "subscription_cycle") {
          const uid = await saveSub(await stripeGet(`subscriptions/${subId}`));
          if (uid) await admin.rpc("credit_new_period", { p_user: uid });
        }
        break;
      }
      case "invoice.payment_failed": {
        // Renewal charge failed: the subscription goes past_due (Stripe retries); the app shows "update payment method".
        const subId = idOf(obj.subscription) ?? idOf(obj.parent?.subscription_details?.subscription);
        if (subId) {
          failedSub = await stripeGet(`subscriptions/${subId}`);
          if (failedSub?.id) await saveSub(failedSub);
        }
        break;
      }
    }
  } catch (e) {
    return new Response(String((e as Error).message ?? e), { status: 500 });
  }

  // Our own mails. Run only after the account was updated; never fail the webhook.
  try {
    let job: Promise<unknown> | null = null;
    if ((ev.type === "checkout.session.completed" || ev.type === "checkout.session.async_payment_succeeded") &&
        (obj.payment_status === "paid" || obj.payment_status === "no_payment_required") && typeof obj.id === "string") {
      job = sendOnce(admin, obj.id, "checkout",
        () => receiptMail(async () => (await receiptFromSession(obj.id)).r, obj.customer_details?.address?.country));
    } else if (ev.type === "invoice.paid" && obj.billing_reason === "subscription_cycle" && typeof obj.id === "string") {
      const subId = idOf(obj.subscription) ?? idOf(obj.parent?.subscription_details?.subscription);
      if (subId) {
        job = sendOnce(admin, obj.id, "renewal", () => receiptMail(async () => {
          const sub = await stripeGetOk(`subscriptions/${subId}?expand[]=default_payment_method`);
          return receiptFromInvoice(obj, sub, itemOfSub(sub));
        }, obj.customer_address?.country));
      }
    } else if (ev.type === "invoice.paid" && obj.billing_reason === "subscription_update" && typeof obj.id === "string") {
      // Plan switched (in the app via stripe-checkout) and charged now: "Plan upgraded" / "Plan changed" confirmation.
      const subId = idOf(obj.subscription) ?? idOf(obj.parent?.subscription_details?.subscription);
      if (subId) {
        job = sendOnce(admin, `upgrade:${obj.id}`, "upgrade", async () => {
          const sub = await stripeGetOk(`subscriptions/${subId}?expand[]=default_payment_method`);
          const r = await receiptFromInvoice(obj, sub, itemOfSub(sub));
          const pl = planLines(obj, itemOfPrice);
          return upgradeMail(r, sub, pl.old, pl.now);
        });
      }
    } else if (ev.type === "invoice.payment_failed" && typeof obj.id === "string" && obj.billing_reason !== "subscription_create") {
      // The first invoice failing is the customer still on Stripe's page; only renewals get a mail. One per invoice.
      const sub = failedSub;
      if (sub?.id) job = sendOnce(admin, `fail:${obj.id}`, "failed", async () => failedMail(obj, sub, itemOfSub(sub)));
    } else if (ev.type === "checkout.session.expired" && typeof obj.id === "string" &&
               obj.payment_status !== "paid" && obj.payment_status !== "no_payment_required") {
      // Unpaid order: one reminder per session (skipped when there's no user / email, or the same thing was bought since).
      job = sendOnce(admin, `unpaid:${obj.id}`, "unpaid", () => unpaidMail(admin, obj));
    } else if (ev.type === "customer.subscription.updated") {
      const prev = ev.data?.previous_attributes ?? {};
      const nowCancelling = !!(obj.cancel_at_period_end || obj.cancel_at);
      const wasCancelling = ("cancel_at_period_end" in prev ? !!prev.cancel_at_period_end : nowCancelling) ||
        ("cancel_at" in prev ? !!prev.cancel_at : false);
      const viaForm = !!obj.metadata?.cancel_request;            // cancel-contract already confirmed it
      if (nowCancelling && !wasCancelling && !viaForm && obj.status !== "canceled") {
        const end = Number(obj.cancel_at ?? subEnd(obj) ?? 0);
        job = sendOnce(admin, `cancel:${obj.id}:${end}`, "cancel", async () => {
          const c = idOf(obj.customer) ? await stripeGetOk(`customers/${idOf(obj.customer)}`) : null;
          return cancelMail(obj, itemOfSub(obj), c?.email ?? null, Number(ev.created ?? Date.now() / 1000));
        });
      }
    }
    if (job) await withTimeout(job, 9000);
  } catch (e) {
    console.error("mail", (e as Error).message);
  }
  return new Response("ok");
});

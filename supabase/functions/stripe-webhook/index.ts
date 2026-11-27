// Stripe → 订阅 / 加油包 / 小鱼干充值写进 OrdCat 账号，并发我们自己的邮件。
// 小鱼干充值：fish_topup(session id) 只加一次（重复的 webhook 不会多加），只有这里用 service_role 能调。
// Stripe 后台 → Developers → Webhooks → Add endpoint：
//   URL = https://<project>.supabase.co/functions/v1/stripe-webhook
//   事件：checkout.session.completed, checkout.session.async_payment_succeeded, customer.subscription.created, customer.subscription.updated,
//         customer.subscription.deleted, invoice.paid, invoice.payment_failed
// 部署：supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets：STRIPE_WEBHOOK_SECRET=whsec_…（同上 STRIPE_SECRET_KEY、STRIPE_PRICES）
//
// 订阅状态（subscriptions 表，App 读）：status = active | trialing | past_due（扣款失败，Stripe 自动重试中，会员照常）| canceled …；
//   cancel_at_period_end = true 表示已取消、当期结束；billing_interval = month | year；amount_cents / currency = 每期价格。
//   方案按价格 ID 认（STRIPE_PRICES），所以在 Portal 里 Pro ↔ Max、月付 ↔ 年付 换了以后也对；订阅删除（到期 / 扣款失败到底）→ canceled → 免费版。
//   新列在 receipts.sql 里；还没运行 receipts.sql 时自动只写旧列（会员照样生效）。
//
// 邮件（Resend，v0.2.64 起；语言按 metadata.lang：zh / en / de，非德语附德文）：
//   · 购买确认（BGB §312f Vertragsbestätigung）：checkout.session.completed / async_payment_succeeded，已付款时
//   · 续费收据：invoice.paid，billing_reason = subscription_cycle（首张发票 subscription_create 已由购买确认覆盖）
//   · 扣款失败：invoice.payment_failed（每张发票只发一次，Stripe 重试不再发）
//   · 取消确认：customer.subscription.updated 里 cancel_at_period_end / cancel_at 刚被设上（Portal 里取消）；
//     cancel-contract（ordcat.de/kuendigen.html）取消的已经由它自己发确认，这里不重复。
//   幂等：先在 receipt_emails（receipts.sql）占位再发；邮件出错只记日志，webhook 照样回 200。
//   Secrets：RESEND_API_KEY（没设就不发）、可选 CANCEL_MAIL_BCC / CANCEL_MAIL_FROM（和 cancel-contract 共用）、SITE_URL。
import { createClient } from "npm:@supabase/supabase-js@2";

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
const SELLER = "Axun Conor (OrdCat) · Hedemannstraße 74 · 78355 Hohenfels · Deutschland · support@ordcat.de";

const ITEM_NAME: Record<string, string> = {
  pro: "OrdCat Pro", max: "OrdCat Max", topup: "OrdCat Top-up", x: "OrdCat X Companion",
  agent: "OrdCat Mac Agent", miao: "OrdCat Live Subtitles", fish: "OrdCat Dried Fish",
};
const ZH_NAME: Record<string, string> = {
  pro: "Pro 会员", max: "Max 会员", topup: "加油包", x: "喵推（X Companion）技能", agent: "喵手（Mac Agent）技能",
  miao: "喵传（Live Subtitles）技能", fish: "小鱼干",
};
const isDigital = (item: string | null) => item === "fish" || item === "topup";

const escH = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const locOf = (l: Lang) => (l === "zh" ? "zh-CN" : l === "en" ? "en-GB" : "de-DE");
const money = (c: number, cur: string, l: Lang) =>
  new Intl.NumberFormat(locOf(l), { style: "currency", currency: cur.toUpperCase() }).format(c / 100);
const when = (t: number, l: Lang) => {
  if (l === "zh") {
    const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Berlin", year: "numeric", month: "2-digit",
      day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(t * 1000)).map((x) => [x.type, x.value]));
    return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}（德国时间）`;
  }
  return new Intl.DateTimeFormat(locOf(l), {
    timeZone: "Europe/Berlin", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
    hour12: false, timeZoneName: "short",
  }).format(new Date(t * 1000));
};
const day = (t: number, l: Lang) =>
  new Intl.DateTimeFormat(l === "zh" ? "en-CA" : locOf(l), { timeZone: "Europe/Berlin", year: "numeric", month: "2-digit", day: "2-digit" })
    .format(new Date(t * 1000));                       // zh: 2026-12-27

function productLine(r: Receipt, l: Lang): string {
  const it = r.items[0];
  const base = l === "zh" && r.item && ZH_NAME[r.item] ? `${ZH_NAME[r.item]}（${it?.name ?? ITEM_NAME[r.item]}）`
    : (it?.name ?? (r.item ? ITEM_NAME[r.item] : "OrdCat"));
  if (r.fish) return l === "zh" ? `${base} · ${r.fish} 条小鱼干` : l === "en" ? `${base} · ${r.fish} Dried Fish` : `${base} · ${r.fish} Trockenfisch`;
  const iv = it?.interval;
  if (!iv) return base;
  const per = {
    de: { month: "monatliches Abonnement", year: "jährliches Abonnement" },
    zh: { month: "按月订阅", year: "按年订阅" },
    en: { month: "monthly subscription", year: "yearly subscription" },
  }[l][iv as "month" | "year"] ?? iv;
  return `${base} · ${per}`;
}

function payLine(r: Receipt): string | null {
  const p = r.payment_method;
  if (!p) return null;
  const b = p.brand.charAt(0).toUpperCase() + p.brand.slice(1);
  return (p.wallet ? `${p.wallet.replace(/_/g, " ")} · ` : "") + b + (p.last4 ? ` •••• ${p.last4}` : "");
}

function mailBlock(l: Lang, r: Receipt): string[] {
  const renewal = r.kind === "renewal";
  const sub = r.mode === "subscription";
  const iv = r.items[0]?.interval;
  const price = money(r.amount_total, r.currency, l);
  const taxTxt = r.amount_tax != null
    ? { de: `inkl. ${money(r.amount_tax, r.currency, l)} MwSt.`, zh: `含增值税 ${money(r.amount_tax, r.currency, l)}`, en: `incl. ${money(r.amount_tax, r.currency, l)} VAT` }[l]
    : { de: "inkl. MwSt.", zh: "已含增值税", en: "VAT included (inkl. MwSt.)" }[l];
  const T = {
    de: {
      head: renewal ? "Ihr Abonnement wurde verlängert" : "Vertragsbestätigung Ihrer Bestellung",
      intro: renewal ? "Ihr OrdCat-Abonnement wurde planmäßig verlängert; die Zahlung ist eingegangen:"
        : "vielen Dank für Ihre Bestellung. Hiermit bestätigen wir den Vertragsschluss mit folgendem Inhalt:",
      seller: "Verkäufer", ref: renewal ? "Rechnung" : "Bestellnummer", date: "Datum", item: "Leistung", price: "Preis",
      pay: "Zahlungsart", acct: "E-Mail",
      yearly: (y: NonNullable<Receipt["yearly"]>) => `Regulär ${money(y.regular, r.currency, l)}/Jahr (${money(y.monthly, r.currency, l)} × 12 Monate), Rabatt bei jährlicher Zahlung −${money(y.discount, r.currency, l)}, Sie zahlen ${money(y.paid, r.currency, l)}/Jahr.`,
      renew: (d: string) => `Das Abonnement verlängert sich automatisch um jeweils ${iv === "year" ? "ein Jahr" : "einen Monat"} zum Preis von ${price} (${taxTxt}), bis Sie es kündigen. Nächste Verlängerung: ${d}.`,
      ends: (d: string) => `Das Abonnement ist gekündigt und endet am ${d}.`,
      cancel: "Kündigen können Sie jederzeit zum Ende des laufenden Zeitraums: in der OrdCat-App unter Einstellungen → Benutzer (User) → Mitgliedschaft verwalten (Manage membership) oder ohne Anmeldung unter " + SITE() + "/kuendigen.html („Verträge hier kündigen“).",
      consentDigital: "Ihre Zustimmung beim Bezahlen: Sie haben den Nutzungsbedingungen zugestimmt, ausdrücklich verlangt, dass wir vor Ablauf der Widerrufsfrist mit der Vertragserfüllung beginnen, und bestätigt, dass Sie wissen, dass Sie Ihr Widerrufsrecht mit Beginn der Vertragserfüllung (Gutschrift in Ihrem Konto) verlieren (§ 356 Abs. 6 BGB). Die Gutschrift ist erfolgt.",
      consentService: "Ihre Zustimmung beim Bezahlen: Sie haben den Nutzungsbedingungen zugestimmt und ausdrücklich verlangt, dass wir vor Ablauf der Widerrufsfrist mit der Leistung beginnen. Widerrufen Sie innerhalb von 14 Tagen, zahlen Sie den anteiligen Betrag für die bis dahin genutzten Tage (§ 357a Abs. 2 BGB); Ihr Widerrufsrecht erlischt mit vollständiger Erbringung der Leistung (§ 356 Abs. 5 BGB).",
      links: "Nutzungsbedingungen", wd: "Widerrufsbelehrung", online: "Online-Beleg", rcpt: "Zahlungsbeleg (Stripe)", inv: "Rechnung",
      wdNow: "Vertrag widerrufen",
    },
    zh: {
      head: renewal ? "订阅已续费" : "订单确认",
      intro: renewal ? "你的 OrdCat 订阅已按期续费，款项已收到：" : "谢谢你的购买！合同已成立，内容如下：",
      seller: "卖家", ref: renewal ? "发票" : "订单号", date: "时间", item: "商品", price: "金额",
      pay: "付款方式", acct: "邮箱",
      yearly: (y: NonNullable<Receipt["yearly"]>) => `原价 ${money(y.regular, r.currency, l)}/年（${money(y.monthly, r.currency, l)} × 12 个月），年付优惠 −${money(y.discount, r.currency, l)}，实付 ${money(y.paid, r.currency, l)}/年。`,
      renew: (d: string) => `订阅会每${iv === "year" ? "年" : "月"}按 ${price}（${taxTxt}）自动续费，直到你取消。下次续费：${d}。`,
      ends: (d: string) => `订阅已取消，将于 ${d} 结束。`,
      cancel: "随时可以取消，当期结束前照常使用：在 OrdCat 里打开 设置 → 用户 → 管理会员，或者不用登录直接打开 " + SITE() + "/kuendigen.html（Verträge hier kündigen）。",
      consentDigital: "你付款时的同意：你同意了用户协议，明确要求我们在撤回期结束前开始履行合同，并确认知道一旦开始履行（加到你的账户）就失去撤回权（德国民法典 §356 第 6 款）。现在已经加到你的账户。",
      consentService: "你付款时的同意：你同意了用户协议，并明确要求我们在撤回期结束前就开始提供服务。14 天内撤回的话，需要按已使用的天数付费（德国民法典 §357a 第 2 款）；服务全部履行完毕后撤回权失效（§356 第 5 款）。",
      links: "用户协议", wd: "撤回说明", online: "在线结算单", rcpt: "Stripe 收据", inv: "发票",
      wdNow: "撤回合同",
    },
    en: {
      head: renewal ? "Your subscription has renewed" : "Your order confirmation",
      intro: renewal ? "Your OrdCat subscription renewed as scheduled and we received your payment:"
        : "thank you for your order. This confirms your contract with the following content:",
      seller: "Seller", ref: renewal ? "Invoice" : "Order number", date: "Date", item: "Item", price: "Price",
      pay: "Payment method", acct: "Email",
      yearly: (y: NonNullable<Receipt["yearly"]>) => `Regular price ${money(y.regular, r.currency, l)}/year (${money(y.monthly, r.currency, l)} × 12 months), yearly discount −${money(y.discount, r.currency, l)}, you pay ${money(y.paid, r.currency, l)}/year.`,
      renew: (d: string) => `Your subscription renews automatically every ${iv === "year" ? "year" : "month"} at ${price} (${taxTxt}) until you cancel. Next renewal: ${d}.`,
      ends: (d: string) => `Your subscription is cancelled and ends on ${d}.`,
      cancel: "You can cancel anytime, effective at the end of the current period: in OrdCat under Settings → User → Manage membership, or without signing in at " + SITE() + "/kuendigen.html (“Verträge hier kündigen”).",
      consentDigital: "What you agreed to at checkout: you accepted the Terms, expressly asked us to start before the withdrawal period ends, and acknowledged that you lose your right of withdrawal once performance begins (the credit to your account) (section 356(6) German Civil Code). The credit has been made.",
      consentService: "What you agreed to at checkout: you accepted the Terms and expressly asked us to start the service before the withdrawal period ends. If you withdraw within 14 days, you pay pro rata for the days used (section 357a(2) German Civil Code); your right of withdrawal ends once the service has been fully provided (section 356(5)).",
      links: "Terms", wd: "Withdrawal information", online: "Online receipt", rcpt: "Stripe receipt", inv: "Invoice",
      wdNow: "Withdraw from the contract",
    },
  }[l];
  const out: string[] = [T.head, "", T.intro];
  const c = l === "zh" ? "：" : ": ";
  out.push(`${T.seller}${c}${SELLER}`);
  out.push(`${T.ref}${c}${renewal ? (r.invoice_number ?? r.id) : r.id}`);
  out.push(`${T.date}${c}${when(r.created, l)}`);
  out.push(`${T.item}${c}${productLine(r, l)}`);
  out.push(`${T.price}${c}${price}${l === "zh" ? `（${taxTxt}）` : ` (${taxTxt})`}`);
  const pl = payLine(r);
  if (pl) out.push(`${T.pay}${c}${pl}`);
  if (r.email) out.push(`${T.acct}${c}${r.email}`);
  if (r.yearly) out.push("", T.yearly(r.yearly));
  if (sub) {
    out.push("");
    if (r.renews_at) out.push(T.renew(day(r.renews_at, l)));
    else if (r.ends_at) out.push(T.ends(day(r.ends_at, l)));
    out.push(T.cancel);
  }
  if (!renewal) out.push("", isDigital(r.item) ? T.consentDigital : T.consentService);
  out.push("");
  out.push(`${T.links}${c}${SITE()}/terms.html`);
  out.push(`${T.wd}${c}${SITE()}/widerruf.html`);
  if (!renewal) out.push(`${T.wdNow}${c}${SITE()}/widerruf.html#widerrufen`);
  if (!renewal) out.push(`${T.online}${c}${SITE()}/thanks.html?session_id=${r.id}`);
  if (r.receipt_url) out.push(`${T.rcpt}${c}${r.receipt_url}`);
  if (r.invoice_url) out.push(`${T.inv}${c}${r.invoice_url}`);
  return out;
}

// Widerrufsbelehrung as on ordcat.de/widerruf.html (Stand 27.11.2026), on a durable medium with the first confirmation.
const WIDERRUF_DE = [
  "Widerrufsbelehrung",
  "",
  "Widerrufsrecht",
  "Sie haben das Recht, binnen vierzehn Tagen ohne Angabe von Gründen diesen Vertrag zu widerrufen. Die Widerrufsfrist beträgt vierzehn Tage ab dem Tag des Vertragsabschlusses.",
  "Um Ihr Widerrufsrecht auszuüben, müssen Sie uns (Axun Conor, Hedemannstraße 74, 78355 Hohenfels, Deutschland, E-Mail: support@ordcat.de) mittels einer eindeutigen Erklärung (z. B. ein mit der Post versandter Brief oder eine E-Mail) über Ihren Entschluss, diesen Vertrag zu widerrufen, informieren. Sie können dafür das beigefügte Muster-Widerrufsformular verwenden, das jedoch nicht vorgeschrieben ist.",
  "Sie können Ihr Widerrufsrecht auch online unter https://ordcat.de/widerruf.html#widerrufen („Vertrag widerrufen“) ausüben. Wenn Sie diese Online-Funktion nutzen, übermitteln wir Ihnen auf einem dauerhaften Datenträger (z. B. durch eine E-Mail) unverzüglich eine Eingangsbestätigung mit Informationen zum Inhalt der Widerrufserklärung sowie dem Datum und der Uhrzeit ihres Eingangs.",
  "Zur Wahrung der Widerrufsfrist reicht es aus, dass Sie die Mitteilung über die Ausübung des Widerrufsrechts vor Ablauf der Widerrufsfrist absenden.",
  "",
  "Folgen des Widerrufs",
  "Wenn Sie diesen Vertrag widerrufen, haben wir Ihnen alle Zahlungen, die wir von Ihnen erhalten haben, unverzüglich und spätestens binnen vierzehn Tagen ab dem Tag zurückzuzahlen, an dem die Mitteilung über Ihren Widerruf dieses Vertrags bei uns eingegangen ist. Für diese Rückzahlung verwenden wir dasselbe Zahlungsmittel, das Sie bei der ursprünglichen Transaktion eingesetzt haben, es sei denn, mit Ihnen wurde ausdrücklich etwas anderes vereinbart; in keinem Fall werden Ihnen wegen dieser Rückzahlung Entgelte berechnet.",
  "Haben Sie verlangt, dass die Dienstleistungen während der Widerrufsfrist beginnen sollen, so haben Sie uns einen angemessenen Betrag zu zahlen, der dem Anteil der bis zu dem Zeitpunkt, zu dem Sie uns von der Ausübung des Widerrufsrechts hinsichtlich dieses Vertrags unterrichten, bereits erbrachten Dienstleistungen im Vergleich zum Gesamtumfang der im Vertrag vorgesehenen Dienstleistungen entspricht.",
  "",
  "Besondere Hinweise zum vorzeitigen Erlöschen des Widerrufsrechts",
  "Digitale Inhalte (Trockenfisch-Pakete, Aufladungen „Top-up“): Ihr Widerrufsrecht erlischt, wenn wir mit der Vertragserfüllung begonnen haben (Gutschrift in Ihrem Konto), nachdem Sie 1. ausdrücklich zugestimmt haben, dass wir mit der Vertragserfüllung vor Ablauf der Widerrufsfrist beginnen, 2. Ihre Kenntnis davon bestätigt haben, dass Sie durch Ihre Zustimmung mit Beginn der Vertragserfüllung Ihr Widerrufsrecht verlieren, und 3. wir Ihnen eine Bestätigung gemäß § 312f BGB zur Verfügung gestellt haben (§ 356 Abs. 6 BGB).",
  "Dienstleistungen (Mitgliedschaften Pro und Max, Skill-Abonnements X Companion, Mac Agent und Live Subtitles): Haben Sie verlangt, dass wir sofort mit der Leistung beginnen, und widerrufen Sie innerhalb von 14 Tagen, zahlen Sie den anteiligen Betrag für die bis zum Widerruf genutzten Tage; den übrigen Betrag erstatten wir (§ 357a Abs. 2 BGB). Ihr Widerrufsrecht erlischt mit der vollständigen Erbringung der Dienstleistung, wenn Sie vor Beginn ausdrücklich zugestimmt haben, dass wir vor Ablauf der Widerrufsfrist beginnen, und Ihre Kenntnis davon bestätigt haben, dass Ihr Widerrufsrecht mit vollständiger Vertragserfüllung erlischt (§ 356 Abs. 5 BGB).",
  "Widerruf und Kündigung sind verschiedene Erklärungen. Um die Verlängerung eines Abonnements zu beenden, nutzen Sie „Verträge hier kündigen“ (https://ordcat.de/kuendigen.html).",
  "Ende der Widerrufsbelehrung",
  "",
  "Muster-Widerrufsformular",
  "(Wenn Sie den Vertrag widerrufen wollen, dann füllen Sie bitte dieses Formular aus und senden Sie es zurück.)",
  "– An Axun Conor, Hedemannstraße 74, 78355 Hohenfels, Deutschland, E-Mail: support@ordcat.de:",
  "– Hiermit widerrufe(n) ich/wir (*) den von mir/uns (*) abgeschlossenen Vertrag über den Kauf der folgenden Waren (*)/die Erbringung der folgenden Dienstleistung (*)",
  "– Bestellt am (*)/erhalten am (*)",
  "– Name des/der Verbraucher(s)",
  "– Anschrift des/der Verbraucher(s)",
  "– Unterschrift des/der Verbraucher(s) (nur bei Mitteilung auf Papier)",
  "– Datum",
  "(*) Unzutreffendes streichen.",
];

const GREET: Record<Lang, string> = { de: "Guten Tag,", zh: "你好，", en: "Hello," };

function buildMail(lang: Lang, r: Receipt) {
  const de = mailBlock("de", r);
  const other = lang === "de" ? [] : mailBlock(lang, r);
  const withGreet = (b: string[], l: Lang) => [GREET[l], ...b.slice(2)];
  const wd = r.kind === "checkout" ? WIDERRUF_DE : [];
  const deTitle = `${de[0]}${lang === "de" ? "" : " (Deutsche Fassung, maßgeblich)"}`;
  const textParts = lang === "de"
    ? [withGreet(de, "de").join("\n")]
    : [withGreet(other, lang).join("\n"), `— ${deTitle} —\n` + withGreet(de, "de").join("\n")];
  if (wd.length) textParts.push(wd.join("\n"));
  const text = textParts.join("\n\n") + "\n\n" + SELLER;
  const linkify = (s: string) => escH(s).replace(/https:\/\/[^\s<]+[^\s<.,;)）]/g, (u) => `<a href="${u}" style="color:#c98400">${u}</a>`);
  const para = (lines: string[]) =>
    `<p style="margin:0 0 14px">${lines.map(linkify).join("<br>").replace(/(<br>){2,}/g, "</p><p style=\"margin:0 0 14px\">")}</p>`;
  const html = `<!doctype html><html><body style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;color:#18181c;max-width:620px;margin:0 auto;padding:24px">
<h2 style="margin:0 0 16px;color:#c98400">${escH(lang === "de" ? de[0] : other[0])}</h2>
${lang === "de" ? para(withGreet(de, "de")) : para(withGreet(other, lang)) + `<hr style="border:0;border-top:1px solid #e6e3dc;margin:24px 0"><h3 style="margin:0 0 12px">${escH(deTitle)}</h3>` + para(withGreet(de, "de"))}
${wd.length ? `<hr style="border:0;border-top:1px solid #e6e3dc;margin:24px 0"><div style="font-size:13px;color:#3d3f48">${para(wd)}</div>` : ""}
<p style="color:#5f6270;font-size:12px;margin-top:28px">${escH(SELLER)}</p></body></html>`;
  const subject = lang === "de" ? `${de[0]} · OrdCat` : `${other[0]} · ${de[0]} · OrdCat`;
  return { subject, html, text };
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

const EUROPE_DE = ["DE", "AT", "CH", "LI", "LU"];
const langOf = (meta: unknown, country?: string | null): Lang =>
  meta === "zh" || meta === "de" || meta === "en" ? meta : (country && EUROPE_DE.includes(country.toUpperCase()) ? "de" : "en");

type Mail = { to: string | null; lang: Lang; subject: string; html: string; text: string; item: string | null; user_id: string | null; skip?: string };

// Short notice (payment failed / cancellation): localized text, plus the German text when the mail isn't German.
function shortMail(lang: Lang, block: (l: Lang) => { head: string; lines: string[] }, to: string | null, item: string | null, user_id: string | null): Mail {
  const de = block("de");
  const loc = lang === "de" ? null : block(lang);
  const linkify = (s: string) => escH(s).replace(/https:\/\/[^\s<]+[^\s<.,;)）]/g, (u) => `<a href="${u}" style="color:#c98400">${u}</a>`);
  const para = (lines: string[]) =>
    `<p style="margin:0 0 14px">${lines.map(linkify).join("<br>").replace(/(<br>){2,}/g, "</p><p style=\"margin:0 0 14px\">")}</p>`;
  const main = loc ?? de;
  const text = [[GREET[lang], ...main.lines].join("\n"),
    ...(loc ? [`— ${de.head} (Deutsche Fassung) —\n` + ["Guten Tag,", ...de.lines].join("\n")] : []), SELLER].join("\n\n");
  const html = `<!doctype html><html><body style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;color:#18181c;max-width:620px;margin:0 auto;padding:24px">
<h2 style="margin:0 0 16px;color:#c98400">${escH(main.head)}</h2>${para([GREET[lang], ...main.lines])}
${loc ? `<hr style="border:0;border-top:1px solid #e6e3dc;margin:24px 0"><h3 style="margin:0 0 12px">${escH(de.head)} (Deutsche Fassung)</h3>` + para(["Guten Tag,", ...de.lines]) : ""}
<p style="color:#5f6270;font-size:12px;margin-top:28px">${escH(SELLER)}</p></body></html>`;
  return { to, lang, subject: loc ? `${loc.head} · ${de.head} · OrdCat` : `${de.head} · OrdCat`, html, text, item, user_id };
}

const nameFor = (item: string | null, l: Lang) =>
  l === "zh" && item && ZH_NAME[item] ? ZH_NAME[item] : (item && ITEM_NAME[item] ? ITEM_NAME[item] : "OrdCat");

function failedMail(inv: any, sub: any, item: string | null): Mail {
  const lang = langOf(sub?.metadata?.lang, inv.customer_address?.country);
  const amount = Number(inv.amount_due ?? inv.total ?? 0), cur = String(inv.currency ?? "eur");
  const payUrl = inv.hosted_invoice_url as string | undefined;
  const block = (l: Lang) => ({
    de: {
      head: "Zahlung fehlgeschlagen",
      lines: [`die Verlängerung von ${nameFor(item, l)} (${money(amount, cur, l)}) konnte nicht abgebucht werden.`,
        "Wir versuchen es in den nächsten Tagen automatisch erneut; bis dahin bleibt Ihr Abonnement aktiv.",
        "Bitte aktualisieren Sie Ihre Zahlungsart: in der OrdCat-App unter Einstellungen → Benutzer (User) → „Update payment method“" + (payUrl ? `, oder bezahlen Sie die Rechnung direkt: ${payUrl}` : "."),
        "Gelingt keine Zahlung, endet das Abonnement und Ihr Konto wechselt zur kostenlosen Version."],
    },
    zh: {
      head: "续费扣款没有成功",
      lines: [`${nameFor(item, l)} 这次续费（${money(amount, cur, l)}）没有扣款成功。`,
        "接下来几天我们会自动重试，期间会员照常可用。",
        "请更新付款方式：在 OrdCat 里打开 设置 → 用户 →「更新付款方式」" + (payUrl ? `，或者直接在这里付款：${payUrl}` : "。"),
        "如果一直扣款失败，订阅会结束，账号回到免费版。"],
    },
    en: {
      head: "Your payment didn't go through",
      lines: [`We couldn't charge the renewal of ${nameFor(item, l)} (${money(amount, cur, l)}).`,
        "We'll retry automatically over the next few days, and your plan stays active in the meantime.",
        "Please update your payment method: in OrdCat, open Settings → User → Update payment method" + (payUrl ? `, or pay the invoice here: ${payUrl}` : "."),
        "If no payment succeeds, the subscription ends and your account goes back to Free."],
    },
  })[l];
  return shortMail(lang, block, inv.customer_email ?? null, item, sub?.metadata?.user_id ?? null);
}

function cancelMail(sub: any, item: string | null, email: string | null, at: number): Mail {
  const lang = langOf(sub?.metadata?.lang, null);
  const end = Number(sub.cancel_at ?? subEnd(sub) ?? 0);
  const recv = Number(sub.canceled_at ?? at);
  const block = (l: Lang) => ({
    de: {
      head: "Bestätigung Ihrer Kündigung",
      lines: [`Ihre Kündigung von ${nameFor(item, l)} ist am ${when(recv, l)} eingegangen.`,
        end ? `Das Abonnement endet am ${day(end, l)}. Bis dahin können Sie es weiter nutzen; es wird nicht mehr verlängert.` : "Das Abonnement wird nicht mehr verlängert.",
        "Es sich anders überlegt? Bis zum Ende können Sie es in der OrdCat-App unter Einstellungen → Benutzer (User) → „Resume subscription“ wieder aufnehmen.",
        `Referenz: ${sub.id}`],
    },
    zh: {
      head: "已取消订阅",
      lines: [`我们在 ${when(recv, l)} 收到了你取消 ${nameFor(item, l)} 的操作。`,
        end ? `订阅将于 ${day(end, l)} 结束，在此之前照常使用，不会再续费。` : "订阅不会再续费。",
        "改主意了？结束前在 OrdCat 里打开 设置 → 用户 →「恢复订阅」就行。",
        `编号：${sub.id}`],
    },
    en: {
      head: "Your cancellation is confirmed",
      lines: [`We received your cancellation of ${nameFor(item, l)} on ${when(recv, l)}.`,
        end ? `Your subscription ends on ${day(end, l)}. You can keep using it until then; it won't renew.` : "Your subscription won't renew.",
        "Changed your mind? Before it ends, open OrdCat → Settings → User → Resume subscription.",
        `Reference: ${sub.id}`],
    },
  })[l];
  return shortMail(lang, block, email, item, sub?.metadata?.user_id ?? null);
}

async function receiptMail(load: () => Promise<Receipt>, country?: string | null): Promise<Mail> {
  const r = await load();
  const lang = langOf(r.lang, country);
  const m = buildMail(lang, r);
  return { to: r.email, lang, ...m, item: r.item, user_id: r.user_id, skip: r.paid ? undefined : "not paid" };
}

/** Claim (receipt_emails) → build → send → mark. One mail per id, ever. Never throws. */
async function sendOnce(admin: any, id: string, kind: "checkout" | "renewal" | "failed" | "cancel", build: () => Promise<Mail>) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return "no_key";                         // nothing claimed, so a later redelivery can still send it
  let claimed = false;
  try {
    const { data, error } = await admin.from("receipt_emails")
      .upsert({ id, kind, status: "sending" }, { onConflict: "id", ignoreDuplicates: true }).select("id");
    if (error) { console.error("receipt_emails claim", error.message); return "no_table"; }   // don't risk duplicates
    if (!data?.length) return "duplicate";
    claimed = true;
    const m = await build();
    let uid: string | null = m.user_id && /^[0-9a-f-]{36}$/i.test(m.user_id) ? m.user_id : null;
    if (!m.to || m.skip) {
      await admin.from("receipt_emails").update({ status: "skipped", item: m.item, lang: m.lang, error: m.skip ?? "no email" }).eq("id", id);
      return "skipped";
    }
    const bcc = Deno.env.get("CANCEL_MAIL_BCC");
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "Idempotency-Key": `ordcat-${id}`.slice(0, 256) },
      body: JSON.stringify({
        from: Deno.env.get("CANCEL_MAIL_FROM") ?? "OrdCat <noreply@ordcat.de>",
        to: [m.to], ...(bcc ? { bcc: [bcc] } : {}), reply_to: "support@ordcat.de",
        subject: m.subject, html: m.html, text: m.text,
      }),
    });
    const err = res.ok ? null : (await res.text()).slice(0, 400);
    const upd = { status: res.ok ? "sent" : "failed", item: m.item, lang: m.lang, error: err, sent_at: res.ok ? new Date().toISOString() : null, user_id: uid };
    let { error: e2 } = await admin.from("receipt_emails").update(upd).eq("id", id);
    if (e2 && uid) { uid = null; ({ error: e2 } = await admin.from("receipt_emails").update({ ...upd, user_id: null }).eq("id", id)); }
    if (e2) console.error("receipt_emails update", e2.message);
    return res.ok ? "sent" : "failed";
  } catch (e) {
    console.error("mail", (e as Error).message);
    if (claimed) {
      try { await admin.from("receipt_emails").update({ status: "failed", error: String((e as Error).message).slice(0, 400) }).eq("id", id); } catch (_) { /* ignore */ }
    }
    return "error";
  }
}

function withTimeout(p: Promise<unknown>, ms: number) {
  return Promise.race([p, new Promise((res) => setTimeout(res, ms))]);
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
    let { error } = await admin.from("subscriptions").upsert({ ...base, ...extra });
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
            const fish = Number(obj.metadata?.fish ?? 0);
            if (!(fish > 0)) throw new Error("fish top-up without amount");
            const { error } = await admin.rpc("fish_topup", {
              p_session: obj.id, p_user: userId, p_fish: fish,
              p_cents: Number(obj.metadata?.cents ?? obj.amount_subtotal ?? 0), p_pack: String(obj.metadata?.pack ?? ""),
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
    } else if (ev.type === "invoice.payment_failed" && typeof obj.id === "string" && obj.billing_reason !== "subscription_create") {
      // The first invoice failing is the customer still on Stripe's page; only renewals get a mail. One per invoice.
      const sub = failedSub;
      if (sub?.id) job = sendOnce(admin, `fail:${obj.id}`, "failed", async () => failedMail(obj, sub, itemOfSub(sub)));
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

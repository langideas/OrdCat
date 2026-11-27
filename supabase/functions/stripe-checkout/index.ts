// OrdCat · 开通会员 / 买加油包 / 管理订阅（Stripe Checkout + Customer Portal）。
// App 带着登录 token 调用：POST /functions/v1/stripe-checkout
//   {"item":"pro","interval":"month"|"year"}      Pro  €9.9/月，年付 €95
//   {"item":"max","interval":"month"|"year"}      Max  €59/月，年付 €566（技能另买，8 折）
//   {"item":"topup"}                              加油包 €2.99 = 1500 条（一次性付款）
//   {"item":"x"} / {"item":"agent"} / {"item":"miao"}   技能订阅 €3/月；Pro / Max 用 8 折价（x.month.member…）
//   {"item":"fish","pack":"5"|"10"|"30"|"100"}   小鱼干充值（一次性付款）：€5 = 500，€10 = 1050，€30 = 3300，€100 = 11500
//   {"item":"fish","amount_eur":N}               自定义金额：整欧元 €5 – €10,000，1 € = 100 条，≥ €10 +5%，≥ €30 +10%，≥ €100 +15%（向下取整）；
//                                                price_data 临时价格（含税 tax_behavior=inclusive），条数由服务器算好放进 metadata[fish]
// 所有 Checkout Session 都开 after_expiration[recovery]：过期没付的单，stripe-webhook 收到 checkout.session.expired 后
// 发一封「Your OrdCat order isn't complete」提醒（只一次，带 Stripe 的恢复链接，约 30 天有效）。过期时间仍用 Stripe 默认。
//   {"portal":true}                              管理订阅 / 取消 / 换卡（Stripe Customer Portal）
//   {"portal":true,"flow":"payment"}             付款失败（past_due）→ 直接打开「更新付款方式」
//   {"portal":true,"flow":"cancel","item":"pro"} 直接打开「取消订阅」确认页（当期结束时生效）
// 已经有 Pro / Max 的 Stripe 订阅时，不开第二个 Checkout，也不再走 Portal 换方案（v0.2.64 起 App 里确认后由这里直接改）：
//   {"item":"max","interval":"year","preview":true}  → {"kind":"upgrade"|"downgrade"|"none","today_cents","next_cents","next_at","effective_at","current":{…}}
//   {"item":"max","interval":"year"}                 → 升级（更高方案，或同方案月付 → 年付）：马上生效，新计费周期从今天开始
//       （billing_cycle_anchor=now，proration_behavior=always_invoice，旧方案没用完的部分抵扣，差价立刻从已存的卡扣；
//        payment_behavior=pending_if_incomplete：没付成功前订阅不变）→ {"changed":"upgraded"}；
//        需要 3-D Secure / 卡被拒 → {"changed":"pending_payment","url":发票付款页}
//                                                    → 降级（Max → Pro，或年付 → 月付）：Subscription Schedule，当期结束时换，不退差价
//        → {"changed":"scheduled","effective_at"}，并发「Plan change scheduled」邮件（receipt_emails key sched:sub_sched_…）
//       同方案同周期 → {"changed":"none"}；同时只有一个预约，升级会取消之前预约的降级。
//   {"cancel_change":true}                           → 撤销预约的降级（release schedule）
//   扣款失败（past_due）时先去 Portal 换卡（reason pay_first）。技能已经有时返回普通 Portal（reason current）。
//   Portal（{"portal":true}）只管换卡 / 取消 / 发票：{"url","portal":true,"reason":"manage"|"payment"|"cancel"}。
// 年付方案在 Stripe 页面「付款」按钮下显示原价 / 年付优惠 / 实付（custom_text[submit]，不用优惠券）。
// 返回 {"url":"https://checkout.stripe.com/…","id":"cs_…"}，App 用浏览器打开；付完跳到 ordcat.de/thanks.html?session_id=cs_…（结算单，
// 由 checkout-receipt 读取），返回 / 取消跳到 thanks.html?session_id=cs_…&cancelled=1（订单未完成，没有扣款）。App 用 id 打开同一张结算单。
//
// 部署：supabase functions deploy stripe-checkout
// Secrets：
//   STRIPE_SECRET_KEY=sk_live_…
//   STRIPE_PRICES='{"pro.month":"price_…","pro.year":"price_…","max.month":"price_…","max.year":"price_…",
//                   "topup":"price_…","x.month":"price_…","agent.month":"price_…","miao.month":"price_…",
//                   "x.month.member":"price_…","agent.month.member":"price_…","miao.month.member":"price_…"}'
//   （*.member = 会员 8 折价 €2.4；没填就用原价）
//   小鱼干充值包的价格：STRIPE_PRICES 里加 "fish.5"、"fish.10"、"fish.30"、"fish.100"（Stripe 一次性价格 €5 / €10 / €30 / €100）。
//   还没建 Stripe 商品时可以设 STRIPE_FISH_INLINE=1，按下面 FISH_PACKS 的金额直接建临时价格（不推荐长期用）。
//   TOPUP_CREDITS=1500
//   SITE_URL=https://ordcat.de
import { createClient } from "npm:@supabase/supabase-js@2";
import { dayEn, type MailOut, money, render, type Row, SELLER_NAME, sendOnce, SUPPORT } from "../_shared/mail.ts";
import { customEur, FISH_CUSTOM_MAX, FISH_CUSTOM_MIN, fishForEur } from "../_shared/fish.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type" };
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function stripe(path: string, params?: Record<string, string>, method: "GET" | "POST" = "POST") {
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    method,
    headers: {
      Authorization: `Bearer ${Deno.env.get("STRIPE_SECRET_KEY")}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: method === "POST" ? new URLSearchParams(params ?? {}) : undefined,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `Stripe ${r.status}`);
  return j;
}

// Subscription states that still hold the plan / skill (a new checkout would create a second subscription).
const LIVE = ["active", "trialing", "past_due", "unpaid", "incomplete"];

// 小鱼干充值包（服务器说了算，不信 App 传来的数量）。1 € = 100 条，大包多送。
const FISH_PACKS: Record<string, { fish: number; cents: number }> = {
  "5": { fish: 500, cents: 500 },
  "10": { fish: 1050, cents: 1000 },
  "30": { fish: 3300, cents: 3000 },
  "100": { fish: 11500, cents: 10000 },
};

// Pflicht-Häkchen auf der Stripe-Seite (AGB + sofortiger Beginn + Wissen um Verlust / anteilige Zahlung beim Widerruf).
// Braucht in Stripe → Settings → Public details eine Terms-of-service-URL (https://ordcat.de/terms.html), sonst lehnt Stripe ab.
const TOS_TEXT: Record<string, string> = {
  zh: "我同意 [用户协议](https://ordcat.de/terms.html)，并要求 OrdCat 立即开始提供服务。我知道：数字内容（小鱼干、加油包）交付到账户后我就失去撤回权；会员和技能订阅如果在 14 天内撤回，需要按已使用的天数付费。详见 [撤回说明](https://ordcat.de/widerruf.html)。",
  en: "I agree to the [Terms](https://ordcat.de/terms.html) and ask OrdCat to start immediately. I know that I lose my right of withdrawal for digital content (Dried Fish, top-ups) once it is delivered to my account, and that if I withdraw from a subscription (plans, skills) within 14 days I pay pro rata for the days used. See the [withdrawal information](https://ordcat.de/widerruf.html).",
  de: "Ich stimme den [Nutzungsbedingungen](https://ordcat.de/terms.html) zu und verlange, dass OrdCat sofort mit der Leistung beginnt. Mir ist bekannt, dass ich mein Widerrufsrecht bei digitalen Inhalten (Trockenfisch, Top-up) mit der Bereitstellung in meinem Konto verliere und bei einem Widerruf eines Abos (Mitgliedschaft, Skills) innerhalb von 14 Tagen anteilig für die genutzten Tage zahle. Siehe [Widerrufsbelehrung](https://ordcat.de/widerruf.html).",
};
const tos = (lang: unknown): Record<string, string> => ({
  "consent_collection[terms_of_service]": "required",
  "custom_text[terms_of_service_acceptance][message]": TOS_TEXT[lang === "zh" || lang === "de" ? lang : "en"],
  // OrdCat 自己是卖家（见用户协议 §7），不用 Stripe Managed Payments；它和 custom_text 不能同时用。
  "managed_payments[enabled]": "false",
});

// Unpaid checkouts: Stripe keeps a recovery link after the session expires (stripe-webhook mails it once, checkout.session.expired).
const RECOVERY: Record<string, string> = { "after_expiration[recovery][enabled]": "true" };

// Yearly plans: show the saving on Stripe's page (custom_text[submit]). No coupon on purpose: a coupon would stay on
// the subscription and follow plan switches in the Customer Portal. Cents, VAT included; keep in sync with the Stripe prices.
const PLAN_CENTS: Record<string, { month: number; year: number }> = {
  pro: { month: 990, year: 9500 },
  max: { month: 5900, year: 56600 },
};
const eur = (c: number) => "€" + (c % 100 === 0 ? String(c / 100) : (c / 100).toFixed(2));
function yearlyNote(item: string, lang: string): string | null {
  const p = PLAN_CENTS[item];
  if (!p) return null;
  const full = p.month * 12, off = full - p.year;
  if (off <= 0) return null;
  const pct = Math.round((p.year / full) * 100);           // 80 → 8 折 / 20 % off
  const zhOff = pct % 10 === 0 ? `${pct / 10} 折` : `${(pct / 10).toFixed(1)} 折`;
  const pctOff = 100 - pct;
  if (lang === "zh") return `原价 ${eur(full)}/年（${eur(p.month)} × 12 个月），年付优惠 −${eur(off)}（约 ${zhOff}），实付 ${eur(p.year)}/年。`;
  if (lang === "de") return `Regulär ${eur(full).replace(".", ",")}/Jahr (${eur(p.month).replace(".", ",")} × 12 Monate), Rabatt bei jährlicher Zahlung −${eur(off).replace(".", ",")} (ca. ${pctOff} %), Sie zahlen ${eur(p.year).replace(".", ",")}/Jahr. Alle Preise inkl. MwSt.`;
  return `Regular price ${eur(full)}/year (${eur(p.month)} × 12 months), yearly discount −${eur(off)} (about ${pctOff}% off), you pay ${eur(p.year)}/year.`;
}

// ---------- plan changes in the app (v0.2.64) ----------
const TIER: Record<string, number> = { pro: 1, max: 2 };
const iso = (t: number | null | undefined) => (t ? new Date(t * 1000).toISOString() : null);
const idOf = (v: any): string | null => (typeof v === "string" ? v : v?.id ?? null);
/** upgrade = higher tier, or same tier monthly → yearly; downgrade = lower tier, or yearly → monthly. */
function changeKind(curItem: string, curIv: string, item: string, iv: string): "upgrade" | "downgrade" | "none" {
  const a = TIER[curItem] ?? 0, b = TIER[item] ?? 0;
  if (b > a) return "upgrade";
  if (b < a) return "downgrade";
  if (curIv === iv) return "none";
  return iv === "year" ? "upgrade" : "downgrade";
}
function addInterval(t: number, iv: string) {
  const d = new Date(t * 1000);
  if (iv === "year") d.setUTCFullYear(d.getUTCFullYear() + 1); else d.setUTCMonth(d.getUTCMonth() + 1);
  return Math.floor(d.getTime() / 1000);
}
/** subscriptions.pending_* (plan_change.sql); silently skipped while those columns don't exist yet. */
async function setPending(admin: any, subId: string, p: { plan: string; interval: string; at: number } | null) {
  try {
    const { error } = await admin.from("subscriptions").update(p
      ? { pending_plan: p.plan, pending_interval: p.interval, pending_at: iso(p.at) }
      : { pending_plan: null, pending_interval: null, pending_at: null }).eq("id", subId);
    if (error) console.error("pending_*", error.message);        // plan_change.sql not run yet: the webhook fills it later
  } catch (_) { /* ignore */ }
}
function withTimeout(p: Promise<unknown>, ms: number) {
  return Promise.race([p, new Promise((r) => setTimeout(r, ms))]);
}
const PLAN_NAME: Record<string, string> = { pro: "OrdCat Pro", max: "OrdCat Max" };
const ivWord = (iv: string) => (iv === "year" ? "yearly" : "monthly");

/** "Plan change scheduled" (English, shared OrdCat template). */
function scheduledMail(o: { to: string | null; user_id: string; from: string; fromInterval: string; to_item: string; interval: string;
  at: number; cents: number | null; currency: string; ref: string; site: string }): MailOut {
  const newName = PLAN_NAME[o.to_item] ?? "OrdCat", oldName = PLAN_NAME[o.from] ?? "OrdCat";
  const when = dayEn(o.at);
  const price = o.cents != null ? money(o.cents, o.currency) : null;
  const per = o.interval === "year" ? "year" : "month";
  const rows: Row[] = [
    { k: "Current plan", v: `${oldName} · ${ivWord(o.fromInterval)}`, sub: `unchanged until ${when}` },
    { k: "New plan", v: `${newName} · ${ivWord(o.interval)}` },
    { k: "Takes effect", v: when },
  ];
  if (price) rows.push({ k: "New price", v: `${price} /${per}`, sub: `VAT included · first charge on ${when}` });
  rows.push({ k: "Charged today", v: money(0, o.currency), sub: "no refund for the current period" });
  rows.push({ k: "Reference", v: o.ref, mono: true });
  const m = render({
    subject: "Plan change scheduled · OrdCat",
    preheader: `${newName} (${ivWord(o.interval)}) from ${when}. Until then you keep ${oldName}.`,
    badge: "ok", icon: "✓",
    title: "Plan change scheduled",
    subtitle: `From ${when} you'll be on ${newName}, billed ${ivWord(o.interval)}.`,
    greeting: "Hello,",
    intro: [`You asked to switch from ${oldName} (${ivWord(o.fromInterval)}) to ${newName} (${ivWord(o.interval)}). The change takes effect at the end of your current billing period.`],
    rows,
    body: [{
      title: "What happens next",
      paras: [
        `Until ${when} you keep using ${oldName} as now. Nothing is charged or refunded today.`,
        price ? `From ${when}, your subscription renews automatically every ${per} at ${price} (VAT included) until you cancel.`
          : `From ${when}, your subscription renews automatically on the new plan until you cancel.`,
        "Changed your mind? Before that date, open OrdCat → Settings → User → Membership and click Undo next to the scheduled change.",
        `You can cancel anytime, effective at the end of the current period, also without signing in at ${o.site}/kuendigen.html.`,
      ],
    }],
    buttons: [{ label: "Cancel subscription", href: `${o.site}/kuendigen.html` }],
    legal: [{
      title: "Seller",
      paras: [`${SELLER_NAME}, Hedemannstraße 74, 78355 Hohenfels, Germany · ${SUPPORT}. This email confirms the change to your contract.`],
      links: [
        { label: "Terms", href: `${o.site}/terms.html` },
        { label: "Withdrawal information", href: `${o.site}/widerruf.html` },
        { label: "Cancel contracts", href: `${o.site}/kuendigen.html` },
      ],
    }],
  }, o.site);
  return { to: o.to, lang: "en", ...m, item: o.to_item, user_id: o.user_id };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: u } = await admin.auth.getUser(token);
  if (!u?.user) return json({ error: "请先登录" }, 401);
  const uid = u.user.id;
  const email = u.user.email ?? "";
  const site = Deno.env.get("SITE_URL") ?? "https://ordcat.de";
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }

  try {
    // One Stripe customer per account (kept on the subscription rows).
    const { data: rows } = await admin.from("subscriptions").select("customer_id")
      .eq("user_id", uid).not("customer_id", "is", null).limit(1);
    let customer: string | undefined = rows?.[0]?.customer_id ?? undefined;
    if (!customer) {
      // Bought only Dried Fish so far (no subscription row): reuse the Stripe customer made for this account.
      try {
        const q = encodeURIComponent(`metadata['user_id']:'${uid}'`);
        const f = await stripe(`customers/search?query=${q}&limit=1`, undefined, "GET");
        customer = f.data?.[0]?.id ?? undefined;
      } catch (_) { /* search not available: a new customer is made below */ }
    }

    // Stripe's own page text follows the app language (zh → Simplified Chinese).
    const locale = body.locale === "en" ? "en" : body.locale === "zh" ? "zh" : "auto";
    // Language of our own confirmation mail (stripe-webhook): zh / en / de.
    const lang = body.locale === "zh" || body.locale === "de" ? body.locale : "en";
    // Receipt page on ordcat.de; Stripe fills in {CHECKOUT_SESSION_ID} itself (keep the braces literal).
    const successUrl = `${site}/thanks.html?session_id={CHECKOUT_SESSION_ID}`;
    const cancelUrl = `${site}/thanks.html?session_id={CHECKOUT_SESSION_ID}&cancelled=1`;   // "order not completed" page

    const item = String(body.item ?? "");
    const prices: Record<string, string> = JSON.parse(Deno.env.get("STRIPE_PRICES") ?? "{}");
    const itemOfPrice = (id: string) => Object.entries(prices).find(([, v]) => v === id)?.[0]?.split(".")[0];
    const portalBase = (): Record<string, string> => ({
      customer: customer!, return_url: `${site}/thanks.html?portal=1`, ...(locale === "auto" ? {} : { locale }),
    });
    // Portal session; a deep-link flow first, the plain portal if Stripe refuses the flow (e.g. not enabled in the portal settings).
    const portal = async (flow: Record<string, string> | null, reason: string) => {
      if (flow) {
        try {
          const s = await stripe("billing_portal/sessions", { ...portalBase(), ...flow });
          return json({ url: s.url, portal: true, reason });
        } catch (_) { /* fall back */ }
      }
      const s = await stripe("billing_portal/sessions", portalBase());
      return json({ url: s.url, portal: true, reason });
    };
    // This customer's subscriptions that still count (one plan + skills at most; never sell a second one).
    const liveSubs = async () => {
      if (!customer) return [] as any[];
      const r = await stripe("subscriptions?customer=" + encodeURIComponent(customer) + "&status=all&limit=30", undefined, "GET");
      return (r.data ?? []).filter((x: any) => LIVE.includes(x.status)).map((x: any) => {
        const it = x.items?.data?.[0];
        return { sub: x, si: it?.id as string, price: it?.price?.id as string,
                 item: itemOfPrice(it?.price?.id ?? "") ?? x.metadata?.item ?? "" };
      });
    };

    if (body.portal) {
      if (!customer) return json({ error: "还没有订阅记录" }, 400);
      const subs = await liveSubs();
      const pick = subs.find((x: any) => x.item === body.item) ?? subs.find((x: any) => x.item === "pro" || x.item === "max") ?? subs[0];
      if (body.flow === "payment") {
        // past_due → update the card; Stripe retries the open invoice with it.
        return portal({ "flow_data[type]": "payment_method_update" }, "payment");
      }
      if (body.flow === "cancel" && pick) {
        return portal({
          "flow_data[type]": "subscription_cancel",
          "flow_data[subscription_cancel][subscription]": pick.sub.id,
        }, "cancel");
      }
      return portal(null, "manage");
    }

    // Undo a booked downgrade / switch to monthly (the Subscription Schedule is released; the plan just keeps renewing).
    if (body.cancel_change) {
      const plan = (await liveSubs()).find((x: any) => x.item === "pro" || x.item === "max");
      const sid = plan ? idOf(plan.sub.schedule) : null;
      if (!plan || !sid) return json({ ok: true, changed: "none", reason: "no_pending_change" });
      await stripe(`subscription_schedules/${sid}/release`, {});
      await setPending(admin, plan.sub.id, null);
      return json({ ok: true, changed: "cancelled_change" });
    }

    // A plan / skill the customer already has on Stripe: never a 2nd checkout.
    //   Plans: changed here via the Stripe API after the app's confirm dialog (no portal switch flow any more):
    //     upgrade (Pro → Max, monthly → yearly) = now, new billing cycle from today, old plan's unused part credited,
    //       difference charged to the saved card (payment_behavior pending_if_incomplete: nothing changes until it's paid);
    //     downgrade (Max → Pro, yearly → monthly) = Subscription Schedule, new price from the end of the current period, no refund.
    //   Skills: the portal, as before.
    if (["pro", "max", "x", "agent", "miao"].includes(item)) {
      const isPlan = item === "pro" || item === "max";
      const subs = await liveSubs();
      const have = subs.find((x: any) => isPlan ? (x.item === "pro" || x.item === "max") : x.item === item);
      if (have && !isPlan) return portal(have.sub.status === "past_due" ? { "flow_data[type]": "payment_method_update" } : null, "current");
      if (have) {
        const interval = body.interval === "year" ? "year" : "month";
        const want = prices[`${item}.${interval}`];
        if (!want) return json({ error: `还没开放：${item}.${interval}` }, 400);
        if (["past_due", "unpaid", "incomplete"].includes(have.sub.status)) {
          return portal(have.sub.status === "past_due" ? { "flow_data[type]": "payment_method_update" } : null, "pay_first");
        }
        const curInterval = have.sub.items?.data?.[0]?.price?.recurring?.interval === "year" ? "year" : "month";
        const kind = changeKind(have.item, curInterval, item, interval);
        const periodEnd = Number(have.sub.current_period_end ?? have.sub.items?.data?.[0]?.current_period_end ?? 0);
        const scheduleId = idOf(have.sub.schedule);
        const cur = { plan: have.item, interval: curInterval, period_end: periodEnd ? iso(periodEnd) : null };
        if (kind === "none") return json({ ok: true, changed: "none", kind, reason: "current", current: cur, preview: !!body.preview });

        const nowTs = Math.floor(Date.now() / 1000);
        if (body.preview) {
          const price = await stripe(`prices/${want}`, undefined, "GET");
          const out: Record<string, unknown> = { ok: true, preview: true, kind, plan: item, interval, current: cur,
            currency: price.currency ?? "eur", next_cents: Number(price.unit_amount ?? 0), has_pending: !!scheduleId };
          if (kind === "upgrade") {
            const pv = await stripe("invoices/create_preview", {
              customer: customer!, subscription: have.sub.id,
              "subscription_details[items][0][id]": have.si, "subscription_details[items][0][price]": want,
              "subscription_details[items][0][quantity]": "1",
              "subscription_details[proration_behavior]": "always_invoice",
              "subscription_details[billing_cycle_anchor]": "now",
              "subscription_details[proration_date]": String(nowTs),
            });
            out.today_cents = Number(pv.amount_due ?? pv.total ?? 0);
            const line = (pv.lines?.data ?? []).find((l: any) => Number(l.amount ?? 0) > 0 && l.period?.end);
            out.next_at = iso(Number(line?.period?.end ?? 0) || addInterval(nowTs, interval));
          } else {
            out.today_cents = 0;
            out.effective_at = cur.period_end;
            out.next_at = cur.period_end;
          }
          return json(out);
        }

        if (kind === "upgrade") {
          // One pending change at a time: an upgrade replaces a booked downgrade.
          if (scheduleId) { await stripe(`subscription_schedules/${scheduleId}/release`, {}); await setPending(admin, have.sub.id, null); }
          const up = await stripe(`subscriptions/${have.sub.id}`, {
            "items[0][id]": have.si, "items[0][price]": want, "items[0][quantity]": "1",
            proration_behavior: "always_invoice",
            billing_cycle_anchor: "now",
            payment_behavior: "pending_if_incomplete",
            "expand[]": "latest_invoice",
          });
          const inv = up.latest_invoice && typeof up.latest_invoice === "object" ? up.latest_invoice : null;
          const paid = !up.pending_update && (!inv || inv.status === "paid");
          if (!paid) {
            // 3-D Secure or a declined card: the plan stays as it was until this invoice is paid (Stripe keeps it ~23 h).
            return json({ ok: true, changed: "pending_payment", kind, reason: "pay_invoice", url: inv?.hosted_invoice_url ?? null,
                          invoice: inv?.id ?? null, plan: item, interval });
          }
          return json({ ok: true, changed: "upgraded", kind, plan: item, interval, invoice: inv?.id ?? null });
        }

        // Downgrade: keep the current price until the period ends, then the new one. No refund.
        if (!periodEnd) return json({ error: "读不到当前计费周期，稍后再试" }, 409);
        if (scheduleId) await stripe(`subscription_schedules/${scheduleId}/release`, {});
        const sched = await stripe("subscription_schedules", { from_subscription: have.sub.id });
        const p0 = sched.phases?.[0] ?? {};
        const done = await stripe(`subscription_schedules/${sched.id}`, {
          end_behavior: "release",
          "phases[0][items][0][price]": have.price, "phases[0][items][0][quantity]": "1",
          "phases[0][start_date]": String(p0.start_date ?? have.sub.current_period_start ?? have.sub.items?.data?.[0]?.current_period_start ?? nowTs),
          "phases[0][end_date]": String(periodEnd),
          "phases[0][proration_behavior]": "none",
          "phases[1][items][0][price]": want, "phases[1][items][0][quantity]": "1",
          "phases[1][iterations]": "1",
          "phases[1][proration_behavior]": "none",
          "metadata[change]": `${have.item}.${curInterval}->${item}.${interval}`,
        });
        const schedId = String(done.id ?? sched.id);
        await setPending(admin, have.sub.id, { plan: item, interval, at: periodEnd });
        const price = await stripe(`prices/${want}`, undefined, "GET").catch(() => null);
        await withTimeout(sendOnce(admin, `sched:${schedId}`, "scheduled", async () => {
          const c = await stripe(`customers/${customer}`, undefined, "GET").catch(() => null);
          return scheduledMail({ to: c?.email ?? email, user_id: uid, from: have.item, fromInterval: curInterval, to_item: item, interval,
            at: periodEnd, cents: price?.unit_amount ?? PLAN_CENTS[item]?.[interval as "month" | "year"] ?? null,
            currency: price?.currency ?? "eur", ref: schedId, site });
        }), 8000);
        return json({ ok: true, changed: "scheduled", kind, plan: item, interval, effective_at: iso(periodEnd), schedule: schedId });
      }
    }

    // A plan not paid through Stripe (Dried Fish, old test rows): never sell the same or a lower plan on top of it
    // (one person, two plan subscriptions). A higher plan stays possible.
    if (item === "pro" || item === "max") {
      const rank = (p: string) => (p === "max" ? 2 : p === "pro" ? 1 : 0);
      const { data: own } = await admin.from("subscriptions").select("skill,status,provider,ends_at,renews_at").eq("user_id", uid);
      const now = Date.now();
      const held = (own ?? []).filter((r: any) =>
        (r.skill === "pro" || r.skill === "max") && (r.provider ?? "stripe") !== "stripe" &&
        !["canceled", "cancelled", "expired", "incomplete_expired"].includes(r.status) &&
        !(((r.ends_at ?? r.renews_at) && Date.parse(r.ends_at ?? r.renews_at) < now)));
      const top = held.reduce((m: string, r: any) => (rank(r.skill) > rank(m) ? r.skill : m), "free");
      if (rank(item) <= rank(top)) {
        return json({ error: top === item ? "已经有这个方案了" : "已有更高的方案，到期后才能换成低一级的", reason: "has_plan", plan: top }, 409);
      }
    }

    // Preview for someone without a Stripe plan: nothing to compute, the app opens a normal checkout.
    if (body.preview) return json({ ok: true, preview: true, kind: "checkout" });

    if (item === "fish") {
      // Custom amount: {"item":"fish","amount_eur":N}. The fish count is computed here, never taken from the app.
      const custom = body.amount_eur !== undefined && body.amount_eur !== null;
      const eur = custom ? customEur(body.amount_eur) : null;
      if (custom && eur === null) {
        return json({ error: `自定义金额要是 €${FISH_CUSTOM_MIN} – €${FISH_CUSTOM_MAX} 之间的整数欧元`, reason: "bad_amount" }, 400);
      }
      const pack = custom ? "custom" : String(body.pack ?? "");
      const def = custom ? { fish: fishForEur(eur!), cents: eur! * 100 } : FISH_PACKS[pack];
      if (!def) return json({ error: "没有这个充值档位" }, 400);
      const price = custom ? undefined : prices[`fish.${pack}`];
      const inline = custom || Deno.env.get("STRIPE_FISH_INLINE") === "1";
      if (!price && !inline) return json({ error: `还没开放：fish.${pack}` }, 400);
      if (!customer) {
        const c = await stripe("customers", { email, "metadata[user_id]": uid });
        customer = c.id as string;
      }
      const p: Record<string, string> = {
        mode: "payment",
        customer: customer!,
        client_reference_id: uid,
        "line_items[0][quantity]": "1",
        "metadata[user_id]": uid,
        "metadata[item]": "fish",
        "metadata[pack]": pack,
        "metadata[fish]": String(def.fish),
        "metadata[cents]": String(def.cents),
        "metadata[lang]": lang,
        "payment_intent_data[metadata][user_id]": uid,
        "payment_intent_data[metadata][item]": "fish",
        success_url: successUrl,
        cancel_url: cancelUrl,
        locale,
        "automatic_tax[enabled]": Deno.env.get("STRIPE_TAX") === "1" ? "true" : "false",
        ...tos(body.locale),
        ...RECOVERY,
      };
      if (custom) p["metadata[amount_eur]"] = String(eur);
      if (price) p["line_items[0][price]"] = price;
      else {
        p["line_items[0][price_data][currency]"] = "eur";
        p["line_items[0][price_data][unit_amount]"] = String(def.cents);
        p["line_items[0][price_data][product_data][name]"] = custom
          ? (lang === "zh" ? `OrdCat 小鱼干 · ${def.fish}` : lang === "de" ? `OrdCat Trockenfisch · ${def.fish}` : `OrdCat Dried Fish · ${def.fish}`)
          : `OrdCat 小鱼干 ${def.fish}`;
        // Same as the other prices: the amount already includes VAT.
        if (custom) p["line_items[0][price_data][tax_behavior]"] = "inclusive";
      }
      const s = await stripe("checkout/sessions", p);
      return json({ url: s.url, id: s.id, ...(custom ? { fish: def.fish, amount_eur: eur } : {}) });
    }

    const isSkill = !["pro", "max", "topup"].includes(item);
    const interval = !isSkill && body.interval === "year" ? "year" : "month";   // skills are monthly only
    let priceKey = item === "topup" ? "topup" : `${item}.${interval}`;
    if (isSkill) {
      const { data: plan } = await admin.rpc("ord_plan", { p_user: uid });
      if ((plan === "pro" || plan === "max") && prices[`${priceKey}.member`]) priceKey = `${priceKey}.member`;
    }
    const price = prices[priceKey];
    if (!price) return json({ error: `还没开放：${priceKey}` }, 400);

    if (!customer) {
      const c = await stripe("customers", { email, "metadata[user_id]": uid });
      customer = c.id as string;
    }
    const p: Record<string, string> = {
      customer: customer!,
      client_reference_id: uid,
      "line_items[0][price]": price,
      "line_items[0][quantity]": "1",
      "metadata[user_id]": uid,
      "metadata[item]": item,
      "metadata[lang]": lang,
      success_url: successUrl,
      cancel_url: cancelUrl,
      allow_promotion_codes: "true",
      locale,
      "automatic_tax[enabled]": Deno.env.get("STRIPE_TAX") === "1" ? "true" : "false",
      ...tos(body.locale),
      ...RECOVERY,
    };
    if (item === "topup") {
      p.mode = "payment";
      p["metadata[credits]"] = Deno.env.get("TOPUP_CREDITS") ?? "1500";
    } else {
      p.mode = "subscription";
      p["subscription_data[metadata][user_id]"] = uid;
      p["subscription_data[metadata][item]"] = item;
      p["subscription_data[metadata][lang]"] = lang;   // renewal mails (invoice.paid) use it
      const note = interval === "year" ? yearlyNote(item, lang) : null;
      if (note) p["custom_text[submit][message]"] = note;   // the ToS consent text (custom_text[terms_of_service_acceptance]) stays
    }
    const s = await stripe("checkout/sessions", p);
    return json({ url: s.url, id: s.id });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});

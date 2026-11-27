// OrdCat · 开通会员 / 买加油包 / 管理订阅（Stripe Checkout + Customer Portal）。
// App 带着登录 token 调用：POST /functions/v1/stripe-checkout
//   {"item":"pro","interval":"month"|"year"}      Pro  €9.9/月，年付 €95
//   {"item":"max","interval":"month"|"year"}      Max  €59/月，年付 €566（技能另买，8 折）
//   {"item":"topup"}                              加油包 €2.99 = 1500 条（一次性付款）
//   {"item":"x"} / {"item":"agent"} / {"item":"miao"}   技能订阅 €3/月；Pro / Max 用 8 折价（x.month.member…）
//   {"item":"fish","pack":"5"|"10"|"30"|"100"}   小鱼干充值（一次性付款）：€5 = 500，€10 = 1050，€30 = 3300，€100 = 11500
//   {"portal":true}                              管理订阅 / 取消 / 换卡（Stripe Customer Portal）
//   {"portal":true,"flow":"payment"}             付款失败（past_due）→ 直接打开「更新付款方式」
//   {"portal":true,"flow":"cancel","item":"pro"} 直接打开「取消订阅」确认页（当期结束时生效）
// 已经有 Pro / Max（或同一个技能）的 Stripe 订阅时，不会再开第二个 Checkout：
//   换方案 / 换月付年付 → 返回 Portal 的 subscription_update_confirm 页面（升级立即生效、按剩余天数折算；降级按 Portal 设置在当期结束生效），
//   同一个方案 → 返回普通 Portal。返回 {"url","portal":true,"reason":"switch"|"current"|"pay_first"|"manage"|"payment"|"cancel"}。
//   Portal 不支持某个 flow（Portal 设置里没开「更换方案」）时自动退回普通 Portal。
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

    // A plan / skill the customer already has: switch it in the portal (proration by the portal settings), never a 2nd checkout.
    if (["pro", "max", "x", "agent", "miao"].includes(item)) {
      const isPlan = item === "pro" || item === "max";
      const subs = await liveSubs();
      const have = subs.find((x: any) => isPlan ? (x.item === "pro" || x.item === "max") : x.item === item);
      if (have) {
        const interval = body.interval === "year" ? "year" : "month";
        const want = isPlan ? prices[`${item}.${interval}`] : null;
        if (!want || want === have.price || have.sub.status === "past_due" || have.sub.status === "unpaid" || have.sub.status === "incomplete") {
          return portal(have.sub.status === "past_due" ? { "flow_data[type]": "payment_method_update" } : null,
                        want && want !== have.price ? "pay_first" : "current");
        }
        return portal({
          "flow_data[type]": "subscription_update_confirm",
          "flow_data[subscription_update_confirm][subscription]": have.sub.id,
          "flow_data[subscription_update_confirm][items][0][id]": have.si,
          "flow_data[subscription_update_confirm][items][0][price]": want,
          "flow_data[subscription_update_confirm][items][0][quantity]": "1",
          "flow_data[after_completion][type]": "redirect",
          "flow_data[after_completion][redirect][return_url]": `${site}/thanks.html?updated=1`,
        }, "switch");
      }
    }

    if (item === "fish") {
      const pack = String(body.pack ?? "");
      const def = FISH_PACKS[pack];
      if (!def) return json({ error: "没有这个充值档位" }, 400);
      const price = prices[`fish.${pack}`];
      const inline = Deno.env.get("STRIPE_FISH_INLINE") === "1";
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
      };
      if (price) p["line_items[0][price]"] = price;
      else {
        p["line_items[0][price_data][currency]"] = "eur";
        p["line_items[0][price_data][unit_amount]"] = String(def.cents);
        p["line_items[0][price_data][product_data][name]"] = `OrdCat 小鱼干 ${def.fish}`;
      }
      const s = await stripe("checkout/sessions", p);
      return json({ url: s.url, id: s.id });
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

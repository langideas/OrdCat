// OrdCat · 开通会员 / 买加油包 / 管理订阅（Stripe Checkout + Customer Portal）。
// App 带着登录 token 调用：POST /functions/v1/stripe-checkout
//   {"item":"pro","interval":"month"|"year"}      Pro  €9.9/月，年付 €95
//   {"item":"max","interval":"month"|"year"}      Max  €59/月，年付 €566（技能另买，8 折）
//   {"item":"topup"}                              加油包 €2.99 = 1500 条（一次性付款）
//   {"item":"x"} / {"item":"agent"} / {"item":"miao"}   技能订阅 €3/月；Pro / Max 用 8 折价（x.month.member…）
//   {"item":"fish","pack":"5"|"10"|"30"|"100"}   小鱼干充值（一次性付款）：€5 = 500，€10 = 1050，€30 = 3300，€100 = 11500
//   {"portal":true}                              管理订阅 / 取消 / 换卡
// 返回 {"url":"https://checkout.stripe.com/…"}，App 用浏览器打开。
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

async function stripe(path: string, params: Record<string, string>) {
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("STRIPE_SECRET_KEY")}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(params),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `Stripe ${r.status}`);
  return j;
}

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

    // Stripe's own page text follows the app language (zh → Simplified Chinese).
    const locale = body.locale === "en" ? "en" : body.locale === "zh" ? "zh" : "auto";

    if (body.portal) {
      if (!customer) return json({ error: "还没有订阅记录" }, 400);
      const s = await stripe("billing_portal/sessions", { customer, return_url: site, ...(locale === "auto" ? {} : { locale }) });
      return json({ url: s.url });
    }

    const item = String(body.item ?? "");
    const prices = JSON.parse(Deno.env.get("STRIPE_PRICES") ?? "{}");

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
        "payment_intent_data[metadata][user_id]": uid,
        "payment_intent_data[metadata][item]": "fish",
        success_url: `${site}/pricing.html?paid=1`,
        cancel_url: `${site}/pricing.html?paid=0`,
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
      return json({ url: s.url });
    }

    const interval = body.interval === "year" ? "year" : "month";
    const isSkill = !["pro", "max", "topup"].includes(item);
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
      success_url: `${site}/pricing.html?paid=1`,
      cancel_url: `${site}/pricing.html?paid=0`,
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
    }
    const s = await stripe("checkout/sessions", p);
    return json({ url: s.url });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});

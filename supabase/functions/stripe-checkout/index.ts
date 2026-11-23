// OrdCat · 开通会员 / 买加油包 / 管理订阅（Stripe Checkout + Customer Portal）。
// App 带着登录 token 调用：POST /functions/v1/stripe-checkout
//   {"item":"member","interval":"month"|"year"}   会员
//   {"item":"pro","interval":"month"|"year"}      会员 Pro
//   {"item":"topup"}                              加油包（一次性付款）
//   {"item":"x"} / {"item":"agent"}              技能订阅
//   {"portal":true}                              管理订阅 / 取消 / 换卡
// 返回 {"url":"https://checkout.stripe.com/…"}，App 用浏览器打开。
//
// 部署：supabase functions deploy stripe-checkout
// Secrets：
//   STRIPE_SECRET_KEY=sk_live_…
//   STRIPE_PRICES='{"member.month":"price_…","member.year":"price_…","pro.month":"price_…","pro.year":"price_…",
//                   "topup":"price_…","x.month":"price_…","agent.month":"price_…"}'
//   TOPUP_CREDITS=1200
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

    if (body.portal) {
      if (!customer) return json({ error: "还没有订阅记录" }, 400);
      const s = await stripe("billing_portal/sessions", { customer, return_url: site });
      return json({ url: s.url });
    }

    const item = String(body.item ?? "");
    const interval = body.interval === "year" ? "year" : "month";
    const prices = JSON.parse(Deno.env.get("STRIPE_PRICES") ?? "{}");
    const priceKey = item === "topup" ? "topup" : `${item}.${interval}`;
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
      success_url: `${site}/?paid=1`,
      cancel_url: `${site}/?paid=0`,
      allow_promotion_codes: "true",
      "automatic_tax[enabled]": Deno.env.get("STRIPE_TAX") === "1" ? "true" : "false",
    };
    if (item === "topup") {
      p.mode = "payment";
      p["metadata[credits]"] = Deno.env.get("TOPUP_CREDITS") ?? "1200";
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

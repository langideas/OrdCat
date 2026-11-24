// Stripe → 订阅 / 加油包写进 OrdCat 账号。
// Stripe 后台 → Developers → Webhooks → Add endpoint：
//   URL = https://<project>.supabase.co/functions/v1/stripe-webhook
//   事件：checkout.session.completed, customer.subscription.created, customer.subscription.updated,
//         customer.subscription.deleted, invoice.paid
// 部署：supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets：STRIPE_WEBHOOK_SECRET=whsec_…（同上 STRIPE_SECRET_KEY、STRIPE_PRICES）
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

  const saveSub = async (sub: any) => {
    const userId = sub.metadata?.user_id ?? null;
    const it = sub.items?.data?.[0];
    const priceId = it?.price?.id ?? "";
    const item = sub.metadata?.item ?? itemOfPrice(priceId) ?? "pro";
    const periodEnd = sub.current_period_end ?? it?.current_period_end ?? null;   // newer API versions keep it on the item
    const { error } = await admin.from("subscriptions").upsert({
      id: sub.id,
      user_id: userId,
      skill: item,
      status: sub.status,                       // active | trialing | past_due | canceled | unpaid | incomplete…
      renews_at: sub.cancel_at_period_end ? null : iso(periodEnd),
      ends_at: sub.status === "canceled" ? iso(sub.ended_at ?? sub.canceled_at) : (sub.cancel_at ? iso(sub.cancel_at) : null),
      provider: "stripe",
      customer_id: typeof sub.customer === "string" ? sub.customer : sub.customer?.id,
      price_id: priceId,
      updated_at: new Date().toISOString(),
    });
    if (error) throw new Error(error.message);
    if (userId && (item === "pro" || item === "max")) await admin.rpc("ord_wallet_sync", { p_user: userId });
    return userId;
  };

  try {
    switch (ev.type) {
      case "checkout.session.completed": {
        const userId = obj.metadata?.user_id ?? obj.client_reference_id;
        if (obj.mode === "payment" && obj.metadata?.item === "topup" && obj.payment_status === "paid" && userId) {
          await admin.rpc("credit_topup", { p_session: obj.id, p_user: userId, p_credits: Number(obj.metadata?.credits ?? 1500) });
        } else if (obj.mode === "subscription" && obj.subscription) {
          await saveSub(await stripeGet(`subscriptions/${obj.subscription}`));
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
        const subId = obj.subscription ?? obj.parent?.subscription_details?.subscription;
        if (subId && obj.billing_reason === "subscription_cycle") {
          const uid = await saveSub(await stripeGet(`subscriptions/${subId}`));
          if (uid) await admin.rpc("credit_new_period", { p_user: uid });
        }
        break;
      }
    }
  } catch (e) {
    return new Response(String((e as Error).message ?? e), { status: 500 });
  }
  return new Response("ok");
});

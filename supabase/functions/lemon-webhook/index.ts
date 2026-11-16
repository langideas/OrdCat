// Lemon Squeezy → 订阅绑定到 OrdCat 账号。
// Lemon Squeezy 后台 Webhook: URL = https://<project>.supabase.co/functions/v1/lemon-webhook
// 事件勾选 subscription_created / subscription_updated / subscription_cancelled / subscription_expired / subscription_resumed
// Secrets: LEMON_WEBHOOK_SECRET（和后台填的 signing secret 一样）, LEMON_VARIANT_SKILLS 例如 {"123456":"x","123457":"agent"}
import { createClient } from "npm:@supabase/supabase-js@2";

async function verify(raw: string, sig: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return hex === sig;
}

Deno.serve(async (req) => {
  const raw = await req.text();
  const ok = await verify(raw, req.headers.get("X-Signature") ?? "", Deno.env.get("LEMON_WEBHOOK_SECRET")!);
  if (!ok) return new Response("bad signature", { status: 401 });

  const body = JSON.parse(raw);
  const event: string = body.meta?.event_name ?? "";
  if (!event.startsWith("subscription_")) return new Response("ignored");
  const a = body.data?.attributes ?? {};
  const userId = body.meta?.custom_data?.user_id ?? null;
  const skills = JSON.parse(Deno.env.get("LEMON_VARIANT_SKILLS") ?? "{}");
  const skill = skills[String(a.variant_id)] ?? "x";

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await admin.from("subscriptions").upsert({
    id: String(body.data.id),
    user_id: userId,
    skill,
    status: a.status,
    renews_at: a.renews_at,
    ends_at: a.ends_at,
    portal_url: a.urls?.customer_portal ?? null,
    customer_email: a.user_email ?? null,
    updated_at: new Date().toISOString(),
  });
  if (error) return new Response(error.message, { status: 500 });
  return new Response("ok");
});

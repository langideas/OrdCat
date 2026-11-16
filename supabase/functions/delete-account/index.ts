// 注销账号：删除头像、订阅绑定、资料和登录账号。
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const auth = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user }, error } = await userClient.auth.getUser();
  if (error || !user) return new Response(JSON.stringify({ error: "not signed in" }), { status: 401 });

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  await admin.storage.from("avatars").remove([`${user.id}.png`]);
  await admin.from("subscriptions").delete().eq("user_id", user.id);
  await admin.from("profiles").delete().eq("id", user.id);
  const { error: delErr } = await admin.auth.admin.deleteUser(user.id);
  if (delErr) return new Response(JSON.stringify({ error: delErr.message }), { status: 500 });
  return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
});

# OrdCat 后端（Supabase + Lemon Squeezy）

1. Supabase 新建项目（地区 Singapore / Tokyo）。
2. SQL Editor 里运行 `schema.sql`。
3. Authentication → Providers：打开 Email（邮件模板里加入 `{{ .Token }}` 显示 6 位验证码）；要手机号就打开 Phone 并接入 Twilio 等短信服务。
4. 部署函数：`supabase functions deploy delete-account` 和 `supabase functions deploy lemon-webhook --no-verify-jwt`。
5. `supabase secrets set LEMON_WEBHOOK_SECRET=... LEMON_VARIANT_SKILLS='{"<variant id>":"x"}'`
6. Lemon Squeezy：建订阅商品「陪你刷推」¥39/月，打开 License keys；Webhook 指向 lemon-webhook。
7. 把 Project URL、anon key 写进 `config/remote.json` 的 `account`，付款链接写进 `billing.skills.x.checkout`，测试通过后把 `billing.enabled` 改成 true。

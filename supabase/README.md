# OrdCat 后端（Supabase + Lemon Squeezy）

1. Supabase 新建项目（地区 Singapore / Tokyo）。
2. SQL Editor 里运行 `schema.sql`，再运行 `square.sql`（任务广场 + 小鱼干），再运行 `signal.sql`（信号站📶 + 小猫等级 + 喵友 + 订阅会员）。
   **Lang：v0.2.41 起必须在 Supabase → SQL Editor 运行一次 `signal.sql`**，否则信号站、等级同步、加喵友都会提示「信号站服务器还没开通好」。可以重复运行。
3. Authentication → Providers：打开 Email（邮件模板里加入 `{{ .Token }}` 显示 6 位验证码）；要手机号就打开 Phone 并接入 Twilio 等短信服务。
4. 部署函数：`supabase functions deploy delete-account` 和 `supabase functions deploy lemon-webhook --no-verify-jwt`。
5. `supabase secrets set LEMON_WEBHOOK_SECRET=... LEMON_VARIANT_SKILLS='{"<variant id>":"x"}'`
6. Lemon Squeezy：建订阅商品「陪你刷推」¥39/月，打开 License keys；Webhook 指向 lemon-webhook。
7. 把 Project URL、anon key 写进 `config/remote.json` 的 `account`，付款链接写进 `billing.skills.x.checkout`，测试通过后把 `billing.enabled` 改成 true。

## 会员 + Stripe + OrdCat 托管模型（v0.2.46 起）

1. SQL Editor 运行 `account2.sql`，再运行 `membership.sql`（会员额度、用量记录、加油包）。
2. Stripe（Dashboard → Product catalog）建 5 个价格：会员 月/年、会员 Pro 月/年、加油包（一次性）。技能「陪你刷推」「帮我操作电脑」要走 Stripe 的话再各建一个月付价格。
3. 部署函数：
   ```
   supabase functions deploy chat-proxy
   supabase functions deploy stripe-checkout
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
4. Secrets：
   ```
   supabase secrets set STRIPE_SECRET_KEY=sk_live_... STRIPE_WEBHOOK_SECRET=whsec_... SITE_URL=https://ordcat.de TOPUP_CREDITS=1200
   supabase secrets set STRIPE_PRICES='{"member.month":"price_...","member.year":"price_...","pro.month":"price_...","pro.year":"price_...","topup":"price_..."}'
   supabase secrets set DASHSCOPE_KEY=... OPENAI_KEY=... ZHIPU_KEY=...
   supabase secrets set HOSTED_MODELS='{"cn":{"base":"https://dashscope.aliyuncs.com/compatible-mode/v1","key":"DASHSCOPE_KEY","model":"qwen3.8-flash","in":0.11,"out":0.38,"extra":{"enable_thinking":false}},"intl":{"base":"https://api.openai.com/v1","key":"OPENAI_KEY","model":"gpt-6-luna","in":0.1,"out":0.5},"slow":{"base":"https://open.bigmodel.cn/api/paas/v4","key":"ZHIPU_KEY","model":"glm-4.7-flash","extra":{"thinking":{"type":"disabled"}}}}'
   ```
5. Stripe → Developers → Webhooks：URL `https://<project>.supabase.co/functions/v1/stripe-webhook`，事件 `checkout.session.completed`、`customer.subscription.created/updated/deleted`、`invoice.paid`。
6. Stripe → Settings → Billing → Customer portal：打开「取消订阅」「换卡」「换方案」。

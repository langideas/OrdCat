# OrdCat 后端（Supabase + Lemon Squeezy）

1. Supabase 新建项目（地区 Singapore / Tokyo）。
2. SQL Editor 里运行 `schema.sql`，再运行 `square.sql`（任务广场 + 小鱼干），再运行 `signal.sql`（信号站📶 + 小猫等级 + 喵友 + 订阅会员）。完整顺序见文末：…→ `membership.sql` → `fish.sql`。
   **Lang：v0.2.41 起必须在 Supabase → SQL Editor 运行一次 `signal.sql`**，否则信号站、等级同步、加喵友都会提示「信号站服务器还没开通好」。可以重复运行。
3. Authentication → Providers：打开 Email（邮件模板里加入 `{{ .Token }}` 显示 6 位验证码）；要手机号就打开 Phone 并接入 Twilio 等短信服务。
4. 部署函数：`supabase functions deploy delete-account` 和 `supabase functions deploy lemon-webhook --no-verify-jwt`。
5. `supabase secrets set LEMON_WEBHOOK_SECRET=... LEMON_VARIANT_SKILLS='{"<variant id>":"x"}'`
6. Lemon Squeezy：建订阅商品「陪你刷推」¥39/月，打开 License keys；Webhook 指向 lemon-webhook。
7. 把 Project URL、anon key 写进 `config/remote.json` 的 `account`，付款链接写进 `billing.skills.x.checkout`，测试通过后把 `billing.enabled` 改成 true。

## 会员 + Stripe + OrdCat 托管模型（v0.2.46 起）

1. SQL Editor 运行 `account2.sql`，再运行 `membership.sql`（会员额度、用量记录、加油包、徽章分档）。`membership.sql` 要最后运行：以后重新运行 `signal.sql` 的话，记得再运行一次 `membership.sql`。
2. Stripe（Dashboard → Product catalog）建价格（方案 v2）：Pro €9.9/月、€95/年；Max €59/月、€566/年；加油包 €2.99（一次性，1500 条）；技能 喵推 / 喵手 / 喵传 各 €3/月，另建 8 折价 €2.4/月给 Pro / Max 会员（技能单独卖，任何会员都不包含）。
3. 部署函数：
   ```
   supabase functions deploy chat-proxy
   supabase functions deploy stripe-checkout
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
4. Secrets：
   ```
   supabase secrets set STRIPE_SECRET_KEY=sk_live_... STRIPE_WEBHOOK_SECRET=whsec_... SITE_URL=https://ordcat.de TOPUP_CREDITS=1500
   supabase secrets set STRIPE_PRICES='{"pro.month":"price_...","pro.year":"price_...","max.month":"price_...","max.year":"price_...","topup":"price_...","x.month":"price_...","agent.month":"price_...","miao.month":"price_...","x.month.member":"price_...","agent.month.member":"price_...","miao.month.member":"price_..."}'
   supabase secrets set DASHSCOPE_KEY=... OPENAI_KEY=... ZHIPU_KEY=...
   supabase secrets set HOSTED_MODELS='{"cn":{"base":"https://dashscope.aliyuncs.com/compatible-mode/v1","key":"DASHSCOPE_KEY","model":"qwen3.8-flash","in":0.11,"out":0.38,"extra":{"enable_thinking":false}},"intl":{"base":"https://api.openai.com/v1","key":"OPENAI_KEY","model":"gpt-6-luna","in":0.1,"out":0.5},"slow":{"base":"https://open.bigmodel.cn/api/paas/v4","key":"ZHIPU_KEY","model":"glm-4.7-flash","extra":{"thinking":{"type":"disabled"}}}}'
   ```
5. Stripe → Developers → Webhooks：URL `https://<project>.supabase.co/functions/v1/stripe-webhook`，事件 `checkout.session.completed`、`customer.subscription.created/updated/deleted`、`invoice.paid`。
6. Stripe → Settings → Billing → Customer portal：打开「取消订阅」「换卡」「换方案」。

## 小鱼干储值 + 邀请防刷（v0.2.62 起）

**运行顺序**（SQL Editor，每个都可以重复运行）：`schema.sql` → `square.sql` → `signal.sql` → `account2.sql` → `membership.sql` → **`fish.sql`**。
`fish.sql` 必须最后运行：它会替换 square.sql / account2.sql 里的几个函数（square_post / square_accept / square_cancel / fish_ensure / invite_my_code / invite_redeem）。以后重新运行了 square.sql 或 account2.sql，记得再运行一次 `fish.sql`。
第一次运行会把所有人现有的小鱼干余额搬进「奖励鱼干」（fish_wallets.reward），只搬一次。

1. Stripe → Product catalog 建 4 个一次性价格（EUR）：€5、€10、€30、€100（商品名比如「OrdCat 小鱼干 500 / 1050 / 3300 / 11500」）。
2. 把 price ID 加进 `STRIPE_PRICES`（保留原来的那些）：
   ```
   supabase secrets set STRIPE_PRICES='{…原来的…,"fish.5":"price_…","fish.10":"price_…","fish.30":"price_…","fish.100":"price_…"}'
   ```
   每档给多少条小鱼干由 stripe-checkout 里的 FISH_PACKS 决定（服务器说了算，App 传的数量不算）；`config/remote.json` 的 `billing.fishPacks` 只用来在 App 里显示（priceId 可以留空）。
   还没建商品时可以临时设 `STRIPE_FISH_INLINE=1`，按金额直接建临时价格（不建议长期用）。
3. 重新部署：`supabase functions deploy stripe-checkout` 和 `supabase functions deploy stripe-webhook --no-verify-jwt`。
4. Stripe → Webhooks：在原来的事件上再加 `checkout.session.async_payment_succeeded`（SEPA 等延迟到账的付款）。同一个 checkout session 只会加一次小鱼干。
5. 自动续费：`fish_autorenew_due()` 只给 service_role，续上 1 天内到期、开了自动续费的小鱼干会员 / 技能。以后用 pg_cron 或定时 Edge Function 每小时调一次，例如 `select cron.schedule('fish-renew', '17 * * * *', 'select public.fish_autorenew_due()');`。
6. 邀请奖励：`invite_settle()` 在邀请人打开邀请窗口时自动跑；也可以用 service_role 定时跑 `select public.invite_settle();` 给所有人结算。

函数一览（都是 security definer，锁行原子扣减，每笔写 fish_ledger，kind = paid | reward）：
- App 用：`fish_status(p_device)`、`fish_history(p_before, p_limit)`、`fish_buy(p_item, p_interval, p_auto)`（item：pro / max / x / agent / miao / credits）、`fish_set_autorenew(p_item, p_on)`、`invite_my_code(p_device)`、`invite_redeem(p_code, p_device)`、`invite_settle()`、`fish_balance()`（旧版 App 用，返回总数）
- 只给 service_role：`fish_topup(p_session, p_user, p_fish, p_cents, p_pack)`（stripe-webhook）、`fish_autorenew_due()`
- 内部：`fish_credit`、`fish_take`、`fish_price`、`fish_ensure`、`fish_note_device`

退款规则：猫帮圈任务记录了多少来自充值鱼干（square_tasks.fish_paid），取消时充值的部分退回充值鱼干、其余退回奖励鱼干。

## 喵副本 · 组队副本（v0.2.63 起）

**运行顺序**（SQL Editor，每个都可以重复运行）：`schema.sql` → `square.sql` → `signal.sql` → `account2.sql` → `membership.sql` → `fish.sql` → **`raids.sql`**。
`raids.sql` 用到 fish.sql 的 `fish_take` / `fish_credit` / `fish_note_device`，所以一定在 fish.sql 之后。它不改 square.sql 里的单人副本（square_tasks）。

1. SQL Editor 运行 `raids.sql`（新表 raids / raid_members / raid_steps / raid_jobs / raid_appeals / raid_ratings，全部开 RLS，只能通过函数写；raid_jobs 会加进 supabase_realtime）。
2. 部署 AI 裁判：`supabase functions deploy raid-judge --no-verify-jwt`（函数自己检查调用者：只认 service_role key 或 `JUDGE_HOOK_SECRET`）。
3. Secrets（裁判用 OpenAI 兼容接口；以后换成自建 RunPod 只改这三个）：
   ```
   supabase secrets set JUDGE_URL=https://…/v1 JUDGE_MODEL=… JUDGE_KEY=…
   supabase secrets set JUDGE_HOOK_SECRET=<随便一串长随机字符>
   ```
   没设 JUDGE_URL / JUDGE_MODEL / JUDGE_KEY 时，申诉一直是 `pending_judge`，不会被判，也不会自动退钱。
4. 定时调用裁判（也顺便跑 `raid_tick()`：72 小时自动通过、截止、结算）。Database → Extensions 打开 `pg_cron` 和 `pg_net`，然后：
   ```
   select cron.schedule('raid-judge', '*/10 * * * *', $$
     select net.http_post(url := 'https://<project>.supabase.co/functions/v1/raid-judge',
                          headers := '{"Content-Type":"application/json","x-judge-secret":"<JUDGE_HOOK_SECRET>"}'::jsonb,
                          body := '{}'::jsonb) $$);
   ```
   App 永远不直接调裁判。App 打开喵副本时也会跑 `raid_tick()`，所以不配 cron 也能结算，只是要有人打开。
5. 可选：完成奖励（只发奖励鱼干，默认每人每次 5 条，24 小时最多 3 次）。关掉：`insert into app_settings (key, value) values ('raid_bonus', '0') on conflict (key) do update set value = excluded.value;`

函数一览（都是 security definer，先锁副本行再动钱，每笔写 fish_ledger，task_id = 副本 id）：
- App 用：`raid_list(p_scope, p_limit)`、`raid_detail(p_raid)`、`raid_post_result(…)`、`raid_post_lend(…)`、`raid_join(…)`、`raid_leave`、`raid_kick`、`raid_cancel`、`raid_brief`、`raid_reassign`、`raid_submit`、`raid_decide`、`raid_appeal`、`raid_finish`、`raid_job_create`、`raid_job_cancel`、`raid_job_claim`、`raid_job_done`、`raid_job_fail`、`raid_rate`、`raid_captain_credit`、`raid_tick`
- 只给 service_role（raid-judge 用）：`raid_judge_claim`、`raid_judge_result`、`raid_judge_release`
- 内部：`raid_pay`（按奖池里充值 : 奖励的比例付出）、`raid_pay_step`、`raid_try_settle`、`raid_close`、`raid_start`、`raid_bonus`、`raid_lacks`、`raid_row`

规则摘要：结果副本奖池发布时锁住（先奖励鱼干再充值鱼干）；分钱比例、清单、奖池、价格发布后不能改（触发器也拦）；退回必须勾清单项 + 写理由；返工一次；72 小时不验收自动通过；申诉 10 条（不退），AI 裁判只按清单判、引用原文，判赢直接付钱并记队长「输掉申诉」；借猫副本每个活先按上限预留，做完按 min(上报, 单活上限, 2×字数+500, 每小时 60000 token) 计费，绝不超预算；结束时按用量付给队友，剩下退回队长。同一台设备或同一 IP 不能进同一个副本。

## Kündigungsbutton + Widerrufsfunktion（BGB §312k / §356a，2026-11-27 起）

官网 `kuendigen.html`（「Verträge hier kündigen」→ 确认页 →「jetzt kündigen」）和 `widerruf.html#widerrufen`（「Vertrag widerrufen」→「Widerruf bestätigen」）不用登录，直接 POST 到 Edge Function `cancel-contract`。

**运行顺序**（SQL Editor，可以重复运行）：`schema.sql` → `square.sql` → `signal.sql` → `account2.sql` → `membership.sql` → `fish.sql` → `raids.sql` → **`cancel.sql`**。
`cancel.sql` 建表 `cancel_requests`（开 RLS、没有 policy，只有 service_role 能读写）和两个只给 service_role 的函数：`cancel_find_user(p_email)`（邮箱 → auth.users.id）、`cancel_recent(p_ip_hash, p_email)`（限流计数）。

1. SQL Editor 运行 `cancel.sql`。
2. 部署（必须 `--no-verify-jwt`，网页没有登录 token）：
   ```
   supabase functions deploy cancel-contract --no-verify-jwt
   supabase functions deploy stripe-checkout
   ```
3. Secrets：
   ```
   supabase secrets set RESEND_API_KEY=re_…
   # 可选：CANCEL_MAIL_BCC=<你的邮箱>（每封确认抄送一份给自己），CANCEL_MAIL_FROM='OrdCat <noreply@ordcat.de>'
   ```
   Resend 里 `ordcat.de` 这个域名要是已验证状态（登录验证码已经在用 noreply@ordcat.de 的话就已经好了）。
   没设 `RESEND_API_KEY` 时：照样保存、网页照样显示可打印的确认，只是不发邮件（`email_sent = false`, `email_error = 'RESEND_API_KEY missing'`）。
   `STRIPE_SECRET_KEY` / `STRIPE_PRICES` 用已有的。
4. Stripe → Settings → Public details（Business details）里填 **Terms of service URL = https://ordcat.de/terms.html**。
   stripe-checkout 现在给每个 Checkout Session 加了必须勾选的 `consent_collection[terms_of_service]=required` 和 `custom_text[terms_of_service_acceptance]`（zh / en / de，按 App 传的 locale，其它用英文）；没填这个 URL 的话 Stripe 会拒绝创建付款页。

函数做的事：
- 校验输入（邮箱、合同 pro / max / x / agent / miao / all，特别解约要写理由，日期），蜜罐字段，按 IP 哈希限流（每小时每 IP 8 次、每邮箱 5 次）。
- 先存 `cancel_requests`（收到时间 = 生效的送达时间），再处理：
  - Kündigung：按邮箱找账号的订阅（`subscriptions`，provider = stripe）+ Stripe 里同邮箱的 customer 的订阅，匹配的设 `cancel_at_period_end = true`；小鱼干开通的（provider = fish）关掉 `auto_renew`。合同选「all」就全部。
  - 特别解约（außerordentlich）、希望日期晚于当前周期结束 → 也停续费，但 `status = manual`，要你手动处理（立即解约要不要退款 / 按日期设 `cancel_at`）。
  - 找不到订阅 → `status = no_match`，邮件里说会人工核实。
  - Widerruf：只保存 + 确认，`status = manual`，退款你在 Stripe 里手动做（服务按已用天数扣）。
- 马上用 Resend 发确认邮件（内容、收到日期时间 UTC 和 Europe/Berlin、结束日期），网页只显示内容和收到时间（不在网页上透露这个邮箱有没有订阅）。

查待处理：
```
select id, received_at, action, kind, email, contract, requested_date, status, matched, reason
  from cancel_requests where status in ('manual','no_match','error') and handled_at is null order by received_at;
```

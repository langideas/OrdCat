-- OrdCat · 小鱼干储值 + 邀请防刷（v0.2.62）. Run in Supabase → SQL Editor AFTER schema.sql, square.sql,
-- signal.sql, account2.sql and membership.sql. Safe to run again (if not exists / create or replace).
-- If you ever re-run square.sql or account2.sql, run this file again afterwards: it replaces some of their functions.
--
-- 规则（Lang 2026-11-25 同意，docs/plan-original-next-2026-11-25.md 第 1、2 节）：
--   1 € = 100 条小鱼干。两种鱼干，都永久有效：
--     paid   充值鱼干：Stripe 充值（fish_topup，只给 stripe-webhook 用 service_role 调），什么都能买
--     reward 奖励鱼干：新号 100、邀请、猫帮圈收到的奖励；猫帮圈发任务可以全额用；买会员 / 技能 / 加油包最多抵 30%
--   现有余额全部算奖励鱼干（一次性迁移，可重复运行）。
--   价格：Pro 990/月、9504/年；Max 5900/月、56640/年；技能 x / agent / miao 300/月（Pro / Max 会员 8 折 = 240；技能单独卖，会员不包含）；
--         加油包 300 = 1500 条托管模型额度（进 credit_wallets.bonus）。
--   扣费顺序：先奖励鱼干（不超过 30% 上限），再充值鱼干。猫帮圈：先奖励再充值，退款按原来的来源各退各的。
--   邀请：被邀请人填码马上得 30 奖励鱼干；邀请人的 50 先「待生效」，等对方邮箱（或手机号）已验证 + 小猫活跃满 3 天
--         才由 invite_settle() 发放；对方第一次充值，邀请人再得充值鱼干数的 10%（最多 500，奖励鱼干）。
--         每人每个自然月最多 20 个生效邀请（超出的留到下个月）；同一台设备只能领一次，邀请人自己的设备不能领；
--         同一邀请人 24 小时内同一 IP 只算 1 个；临时邮箱不能领。
-- 所有钱的改动都在下面的 security definer 函数里，锁住钱包那一行再改，每笔都写 fish_ledger（kind = paid | reward）。

-- ---------- 1. 钱包拆成 paid / reward ----------
alter table public.fish_wallets add column if not exists paid int not null default 0;
alter table public.fish_wallets add column if not exists reward int not null default 0;
alter table public.fish_wallets add column if not exists split_done boolean not null default false;
alter table public.fish_wallets alter column balance set default 0;
alter table public.fish_wallets drop constraint if exists fish_wallets_paid_check;
alter table public.fish_wallets add constraint fish_wallets_paid_check check (paid >= 0);
alter table public.fish_wallets drop constraint if exists fish_wallets_reward_check;
alter table public.fish_wallets add constraint fish_wallets_reward_check check (reward >= 0);

-- balance is always paid + reward. A not-yet-split row (old data, or a row written by an old function) moves its
-- whole balance into reward; an old-style "balance = balance ± n" update lands on reward (spends take reward first).
create or replace function public.fish_wallet_tg() returns trigger
language plpgsql set search_path = public as $$
declare d int; r int;
begin
  if tg_op = 'INSERT' then
    if not new.split_done then
      new.reward := coalesce(new.balance, 0); new.paid := 0; new.split_done := true;
    end if;
  elsif not old.split_done then
    new.reward := coalesce(old.balance, 0) + (coalesce(new.balance, 0) - coalesce(old.balance, 0));
    new.paid := 0; new.split_done := true;
  elsif new.balance is distinct from old.balance and new.paid = old.paid and new.reward = old.reward then
    d := coalesce(new.balance, 0) - coalesce(old.balance, 0);
    if d >= 0 then new.reward := new.reward + d;
    else
      r := least(new.reward, -d);
      new.reward := new.reward - r;
      new.paid := new.paid - (-d - r);
    end if;
  end if;
  new.balance := new.paid + new.reward;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists fish_wallet_split on public.fish_wallets;
create trigger fish_wallet_split before insert or update on public.fish_wallets
  for each row execute function public.fish_wallet_tg();
-- One-time migration: every existing balance becomes reward fish.
update public.fish_wallets set split_done = true where not split_done;

alter table public.fish_ledger add column if not exists kind text not null default 'reward';
alter table public.fish_ledger add column if not exists ref text;
alter table public.fish_ledger drop constraint if exists fish_ledger_kind_check;
alter table public.fish_ledger add constraint fish_ledger_kind_check check (kind in ('paid', 'reward'));
create index if not exists fish_ledger_user on public.fish_ledger (user_id, id desc);

-- Stripe top-ups (session id = idempotency key).
create table if not exists public.fish_topups (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  pack text not null default '',
  fish int not null check (fish > 0),
  cents int not null default 0,
  at timestamptz not null default now()
);
alter table public.fish_topups enable row level security;
drop policy if exists "own topups read" on public.fish_topups;
create policy "own topups read" on public.fish_topups for select using (auth.uid() = user_id);

-- Plans / skills opened with fish live in subscriptions too (provider = 'fish', id = 'fish:<item>:<user>').
alter table public.subscriptions add column if not exists auto_renew boolean not null default false;
alter table public.subscriptions add column if not exists fish_interval text;
alter table public.subscriptions add column if not exists renew_error text;

-- 猫帮圈: how much of a task's reward came from paid fish (refunds go back to the same buckets).
alter table public.square_tasks add column if not exists fish_paid int not null default 0;

-- ---------- 2. 邀请防刷的数据 ----------
alter table public.invite_uses add column if not exists status text not null default 'legacy';
alter table public.invite_uses alter column status set default 'pending';  -- pending | effective | dup_ip | frozen | legacy
alter table public.invite_uses add column if not exists device_hash text;
alter table public.invite_uses add column if not exists ip_hash text;
alter table public.invite_uses add column if not exists settled_at timestamptz;
alter table public.invite_uses add column if not exists topup_bonus int not null default 0;
create unique index if not exists invite_uses_device on public.invite_uses (device_hash) where device_hash is not null;
create index if not exists invite_uses_owner on public.invite_uses (owner_id, status);

-- Devices each account has used (SHA-256 of IOPlatformUUID + app salt, made on the Mac; never the raw id).
create table if not exists public.fish_devices (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_hash text not null check (device_hash ~ '^[0-9a-f]{64}$'),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (user_id, device_hash)
);
create index if not exists fish_devices_hash on public.fish_devices (device_hash);
alter table public.fish_devices enable row level security;

create table if not exists public.invite_blocked_domains (domain text primary key);
alter table public.invite_blocked_domains enable row level security;
insert into public.invite_blocked_domains (domain) values
  ('mailinator.com'), ('guerrillamail.com'), ('guerrillamail.net'), ('sharklasers.com'), ('grr.la'), ('10minutemail.com'),
  ('temp-mail.org'), ('tempmail.com'), ('tempmail.plus'), ('tempmailo.com'), ('yopmail.com'), ('trashmail.com'),
  ('getnada.com'), ('dispostable.com'), ('maildrop.cc'), ('throwawaymail.com'), ('fakeinbox.com'), ('mohmal.com'),
  ('emailondeck.com'), ('minuteinbox.com'), ('mailnesia.com'), ('1secmail.com'), ('moakt.com'), ('tempr.email'),
  ('burnermail.io'), ('spamgourmet.com'), ('mintemail.com'), ('mail.tm'), ('linshiyouxiang.net'), ('bccto.me'),
  ('chacuo.net'), ('027168.com'), ('snapmail.cc'), ('emailfake.com')
on conflict do nothing;

-- Calendar days (UTC) on which the cat sent at least one heartbeat. Filled by a trigger on cat_levels, so
-- account2.sql's cat_heartbeat stays as it is. Counting starts when this file is first run.
create table if not exists public.cat_active_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  primary key (user_id, day)
);
alter table public.cat_active_days enable row level security;
create or replace function public.cat_active_tg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.last_beat is not null then
    insert into cat_active_days (user_id, day) values (new.user_id, (new.last_beat at time zone 'utc')::date)
    on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists cat_active_day on public.cat_levels;
create trigger cat_active_day after insert or update of last_beat on public.cat_levels
  for each row execute function public.cat_active_tg();

-- ---------- 3. 内部函数（客户端不能直接调） ----------

-- First use: 100 reward fish.
create or replace function public.fish_ensure(uid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare b int; n int;
begin
  insert into fish_wallets (user_id, paid, reward, balance, split_done) values (uid, 0, 100, 100, true)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    insert into fish_ledger (user_id, delta, reason, kind) values (uid, 100, 'welcome', 'reward');
  end if;
  select balance into b from fish_wallets where user_id = uid;
  return b;
end $$;

-- Add fish to one bucket.
create or replace function public.fish_credit(uid uuid, p_kind text, p_amount int, p_reason text,
                                              p_task uuid default null, p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_amount is null or p_amount <= 0 then return; end if;
  if p_kind not in ('paid', 'reward') then raise exception 'bad fish kind %', p_kind; end if;
  perform fish_ensure(uid);
  perform 1 from fish_wallets where user_id = uid for update;
  if p_kind = 'paid' then update fish_wallets set paid = paid + p_amount where user_id = uid;
  else update fish_wallets set reward = reward + p_amount where user_id = uid; end if;
  insert into fish_ledger (user_id, delta, reason, kind, task_id, ref) values (uid, p_amount, p_reason, p_kind, p_task, p_ref);
end $$;

-- Take p_amount: reward first (at most p_reward_cap), the rest from paid. Returns {from_reward, from_paid}.
create or replace function public.fish_take(uid uuid, p_amount int, p_reward_cap int, p_reason text,
                                            p_task uuid default null, p_ref text default null) returns int[]
language plpgsql security definer set search_path = public as $$
declare w fish_wallets; r int; p int;
begin
  if p_amount is null or p_amount <= 0 then return array[0, 0]; end if;
  perform fish_ensure(uid);
  select * into w from fish_wallets where user_id = uid for update;
  r := least(w.reward, greatest(coalesce(p_reward_cap, 0), 0), p_amount);
  p := p_amount - r;
  if w.paid < p then
    if p_reward_cap < p_amount then
      raise exception '小鱼干不够：要 % 条，奖励鱼干能抵 % 条，还差 % 条充值鱼干', p_amount, least(w.reward, p_reward_cap), p - w.paid;
    end if;
    raise exception '小鱼干不够（还有 % 条）', w.paid + w.reward;
  end if;
  update fish_wallets set reward = reward - r, paid = paid - p where user_id = uid;
  if r > 0 then insert into fish_ledger (user_id, delta, reason, kind, task_id, ref) values (uid, -r, p_reason, 'reward', p_task, p_ref); end if;
  if p > 0 then insert into fish_ledger (user_id, delta, reason, kind, task_id, ref) values (uid, -p, p_reason, 'paid', p_task, p_ref); end if;
  return array[r, p];
end $$;

-- Prices in fish. item: pro | max | x | agent | miao | credits (加油包). interval: month | year.
create or replace function public.fish_price(p_item text, p_interval text, p_user uuid) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  return case
    when p_item = 'pro' and p_interval = 'year' then 9504
    when p_item = 'pro' then 990
    when p_item = 'max' and p_interval = 'year' then 56640
    when p_item = 'max' then 5900
    when p_item in ('x', 'agent', 'miao') and p_interval = 'month' then
      case when ord_plan(p_user) in ('pro', 'max') then 240 else 300 end     -- Pro / Max: skills 20% off (same as Stripe *.member)
    when p_item = 'credits' then 300
    else null end;
end $$;

-- ---------- 4. 用户能调的函数 ----------

-- Device seen on this account (ignored unless it looks like a SHA-256 hex).
create or replace function public.fish_note_device(uid uuid, p_device text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if uid is null or p_device is null or lower(p_device) !~ '^[0-9a-f]{64}$' then return; end if;
  insert into fish_devices (user_id, device_hash) values (uid, lower(p_device))
  on conflict (user_id, device_hash) do update set last_seen = now();
end $$;

-- What 设置 → 用户 → 小鱼干 shows.
create or replace function public.fish_status(p_device text default null) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); w fish_wallets;
begin
  if uid is null then raise exception '还没登录'; end if;
  perform fish_ensure(uid);
  perform fish_note_device(uid, p_device);
  select * into w from fish_wallets where user_id = uid;
  return json_build_object(
    'total', w.paid + w.reward, 'paid', w.paid, 'reward', w.reward, 'reward_cap_pct', 30,
    'plan', ord_plan(uid),
    'prices', json_build_object('pro.month', 990, 'pro.year', 9504, 'max.month', 5900, 'max.year', 56640,
                                'skill.month', fish_price('x', 'month', uid), 'credits', 300, 'credits_messages', 1500),
    'subs', coalesce((select json_agg(json_build_object('item', s.skill, 'interval', s.fish_interval, 'ends_at', s.ends_at,
                                                        'auto_renew', s.auto_renew, 'renew_error', s.renew_error)
                                      order by s.ends_at desc)
                      from subscriptions s where s.user_id = uid and s.provider = 'fish' and s.ends_at > now() - interval '30 days'),
                     '[]'::json));
end $$;

-- 流水.
create or replace function public.fish_history(p_before bigint default null, p_limit int default 100)
returns table (id bigint, delta int, kind text, reason text, task_id uuid, ref text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select l.id, l.delta, l.kind, l.reason, l.task_id, l.ref, l.created_at from fish_ledger l
  where l.user_id = auth.uid() and (p_before is null or l.id < p_before)
  order by l.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 300);
$$;

-- 加油包开关（v0.2.64+，Lang 2026-11-27：先暂停卖加油包）。唯一的开关：改成 select true 再运行就重新开卖
-- （topup_off.sql 里是同一个函数）。已经买到的加油包额度（credit_wallets.bonus）照常能用。
create or replace function public.fish_topup_on() returns boolean
language sql stable as $$ select false $$;

-- Open (or extend) a plan / skill for 30 days (365 for yearly), or buy a 加油包 (item 'credits').
create or replace function public.fish_buy(p_item text, p_interval text default 'month', p_auto boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  iv text := case when p_interval = 'year' then 'year' else 'month' end;
  price int; parts int[]; sid text; cur timestamptz; base timestamptz; new_end timestamptz; plan text;
begin
  if uid is null then raise exception '还没登录'; end if;
  if p_item not in ('pro', 'max', 'x', 'agent', 'miao', 'credits') then raise exception '没有这个商品'; end if;
  if p_item in ('x', 'agent', 'miao', 'credits') then iv := 'month'; end if;
  if p_item = 'credits' and not fish_topup_on() then raise exception '加油包暂停销售 / Top-ups are paused'; end if;
  plan := ord_plan(uid);
  if p_item = 'pro' and plan = 'max' then raise exception '你现在是 Max，已经包含 Pro 的全部内容'; end if;
  price := fish_price(p_item, iv, uid);
  if price is null then raise exception '没有这个价格'; end if;

  if p_item = 'credits' then
    parts := fish_take(uid, price, price * 30 / 100, 'buy:credits');
    perform ord_wallet_sync(uid);
    update credit_wallets set bonus = bonus + 1500, updated_at = now() where user_id = uid;
    return json_build_object('ok', true, 'item', 'credits', 'price', price, 'from_reward', parts[1], 'from_paid', parts[2],
                             'messages', 1500, 'total', fish_ensure(uid));
  end if;

  sid := 'fish:' || p_item || ':' || uid::text;
  parts := fish_take(uid, price, price * 30 / 100, 'buy:' || p_item || '.' || iv, null, sid);
  select ends_at into cur from subscriptions where id = sid for update;
  base := greatest(now(), coalesce(cur, now()));
  new_end := base + case when iv = 'year' then interval '365 days' else interval '30 days' end;
  insert into subscriptions (id, user_id, skill, status, renews_at, ends_at, provider, auto_renew, fish_interval, renew_error, updated_at)
  values (sid, uid, p_item, 'active', case when coalesce(p_auto, false) then new_end end, new_end, 'fish',
          coalesce(p_auto, false), iv, null, now())
  on conflict (id) do update set status = 'active', ends_at = excluded.ends_at, renews_at = excluded.renews_at,
    auto_renew = excluded.auto_renew, fish_interval = excluded.fish_interval, renew_error = null, updated_at = now();
  if p_item in ('pro', 'max') then perform ord_wallet_sync(uid); end if;
  return json_build_object('ok', true, 'item', p_item, 'interval', iv, 'price', price, 'from_reward', parts[1],
                           'from_paid', parts[2], 'ends_at', new_end, 'auto_renew', coalesce(p_auto, false),
                           'total', fish_ensure(uid));
end $$;

create or replace function public.fish_set_autorenew(p_item text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception '还没登录'; end if;
  update subscriptions set auto_renew = coalesce(p_on, false),
         renews_at = case when coalesce(p_on, false) then ends_at end, renew_error = null, updated_at = now()
  where id = 'fish:' || p_item || ':' || uid::text and user_id = uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception '还没有用小鱼干开通这一项'; end if;
  return json_build_object('ok', true, 'item', p_item, 'auto_renew', coalesce(p_on, false));
end $$;

-- Cron / edge function (service_role): renew fish plans that end within a day and have auto-renew on.
-- Not enough fish → auto-renew turns off and renew_error says why.
create or replace function public.fish_autorenew_due() returns json
language plpgsql security definer set search_path = public as $$
declare s record; price int; ok int := 0; bad int := 0;
begin
  for s in select * from subscriptions
           where provider = 'fish' and auto_renew and ends_at <= now() + interval '1 day' and ends_at > now() - interval '7 days'
           order by ends_at for update skip locked loop
    begin
      price := fish_price(s.skill, coalesce(s.fish_interval, 'month'), s.user_id);
      perform fish_take(s.user_id, price, price * 30 / 100, 'renew:' || s.skill || '.' || coalesce(s.fish_interval, 'month'), null, s.id);
      update subscriptions set
        ends_at = greatest(ends_at, now()) + case when fish_interval = 'year' then interval '365 days' else interval '30 days' end,
        status = 'active', renew_error = null, updated_at = now()
      where id = s.id;
      update subscriptions set renews_at = ends_at where id = s.id;
      if s.skill in ('pro', 'max') then perform ord_wallet_sync(s.user_id); end if;
      ok := ok + 1;
    exception when others then
      update subscriptions set auto_renew = false, renews_at = null, renew_error = left(sqlerrm, 200), updated_at = now()
      where id = s.id;
      bad := bad + 1;
    end;
  end loop;
  return json_build_object('renewed', ok, 'failed', bad);
end $$;

-- Stripe webhook (service_role only): a paid top-up adds paid fish exactly once per checkout session.
-- The buyer's first top-up gives their inviter 10% of it as reward fish (max 500).
create or replace function public.fish_topup(p_session text, p_user uuid, p_fish int, p_cents int default 0, p_pack text default '')
returns boolean language plpgsql security definer set search_path = public as $$
declare n int; u invite_uses; bonus int;
begin
  if p_session is null or p_user is null or coalesce(p_fish, 0) <= 0 then raise exception 'bad top-up'; end if;
  insert into fish_topups (id, user_id, pack, fish, cents) values (p_session, p_user, coalesce(p_pack, ''), p_fish, coalesce(p_cents, 0))
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return false; end if;
  perform fish_credit(p_user, 'paid', p_fish, 'topup', null, p_session);
  if (select count(*) from fish_topups where user_id = p_user) = 1 then
    select * into u from invite_uses where invitee_id = p_user for update;
    if u.invitee_id is not null and u.status not in ('dup_ip', 'frozen') and u.topup_bonus = 0 then
      bonus := least(500, p_fish / 10);
      if bonus > 0 then
        update invite_uses set topup_bonus = bonus where invitee_id = p_user;
        perform fish_credit(u.owner_id, 'reward', bonus, 'invite_topup', null, p_user::text);
      end if;
    end if;
  end if;
  return true;
end $$;

-- ---------- 5. 猫帮圈：先用奖励鱼干，再用充值鱼干；退款各回各的 ----------

create or replace function public.square_post(p_title text, p_body text, p_kind text, p_needs text[],
                                              p_reward int, p_image text default null, p_name text default '',
                                              p_links jsonb default '[]'::jsonb, p_files jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); w fish_wallets; tid uuid; parts int[];
begin
  if uid is null then raise exception '还没登录'; end if;
  if p_reward < 1 or p_reward > 1000 then raise exception '奖励要在 1 到 1000 条小鱼干之间'; end if;
  if jsonb_typeof(coalesce(p_links, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_links, '[]'::jsonb)) > 10 then
    raise exception '链接最多 10 个'; end if;
  if jsonb_typeof(coalesce(p_files, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_files, '[]'::jsonb)) > 5 then
    raise exception '附件最多 5 个'; end if;
  if (select count(*) from square_tasks where poster_id = uid and status in ('open','claimed','answered')) >= 10 then
    raise exception '同时进行中的任务最多 10 个';
  end if;
  perform fish_ensure(uid);
  select * into w from fish_wallets where user_id = uid for update;
  if w.paid + w.reward < p_reward then raise exception '小鱼干不够（还有 % 条）', w.paid + w.reward; end if;
  insert into square_tasks (poster_id, poster_name, title, body, kind, needs, reward, image_url, links, files)
  values (uid, coalesce(p_name, ''), p_title, coalesce(p_body, ''), coalesce(p_kind, '其他'),
          coalesce(p_needs, '{text}'), p_reward, p_image, coalesce(p_links, '[]'::jsonb), coalesce(p_files, '[]'::jsonb))
  returning id into tid;
  parts := fish_take(uid, p_reward, p_reward, 'post', tid);
  update square_tasks set fish_paid = parts[2] where id = tid;
  return tid;
end $$;

-- Solvers are paid in reward fish.
create or replace function public.square_accept(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); t square_tasks;
begin
  select * into t from square_tasks where id = p_task for update;
  if t.id is null or t.poster_id <> uid or t.status <> 'answered' then raise exception '这个任务现在不能采纳'; end if;
  update square_tasks set status = 'done' where id = p_task;
  perform fish_credit(t.solver_id, 'reward', t.reward, 'reward', p_task);
end $$;

create or replace function public.square_cancel(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); t square_tasks; pp int;
begin
  perform square_expire();
  select * into t from square_tasks where id = p_task for update;
  if t.id is null or t.poster_id <> uid or t.status <> 'open' then raise exception '只有还没人接的任务能取消'; end if;
  update square_tasks set status = 'cancelled' where id = p_task;
  pp := least(greatest(coalesce(t.fish_paid, 0), 0), t.reward);
  perform fish_credit(uid, 'reward', t.reward - pp, 'refund', p_task);
  perform fish_credit(uid, 'paid', pp, 'refund', p_task);
end $$;

-- ---------- 6. 邀请（防刷） ----------
drop function if exists public.invite_my_code();
drop function if exists public.invite_redeem(text);

-- Pay the inviter's pending 50 for invitees that have a verified email (or phone) and ≥ 3 active days.
-- Max 20 effective invites per inviter per calendar month (UTC); the rest wait for next month.
-- Signed in: settles your own invites. service_role with p_owner null: settles everyone. Safe to run any time.
create or replace function public.invite_settle(p_owner uuid default null) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := coalesce(auth.uid(), p_owner); r record; n int := 0; month_n int;
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'service_role') then
    raise exception '还没登录';
  end if;
  for r in select u.invitee_id, u.owner_id from invite_uses u
           join auth.users au on au.id = u.invitee_id
           where u.status = 'pending' and (me is null or u.owner_id = me)
             and (au.email_confirmed_at is not null or au.phone_confirmed_at is not null)
             and ((select count(*) from cat_active_days a where a.user_id = u.invitee_id) >= 3
                  or coalesce((select l.days from cat_levels l where l.user_id = u.invitee_id), 0) >= 3)
           order by u.created_at
           for update of u skip locked loop
    select count(*) into month_n from invite_uses
     where owner_id = r.owner_id and status = 'effective' and settled_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc';
    continue when month_n >= 20;
    update invite_uses set status = 'effective', settled_at = now() where invitee_id = r.invitee_id;
    perform fish_credit(r.owner_id, 'reward', 50, 'invite', null, r.invitee_id::text);
    n := n + 1;
  end loop;
  return json_build_object('settled', n, 'fish', n * 50);
end $$;

create or replace function public.invite_my_code(p_device text default null) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c text; s json;
begin
  if uid is null then raise exception '还没登录'; end if;
  perform fish_note_device(uid, p_device);
  select code into c from invite_codes where owner_id = uid;
  while c is null loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text || uid::text), 1, 6));
    if char_length(c) = 6 and not exists (select 1 from invite_codes where code = c) then
      insert into invite_codes (owner_id, code) values (uid, c);
    else c := null; end if;
  end loop;
  s := invite_settle(uid);
  return (select json_build_object(
    'code', c,
    'invited', count(*),
    'effective', count(*) filter (where status in ('effective', 'legacy')),
    'pending', count(*) filter (where status = 'pending'),
    'month_effective', count(*) filter (where status = 'effective'
                                        and settled_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc'),
    'month_cap', 20, 'reward', 50, 'invitee_reward', 30, 'just_settled', (s ->> 'settled')::int)
    from invite_uses where owner_id = uid);
end $$;

-- A new account (≤ 7 days old) redeems one code from this Mac. Invitee: 30 reward fish now. Inviter: 50 later.
create or replace function public.invite_redeem(p_code text, p_device text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); owner uuid; joined timestamptz; mail text; dev text := lower(coalesce(p_device, ''));
  ip text; iph text; dup boolean := false;
begin
  if uid is null then raise exception '还没登录'; end if;
  if dev !~ '^[0-9a-f]{64}$' then raise exception '请先把 OrdCat 更新到最新版再填邀请码'; end if;
  select owner_id into owner from invite_codes where code = upper(trim(p_code));
  if owner is null then raise exception '邀请码不对'; end if;
  if owner = uid then raise exception '不能填自己的邀请码'; end if;
  if exists (select 1 from invite_uses where invitee_id = uid) then raise exception '你已经填过邀请码了'; end if;
  select created_at, lower(coalesce(email, '')) into joined, mail from auth.users where id = uid;
  if joined < now() - interval '7 days' then raise exception '邀请码只能在注册 7 天内填写'; end if;
  if mail like '%@%' and exists (select 1 from invite_blocked_domains d where d.domain = split_part(mail, '@', 2)) then
    raise exception '临时邮箱不能领邀请奖励，换个常用邮箱注册吧';
  end if;
  if exists (select 1 from invite_uses where device_hash = dev) then raise exception '这台 Mac 已经领过邀请奖励了'; end if;
  if exists (select 1 from fish_devices where user_id = owner and device_hash = dev) then
    raise exception '不能在邀请人自己的 Mac 上填他的邀请码';
  end if;
  begin
    ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1));
  exception when others then ip := '';
  end;
  if ip <> '' then
    iph := encode(sha256(convert_to(ip, 'UTF8')), 'hex');
    dup := exists (select 1 from invite_uses where owner_id = owner and ip_hash = iph and created_at > now() - interval '24 hours');
  end if;
  perform fish_note_device(uid, dev);
  insert into invite_uses (invitee_id, owner_id, status, device_hash, ip_hash)
  values (uid, owner, case when dup then 'dup_ip' else 'pending' end, dev, iph);
  perform fish_credit(uid, 'reward', 30, 'invite', null, owner::text);
  insert into cat_follows (follower_id, followee_id) values (uid, owner), (owner, uid) on conflict do nothing;
  return json_build_object('ok', true, 'reward', 30, 'inviter_pending', not dup);
end $$;

-- ---------- grants ----------
revoke all on function public.fish_wallet_tg(), public.cat_active_tg(), public.fish_ensure(uuid),
  public.fish_credit(uuid, text, int, text, uuid, text), public.fish_take(uuid, int, int, text, uuid, text),
  public.fish_price(text, text, uuid), public.fish_note_device(uuid, text), public.fish_autorenew_due(),
  public.fish_topup(text, uuid, int, int, text) from public, anon, authenticated;
grant execute on function public.fish_autorenew_due(), public.fish_topup(text, uuid, int, int, text),
  public.invite_settle(uuid) to service_role;
revoke all on function public.fish_status(text), public.fish_history(bigint, int), public.fish_buy(text, text, boolean),
  public.fish_set_autorenew(text, boolean), public.invite_settle(uuid), public.invite_my_code(text),
  public.invite_redeem(text, text) from public, anon;
grant execute on function public.fish_status(text), public.fish_history(bigint, int), public.fish_buy(text, text, boolean),
  public.fish_set_autorenew(text, boolean), public.invite_settle(uuid), public.invite_my_code(text),
  public.invite_redeem(text, text), public.fish_balance(),
  public.square_post(text, text, text, text[], int, text, text, jsonb, jsonb), public.square_accept(uuid),
  public.square_cancel(uuid) to authenticated;

-- OrdCat · 会员与托管模型额度（Stripe）。在 schema.sql / signal.sql / account2.sql 之后运行，可以重复运行。
--
-- 方案（Lang 2026-11-23 同意）：
--   免费      自带 Key 什么都能用；新用户一次性送 100 条托管额度试用
--   会员      ¥30 / €3.99 每月 2000 条，每天最多 200 条
--   会员 Pro  ¥68 / €8.99 每月 6000 条，每天最多 500 条，可选高级模型（按倍数扣）
--   额度用完：每天 30 条慢速模型；或买加油包 ¥18 = 1200 条
-- 1 条 = 一条普通消息；带截图 +1；上下文超过 8k token +1；高级模型 × 倍数。
--
-- subscriptions.skill 现在可以是：member | pro | x | agent（技能）。

alter table public.subscriptions add column if not exists provider text not null default 'lemon';
alter table public.subscriptions add column if not exists customer_id text;
alter table public.subscriptions add column if not exists price_id text;

-- 「订阅会员」只算会员 / 会员 Pro（技能订阅不算会员）。信号站的「仅会员」条件也按这个算。
create or replace function public.ord_is_member(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from subscriptions s
                 where s.user_id = p_user and s.skill in ('member', 'pro') and s.status not in ('expired', 'unpaid', 'canceled', 'incomplete_expired')
                   and coalesce(s.ends_at, s.renews_at, now() + interval '32 days') > now());
$$;

create or replace function public.ord_plan(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select case when bool_or(s.skill = 'pro') then 'pro' else 'member' end
                   from subscriptions s
                   where s.user_id = p_user and s.skill in ('member', 'pro')
                     and s.status not in ('expired', 'unpaid', 'canceled', 'incomplete_expired')
                     and coalesce(s.ends_at, s.renews_at, now() + interval '32 days') > now()
                   having count(*) > 0), 'free');
$$;

-- ---------- 额度钱包 ----------
create table if not exists public.credit_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free',
  monthly_left int not null default 0,      -- 本期会员额度（到期清零重发）
  bonus int not null default 100,           -- 试用 + 加油包（不过期）
  period_end timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.credit_wallets enable row level security;
drop policy if exists "own wallet read" on public.credit_wallets;
create policy "own wallet read" on public.credit_wallets for select using (auth.uid() = user_id);

create table if not exists public.usage_ledger (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  at timestamptz not null default now(),
  tier text not null,                       -- hosted | slow
  model text not null default '',
  prompt_tokens int not null default 0,
  completion_tokens int not null default 0,
  credits int not null default 0,
  cost_usd numeric(12, 6) not null default 0
);
create index if not exists usage_ledger_user_at on public.usage_ledger (user_id, at desc);
alter table public.usage_ledger enable row level security;
drop policy if exists "own usage read" on public.usage_ledger;
create policy "own usage read" on public.usage_ledger for select using (auth.uid() = user_id);

create table if not exists public.credit_topups (
  id text primary key,                      -- Stripe checkout session id（防止重复加）
  user_id uuid not null references auth.users(id) on delete cascade,
  credits int not null,
  at timestamptz not null default now()
);
alter table public.credit_topups enable row level security;

create or replace function public.ord_quota(p_plan text) returns int language sql immutable as $$
  select case p_plan when 'pro' then 6000 when 'member' then 2000 else 0 end;
$$;
create or replace function public.ord_daily_cap(p_plan text) returns int language sql immutable as $$
  select case p_plan when 'pro' then 500 when 'member' then 200 else 100 end;
$$;

-- Make sure the wallet exists and matches the current plan; start a new month of credits when due.
create or replace function public.ord_wallet_sync(p_user uuid) returns public.credit_wallets
language plpgsql security definer set search_path = public as $$
declare
  w credit_wallets;
  p text := ord_plan(p_user);
  pend timestamptz;
begin
  insert into credit_wallets (user_id) values (p_user) on conflict do nothing;
  select * into w from credit_wallets where user_id = p_user for update;
  if p = 'free' then
    if w.plan <> 'free' then
      update credit_wallets set plan = 'free', monthly_left = 0, period_end = null, updated_at = now()
       where user_id = p_user returning * into w;
    end if;
    return w;
  end if;
  if w.plan <> p or w.period_end is null or w.period_end <= now() then
    pend := greatest(now() + interval '1 month',
                     coalesce((select max(coalesce(s.renews_at, s.ends_at)) from subscriptions s
                               where s.user_id = p_user and s.skill = p), now()));
    if pend > now() + interval '13 months' then pend := now() + interval '1 month'; end if;
    -- Yearly plans still get credits month by month.
    if pend > now() + interval '32 days' then pend := now() + interval '1 month'; end if;
    update credit_wallets
       set plan = p,
           monthly_left = case when w.plan = 'member' and p = 'pro' and w.period_end > now()
                               then ord_quota('pro') - (ord_quota('member') - w.monthly_left)   -- upgrade mid-month
                               else ord_quota(p) end,
           period_end = pend, updated_at = now()
     where user_id = p_user returning * into w;
  end if;
  return w;
end $$;

-- What the app shows in 设置 → 用户 → 会员.
create or replace function public.credits_status() returns json
language plpgsql security definer set search_path = public as $$
declare
  w credit_wallets;
  used int;
  slow int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  w := ord_wallet_sync(auth.uid());
  select coalesce(sum(credits) filter (where tier = 'hosted'), 0), count(*) filter (where tier = 'slow')
    into used, slow from usage_ledger where user_id = auth.uid() and at > date_trunc('day', now());
  return json_build_object('plan', w.plan, 'monthly_left', w.monthly_left, 'monthly_total', ord_quota(w.plan),
                           'bonus', w.bonus, 'period_end', w.period_end,
                           'today_used', used, 'daily_cap', ord_daily_cap(w.plan),
                           'slow_today', slow, 'slow_cap', 30);
end $$;

-- Proxy, before calling the model: may this user send one more message, and on which tier?
create or replace function public.proxy_admit(p_user uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  w credit_wallets;
  used int;
  slow int;
  recent int;
begin
  w := ord_wallet_sync(p_user);
  select coalesce(sum(credits) filter (where tier = 'hosted'), 0), count(*) filter (where tier = 'slow')
    into used, slow from usage_ledger where user_id = p_user and at > date_trunc('day', now());
  select count(*) into recent from usage_ledger where user_id = p_user and at > now() - interval '1 minute';
  if recent >= 20 then
    return json_build_object('ok', false, 'plan', w.plan, 'reason', 'too_fast');
  end if;
  if w.monthly_left + w.bonus > 0 and used < ord_daily_cap(w.plan) then
    return json_build_object('ok', true, 'tier', 'hosted', 'plan', w.plan, 'left', w.monthly_left + w.bonus);
  end if;
  if slow < 30 then
    return json_build_object('ok', true, 'tier', 'slow', 'plan', w.plan,
                             'reason', case when used >= ord_daily_cap(w.plan) then 'daily_cap' else 'no_credits' end);
  end if;
  return json_build_object('ok', false, 'plan', w.plan, 'reason', 'slow_cap');
end $$;

-- Proxy, after the answer: record the real usage and take the credits (monthly first, then bonus).
create or replace function public.consume_credits(p_user uuid, p_tier text, p_credits int, p_model text,
                                                  p_prompt int, p_completion int, p_cost numeric)
returns int language plpgsql security definer set search_path = public as $$
declare
  w credit_wallets;
  take_m int;
  take_b int;
  n int := case when p_tier = 'hosted' then greatest(0, p_credits) else 0 end;
begin
  select * into w from credit_wallets where user_id = p_user for update;
  if not found then w := ord_wallet_sync(p_user); end if;
  take_m := least(n, greatest(w.monthly_left, 0));
  take_b := least(n - take_m, greatest(w.bonus, 0));
  update credit_wallets set monthly_left = monthly_left - take_m, bonus = bonus - take_b, updated_at = now()
   where user_id = p_user;
  insert into usage_ledger (user_id, tier, model, prompt_tokens, completion_tokens, credits, cost_usd)
  values (p_user, p_tier, left(coalesce(p_model, ''), 80), coalesce(p_prompt, 0), coalesce(p_completion, 0),
          take_m + take_b, coalesce(p_cost, 0));
  return (w.monthly_left - take_m) + (w.bonus - take_b);
end $$;

-- Stripe webhook: a paid top-up adds bonus credits once.
create or replace function public.credit_topup(p_session text, p_user uuid, p_credits int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into credit_topups (id, user_id, credits) values (p_session, p_user, p_credits);
  insert into credit_wallets (user_id) values (p_user) on conflict do nothing;
  update credit_wallets set bonus = bonus + p_credits, updated_at = now() where user_id = p_user;
  return true;
exception when unique_violation then
  return false;
end $$;

-- Stripe webhook: a new paid period (invoice paid) starts a fresh month of credits.
create or replace function public.credit_new_period(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into credit_wallets (user_id) values (p_user) on conflict do nothing;
  update credit_wallets set period_end = null where user_id = p_user;
  perform ord_wallet_sync(p_user);
end $$;

revoke all on function public.ord_wallet_sync(uuid), public.proxy_admit(uuid),
  public.consume_credits(uuid, text, int, text, int, int, numeric), public.credit_topup(text, uuid, int),
  public.credit_new_period(uuid), public.ord_plan(uuid) from public, anon, authenticated;
grant execute on function public.ord_wallet_sync(uuid), public.proxy_admit(uuid),
  public.consume_credits(uuid, text, int, text, int, int, numeric), public.credit_topup(text, uuid, int),
  public.credit_new_period(uuid), public.ord_plan(uuid) to service_role;
grant execute on function public.credits_status() to authenticated;
grant execute on function public.ord_quota(text), public.ord_daily_cap(text) to authenticated;

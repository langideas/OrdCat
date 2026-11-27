-- OrdCat · 暂停卖加油包（v0.2.64+，Lang 2026-11-27）。在 Supabase → SQL Editor 运行；可以重复运行。
-- 要在 fish.sql 之后运行（fish.sql 已经包含同样的内容，新装的话只跑 fish.sql 也一样）。
-- 只改两样：
--   1) 新函数 fish_topup_on()：唯一的开关，现在返回 false。
--   2) fish_buy：item 'credits'（加油包，300 条小鱼干 = 1500 条托管消息）在开关关着时报错「加油包暂停销售 / Top-ups are paused」，
--      其它商品（pro / max / x / agent / miao）和原来完全一样。
-- 已经买到的加油包额度（credit_wallets.bonus）、流水里的「买加油包」、App 里的「加油包余额」都不受影响。
-- 重新开卖：把下面 fish_topup_on() 里的 select false 改成 select true 再运行这个文件（fish.sql 里也改一下，保持一致）。

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

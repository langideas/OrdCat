-- OrdCat · 信号站📶 + 小猫等级 + 喵友 + 订阅会员. Run in Supabase → SQL Editor (after schema.sql).
-- 可以重复运行（create table if not exists / create or replace / drop policy if exists）。
--
-- 信号站：用户把小猫从桌面看到的有价值信息（自己先审过、改过）分享出去，并设置谁能看：
--   最低小猫等级、最少喵友数、仅订阅会员、需要拥有某些技能。
-- 不满足条件的人只拿到标题和缺少的条件，正文根本不会发给他们：signals 表别人直接读不到，
-- 只能通过 security definer 函数 signal_feed() 读取，函数里按条件把正文换成 null。
--
-- 小猫等级（像 QQ 等级）：按活跃天数点亮，没有上限。升到 Lv N 需要 N*N + 4*N 天（Lv1 = 5 天）。
--   活跃天数由 cat_touch() 记，每个用户每天（UTC）最多 +1。第一次同步时，可以带上本机已记的天数，最多算 30 天。
-- 喵友：单向关注，「喵友数」= 关注你的人数。
-- 订阅会员：subscriptions 里有任何一个仍有效的订阅。

-- ---------- 小猫等级 ----------
create table if not exists public.cat_levels (
  user_id uuid primary key references auth.users(id) on delete cascade,
  days int not null default 0 check (days >= 0),
  last_day date,
  updated_at timestamptz not null default now()
);
alter table public.cat_levels enable row level security;
drop policy if exists "cat level read" on public.cat_levels;
create policy "cat level read" on public.cat_levels for select using (auth.role() = 'authenticated');
-- 没有 insert / update 策略：只能通过 cat_touch() 改。

-- ---------- 喵友（单向关注） ----------
create table if not exists public.cat_follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  followee_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists cat_follows_followee on public.cat_follows (followee_id);
alter table public.cat_follows enable row level security;
drop policy if exists "follow read" on public.cat_follows;
create policy "follow read" on public.cat_follows for select using (auth.role() = 'authenticated');
drop policy if exists "follow insert own" on public.cat_follows;
create policy "follow insert own" on public.cat_follows for insert with check (auth.uid() = follower_id);
drop policy if exists "follow delete own" on public.cat_follows;
create policy "follow delete own" on public.cat_follows for delete using (auth.uid() = follower_id);

-- ---------- 信号 ----------
create table if not exists public.signals (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null default '',
  author_avatar text,
  title text not null check (char_length(title) between 2 and 80),
  body text not null default '' check (char_length(body) <= 8000),
  grade int not null default 1 check (grade between 1 and 4),          -- 1 普通 · 2 优质 · 3 稀有 · 4 绝密
  min_level int not null default 0 check (min_level between 0 and 999),
  min_followers int not null default 0 check (min_followers between 0 and 1000000),
  member_only boolean not null default false,
  need_skills text[] not null default '{}',                              -- skill ids from Skills.swift: x | agent
  source_app text not null default '',
  status text not null default 'live',                                  -- live | deleted
  created_at timestamptz not null default now()
);
create index if not exists signals_live on public.signals (status, created_at desc);
create index if not exists signals_author on public.signals (author_id, created_at desc);
alter table public.signals enable row level security;
-- 只有作者自己能直接读自己的信号；其他人一律走 signal_feed()（会按条件隐藏正文）。没有写策略：只能用函数写。
drop policy if exists "signal own read" on public.signals;
create policy "signal own read" on public.signals for select using (auth.uid() = author_id);

-- ---------- helpers ----------

-- Level from active days: the highest N with N*N + 4*N <= days.
create or replace function public.ord_level(p_days int) returns int
language plpgsql immutable as $$
declare n int := greatest(floor(sqrt(greatest(coalesce(p_days, 0), 0) + 4)::numeric)::int - 2, 0);
begin
  while (n + 1) * (n + 1) + 4 * (n + 1) <= coalesce(p_days, 0) loop n := n + 1; end loop;
  while n > 0 and n * n + 4 * n > coalesce(p_days, 0) loop n := n - 1; end loop;
  return n;
end $$;

-- Any subscription still valid (same rule as the app: expired / unpaid don't count; no date = 32 days from now).
create or replace function public.ord_is_member(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from subscriptions s
                 where s.user_id = p_user and s.status not in ('expired', 'unpaid')
                   and coalesce(s.ends_at, s.renews_at, now() + interval '32 days') > now());
$$;

-- Owns (has a valid subscription to) this skill.
create or replace function public.ord_has_skill(p_user uuid, p_skill text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from subscriptions s
                 where s.user_id = p_user and s.skill = p_skill and s.status not in ('expired', 'unpaid')
                   and coalesce(s.ends_at, s.renews_at, now() + interval '32 days') > now());
$$;

-- ---------- RPCs ----------

-- Called by the app on a day the user interacted with the cat. Counts at most one day per user per (UTC) day.
-- p_local_days: days the app counted on this Mac before; used only the first time, capped at 30.
-- cat_touch: since account2.sql days come from online time (cat_heartbeat); this only reports.
create or replace function public.cat_touch(p_local_days int default 0) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); d int;
begin
  if uid is null then raise exception '还没登录'; end if;
  select days into d from cat_levels where user_id = uid;
  d := coalesce(d, 0);
  return json_build_object('days', d, 'level', ord_level(d));
end $$;

-- Level, 喵友 and membership of one user (default: me).
create or replace function public.cat_stats(p_user uuid default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); u uuid := coalesce(p_user, auth.uid()); d int;
begin
  if me is null then raise exception '还没登录'; end if;
  select days into d from cat_levels where user_id = u;
  d := coalesce(d, 0);
  return json_build_object(
    'user_id', u,
    'days', d,
    'level', ord_level(d),
    'followers', (select count(*) from cat_follows where followee_id = u),
    'following', (select count(*) from cat_follows where follower_id = u),
    'member', ord_is_member(u),
    'i_follow', exists (select 1 from cat_follows where follower_id = me and followee_id = u));
end $$;

-- 加喵友 / 取消喵友. Returns the user's new 喵友 count.
create or replace function public.follow_set(p_user uuid, p_on boolean default true) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception '还没登录'; end if;
  if p_user is null or p_user = me then raise exception '不能加自己为喵友'; end if;
  if p_on then
    insert into cat_follows (follower_id, followee_id) values (me, p_user) on conflict do nothing;
  else
    delete from cat_follows where follower_id = me and followee_id = p_user;
  end if;
  return json_build_object(
    'followers', (select count(*) from cat_follows where followee_id = p_user),
    'i_follow', exists (select 1 from cat_follows where follower_id = me and followee_id = p_user));
end $$;

drop function if exists public.signal_post(text, text, int, int, int, boolean, text[], text, text, text);
create or replace function public.signal_post(p_title text, p_body text, p_grade int default 1,
                                              p_min_level int default 0, p_min_followers int default 0,
                                              p_member_only boolean default false, p_need_skills text[] default '{}',
                                              p_name text default '', p_avatar text default null,
                                              p_source_app text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); sid uuid; bad text;
begin
  if uid is null then raise exception '还没登录'; end if;
  if char_length(coalesce(p_title, '')) < 2 then raise exception '标题至少 2 个字'; end if;
  if coalesce(p_grade, 1) not between 1 and 4 then raise exception '情报等级不对'; end if;
  if coalesce(p_min_level, 0) < 0 or coalesce(p_min_followers, 0) < 0 then raise exception '查看条件不对'; end if;
  if cardinality(coalesce(p_need_skills, '{}')) > 5 then raise exception '技能条件最多 5 个'; end if;
  select k into bad from unnest(coalesce(p_need_skills, '{}')) k where k not in ('x', 'agent') limit 1;
  if bad is not null then raise exception '不认识的技能：%', bad; end if;
  if (select count(*) from signals where author_id = uid and created_at > now() - interval '1 day') >= 20 then
    raise exception '一天最多发 20 条信号';
  end if;
  insert into signals (author_id, author_name, author_avatar, title, body, grade, min_level, min_followers,
                       member_only, need_skills, source_app)
  values (uid, left(coalesce(p_name, ''), 40), p_avatar, left(p_title, 80), left(coalesce(p_body, ''), 8000),
          coalesce(p_grade, 1), coalesce(p_min_level, 0), coalesce(p_min_followers, 0),
          coalesce(p_member_only, false), coalesce(p_need_skills, '{}'), left(coalesce(p_source_app, ''), 80))
  returning id into sid;
  return sid;
end $$;

create or replace function public.signal_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update signals set status = 'deleted' where id = p_id and author_id = auth.uid() and status = 'live';
  get diagnostics n = row_count;
  if n = 0 then raise exception '只能删除自己发的信号'; end if;
end $$;

-- 信号流 / 我发出的 / 单条信号. Body is null (and lacks lists what is missing) unless the reader qualifies.
-- lacks items: level:<n> | followers:<n> | member | skill:<id>
drop function if exists public.signal_feed(boolean, int, uuid);
create or replace function public.signal_feed(p_mine boolean default false, p_limit int default 60, p_id uuid default null)
returns table (id uuid, author_id uuid, author_name text, author_avatar text, author_level int, author_followers int,
               author_member boolean, title text, grade int, min_level int, min_followers int, member_only boolean,
               need_skills text[], source_app text, created_at timestamptz, lacks text[], unlocked boolean,
               body text, i_follow boolean)
language sql stable security definer set search_path = public as $$
  with me as (
    select auth.uid() as uid,
           ord_level(coalesce((select c.days from cat_levels c where c.user_id = auth.uid()), 0)) as lvl,
           (select count(*)::int from cat_follows f where f.followee_id = auth.uid()) as fans,
           ord_is_member(auth.uid()) as member
  ),
  cand as (
    select s.*, me.uid as viewer,
           array_remove(array[
               case when s.min_level > me.lvl then 'level:' || s.min_level end,
               case when s.min_followers > me.fans then 'followers:' || s.min_followers end,
               case when s.member_only and not me.member then 'member' end]::text[]
             || coalesce((select array_agg('skill:' || k) from unnest(s.need_skills) k
                          where not ord_has_skill(me.uid, k)), '{}'::text[]),
             null) as lacks0
    from signals s cross join me
    where me.uid is not null and s.status = 'live'
      and (not coalesce(p_mine, false) or s.author_id = me.uid)
      and (p_id is null or s.id = p_id)
    order by s.created_at desc
    limit least(greatest(coalesce(p_limit, 60), 1), 100)
  )
  select c.id, c.author_id, c.author_name, c.author_avatar,
         ord_level(coalesce((select l.days from cat_levels l where l.user_id = c.author_id), 0)),
         (select count(*)::int from cat_follows f where f.followee_id = c.author_id),
         ord_is_member(c.author_id),
         c.title, c.grade, c.min_level, c.min_followers, c.member_only, c.need_skills, c.source_app, c.created_at,
         case when c.author_id = c.viewer then '{}'::text[] else c.lacks0 end,
         (c.author_id = c.viewer or cardinality(c.lacks0) = 0),
         case when c.author_id = c.viewer or cardinality(c.lacks0) = 0 then c.body else null end,
         exists (select 1 from cat_follows f where f.follower_id = c.viewer and f.followee_id = c.author_id)
  from cand c
  order by c.created_at desc;
$$;

revoke all on function public.ord_is_member(uuid), public.ord_has_skill(uuid, text) from public, anon;
revoke all on function public.cat_touch(int), public.cat_stats(uuid), public.follow_set(uuid, boolean),
  public.signal_post(text, text, int, int, int, boolean, text[], text, text, text), public.signal_delete(uuid),
  public.signal_feed(boolean, int, uuid) from public, anon;
grant execute on function public.ord_level(int), public.ord_is_member(uuid), public.ord_has_skill(uuid, text),
  public.cat_touch(int), public.cat_stats(uuid), public.follow_set(uuid, boolean),
  public.signal_post(text, text, int, int, int, boolean, text[], text, text, text), public.signal_delete(uuid),
  public.signal_feed(boolean, int, uuid) to authenticated;

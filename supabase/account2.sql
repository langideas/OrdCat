-- OrdCat · 账号 2：用户名检查、喵友列表、在线时长等级、好友邀请、私信、客服.
-- Run in Supabase → SQL Editor after schema.sql, square.sql and signal.sql. Safe to run again.

-- ---------- 用户名是否可用（登录前后都能查） ----------
create or replace function public.username_available(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_name ~ '^[A-Za-z0-9_]{3,20}$'
     and lower(p_name) not in ('ordcat', 'admin', 'support', 'kefu', 'official', 'root', 'system')
     and not exists (select 1 from profiles p
                     where lower(p.username) = lower(p_name) and p.id is distinct from auth.uid());
$$;

-- ---------- 喵友列表（关注 / 被关注） ----------
create or replace function public.follow_list(p_user uuid default null, p_kind text default 'followers', p_limit int default 200)
returns table (user_id uuid, display_name text, username text, avatar_url text, level int, i_follow boolean,
               follows_me boolean, since timestamptz)
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as uid),
  rows as (
    select case when p_kind = 'following' then f.followee_id else f.follower_id end as uid, f.created_at
    from cat_follows f, me
    where me.uid is not null
      and ((p_kind = 'following' and f.follower_id = coalesce(p_user, me.uid))
        or (p_kind <> 'following' and f.followee_id = coalesce(p_user, me.uid)))
    order by f.created_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  )
  select r.uid, coalesce(p.display_name, ''), p.username, p.avatar_url,
         ord_level(coalesce((select l.days from cat_levels l where l.user_id = r.uid), 0)),
         exists (select 1 from cat_follows x, me where x.follower_id = me.uid and x.followee_id = r.uid),
         exists (select 1 from cat_follows x, me where x.follower_id = r.uid and x.followee_id = me.uid),
         r.created_at
  from rows r left join profiles p on p.id = r.uid;
$$;

-- ---------- 等级：在线满 24 小时 = 1 天 ----------
-- The app sends a heartbeat every few minutes while it runs. The server only counts real time between
-- heartbeats (at most 10 minutes per beat), so the count can't be pushed faster than the clock.
alter table public.cat_levels add column if not exists online_seconds bigint not null default 0;
alter table public.cat_levels add column if not exists last_beat timestamptz;
alter table public.cat_levels add column if not exists migrated boolean not null default false;
-- Days earned under the old rule are kept as full days.
update public.cat_levels set online_seconds = greatest(online_seconds, days::bigint * 86400), migrated = true
where not migrated;

create or replace function public.cat_heartbeat(p_seconds int default 300, p_local_seconds bigint default 0) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r cat_levels%rowtype; add int; d int;
begin
  if uid is null then raise exception '还没登录'; end if;
  select * into r from cat_levels where user_id = uid for update;
  if not found then
    -- First beat of this account: carry what this Mac counted before signing in, up to 30 days.
    insert into cat_levels (user_id, days, online_seconds, last_beat, migrated, last_day)
    values (uid, 0, least(greatest(coalesce(p_local_seconds, 0), 0), 30 * 86400), now(), true, current_date)
    returning * into r;
  else
    add := least(greatest(coalesce(p_seconds, 0), 0), 600,
                 coalesce(extract(epoch from (now() - r.last_beat))::int + 5, 600));
    update cat_levels set online_seconds = online_seconds + add, last_beat = now(), updated_at = now()
    where user_id = uid returning * into r;
  end if;
  d := (r.online_seconds / 86400)::int;
  update cat_levels set days = d where user_id = uid and days <> d;
  return json_build_object('days', d, 'level', ord_level(d), 'online_seconds', r.online_seconds,
                           'seconds_to_next_day', 86400 - (r.online_seconds % 86400));
end $$;

-- Old clients call cat_touch once a day: from now on it only reports, it no longer adds days.
create or replace function public.cat_touch(p_local_days int default 0) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); d int;
begin
  if uid is null then raise exception '还没登录'; end if;
  select days into d from cat_levels where user_id = uid;
  d := coalesce(d, 0);
  return json_build_object('days', d, 'level', ord_level(d));
end $$;

-- ---------- 好友邀请 ----------
create table if not exists public.invite_codes (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.invite_uses (
  invitee_id uuid primary key references auth.users(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.invite_codes enable row level security;
alter table public.invite_uses enable row level security;

create or replace function public.invite_my_code() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c text; n int;
begin
  if uid is null then raise exception '还没登录'; end if;
  select code into c from invite_codes where owner_id = uid;
  while c is null loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text || uid::text), 1, 6));
    if char_length(c) = 6 and not exists (select 1 from invite_codes where code = c) then
      insert into invite_codes (owner_id, code) values (uid, c);
    else c := null; end if;
  end loop;
  select count(*) into n from invite_uses where owner_id = uid;
  return json_build_object('code', c, 'invited', n, 'reward', 50);
end $$;

-- Each new account can redeem one code within 7 days of signing up. Both sides get 50 小鱼干.
create or replace function public.invite_redeem(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); owner uuid; joined timestamptz;
begin
  if uid is null then raise exception '还没登录'; end if;
  select owner_id into owner from invite_codes where code = upper(trim(p_code));
  if owner is null then raise exception '邀请码不对'; end if;
  if owner = uid then raise exception '不能填自己的邀请码'; end if;
  if exists (select 1 from invite_uses where invitee_id = uid) then raise exception '你已经填过邀请码了'; end if;
  select created_at into joined from auth.users where id = uid;
  if joined < now() - interval '7 days' then raise exception '邀请码只能在注册 7 天内填写'; end if;
  insert into invite_uses (invitee_id, owner_id) values (uid, owner);
  perform fish_ensure(uid); perform fish_ensure(owner);
  update fish_wallets set balance = balance + 50 where user_id in (uid, owner);
  insert into fish_ledger (user_id, delta, reason) values (uid, 50, 'invite'), (owner, 50, 'invite');
  insert into cat_follows (follower_id, followee_id) values (uid, owner), (owner, uid) on conflict do nothing;
  return json_build_object('ok', true, 'reward', 50);
end $$;

-- ---------- 私信 ----------
create table if not exists public.direct_messages (
  id bigserial primary key,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender_id <> recipient_id)
);
create index if not exists dm_pair on public.direct_messages (least(sender_id, recipient_id), greatest(sender_id, recipient_id), id desc);
create index if not exists dm_inbox on public.direct_messages (recipient_id, read_at);
alter table public.direct_messages enable row level security;
drop policy if exists "dm read own" on public.direct_messages;
create policy "dm read own" on public.direct_messages for select using (auth.uid() in (sender_id, recipient_id));

-- 客服账号：在 Supabase 的 Authentication 里建好 support 账号后，把它的 id 填到这张表。
create table if not exists public.app_settings (key text primary key, value text not null);
alter table public.app_settings enable row level security;

create or replace function public.support_id() returns uuid
language sql stable security definer set search_path = public as $$
  select nullif(value, '')::uuid from app_settings where key = 'support_user_id';
$$;

-- You can message a 喵友 when you follow each other, anyone who follows you, and always the support account.
create or replace function public.dm_send(p_to uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); mid bigint; sup uuid := support_id();
begin
  if uid is null then raise exception '还没登录'; end if;
  if p_to is null or p_to = uid then raise exception '收件人不对'; end if;
  if char_length(trim(coalesce(p_body, ''))) = 0 then raise exception '消息是空的'; end if;
  if not (coalesce(p_to = sup, false) or coalesce(uid = sup, false)
          or exists (select 1 from cat_follows where follower_id = p_to and followee_id = uid)
          or exists (select 1 from direct_messages where sender_id = p_to and recipient_id = uid)) then
    raise exception '对方关注你之后才能发私信';
  end if;
  if (select count(*) from direct_messages where sender_id = uid and created_at > now() - interval '1 hour') >= 120 then
    raise exception '发得太快啦，休息一下';
  end if;
  insert into direct_messages (sender_id, recipient_id, body) values (uid, p_to, left(trim(p_body), 4000)) returning id into mid;
  return mid;
end $$;

create or replace function public.dm_threads() returns table (peer_id uuid, display_name text, username text, avatar_url text,
  last_body text, last_at timestamptz, last_from_me boolean, unread int, is_support boolean)
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as uid),
  m as (
    select d.*, case when d.sender_id = me.uid then d.recipient_id else d.sender_id end as peer
    from direct_messages d, me where me.uid in (d.sender_id, d.recipient_id)
  ),
  last as (select distinct on (peer) * from m order by peer, id desc)
  select l.peer, coalesce(p.display_name, ''), p.username, p.avatar_url, left(l.body, 120), l.created_at,
         l.sender_id = (select uid from me),
         (select count(*)::int from m x where x.peer = l.peer and x.recipient_id = (select uid from me) and x.read_at is null),
         l.peer = support_id()
  from last l left join profiles p on p.id = l.peer
  order by l.created_at desc
  limit 200;
$$;

create or replace function public.dm_messages(p_with uuid, p_before bigint default null, p_limit int default 60)
returns table (id bigint, from_me boolean, body text, created_at timestamptz, read_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception '还没登录'; end if;
  update direct_messages dm set read_at = now() where dm.recipient_id = uid and dm.sender_id = p_with and dm.read_at is null;
  return query
    select d.id, d.sender_id = uid, d.body, d.created_at, d.read_at from direct_messages d
    where ((d.sender_id = uid and d.recipient_id = p_with) or (d.sender_id = p_with and d.recipient_id = uid))
      and (p_before is null or d.id < p_before)
    order by d.id desc
    limit least(greatest(coalesce(p_limit, 60), 1), 200);
end $$;

create or replace function public.dm_unread() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from direct_messages where recipient_id = auth.uid() and read_at is null;
$$;

-- Basic public card for a user (to open a chat from a 喵友 list or a signal).
create or replace function public.user_card(p_user uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('user_id', p.id, 'display_name', p.display_name, 'username', p.username,
                           'avatar_url', p.avatar_url, 'is_support', p.id = support_id())
  from profiles p where p.id = p_user and auth.uid() is not null;
$$;

-- ---------- grants ----------
revoke all on function public.follow_list(uuid, text, int), public.cat_heartbeat(int, bigint), public.invite_my_code(),
  public.invite_redeem(text), public.dm_send(uuid, text), public.dm_threads(), public.dm_messages(uuid, bigint, int),
  public.dm_unread(), public.user_card(uuid), public.support_id() from public, anon;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.follow_list(uuid, text, int), public.cat_heartbeat(int, bigint), public.cat_touch(int),
  public.invite_my_code(), public.invite_redeem(text), public.dm_send(uuid, text), public.dm_threads(),
  public.dm_messages(uuid, bigint, int), public.dm_unread(), public.user_card(uuid), public.support_id() to authenticated;

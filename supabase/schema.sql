-- OrdCat · Supabase schema. Run in Supabase → SQL Editor first. Safe to run again.

-- 用户资料
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  display_name text not null default '',
  avatar_url text,
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "own profile read" on public.profiles;
create policy "own profile read"   on public.profiles for select using (auth.uid() = id);
drop policy if exists "own profile insert" on public.profiles;
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = id);
drop policy if exists "own profile update" on public.profiles;
create policy "own profile update" on public.profiles for update using (auth.uid() = id);

-- 订阅（由 lemon-webhook 写入，用户只能读自己的）
create table if not exists public.subscriptions (
  id text primary key,                 -- Lemon Squeezy subscription id
  user_id uuid references auth.users(id) on delete cascade,
  skill text not null,                 -- x | agent
  status text not null,                -- on_trial | active | paused | past_due | unpaid | cancelled | expired
  renews_at timestamptz,
  ends_at timestamptz,
  portal_url text,
  customer_email text,
  updated_at timestamptz not null default now()
);
alter table public.subscriptions enable row level security;
drop policy if exists "own subs read" on public.subscriptions;
create policy "own subs read" on public.subscriptions for select using (auth.uid() = user_id);

-- 头像存储（公开读，只能写自己的 <uid>.png）
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict do nothing;
drop policy if exists "avatar read" on storage.objects;
create policy "avatar read"   on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists "avatar write" on storage.objects;
create policy "avatar write"  on storage.objects for insert with check (bucket_id = 'avatars' and name = auth.uid()::text || '.png');
drop policy if exists "avatar update" on storage.objects;
create policy "avatar update" on storage.objects for update using (bucket_id = 'avatars' and name = auth.uid()::text || '.png');
drop policy if exists "avatar delete" on storage.objects;
create policy "avatar delete" on storage.objects for delete using (bucket_id = 'avatars' and name = auth.uid()::text || '.png');

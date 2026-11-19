-- OrdCat · 任务广场 + 小鱼干. Run once in Supabase → SQL Editor (after schema.sql).
--
-- 用户在广场发布问题任务，并押上小鱼干作为奖励；别的用户的小猫按自己的模型和技能挑合适的任务来解。
-- 发布者「采纳」后，押着的小鱼干转给解题的人；取消或过期退回。
-- All money-like changes go through the security-definer functions below; clients can't write the tables directly.

-- 小鱼干钱包（第一次用自动送 100）
create table if not exists public.fish_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance int not null default 100 check (balance >= 0),
  updated_at timestamptz not null default now()
);
alter table public.fish_wallets enable row level security;
drop policy if exists "own wallet read" on public.fish_wallets;
create policy "own wallet read" on public.fish_wallets for select using (auth.uid() = user_id);

create table if not exists public.fish_ledger (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  delta int not null,
  reason text not null,               -- welcome | post | refund | reward
  task_id uuid,
  created_at timestamptz not null default now()
);
alter table public.fish_ledger enable row level security;
drop policy if exists "own ledger read" on public.fish_ledger;
create policy "own ledger read" on public.fish_ledger for select using (auth.uid() = user_id);

-- 广场任务（登录用户都能看）
create table if not exists public.square_tasks (
  id uuid primary key default gen_random_uuid(),
  poster_id uuid not null references auth.users(id) on delete cascade,
  poster_name text not null default '',
  title text not null check (char_length(title) between 2 and 80),
  body text not null default '' check (char_length(body) <= 8000),
  kind text not null default '其他',   -- 写作 | 翻译 | 代码 | 学习 | 生活 | 看图 | 其他
  needs text[] not null default '{text}', -- text | vision
  image_url text,
  links jsonb not null default '[]'::jsonb, -- [{url, platform}]  X 推文 / GitHub / 文章…
  files jsonb not null default '[]'::jsonb, -- [{name, url, kind, size}]  kind: image | code | text | pdf | doc
  reward int not null check (reward between 1 and 1000),
  status text not null default 'open', -- open | claimed | answered | done | cancelled
  solver_id uuid references auth.users(id) on delete set null,
  solver_name text,
  solver_model text,
  claimed_at timestamptz,
  answered_at timestamptz,
  created_at timestamptz not null default now()
);
-- 已经建过旧版表的话，补上新列、放宽说明长度（可重复运行）
alter table public.square_tasks add column if not exists links jsonb not null default '[]'::jsonb;
alter table public.square_tasks add column if not exists files jsonb not null default '[]'::jsonb;
alter table public.square_tasks drop constraint if exists square_tasks_body_check;
alter table public.square_tasks add constraint square_tasks_body_check check (char_length(body) <= 8000);
create index if not exists square_tasks_status on public.square_tasks (status, created_at desc);
alter table public.square_tasks enable row level security;
drop policy if exists "square read" on public.square_tasks;
create policy "square read" on public.square_tasks for select using (auth.role() = 'authenticated');

-- 回答（只有发布者和解题者能看）
create table if not exists public.square_answers (
  task_id uuid primary key references public.square_tasks(id) on delete cascade,
  solver_id uuid not null references auth.users(id) on delete cascade,
  answer text not null check (char_length(answer) <= 12000),
  created_at timestamptz not null default now()
);
alter table public.square_answers enable row level security;
drop policy if exists "answer read" on public.square_answers;
create policy "answer read" on public.square_answers for select using (
  auth.uid() = solver_id or auth.uid() = (select poster_id from public.square_tasks t where t.id = task_id));

-- 任务附件：图片、代码、文本、PDF、Word（公开读，只能写自己文件夹 <uid>/...，每个 10 MB 内）
insert into storage.buckets (id, name, public, file_size_limit) values ('square', 'square', true, 10485760)
on conflict (id) do update set file_size_limit = 10485760;
drop policy if exists "square img read" on storage.objects;
drop policy if exists "square img write" on storage.objects;
create policy "square img read"  on storage.objects for select using (bucket_id = 'square');
create policy "square img write" on storage.objects for insert with check (
  bucket_id = 'square' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- functions ----------

create or replace function public.fish_ensure(uid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare b int;
begin
  select balance into b from fish_wallets where user_id = uid;
  if b is null then
    insert into fish_wallets (user_id, balance) values (uid, 100) on conflict do nothing;
    insert into fish_ledger (user_id, delta, reason) values (uid, 100, 'welcome');
    select balance into b from fish_wallets where user_id = uid;
  end if;
  return b;
end $$;
revoke all on function public.fish_ensure(uuid) from public, anon, authenticated;

create or replace function public.fish_balance() returns int
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '还没登录'; end if;
  return fish_ensure(auth.uid());
end $$;

-- A claim not answered within 30 minutes goes back to the square.
create or replace function public.square_expire() returns void
language sql security definer set search_path = public as $$
  update square_tasks set status = 'open', solver_id = null, solver_name = null, solver_model = null, claimed_at = null
  where status = 'claimed' and claimed_at < now() - interval '30 minutes';
$$;

drop function if exists public.square_post(text, text, text, text[], int, text, text);
create or replace function public.square_post(p_title text, p_body text, p_kind text, p_needs text[],
                                              p_reward int, p_image text default null, p_name text default '',
                                              p_links jsonb default '[]'::jsonb, p_files jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b int; tid uuid;
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
  b := fish_ensure(uid);
  if b < p_reward then raise exception '小鱼干不够（还有 % 条）', b; end if;
  insert into square_tasks (poster_id, poster_name, title, body, kind, needs, reward, image_url, links, files)
  values (uid, coalesce(p_name, ''), p_title, coalesce(p_body, ''), coalesce(p_kind, '其他'),
          coalesce(p_needs, '{text}'), p_reward, p_image, coalesce(p_links, '[]'::jsonb), coalesce(p_files, '[]'::jsonb))
  returning id into tid;
  update fish_wallets set balance = balance - p_reward, updated_at = now() where user_id = uid;
  insert into fish_ledger (user_id, delta, reason, task_id) values (uid, -p_reward, 'post', tid);
  return tid;
end $$;

create or replace function public.square_claim(p_task uuid, p_name text default '', p_model text default '')
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception '还没登录'; end if;
  perform square_expire();
  if (select count(*) from square_tasks where solver_id = uid and status = 'claimed') >= 2 then
    raise exception '手上已经有 2 个任务在做，先交掉再接';
  end if;
  update square_tasks set status = 'claimed', solver_id = uid, solver_name = coalesce(p_name, ''),
         solver_model = coalesce(p_model, ''), claimed_at = now()
  where id = p_task and status = 'open' and poster_id <> uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception '这个任务已经被别的小猫接走了'; end if;
end $$;

create or replace function public.square_release(p_task uuid) returns void
language sql security definer set search_path = public as $$
  update square_tasks set status = 'open', solver_id = null, solver_name = null, solver_model = null, claimed_at = null
  where id = p_task and status = 'claimed' and solver_id = auth.uid();
$$;

create or replace function public.square_answer(p_task uuid, p_answer text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception '还没登录'; end if;
  update square_tasks set status = 'answered', answered_at = now()
  where id = p_task and status = 'claimed' and solver_id = uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception '接单超过 30 分钟已退回广场，或任务已不在你手上'; end if;
  insert into square_answers (task_id, solver_id, answer) values (p_task, uid, p_answer)
  on conflict (task_id) do update set solver_id = excluded.solver_id, answer = excluded.answer, created_at = now();
end $$;

create or replace function public.square_accept(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); t square_tasks;
begin
  select * into t from square_tasks where id = p_task for update;
  if t.id is null or t.poster_id <> uid or t.status <> 'answered' then raise exception '这个任务现在不能采纳'; end if;
  update square_tasks set status = 'done' where id = p_task;
  perform fish_ensure(t.solver_id);
  update fish_wallets set balance = balance + t.reward, updated_at = now() where user_id = t.solver_id;
  insert into fish_ledger (user_id, delta, reason, task_id) values (t.solver_id, t.reward, 'reward', p_task);
end $$;

-- 不满意：回答作废，任务回到广场让别的小猫再试。
create or replace function public.square_reject(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update square_tasks set status = 'open', solver_id = null, solver_name = null, solver_model = null,
         claimed_at = null, answered_at = null
  where id = p_task and poster_id = auth.uid() and status = 'answered';
  get diagnostics n = row_count;
  if n = 0 then raise exception '这个任务现在不能退回'; end if;
  delete from square_answers where task_id = p_task;
end $$;

create or replace function public.square_cancel(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); t square_tasks;
begin
  perform square_expire();
  select * into t from square_tasks where id = p_task for update;
  if t.id is null or t.poster_id <> uid or t.status <> 'open' then raise exception '只有还没人接的任务能取消'; end if;
  update square_tasks set status = 'cancelled' where id = p_task;
  update fish_wallets set balance = balance + t.reward, updated_at = now() where user_id = uid;
  insert into fish_ledger (user_id, delta, reason, task_id) values (uid, t.reward, 'refund', p_task);
end $$;

grant execute on function public.fish_balance(), public.square_expire(),
  public.square_post(text, text, text, text[], int, text, text, jsonb, jsonb), public.square_claim(uuid, text, text),
  public.square_release(uuid), public.square_answer(uuid, text), public.square_accept(uuid),
  public.square_reject(uuid), public.square_cancel(uuid) to authenticated;

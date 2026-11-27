-- OrdCat · 喵副本 Cat Raids (v0.2.63). Run in Supabase → SQL Editor AFTER schema.sql, square.sql, signal.sql,
-- account2.sql, membership.sql and fish.sql. Safe to run again (if not exists / create or replace).
--
-- 规则（Lang 2026-11-25 同意，docs/plan-original-next-2026-11-25.md 第 3 节 + 21:20）：
--   原来的单人悬赏（square_tasks）保留为「单人副本」，这个文件不动它。
--   组队副本两种：
--   A 结果副本 mode = 'result'：队长发布时定模板、任务、加入条件、人数 2–5（含队长）、截止时间、奖池、
--     分钱比例（队长 0–50% + 每一份的百分比，合计 100，报名前可见，发布后不能改）和验收清单（发布后不能改）。
--     满员开打：队长的小猫拆任务（raid_brief），队友的小猫用自己的模型做完提交（raid_submit），队长验收（raid_decide）：
--     退回必须勾出没达到的清单项 + 写理由；可以返工一次；队长 72 小时不处理 = 自动通过并发鱼干。
--     被退回后队友可以申诉一次（raid_appeal，10 条小鱼干，不退）。申诉交给服务器上的 AI 裁判（Edge Function raid-judge，
--     只按发布时的清单判，引用原文作证据）；没配置裁判时申诉保持 pending_judge。App 永远不直接调裁判。
--   B 借猫副本 mode = 'lend'：队长定每 1k token 的价格（小鱼干）和预算上限（发布时锁住）。队友把小猫借给队长：
--     只在沙箱里用队友自己的模型做纯文字活（raid_jobs），绝不碰喵手 / 文件 / 麦克风 / 屏幕 / 喵推 / 队友 Mac 上的任何操作。
--     队友的 App 上报每个活用了多少 token，服务器按单个活上限、按字数估算上限和每小时上限封顶，绝不超过预算。
--     结束时按用量从锁住的奖池付给队友，剩下的退回队长；双方都能看用量记录，结束后互相评分。没有验收这一步。
--   共同：奖池发布时用 fish_take 锁住（先奖励鱼干再充值鱼干）；发出去的鱼干保持奖池里 充值 : 奖励 的比例
--     （raid_pay，按累计数取整，退款时正好补齐）。同一台设备（fish_devices 同款哈希）或同一个 IP 不能进同一个副本。
--     队长信用分公开：通过率、输掉的申诉、自动通过次数。平台完成奖励只发奖励鱼干（app_settings.raid_bonus，默认 5，每天最多 3 次）。
-- 所有钱的改动都在下面的 security definer 函数里，先锁副本那一行再改，每笔写 fish_ledger（task_id = 副本 id）。

-- ---------- 1. tables ----------

create table if not exists public.raids (
  id uuid primary key default gen_random_uuid(),
  mode text not null check (mode in ('result', 'lend')),
  captain_id uuid not null references auth.users(id) on delete cascade,
  captain_name text not null default '',
  template text not null,                       -- 结果副本：翻译 | 长文协作 | 调研总结 | 代码审查；借猫副本：借猫
  title text not null check (char_length(title) between 2 and 80),
  body text not null default '' check (char_length(body) <= 8000),
  cond_level int not null default 0 check (cond_level between 0 and 999),
  cond_skills text[] not null default '{}',     -- owned skill subscriptions: x | agent | miao
  cond_member boolean not null default false,
  cond_vision boolean not null default false,
  team_size int not null check (team_size between 2 and 5),   -- including the captain
  deadline timestamptz not null,
  pool int not null check (pool > 0),
  pool_paid int not null default 0 check (pool_paid >= 0),    -- how much of the pool came from paid fish
  spent int not null default 0 check (spent >= 0),            -- fish already paid out of the pool (incl. refund)
  spent_paid int not null default 0 check (spent_paid >= 0),
  captain_pct int not null default 0 check (captain_pct between 0 and 50),
  step_pcts int[] not null default '{}',                      -- one per member slot; captain_pct + sum = 100
  checklist jsonb not null default '[]'::jsonb,               -- [{id, text}] fixed at posting
  price_1k int check (price_1k is null or price_1k between 1 and 1000),   -- 借猫：fish per 1k tokens
  reserved int not null default 0 check (reserved >= 0),     -- 借猫：held for queued / running jobs
  used int not null default 0 check (used >= 0),             -- 借猫：billed so far (paid at settlement)
  status text not null default 'recruiting',                 -- recruiting | running | closing | done | cancelled | expired
  close_reason text,
  result text check (result is null or char_length(result) <= 60000),
  captain_device text,
  captain_ip text,
  bonus_done boolean not null default false,
  started_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  check (pool_paid <= pool),
  check (spent <= pool),
  check (spent_paid <= pool_paid)
);
create index if not exists raids_status on public.raids (status, created_at desc);
create index if not exists raids_captain on public.raids (captain_id, created_at desc);

create table if not exists public.raid_members (
  raid_id uuid not null references public.raids(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null default '',
  model text not null default '',
  caps text[] not null default '{text}',
  lend_skills text[] not null default '{}',
  slot int not null,
  status text not null default 'active',     -- active | left | kicked | dropped
  device_hash text,
  ip_hash text,
  usage_tokens int not null default 0,
  usage_fish int not null default 0,         -- 借猫：billed, paid at settlement
  earned int not null default 0,             -- fish actually paid to this member
  consent_at timestamptz,
  joined_at timestamptz not null default now(),
  primary key (raid_id, user_id)
);
create index if not exists raid_members_user on public.raid_members (user_id, joined_at desc);

create table if not exists public.raid_steps (
  id uuid primary key default gen_random_uuid(),
  raid_id uuid not null references public.raids(id) on delete cascade,
  slot int not null,
  pct int not null,
  reward int not null,
  assignee uuid references auth.users(id) on delete set null,
  title text not null default '',
  instructions text not null default '' check (char_length(instructions) <= 8000),
  status text not null default 'waiting_brief',
  -- waiting_brief | working | submitted | rejected | failed | appealed | accepted | auto_passed | judge_passed | cancelled
  round int not null default 0,              -- 0 = first hand-in, 1 = the one rework
  submission text check (submission is null or char_length(submission) <= 30000),
  submitted_at timestamptz,
  unmet text[] not null default '{}',
  reject_reason text,
  decided_at timestamptz,
  appeal_used boolean not null default false,
  paid boolean not null default false,
  unique (raid_id, slot)
);

create table if not exists public.raid_appeals (
  id uuid primary key default gen_random_uuid(),
  step_id uuid not null references public.raid_steps(id) on delete cascade,
  raid_id uuid not null references public.raids(id) on delete cascade,
  member_id uuid not null references auth.users(id) on delete cascade,
  captain_id uuid not null references auth.users(id) on delete cascade,
  fee int not null default 10,
  reason text not null default '',
  checklist jsonb not null,
  unmet text[] not null default '{}',
  captain_reason text,
  submission text not null default '',
  step_round int not null default 0,
  status text not null default 'pending_judge',   -- pending_judge | judging | won | lost
  verdict jsonb,
  judge_model text,
  claimed_at timestamptz,
  judged_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists raid_appeals_status on public.raid_appeals (status, created_at);

create table if not exists public.raid_jobs (
  id uuid primary key default gen_random_uuid(),
  raid_id uuid not null references public.raids(id) on delete cascade,
  captain_id uuid not null references auth.users(id) on delete cascade,
  assignee uuid references auth.users(id) on delete set null,
  skill text not null,
  prompt text not null check (char_length(prompt) between 1 and 8000),
  max_tokens int not null check (max_tokens between 200 and 16000),
  reserve int not null default 0,
  status text not null default 'queued',      -- queued | running | done | failed | cancelled
  output text check (output is null or char_length(output) <= 20000),
  error text,
  reported_tokens int,
  billed_tokens int not null default 0,
  cost int not null default 0,
  capped text,                                -- why billed < reported, if it was
  model text,
  claimed_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists raid_jobs_raid on public.raid_jobs (raid_id, created_at desc);
create index if not exists raid_jobs_queue on public.raid_jobs (status, created_at) where status in ('queued', 'running');

create table if not exists public.raid_ratings (
  raid_id uuid not null references public.raids(id) on delete cascade,
  rater uuid not null references auth.users(id) on delete cascade,
  target uuid not null references auth.users(id) on delete cascade,
  as_captain boolean not null,                -- target was the captain
  stars int not null check (stars between 1 and 5),
  note text not null default '' check (char_length(note) <= 300),
  created_at timestamptz not null default now(),
  primary key (raid_id, rater, target)
);

-- The checklist and the split can never change once posted (belt and braces: no client can update tables anyway).
create or replace function public.raid_lock_tg() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.checklist is distinct from old.checklist or new.captain_pct is distinct from old.captain_pct
     or new.step_pcts is distinct from old.step_pcts or new.pool is distinct from old.pool
     or new.pool_paid is distinct from old.pool_paid or new.price_1k is distinct from old.price_1k
     or new.mode is distinct from old.mode or new.team_size is distinct from old.team_size then
    raise exception '副本发布后清单、分钱比例、奖池和价格都不能改';
  end if;
  return new;
end $$;
drop trigger if exists raid_lock on public.raids;
create trigger raid_lock before update on public.raids for each row execute function public.raid_lock_tg();

-- ---------- 2. RLS (reads only; every write goes through the functions below) ----------

create or replace function public.raid_is_captain(p_raid uuid, p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from raids where id = p_raid and captain_id = p_uid);
$$;
create or replace function public.raid_is_member(p_raid uuid, p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from raid_members where raid_id = p_raid and user_id = p_uid);
$$;

alter table public.raids enable row level security;
alter table public.raid_members enable row level security;
alter table public.raid_steps enable row level security;
alter table public.raid_appeals enable row level security;
alter table public.raid_jobs enable row level security;
alter table public.raid_ratings enable row level security;
drop policy if exists "raid read" on public.raids;
create policy "raid read" on public.raids for select
  using (captain_id = auth.uid() or public.raid_is_member(id, auth.uid()));
drop policy if exists "raid member read" on public.raid_members;
create policy "raid member read" on public.raid_members for select
  using (user_id = auth.uid() or public.raid_is_captain(raid_id, auth.uid()));
drop policy if exists "raid step read" on public.raid_steps;
create policy "raid step read" on public.raid_steps for select
  using (assignee = auth.uid() or public.raid_is_captain(raid_id, auth.uid()));
drop policy if exists "raid appeal read" on public.raid_appeals;
create policy "raid appeal read" on public.raid_appeals for select
  using (member_id = auth.uid() or captain_id = auth.uid());
drop policy if exists "raid job read" on public.raid_jobs;
create policy "raid job read" on public.raid_jobs for select
  using (captain_id = auth.uid() or assignee = auth.uid());
drop policy if exists "raid rating read" on public.raid_ratings;
create policy "raid rating read" on public.raid_ratings for select
  using (rater = auth.uid() or target = auth.uid());

-- Realtime for lent cats (the app also polls, so this is optional).
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'raid_jobs') then
    execute 'alter publication supabase_realtime add table public.raid_jobs';
  end if;
end $$;

-- ---------- 3. internal helpers ----------

create or replace function public.raid_ip_hash() returns text
language plpgsql stable security definer set search_path = public as $$
declare ip text;
begin
  begin
    ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1));
  exception when others then ip := '';
  end;
  if coalesce(ip, '') = '' then return null; end if;
  return encode(sha256(convert_to(ip, 'UTF8')), 'hex');
end $$;

-- Pay p_amount out of the raid's pool, keeping the pool's paid : reward ratio (cumulative rounding, so a full
-- payout lands exactly on pool_paid). Caller holds the raid row lock.
create or replace function public.raid_pay(p_raid uuid, p_uid uuid, p_amount int, p_reason text, p_ref text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r raids; target int; pp int;
begin
  if p_amount is null or p_amount <= 0 then return; end if;
  select * into r from raids where id = p_raid for update;
  if r.spent + p_amount > r.pool then raise exception '副本奖池不够了'; end if;
  target := floor((r.spent + p_amount)::numeric * r.pool_paid / r.pool)::int;
  pp := least(greatest(target - r.spent_paid, 0), p_amount, r.pool_paid - r.spent_paid);
  update raids set spent = spent + p_amount, spent_paid = spent_paid + pp where id = p_raid;
  perform fish_credit(p_uid, 'paid', pp, p_reason, p_raid, p_ref);
  perform fish_credit(p_uid, 'reward', p_amount - pp, p_reason, p_raid, p_ref);
end $$;

-- Platform completion reward: reward fish only, app_settings.raid_bonus (default 5, 0 = off), max 3 a day per user.
create or replace function public.raid_bonus(p_uid uuid, p_raid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n int; today int;
begin
  begin
    n := coalesce((select value::int from app_settings where key = 'raid_bonus'), 5);
  exception when others then n := 5;
  end;
  if n <= 0 then return; end if;
  select count(*) into today from fish_ledger
   where user_id = p_uid and reason = 'raid_bonus' and created_at > now() - interval '24 hours';
  if today >= 3 then return; end if;
  perform fish_credit(p_uid, 'reward', n, 'raid_bonus', p_raid);
end $$;

-- A step that will not change any more (so the raid can settle).
create or replace function public.raid_step_final(s raid_steps) returns boolean
language sql stable set search_path = public as $$
  select s.status in ('accepted', 'auto_passed', 'judge_passed', 'cancelled')
      or (s.status = 'failed' and (s.appeal_used or s.decided_at < now() - interval '72 hours'));
$$;

-- Close a raid when nothing is left in flight: pay 借猫 usage, completion rewards, refund the rest to the captain.
create or replace function public.raid_try_settle(p_raid uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare r raids; m record; s raid_steps; any_paid boolean := false;
begin
  select * into r from raids where id = p_raid for update;
  if r.id is null or r.status <> 'closing' then return false; end if;
  if r.mode = 'result' then
    for s in select * from raid_steps where raid_id = p_raid loop
      if not raid_step_final(s) then return false; end if;
    end loop;
    if exists (select 1 from raid_appeals where raid_id = p_raid and status in ('pending_judge', 'judging')) then return false; end if;
    any_paid := exists (select 1 from raid_steps where raid_id = p_raid and paid);
  else
    if exists (select 1 from raid_jobs where raid_id = p_raid and status in ('queued', 'running')) then return false; end if;
    for m in select * from raid_members where raid_id = p_raid and usage_fish > 0 order by slot loop
      perform raid_pay(p_raid, m.user_id, m.usage_fish, 'raid_usage', 'lend');
      update raid_members set earned = earned + m.usage_fish where raid_id = p_raid and user_id = m.user_id;
      any_paid := true;
    end loop;
    update raids set reserved = 0 where id = p_raid;
  end if;
  select * into r from raids where id = p_raid;
  if r.pool - r.spent > 0 then perform raid_pay(p_raid, r.captain_id, r.pool - r.spent, 'raid_refund'); end if;
  if any_paid and not r.bonus_done then
    perform raid_bonus(r.captain_id, p_raid);
    for m in select distinct x.uid from (
               select assignee as uid from raid_steps where raid_id = p_raid and paid and assignee is not null
               union select user_id from raid_members where raid_id = p_raid and usage_fish > 0) x loop
      perform raid_bonus(m.uid, p_raid);
    end loop;
  end if;
  update raids set status = case when any_paid or close_reason = 'finished' then 'done'
                                 when close_reason = 'disbanded' then 'cancelled' else 'expired' end,
                   bonus_done = any_paid or bonus_done, closed_at = now()
  where id = p_raid;
  return true;
end $$;

-- Move a raid into 'closing': unstarted work is cancelled, queued jobs released.
create or replace function public.raid_close(p_raid uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update raids set status = 'closing', close_reason = coalesce(close_reason, p_reason)
  where id = p_raid and status in ('recruiting', 'running');
  update raid_steps set status = 'cancelled' where raid_id = p_raid and status in ('waiting_brief', 'working');
  update raid_steps set status = 'failed' where raid_id = p_raid and status = 'rejected';
  update raid_jobs set status = 'cancelled', finished_at = now() where raid_id = p_raid and status = 'queued';
  update raids set reserved = coalesce((select sum(reserve) from raid_jobs where raid_id = p_raid and status = 'running'), 0)
  where id = p_raid;
  perform raid_try_settle(p_raid);
end $$;

-- Pay one step's reward to its assignee.
create or replace function public.raid_pay_step(p_step uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare s raid_steps;
begin
  select * into s from raid_steps where id = p_step for update;
  if s.paid then return; end if;
  update raid_steps set status = p_status, paid = true, decided_at = coalesce(decided_at, now()) where id = p_step;
  if s.assignee is not null and s.reward > 0 then
    perform raid_pay(s.raid_id, s.assignee, s.reward, 'raid_pay', s.id::text);
    update raid_members set earned = earned + s.reward where raid_id = s.raid_id and user_id = s.assignee;
  end if;
end $$;

-- ---------- 4. sweeper (anyone may call it; also runs inside list / detail) ----------

create or replace function public.raid_tick() returns json
language plpgsql security definer set search_path = public as $$
declare x record; auto int := 0; closed int := 0; stale int := 0;
begin
  -- 72 h without the captain's answer = auto-pass and pay.
  for x in select s.id from raid_steps s where s.status = 'submitted' and s.submitted_at < now() - interval '72 hours'
           for update skip locked loop
    perform raid_pay_step(x.id, 'auto_passed');
    auto := auto + 1;
  end loop;
  -- Lent-cat jobs stuck for 15 minutes: failed, no charge, reservation released.
  for x in select j.id, j.raid_id, j.reserve from raid_jobs j
           where j.status = 'running' and j.claimed_at < now() - interval '15 minutes' for update skip locked loop
    update raid_jobs set status = 'failed', error = 'timeout', finished_at = now() where id = x.id;
    update raids set reserved = greatest(reserved - x.reserve, 0) where id = x.raid_id;
    stale := stale + 1;
  end loop;
  -- Deadline passed.
  for x in select id from raids where status in ('recruiting', 'running') and deadline < now() for update skip locked loop
    perform raid_close(x.id, 'deadline');
    closed := closed + 1;
  end loop;
  -- Anything closing that can settle now.
  for x in select id from raids where status = 'closing' for update skip locked loop
    perform raid_try_settle(x.id);
  end loop;
  return json_build_object('auto_passed', auto, 'closed', closed, 'stale_jobs', stale);
end $$;

-- ---------- 5. public reads ----------

-- Captain credit (public): pass rate on decided steps, appeals lost, auto-passes, ratings.
create or replace function public.raid_captain_credit(p_user uuid) returns json
language sql stable security definer set search_path = public as $$
  with st as (
    select s.status from raid_steps s join raids r on r.id = s.raid_id where r.captain_id = p_user
  ), ap as (
    select a.status from raid_appeals a where a.captain_id = p_user
  )
  select json_build_object(
    'raids', (select count(*) from raids where captain_id = p_user and status in ('done', 'expired', 'cancelled', 'closing', 'running')),
    'passed', (select count(*) from st where status in ('accepted', 'auto_passed', 'judge_passed')),
    'failed', (select count(*) from st where status = 'failed'),
    'auto_passed', (select count(*) from st where status = 'auto_passed'),
    'pass_rate', (select case when count(*) filter (where status in ('accepted', 'auto_passed', 'judge_passed', 'failed')) = 0 then null
                         else round(100.0 * count(*) filter (where status in ('accepted', 'auto_passed', 'judge_passed'))
                                    / count(*) filter (where status in ('accepted', 'auto_passed', 'judge_passed', 'failed'))) end
                  from st),
    'appeals_lost', (select count(*) from ap where status = 'won'),
    'appeals', (select count(*) from ap where status in ('won', 'lost')),
    'stars', (select round(avg(stars)::numeric, 1) from raid_ratings where target = p_user and as_captain),
    'ratings', (select count(*) from raid_ratings where target = p_user and as_captain));
$$;

-- Why the caller can't join (empty = can). Items: level:<n> | skill:<id> | member | vision | text | full | device | ip
create or replace function public.raid_lacks(r raids, p_uid uuid, p_caps text[] default null) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare out text[] := '{}'; lvl int; s text;
begin
  lvl := ord_level(coalesce((select c.days from cat_levels c where c.user_id = p_uid), 0));
  if r.cond_level > lvl then out := out || ('level:' || r.cond_level); end if;
  foreach s in array r.cond_skills loop
    if not ord_has_skill(p_uid, s) then out := out || ('skill:' || s); end if;
  end loop;
  if r.cond_member and not ord_is_member(p_uid) then out := out || 'member'::text; end if;
  if p_caps is not null then
    if not ('text' = any(p_caps)) then out := out || 'text'::text; end if;
    if r.cond_vision and not ('vision' = any(p_caps)) then out := out || 'vision'::text; end if;
  end if;
  return out;
end $$;

create or replace function public.raid_row(r raids, p_uid uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', r.id, 'mode', r.mode, 'template', r.template, 'title', r.title, 'body', r.body,
    'captain_id', r.captain_id, 'captain_name', r.captain_name, 'captain_credit', raid_captain_credit(r.captain_id),
    'cond_level', r.cond_level, 'cond_skills', r.cond_skills, 'cond_member', r.cond_member, 'cond_vision', r.cond_vision,
    'team_size', r.team_size,
    'members', (select count(*) from raid_members m where m.raid_id = r.id and m.status = 'active'),
    'pool', r.pool, 'captain_pct', r.captain_pct, 'step_pcts', r.step_pcts, 'checklist', r.checklist,
    'price_1k', r.price_1k, 'used', r.used, 'reserved', r.reserved, 'spent', r.spent,
    'deadline', r.deadline, 'status', r.status, 'close_reason', r.close_reason,
    'created_at', r.created_at, 'started_at', r.started_at,
    'my_role', case when r.captain_id = p_uid then 'captain'
                    when exists (select 1 from raid_members m where m.raid_id = r.id and m.user_id = p_uid) then 'member' end,
    'my_status', (select m.status from raid_members m where m.raid_id = r.id and m.user_id = p_uid),
    'lacks', raid_lacks(r, p_uid));
$$;

-- p_scope: 'open' (recruiting, or running with a free slot) | 'mine' (captain or member).
create or replace function public.raid_list(p_scope text default 'open', p_limit int default 60) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception '还没登录'; end if;
  perform raid_tick();
  if p_scope = 'mine' then
    return coalesce((select json_agg(raid_row(r, uid) order by r.created_at desc) from (
      select * from raids r where r.captain_id = uid
         or exists (select 1 from raid_members m where m.raid_id = r.id and m.user_id = uid)
      order by r.created_at desc limit least(greatest(coalesce(p_limit, 60), 1), 200)) r), '[]'::json);
  end if;
  return coalesce((select json_agg(raid_row(r, uid) order by r.created_at desc) from (
    select * from raids r where (r.status = 'recruiting'
           or (r.status = 'running' and (select count(*) from raid_members m where m.raid_id = r.id and m.status = 'active') < r.team_size - 1))
      and r.deadline > now()
    order by r.created_at desc limit least(greatest(coalesce(p_limit, 60), 1), 200)) r), '[]'::json);
end $$;

-- Everything the caller may see about one raid. Members see only their own steps (privacy) and their own jobs.
create or replace function public.raid_detail(p_raid uuid) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids; cap boolean; mem boolean;
begin
  if uid is null then raise exception '还没登录'; end if;
  perform raid_tick();
  select * into r from raids where id = p_raid;
  if r.id is null then raise exception '没有这个副本'; end if;
  cap := r.captain_id = uid;
  mem := exists (select 1 from raid_members where raid_id = p_raid and user_id = uid);
  return json_build_object(
    'raid', raid_row(r, uid),
    'result', case when cap then r.result end,
    'members', case when cap or mem then coalesce((select json_agg(json_build_object(
        'user_id', m.user_id, 'name', m.name, 'model', m.model, 'caps', m.caps, 'slot', m.slot, 'status', m.status,
        'lend_skills', m.lend_skills, 'usage_tokens', m.usage_tokens, 'usage_fish', m.usage_fish, 'earned', m.earned,
        'level', ord_level(coalesce((select c.days from cat_levels c where c.user_id = m.user_id), 0)))
        order by m.slot) from raid_members m where m.raid_id = p_raid), '[]'::json) else '[]'::json end,
    'steps', coalesce((select json_agg(json_build_object(
        'id', s.id, 'slot', s.slot, 'pct', s.pct, 'reward', s.reward, 'assignee', s.assignee, 'title', s.title,
        'instructions', s.instructions, 'status', s.status, 'round', s.round, 'submission', s.submission,
        'submitted_at', s.submitted_at, 'unmet', s.unmet, 'reject_reason', s.reject_reason, 'decided_at', s.decided_at,
        'appeal_used', s.appeal_used, 'paid', s.paid,
        'appeal', (select json_build_object('id', a.id, 'status', a.status, 'verdict', a.verdict, 'created_at', a.created_at)
                   from raid_appeals a where a.step_id = s.id order by a.created_at desc limit 1))
        order by s.slot) from raid_steps s where s.raid_id = p_raid and (cap or s.assignee = uid)), '[]'::json),
    'jobs', coalesce((select json_agg(json_build_object(
        'id', j.id, 'assignee', j.assignee, 'skill', j.skill, 'prompt', j.prompt, 'max_tokens', j.max_tokens,
        'status', j.status, 'output', j.output, 'error', j.error, 'reported_tokens', j.reported_tokens,
        'billed_tokens', j.billed_tokens, 'cost', j.cost, 'capped', j.capped, 'model', j.model,
        'created_at', j.created_at, 'finished_at', j.finished_at)
        order by j.created_at desc) from (select * from raid_jobs where raid_id = p_raid and (cap or assignee = uid)
                                          order by created_at desc limit 200) j), '[]'::json),
    'my_ratings', coalesce((select json_agg(json_build_object('target', t.target, 'stars', t.stars))
                            from raid_ratings t where t.raid_id = p_raid and t.rater = uid), '[]'::json));
end $$;

-- ---------- 6. posting ----------

create or replace function public.raid_check_common(p_title text, p_team int, p_hours int, p_cond_level int,
                                                    p_cond_skills text[], p_device text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s text;
begin
  if uid is null then raise exception '还没登录'; end if;
  if lower(coalesce(p_device, '')) !~ '^[0-9a-f]{64}$' then raise exception '请先把 OrdCat 更新到最新版再用喵副本'; end if;
  if char_length(coalesce(trim(p_title), '')) < 2 then raise exception '标题至少 2 个字'; end if;
  if p_team is null or p_team < 2 or p_team > 5 then raise exception '人数要在 2 到 5 之间（含队长）'; end if;
  if p_hours is null or p_hours < 1 or p_hours > 336 then raise exception '截止时间要在 1 小时到 14 天之间'; end if;
  if coalesce(p_cond_level, 0) < 0 or coalesce(p_cond_level, 0) > 999 then raise exception '等级条件不对'; end if;
  foreach s in array coalesce(p_cond_skills, '{}') loop
    if s not in ('x', 'agent', 'miao') then raise exception '没有这个技能：%', s; end if;
  end loop;
  if (select count(*) from raids where captain_id = uid and status in ('recruiting', 'running', 'closing')) >= 5 then
    raise exception '同时进行中的副本最多 5 个';
  end if;
  perform fish_note_device(uid, p_device);
end $$;

-- Mode A. p_step_pcts: one per member slot (team - 1), captain_pct + sum = 100. p_checklist: 1–12 items.
create or replace function public.raid_post_result(p_title text, p_body text, p_template text, p_team int, p_hours int,
    p_pool int, p_captain_pct int, p_step_pcts int[], p_checklist text[],
    p_cond_level int default 0, p_cond_skills text[] default '{}', p_cond_member boolean default false,
    p_cond_vision boolean default false, p_name text default '', p_device text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid; parts int[]; cl jsonb := '[]'::jsonb; i int; t text; p int;
begin
  perform raid_check_common(p_title, p_team, p_hours, p_cond_level, p_cond_skills, p_device);
  if p_template not in ('翻译', '长文协作', '调研总结', '代码审查') then raise exception '没有这个模板'; end if;
  if char_length(coalesce(trim(p_body), '')) < 2 then raise exception '请写清楚任务'; end if;
  if p_pool is null or p_pool < 10 or p_pool > 20000 then raise exception '奖池要在 10 到 20000 条小鱼干之间'; end if;
  if p_captain_pct is null or p_captain_pct < 0 or p_captain_pct > 50 then raise exception '队长比例要在 0 到 50%% 之间'; end if;
  if coalesce(array_length(p_step_pcts, 1), 0) <> p_team - 1 then raise exception '每个队友都要有一份比例'; end if;
  foreach p in array p_step_pcts loop
    if p is null or p < 1 then raise exception '每一份至少 1%%'; end if;
  end loop;
  if p_captain_pct + (select sum(x) from unnest(p_step_pcts) x) <> 100 then raise exception '队长和队友的比例加起来要等于 100%%'; end if;
  if coalesce(array_length(p_checklist, 1), 0) < 1 or array_length(p_checklist, 1) > 12 then
    raise exception '验收清单要有 1 到 12 条';
  end if;
  i := 0;
  foreach t in array p_checklist loop
    t := trim(coalesce(t, ''));
    if char_length(t) < 2 or char_length(t) > 200 then raise exception '每条验收标准 2 到 200 个字'; end if;
    i := i + 1;
    cl := cl || jsonb_build_object('id', 'c' || i, 'text', t);
  end loop;
  rid := gen_random_uuid();
  parts := fish_take(uid, p_pool, p_pool, 'raid_post', rid);   -- reward fish first, then paid; raises if not enough
  insert into raids (id, mode, captain_id, captain_name, template, title, body, cond_level, cond_skills, cond_member, cond_vision,
                     team_size, deadline, pool, pool_paid, captain_pct, step_pcts, checklist, captain_device, captain_ip)
  values (rid, 'result', uid, coalesce(p_name, ''), p_template, left(trim(p_title), 80), left(p_body, 8000),
          coalesce(p_cond_level, 0), coalesce(p_cond_skills, '{}'), coalesce(p_cond_member, false), coalesce(p_cond_vision, false),
          p_team, now() + make_interval(hours => p_hours), p_pool, parts[2], p_captain_pct, p_step_pcts, cl,
          lower(p_device), raid_ip_hash());
  return rid;
end $$;

-- Mode B. Budget locked now; members are paid by usage at the end.
create or replace function public.raid_post_lend(p_title text, p_body text, p_team int, p_hours int, p_price_1k int, p_budget int,
    p_cond_level int default 0, p_cond_skills text[] default '{}', p_cond_member boolean default false,
    p_cond_vision boolean default false, p_name text default '', p_device text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid; parts int[];
begin
  perform raid_check_common(p_title, p_team, p_hours, p_cond_level, p_cond_skills, p_device);
  if p_price_1k is null or p_price_1k < 1 or p_price_1k > 1000 then raise exception '每 1k token 的价格要在 1 到 1000 条之间'; end if;
  if p_budget is null or p_budget < 10 or p_budget > 20000 then raise exception '预算要在 10 到 20000 条小鱼干之间'; end if;
  rid := gen_random_uuid();
  parts := fish_take(uid, p_budget, p_budget, 'raid_post', rid);
  insert into raids (id, mode, captain_id, captain_name, template, title, body, cond_level, cond_skills, cond_member, cond_vision,
                     team_size, deadline, pool, pool_paid, price_1k, captain_device, captain_ip)
  values (rid, 'lend', uid, coalesce(p_name, ''), '借猫', left(trim(p_title), 80), left(coalesce(p_body, ''), 8000),
          coalesce(p_cond_level, 0), coalesce(p_cond_skills, '{}'), coalesce(p_cond_member, false), coalesce(p_cond_vision, false),
          p_team, now() + make_interval(hours => p_hours), p_budget, parts[2], p_price_1k, lower(p_device), raid_ip_hash());
  return rid;
end $$;

-- ---------- 7. team ----------

-- Start a result raid once every slot is filled: one step per member slot, reward = pool × pct.
create or replace function public.raid_start(p_raid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r raids; m record;
begin
  select * into r from raids where id = p_raid for update;
  if r.status <> 'recruiting' then return; end if;
  update raids set status = 'running', started_at = now() where id = p_raid;
  if r.mode = 'result' then
    for m in select * from raid_members where raid_id = p_raid and status = 'active' order by slot loop
      insert into raid_steps (raid_id, slot, pct, reward, assignee, title)
      values (p_raid, m.slot, r.step_pcts[m.slot], (r.pool * r.step_pcts[m.slot]) / 100, m.user_id, '第 ' || m.slot || ' 份')
      on conflict (raid_id, slot) do nothing;
    end loop;
  end if;
end $$;

create or replace function public.raid_join(p_raid uuid, p_name text default '', p_model text default '',
    p_caps text[] default '{text}', p_device text default null, p_lend_skills text[] default '{}',
    p_consent boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); r raids; dev text := lower(coalesce(p_device, '')); iph text := raid_ip_hash();
  lacks text[]; slot_n int; active_n int; old raid_members; s text; ls text[] := '{}';
begin
  if uid is null then raise exception '还没登录'; end if;
  if dev !~ '^[0-9a-f]{64}$' then raise exception '请先把 OrdCat 更新到最新版再用喵副本'; end if;
  perform raid_tick();
  select * into r from raids where id = p_raid for update;
  if r.id is null then raise exception '没有这个副本'; end if;
  if r.captain_id = uid then raise exception '你是这个副本的队长'; end if;
  if r.status not in ('recruiting', 'running') or r.deadline < now() then raise exception '这个副本已经不招人了'; end if;
  select * into old from raid_members where raid_id = p_raid and user_id = uid;
  if old.user_id is not null then
    if old.status = 'active' then raise exception '你已经在这个副本里了'; end if;
    raise exception '你已经离开过这个副本，不能再加入';
  end if;
  lacks := raid_lacks(r, uid, coalesce(p_caps, '{}'));
  if array_length(lacks, 1) > 0 then raise exception '还不满足加入条件：%', array_to_string(lacks, ', '); end if;
  -- Anti-farm: not the captain's Mac or network, and not one already in this raid.
  if dev = r.captain_device or exists (select 1 from raid_members where raid_id = p_raid and device_hash = dev)
     or exists (select 1 from fish_devices where user_id = r.captain_id and device_hash = dev) then
    raise exception '同一台 Mac 不能加入同一个副本';
  end if;
  if iph is not null and (iph = r.captain_ip or exists (select 1 from raid_members where raid_id = p_raid and ip_hash = iph)) then
    raise exception '同一个网络（IP）不能加入同一个副本';
  end if;
  if (select count(*) from raid_members m join raids x on x.id = m.raid_id
      where m.user_id = uid and m.status = 'active' and x.status in ('recruiting', 'running', 'closing')) >= 5 then
    raise exception '同时参加的副本最多 5 个';
  end if;
  if r.mode = 'lend' then
    if not coalesce(p_consent, false) then raise exception '借猫前请先看完并同意隐私说明'; end if;
    foreach s in array coalesce(p_lend_skills, '{}') loop
      if s in ('问答', '翻译', '总结', '写作', '代码审查') and not (s = any(ls)) then ls := ls || s; end if;
    end loop;
    if coalesce(array_length(ls, 1), 0) = 0 then raise exception '至少选一种允许的文字技能'; end if;
  end if;
  select count(*) into active_n from raid_members where raid_id = p_raid and status = 'active';
  if active_n >= r.team_size - 1 then raise exception '人满了'; end if;
  -- Lowest slot not held by an active member (a dropped member's slot can be taken over).
  select min(g) into slot_n from generate_series(1, r.team_size - 1) g
   where not exists (select 1 from raid_members m where m.raid_id = p_raid and m.slot = g and m.status = 'active');
  perform fish_note_device(uid, dev);
  insert into raid_members (raid_id, user_id, name, model, caps, lend_skills, slot, device_hash, ip_hash, consent_at)
  values (p_raid, uid, left(coalesce(p_name, ''), 40), left(coalesce(p_model, ''), 80), coalesce(p_caps, '{text}'), ls,
          slot_n, dev, iph, case when r.mode = 'lend' then now() end);
  -- Taking over a dropped member's step in a running result raid.
  update raid_steps set assignee = uid
  where raid_id = p_raid and slot = slot_n and status in ('waiting_brief', 'working') and not paid;
  if r.status = 'recruiting' and active_n + 1 >= r.team_size - 1 then perform raid_start(p_raid); end if;
  return json_build_object('ok', true, 'slot', slot_n, 'started', (select status from raids where id = p_raid) = 'running');
end $$;

-- Leave: before start just frees the slot; after start the member is 'dropped' and their unfinished step can be reassigned.
create or replace function public.raid_leave(p_raid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids; m raid_members;
begin
  select * into r from raids where id = p_raid for update;
  select * into m from raid_members where raid_id = p_raid and user_id = uid for update;
  if m.user_id is null or m.status <> 'active' then raise exception '你不在这个副本里'; end if;
  if r.status in ('done', 'cancelled', 'expired') then raise exception '副本已经结束了'; end if;
  if r.status = 'recruiting' then
    delete from raid_members where raid_id = p_raid and user_id = uid;
  else
    update raid_members set status = 'dropped' where raid_id = p_raid and user_id = uid;
    update raid_steps set assignee = null where raid_id = p_raid and assignee = uid and status in ('waiting_brief', 'working');
    update raid_jobs set status = 'cancelled', finished_at = now() where raid_id = p_raid and assignee = uid and status = 'queued';
    update raids set reserved = coalesce((select sum(reserve) from raid_jobs where raid_id = p_raid and status in ('queued', 'running')), 0)
    where id = p_raid;
  end if;
end $$;

create or replace function public.raid_kick(p_raid uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids;
begin
  select * into r from raids where id = p_raid for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能请人离队'; end if;
  if r.status not in ('recruiting', 'running') then raise exception '副本已经结束了'; end if;
  if r.status = 'recruiting' then
    delete from raid_members where raid_id = p_raid and user_id = p_user and status = 'active';
  else
    -- After start, only someone whose step isn't handed in yet.
    if exists (select 1 from raid_steps where raid_id = p_raid and assignee = p_user
               and status not in ('waiting_brief', 'working')) then
      raise exception '这位队友已经交了成果，不能请离';
    end if;
    update raid_members set status = 'kicked' where raid_id = p_raid and user_id = p_user and status = 'active';
    update raid_steps set assignee = null where raid_id = p_raid and assignee = p_user and status in ('waiting_brief', 'working');
    update raid_jobs set status = 'cancelled', finished_at = now() where raid_id = p_raid and assignee = p_user and status = 'queued';
    update raids set reserved = coalesce((select sum(reserve) from raid_jobs where raid_id = p_raid and status in ('queued', 'running')), 0)
    where id = p_raid;
  end if;
end $$;

-- Captain disbands. Before start: full refund. After start: unfinished work is cancelled, handed-in work still
-- gets its 72 h (auto-pass) and appeals; the rest of the pool returns when everything is settled.
create or replace function public.raid_cancel(p_raid uuid) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids;
begin
  select * into r from raids where id = p_raid for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能解散副本'; end if;
  if r.status not in ('recruiting', 'running') then raise exception '副本已经在结算或已经结束了'; end if;
  perform raid_close(p_raid, 'disbanded');
  select * into r from raids where id = p_raid;
  return json_build_object('status', r.status, 'spent', r.spent, 'pool', r.pool);
end $$;

-- ---------- 8. 结果副本 work ----------

-- Captain's cat splits the task: [{slot, title, instructions}]. A step can be re-briefed until it is handed in.
create or replace function public.raid_brief(p_raid uuid, p_briefs jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids; b jsonb; n int := 0; k int;
begin
  select * into r from raids where id = p_raid for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能分配任务'; end if;
  if r.mode <> 'result' or r.status <> 'running' then raise exception '副本还没开打'; end if;
  if jsonb_typeof(p_briefs) <> 'array' then raise exception '分工格式不对'; end if;
  for b in select * from jsonb_array_elements(p_briefs) loop
    update raid_steps set title = left(coalesce(b ->> 'title', title), 80),
                          instructions = left(coalesce(b ->> 'instructions', ''), 8000),
                          status = 'working'
    where raid_id = p_raid and slot = (b ->> 'slot')::int and status in ('waiting_brief', 'working');
    get diagnostics k = row_count;
    n := n + k;
  end loop;
  return n;
end $$;

-- Give a dropped member's step to another active member (or leave it for whoever joins that slot).
create or replace function public.raid_reassign(p_step uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s raid_steps; r raids;
begin
  select * into s from raid_steps where id = p_step for update;
  select * into r from raids where id = s.raid_id for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能转交任务'; end if;
  if r.status <> 'running' then raise exception '副本不在进行中'; end if;
  if s.status not in ('waiting_brief', 'working') or s.paid then raise exception '这一份已经交了，不能转交'; end if;
  if s.assignee is not null and exists (select 1 from raid_members where raid_id = r.id and user_id = s.assignee and status = 'active') then
    raise exception '这一份的队友还在队里';
  end if;
  if not exists (select 1 from raid_members where raid_id = r.id and user_id = p_user and status = 'active') then
    raise exception '只能转给队里的队友';
  end if;
  update raid_steps set assignee = p_user where id = p_step;
end $$;

-- Member hands in (first time, or the one rework after a rejection).
create or replace function public.raid_submit(p_step uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s raid_steps; r raids;
begin
  select * into s from raid_steps where id = p_step for update;
  if s.id is null or s.assignee is distinct from uid then raise exception '这一份不在你手上'; end if;
  select * into r from raids where id = s.raid_id;
  if r.status <> 'running' or r.deadline < now() then raise exception '副本已经截止了'; end if;
  if char_length(coalesce(trim(p_text), '')) < 1 then raise exception '成果是空的'; end if;
  if s.status = 'working' then
    update raid_steps set submission = left(p_text, 30000), submitted_at = now(), status = 'submitted' where id = p_step;
  elsif s.status = 'rejected' and s.round = 0 then
    update raid_steps set submission = left(p_text, 30000), submitted_at = now(), status = 'submitted', round = 1,
                          unmet = '{}', reject_reason = null, decided_at = null where id = p_step;
  else
    raise exception '这一份现在不能提交';
  end if;
end $$;

-- Captain accepts, or rejects with the unmet checklist items + a reason. Rejecting the rework ends the step.
create or replace function public.raid_decide(p_step uuid, p_accept boolean, p_unmet text[] default '{}', p_reason text default '')
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s raid_steps; r raids; ids text[]; u text;
begin
  select * into s from raid_steps where id = p_step for update;
  select * into r from raids where id = s.raid_id for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能验收'; end if;
  if s.status <> 'submitted' then raise exception '这一份现在不用验收'; end if;
  if p_accept then
    perform raid_pay_step(p_step, 'accepted');
    perform raid_try_settle(r.id);
    return;
  end if;
  select array_agg(x ->> 'id') into ids from jsonb_array_elements(r.checklist) x;
  if coalesce(array_length(p_unmet, 1), 0) = 0 then raise exception '退回要勾出没达到的清单项'; end if;
  foreach u in array p_unmet loop
    if not (u = any(ids)) then raise exception '清单里没有 %', u; end if;
  end loop;
  if char_length(coalesce(trim(p_reason), '')) < 2 then raise exception '退回要写理由'; end if;
  update raid_steps set status = case when s.round = 0 and r.status = 'running' then 'rejected' else 'failed' end,
                        unmet = p_unmet, reject_reason = left(p_reason, 1000), decided_at = now()
  where id = p_step;
end $$;

-- Member appeals a rejection once (10 fish, not refunded). The judge (Edge Function raid-judge) picks it up.
create or replace function public.raid_appeal(p_step uuid, p_reason text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s raid_steps; r raids; aid uuid;
begin
  select * into s from raid_steps where id = p_step for update;
  if s.id is null or s.assignee is distinct from uid then raise exception '这一份不在你手上'; end if;
  if s.status not in ('rejected', 'failed') then raise exception '只有被退回的成果能申诉'; end if;
  if s.appeal_used then raise exception '每一份只能申诉一次'; end if;
  if s.decided_at < now() - interval '72 hours' then raise exception '退回超过 72 小时，不能再申诉了'; end if;
  select * into r from raids where id = s.raid_id;
  insert into raid_appeals (step_id, raid_id, member_id, captain_id, fee, reason, checklist, unmet, captain_reason, submission, step_round)
  values (p_step, s.raid_id, uid, r.captain_id, 10, left(coalesce(p_reason, ''), 1000), r.checklist, s.unmet, s.reject_reason,
          coalesce(s.submission, ''), s.round)
  returning id into aid;
  perform fish_take(uid, 10, 10, 'raid_appeal_fee', s.raid_id, aid::text);
  update raid_steps set status = 'appealed', appeal_used = true where id = p_step;
  return aid;
end $$;

-- Captain's cat merged the accepted parts: close the raid. Every step must be settled first.
create or replace function public.raid_finish(p_raid uuid, p_result text default '') returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids; open_n int := 0;
begin
  perform raid_tick();
  select * into r from raids where id = p_raid for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能结束副本'; end if;
  if r.status not in ('recruiting', 'running') then raise exception '副本已经在结算或已经结束了'; end if;
  if r.mode = 'result' then
    if r.status = 'recruiting' then raise exception '副本还没开打，不想等了可以解散'; end if;
    -- Rejected / failed parts may stay: they keep their 72 h appeal window while the raid settles.
    select count(*) into open_n from raid_steps where raid_id = p_raid
       and status in ('waiting_brief', 'working', 'submitted', 'appealed');
    if open_n > 0 then
      raise exception '还有 % 份没做完、没验收或在申诉，先处理好再合并', open_n;
    end if;
  else
    if exists (select 1 from raid_jobs where raid_id = p_raid and status = 'running') then
      raise exception '还有借来的小猫在干活，等它们做完再结算';
    end if;
  end if;
  update raids set result = nullif(left(coalesce(p_result, ''), 60000), '') where id = p_raid;
  perform raid_close(p_raid, 'finished');
  select * into r from raids where id = p_raid;
  return json_build_object('status', r.status, 'spent', r.spent, 'pool', r.pool);
end $$;

-- ---------- 9. 借猫副本 jobs ----------

create or replace function public.raid_job_create(p_raid uuid, p_skill text, p_prompt text, p_member uuid default null,
                                                  p_max_tokens int default 4000) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids; res int; jid uuid; mt int := least(greatest(coalesce(p_max_tokens, 4000), 200), 16000);
begin
  perform raid_tick();
  select * into r from raids where id = p_raid for update;
  if r.id is null or r.captain_id <> uid then raise exception '只有队长能派活'; end if;
  if r.mode <> 'lend' or r.status not in ('recruiting', 'running') then raise exception '这个借猫副本现在不能派活'; end if;
  if p_skill not in ('问答', '翻译', '总结', '写作', '代码审查') then raise exception '借来的小猫只能做文字活'; end if;
  if char_length(coalesce(trim(p_prompt), '')) < 1 or char_length(p_prompt) > 8000 then raise exception '活的内容要在 1 到 8000 字之间'; end if;
  if p_member is not null and not exists (select 1 from raid_members where raid_id = p_raid and user_id = p_member
                                          and status = 'active' and p_skill = any(lend_skills)) then
    raise exception '这位队友没有借出这种技能';
  end if;
  if p_member is null and not exists (select 1 from raid_members where raid_id = p_raid and status = 'active'
                                      and p_skill = any(lend_skills)) then
    raise exception '队里还没有小猫借出这种技能';
  end if;
  if (select count(*) from raid_jobs where raid_id = p_raid and status = 'queued') >= 20 then raise exception '排队的活最多 20 个'; end if;
  res := ceil(mt::numeric * r.price_1k / 1000)::int;
  if r.used + r.reserved + res > r.pool then
    raise exception '预算不够：这个活最多要 % 条，还剩 % 条', res, r.pool - r.used - r.reserved;
  end if;
  insert into raid_jobs (raid_id, captain_id, assignee, skill, prompt, max_tokens, reserve)
  values (p_raid, uid, p_member, p_skill, p_prompt, mt, res) returning id into jid;
  update raids set reserved = reserved + res where id = p_raid;
  return jid;
end $$;

create or replace function public.raid_job_cancel(p_job uuid) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); j raid_jobs;
begin
  select * into j from raid_jobs where id = p_job for update;
  if j.id is null or j.captain_id <> uid then raise exception '只有队长能撤回'; end if;
  if j.status <> 'queued' then raise exception '这个活已经开始做了'; end if;
  update raid_jobs set status = 'cancelled', finished_at = now() where id = p_job;
  update raids set reserved = greatest(reserved - j.reserve, 0) where id = j.raid_id;
end $$;

-- A lent cat asks for its next job (one at a time per member). Returns null when there is none.
create or replace function public.raid_job_claim(p_model text default '') returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); j raid_jobs;
begin
  if uid is null then raise exception '还没登录'; end if;
  perform raid_tick();
  if exists (select 1 from raid_jobs where assignee = uid and status = 'running') then return null; end if;
  select x.* into j from raid_jobs x
    join raids r on r.id = x.raid_id
    join raid_members m on m.raid_id = x.raid_id and m.user_id = uid
   where x.status = 'queued' and r.mode = 'lend' and r.status in ('recruiting', 'running')
     and m.status = 'active' and x.skill = any(m.lend_skills) and (x.assignee is null or x.assignee = uid)
   order by (x.assignee is null), x.created_at
   limit 1 for update of x skip locked;
  if j.id is null then return null; end if;
  update raid_jobs set status = 'running', assignee = uid, claimed_at = now(), model = left(coalesce(p_model, ''), 80) where id = j.id;
  return json_build_object('id', j.id, 'raid_id', j.raid_id, 'skill', j.skill, 'prompt', j.prompt, 'max_tokens', j.max_tokens,
                           'title', (select title from raids where id = j.raid_id));
end $$;

-- The lent cat reports the output and its token usage. Billing = min(reported, job cap, length estimate, hourly room).
create or replace function public.raid_job_done(p_job uuid, p_output text, p_tokens int) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); j raid_jobs; r raids; out_txt text := left(coalesce(p_output, ''), 20000);
  rep int := greatest(coalesce(p_tokens, 0), 0); est int; hour_used int; hour_cap int := 60000; billed int; c int; why text;
begin
  select * into j from raid_jobs where id = p_job for update;
  if j.id is null or j.assignee is distinct from uid or j.status <> 'running' then raise exception '这个活不在你手上'; end if;
  select * into r from raids where id = j.raid_id for update;
  -- Generous upper bound from the text itself: ≈ 2 tokens per character of prompt + output, plus overhead.
  est := 2 * (char_length(j.prompt) + char_length(out_txt)) + 500;
  select coalesce(sum(billed_tokens), 0) into hour_used from raid_jobs
   where raid_id = j.raid_id and assignee = uid and status = 'done' and finished_at > now() - interval '1 hour';
  billed := least(rep, j.max_tokens, est, greatest(hour_cap - hour_used, 0));
  if billed < rep then
    why := case when billed = j.max_tokens then 'job_cap' when billed = est then 'length_estimate' else 'hourly_cap' end;
  end if;
  c := least(ceil(billed::numeric * r.price_1k / 1000)::int, j.reserve);
  update raid_jobs set status = 'done', output = out_txt, reported_tokens = rep, billed_tokens = billed, cost = c,
                       capped = why, finished_at = now() where id = p_job;
  update raids set reserved = greatest(reserved - j.reserve, 0), used = used + c where id = j.raid_id;
  update raid_members set usage_tokens = usage_tokens + billed, usage_fish = usage_fish + c
  where raid_id = j.raid_id and user_id = uid;
  perform raid_try_settle(j.raid_id);
  return json_build_object('billed_tokens', billed, 'cost', c, 'capped', why);
end $$;

create or replace function public.raid_job_fail(p_job uuid, p_error text default '') returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); j raid_jobs;
begin
  select * into j from raid_jobs where id = p_job for update;
  if j.id is null or j.assignee is distinct from uid or j.status <> 'running' then raise exception '这个活不在你手上'; end if;
  update raid_jobs set status = 'failed', error = left(coalesce(p_error, ''), 300), finished_at = now() where id = p_job;
  update raids set reserved = greatest(reserved - j.reserve, 0) where id = j.raid_id;
  perform raid_try_settle(j.raid_id);
end $$;

-- ---------- 10. ratings ----------

create or replace function public.raid_rate(p_raid uuid, p_user uuid, p_stars int, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r raids;
begin
  select * into r from raids where id = p_raid;
  if r.id is null then raise exception '没有这个副本'; end if;
  if r.status not in ('closing', 'done', 'expired', 'cancelled') then raise exception '副本结束后才能评分'; end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then raise exception '评分是 1 到 5 星'; end if;
  if uid = r.captain_id then
    if not exists (select 1 from raid_members where raid_id = p_raid and user_id = p_user) then raise exception '只能给队友评分'; end if;
  elsif p_user = r.captain_id then
    if not exists (select 1 from raid_members where raid_id = p_raid and user_id = uid) then raise exception '你不在这个副本里'; end if;
  else
    raise exception '只能给队长或队友评分';
  end if;
  insert into raid_ratings (raid_id, rater, target, as_captain, stars, note)
  values (p_raid, uid, p_user, p_user = r.captain_id, p_stars, left(coalesce(p_note, ''), 300))
  on conflict (raid_id, rater, target) do update set stars = excluded.stars, note = excluded.note, created_at = now();
end $$;

-- ---------- 11. AI judge (service_role only; called by the Edge Function raid-judge, never by the app) ----------

-- Take up to p_limit appeals to judge (re-takes ones stuck in 'judging' for 15 minutes).
create or replace function public.raid_judge_claim(p_limit int default 5) returns json
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  select array_agg(id) into ids from (
    select id from raid_appeals
    where status = 'pending_judge' or (status = 'judging' and claimed_at < now() - interval '15 minutes')
    order by created_at limit least(greatest(coalesce(p_limit, 5), 1), 20) for update skip locked) x;
  if ids is null then return '[]'::json; end if;
  update raid_appeals set status = 'judging', claimed_at = now() where id = any(ids);
  return (select json_agg(json_build_object('id', a.id, 'checklist', a.checklist, 'unmet', a.unmet,
            'captain_reason', a.captain_reason, 'member_reason', a.reason, 'submission', a.submission,
            'template', r.template, 'task', r.body,
            'instructions', (select s.instructions from raid_steps s where s.id = a.step_id)))
          from raid_appeals a join raids r on r.id = a.raid_id where a.id = any(ids));
end $$;

-- Put a claimed appeal back (judge unreachable / bad output): it stays pending_judge.
create or replace function public.raid_judge_release(p_appeal uuid, p_note text default '') returns void
language sql security definer set search_path = public as $$
  update raid_appeals set status = 'pending_judge', claimed_at = null,
         verdict = jsonb_build_object('error', left(coalesce(p_note, ''), 300))
  where id = p_appeal and status = 'judging';
$$;

-- Record the verdict. Pass = every checklist item met (decided here, not by the model's own "pass").
-- Won: the step is paid (judge_passed). Lost: back to where it was (a first rejection can still be reworked).
create or replace function public.raid_judge_result(p_appeal uuid, p_items jsonb, p_model text default '') returns json
language plpgsql security definer set search_path = public as $$
declare a raid_appeals; s raid_steps; c jsonb; it jsonb; met boolean; all_met boolean := true; items jsonb := '[]'::jsonb;
begin
  select * into a from raid_appeals where id = p_appeal for update;
  if a.id is null or a.status not in ('judging', 'pending_judge') then raise exception 'appeal not open'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'items must be an array'; end if;
  for c in select * from jsonb_array_elements(a.checklist) loop
    select x into it from jsonb_array_elements(p_items) x where x ->> 'id' = c ->> 'id' limit 1;
    met := coalesce((it ->> 'met')::boolean, false);
    all_met := all_met and met;
    items := items || jsonb_build_object('id', c ->> 'id', 'met', met, 'evidence', left(coalesce(it ->> 'evidence', ''), 600));
  end loop;
  update raid_appeals set status = case when all_met then 'won' else 'lost' end,
         verdict = jsonb_build_object('pass', all_met, 'items', items), judge_model = left(coalesce(p_model, ''), 120),
         judged_at = now()
  where id = p_appeal;
  select * into s from raid_steps where id = a.step_id for update;
  if all_met then
    perform raid_pay_step(a.step_id, 'judge_passed');
  else
    update raid_steps set status = case when a.step_round = 0
                                          and (select status from raids where id = a.raid_id) = 'running' then 'rejected'
                                        else 'failed' end
    where id = a.step_id and status = 'appealed';
  end if;
  perform raid_try_settle(a.raid_id);
  return json_build_object('pass', all_met, 'items', items);
end $$;

-- ---------- grants ----------
revoke all on function public.raid_lock_tg(), public.raid_ip_hash(), public.raid_pay(uuid, uuid, int, text, text),
  public.raid_bonus(uuid, uuid), public.raid_step_final(raid_steps), public.raid_try_settle(uuid), public.raid_close(uuid, text),
  public.raid_pay_step(uuid, text), public.raid_lacks(raids, uuid, text[]), public.raid_row(raids, uuid),
  public.raid_check_common(text, int, int, int, text[], text), public.raid_start(uuid),
  public.raid_judge_claim(int), public.raid_judge_release(uuid, text), public.raid_judge_result(uuid, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.raid_judge_claim(int), public.raid_judge_release(uuid, text),
  public.raid_judge_result(uuid, jsonb, text), public.raid_tick() to service_role;
revoke all on function public.raid_tick(), public.raid_captain_credit(uuid), public.raid_list(text, int), public.raid_detail(uuid),
  public.raid_post_result(text, text, text, int, int, int, int, int[], text[], int, text[], boolean, boolean, text, text),
  public.raid_post_lend(text, text, int, int, int, int, int, text[], boolean, boolean, text, text),
  public.raid_join(uuid, text, text, text[], text, text[], boolean), public.raid_leave(uuid), public.raid_kick(uuid, uuid),
  public.raid_cancel(uuid), public.raid_brief(uuid, jsonb), public.raid_reassign(uuid, uuid), public.raid_submit(uuid, text),
  public.raid_decide(uuid, boolean, text[], text), public.raid_appeal(uuid, text), public.raid_finish(uuid, text),
  public.raid_job_create(uuid, text, text, uuid, int), public.raid_job_cancel(uuid), public.raid_job_claim(text),
  public.raid_job_done(uuid, text, int), public.raid_job_fail(uuid, text), public.raid_rate(uuid, uuid, int, text),
  public.raid_is_captain(uuid, uuid), public.raid_is_member(uuid, uuid)
  from public, anon;
grant execute on function public.raid_tick(), public.raid_captain_credit(uuid), public.raid_list(text, int), public.raid_detail(uuid),
  public.raid_post_result(text, text, text, int, int, int, int, int[], text[], int, text[], boolean, boolean, text, text),
  public.raid_post_lend(text, text, int, int, int, int, int, text[], boolean, boolean, text, text),
  public.raid_join(uuid, text, text, text[], text, text[], boolean), public.raid_leave(uuid), public.raid_kick(uuid, uuid),
  public.raid_cancel(uuid), public.raid_brief(uuid, jsonb), public.raid_reassign(uuid, uuid), public.raid_submit(uuid, text),
  public.raid_decide(uuid, boolean, text[], text), public.raid_appeal(uuid, text), public.raid_finish(uuid, text),
  public.raid_job_create(uuid, text, text, uuid, int), public.raid_job_cancel(uuid), public.raid_job_claim(text),
  public.raid_job_done(uuid, text, int), public.raid_job_fail(uuid, text), public.raid_rate(uuid, uuid, int, text),
  public.raid_is_captain(uuid, uuid), public.raid_is_member(uuid, uuid)
  to authenticated;

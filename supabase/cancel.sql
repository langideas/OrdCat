-- OrdCat · Kündigungsbutton (BGB §312k) + Widerrufsfunktion (BGB §356a). 2026-11-27.
-- Run in Supabase → SQL Editor AFTER schema.sql … membership.sql → fish.sql → raids.sql.
-- Safe to run again (if not exists / create or replace / drop … if exists).
--
-- ordcat.de/kuendigen.html und ordcat.de/widerruf.html schicken das Formular an die Edge Function cancel-contract
-- (--no-verify-jwt, kein Login nötig). Nur die Funktion schreibt hier, mit service_role. App und Browser kommen nicht ran.

create extension if not exists pgcrypto;

create table if not exists public.cancel_requests (
  id uuid primary key default gen_random_uuid(),
  received_at timestamptz not null default now(),
  action text not null default 'cancel' check (action in ('cancel', 'withdraw')),   -- Kündigung | Widerruf
  kind text not null default 'ordinary' check (kind in ('ordinary', 'extraordinary')),
  reason text check (reason is null or char_length(reason) <= 2000),
  email text not null check (char_length(email) between 3 and 254),
  name text check (name is null or char_length(name) <= 200),                         -- Widerruf: Name des Verbrauchers
  contract text not null check (contract in ('pro', 'max', 'x', 'agent', 'miao', 'all', 'fish', 'topup', 'other')),
  contract_note text check (contract_note is null or char_length(contract_note) <= 500),
  requested_date date,                                   -- null = zum nächstmöglichen Zeitpunkt
  lang text not null default 'de' check (lang in ('de', 'zh', 'en')),
  user_id uuid references auth.users(id) on delete set null,
  ip_hash text,
  status text not null default 'received'
    check (status in ('received', 'done', 'manual', 'no_match', 'error')),
  matched jsonb not null default '[]'::jsonb,            -- [{id, item, provider, ends_at, action}]
  effective_at timestamptz,
  email_sent boolean not null default false,
  email_error text,
  handled_at timestamptz,
  handled_note text
);

-- Older runs of this file: add columns that may be missing.
alter table public.cancel_requests add column if not exists action text not null default 'cancel';
alter table public.cancel_requests add column if not exists name text;
alter table public.cancel_requests add column if not exists contract_note text;
alter table public.cancel_requests add column if not exists handled_at timestamptz;
alter table public.cancel_requests add column if not exists handled_note text;

create index if not exists cancel_requests_ip on public.cancel_requests (ip_hash, received_at desc);
create index if not exists cancel_requests_email on public.cancel_requests (lower(email), received_at desc);
create index if not exists cancel_requests_open on public.cancel_requests (status, received_at) where status in ('manual', 'no_match', 'error');

-- RLS on, no policies: anon / authenticated see nothing. service_role bypasses RLS.
alter table public.cancel_requests enable row level security;
revoke all on table public.cancel_requests from public, anon, authenticated;
grant all on table public.cancel_requests to service_role;

-- E-Mail → Supabase user id (auth.users is not reachable through PostgREST). service_role only.
create or replace function public.cancel_find_user(p_email text) returns uuid
language sql stable security definer set search_path = public, auth as $$
  select u.id from auth.users u
   where lower(u.email) = lower(trim(p_email))
   order by u.created_at
   limit 1
$$;

-- Simple rate limit: requests from one IP hash / one email in the last hour.
create or replace function public.cancel_recent(p_ip_hash text, p_email text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'ip', (select count(*) from cancel_requests where ip_hash = p_ip_hash and received_at > now() - interval '1 hour'),
    'email', (select count(*) from cancel_requests where lower(email) = lower(trim(p_email)) and received_at > now() - interval '1 hour'))
$$;

revoke all on function public.cancel_find_user(text), public.cancel_recent(text, text) from public, anon, authenticated;
grant execute on function public.cancel_find_user(text), public.cancel_recent(text, text) to service_role;

-- Offene Fälle (für Lang, im SQL Editor):
--   select id, received_at, action, kind, email, contract, requested_date, status, matched, reason
--     from cancel_requests where status in ('manual', 'no_match', 'error') and handled_at is null order by received_at;
--   update cancel_requests set handled_at = now(), handled_note = '…' where id = '…';

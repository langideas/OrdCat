-- OrdCat · Abo-Details für die App + Bestätigungsmails (BGB §312f) nach Stripe-Zahlung. 2026-11-27 (v0.2.64).
-- Run in Supabase → SQL Editor AFTER schema.sql … fish.sql → raids.sql → cancel.sql.
-- Safe to run again (if not exists / create or replace).
--
-- 1) subscriptions bekommt Spalten, die die App im Mitgliedschafts-Bereich zeigt (Monat/Jahr, gekündigt, Preis).
--    stripe-webhook schreibt sie; ohne diese Datei schreibt er nur die alten Spalten (Mitgliedschaft geht trotzdem).
-- 2) receipt_emails: stripe-webhook schickt eigene Mails über Resend (Kaufbestätigung, Verlängerung, Zahlung
--    fehlgeschlagen, Kündigung über das Stripe-Portal). Damit Stripe-Wiederholungen keine zweite Mail auslösen, legt
--    die Funktion VOR dem Senden eine Zeile an (primary key): cs_… (Kauf), in_… (Verlängerung), fail:in_…, cancel:sub_…:<Ende>.
--    Gibt es die Zeile schon, wird nicht gesendet. Nur service_role liest und schreibt; App und Browser kommen nicht ran.

alter table public.subscriptions add column if not exists billing_interval text;            -- month | year
alter table public.subscriptions add column if not exists cancel_at_period_end boolean not null default false;
alter table public.subscriptions add column if not exists amount_cents integer;               -- Preis pro Zeitraum (inkl. MwSt.)
alter table public.subscriptions add column if not exists currency text;

create table if not exists public.receipt_emails (
  id text primary key,                     -- cs_… | in_… | fail:in_… | cancel:sub_…:<unix> | upgrade:in_… | sched:sub_sched_… | unpaid:cs_…
  kind text not null default 'checkout',
  user_id uuid references auth.users(id) on delete set null,
  item text check (item is null or char_length(item) <= 20),           -- pro | max | x | agent | miao | fish | topup
  lang text not null default 'de' check (lang in ('de', 'zh', 'en')),
  status text not null default 'sending' check (status in ('sending', 'sent', 'failed', 'skipped')),
  error text check (error is null or char_length(error) <= 500),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

-- Constraints by name, so re-running the file (or an older version of it) ends in the same state.
alter table public.receipt_emails drop constraint if exists receipt_emails_id_check;
alter table public.receipt_emails add constraint receipt_emails_id_check check (id ~ '^[A-Za-z0-9_:.-]+$' and char_length(id) between 6 and 300);
alter table public.receipt_emails drop constraint if exists receipt_emails_kind_check;
alter table public.receipt_emails add constraint receipt_emails_kind_check check (kind in ('checkout', 'renewal', 'failed', 'cancel', 'upgrade', 'scheduled', 'unpaid'));

create index if not exists receipt_emails_user on public.receipt_emails (user_id, created_at desc);
create index if not exists receipt_emails_open on public.receipt_emails (status, created_at) where status in ('sending', 'failed');

-- RLS on, no policies: anon / authenticated see nothing. service_role bypasses RLS.
alter table public.receipt_emails enable row level security;
revoke all on table public.receipt_emails from public, anon, authenticated;
grant all on table public.receipt_emails to service_role;

-- Nicht zugestellte Bestätigungen (für Lang, im SQL Editor):
--   select id, kind, item, lang, status, error, created_at from receipt_emails
--    where status in ('sending', 'failed') order by created_at desc;
-- Eine Mail erneut senden lassen: Zeile löschen und das Event in Stripe → Webhooks → „Resend“ erneut zustellen.
--   delete from receipt_emails where id = 'cs_…';

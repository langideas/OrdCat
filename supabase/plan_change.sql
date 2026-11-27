-- OrdCat · Planwechsel in der App (v0.2.64). Nach receipts.sql ausführen; mehrfach ausführbar.
-- 1) subscriptions.pending_*: vorgemerkter Wechsel zum Ende des Zeitraums (Downgrade Max → Pro oder jährlich → monatlich),
--    in Stripe als Subscription Schedule (Phase 1 = jetziger Preis bis Periodenende, Phase 2 = neuer Preis).
--    stripe-webhook / stripe-checkout schreiben die Spalten, die App zeigt „{Datum} 起改为 …“ mit „撤销“.
--    Ohne diese Spalten läuft alles weiter, nur zeigt die App den vorgemerkten Wechsel nicht an.
alter table public.subscriptions add column if not exists pending_plan text;          -- pro | max
alter table public.subscriptions add column if not exists pending_interval text;      -- month | year
alter table public.subscriptions add column if not exists pending_at timestamptz;     -- wann der Wechsel greift

-- 2) receipt_emails: neue Mail-Arten
--    upgrade   = „Plan upgraded“ (invoice.paid, billing_reason = subscription_update), Schlüssel upgrade:in_…
--    scheduled = „Plan change scheduled“ (stripe-checkout nach dem Anlegen des Schedules), Schlüssel sched:sub_sched_…
--    unpaid    = „Your OrdCat order isn't complete“ (checkout.session.expired), Schlüssel unpaid:cs_… (auch in unpaid_mail.sql)
--    Ohne diesen Teil scheitert nur das Anlegen der Zeile (CHECK) und diese Mails werden nicht geschickt.
alter table public.receipt_emails drop constraint if exists receipt_emails_kind_check;
alter table public.receipt_emails add constraint receipt_emails_kind_check
  check (kind in ('checkout', 'renewal', 'failed', 'cancel', 'upgrade', 'scheduled', 'unpaid'));

-- OrdCat · 未付款提醒邮件（v0.2.64+）。在 receipts.sql 和 plan_change.sql 之后运行；可以重复运行。
-- receipt_emails.kind 加 'unpaid'：stripe-webhook 收到 checkout.session.expired（没付款的结账过期）时发一封
-- 「Your OrdCat order isn't complete」，key = unpaid:cs_…，每个 Checkout Session 只发一次。
-- 没运行这个文件时，只是这封提醒发不出去（CHECK 不让插入那一行），别的邮件和付款都不受影响。
-- receipts.sql / plan_change.sql 里的同一个 CHECK 也已经包含 'unpaid'，以后重跑它们不会把它去掉。
alter table public.receipt_emails drop constraint if exists receipt_emails_kind_check;
alter table public.receipt_emails add constraint receipt_emails_kind_check
  check (kind in ('checkout', 'renewal', 'failed', 'cancel', 'upgrade', 'scheduled', 'unpaid'));

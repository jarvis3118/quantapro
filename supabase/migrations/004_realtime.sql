-- =========================================================
-- 004_realtime.sql
-- Trimora — Realtime configuration
--
-- REPLICA IDENTITY FULL is required so UPDATE/DELETE payloads
-- include the full old row (not just the primary key), which the
-- frontend needs to detect what changed (e.g. old status vs new).
-- =========================================================

alter table public.appointments   replica identity full;
alter table public.payments       replica identity full;
alter table public.salon_activity replica identity full;

-- Add tables to the Supabase realtime publication.
-- (If a table is already a member, Postgres will error — in that
-- case just skip that line; this is safe to re-run on a fresh DB.)
alter publication supabase_realtime add table public.appointments;
alter publication supabase_realtime add table public.payments;
alter publication supabase_realtime add table public.salon_activity;

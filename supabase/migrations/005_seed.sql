-- =========================================================
-- 005_seed.sql
-- Trimora — seed data
--
-- IMPORTANT — read this before running:
-- profiles.id is a foreign key into auth.users(id), so demo
-- customer/staff *profiles* cannot be seeded with made-up UUIDs —
-- the auth user must exist first. Two options:
--
--   A) Dashboard: Authentication → Users → "Add user", for each
--      demo person (see suggested list below), then copy the UUID
--      Supabase assigns and paste it into the variables block.
--
--   B) Script (recommended, run once before this file):
--      supabase/seed_auth_users.mjs creates the demo auth users via
--      the Admin API and prints the UUIDs to paste below.
--
-- Suggested demo accounts:
--   staff1@trimora.demo   / role staff   (the person running the counter)
--   rahul@trimora.demo    / role customer
--   priya@trimora.demo    / role customer
--   aman@trimora.demo     / role customer
--   neha@trimora.demo     / role customer
-- =========================================================

-- ---------------------------------------------------------
-- 1. Services (safe to run any time — no FK dependency)
-- ---------------------------------------------------------
insert into public.services (name, description, duration_minutes, price, is_active)
values
  ('Haircut',    'Classic haircut and styling',        30, 200.00, true),
  ('Beard Trim', 'Beard shaping and trim',              15, 100.00, true),
  ('Hair Wash',  'Shampoo and blow-dry',                20, 150.00, true),
  ('Hair Spa',   'Deep conditioning hair spa treatment', 45, 500.00, true)
on conflict do nothing;

-- ---------------------------------------------------------
-- 2. Demo profiles / appointments / payments
-- Fill in the UUIDs from option A or B above, then run this block.
-- ---------------------------------------------------------
do $$
declare
  v_staff_id   uuid := '00000000-0000-0000-0000-000000000001'; -- replace
  v_rahul_id   uuid := '00000000-0000-0000-0000-000000000002'; -- replace
  v_priya_id   uuid := '00000000-0000-0000-0000-000000000003'; -- replace
  v_aman_id    uuid := '00000000-0000-0000-0000-000000000004'; -- replace
  v_neha_id    uuid := '00000000-0000-0000-0000-000000000005'; -- replace

  v_haircut_id   uuid;
  v_beard_id     uuid;
  v_spa_id       uuid;

  v_appt_rahul uuid;
  v_appt_priya uuid;
  v_appt_aman  uuid;
  v_appt_neha  uuid;
begin
  select id into v_haircut_id from public.services where name = 'Haircut' limit 1;
  select id into v_beard_id   from public.services where name = 'Beard Trim' limit 1;
  select id into v_spa_id     from public.services where name = 'Hair Spa' limit 1;

  -- Profiles (requires the auth.users rows to already exist —
  -- see instructions at the top of this file)
  insert into public.profiles (id, full_name, phone, role) values
    (v_staff_id, 'Demo Staff', '9990000001', 'staff'),
    (v_rahul_id, 'Rahul',      '9990000002', 'customer'),
    (v_priya_id, 'Priya',      '9990000003', 'customer'),
    (v_aman_id,  'Aman',       '9990000004', 'customer'),
    (v_neha_id,  'Neha',       '9990000005', 'customer')
  on conflict (id) do nothing;

  -- Demo queue for today:
  --   #1 Rahul — Haircut  — COMPLETED
  --   #2 Priya — Hair Spa — SERVING
  --   #3 Aman  — Haircut  — WAITING
  --   #4 Neha  — Beard Trim — WAITING
  insert into public.appointments
    (customer_id, service_id, appointment_date, appointment_time, status, queue_number)
  values
    (v_rahul_id, v_haircut_id, current_date, '10:00', 'COMPLETED', 1)
  returning id into v_appt_rahul;

  insert into public.appointments
    (customer_id, service_id, appointment_date, appointment_time, status, queue_number)
  values
    (v_priya_id, v_spa_id, current_date, '10:15', 'SERVING', 2)
  returning id into v_appt_priya;

  insert into public.appointments
    (customer_id, service_id, appointment_date, appointment_time, status, queue_number)
  values
    (v_aman_id, v_haircut_id, current_date, '11:00', 'WAITING', 3)
  returning id into v_appt_aman;

  insert into public.appointments
    (customer_id, service_id, appointment_date, appointment_time, status, queue_number)
  values
    (v_neha_id, v_beard_id, current_date, '11:15', 'WAITING', 4)
  returning id into v_appt_neha;

  -- A completed, paid payment for Rahul
  insert into public.payments (appointment_id, amount, payment_method, status)
  values (v_appt_rahul, 200.00, 'CASH', 'PAID');

  -- Matching activity feed entries
  insert into public.salon_activity (appointment_id, actor_id, activity_type, message) values
    (v_appt_rahul, v_rahul_id, 'APPOINTMENT_BOOKED',  'New appointment booked for Haircut'),
    (v_appt_rahul, v_staff_id, 'SERVICE_STARTED',      'Customer called for service'),
    (v_appt_rahul, v_staff_id, 'SERVICE_COMPLETED',    'Service completed'),
    (v_appt_rahul, v_staff_id, 'PAYMENT_RECEIVED',     'Payment of 200.00 received via CASH'),
    (v_appt_priya, v_priya_id, 'APPOINTMENT_BOOKED',  'New appointment booked for Hair Spa'),
    (v_appt_priya, v_staff_id, 'SERVICE_STARTED',      'Customer called for service'),
    (v_appt_aman,  v_aman_id,  'APPOINTMENT_BOOKED',  'New appointment booked for Haircut'),
    (v_appt_neha,  v_neha_id,  'APPOINTMENT_BOOKED',  'New appointment booked for Beard Trim');
end $$;

-- ---------------------------------------------------------
-- 3. Demo reset helper — wipes and re-seeds TODAY's queue only.
-- Handy to re-run between hackathon demo takes. Admin only.
-- ---------------------------------------------------------
create or replace function public.reset_demo_queue()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_role_name() <> 'admin' then
    raise exception 'Customer is not authorized: admin only';
  end if;

  delete from public.salon_activity
    using public.appointments a
    where salon_activity.appointment_id = a.id
      and a.appointment_date = current_date;

  delete from public.payments
    using public.appointments a
    where payments.appointment_id = a.id
      and a.appointment_date = current_date;

  delete from public.appointments where appointment_date = current_date;
end;
$$;

grant execute on function public.reset_demo_queue() to authenticated;

-- After calling reset_demo_queue(), just re-run section 2 above
-- (with the same UUIDs) to restore the demo queue.

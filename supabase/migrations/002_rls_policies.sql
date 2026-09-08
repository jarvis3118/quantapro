-- =========================================================
-- 002_rls_policies.sql
-- Trimora — Row Level Security
--
-- Design principle: RLS stays ON for every table. Regular users
-- (customer/staff) get SELECT policies only. All writes to
-- appointments / payments / salon_activity happen exclusively
-- through the SECURITY DEFINER RPCs in 003_queue_functions.sql,
-- which are owned by the table owner and therefore bypass RLS
-- internally while doing their own explicit authorization checks.
-- Since there are no INSERT/UPDATE/DELETE policies for
-- 'authenticated' on those tables, direct writes from the client
-- are denied by default — this is what makes "no direct status
-- changes / no direct payment writes" actually enforced.
-- =========================================================

alter table public.profiles       enable row level security;
alter table public.services       enable row level security;
alter table public.appointments   enable row level security;
alter table public.payments       enable row level security;
alter table public.salon_activity enable row level security;

-- ---------------------------------------------------------
-- profiles
-- ---------------------------------------------------------
drop policy if exists profiles_select_own   on public.profiles;
drop policy if exists profiles_select_staff on public.profiles;
drop policy if exists profiles_update_own   on public.profiles;
drop policy if exists profiles_admin_all    on public.profiles;

create policy profiles_select_own
  on public.profiles for select
  using (id = auth.uid());

create policy profiles_select_staff
  on public.profiles for select
  using (public.is_staff_or_admin());

create policy profiles_update_own
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());
  -- role escalation is separately blocked by trg_prevent_role_escalation

create policy profiles_admin_all
  on public.profiles for all
  using (public.current_role_name() = 'admin')
  with check (public.current_role_name() = 'admin');

-- Allow a new row to be created for a just-signed-up user (id = auth.uid()).
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self
  on public.profiles for insert
  with check (id = auth.uid());

-- ---------------------------------------------------------
-- services
-- ---------------------------------------------------------
drop policy if exists services_select_all    on public.services;
drop policy if exists services_admin_insert  on public.services;
drop policy if exists services_admin_update  on public.services;
drop policy if exists services_admin_delete  on public.services;

create policy services_select_all
  on public.services for select
  using (is_active = true or public.is_staff_or_admin());

create policy services_admin_insert
  on public.services for insert
  with check (public.current_role_name() = 'admin');

create policy services_admin_update
  on public.services for update
  using (public.current_role_name() = 'admin')
  with check (public.current_role_name() = 'admin');

create policy services_admin_delete
  on public.services for delete
  using (public.current_role_name() = 'admin');

-- ---------------------------------------------------------
-- appointments  (SELECT only — writes go through RPCs)
-- ---------------------------------------------------------
drop policy if exists appointments_select_own   on public.appointments;
drop policy if exists appointments_select_staff on public.appointments;

create policy appointments_select_own
  on public.appointments for select
  using (customer_id = auth.uid());

create policy appointments_select_staff
  on public.appointments for select
  using (public.is_staff_or_admin());

-- No insert/update/delete policy for 'authenticated' on purpose:
-- customers can only create/cancel via create_appointment() /
-- cancel_appointment(); staff can only transition state via the
-- queue RPCs. This is what stops "customers changing status directly".

-- ---------------------------------------------------------
-- payments (SELECT only — writes go through RPCs)
-- ---------------------------------------------------------
drop policy if exists payments_select_own   on public.payments;
drop policy if exists payments_select_staff on public.payments;

create policy payments_select_own
  on public.payments for select
  using (
    exists (
      select 1 from public.appointments a
      where a.id = payments.appointment_id
        and a.customer_id = auth.uid()
    )
  );

create policy payments_select_staff
  on public.payments for select
  using (public.is_staff_or_admin());

-- ---------------------------------------------------------
-- salon_activity (staff/admin read only — writes go through RPCs)
-- ---------------------------------------------------------
drop policy if exists salon_activity_select_staff on public.salon_activity;

create policy salon_activity_select_staff
  on public.salon_activity for select
  using (public.is_staff_or_admin());

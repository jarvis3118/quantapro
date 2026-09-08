-- =========================================================
-- 001_initial_schema.sql
-- Trimora — core tables, constraints, indexes
-- =========================================================

create extension if not exists "pgcrypto"; -- gen_random_uuid()

-- ---------------------------------------------------------
-- profiles
-- ---------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  phone       text,
  role        text not null default 'customer'
              check (role in ('customer','staff','admin')),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------
-- services
-- ---------------------------------------------------------
create table if not exists public.services (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  description       text,
  duration_minutes  integer not null check (duration_minutes > 0),
  price             numeric(10,2) not null check (price >= 0),
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------
-- appointments
-- ---------------------------------------------------------
create table if not exists public.appointments (
  id                      uuid primary key default gen_random_uuid(),
  customer_id             uuid not null references public.profiles(id),
  service_id              uuid not null references public.services(id),
  appointment_date        date not null,
  appointment_time        time not null,
  status                  text not null default 'BOOKED'
                          check (status in
                            ('BOOKED','WAITING','SERVING','COMPLETED','CANCELLED','NO_SHOW')),
  queue_number            integer,
  estimated_wait_minutes  integer default 0,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- A queue number must be unique per day (historical rows keep their number,
-- we never renumber — see 003_queue_functions.sql for position logic).
create unique index if not exists uq_appointments_date_queue
  on public.appointments (appointment_date, queue_number)
  where queue_number is not null;

-- MVP assumption: a single service station/stylist, so only one
-- appointment may be SERVING at any given time.
create unique index if not exists uq_one_serving_at_a_time
  on public.appointments ((true))
  where status = 'SERVING';

create index if not exists idx_appointments_date        on public.appointments (appointment_date);
create index if not exists idx_appointments_status       on public.appointments (status);
create index if not exists idx_appointments_queue_number on public.appointments (queue_number);
create index if not exists idx_appointments_customer_id  on public.appointments (customer_id);

-- ---------------------------------------------------------
-- payments
-- ---------------------------------------------------------
create table if not exists public.payments (
  id                      uuid primary key default gen_random_uuid(),
  appointment_id          uuid not null references public.appointments(id),
  amount                  numeric(10,2) not null check (amount >= 0),
  payment_method          text check (payment_method in ('CASH','UPI','CARD')),
  status                  text not null default 'PENDING'
                          check (status in ('PENDING','PAID','REFUNDED')),
  transaction_reference   text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create index if not exists idx_payments_appointment_id on public.payments (appointment_id);

-- ---------------------------------------------------------
-- salon_activity
-- ---------------------------------------------------------
create table if not exists public.salon_activity (
  id              uuid primary key default gen_random_uuid(),
  appointment_id  uuid references public.appointments(id),
  actor_id        uuid references public.profiles(id),
  activity_type   text not null,
  message         text not null,
  created_at      timestamptz not null default now()
);

create index if not exists idx_salon_activity_created_at on public.salon_activity (created_at);

-- ---------------------------------------------------------
-- updated_at trigger (reusable)
-- ---------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_appointments_updated_at on public.appointments;
create trigger trg_appointments_updated_at
  before update on public.appointments
  for each row execute function public.set_updated_at();

drop trigger if exists trg_payments_updated_at on public.payments;
create trigger trg_payments_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------
-- Role helper functions (used by RLS policies and RPCs)
-- ---------------------------------------------------------
create or replace function public.current_role_name()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_staff_or_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select role in ('staff','admin') from public.profiles where id = auth.uid()),
    false
  );
$$;

-- Prevent a non-admin from elevating their own role via direct table update.
create or replace function public.prevent_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role <> old.role
     and coalesce((select role from public.profiles where id = auth.uid()), '') <> 'admin' then
    raise exception 'Not authorized to change role';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_role_escalation on public.profiles;
create trigger trg_prevent_role_escalation
  before update on public.profiles
  for each row execute function public.prevent_role_escalation();

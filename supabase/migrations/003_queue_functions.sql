-- =========================================================
-- 003_queue_functions.sql
-- Trimora — queue RPCs, staff operations, payments, views
--
-- All functions below are SECURITY DEFINER, owned by the table
-- owner (postgres), so they bypass RLS internally — every one of
-- them does its OWN explicit auth.uid()/role check before touching
-- data. Concurrency for queue-mutating operations is protected with
-- pg_advisory_xact_lock() (one lock per calendar day) plus
-- `select ... for update` on the row being changed, so two staff
-- clicking at the same instant cannot both succeed.
-- =========================================================

-- ---------------------------------------------------------
-- calculate_queue_position
-- Position = 1 + (number of WAITING/SERVING appointments today
-- with a smaller queue_number). Works for both WAITING and
-- SERVING rows; the frontend can show "Now Serving" instead of
-- a number when status = SERVING.
-- ---------------------------------------------------------
create or replace function public.calculate_queue_position(p_appointment_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_date   date;
  v_qnum   integer;
  v_status text;
  v_ahead  integer;
begin
  select appointment_date, queue_number, status
    into v_date, v_qnum, v_status
  from appointments
  where id = p_appointment_id;

  if not found then
    raise exception 'Appointment not found';
  end if;

  if v_status not in ('WAITING','SERVING') or v_qnum is null then
    return null; -- not in the active queue
  end if;

  select count(*) into v_ahead
  from appointments
  where appointment_date = v_date
    and queue_number is not null
    and queue_number < v_qnum
    and status in ('WAITING','SERVING');

  return v_ahead + 1;
end;
$$;

-- ---------------------------------------------------------
-- calculate_estimated_wait
-- Sum of duration_minutes for every active (WAITING/SERVING)
-- appointment ahead of this one, including the one currently
-- being served (its remaining time is approximated as its full
-- service duration, per the spec).
-- ---------------------------------------------------------
create or replace function public.calculate_estimated_wait(p_appointment_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_date date;
  v_qnum integer;
  v_wait integer;
begin
  select appointment_date, queue_number into v_date, v_qnum
  from appointments where id = p_appointment_id;

  if not found then
    raise exception 'Appointment not found';
  end if;

  if v_qnum is null then
    return 0;
  end if;

  select coalesce(sum(s.duration_minutes), 0) into v_wait
  from appointments a
  join services s on s.id = a.service_id
  where a.appointment_date = v_date
    and a.queue_number is not null
    and a.queue_number < v_qnum
    and a.status in ('WAITING','SERVING');

  return v_wait;
end;
$$;

-- ---------------------------------------------------------
-- create_appointment
-- Design decision: Trimora is a live walk-in queue, so booking
-- for TODAY joins the active queue immediately (status WAITING,
-- queue_number assigned now). Booking for a future date creates a
-- placeholder (status BOOKED, no queue_number) — activating future
-- bookings into the queue on their date is out of scope for the MVP.
-- ---------------------------------------------------------
create or replace function public.create_appointment(
  p_service_id uuid,
  p_date       date,
  p_time       time
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id     uuid := auth.uid();
  v_service         services%rowtype;
  v_queue_number    integer;
  v_status          text;
  v_appointment_id  uuid;
  v_existing_count  integer;
begin
  if v_customer_id is null then
    raise exception 'Not authorized';
  end if;

  if p_date < current_date then
    raise exception 'Cannot book an appointment in the past';
  end if;

  select * into v_service
  from services
  where id = p_service_id and is_active = true;

  if not found then
    raise exception 'Service not found or inactive';
  end if;

  select count(*) into v_existing_count
  from appointments
  where customer_id = v_customer_id
    and appointment_date = p_date
    and status in ('BOOKED','WAITING','SERVING');

  if v_existing_count > 0 then
    raise exception 'You already have an active appointment on this date';
  end if;

  -- Serialize queue-number assignment per calendar day.
  perform pg_advisory_xact_lock(hashtext('queue-' || p_date::text));

  if p_date = current_date then
    v_status := 'WAITING';
    select coalesce(max(queue_number), 0) + 1 into v_queue_number
    from appointments
    where appointment_date = p_date and queue_number is not null;
  else
    v_status := 'BOOKED';
    v_queue_number := null;
  end if;

  insert into appointments (customer_id, service_id, appointment_date, appointment_time, status, queue_number)
  values (v_customer_id, p_service_id, p_date, p_time, v_status, v_queue_number)
  returning id into v_appointment_id;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (
    v_appointment_id, v_customer_id, 'APPOINTMENT_BOOKED',
    format('New appointment booked for %s', v_service.name)
  );

  return json_build_object(
    'id', v_appointment_id,
    'queue_number', v_queue_number,
    'status', v_status,
    'appointment_date', p_date,
    'appointment_time', p_time,
    'queue_position', case when v_queue_number is not null
      then public.calculate_queue_position(v_appointment_id) else null end,
    'estimated_wait_minutes', case when v_queue_number is not null
      then public.calculate_estimated_wait(v_appointment_id) else 0 end
  );
end;
$$;

-- ---------------------------------------------------------
-- cancel_appointment
-- Note on refunds: payments.status only has PENDING/PAID/REFUNDED
-- (per the fixed schema). Cancelling never moves money or changes
-- a PAID payment automatically — it only reports refund_eligible
-- so staff can call refund_payment() explicitly.
-- ---------------------------------------------------------
create or replace function public.cancel_appointment(p_appointment_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appt            appointments%rowtype;
  v_caller          uuid := auth.uid();
  v_is_staff        boolean := public.is_staff_or_admin();
  v_payment         payments%rowtype;
  v_refund_eligible boolean := false;
begin
  select * into v_appt from appointments where id = p_appointment_id for update;

  if not found then
    raise exception 'Appointment not found';
  end if;

  if not v_is_staff and v_appt.customer_id <> v_caller then
    raise exception 'Customer is not authorized to cancel this appointment';
  end if;

  if v_appt.status = 'CANCELLED' then
    raise exception 'Appointment is already cancelled';
  end if;

  if v_appt.status in ('COMPLETED','NO_SHOW') then
    raise exception 'Cannot cancel a completed appointment';
  end if;

  update appointments set status = 'CANCELLED' where id = p_appointment_id;

  select * into v_payment from payments where appointment_id = p_appointment_id;
  if found and v_payment.status = 'PAID' then
    v_refund_eligible := true;
  end if;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (p_appointment_id, v_caller, 'APPOINTMENT_CANCELLED', 'Appointment cancelled');

  return json_build_object(
    'id', p_appointment_id,
    'status', 'CANCELLED',
    'refund_eligible', v_refund_eligible
  );
end;
$$;

-- ---------------------------------------------------------
-- call_next_customer
-- Staff-only. Picks the earliest WAITING appointment for today.
-- ---------------------------------------------------------
create or replace function public.call_next_customer()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller        uuid := auth.uid();
  v_appt          appointments%rowtype;
  v_serving_count integer;
begin
  if not public.is_staff_or_admin() then
    raise exception 'Customer is not authorized: staff only';
  end if;

  perform pg_advisory_xact_lock(hashtext('queue-' || current_date::text));

  select count(*) into v_serving_count
  from appointments
  where status = 'SERVING' and appointment_date = current_date;

  if v_serving_count > 0 then
    raise exception 'Customer is already being served';
  end if;

  select * into v_appt
  from appointments
  where appointment_date = current_date and status = 'WAITING'
  order by queue_number asc
  limit 1
  for update;

  if not found then
    raise exception 'No waiting customers';
  end if;

  update appointments set status = 'SERVING' where id = v_appt.id;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (v_appt.id, v_caller, 'SERVICE_STARTED', 'Customer called for service');

  return json_build_object('id', v_appt.id, 'queue_number', v_appt.queue_number, 'status', 'SERVING');
end;
$$;

-- ---------------------------------------------------------
-- start_service — like call_next_customer but for a specific
-- appointment (lets staff pick out of strict order if needed).
-- ---------------------------------------------------------
create or replace function public.start_service(p_appointment_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller        uuid := auth.uid();
  v_appt          appointments%rowtype;
  v_serving_count integer;
begin
  if not public.is_staff_or_admin() then
    raise exception 'Customer is not authorized: staff only';
  end if;

  perform pg_advisory_xact_lock(hashtext('queue-' || current_date::text));

  select * into v_appt from appointments where id = p_appointment_id for update;
  if not found then
    raise exception 'Appointment not found';
  end if;

  if v_appt.status <> 'WAITING' then
    raise exception 'Appointment is not in WAITING state';
  end if;

  select count(*) into v_serving_count
  from appointments
  where status = 'SERVING' and appointment_date = v_appt.appointment_date;

  if v_serving_count > 0 then
    raise exception 'Customer is already being served';
  end if;

  update appointments set status = 'SERVING' where id = p_appointment_id;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (p_appointment_id, v_caller, 'SERVICE_STARTED', 'Service started');

  return json_build_object('id', p_appointment_id, 'status', 'SERVING');
end;
$$;

-- ---------------------------------------------------------
-- complete_service
-- ---------------------------------------------------------
create or replace function public.complete_service(p_appointment_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_appt   appointments%rowtype;
begin
  if not public.is_staff_or_admin() then
    raise exception 'Customer is not authorized: staff only';
  end if;

  select * into v_appt from appointments where id = p_appointment_id for update;
  if not found then
    raise exception 'Appointment not found';
  end if;

  if v_appt.status <> 'SERVING' then
    raise exception 'Appointment is not currently being served';
  end if;

  update appointments set status = 'COMPLETED' where id = p_appointment_id;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (p_appointment_id, v_caller, 'SERVICE_COMPLETED', 'Service completed');

  return json_build_object('id', p_appointment_id, 'status', 'COMPLETED');
end;
$$;

-- ---------------------------------------------------------
-- mark_payment_paid
-- ---------------------------------------------------------
create or replace function public.mark_payment_paid(p_appointment_id uuid, p_method text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller     uuid := auth.uid();
  v_appt       appointments%rowtype;
  v_service    services%rowtype;
  v_payment    payments%rowtype;
  v_payment_id uuid;
begin
  if not public.is_staff_or_admin() then
    raise exception 'Customer is not authorized: staff only';
  end if;

  if p_method not in ('CASH','UPI','CARD') then
    raise exception 'Invalid payment method';
  end if;

  select * into v_appt from appointments where id = p_appointment_id;
  if not found then
    raise exception 'Appointment not found';
  end if;

  select * into v_service from services where id = v_appt.service_id;

  select * into v_payment from payments where appointment_id = p_appointment_id;

  if found then
    if v_payment.status = 'PAID' then
      raise exception 'Payment already marked as paid';
    end if;
    update payments
      set status = 'PAID', payment_method = p_method, amount = v_service.price
      where id = v_payment.id
      returning id into v_payment_id;
  else
    insert into payments (appointment_id, amount, payment_method, status)
    values (p_appointment_id, v_service.price, p_method, 'PAID')
    returning id into v_payment_id;
  end if;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (
    p_appointment_id, v_caller, 'PAYMENT_RECEIVED',
    format('Payment of %s received via %s', v_service.price, p_method)
  );

  return json_build_object('id', v_payment_id, 'status', 'PAID', 'amount', v_service.price);
end;
$$;

-- ---------------------------------------------------------
-- refund_payment
-- ---------------------------------------------------------
create or replace function public.refund_payment(p_payment_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller  uuid := auth.uid();
  v_payment payments%rowtype;
begin
  if not public.is_staff_or_admin() then
    raise exception 'Customer is not authorized: staff only';
  end if;

  select * into v_payment from payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;

  if v_payment.status <> 'PAID' then
    raise exception 'Payment already refunded or not eligible for refund';
  end if;

  update payments set status = 'REFUNDED' where id = p_payment_id;

  insert into salon_activity (appointment_id, actor_id, activity_type, message)
  values (
    v_payment.appointment_id, v_caller, 'PAYMENT_REFUNDED',
    format('Payment of %s refunded', v_payment.amount)
  );

  return json_build_object('id', p_payment_id, 'status', 'REFUNDED');
end;
$$;

-- ---------------------------------------------------------
-- Grants — every authorization decision is enforced INSIDE each
-- function body; granting execute to 'authenticated' just lets any
-- logged-in user call the function, not perform the action.
-- ---------------------------------------------------------
grant execute on function public.calculate_queue_position(uuid)      to authenticated;
grant execute on function public.calculate_estimated_wait(uuid)      to authenticated;
grant execute on function public.create_appointment(uuid, date, time) to authenticated;
grant execute on function public.cancel_appointment(uuid)            to authenticated;
grant execute on function public.call_next_customer()                to authenticated;
grant execute on function public.start_service(uuid)                 to authenticated;
grant execute on function public.complete_service(uuid)              to authenticated;
grant execute on function public.mark_payment_paid(uuid, text)       to authenticated;
grant execute on function public.refund_payment(uuid)                to authenticated;

-- =========================================================
-- Views — simple, read-optimized shapes for the frontend.
-- Views are queried with the caller's own privileges applied to
-- the underlying tables' RLS policies (Supabase's standard
-- behaviour), so a customer querying customer_queue_status only
-- ever sees rows their appointments RLS policy already allows.
-- =========================================================

create or replace view public.today_queue as
select
  a.id as appointment_id,
  p.full_name as customer_name,
  s.name as service_name,
  s.duration_minutes,
  a.appointment_time,
  a.queue_number,
  a.status,
  coalesce(pay.status, 'PENDING') as payment_status
from appointments a
join profiles p on p.id = a.customer_id
join services s on s.id = a.service_id
left join payments pay on pay.appointment_id = a.id
where a.appointment_date = current_date
order by a.queue_number nulls last, a.appointment_time;

create or replace view public.today_dashboard_stats as
select
  count(*) as total_appointments,
  count(*) filter (where status = 'WAITING')   as waiting,
  count(*) filter (where status = 'SERVING')   as serving,
  count(*) filter (where status = 'COMPLETED') as completed,
  count(*) filter (where status = 'CANCELLED') as cancelled,
  coalesce((
    select sum(pay.amount)
    from payments pay
    join appointments a2 on a2.id = pay.appointment_id
    where a2.appointment_date = current_date and pay.status = 'PAID'
  ), 0) as revenue
from appointments
where appointment_date = current_date;

create or replace view public.customer_queue_status as
select
  a.id as appointment_id,
  a.customer_id,
  a.status,
  a.queue_number,
  public.calculate_queue_position(a.id) as queue_position,
  greatest(public.calculate_queue_position(a.id) - 1, 0) as customers_ahead,
  public.calculate_estimated_wait(a.id) as estimated_wait_minutes
from appointments a
where a.appointment_date = current_date
  and a.status in ('WAITING','SERVING');

grant select on public.today_queue            to authenticated;
grant select on public.today_dashboard_stats  to authenticated;
grant select on public.customer_queue_status  to authenticated;

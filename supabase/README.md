# Trimora — Supabase Backend

Real-time salon queue system built entirely on Supabase (Postgres + Auth +
Realtime + RLS). No custom Node/Express backend — all business logic lives
in SQL functions (RPCs), called directly from the React frontend via
`@supabase/supabase-js`.

## 1. Architecture

```
React + Vite (JS)
   │  @supabase/supabase-js
   ▼
Supabase Auth  ──────────────  who is logged in (customer/staff/admin)
Supabase Postgres
   ├── Tables: profiles, services, appointments, payments, salon_activity
   ├── RLS: SELECT policies only for customer/staff on the mutable tables
   ├── RPCs (SECURITY DEFINER): all writes + all state transitions
   └── Views: today_queue, today_dashboard_stats, customer_queue_status
Supabase Realtime ───────────  postgres_changes on appointments/payments/salon_activity
```

**Why no direct table writes from the client:** every table that has a
status machine (`appointments`, `payments`) or is an audit log
(`salon_activity`) has *no* INSERT/UPDATE/DELETE RLS policy for regular
users. The only way to change them is through a `SECURITY DEFINER`
function that is owned by the table owner (bypasses RLS) and does its own
explicit `auth.uid()` / role check first. This is what makes "customers
can't change appointment status directly" and "only staff can process
payments" actually true at the database level, not just in the UI.

### Contradictions in the brief, and how they were resolved

1. **"Queue numbers should be sequential" vs. "do not renumber historical
   records."** Resolved by treating `queue_number` as a permanent ticket
   number assigned once (like a token at a bakery counter), and computing
   the customer-facing **queue position** dynamically: `position = 1 +
   count of WAITING/SERVING appointments today with a smaller queue_number`.
   Cancelled/completed rows drop out of that count automatically without
   ever being renumbered.

2. **`BOOKED` vs `WAITING`, and what "enters the active queue" means.**
   The brief didn't say when a booking becomes a queue entry. Since this is
   a *live* queue system (not a calendar), the simplest correct behavior is:
   booking for **today** joins the queue immediately (`WAITING` +
   `queue_number` assigned). Booking for a **future date** creates a
   `BOOKED` placeholder with no queue number — activating a future booking
   on its date is out of scope for a 6-hour MVP and isn't needed for the
   demo.

3. **`call_next_customer()` vs. `start_service(appointment_id)`** overlap
   (both move WAITING → SERVING). Kept both because they serve different
   UI affordances — one big "Call Next" button vs. picking a specific
   customer out of the list — but they share the same validation (no
   double-serving, no calling an appointment that isn't `WAITING`).

4. **Refunds.** `payments.status` is fixed to `PENDING/PAID/REFUNDED` by
   the schema (no `REFUNDABLE` value). `cancel_appointment()` never touches
   the payment row automatically (per "do not integrate real payment
   processing"); instead it returns `refund_eligible: true` in its JSON
   response when a `PAID` payment exists, so the staff UI can prompt for
   `refund_payment()` explicitly.

5. **Single service station.** The brief describes one queue with one
   "currently serving" customer, so a partial unique index enforces at
   most one `SERVING` appointment system-wide at a time. If Trimora ever
   needs multiple simultaneous stylists, that index (and the "already
   serving" checks in the RPCs) is the one place to revisit.

## 2. File structure

```
supabase/
├── migrations/
│   ├── 001_initial_schema.sql   -- tables, indexes, updated_at trigger
│   ├── 002_rls_policies.sql     -- RLS (SELECT-only for regular users)
│   ├── 003_queue_functions.sql  -- all RPCs + dashboard views
│   ├── 004_realtime.sql         -- realtime publication + replica identity
│   └── 005_seed.sql             -- services + demo queue + reset helper
├── seed_auth_users.mjs          -- one-time script to create demo auth users
└── README.md
```

Run the migrations in numeric order (`supabase db push`, or paste each file
into the SQL editor in order). No Edge Functions are used — everything
needed fits in RLS + RPCs.

## 3. Authentication

Email/password via Supabase Auth, plus a `profiles` row per user holding
`role` (`customer` | `staff` | `admin`).

```js
// lib/supabase.js
import { createClient } from '@supabase/supabase-js'
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
```

**Sign up** (customer self-serve):
```js
const { data, error } = await supabase.auth.signUp({ email, password })
// then create their profile row (id must equal the new auth user's id)
await supabase.from('profiles').insert({
  id: data.user.id,
  full_name: fullName,
  phone,
  // role defaults to 'customer' — do not let the client set it to anything else
})
```

**Log in / log out:**
```js
await supabase.auth.signInWithPassword({ email, password })
await supabase.auth.signOut()
```

**Role retrieval** (after login, to decide which UI to show):
```js
const { data: { user } } = await supabase.auth.getUser()
const { data: profile } = await supabase
  .from('profiles')
  .select('role, full_name')
  .eq('id', user.id)
  .single()
// profile.role is 'customer' | 'staff' | 'admin'
```

**Creating a demo staff account safely:** do NOT let the signup form set
`role`. Create the staff/admin account normally through signup (or the
Supabase dashboard → Authentication → Add user), then have an existing
`admin` update that one row:
```sql
update public.profiles set role = 'staff' where id = '<their-uuid>';
```
This is safe because `profiles` RLS only lets an `admin` change someone
else's `role` (enforced by `trg_prevent_role_escalation` — a non-admin
updating their own `role` column is rejected even though they can update
their own row).

## 4. RPC contract (frontend integration guide)

All examples assume:
```js
import { supabase } from './lib/supabase'
```

---

### `create_appointment(p_service_id, p_date, p_time)`
**Who:** any authenticated customer.
**Returns:**
```json
{ "id": "...", "queue_number": 3, "status": "WAITING",
  "appointment_date": "2026-09-08", "appointment_time": "11:00",
  "queue_position": 2, "estimated_wait_minutes": 45 }
```
**Errors:** `Not authorized` · `Cannot book an appointment in the past` ·
`Service not found or inactive` · `You already have an active appointment on this date`
```js
const { data, error } = await supabase.rpc('create_appointment', {
  p_service_id: serviceId,
  p_date: '2026-09-08',
  p_time: '11:00',
})
```

---

### `cancel_appointment(p_appointment_id)`
**Who:** the owning customer, or staff/admin for any appointment.
**Returns:** `{ "id": "...", "status": "CANCELLED", "refund_eligible": true|false }`
**Errors:** `Appointment not found` · `Customer is not authorized to cancel this appointment` ·
`Appointment is already cancelled` · `Cannot cancel a completed appointment`
```js
const { data, error } = await supabase.rpc('cancel_appointment', {
  p_appointment_id: appointmentId,
})
```

---

### `call_next_customer()`
**Who:** staff/admin only.
**Returns:** `{ "id": "...", "queue_number": 3, "status": "SERVING" }`
**Errors:** `Customer is not authorized: staff only` · `Customer is already being served` ·
`No waiting customers`
```js
const { data, error } = await supabase.rpc('call_next_customer')
```

---

### `start_service(p_appointment_id)`
**Who:** staff/admin only. Starts a *specific* WAITING appointment.
**Returns:** `{ "id": "...", "status": "SERVING" }`
**Errors:** `Customer is not authorized: staff only` · `Appointment not found` ·
`Appointment is not in WAITING state` · `Customer is already being served`

---

### `complete_service(p_appointment_id)`
**Who:** staff/admin only.
**Returns:** `{ "id": "...", "status": "COMPLETED" }`
**Errors:** `Customer is not authorized: staff only` · `Appointment not found` ·
`Appointment is not currently being served`

---

### `mark_payment_paid(p_appointment_id, p_method)`
**Who:** staff/admin only. `p_method` ∈ `CASH | UPI | CARD`.
**Returns:** `{ "id": "...", "status": "PAID", "amount": 200.00 }`
**Errors:** `Customer is not authorized: staff only` · `Invalid payment method` ·
`Appointment not found` · `Payment already marked as paid`
```js
await supabase.rpc('mark_payment_paid', {
  p_appointment_id: appointmentId,
  p_method: 'UPI',
})
```

---

### `refund_payment(p_payment_id)`
**Who:** staff/admin only.
**Returns:** `{ "id": "...", "status": "REFUNDED" }`
**Errors:** `Customer is not authorized: staff only` · `Payment not found` ·
`Payment already refunded or not eligible for refund`

---

### `calculate_queue_position(p_appointment_id)` / `calculate_estimated_wait(p_appointment_id)`
**Who:** any authenticated user (RLS on `appointments` still restricts what
they can pass in meaningfully, since a customer can only usefully query
their own appointment id). Return a single integer. Prefer the
`customer_queue_status` view for the customer-facing UI instead of calling
these one-off.

---

### Views (query these directly with `.from()`, not `.rpc()`)

**`today_queue`** — staff dashboard row list. Columns: `appointment_id,
customer_name, service_name, duration_minutes, appointment_time,
queue_number, status, payment_status`.
```js
const { data } = await supabase.from('today_queue').select('*')
```

**`today_dashboard_stats`** — single row: `total_appointments, waiting,
serving, completed, cancelled, revenue`.

**`customer_queue_status`** — one row per active appointment (today,
WAITING/SERVING only): `appointment_id, customer_id, status, queue_number,
queue_position, customers_ahead, estimated_wait_minutes`. A customer's
query only returns their own row(s) thanks to the underlying `appointments`
RLS policy.
```js
const { data } = await supabase
  .from('customer_queue_status')
  .select('*')
  .eq('appointment_id', myAppointmentId)
  .maybeSingle()
```

## 5. Realtime — exact subscription pattern

Subscribe once per page/component, filter server-side where possible, and
**re-fetch the derived value** (queue position, dashboard stats) on every
change rather than trying to patch it manually — the position/wait
calculations depend on other rows, not just the one that changed.

**Customer: watch my own appointment for status/queue changes**
```js
useEffect(() => {
  const channel = supabase
    .channel(`appointment-${appointmentId}`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'appointments',
        filter: `id=eq.${appointmentId}`,
      },
      async () => {
        const { data } = await supabase
          .from('customer_queue_status')
          .select('*')
          .eq('appointment_id', appointmentId)
          .maybeSingle()
        setQueueStatus(data)
      }
    )
    .subscribe()

  return () => { supabase.removeChannel(channel) }
}, [appointmentId])
```

**Staff dashboard: watch all of today's appointments + payments + activity**
```js
useEffect(() => {
  const channel = supabase
    .channel('staff-dashboard')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'appointments' },
      () => refetchTodayQueueAndStats()
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'payments' },
      () => refetchTodayQueueAndStats()
    )
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'salon_activity' },
      (payload) => setActivityFeed((prev) => [payload.new, ...prev])
    )
    .subscribe()

  return () => { supabase.removeChannel(channel) }
}, [])
```

No page refresh is needed in either case: an RPC call updates the row(s),
Postgres emits the change over the realtime publication (enabled in
`004_realtime.sql`), the subscribed client re-runs its query, and React
re-renders.

## 6. Testing instructions

Run these against a freshly migrated + seeded database (use two browser
sessions/users — one customer, one staff — to see realtime updates live).

1. **Customer creates appointment** — call `create_appointment` as a
   logged-in customer for today. Confirm it returns `status: "WAITING"`
   and a `queue_number`.
2. **Appointment appears in queue** — `select * from today_queue` (as
   staff) shows the new row; the staff dashboard updates in realtime
   without refresh.
3. **Staff calls next customer** — call `call_next_customer()` as staff.
4. **Customer status becomes SERVING** — the customer's
   `customer_queue_status` subscription fires and shows `status:
   "SERVING"`.
5. **Staff completes service** — call `complete_service(id)` for the
   `SERVING` appointment.
6. **Next customer can be called** — `call_next_customer()` succeeds again
   (no "already being served" error) and picks the next-lowest
   `queue_number`.
7. **Queue position updates** — a customer further back in line sees
   `queue_position` decrease by 1 in their realtime subscription after
   step 5.
8. **Cancellation works** — a `WAITING` customer calls
   `cancel_appointment(id)` on their own appointment; `today_queue` drops
   it and everyone behind them shifts up one position.
9. **Payment can be marked PAID** — staff calls
   `mark_payment_paid(appointment_id, 'CASH')`; `today_dashboard_stats.revenue`
   increases.
10. **Payment can be REFUNDED** — staff calls `refund_payment(payment_id)`;
    confirm calling it again raises `Payment already refunded or not
    eligible for refund`.
11. **Unauthorized customer cannot modify another customer** — log in as
    customer A, call `cancel_appointment(<customer B's appointment id>)`;
    confirm it raises `Customer is not authorized to cancel this
    appointment`. Also confirm a raw `update appointments set status =
    'SERVING' ...` from any non-owner client is rejected by RLS (no
    matching policy).
12. **Two simultaneous queue operations cannot corrupt queue state** —
    from two separate sessions, call `call_next_customer()` at nearly the
    same time. Exactly one should succeed with the next `WAITING`
    appointment; the other should either get `Customer is already being
    served` or (if it raced before the first commit) block briefly on the
    advisory lock and then see the updated state. Confirm no two rows are
    ever `SERVING` at once (the partial unique index guarantees this even
    under a bug elsewhere).

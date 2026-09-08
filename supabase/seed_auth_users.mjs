// supabase/seed_auth_users.mjs
//
// One-time helper: creates the demo auth users needed by
// migrations/005_seed.sql and prints their UUIDs so you can paste
// them into that file's `do $$ declare ... $$` block.
//
// Run with: node supabase/seed_auth_users.mjs
// Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY env vars
// (service role key — never expose this in the frontend).

import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

const demoUsers = [
  { email: 'staff1@trimora.demo', password: 'DemoPass123!', label: 'staff' },
  { email: 'rahul@trimora.demo',  password: 'DemoPass123!', label: 'rahul' },
  { email: 'priya@trimora.demo',  password: 'DemoPass123!', label: 'priya' },
  { email: 'aman@trimora.demo',   password: 'DemoPass123!', label: 'aman' },
  { email: 'neha@trimora.demo',   password: 'DemoPass123!', label: 'neha' },
]

for (const u of demoUsers) {
  const { data, error } = await supabase.auth.admin.createUser({
    email: u.email,
    password: u.password,
    email_confirm: true,
  })

  if (error) {
    console.error(`Failed to create ${u.label}:`, error.message)
    continue
  }

  console.log(`${u.label.padEnd(8)} ${data.user.email.padEnd(28)} ${data.user.id}`)
}

console.log('\nPaste these UUIDs into supabase/migrations/005_seed.sql, then run:')
console.log('  supabase db push   (or run 005_seed.sql directly in the SQL editor)')
console.log('\nAfter running the seed, also insert a `staff` role for staff1 in the')
console.log('profiles table if the seed block did not already set it.')

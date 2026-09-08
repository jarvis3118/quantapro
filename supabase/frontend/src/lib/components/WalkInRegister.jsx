import { useState } from 'react';
import { supabase } from '../lib/supabaseClient.js';

export default function WalkInRegister({ onRegistered }) {
  const [form, setForm] = useState({ name: '', phone: '', service_name: '' });
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setSuccess('');

    if (!form.name || !form.phone || !form.service_name) {
      setError('All fields are required');
      return;
    }

    // Create (or find existing) customer
    const { data: customer, error: custErr } = await supabase
      .from('customers')
      .insert({ name: form.name, phone: form.phone })
      .select()
      .single();

    if (custErr) return setError(custErr.message);

    // Same booking RPC used by the online form — walk-ins join the same queue
    const { data: appt, error: apptErr } = await supabase.rpc('book_appointment', {
      p_customer_id: customer.id,
      p_service_name: form.service_name
    });

    if (apptErr) return setError(apptErr.message);

    setSuccess(`Registered! Queue position: ${appt.position}`);
    setForm({ name: '', phone: '', service_name: '' });
    if (onRegistered) onRegistered(appt);
  };

  return (
    <div style={{ maxWidth: 400, marginBottom: '1.5rem' }}>
      <h3>Walk-in registration</h3>
      <form onSubmit={handleSubmit}>
        <input placeholder="Customer name" value={form.name}
          onChange={e => setForm({ ...form, name: e.target.value })} /><br />
        <input placeholder="Phone" value={form.phone}
          onChange={e => setForm({ ...form, phone: e.target.value })} /><br />
        <input placeholder="Service" value={form.service_name}
          onChange={e => setForm({ ...form, service_name: e.target.value })} /><br />
        <button type="submit">Add to queue</button>
      </form>
      {error && <p style={{ color: 'red' }}>{error}</p>}
      {success && <p style={{ color: 'green' }}>{success}</p>}
    </div>
  );
}

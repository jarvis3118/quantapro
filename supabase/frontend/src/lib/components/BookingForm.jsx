import { useState } from 'react';
import { supabase } from '../lib/supabaseClient.js';

export default function BookingForm({ onBooked }) {
  const [form, setForm] = useState({ name: '', phone: '', email: '', service_name: '' });
  const [error, setError] = useState('');

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');

    const { data: customer, error: custErr } = await supabase
      .from('customers')
      .insert({ name: form.name, phone: form.phone, email: form.email })
      .select()
      .single();

    if (custErr) return setError(custErr.message);

    
    const { data: appt, error: apptErr } = await supabase.rpc('book_appointment', {
      p_customer_id: customer.id,
      p_service_name: form.service_name
    });

    if (apptErr) return setError(apptErr.message);

    onBooked(appt.appointment_id);
  };

  return (
    <form onSubmit={handleSubmit} style={{ maxWidth: 400 }}>
      <input placeholder="Name" required
        onChange={e => setForm({ ...form, name: e.target.value })} /><br />
      <input placeholder="Phone" required
        onChange={e => setForm({ ...form, phone: e.target.value })} /><br />
      <input placeholder="Email"
        onChange={e => setForm({ ...form, email: e.target.value })} /><br />
      <input placeholder="Service" required
        onChange={e => setForm({ ...form, service_name: e.target.value })} /><br />
      <button type="submit">Book Appointment</button>
      {error && <p style={{ color: 'red' }}>{error}</p>}
    </form>
  );
}

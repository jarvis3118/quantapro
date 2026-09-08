import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient.js';

export default function StaffDashboard() {
  const [queue, setQueue] = useState([]);

  const fetchQueue = async () => {
    const { data } = await supabase
      .from('queue')
      .select('*, appointments(service_name, status, customers(name))')
      .order('position', { ascending: true });
    setQueue(data || []);
  };

  useEffect(() => {
    fetchQueue();
    const channel = supabase
      .channel('staff-queue')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' },
        () => fetchQueue()
      )
      .subscribe();
    return () => supabase.removeChannel(channel);
  }, []);

  const nextCustomer = async () => {
    await supabase.rpc('move_to_next_customer'); // adjust name to your RPC
  };

  const updateStatus = async (appointmentId, status) => {
    await supabase.from('appointments').update({ status }).eq('id', appointmentId);
  };

  return (
    <div>
      <h2>Staff Dashboard</h2>
      <button onClick={nextCustomer}>Move to Next Customer</button>
      <table border="1" cellPadding="8">
        <thead>
          <tr><th>Position</th><th>Customer</th><th>Service</th><th>Status</th><th>Actions</th></tr>
        </thead>
        <tbody>
          {queue.map(q => (
            <tr key={q.id}>
              <td>{q.position}</td>
              <td>{q.appointments?.customers?.name}</td>
              <td>{q.appointments?.service_name}</td>
              <td>{q.appointments?.status}</td>
              <td>
                <button onClick={() => updateStatus(q.appointment_id, 'in-progress')}>Start</button>
                <button onClick={() => updateStatus(q.appointment_id, 'completed')}>Complete</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

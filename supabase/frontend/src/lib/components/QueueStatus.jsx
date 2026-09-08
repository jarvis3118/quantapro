import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient.js';

export default function QueueStatus({ appointmentId }) {
  const [queueInfo, setQueueInfo] = useState(null);

  const fetchPosition = async () => {
    const { data } = await supabase
      .from('queue')
      .select('position, estimated_wait_minutes')
      .eq('appointment_id', appointmentId)
      .single();
    setQueueInfo(data);
  };

  useEffect(() => {
    fetchPosition();

   
    const channel = supabase
      .channel('queue-changes')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' },
        () => fetchPosition()
      )
      .subscribe();

    return () => supabase.removeChannel(channel);
  }, [appointmentId]);

  if (!queueInfo) return <p>Loading queue status...</p>;

  return (
    <div>
      <p>Your position: <b>{queueInfo.position}</b></p>
      <p>Estimated wait: <b>{queueInfo.estimated_wait_minutes} mins</b></p>
    </div>
  );
}

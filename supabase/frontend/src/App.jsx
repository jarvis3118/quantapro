import { useState } from 'react';
import BookingForm from './lib/components/BookingForm.jsx';
import QueueStatus from './lib/components/QueueStatus.jsx';
import StaffLogin from './lib/components/StaffLogin.jsx';
import StaffDashboard from './lib/components/StaffDashboard.jsx';

export default function App() {
  const [appointmentId, setAppointmentId] = useState(null);
  const [staff, setStaff] = useState(null);
  const [view, setView] = useState('customer'); // 'customer' | 'staff'

  return (
    <div style={{ fontFamily: 'sans-serif', padding: '1rem' }}>
      <nav style={{ marginBottom: '1rem' }}>
        <button onClick={() => setView('customer')}>Customer</button>
        <button onClick={() => setView('staff')}>Staff</button>
      </nav>

      {view === 'customer' && !appointmentId && (
        <BookingForm onBooked={(id) => setAppointmentId(id)} />
      )}
      {view === 'customer' && appointmentId && (
        <QueueStatus appointmentId={appointmentId} />
      )}

      {view === 'staff' && !staff && (
        <StaffLogin onLogin={(s) => setStaff(s)} />
      )}
      {view === 'staff' && staff && <StaffDashboard />}
    </div>
  );
}

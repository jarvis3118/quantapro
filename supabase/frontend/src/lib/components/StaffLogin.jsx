import { useState } from 'react';
import { supabase } from '../lib/supabaseClient.js';

export default function StaffLogin({ onLogin }) {
  const [creds, setCreds] = useState({ email: '', password: '' });
  const [error, setError] = useState('');

  const handleLogin = async (e) => {
    e.preventDefault();
    const { data, error } = await supabase.auth.signInWithPassword(creds);
    if (error) return setError(error.message);
    onLogin(data.user);
  };

  return (
    <form onSubmit={handleLogin} style={{ maxWidth: 300 }}>
      <input placeholder="Email" required
        onChange={e => setCreds({ ...creds, email: e.target.value })} /><br />
      <input type="password" placeholder="Password" required
        onChange={e => setCreds({ ...creds, password: e.target.value })} /><br />
      <button type="submit">Login</button>
      {error && <p style={{ color: 'red' }}>{error}</p>}
    </form>
  );
}

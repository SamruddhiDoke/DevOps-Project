import React, { useState, useEffect } from 'react';
import { healthApi } from '../services/api';

export default function Header({ title, subtitle }) {
  const [healthStatus, setHealthStatus] = useState('checking'); // 'up', 'down', 'checking'

  useEffect(() => {
    let isMounted = true;

    const checkHealth = async () => {
      try {
        const res = await healthApi.getHealth();
        if (isMounted) {
          if (res && res.status === 'UP') {
            setHealthStatus('up');
          } else {
            setHealthStatus('down');
          }
        }
      } catch (err) {
        if (isMounted) {
          setHealthStatus('down');
        }
      }
    };

    checkHealth();
    const interval = setInterval(checkHealth, 15000); // poll every 15s

    return () => {
      isMounted = false;
      clearInterval(interval);
    };
  }, []);

  return (
    <header className="top-header">
      <div className="header-title-area">
        <h1>{title}</h1>
        {subtitle && <p>{subtitle}</p>}
      </div>

      <div className="header-actions">
        <div className={`health-badge ${healthStatus}`}>
          <span className="health-dot"></span>
          <span>
            API {healthStatus === 'up' ? 'Online' : healthStatus === 'down' ? 'Offline' : 'Connecting...'}
          </span>
        </div>

        <div className="user-profile-badge">
          <div className="avatar">AD</div>
          <div style={{ display: 'flex', flexDirection: 'column' }}>
            <span style={{ fontSize: '0.85rem', fontWeight: 600, color: 'var(--slate-800)' }}>Administrator</span>
            <span style={{ fontSize: '0.75rem', color: 'var(--slate-500)' }}>admin@corestore.internal</span>
          </div>
        </div>
      </div>
    </header>
  );
}

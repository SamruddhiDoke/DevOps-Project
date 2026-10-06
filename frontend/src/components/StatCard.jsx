import React from 'react';

export default function StatCard({ title, value, icon, accentColor = 'var(--primary-600)', iconBg = 'var(--primary-50)', iconColor = 'var(--primary-600)', subtitle }) {
  return (
    <div className="card stat-card" style={{ '--accent-color': accentColor, '--icon-bg': iconBg, '--icon-color': iconColor }}>
      <div>
        <div className="stat-label">{title}</div>
        <div className="stat-value">{value}</div>
        {subtitle && <div style={{ fontSize: '0.8rem', color: 'var(--slate-500)', marginTop: '0.35rem' }}>{subtitle}</div>}
      </div>
      <div className="stat-icon-wrapper">
        {icon}
      </div>
    </div>
  );
}

import React from 'react';
import { IconCheck, IconAlert, IconClose } from './Icons';

export default function Toast({ toasts, onDismiss }) {
  if (!toasts || toasts.length === 0) return null;

  return (
    <div className="toast-container">
      {toasts.map((toast) => (
        <div key={toast.id} className={`toast toast-${toast.type || 'info'}`}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            {toast.type === 'success' && <span style={{ color: 'var(--success-600)' }}><IconCheck size={20} /></span>}
            {toast.type === 'error' && <span style={{ color: 'var(--danger-600)' }}><IconAlert size={20} /></span>}
            {toast.type === 'warning' && <span style={{ color: 'var(--warning-600)' }}><IconAlert size={20} /></span>}
            <span style={{ fontSize: '0.875rem', fontWeight: 500, color: 'var(--slate-800)' }}>
              {toast.message}
            </span>
          </div>
          <button 
            className="btn-icon-only" 
            onClick={() => onDismiss(toast.id)}
            style={{ padding: '2px', marginLeft: '0.5rem' }}
          >
            <IconClose size={16} />
          </button>
        </div>
      ))}
    </div>
  );
}

import React from 'react';
import Modal from './Modal';
import { IconAlert } from './Icons';

export default function ConfirmDialog({ isOpen, onClose, onConfirm, title, message, confirmText = 'Delete', isDanger = true }) {
  return (
    <Modal isOpen={isOpen} onClose={onClose} title={title} maxWidth="460px">
      <div className="modal-body" style={{ display: 'flex', gap: '1rem', alignItems: 'flex-start' }}>
        <div style={{
          width: '42px',
          height: '42px',
          borderRadius: '50%',
          backgroundColor: isDanger ? 'var(--danger-50)' : 'var(--warning-50)',
          color: isDanger ? 'var(--danger-600)' : 'var(--warning-600)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          flexShrink: 0
        }}>
          <IconAlert size={22} />
        </div>
        <div>
          <p style={{ fontSize: '0.925rem', color: 'var(--slate-700)', lineHeight: '1.5' }}>
            {message}
          </p>
        </div>
      </div>
      <div className="modal-footer">
        <button type="button" className="btn btn-secondary" onClick={onClose}>
          Cancel
        </button>
        <button 
          type="button" 
          className={`btn ${isDanger ? 'btn-danger' : 'btn-primary'}`} 
          onClick={onConfirm}
        >
          {confirmText}
        </button>
      </div>
    </Modal>
  );
}

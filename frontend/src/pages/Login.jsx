import React from 'react';
import { useNavigate } from 'react-router-dom';
import { IconBox } from '../components/Icons';

export default function Login() {
  const navigate = useNavigate();

  const handleEnter = (e) => {
    e.preventDefault();
    navigate('/dashboard');
  };

  return (
    <div className="login-page">
      <div className="login-card">
        <div className="login-brand-logo">
          <IconBox size={32} />
        </div>
        
        <h2 style={{ fontSize: '1.6rem', fontWeight: 700, color: 'var(--slate-900)', marginBottom: '0.5rem' }}>
          CoreStore Platform
        </h2>
        <p style={{ fontSize: '0.9rem', color: 'var(--slate-500)', marginBottom: '2rem' }}>
          Internal Order & Inventory Management System
        </p>

        <form onSubmit={handleEnter} style={{ textAlign: 'left' }}>
          <div className="form-group">
            <label className="form-label">Operator Email / Username</label>
            <input 
              type="text" 
              className="form-control" 
              defaultValue="admin@corestore.internal"
              placeholder="e.g. admin@corestore.internal"
              readOnly
            />
          </div>

          <div className="form-group" style={{ marginBottom: '1.75rem' }}>
            <label className="form-label">Access Role</label>
            <input 
              type="text" 
              className="form-control" 
              defaultValue="Enterprise DevOps Administrator" 
              readOnly 
            />
          </div>

          <button type="submit" className="btn btn-primary" style={{ width: '100%', padding: '0.8rem', fontSize: '1rem' }}>
            Continue to Dashboard &rarr;
          </button>
        </form>

        <div style={{ marginTop: '2rem', paddingTop: '1.5rem', borderTop: '1px solid var(--slate-100)', fontSize: '0.8rem', color: 'var(--slate-400)' }}>
          DevOps Phase 1 Base Application &bull; Ready for CI/CD, Containers & Cloud
        </div>
      </div>
    </div>
  );
}

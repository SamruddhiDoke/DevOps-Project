import React, { useState, useEffect } from 'react';
import Header from '../components/Header';
import Modal from '../components/Modal';
import Toast from '../components/Toast';
import { IconPlus, IconEye, IconSearch, IconRefresh, IconUsers } from '../components/Icons';
import { usersApi } from '../services/api';

export default function Users() {
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');

  // Modals
  const [isAddModalOpen, setIsAddModalOpen] = useState(false);
  const [selectedUser, setSelectedUser] = useState(null);

  // Form State
  const [formData, setFormData] = useState({ name: '', email: '', phone: '' });
  const [formErrors, setFormErrors] = useState({});
  const [submitting, setSubmitting] = useState(false);

  // Toast Notifications
  const [toasts, setToasts] = useState([]);

  const addToast = (message, type = 'info') => {
    const id = Date.now();
    setToasts((prev) => [...prev, { id, message, type }]);
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 4000);
  };

  const removeToast = (id) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  };

  const fetchUsers = async () => {
    setLoading(true);
    try {
      const data = await usersApi.getAll();
      setUsers(data || []);
    } catch (err) {
      addToast(err.message || 'Failed to load users', 'error');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchUsers();
  }, []);

  const handleOpenAddModal = () => {
    setFormData({ name: '', email: '', phone: '' });
    setFormErrors({});
    setIsAddModalOpen(true);
  };

  const validateForm = () => {
    const errors = {};
    if (!formData.name.trim()) errors.name = 'Full name is required';
    if (!formData.email.trim()) {
      errors.email = 'Email is required';
    } else if (!/\S+@\S+\.\S+/.test(formData.email)) {
      errors.email = 'Please provide a valid email address';
    }
    setFormErrors(errors);
    return Object.keys(errors).length === 0;
  };

  const handleCreateUser = async (e) => {
    e.preventDefault();
    if (!validateForm()) return;

    setSubmitting(true);
    try {
      const payload = {
        name: formData.name.trim(),
        email: formData.email.trim().toLowerCase(),
        phone: formData.phone.trim() || null,
      };

      await usersApi.create(payload);
      addToast('User created successfully', 'success');
      setIsAddModalOpen(false);
      fetchUsers();
    } catch (err) {
      addToast(err.message || 'Failed to create user', 'error');
    } finally {
      setSubmitting(false);
    }
  };

  const filteredUsers = users.filter((user) => {
    return (
      user.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      user.email.toLowerCase().includes(searchTerm.toLowerCase()) ||
      (user.phone && user.phone.toLowerCase().includes(searchTerm.toLowerCase())) ||
      user.id.toString().includes(searchTerm)
    );
  });

  return (
    <>
      <Header 
        title="User Directory" 
        subtitle="Manage registered customers and enterprise accounts" 
      />

      <div className="page-wrapper">
        <Toast toasts={toasts} onDismiss={removeToast} />

        <div className="table-container">
          <div className="table-toolbar">
            <div className="search-input-wrapper">
              <IconSearch className="search-icon" size={16} />
              <input 
                type="text" 
                className="search-input" 
                placeholder="Search by name, email, or ID..." 
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
              />
            </div>

            <div style={{ display: 'flex', gap: '0.75rem' }}>
              <button className="btn btn-secondary" onClick={fetchUsers} disabled={loading}>
                <IconRefresh size={16} className={loading ? 'spinner' : ''} />
                Refresh
              </button>
              <button className="btn btn-primary" onClick={handleOpenAddModal}>
                <IconPlus size={18} />
                Add User
              </button>
            </div>
          </div>

          {loading ? (
            <div className="loading-spinner-wrapper">
              <div className="spinner"></div>
              <span style={{ fontSize: '0.85rem', color: 'var(--slate-500)' }}>Loading users...</span>
            </div>
          ) : filteredUsers.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-icon">
                <IconUsers size={28} />
              </div>
              <div className="empty-state-title">No users found</div>
              <p className="empty-state-desc">
                {searchTerm ? 'No user records match your search filter.' : 'Click "Add User" to register the first customer.'}
              </p>
            </div>
          ) : (
            <div style={{ overflowX: 'auto' }}>
              <table className="app-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Name</th>
                    <th>Email</th>
                    <th>Phone</th>
                    <th>Created Date</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredUsers.map((user) => (
                    <tr key={user.id}>
                      <td style={{ fontWeight: 600 }}>#{user.id}</td>
                      <td>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
                          <div style={{
                            width: '32px',
                            height: '32px',
                            borderRadius: '50%',
                            backgroundColor: 'var(--primary-100)',
                            color: 'var(--primary-700)',
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            fontWeight: 600,
                            fontSize: '0.8rem'
                          }}>
                            {user.name.charAt(0).toUpperCase()}
                          </div>
                          <span style={{ fontWeight: 600, color: 'var(--slate-900)' }}>{user.name}</span>
                        </div>
                      </td>
                      <td>{user.email}</td>
                      <td>{user.phone || <span style={{ color: 'var(--slate-400)' }}>—</span>}</td>
                      <td style={{ fontSize: '0.825rem', color: 'var(--slate-600)' }}>
                        {user.createdAt
                          ? new Date(user.createdAt).toLocaleDateString(undefined, {
                              year: 'numeric',
                              month: 'short',
                              day: 'numeric'
                            })
                          : '—'}
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        <button 
                          className="btn btn-secondary btn-sm"
                          onClick={() => setSelectedUser(user)}
                        >
                          <IconEye size={14} /> Details
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {/* Add User Modal */}
      <Modal 
        isOpen={isAddModalOpen} 
        onClose={() => !submitting && setIsAddModalOpen(false)} 
        title="Add New User"
      >
        <form onSubmit={handleCreateUser}>
          <div className="modal-body">
            <div className="form-group">
              <label className="form-label">Full Name *</label>
              <input 
                type="text" 
                className={`form-control ${formErrors.name ? 'is-invalid' : ''}`}
                placeholder="e.g. Jane Smith"
                value={formData.name}
                onChange={(e) => setFormData({ ...formData, name: e.target.value })}
              />
              {formErrors.name && <div className="form-error-text">{formErrors.name}</div>}
            </div>

            <div className="form-group">
              <label className="form-label">Email Address *</label>
              <input 
                type="email" 
                className={`form-control ${formErrors.email ? 'is-invalid' : ''}`}
                placeholder="e.g. jane.smith@example.com"
                value={formData.email}
                onChange={(e) => setFormData({ ...formData, email: e.target.value })}
              />
              {formErrors.email && <div className="form-error-text">{formErrors.email}</div>}
            </div>

            <div className="form-group" style={{ marginBottom: 0 }}>
              <label className="form-label">Phone Number</label>
              <input 
                type="text" 
                className="form-control"
                placeholder="e.g. +1-555-0199"
                value={formData.phone}
                onChange={(e) => setFormData({ ...formData, phone: e.target.value })}
              />
            </div>
          </div>

          <div className="modal-footer">
            <button 
              type="button" 
              className="btn btn-secondary" 
              onClick={() => setIsAddModalOpen(false)}
              disabled={submitting}
            >
              Cancel
            </button>
            <button 
              type="submit" 
              className="btn btn-primary"
              disabled={submitting}
            >
              {submitting ? 'Creating...' : 'Create User'}
            </button>
          </div>
        </form>
      </Modal>

      {/* View User Details Modal */}
      {selectedUser && (
        <Modal 
          isOpen={!!selectedUser} 
          onClose={() => setSelectedUser(null)} 
          title="User Account Details"
          maxWidth="480px"
        >
          <div className="modal-body">
            <div style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '1.5rem', paddingBottom: '1rem', borderBottom: '1px solid var(--slate-100)' }}>
              <div style={{
                width: '52px',
                height: '52px',
                borderRadius: '50%',
                backgroundColor: 'var(--primary-600)',
                color: '#ffffff',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontWeight: 700,
                fontSize: '1.35rem'
              }}>
                {selectedUser.name.charAt(0).toUpperCase()}
              </div>
              <div>
                <h3 style={{ fontSize: '1.15rem', fontWeight: 700, color: 'var(--slate-900)' }}>{selectedUser.name}</h3>
                <span style={{ fontSize: '0.85rem', color: 'var(--slate-500)' }}>User ID: #{selectedUser.id}</span>
              </div>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
              <div>
                <span style={{ fontSize: '0.75rem', textTransform: 'uppercase', color: 'var(--slate-400)', fontWeight: 600 }}>Email Address</span>
                <div style={{ fontWeight: 500, color: 'var(--slate-800)', marginTop: '0.2rem' }}>{selectedUser.email}</div>
              </div>

              <div>
                <span style={{ fontSize: '0.75rem', textTransform: 'uppercase', color: 'var(--slate-400)', fontWeight: 600 }}>Phone Number</span>
                <div style={{ fontWeight: 500, color: 'var(--slate-800)', marginTop: '0.2rem' }}>{selectedUser.phone || 'Not provided'}</div>
              </div>

              <div>
                <span style={{ fontSize: '0.75rem', textTransform: 'uppercase', color: 'var(--slate-400)', fontWeight: 600 }}>Registration Timestamp</span>
                <div style={{ fontWeight: 500, color: 'var(--slate-800)', marginTop: '0.2rem' }}>
                  {selectedUser.createdAt ? new Date(selectedUser.createdAt).toLocaleString() : 'N/A'}
                </div>
              </div>
            </div>
          </div>
          <div className="modal-footer">
            <button className="btn btn-secondary" onClick={() => setSelectedUser(null)}>
              Close
            </button>
          </div>
        </Modal>
      )}
    </>
  );
}

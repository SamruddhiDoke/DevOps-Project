import React, { useState, useEffect } from 'react';
import Header from '../components/Header';
import StatusBadge from '../components/StatusBadge';
import Modal from '../components/Modal';
import ConfirmDialog from '../components/ConfirmDialog';
import Toast from '../components/Toast';
import { IconPlus, IconEdit, IconTrash, IconSearch, IconRefresh, IconProducts } from '../components/Icons';
import { productsApi } from '../services/api';

export default function Products() {
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('ALL');

  // Modal State
  const [isFormModalOpen, setIsFormModalOpen] = useState(false);
  const [isEditing, setIsEditing] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [formData, setFormData] = useState({
    name: '',
    description: '',
    price: '',
    stockQuantity: '',
    category: '',
  });
  const [formErrors, setFormErrors] = useState({});
  const [submitting, setSubmitting] = useState(false);

  // Delete Confirmation State
  const [deleteTarget, setDeleteTarget] = useState(null);

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

  const fetchProducts = async () => {
    setLoading(true);
    try {
      const data = await productsApi.getAll();
      setProducts(data || []);
    } catch (err) {
      addToast(err.message || 'Failed to load products', 'error');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchProducts();
  }, []);

  const handleOpenAddModal = () => {
    setIsEditing(false);
    setEditingId(null);
    setFormData({
      name: '',
      description: '',
      price: '',
      stockQuantity: '',
      category: '',
    });
    setFormErrors({});
    setIsFormModalOpen(true);
  };

  const handleOpenEditModal = (product) => {
    setIsEditing(true);
    setEditingId(product.id);
    setFormData({
      name: product.name,
      description: product.description || '',
      price: product.price,
      stockQuantity: product.stockQuantity,
      category: product.category || '',
    });
    setFormErrors({});
    setIsFormModalOpen(true);
  };

  const validateForm = () => {
    const errors = {};
    if (!formData.name.trim()) errors.name = 'Product name is required';
    if (!formData.price || Number(formData.price) <= 0) errors.price = 'Valid price greater than 0 is required';
    if (formData.stockQuantity === '' || Number(formData.stockQuantity) < 0) errors.stockQuantity = 'Valid stock quantity (≥ 0) is required';
    setFormErrors(errors);
    return Object.keys(errors).length === 0;
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!validateForm()) return;

    setSubmitting(true);
    const payload = {
      name: formData.name.trim(),
      description: formData.description.trim() || null,
      price: parseFloat(formData.price),
      stockQuantity: parseInt(formData.stockQuantity, 10),
      category: formData.category.trim() || null,
    };

    try {
      if (isEditing) {
        await productsApi.update(editingId, payload);
        addToast('Product updated successfully', 'success');
      } else {
        await productsApi.create(payload);
        addToast('Product created successfully', 'success');
      }
      setIsFormModalOpen(false);
      fetchProducts();
    } catch (err) {
      addToast(err.message || 'Operation failed', 'error');
    } finally {
      setSubmitting(false);
    }
  };

  const handleDeleteConfirm = async () => {
    if (!deleteTarget) return;
    try {
      await productsApi.delete(deleteTarget.id);
      addToast(`Product "${deleteTarget.name}" deleted`, 'success');
      setDeleteTarget(null);
      fetchProducts();
    } catch (err) {
      addToast(err.message || 'Failed to delete product', 'error');
      setDeleteTarget(null);
    }
  };

  // Categories list for filtering
  const categories = ['ALL', ...new Set(products.map((p) => p.category).filter(Boolean))];

  const filteredProducts = products.filter((product) => {
    const matchesSearch =
      product.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      (product.description && product.description.toLowerCase().includes(searchTerm.toLowerCase())) ||
      (product.category && product.category.toLowerCase().includes(searchTerm.toLowerCase()));

    const matchesCategory = categoryFilter === 'ALL' || product.category === categoryFilter;

    return matchesSearch && matchesCategory;
  });

  return (
    <>
      <Header 
        title="Products & Inventory" 
        subtitle="Manage product catalog, pricing, and live warehouse inventory" 
      />

      <div className="page-wrapper">
        <Toast toasts={toasts} onDismiss={removeToast} />

        <div className="table-container">
          <div className="table-toolbar">
            <div style={{ display: 'flex', alignItems: 'center', gap: '1rem', flex: 1 }}>
              <div className="search-input-wrapper">
                <IconSearch className="search-icon" size={16} />
                <input 
                  type="text" 
                  className="search-input" 
                  placeholder="Search products..." 
                  value={searchTerm}
                  onChange={(e) => setSearchTerm(e.target.value)}
                />
              </div>

              <select 
                className="form-control" 
                style={{ width: 'auto', minWidth: '150px' }}
                value={categoryFilter}
                onChange={(e) => setCategoryFilter(e.target.value)}
              >
                {categories.map((cat) => (
                  <option key={cat} value={cat}>
                    {cat === 'ALL' ? 'All Categories' : cat}
                  </option>
                ))}
              </select>
            </div>

            <div style={{ display: 'flex', gap: '0.75rem' }}>
              <button className="btn btn-secondary" onClick={fetchProducts} disabled={loading}>
                <IconRefresh size={16} className={loading ? 'spinner' : ''} />
                Refresh
              </button>
              <button className="btn btn-primary" onClick={handleOpenAddModal}>
                <IconPlus size={18} />
                Add Product
              </button>
            </div>
          </div>

          {loading ? (
            <div className="loading-spinner-wrapper">
              <div className="spinner"></div>
              <span style={{ fontSize: '0.85rem', color: 'var(--slate-500)' }}>Loading inventory items...</span>
            </div>
          ) : filteredProducts.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-icon">
                <IconProducts size={28} />
              </div>
              <div className="empty-state-title">No products found</div>
              <p className="empty-state-desc">
                {searchTerm ? 'No products match your search filter.' : 'Get started by creating your first product.'}
              </p>
            </div>
          ) : (
            <div style={{ overflowX: 'auto' }}>
              <table className="app-table">
                <thead>
                  <tr>
                    <th>Product</th>
                    <th>Category</th>
                    <th>Price</th>
                    <th>Stock</th>
                    <th>Status</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredProducts.map((product) => (
                    <tr key={product.id}>
                      <td>
                        <div style={{ fontWeight: 600, color: 'var(--slate-900)' }}>{product.name}</div>
                        {product.description && (
                          <div style={{ fontSize: '0.775rem', color: 'var(--slate-500)', maxWidth: '300px', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                            {product.description}
                          </div>
                        )}
                      </td>
                      <td>
                        <span className="badge badge-category">{product.category || 'General'}</span>
                      </td>
                      <td style={{ fontWeight: 600 }}>
                        ${Number(product.price).toFixed(2)}
                      </td>
                      <td style={{ fontWeight: 600, color: product.stockQuantity === 0 ? 'var(--danger-600)' : 'inherit' }}>
                        {product.stockQuantity} units
                      </td>
                      <td>
                        <StatusBadge status={product.status} type="product" />
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        <div style={{ display: 'inline-flex', gap: '0.4rem' }}>
                          <button 
                            className="btn btn-secondary btn-sm" 
                            onClick={() => handleOpenEditModal(product)}
                            title="Edit Product"
                          >
                            <IconEdit size={14} /> Edit
                          </button>
                          <button 
                            className="btn btn-secondary btn-sm" 
                            style={{ color: 'var(--danger-600)', borderColor: 'var(--danger-100)' }}
                            onClick={() => setDeleteTarget(product)}
                            title="Delete Product"
                          >
                            <IconTrash size={14} />
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {/* Add / Edit Product Modal */}
      <Modal 
        isOpen={isFormModalOpen} 
        onClose={() => !submitting && setIsFormModalOpen(false)} 
        title={isEditing ? 'Edit Product' : 'Add New Product'}
      >
        <form onSubmit={handleSubmit}>
          <div className="modal-body">
            <div className="form-group">
              <label className="form-label">Product Name *</label>
              <input 
                type="text" 
                className={`form-control ${formErrors.name ? 'is-invalid' : ''}`}
                placeholder="e.g. Ergonomic Office Desk"
                value={formData.name}
                onChange={(e) => setFormData({ ...formData, name: e.target.value })}
              />
              {formErrors.name && <div className="form-error-text">{formErrors.name}</div>}
            </div>

            <div className="form-grid-2">
              <div className="form-group">
                <label className="form-label">Price ($) *</label>
                <input 
                  type="number" 
                  step="0.01" 
                  min="0.01"
                  className={`form-control ${formErrors.price ? 'is-invalid' : ''}`}
                  placeholder="0.00"
                  value={formData.price}
                  onChange={(e) => setFormData({ ...formData, price: e.target.value })}
                />
                {formErrors.price && <div className="form-error-text">{formErrors.price}</div>}
              </div>

              <div className="form-group">
                <label className="form-label">Stock Quantity *</label>
                <input 
                  type="number" 
                  min="0"
                  className={`form-control ${formErrors.stockQuantity ? 'is-invalid' : ''}`}
                  placeholder="0"
                  value={formData.stockQuantity}
                  onChange={(e) => setFormData({ ...formData, stockQuantity: e.target.value })}
                />
                {formErrors.stockQuantity && <div className="form-error-text">{formErrors.stockQuantity}</div>}
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">Category</label>
              <input 
                type="text" 
                className="form-control"
                placeholder="e.g. Electronics, Furniture, Accessories"
                value={formData.category}
                onChange={(e) => setFormData({ ...formData, category: e.target.value })}
              />
            </div>

            <div className="form-group" style={{ marginBottom: 0 }}>
              <label className="form-label">Description</label>
              <textarea 
                className="form-control" 
                rows="3"
                placeholder="Product specifications and features..."
                value={formData.description}
                onChange={(e) => setFormData({ ...formData, description: e.target.value })}
              ></textarea>
            </div>
          </div>

          <div className="modal-footer">
            <button 
              type="button" 
              className="btn btn-secondary" 
              onClick={() => setIsFormModalOpen(false)}
              disabled={submitting}
            >
              Cancel
            </button>
            <button 
              type="submit" 
              className="btn btn-primary"
              disabled={submitting}
            >
              {submitting ? 'Saving...' : isEditing ? 'Save Changes' : 'Create Product'}
            </button>
          </div>
        </form>
      </Modal>

      {/* Delete Confirmation Dialog */}
      <ConfirmDialog 
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={handleDeleteConfirm}
        title="Delete Product"
        message={`Are you sure you want to delete "${deleteTarget?.name}"? This action cannot be undone.`}
        confirmText="Delete Product"
        isDanger={true}
      />
    </>
  );
}

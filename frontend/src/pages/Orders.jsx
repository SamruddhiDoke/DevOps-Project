import React, { useState, useEffect } from 'react';
import Header from '../components/Header';
import StatusBadge from '../components/StatusBadge';
import Modal from '../components/Modal';
import Toast from '../components/Toast';
import { IconPlus, IconEye, IconSearch, IconRefresh, IconOrders, IconClose, IconEdit } from '../components/Icons';
import { ordersApi, usersApi, productsApi } from '../services/api';

export default function Orders() {
  const [orders, setOrders] = useState([]);
  const [users, setUsers] = useState([]);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);

  // Filters
  const [searchTerm, setSearchTerm] = useState('');
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Modals
  const [selectedOrder, setSelectedOrder] = useState(null);
  const [isStatusModalOpen, setIsStatusModalOpen] = useState(false);
  const [orderToUpdate, setOrderToUpdate] = useState(null);
  const [newStatus, setNewStatus] = useState('PENDING');

  // Create Order Modal State
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);
  const [orderUserId, setOrderUserId] = useState('');
  const [orderItems, setOrderItems] = useState([{ productId: '', quantity: 1 }]);
  const [orderErrors, setOrderErrors] = useState({});
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

  const fetchData = async () => {
    setLoading(true);
    try {
      const [ordersData, usersData, productsData] = await Promise.all([
        ordersApi.getAll().catch(() => []),
        usersApi.getAll().catch(() => []),
        productsApi.getAll().catch(() => []),
      ]);
      setOrders(ordersData || []);
      setUsers(usersData || []);
      setProducts(productsData || []);
    } catch (err) {
      addToast(err.message || 'Failed to fetch orders data', 'error');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchData();
  }, []);

  const handleOpenCreateModal = () => {
    setOrderUserId(users[0]?.id || '');
    setOrderItems([{ productId: products[0]?.id || '', quantity: 1 }]);
    setOrderErrors({});
    setIsCreateModalOpen(true);
  };

  const handleAddItemRow = () => {
    setOrderItems([...orderItems, { productId: products[0]?.id || '', quantity: 1 }]);
  };

  const handleRemoveItemRow = (index) => {
    if (orderItems.length === 1) return;
    setOrderItems(orderItems.filter((_, idx) => idx !== index));
  };

  const handleItemChange = (index, field, value) => {
    const updated = [...orderItems];
    updated[index][field] = value;
    setOrderItems(updated);
  };

  const calculateOrderPreviewTotal = () => {
    return orderItems.reduce((sum, item) => {
      const prod = products.find((p) => p.id === Number(item.productId));
      const price = prod ? Number(prod.price) : 0;
      const qty = Number(item.quantity) || 0;
      return sum + (price * qty);
    }, 0);
  };

  const handleCreateOrder = async (e) => {
    e.preventDefault();
    const errors = {};

    if (!orderUserId) errors.userId = 'Please select a customer';
    if (!orderItems.length) errors.items = 'At least one item is required';

    for (let i = 0; i < orderItems.length; i++) {
      const item = orderItems[i];
      if (!item.productId) {
        errors[`item_${i}`] = 'Please select a product';
      } else {
        const prod = products.find((p) => p.id === Number(item.productId));
        if (prod && Number(item.quantity) > prod.stockQuantity) {
          errors[`item_${i}`] = `Only ${prod.stockQuantity} units available`;
        }
      }
      if (!item.quantity || Number(item.quantity) < 1) {
        errors[`item_qty_${i}`] = 'Min qty 1';
      }
    }

    if (Object.keys(errors).length > 0) {
      setOrderErrors(errors);
      return;
    }

    setSubmitting(true);
    try {
      const payload = {
        userId: Number(orderUserId),
        items: orderItems.map((item) => ({
          productId: Number(item.productId),
          quantity: parseInt(item.quantity, 10),
        })),
      };

      await ordersApi.create(payload);
      addToast('Order created successfully', 'success');
      setIsCreateModalOpen(false);
      fetchData();
    } catch (err) {
      addToast(err.message || 'Failed to create order', 'error');
    } finally {
      setSubmitting(false);
    }
  };

  const handleOpenStatusModal = (order) => {
    setOrderToUpdate(order);
    setNewStatus(order.status);
    setIsStatusModalOpen(true);
  };

  const handleUpdateStatus = async (e) => {
    e.preventDefault();
    if (!orderToUpdate) return;

    setSubmitting(true);
    try {
      await ordersApi.updateStatus(orderToUpdate.id, newStatus);
      addToast(`Order #${orderToUpdate.id} updated to ${newStatus}`, 'success');
      setIsStatusModalOpen(false);
      setOrderToUpdate(null);
      fetchData();
    } catch (err) {
      addToast(err.message || 'Failed to update order status', 'error');
    } finally {
      setSubmitting(false);
    }
  };

  const statuses = ['ALL', 'PENDING', 'CONFIRMED', 'SHIPPED', 'DELIVERED', 'CANCELLED'];

  const filteredOrders = orders.filter((order) => {
    const matchesSearch =
      order.id.toString().includes(searchTerm) ||
      (order.userName && order.userName.toLowerCase().includes(searchTerm.toLowerCase())) ||
      (order.userEmail && order.userEmail.toLowerCase().includes(searchTerm.toLowerCase()));

    const matchesStatus = statusFilter === 'ALL' || order.status === statusFilter;

    return matchesSearch && matchesStatus;
  });

  return (
    <>
      <Header 
        title="Order Management" 
        subtitle="Track customer purchases, fulfillment cycles, and line-item details" 
      />

      <div className="page-wrapper">
        <Toast toasts={toasts} onDismiss={removeToast} />

        <div className="table-container">
          <div className="table-toolbar">
            <div style={{ display: 'flex', alignItems: 'center', gap: '1rem', flex: 1, flexWrap: 'wrap' }}>
              <div className="search-input-wrapper">
                <IconSearch className="search-icon" size={16} />
                <input 
                  type="text" 
                  className="search-input" 
                  placeholder="Search order ID or customer..." 
                  value={searchTerm}
                  onChange={(e) => setSearchTerm(e.target.value)}
                />
              </div>

              <div style={{ display: 'flex', gap: '0.25rem', overflowX: 'auto' }}>
                {statuses.map((st) => (
                  <button
                    key={st}
                    className={`btn btn-sm ${statusFilter === st ? 'btn-primary' : 'btn-secondary'}`}
                    onClick={() => setStatusFilter(st)}
                  >
                    {st === 'ALL' ? 'All Orders' : st}
                  </button>
                ))}
              </div>
            </div>

            <div style={{ display: 'flex', gap: '0.75rem' }}>
              <button className="btn btn-secondary" onClick={fetchData} disabled={loading}>
                <IconRefresh size={16} className={loading ? 'spinner' : ''} />
                Refresh
              </button>
              <button className="btn btn-primary" onClick={handleOpenCreateModal}>
                <IconPlus size={18} />
                Create Order
              </button>
            </div>
          </div>

          {loading ? (
            <div className="loading-spinner-wrapper">
              <div className="spinner"></div>
              <span style={{ fontSize: '0.85rem', color: 'var(--slate-500)' }}>Loading orders...</span>
            </div>
          ) : filteredOrders.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-icon">
                <IconOrders size={28} />
              </div>
              <div className="empty-state-title">No orders found</div>
              <p className="empty-state-desc">
                {searchTerm || statusFilter !== 'ALL'
                  ? 'No orders matched your current filters.'
                  : 'Start by clicking "Create Order" above.'}
              </p>
            </div>
          ) : (
            <div style={{ overflowX: 'auto' }}>
              <table className="app-table">
                <thead>
                  <tr>
                    <th>Order ID</th>
                    <th>Customer</th>
                    <th>Amount</th>
                    <th>Date</th>
                    <th>Status</th>
                    <th style={{ textAlign: 'right' }}>Action</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredOrders.map((order) => (
                    <tr key={order.id}>
                      <td style={{ fontWeight: 600 }}>#{order.id}</td>
                      <td>
                        <div style={{ fontWeight: 600, color: 'var(--slate-900)' }}>
                          {order.userName || `User #${order.userId}`}
                        </div>
                        <div style={{ fontSize: '0.75rem', color: 'var(--slate-500)' }}>
                          {order.userEmail}
                        </div>
                      </td>
                      <td style={{ fontWeight: 700, color: 'var(--slate-900)' }}>
                        ${Number(order.totalAmount).toFixed(2)}
                      </td>
                      <td style={{ fontSize: '0.825rem', color: 'var(--slate-600)' }}>
                        {new Date(order.createdAt).toLocaleDateString(undefined, {
                          year: 'numeric',
                          month: 'short',
                          day: 'numeric',
                          hour: '2-digit',
                          minute: '2-digit'
                        })}
                      </td>
                      <td>
                        <StatusBadge status={order.status} type="order" />
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        <div style={{ display: 'inline-flex', gap: '0.4rem' }}>
                          <button 
                            className="btn btn-secondary btn-sm"
                            onClick={() => setSelectedOrder(order)}
                            title="View Full Details"
                          >
                            <IconEye size={14} /> View
                          </button>
                          <button 
                            className="btn btn-secondary btn-sm"
                            onClick={() => handleOpenStatusModal(order)}
                            title="Update Status"
                          >
                            <IconEdit size={14} /> Status
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

      {/* View Order Details Modal */}
      {selectedOrder && (
        <Modal 
          isOpen={!!selectedOrder} 
          onClose={() => setSelectedOrder(null)} 
          title={`Order #${selectedOrder.id} Invoice Summary`}
          maxWidth="680px"
        >
          <div className="modal-body">
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem', marginBottom: '1.5rem', background: 'var(--slate-50)', padding: '1.25rem', borderRadius: '8px' }}>
              <div>
                <span style={{ fontSize: '0.75rem', color: 'var(--slate-500)', textTransform: 'uppercase', fontWeight: 600 }}>Customer Information</span>
                <div style={{ fontWeight: 600, fontSize: '1rem', color: 'var(--slate-900)', marginTop: '0.25rem' }}>
                  {selectedOrder.userName}
                </div>
                <div style={{ fontSize: '0.85rem', color: 'var(--slate-600)' }}>{selectedOrder.userEmail}</div>
              </div>
              <div>
                <span style={{ fontSize: '0.75rem', color: 'var(--slate-500)', textTransform: 'uppercase', fontWeight: 600 }}>Fulfillment State</span>
                <div style={{ marginTop: '0.25rem' }}><StatusBadge status={selectedOrder.status} type="order" /></div>
                <div style={{ fontSize: '0.8rem', color: 'var(--slate-500)', marginTop: '0.35rem' }}>
                  Placed on: {new Date(selectedOrder.createdAt).toLocaleString()}
                </div>
              </div>
            </div>

            <h4 style={{ fontSize: '0.925rem', fontWeight: 700, marginBottom: '0.75rem', color: 'var(--slate-800)' }}>
              Itemized Products ({selectedOrder.items?.length || 0})
            </h4>

            <table className="app-table">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Category</th>
                  <th>Quantity</th>
                  <th>Unit Price</th>
                  <th>Subtotal</th>
                </tr>
              </thead>
              <tbody>
                {selectedOrder.items?.map((item) => (
                  <tr key={item.id}>
                    <td style={{ fontWeight: 600 }}>{item.productName}</td>
                    <td><span className="badge badge-category">{item.productCategory || 'General'}</span></td>
                    <td>{item.quantity}</td>
                    <td>${Number(item.price).toFixed(2)}</td>
                    <td style={{ fontWeight: 600 }}>${Number(item.subtotal || item.price * item.quantity).toFixed(2)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan="4" style={{ textAlign: 'right', fontWeight: 700, fontSize: '1rem' }}>Total Amount:</td>
                  <td style={{ fontWeight: 700, fontSize: '1.1rem', color: 'var(--primary-700)' }}>
                    ${Number(selectedOrder.totalAmount).toFixed(2)}
                  </td>
                </tr>
              </tfoot>
            </table>
          </div>
          <div className="modal-footer">
            <button className="btn btn-secondary" onClick={() => setSelectedOrder(null)}>
              Close
            </button>
            <button 
              className="btn btn-primary" 
              onClick={() => {
                const o = selectedOrder;
                setSelectedOrder(null);
                handleOpenStatusModal(o);
              }}
            >
              Update Status
            </button>
          </div>
        </Modal>
      )}

      {/* Update Order Status Modal */}
      <Modal 
        isOpen={isStatusModalOpen} 
        onClose={() => !submitting && setIsStatusModalOpen(false)} 
        title={`Update Order #${orderToUpdate?.id} Status`}
        maxWidth="460px"
      >
        <form onSubmit={handleUpdateStatus}>
          <div className="modal-body">
            <div className="form-group">
              <label className="form-label">Current Status</label>
              <div>
                <StatusBadge status={orderToUpdate?.status} type="order" />
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">New Status *</label>
              <select 
                className="form-control"
                value={newStatus}
                onChange={(e) => setNewStatus(e.target.value)}
              >
                <option value="PENDING">PENDING</option>
                <option value="CONFIRMED">CONFIRMED</option>
                <option value="SHIPPED">SHIPPED</option>
                <option value="DELIVERED">DELIVERED</option>
                <option value="CANCELLED">CANCELLED</option>
              </select>
            </div>
            
            {newStatus === 'CANCELLED' && (
              <div style={{ fontSize: '0.8rem', color: 'var(--warning-700)', backgroundColor: 'var(--warning-50)', padding: '0.75rem', borderRadius: '6px' }}>
                Note: Setting order to CANCELLED will automatically replenish warehouse inventory stock for these items.
              </div>
            )}
          </div>
          <div className="modal-footer">
            <button 
              type="button" 
              className="btn btn-secondary" 
              onClick={() => setIsStatusModalOpen(false)}
              disabled={submitting}
            >
              Cancel
            </button>
            <button 
              type="submit" 
              className="btn btn-primary"
              disabled={submitting}
            >
              {submitting ? 'Saving...' : 'Update Status'}
            </button>
          </div>
        </form>
      </Modal>

      {/* Create Order Modal */}
      <Modal 
        isOpen={isCreateModalOpen} 
        onClose={() => !submitting && setIsCreateModalOpen(false)} 
        title="Create New Customer Order"
        maxWidth="680px"
      >
        <form onSubmit={handleCreateOrder}>
          <div className="modal-body">
            <div className="form-group">
              <label className="form-label">Select Customer *</label>
              <select 
                className={`form-control ${orderErrors.userId ? 'is-invalid' : ''}`}
                value={orderUserId}
                onChange={(e) => setOrderUserId(e.target.value)}
              >
                <option value="">-- Choose Customer --</option>
                {users.map((u) => (
                  <option key={u.id} value={u.id}>
                    {u.name} ({u.email})
                  </option>
                ))}
              </select>
              {orderErrors.userId && <div className="form-error-text">{orderErrors.userId}</div>}
            </div>

            <div style={{ marginBottom: '1.25rem' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.5rem' }}>
                <label className="form-label" style={{ marginBottom: 0 }}>Order Items</label>
                <button 
                  type="button" 
                  className="btn btn-secondary btn-sm"
                  onClick={handleAddItemRow}
                >
                  <IconPlus size={14} /> Add Another Item
                </button>
              </div>

              {orderItems.map((item, idx) => {
                const selectedProd = products.find((p) => p.id === Number(item.productId));
                return (
                  <div 
                    key={idx} 
                    style={{ 
                      display: 'flex', 
                      gap: '0.75rem', 
                      alignItems: 'flex-start', 
                      marginBottom: '0.75rem',
                      background: 'var(--slate-50)',
                      padding: '0.75rem',
                      borderRadius: '8px'
                    }}
                  >
                    <div style={{ flex: 2 }}>
                      <select 
                        className={`form-control ${orderErrors[`item_${idx}`] ? 'is-invalid' : ''}`}
                        value={item.productId}
                        onChange={(e) => handleItemChange(idx, 'productId', e.target.value)}
                      >
                        <option value="">-- Select Product --</option>
                        {products.map((p) => (
                          <option key={p.id} value={p.id} disabled={p.stockQuantity <= 0}>
                            {p.name} - ${Number(p.price).toFixed(2)} (Stock: {p.stockQuantity})
                          </option>
                        ))}
                      </select>
                      {orderErrors[`item_${idx}`] && (
                        <div className="form-error-text">{orderErrors[`item_${idx}`]}</div>
                      )}
                    </div>

                    <div style={{ width: '100px' }}>
                      <input 
                        type="number" 
                        min="1" 
                        max={selectedProd ? selectedProd.stockQuantity : undefined}
                        className={`form-control ${orderErrors[`item_qty_${idx}`] ? 'is-invalid' : ''}`}
                        value={item.quantity}
                        placeholder="Qty"
                        onChange={(e) => handleItemChange(idx, 'quantity', e.target.value)}
                      />
                    </div>

                    <div style={{ width: '110px', textAlign: 'right', fontWeight: 600, alignSelf: 'center' }}>
                      ${selectedProd ? (Number(selectedProd.price) * (Number(item.quantity) || 0)).toFixed(2) : '0.00'}
                    </div>

                    <button 
                      type="button" 
                      className="btn-icon-only"
                      onClick={() => handleRemoveItemRow(idx)}
                      disabled={orderItems.length === 1}
                      style={{ alignSelf: 'center', opacity: orderItems.length === 1 ? 0.3 : 1 }}
                    >
                      <IconClose size={18} />
                    </button>
                  </div>
                );
              })}
            </div>

            <div style={{ 
              borderTop: '1px solid var(--slate-200)', 
              paddingTop: '1rem', 
              display: 'flex', 
              justifyContent: 'space-between', 
              alignItems: 'center',
              fontWeight: 700 
            }}>
              <span>Calculated Total:</span>
              <span style={{ fontSize: '1.25rem', color: 'var(--primary-700)' }}>
                ${calculateOrderPreviewTotal().toFixed(2)}
              </span>
            </div>
          </div>

          <div className="modal-footer">
            <button 
              type="button" 
              className="btn btn-secondary" 
              onClick={() => setIsCreateModalOpen(false)}
              disabled={submitting}
            >
              Cancel
            </button>
            <button 
              type="submit" 
              className="btn btn-primary"
              disabled={submitting || products.length === 0 || users.length === 0}
            >
              {submitting ? 'Placing Order...' : 'Confirm Order'}
            </button>
          </div>
        </form>
      </Modal>
    </>
  );
}

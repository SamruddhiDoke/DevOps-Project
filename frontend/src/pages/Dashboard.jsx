import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import Header from '../components/Header';
import StatCard from '../components/StatCard';
import StatusBadge from '../components/StatusBadge';
import Modal from '../components/Modal';
import { IconUsers, IconProducts, IconOrders, IconAlert, IconEye, IconRefresh } from '../components/Icons';
import { usersApi, productsApi, ordersApi } from '../services/api';

export default function Dashboard() {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  
  const [users, setUsers] = useState([]);
  const [products, setProducts] = useState([]);
  const [orders, setOrders] = useState([]);

  // Selected Order for quick details modal
  const [selectedOrder, setSelectedOrder] = useState(null);

  const fetchData = async () => {
    setLoading(true);
    setError(null);
    try {
      const [usersData, productsData, ordersData] = await Promise.all([
        usersApi.getAll().catch(() => []),
        productsApi.getAll().catch(() => []),
        ordersApi.getAll().catch(() => []),
      ]);

      setUsers(usersData || []);
      setProducts(productsData || []);
      setOrders(ordersData || []);
    } catch (err) {
      setError('Failed to fetch dashboard data. Please check backend connection.');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchData();
  }, []);

  const lowStockProducts = products.filter(
    (p) => p.stockQuantity <= 10
  );

  const recentOrders = orders.slice(0, 5);

  const totalRevenue = orders
    .filter(o => o.status !== 'CANCELLED')
    .reduce((sum, o) => sum + (Number(o.totalAmount) || 0), 0);

  return (
    <>
      <Header 
        title="Operations Dashboard" 
        subtitle="Real-time overview of inventory, orders, and customer activity" 
      />

      <div className="page-wrapper">
        <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: '1.25rem' }}>
          <button 
            className="btn btn-secondary btn-sm" 
            onClick={fetchData} 
            disabled={loading}
          >
            <IconRefresh size={16} className={loading ? 'spinner' : ''} />
            Refresh Data
          </button>
        </div>

        {error && (
          <div style={{
            padding: '1rem',
            backgroundColor: 'var(--danger-50)',
            color: 'var(--danger-700)',
            borderRadius: '8px',
            marginBottom: '1.5rem',
            border: '1px solid var(--danger-100)'
          }}>
            {error}
          </div>
        )}

        {/* 4 KPI Summary Cards */}
        <div className="stats-grid">
          <StatCard 
            title="Total Users" 
            value={users.length} 
            icon={<IconUsers size={24} />}
            accentColor="var(--primary-600)"
            iconBg="var(--primary-50)"
            iconColor="var(--primary-600)"
            subtitle="Registered Customers"
          />

          <StatCard 
            title="Total Products" 
            value={products.length} 
            icon={<IconProducts size={24} />}
            accentColor="#0284c7"
            iconBg="#f0f9ff"
            iconColor="#0284c7"
            subtitle="Catalog Items"
          />

          <StatCard 
            title="Low Stock Products" 
            value={lowStockProducts.length} 
            icon={<IconAlert size={24} />}
            accentColor={lowStockProducts.length > 0 ? "var(--warning-600)" : "var(--success-600)"}
            iconBg={lowStockProducts.length > 0 ? "var(--warning-50)" : "var(--success-50)"}
            iconColor={lowStockProducts.length > 0 ? "var(--warning-600)" : "var(--success-600)"}
            subtitle="≤ 10 Units Remaining"
          />

          <StatCard 
            title="Total Orders" 
            value={orders.length} 
            icon={<IconOrders size={24} />}
            accentColor="#7c3aed"
            iconBg="#f5f3ff"
            iconColor="#7c3aed"
            subtitle={`$${totalRevenue.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })} Total Volume`}
          />
        </div>

        {/* 2-Column Section: Recent Orders & Low Stock Inventory */}
        <div className="dashboard-layout-2col">
          {/* Recent Orders */}
          <div className="card">
            <div className="card-header">
              <div>
                <h2 className="card-title">Recent Orders</h2>
                <p style={{ fontSize: '0.8rem', color: 'var(--slate-500)' }}>Latest transactions across the platform</p>
              </div>
              <Link to="/orders" className="btn btn-secondary btn-sm">
                View All Orders &rarr;
              </Link>
            </div>

            {loading ? (
              <div className="loading-spinner-wrapper">
                <div className="spinner"></div>
                <span style={{ fontSize: '0.85rem', color: 'var(--slate-500)' }}>Loading orders...</span>
              </div>
            ) : recentOrders.length === 0 ? (
              <div className="empty-state" style={{ padding: '2rem 1rem' }}>
                <div className="empty-state-title">No orders yet</div>
                <p className="empty-state-desc">When customers place orders, they will appear here.</p>
              </div>
            ) : (
              <div style={{ overflowX: 'auto' }}>
                <table className="app-table">
                  <thead>
                    <tr>
                      <th>Order ID</th>
                      <th>Customer</th>
                      <th>Amount</th>
                      <th>Status</th>
                      <th>Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {recentOrders.map((order) => (
                      <tr key={order.id}>
                        <td style={{ fontWeight: 600 }}>#{order.id}</td>
                        <td>{order.userName || `User #${order.userId}`}</td>
                        <td style={{ fontWeight: 600 }}>${Number(order.totalAmount).toFixed(2)}</td>
                        <td><StatusBadge status={order.status} type="order" /></td>
                        <td>
                          <button 
                            className="btn btn-secondary btn-sm"
                            onClick={() => setSelectedOrder(order)}
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

          {/* Low Stock Alerts */}
          <div className="card">
            <div className="card-header">
              <div>
                <h2 className="card-title">Low Stock Alert</h2>
                <p style={{ fontSize: '0.8rem', color: 'var(--slate-500)' }}>Items requiring inventory replenishment</p>
              </div>
              <Link to="/products" className="btn btn-secondary btn-sm">
                Manage Inventory &rarr;
              </Link>
            </div>

            {loading ? (
              <div className="loading-spinner-wrapper">
                <div className="spinner"></div>
                <span style={{ fontSize: '0.85rem', color: 'var(--slate-500)' }}>Checking stock...</span>
              </div>
            ) : lowStockProducts.length === 0 ? (
              <div className="empty-state" style={{ padding: '2rem 1rem' }}>
                <div className="empty-state-icon" style={{ backgroundColor: 'var(--success-50)', color: 'var(--success-600)' }}>
                  ✓
                </div>
                <div className="empty-state-title">All stock levels healthy</div>
                <p className="empty-state-desc">No products are currently under the low stock threshold.</p>
              </div>
            ) : (
              <div style={{ overflowX: 'auto' }}>
                <table className="app-table">
                  <thead>
                    <tr>
                      <th>Product</th>
                      <th>Category</th>
                      <th>Stock</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {lowStockProducts.map((p) => (
                      <tr key={p.id}>
                        <td style={{ fontWeight: 600 }}>{p.name}</td>
                        <td><span className="badge badge-category">{p.category || 'General'}</span></td>
                        <td style={{ fontWeight: 700, color: p.stockQuantity === 0 ? 'var(--danger-600)' : 'var(--warning-600)' }}>
                          {p.stockQuantity} units
                        </td>
                        <td><StatusBadge status={p.status || (p.stockQuantity === 0 ? 'OUT_OF_STOCK' : 'LOW_STOCK')} type="product" /></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Quick Order Details Modal */}
      {selectedOrder && (
        <Modal 
          isOpen={!!selectedOrder} 
          onClose={() => setSelectedOrder(null)} 
          title={`Order #${selectedOrder.id} Details`}
          maxWidth="640px"
        >
          <div className="modal-body">
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem', marginBottom: '1.5rem', background: 'var(--slate-50)', padding: '1rem', borderRadius: '8px' }}>
              <div>
                <span style={{ fontSize: '0.75rem', color: 'var(--slate-500)', textTransform: 'uppercase', fontWeight: 600 }}>Customer</span>
                <div style={{ fontWeight: 600, color: 'var(--slate-900)' }}>{selectedOrder.userName || `User #${selectedOrder.userId}`}</div>
                <div style={{ fontSize: '0.8rem', color: 'var(--slate-600)' }}>{selectedOrder.userEmail}</div>
              </div>
              <div>
                <span style={{ fontSize: '0.75rem', color: 'var(--slate-500)', textTransform: 'uppercase', fontWeight: 600 }}>Status & Date</span>
                <div><StatusBadge status={selectedOrder.status} type="order" /></div>
                <div style={{ fontSize: '0.8rem', color: 'var(--slate-500)', marginTop: '0.25rem' }}>
                  {new Date(selectedOrder.createdAt).toLocaleString()}
                </div>
              </div>
            </div>

            <h4 style={{ fontSize: '0.9rem', fontWeight: 700, marginBottom: '0.75rem', color: 'var(--slate-800)' }}>
              Ordered Items
            </h4>

            <table className="app-table">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Quantity</th>
                  <th>Unit Price</th>
                  <th>Subtotal</th>
                </tr>
              </thead>
              <tbody>
                {selectedOrder.items?.map((item) => (
                  <tr key={item.id}>
                    <td style={{ fontWeight: 500 }}>{item.productName}</td>
                    <td>{item.quantity}</td>
                    <td>${Number(item.price).toFixed(2)}</td>
                    <td style={{ fontWeight: 600 }}>${Number(item.subtotal || item.price * item.quantity).toFixed(2)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan="3" style={{ textAlign: 'right', fontWeight: 700 }}>Total Amount:</td>
                  <td style={{ fontWeight: 700, fontSize: '1rem', color: 'var(--primary-700)' }}>
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
          </div>
        </Modal>
      )}
    </>
  );
}

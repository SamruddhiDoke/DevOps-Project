import React from 'react';

export default function StatusBadge({ status, type = 'order' }) {
  if (!status) return null;

  const normalized = status.toUpperCase();

  if (type === 'product' || normalized === 'IN_STOCK' || normalized === 'LOW_STOCK' || normalized === 'OUT_OF_STOCK') {
    switch (normalized) {
      case 'IN_STOCK':
        return <span className="badge badge-in-stock">● In Stock</span>;
      case 'LOW_STOCK':
        return <span className="badge badge-low-stock">▲ Low Stock</span>;
      case 'OUT_OF_STOCK':
        return <span className="badge badge-out-of-stock">✕ Out of Stock</span>;
      default:
        return <span className="badge">{status}</span>;
    }
  }

  // Default: Order status
  switch (normalized) {
    case 'PENDING':
      return <span className="badge badge-pending">⏱ Pending</span>;
    case 'CONFIRMED':
      return <span className="badge badge-confirmed">✓ Confirmed</span>;
    case 'SHIPPED':
      return <span className="badge badge-shipped">✈ Shipped</span>;
    case 'DELIVERED':
      return <span className="badge badge-delivered">★ Delivered</span>;
    case 'CANCELLED':
      return <span className="badge badge-cancelled">✕ Cancelled</span>;
    default:
      return <span className="badge">{status}</span>;
  }
}

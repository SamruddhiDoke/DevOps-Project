import React from 'react';
import { NavLink } from 'react-router-dom';
import { IconDashboard, IconUsers, IconProducts, IconOrders, IconBox } from './Icons';

export default function Sidebar() {
  return (
    <aside className="sidebar">
      <div className="sidebar-brand">
        <div className="brand-icon">
          <IconBox size={22} />
        </div>
        <div>
          <div className="brand-title">CoreStore</div>
          <div className="brand-subtitle">Order & Inventory</div>
        </div>
      </div>

      <nav className="sidebar-nav">
        <div className="nav-category">Main Navigation</div>
        
        <NavLink to="/dashboard" className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>
          <IconDashboard size={19} />
          <span>Dashboard</span>
        </NavLink>

        <NavLink to="/products" className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>
          <IconProducts size={19} />
          <span>Products</span>
        </NavLink>

        <NavLink to="/orders" className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>
          <IconOrders size={19} />
          <span>Orders</span>
        </NavLink>

        <NavLink to="/users" className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>
          <IconUsers size={19} />
          <span>Users</span>
        </NavLink>
      </nav>

      <div className="sidebar-footer">
        <div className="devops-phase-tag">
          <span>● Base Application (Phase 1)</span>
        </div>
      </div>
    </aside>
  );
}

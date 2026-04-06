import React from 'react';

export default function MetricsCard({ title, value, icon, trend }) {
  return (
    <div className="glass-panel" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
      <div>
        <h3 style={{ color: 'var(--text-muted)', fontSize: '0.9rem', marginTop: 0, marginBottom: '0.5rem', fontWeight: 500 }}>
          {title}
        </h3>
        <div style={{ fontSize: '2rem', fontWeight: 700, margin: 0, color: trend === 'negative' ? 'var(--error-color)' : 'var(--text-main)' }}>
          {value}
        </div>
      </div>
      <div style={{ padding: '12px', background: 'rgba(255,255,255,0.05)', borderRadius: '12px' }}>
        {icon}
      </div>
    </div>
  );
}

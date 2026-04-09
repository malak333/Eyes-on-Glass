import React, { useState } from 'react';

export default function LogViewer({ logs, apiUrl }) {
  const [expandedLog, setExpandedLog] = useState(null);

  if (!logs || logs.length === 0) {
    return <div style={{ color: 'var(--text-muted)' }}>No logs collected yet.</div>;
  }

  // Reverse logs so the newest logs are displayed at the top
  const reversedLogs = [...logs].reverse();
  
  // Show only issues to avoid clutter, unless all are OK
  const issues = reversedLogs.filter(l => l.issue_type !== 'ok');
  const displayLogs = issues.length > 0 ? issues : reversedLogs.slice(0, 5); // Just show a few 'ok's if no issues

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '0.8rem', marginTop: '1rem', maxHeight: '400px', overflowY: 'auto', paddingRight: '8px' }}>
      {displayLogs.map(log => {
        let titleColor = 'var(--text-main)';
        if (log.issue_type === 'black_screen') titleColor = 'var(--error-color)';
        if (log.issue_type === 'slate') titleColor = 'var(--warning-color)';
        if (log.issue_type === 'macroblocking') titleColor = 'var(--error-color)';
        if (log.issue_type === 'no_audio' || log.issue_type === 'static_audio') titleColor = 'var(--audio-error)';

        const isExpanded = expandedLog === log.id;

        return (
          <div 
            key={log.id} 
            style={{ 
              background: 'rgba(0,0,0,0.2)', 
              border: `1px solid ${isExpanded ? 'var(--primary-color)' : 'rgba(255,255,255,0.05)'}`,
              borderRadius: '8px',
              padding: '1rem',
              cursor: 'pointer',
              transition: 'all 0.2s'
            }}
            onClick={() => setExpandedLog(isExpanded ? null : log.id)}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div>
                <span style={{ fontWeight: 'bold', color: titleColor }}>
                  {log.issue_type.toUpperCase().replace('_', ' ')}
                </span>
                <span style={{ color: 'var(--text-muted)', marginLeft: '0.8rem', fontSize: '0.85rem' }}>
                  {log.created_at ? `${new Date(log.created_at).toLocaleString()} | ` : ''}{log.timestamp_sec.toFixed(2)}s
                </span>
              </div>
            </div>

            {isExpanded && log.thumbnail_url && (
              <div style={{ marginTop: '1rem', background: '#000', borderRadius: '4px', overflow: 'hidden' }}>
                <img 
                  src={`${apiUrl}${log.thumbnail_url}`} 
                  alt="Frame Capture" 
                  style={{ width: '100%', maxHeight: '200px', objectFit: 'contain', display: 'block' }} 
                />
                <div style={{ padding: '0.5rem', fontSize: '0.8rem', color: 'var(--text-muted)' }}>
                  Engine: {log.analysis_engine || 'N/A'} | Conf: {(log.issue_score * 100).toFixed(1)}% | Source: {log.node_source} | Edge: {log.node_dest}
                </div>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

import React from 'react';

export default function Timeline({ logs }) {
  if (!logs || logs.length === 0) {
    return <div style={{ color: 'var(--text-muted)', paddingTop: '2rem' }}>Awaiting data streams...</div>;
  }

  // Calculate the maximum timestamp roughly to scale the timeline
  const maxTime = Math.max(...logs.map(l => l.timestamp_sec), 60);

  return (
    <div style={{ position: 'relative', height: '60px', marginTop: '2rem', background: 'rgba(0,0,0,0.4)', borderRadius: '8px', overflow: 'hidden' }}>
      {/* Base Timeline Line */}
      <div style={{ position: 'absolute', top: '50%', left: '0', right: '0', height: '2px', background: 'var(--surface-border)', transform: 'translateY(-50%)' }}></div>
      
      {logs.map(log => {
        const leftPercent = (log.timestamp_sec / maxTime) * 100;
        let color = "var(--success-color)";
        if (log.issue_type === "black_screen") color = "var(--error-color)";
        if (log.issue_type === "slate") color = "var(--warning-color)";
        if (log.issue_type === "macroblocking") color = "var(--error-color)";
        if (log.issue_type === "no_audio") color = "var(--audio-error)";

        return (
          <div 
            key={log.id}
            title={`${log.issue_type} at ${log.timestamp_sec}s`}
            style={{
              position: 'absolute',
              left: `${leftPercent}%`,
              top: '50%',
              transform: 'translate(-50%, -50%)',
              width: log.issue_type !== 'ok' ? '12px' : '4px',
              height: log.issue_type !== 'ok' ? '24px' : '12px',
              background: color,
              borderRadius: '2px',
              boxShadow: log.issue_type !== 'ok' ? `0 0 10px ${color}` : 'none',
              zIndex: log.issue_type !== 'ok' ? 10 : 1
            }}
          />
        );
      })}
    </div>
  );
}

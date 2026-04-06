import React, { useState, useEffect } from 'react';
import VideoUploader from './components/VideoUploader';
import MetricsCard from './components/MetricsCard';
import Timeline from './components/Timeline';
import LogViewer from './components/LogViewer';
import SystemResources from './components/SystemResources';
import { Activity, ShieldAlert, CheckCircle, RefreshCcw } from 'lucide-react';

const API_URL = "http://localhost:8000";

function App() {
  const [logs, setLogs] = useState([]);
  const [loading, setLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('active');
  const [selectedHistory, setSelectedHistory] = useState(null);
  const [processingFile, setProcessingFile] = useState(null);
  const [progressData, setProgressData] = useState({});

  const fetchLogs = async () => {
    setLoading(true);
    try {
      const logRes = await fetch(`${API_URL}/logs`);
      const logData = await logRes.json();
      setLogs(logData.logs);
    } catch (err) {
      console.error("Failed to fetch data:", err);
    } finally {
      setLoading(false);
    }
  };

  const fetchProgress = async () => {
    try {
      const res = await fetch(`${API_URL}/progress`);
      const data = await res.json();
      setProgressData(data);
    } catch (err) {
      console.error("Failed to fetch progress:", err);
    }
  };

  useEffect(() => {
    fetchLogs();
    fetchProgress();
    const interval = setInterval(() => {
        fetchLogs();
        fetchProgress();
    }, 5000); // refresh every 5s for MVP sync
    return () => clearInterval(interval);
  }, []);

  const logsByFile = logs.reduce((acc, log) => {
    if (!acc[log.filename]) acc[log.filename] = [];
    acc[log.filename].push(log);
    return acc;
  }, {});

  const filenames = Object.keys(logsByFile).sort((a, b) => {
    const maxIdA = Math.max(...logsByFile[a].map(l => l.id));
    const maxIdB = Math.max(...logsByFile[b].map(l => l.id));
    return maxIdA - maxIdB;
  });
  const activeFilename = processingFile || (filenames.length > 0 ? filenames[filenames.length - 1] : null);
  const currentFilename = activeTab === 'active' ? activeFilename : selectedHistory;
  const currentLogs = currentFilename ? logsByFile[currentFilename] : [];

  const calculateStats = (streamLogs) => {
    const total_frames = streamLogs.length;
    if (total_frames === 0) return { total_frames: 0, issues_count: 0, health_score: 100 };
    const issues_count = streamLogs.filter(l => l.issue_type !== "ok").length;
    const health_score = Math.max(0, 100 - (issues_count / total_frames * 100)).toFixed(2);
    return { total_frames, issues_count, health_score };
  };

  const currentStats = currentFilename ? calculateStats(currentLogs) : { total_frames: 0, issues_count: 0, health_score: 100 };

  return (
    <div className="app-container animate-fade-in">
      <header className="header">
        <h1>Eyes on Glass</h1>
        <div style={{display: 'flex', gap: '1rem'}}>
          <VideoUploader onUploadSuccess={(filename) => { setActiveTab('active'); setProcessingFile(filename); fetchLogs(); fetchProgress(); }} apiUrl={API_URL} />
          <button className="btn" onClick={() => { fetchLogs(); fetchProgress(); }}>
            <RefreshCcw size={18} className={loading ? 'spinning' : ''} />
            Refresh
          </button>
        </div>
      </header>

      <div className="tabs animate-fade-in" style={{animationDelay: '0.05s'}}>
        <button className={`tab-btn ${activeTab === 'active' ? 'active' : ''}`} onClick={() => { setActiveTab('active'); setSelectedHistory(null); }}>Active Stream</button>
        <button className={`tab-btn ${activeTab === 'history' ? 'active' : ''}`} onClick={() => setActiveTab('history')}>Old Analysis</button>
      </div>

      {activeTab === 'history' && !selectedHistory && (
        <section className="glass-panel animate-fade-in" style={{marginBottom: '2rem'}}>
          <h2 style={{marginTop: 0}}>Past Analysis Sessions</h2>
          {filenames.length === 0 && <p style={{color: 'var(--text-muted)'}}>No analysis history available.</p>}
          {filenames.length > 0 && filenames.length <= 1 && <p style={{color: 'var(--text-muted)'}}>No older analysis available yet.</p>}
          {filenames.length > 1 && (
            <ul style={{listStyle: 'none', padding: 0, display: 'grid', gap: '1rem', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))'}}>
              {filenames.filter(f => f !== activeFilename).reverse().map(file => (
                <li key={file}>
                  <button className="btn" style={{width: '100%', justifyContent: 'flex-start'}} onClick={() => setSelectedHistory(file)}>
                    📄 {file}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}

      {activeTab === 'active' && processingFile && progressData[processingFile] && progressData[processingFile].status !== 'completed' && progressData[processingFile].status !== 'error' && (
        <section className="glass-panel animate-fade-in" style={{marginBottom: '2rem'}}>
          <h2 style={{marginTop: 0, fontSize: '1.2rem', display: 'flex', alignItems: 'center', gap: '0.5rem'}}>
            <Activity size={20} className="spinning" color="var(--primary-color)" /> Analyzing: <span style={{color: 'var(--primary-color)'}}>{processingFile}</span>
          </h2>
          <div style={{background: 'rgba(0,0,0,0.3)', borderRadius: '8px', padding: '1rem'}}>
            <div style={{display: 'flex', justifyContent: 'space-between', marginBottom: '0.5rem', fontSize: '0.9rem'}}>
              <span>Status: <strong style={{textTransform: 'capitalize', color: 'var(--text-main)'}}>{progressData[processingFile].status}</strong></span>
              <span>{progressData[processingFile].current} / {progressData[processingFile].total} Frames Processed</span>
            </div>
            <div style={{width: '100%', background: 'rgba(255,255,255,0.1)', height: '12px', borderRadius: '6px', overflow: 'hidden'}}>
              <div style={{
                height: '100%', 
                background: 'var(--primary-color)', 
                width: `${progressData[processingFile].total > 0 ? (progressData[processingFile].current / progressData[processingFile].total) * 100 : (progressData[processingFile].status === 'extracting' ? 100 : 0)}%`,
                transition: 'width 0.5s ease-out'
              }} className={progressData[processingFile].status === 'extracting' ? 'progress-pulse' : ''} />
            </div>
          </div>
        </section>
      )}

      {(activeTab === 'active' || (activeTab === 'history' && selectedHistory)) && (
        <>
          {activeTab === 'history' && selectedHistory && (
            <div className="animate-fade-in" style={{marginBottom: '1rem', display: 'flex', justifyContent: 'space-between', alignItems: 'center'}}>
                <h2 style={{marginTop: 0, marginBottom: 0, fontSize: '1.5rem'}}>Viewing Record: <span style={{color: 'var(--primary-color)'}}>{selectedHistory}</span></h2>
                <button className="btn" onClick={() => setSelectedHistory(null)}>← Back to History</button>
            </div>
          )}
          <section className="grid-3 animate-fade-in" style={{animationDelay: '0.1s'}}>
            <MetricsCard 
              title="Stream Health" 
              value={`${currentStats.health_score}%`} 
              icon={<Activity size={24} color="var(--primary-color)" />}
              trend={currentStats.health_score > 90 ? "positive" : "negative"}
            />
            <MetricsCard 
              title="Total Frames Analyzed" 
              value={currentStats.total_frames} 
              icon={<CheckCircle size={24} />}
            />
            <MetricsCard 
              title="Anomalies Detected" 
              value={currentStats.issues_count} 
              icon={<ShieldAlert size={24} color={currentStats.issues_count > 0 ? "var(--error-color)" : "var(--primary-color)"} />}
            />
          </section>

      <section className="grid-2-1 animate-fade-in" style={{animationDelay: '0.2s'}}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
          <div className="glass-panel" style={{minHeight: '200px'}}>
            <h2 style={{marginTop: 0}}>Stream Integrity Timeline</h2>
            <Timeline logs={currentLogs} />
          </div>
          <div className="glass-panel" style={{flex: 1}}>
            <h2 style={{marginTop: 0}}>Detection Logs</h2>
            <LogViewer logs={currentLogs} apiUrl={API_URL} />
          </div>
        </div>
        
        <div className="glass-panel">
          <h2 style={{marginTop: 0}}>In-Depth Intelligence</h2>
          <p style={{color: 'var(--text-muted)'}}>
            This concept dashboard simulates real-time ingestion of HLS/MPEG-TS/MP4 feeds. 
            Local models analyze an optimized frame rate (1 FPS) to detect macroblocking, black screens, and slates securely.
          </p>
          <div style={{ marginTop: '2rem', background: 'rgba(0,0,0,0.3)', padding: '1rem', borderRadius: '8px', border: '1px solid var(--surface-border)' }}>
            <h3 style={{marginTop: 0, fontSize: '0.9rem', color: 'var(--primary-color)'}}>Node Activity Monitor</h3>
            {currentLogs.length > 0 ? (
              <ul style={{listStyle: 'none', padding: 0, fontSize: '0.85rem', color: 'var(--text-muted)'}}>
                <li style={{marginBottom: '0.5rem'}}>🟢 Source Node ID: {currentLogs[0]?.node_source}</li>
                <li style={{marginBottom: '0.5rem'}}>🟢 Backbone Relay: {currentLogs[0]?.node_backbone}</li>
                <li>🟢 Edge Dest: {currentLogs[0]?.node_dest}</li>
              </ul>
            ) : <p style={{fontSize: '0.85rem'}}>Awaiting stream...</p>}
          </div>
        </div>
      </section>

      <section className="animate-fade-in" style={{ animationDelay: '0.3s', marginTop: '1.5rem' }}>
        <SystemResources apiUrl={API_URL} />
      </section>
      </>
      )}

      <style>{`
        .spinning { animation: spin 1s linear infinite; }
        @keyframes spin { 100% { transform: rotate(360deg); } }
        .progress-pulse { animation: pulse 2s ease-in-out infinite; }
        @keyframes pulse { 0% { opacity: 0.5; } 50% { opacity: 1; } 100% { opacity: 0.5; } }
      `}</style>
    </div>
  );
}

export default App;

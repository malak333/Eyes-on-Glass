import React, { useState, useEffect } from 'react';
import { AreaChart, Area, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';
import { Cpu, MemoryStick, MonitorPlay } from 'lucide-react';

const SystemResources = ({ apiUrl }) => {
  const [data, setData] = useState({ "1m": [], "5m": [], "10m": [], "20m": [], "30m": [] });
  const [timeRange, setTimeRange] = useState("5m");
  const [ollamaStatus, setOllamaStatus] = useState("unknown");
  
  useEffect(() => {
    const fetchResources = async () => {
      try {
        const res = await fetch(`${apiUrl}/system/resources`);
        const json = await res.json();
        setData(json);
      } catch (err) {
        console.error("Failed to fetch system resources:", err);
      }
    };

    const fetchOllama = async () => {
      try {
        const res = await fetch(`${apiUrl}/system/ollama_status`);
        const json = await res.json();
        setOllamaStatus(json.status);
      } catch {
        setOllamaStatus("stopped");
      }
    };
    
    fetchResources();
    fetchOllama();
    const interval = setInterval(fetchResources, 5000);
    const ollamaInterval = setInterval(fetchOllama, 10000); // Check every 10 seconds
    return () => {
      clearInterval(interval);
      clearInterval(ollamaInterval);
    };
  }, [apiUrl]);

  const currentData = data[timeRange] || [];
  
  // Format the timestamp to a readable time string
  const formatTime = (unixTime) => {
    const d = new Date(unixTime * 1000);
    return d.toLocaleTimeString([], { hour12: false, minute: '2-digit', second: '2-digit' });
  };

  // Get current exact footprint if available
  const latestPoint = currentData.length > 0 ? currentData[currentData.length - 1] : { cpu: 0, memory: 0, gpu: 0 };

  return (
    <div className="glass-panel animate-fade-in" style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1.5rem' }}>
        
        <div style={{ display: 'flex', alignItems: 'center', gap: '1rem' }}>
          <h2 style={{ marginTop: 0, marginBottom: 0 }}>System Resources</h2>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', background: 'rgba(255,255,255,0.05)', padding: '0.25rem 0.75rem', borderRadius: '20px', fontSize: '0.85rem' }}>
            <div style={{ width: '8px', height: '8px', borderRadius: '50%', background: ollamaStatus === 'running' ? '#10b981' : (ollamaStatus === 'stopped' ? '#ef4444' : '#64748b') }}></div>
            <span>Ollama: {ollamaStatus === 'running' ? 'Running' : (ollamaStatus === 'stopped' ? 'Stopped' : 'Checking...')}</span>
          </div>
        </div>
        
        <div style={{ display: 'flex', gap: '0.25rem', background: 'rgba(0,0,0,0.3)', padding: '0.25rem', borderRadius: '8px' }}>
          {["1m", "5m", "10m", "20m", "30m"].map(range => (
            <button
              key={range}
              onClick={() => setTimeRange(range)}
              style={{
                background: timeRange === range ? 'var(--primary-color)' : 'transparent',
                color: timeRange === range ? '#fff' : 'var(--text-muted)',
                border: 'none',
                padding: '0.25rem 0.75rem',
                borderRadius: '6px',
                cursor: 'pointer',
                fontSize: '0.85rem',
                fontWeight: 'bold',
                transition: 'all 0.2s ease'
              }}
            >
              {range}
            </button>
          ))}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '1rem', marginBottom: '1.5rem' }}>
        <div style={{ background: 'rgba(255,255,255,0.03)', padding: '1rem', borderRadius: '8px', border: '1px solid rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', gap: '1rem' }}>
          <Cpu color="#3b82f6" />
          <div>
            <div style={{ fontSize: '0.8rem', color: 'var(--text-muted)' }}>CPU Utilization</div>
            <div style={{ fontSize: '1.25rem', fontWeight: 'bold' }}>{latestPoint.cpu}%</div>
          </div>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.03)', padding: '1rem', borderRadius: '8px', border: '1px solid rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', gap: '1rem' }}>
          <MemoryStick color="#10b981" />
          <div>
            <div style={{ fontSize: '0.8rem', color: 'var(--text-muted)' }}>Memory (RSS)</div>
            <div style={{ fontSize: '1.25rem', fontWeight: 'bold' }}>{latestPoint.memory} MB</div>
          </div>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.03)', padding: '1rem', borderRadius: '8px', border: '1px solid rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', gap: '1rem' }}>
          <MonitorPlay color="#8b5cf6" />
          <div>
            <div style={{ fontSize: '0.8rem', color: 'var(--text-muted)' }}>App GPU Load</div>
            <div style={{ fontSize: '1.25rem', fontWeight: 'bold' }}>{latestPoint.gpu}%</div>
          </div>
        </div>
      </div>

      <div style={{ flex: 1, width: '100%', minHeight: '200px' }}>
        {currentData.length > 0 ? (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '1rem', height: '100%' }}>
            
            {/* CPU Chart */}
            <div style={{ background: 'rgba(0,0,0,0.2)', borderRadius: '8px', padding: '1rem', display: 'flex', flexDirection: 'column' }}>
              <div style={{ fontSize: '0.85rem', color: 'var(--text-muted)', marginBottom: '0.5rem' }}>CPU History (%)</div>
              <div style={{ flex: 1, minHeight: '150px' }}>
                <ResponsiveContainer width="100%" height="100%">
                  <AreaChart data={currentData} margin={{ top: 5, right: 0, left: -25, bottom: 0 }}>
                    <defs>
                      <linearGradient id="colorCpu" x1="0" y1="0" x2="0" y2="1">
                        <stop offset="5%" stopColor="#3b82f6" stopOpacity={0.8}/>
                        <stop offset="95%" stopColor="#3b82f6" stopOpacity={0}/>
                      </linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.1)" vertical={false} />
                    <XAxis dataKey="timestamp" tickFormatter={formatTime} stroke="rgba(255,255,255,0.3)" tick={{fill: 'rgba(255,255,255,0.5)', fontSize: 10}} tickMargin={5} />
                    <YAxis stroke="rgba(255,255,255,0.3)" tick={{fill: 'rgba(255,255,255,0.5)', fontSize: 10}} />
                    <Tooltip 
                      contentStyle={{ backgroundColor: 'rgba(15, 23, 42, 0.9)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '8px', fontSize: '12px' }}
                      itemStyle={{ fontWeight: 'bold' }}
                      labelFormatter={(val) => `Time: ${formatTime(val)}`}
                    />
                    <Area type="monotone" dataKey="cpu" stroke="#3b82f6" fillOpacity={1} fill="url(#colorCpu)" name="CPU %" />
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            </div>

            {/* Memory Chart */}
            <div style={{ background: 'rgba(0,0,0,0.2)', borderRadius: '8px', padding: '1rem', display: 'flex', flexDirection: 'column' }}>
              <div style={{ fontSize: '0.85rem', color: 'var(--text-muted)', marginBottom: '0.5rem' }}>Memory History (MB)</div>
              <div style={{ flex: 1, minHeight: '150px' }}>
                <ResponsiveContainer width="100%" height="100%">
                  <AreaChart data={currentData} margin={{ top: 5, right: 0, left: -25, bottom: 0 }}>
                    <defs>
                      <linearGradient id="colorMem" x1="0" y1="0" x2="0" y2="1">
                        <stop offset="5%" stopColor="#10b981" stopOpacity={0.8}/>
                        <stop offset="95%" stopColor="#10b981" stopOpacity={0}/>
                      </linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.1)" vertical={false} />
                    <XAxis dataKey="timestamp" tickFormatter={formatTime} stroke="rgba(255,255,255,0.3)" tick={{fill: 'rgba(255,255,255,0.5)', fontSize: 10}} tickMargin={5} />
                    <YAxis stroke="rgba(255,255,255,0.3)" tick={{fill: 'rgba(255,255,255,0.5)', fontSize: 10}} />
                    <Tooltip 
                      contentStyle={{ backgroundColor: 'rgba(15, 23, 42, 0.9)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '8px', fontSize: '12px' }}
                      itemStyle={{ fontWeight: 'bold' }}
                      labelFormatter={(val) => `Time: ${formatTime(val)}`}
                    />
                    <Area type="monotone" dataKey="memory" stroke="#10b981" fillOpacity={1} fill="url(#colorMem)" name="Memory (MB)" />
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            </div>

            {/* GPU Chart */}
            <div style={{ background: 'rgba(0,0,0,0.2)', borderRadius: '8px', padding: '1rem', display: 'flex', flexDirection: 'column' }}>
              <div style={{ fontSize: '0.85rem', color: 'var(--text-muted)', marginBottom: '0.5rem' }}>GPU History (%)</div>
              <div style={{ flex: 1, minHeight: '150px' }}>
                <ResponsiveContainer width="100%" height="100%">
                  <AreaChart data={currentData} margin={{ top: 5, right: 0, left: -25, bottom: 0 }}>
                    <defs>
                      <linearGradient id="colorGpu" x1="0" y1="0" x2="0" y2="1">
                        <stop offset="5%" stopColor="#8b5cf6" stopOpacity={0.8}/>
                        <stop offset="95%" stopColor="#8b5cf6" stopOpacity={0}/>
                      </linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.1)" vertical={false} />
                    <XAxis dataKey="timestamp" tickFormatter={formatTime} stroke="rgba(255,255,255,0.3)" tick={{fill: 'rgba(255,255,255,0.5)', fontSize: 10}} tickMargin={5} />
                    <YAxis stroke="rgba(255,255,255,0.3)" tick={{fill: 'rgba(255,255,255,0.5)', fontSize: 10}} />
                    <Tooltip 
                      contentStyle={{ backgroundColor: 'rgba(15, 23, 42, 0.9)', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '8px', fontSize: '12px' }}
                      itemStyle={{ fontWeight: 'bold' }}
                      labelFormatter={(val) => `Time: ${formatTime(val)}`}
                    />
                    <Area type="monotone" dataKey="gpu" stroke="#8b5cf6" fillOpacity={1} fill="url(#colorGpu)" name="GPU %" />
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            </div>

          </div>
        ) : (
          <div style={{ display: 'flex', height: '100%', justifyContent: 'center', alignItems: 'center', color: 'var(--text-muted)' }}>
            Collecting telemetry...
          </div>
        )}
      </div>
    </div>
  );
};

export default SystemResources;

import React, { useRef, useState } from 'react';
import { UploadCloud, Radio } from 'lucide-react';

export default function VideoUploader({ onUploadSuccess, onStopLive, apiUrl }) {
  const fileInputRef = useRef(null);
  const [uploading, setUploading] = useState(false);
  const [liveUri, setLiveUri] = useState('udp://@227.0.0.1:4001');
  const [isLive, setIsLive] = useState(false);

  const handleFileChange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;

    setUploading(true);
    const formData = new FormData();
    formData.append("file", file);

    try {
      const response = await fetch(`${apiUrl}/upload`, {
        method: "POST",
        body: formData,
      });
      if (response.ok) {
        onUploadSuccess(file.name);
      } else {
        alert("Upload failed.");
      }
    } catch (err) {
      console.error(err);
      alert("Upload failed. Ensure backend is running.");
    } finally {
      setUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  };

  const handleStartLive = async () => {
    if (!liveUri) return;
    setUploading(true);
    setIsLive(true);
    try {
      const response = await fetch(`${apiUrl}/live/start`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ uri: liveUri }),
      });
      if (response.ok) {
        const data = await response.json();
        onUploadSuccess(data.session_name || liveUri);
      } else {
        alert("Live start failed.");
        setIsLive(false);
      }
    } catch (err) {
      console.error(err);
      alert("Live start failed.");
      setIsLive(false);
    } finally {
      setUploading(false);
    }
  };

  const handleStopLive = async () => {
    try {
      await fetch(`${apiUrl}/live/stop`, { method: "POST" });
      setIsLive(false);
      if (onStopLive) onStopLive();
    } catch (err) {
      console.error(err);
    }
  };

  return (
    <div style={{ display: 'flex', gap: '1rem', alignItems: 'center' }}>
      <input
        type="file"
        accept="video/mp4,video/mp2t,.ts,.mp4"
        style={{ display: 'none' }}
        ref={fileInputRef}
        onChange={handleFileChange}
      />
      <button
        className="btn primary"
        onClick={() => fileInputRef.current?.click()}
        disabled={uploading || isLive}
      >
        <UploadCloud size={18} />
        {uploading && !isLive ? 'Uploading...' : 'Upload File'}
      </button>

      <div style={{ display: 'flex', gap: '0.5rem', background: 'rgba(255,255,255,0.05)', padding: '4px 8px', borderRadius: '8px' }}>
        <input
          type="text"
          value={liveUri}
          onChange={(e) => setLiveUri(e.target.value)}
          placeholder="udp://..."
          style={{ background: 'transparent', border: 'none', color: 'white', borderBottom: '1px solid rgba(255,255,255,0.2)', padding: '4px', outline: 'none' }}
          disabled={isLive}
        />
        {!isLive ? (
          <button className="btn primary" onClick={handleStartLive} disabled={uploading}>
            <Radio size={18} />
            Start Live
          </button>
        ) : (
          <button className="btn" style={{ background: 'var(--error-color)' }} onClick={handleStopLive}>
            Stop Live
          </button>
        )}
      </div>
    </div>
  );
}

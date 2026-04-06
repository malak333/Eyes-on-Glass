import React, { useRef, useState } from 'react';
import { UploadCloud } from 'lucide-react';

export default function VideoUploader({ onUploadSuccess, apiUrl }) {
  const fileInputRef = useRef(null);
  const [uploading, setUploading] = useState(false);

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

  return (
    <div>
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
        disabled={uploading}
      >
        <UploadCloud size={18} />
        {uploading ? 'Processing Stream...' : 'Monitor Stream'}
      </button>
    </div>
  );
}

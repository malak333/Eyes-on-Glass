import os
import asyncio
from fastapi import FastAPI, UploadFile, File, BackgroundTasks, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
from db.database import init_db, get_db, VideoLog
from core.video_pipeline import extract_and_analyze, analysis_progress, UPLOADS_DIR, THUMBNAILS_DIR
from app.system_monitor import resource_monitor_task, get_aggregated_stats
import httpx

from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    asyncio.create_task(resource_monitor_task())
    yield


app = FastAPI(title="Eyes on Glass - AI Video Monitoring API", lifespan=lifespan)

# Allow CORS for Vite frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(UPLOADS_DIR, exist_ok=True)
os.makedirs(THUMBNAILS_DIR, exist_ok=True)

# Mount thumbnails to serve them to the frontend
app.mount(
    "/thumbnails",
    StaticFiles(
        directory=THUMBNAILS_DIR),
    name="thumbnails")


@app.post("/upload")
async def upload_video(
        background_tasks: BackgroundTasks,
        file: UploadFile = File(...)):
    """Uploads a .ts or .mp4 file and begins the AI processing pipeline."""
    file_path = os.path.join(UPLOADS_DIR, file.filename)

    with open(file_path, "wb") as buffer:
        buffer.write(await file.read())

    # Pre-set progress to 'extracting' immediately so the frontend knows
    # processing started
    analysis_progress[file.filename] = {
        "status": "extracting", "current": 0, "total": 0}

    # Clear old database logs if this file is being re-uploaded
    from db.database import SessionLocal
    db = SessionLocal()
    try:
        db.query(VideoLog).filter(
            VideoLog.video_filename == file.filename).delete()
        db.commit()
    finally:
        db.close()

    # Trigger background processing
    background_tasks.add_task(extract_and_analyze, file.filename)

    return {"message": f"Successfully uploaded {file.filename}. Processing started."}


@app.get("/logs")
def get_logs(db: Session = Depends(get_db)):
    """Retrieves the aggregated 'source, backbone, dest' frame logs."""
    logs = db.query(VideoLog).order_by(VideoLog.timestamp_sec.asc()).all()

    # Process into nice JSON output
    output = []
    for log in logs:
        output.append({
            "id": log.id,
            "filename": log.video_filename,
            "timestamp_sec": log.timestamp_sec,
            "node_source": log.node_source,
            "node_backbone": log.node_backbone,
            "node_dest": log.node_dest,
            "issue_type": log.issue_type,
            "issue_score": log.issue_score,
            "thumbnail_url": f"/thumbnails/{log.thumbnail_path}" if log.thumbnail_path else None,
            "created_at": log.created_at.isoformat() if log.created_at else None
        })
    return {"logs": output}


@app.get("/stats")
def get_stats(db: Session = Depends(get_db)):
    """Retrieves macro stats for the dashboard."""
    logs = db.query(VideoLog).all()
    total_frames = len(logs)
    if total_frames == 0:
        return {"total_frames": 0, "issues_count": 0, "health_score": 100}

    issues_count = len([log_entry for log_entry in logs if log_entry.issue_type != "ok"])
    health_score = max(0, 100 - (issues_count / total_frames * 100))

    return {
        "total_frames": total_frames,
        "issues_count": issues_count,
        "health_score": round(health_score, 2)
    }


@app.get("/system/resources")
def get_system_resources():
    """Retrieves the aggregated system resource usage over time."""
    return get_aggregated_stats()


@app.get("/system/ollama_status")
async def check_ollama_status():
    """Checks if the local Ollama instance is running."""
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get("http://localhost:11434/", timeout=2.0)
            if resp.status_code == 200:
                return {"status": "running"}
    except Exception:
        pass
    return {"status": "stopped"}


@app.get("/progress")
def get_progress():
    """Retrieves the analysis progress dictionary."""
    return analysis_progress


if __name__ == "__main__":
    import uvicorn
    # Make sure this runs correctly when you execute main.py directly
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)

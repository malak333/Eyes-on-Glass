import os
import asyncio
import ffmpeg
import uuid
import math
import re
from db.database import SessionLocal, VideoLog
from core.analyzers.cv_analyzer import analyze_frame
from core.analyzers.ai_analyzer import analyze_frame_ai

THUMBNAILS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "thumbnails")
UPLOADS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "uploads")

# Store background processing tracking progress
# Format: { "video_filename.mp4": {"status": "extracting|analyzing|completed|error", "current": 0, "total": 0} }
analysis_progress = {}

# Ensure thumbnails directory exists
os.makedirs(THUMBNAILS_DIR, exist_ok=True)

async def detect_silence(video_path: str):
    cmd = [
        "ffmpeg", "-i", video_path,
        "-af", "silencedetect=noise=-30dB:d=0.5",
        "-f", "null", "-"
    ]
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    _, stderr = await process.communicate()
    stderr_str = stderr.decode()
    
    silence_intervals = []
    start_pattern = re.compile(r"silence_start: ([\d\.]+)")
    end_pattern = re.compile(r"silence_end: ([\d\.]+)")
    
    current_start = None
    for line in stderr_str.split('\n'):
        start_match = start_pattern.search(line)
        if start_match:
            current_start = float(start_match.group(1))
            
        end_match = end_pattern.search(line)
        if end_match and current_start is not None:
            end_time = float(end_match.group(1))
            silence_intervals.append((current_start, end_time))
            current_start = None
            
    return silence_intervals

async def extract_and_analyze(video_filename: str):
    global analysis_progress
    analysis_progress[video_filename] = {"status": "extracting", "current": 0, "total": 0}
    
    video_path = os.path.join(UPLOADS_DIR, video_filename)
    if not os.path.exists(video_path):
        print(f"Video file not found: {video_path}")
        analysis_progress[video_filename]["status"] = "error"
        return

    # Probe video to get duration
    try:
        probe = ffmpeg.probe(video_path)
        video_info = next(s for s in probe['streams'] if s['codec_type'] == 'video')
        duration = float(probe['format']['duration'])
    except Exception as e:
        print(f"Error probing video {video_path}: {e}")
        return

    # For MVP, we will extract 1 frame per second
    fps_to_extract = 1.0
    
    # We will use ffmpeg to output frames as JPEGs into the thumbnails directory
    # Format: filename_timestamp.jpg (for this MVP, using %d and we'll calculate timestamp)
    frame_pattern = os.path.join(THUMBNAILS_DIR, f"{video_filename}_frame_%04d.jpg")
    try:
        (
            ffmpeg
            .input(video_path)
            .filter('fps', fps=fps_to_extract)
            .output(frame_pattern, vframes=int(duration * fps_to_extract), **{'qscale:v': 2})
            .overwrite_output()
            .run(quiet=True)
        )
    except ffmpeg.Error as e:
        print(f"Ffmpeg error: {e}")
        analysis_progress[video_filename]["status"] = "error"
        return

    # Detect audio dropouts using async ffmpeg process
    silence_intervals = await detect_silence(video_path)
    print(f"Detected silence intervals: {silence_intervals}")

    # Now, process the extracted frames
    # Count generated frames
    frame_files = sorted([f for f in os.listdir(THUMBNAILS_DIR) if f.startswith(f"{video_filename}_frame_")])
    
    analysis_progress[video_filename]["status"] = "analyzing"
    analysis_progress[video_filename]["total"] = len(frame_files)
    
    db = SessionLocal()
    for index, frame_file in enumerate(frame_files):
        analysis_progress[video_filename]["current"] = index + 1
        timestamp_sec = float(index) / fps_to_extract
        frame_path = os.path.join(THUMBNAILS_DIR, frame_file)
        
        # 1. Run CV Analysis
        cv_results = analyze_frame(frame_path)
        
        # 2. Run AI Analysis
        ai_results = await analyze_frame_ai(frame_path)
        
        # Determine issue type
        issue_type = "ok"
        confidence = 1.0
        
        if cv_results.get("is_black_screen"):
            issue_type = "black_screen"
        elif ai_results.get("is_slate"):
            issue_type = "slate"
            confidence = ai_results.get("confidence", 0.8)
        elif cv_results.get("is_blurry"):
            # Mocking macroblocking if it is highly blurry
            issue_type = "macroblocking"
            confidence = 0.7
        else:
            # Check if this frame's timestamp falls within any silence interval
            is_silent = any(start <= timestamp_sec <= end for start, end in silence_intervals)
            if is_silent:
                issue_type = "no_audio"
                confidence = 1.0
            
        # Add to DB
        # To simulate the network log requirement ("source, backbone, dest")
        log_entry = VideoLog(
            video_filename=video_filename,
            timestamp_sec=timestamp_sec,
            node_source="Primary-Ingest-A",
            node_backbone="East-Backbone-2",
            node_dest="Distribution-Node",
            issue_type=issue_type,
            issue_score=confidence,
            thumbnail_path=frame_file
        )
        db.add(log_entry)
        db.commit()
        
    db.close()
    analysis_progress[video_filename]["status"] = "completed"
    print(f"Finished processing {video_filename}")

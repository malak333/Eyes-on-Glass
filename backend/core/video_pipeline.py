import os
import asyncio
import ffmpeg
import re
from db.database import SessionLocal, VideoLog
from core.analyzers.cv_analyzer import analyze_frame
from core.analyzers.ai_analyzer import analyze_frame_ai

THUMBNAILS_DIR = os.path.join(
    os.path.dirname(
        os.path.dirname(
            os.path.dirname(__file__))),
    "thumbnails")
UPLOADS_DIR = os.path.join(
    os.path.dirname(
        os.path.dirname(
            os.path.dirname(__file__))),
    "uploads")

# Store background processing tracking progress
# Format: { "video_filename.mp4": {"status": "extracting|analyzing|completed|error", "current": 0, "total": 0} }
analysis_progress = {}

# Ensure thumbnails directory exists
os.makedirs(THUMBNAILS_DIR, exist_ok=True)


async def detect_pts_offset(video_path: str, threshold: float = 0.1) -> bool:
    """
    Checks the Presentation Time Stamp (PTS) offset between the first video and audio streams at the container level.
    Returns True if an issue > threshold is detected, indicating a multiplexing lip sync fault.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "stream=codec_type,start_time",
        "-of", "json",
        video_path
    ]
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    stdout, _ = await process.communicate()

    try:
        import json
        data = json.loads(stdout)
        streams = data.get("streams", [])

        v_start = None
        a_start = None

        for s in streams:
            if s.get("codec_type") == "video" and v_start is None:
                v_start = float(s.get("start_time", 0))
            elif s.get("codec_type") == "audio" and a_start is None:
                a_start = float(s.get("start_time", 0))

        if v_start is not None and a_start is not None:
            offset = abs(v_start - a_start)
            if offset > threshold:
                print(f"Container PTS offset detected: {offset}s")
                return True
    except Exception as e:
        print(f"Error parsing ffprobe PTS Output: {e}")

    return False


async def detect_lip_sync_ai(video_path: str) -> bool:
    """
    Stub for Approach 2: AI Lip Sync Analysis.
    This would run a deep learning model (e.g., SyncNet, Wav2Lip Discriminator)
    that correlates generated face bounding boxes with audio phonemes to detect baked-in sync errors.
    Returns True if an AI model determines a lip sync issue.
    """
    # For MVP: Return False since we do not have a SyncNet pipeline configured
    # yet.
    return False


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
    analysis_progress[video_filename] = {
        "status": "extracting", "current": 0, "total": 0}

    video_path = os.path.join(UPLOADS_DIR, video_filename)
    if not os.path.exists(video_path):
        print(f"Video file not found: {video_path}")
        analysis_progress[video_filename]["status"] = "error"
        return

    # Probe video to get duration
    try:
        probe = ffmpeg.probe(video_path)
        duration = float(probe['format']['duration'])
    except Exception as e:
        print(f"Error probing video {video_path}: {e}")
        return

    # For MVP, we will extract 1 frame per second
    fps_to_extract = 1.0

    # Lip Sync Detection
    # 1. Approach 1 (Container PTS Check)
    has_lip_sync_issue = await detect_pts_offset(video_path)
    if not has_lip_sync_issue:
        # 2. Approach 2 (AI Lip Sync Content Check)
        has_lip_sync_issue = await detect_lip_sync_ai(video_path)
        if has_lip_sync_issue:
            print(f"AI Lip Sync Issue detected for {video_filename}")
    else:
        print(f"Container Lip Sync Issue detected for {video_filename}")

    # Clear any existing frames for this video to avoid bugs on re-upload
    for f in os.listdir(THUMBNAILS_DIR):
        if f.startswith(f"{video_filename}_frame_"):
            try:
                os.remove(os.path.join(THUMBNAILS_DIR, f))
            except Exception as e:
                print(f"Error removing old frame {f}: {e}")

    # We will use ffmpeg to output frames as JPEGs into the thumbnails directory
    # Format: filename_timestamp.jpg (for this MVP, using %d and we'll
    # calculate timestamp)
    frame_pattern = os.path.join(
        THUMBNAILS_DIR,
        f"{video_filename}_frame_%04d.jpg")
    try:
        (ffmpeg .input(video_path) .filter('fps',
                                           fps=fps_to_extract) .output(frame_pattern,
                                                                       vframes=int(duration * fps_to_extract),
                                                                       **{'qscale:v': 2}) .overwrite_output() .run(quiet=True))
    except ffmpeg.Error as e:
        print(f"Ffmpeg error: {e}")
        analysis_progress[video_filename]["status"] = "error"
        return

    # Detect audio dropouts using async ffmpeg process
    silence_intervals = await detect_silence(video_path)
    print(f"Detected silence intervals: {silence_intervals}")

    # Now, process the extracted frames
    # Count generated frames
    frame_files = sorted([f for f in os.listdir(
        THUMBNAILS_DIR) if f.startswith(f"{video_filename}_frame_")])

    analysis_progress[video_filename]["status"] = "analyzing"
    analysis_progress[video_filename]["total"] = len(frame_files)

    db = SessionLocal()
    for index, frame_file in enumerate(frame_files):
        analysis_progress[video_filename]["current"] = index + 1
        timestamp_sec = float(index) / fps_to_extract
        frame_path = os.path.join(THUMBNAILS_DIR, frame_file)

        # 1. Run CV Analysis first
        cv_results = analyze_frame(frame_path)

        issue_type = "ok"
        confidence = 1.0

        # Check audio silence first since it's pre-calculated
        is_silent = any(
            start <= timestamp_sec <= end for start,
            end in silence_intervals)

        macro_confidence = max(
            0.0, 1.0 - (cv_results.get("laplacian_variance", 50.0) / 50.0))

        if cv_results.get("is_black_screen"):
            issue_type = "black_screen"
        elif cv_results.get("is_blurry") and macro_confidence >= 0.80:
            issue_type = "macroblocking"
            confidence = round(macro_confidence, 2)
        elif is_silent:
            issue_type = "no_audio"
            confidence = 1.0
        elif has_lip_sync_issue:
            issue_type = "lip_sync"
            confidence = 0.95
        else:
            # 2. If no CV/Audio issues, run lighter AI Analysis (moondream)
            ai_results = await analyze_frame_ai(frame_path, model="moondream")

            if ai_results.get("is_slate"):
                issue_type = "slate"
                confidence = ai_results.get("confidence", 0.85)
            else:
                # 3. If Moondream does NOT detect anything, fallback to heavier
                # LLaVA for double check
                fallback_ai_results = await analyze_frame_ai(frame_path, model="llava")
                if fallback_ai_results.get("is_slate"):
                    issue_type = "slate"
                    confidence = fallback_ai_results.get("confidence", 0.85)

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

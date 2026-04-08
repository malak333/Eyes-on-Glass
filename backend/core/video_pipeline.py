import os
import asyncio
import ffmpeg
import re
import time
import wave
import struct
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
# Format: { "video_filename.mp4": {"status": "extracting|analyzing|completed|error",
# "current": 0, "total": 0} }
analysis_progress = {}

# Ensure thumbnails directory exists
os.makedirs(THUMBNAILS_DIR, exist_ok=True)


async def detect_pts_offset(video_path: str, threshold: float = 0.1) -> bool:
    """
    Checks the Presentation Time Stamp (PTS) offset between the first video
    and audio streams at the container level.
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
            # Lip sync errors usually visible > 0.1s. Broadcasts can be slightly off.
            # Using 0.25s threshold for all files to be safe
            active_threshold = 0.25
            if offset > active_threshold:
                print(f"Container PTS offset detected: {offset}s")
                return True
    except Exception as e:
        print(f"Error parsing ffprobe PTS Output: {e}")

    return False


async def detect_lip_sync_ai(video_path: str) -> bool:
    """
    Stub for Approach 2: AI Lip Sync Analysis.
    This would run a deep learning model (e.g., SyncNet, Wav2Lip Discriminator)
    that correlates generated face bounding boxes with audio phonemes to detect
    baked-in sync errors.
    Returns True if an AI model determines a lip sync issue.
    """
    # For MVP: Return False since we do not have a SyncNet pipeline configured
    # yet.
    return False


async def detect_audio_anomalies(
    video_path: str,
    static_hz_threshold: float = 0.2,
    flat_factor_threshold: float = 10.0
) -> tuple:
    """
    Detects if the audio exhibits:
    1. high zero-crossing rates indicative of static/white noise.
    2. high flat factor indicative of clipping/buzzing audio.
    """
    cmd = [
        "ffmpeg", "-i", video_path,
        "-vn",
        "-map", "0:a:0?",  # use first audio stream if it exists
        "-af", "astats",
        "-f", "null", "-"
    ]
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    _, stderr = await process.communicate()
    stderr_str = stderr.decode()

    import re
    zc_pattern = re.compile(r"Zero crossings rate:\s+([\d\.]+)")
    flat_pattern = re.compile(r"Flat factor:\s+([\d\.]+)")

    zc_rates = zc_pattern.findall(stderr_str)
    flat_factors = flat_pattern.findall(stderr_str)

    has_static = False
    has_buzzing = False

    if zc_rates:
        try:
            max_zc = max([float(r) for r in zc_rates])
            if max_zc > static_hz_threshold:
                print(f"Static audio detected with max zero crossing rate: {max_zc}")
                has_static = True
        except Exception as e:
            print(f"Error parsing static audio detection: {e}")

    if flat_factors:
        try:
            max_flat = max([float(f) for f in flat_factors])
            if max_flat > flat_factor_threshold:
                print(f"Buzzing audio detected with max flat factor: {max_flat}")
                has_buzzing = True
        except Exception as e:
            print(f"Error parsing buzzing audio detection: {e}")

    return has_static, has_buzzing


async def detect_audio_clicks(video_path: str) -> bool:
    """
    Detects audio clicking using discrete volume jump analysis.
    """

    import uuid
    wav_path = f"/tmp/audio_click_detect_{uuid.uuid4().hex}.wav"
    cmd = [
        "ffmpeg", "-i", video_path,
        "-vn", "-acodec", "pcm_s16le", "-ac", "1", "-ar", "44100",
        wav_path, "-y", "-v", "quiet"
    ]

    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    await process.communicate()

    if not os.path.exists(wav_path):
        return False

    try:
        import numpy as np
        with wave.open(wav_path, 'rb') as w:
            n_frames = w.getnframes()
            if n_frames == 0:
                return False
            frames = w.readframes(n_frames)
            # Use numpy for rapid computation
            data = np.frombuffer(frames, dtype=np.int16)

        if len(data) < 2:
            return False

        data_f = data.astype(np.float32)
        diffs = np.abs(np.diff(data_f))
        
        mean_diff = np.mean(diffs)
        std_diff = np.std(diffs)
        
        clicks = diffs[diffs > mean_diff + 20 * std_diff]
        max_diff = np.max(diffs) if len(diffs) > 0 else 0

        if len(clicks) > 10 and max_diff > 2000 and (max_diff / (mean_diff + 1e-5)) > 100:
            print(f"Audio clicking detected: {len(clicks)} clicks, max diff {max_diff}")
            return True
    except Exception as e:
        print(f"Error detecting audio clicks: {e}")
    finally:
        if os.path.exists(wav_path):
            try:
                os.remove(wav_path)
            except Exception:
                pass

    return False


async def detect_silence(video_path: str):
    cmd = [
        "ffmpeg", "-i", video_path,
        "-vn",
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

    if current_start is not None:
        silence_intervals.append((current_start, float('inf')))

    return silence_intervals


async def detect_freeze(video_path: str):
    cmd = [
        "ffmpeg", "-i", video_path,
        "-an",
        "-vf", "freezedetect=n=-60dB:d=2.0",
        "-f", "null", "-"
    ]
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    _, stderr = await process.communicate()
    stderr_str = stderr.decode()

    freeze_intervals = []
    start_pattern = re.compile(r"lavfi\.freezedetect\.freeze_start: ([\d\.]+)")
    end_pattern = re.compile(r"lavfi\.freezedetect\.freeze_end: ([\d\.]+)")

    current_start = None
    for line in stderr_str.split('\n'):
        start_match = start_pattern.search(line)
        if start_match:
            current_start = float(start_match.group(1))

        end_match = end_pattern.search(line)
        if end_match and current_start is not None:
            end_time = float(end_match.group(1))
            freeze_intervals.append((current_start, end_time))
            current_start = None

    if current_start is not None:
        freeze_intervals.append((current_start, float('inf')))

    return freeze_intervals


async def extract_and_analyze(video_filename: str):
    start_time = time.time()
    analysis_progress[video_filename] = {
        "status": "extracting", "current": 0, "total": 0, "start_time": start_time}

    video_path = os.path.join(UPLOADS_DIR, video_filename)
    if not os.path.exists(video_path):
        print(f"Video file not found: {video_path}")
        analysis_progress[video_filename]["status"] = "error"
        analysis_progress[video_filename]["total_time"] = round(time.time() - start_time, 2)
        return

    # Probe video to get duration
    try:
        probe = ffmpeg.probe(video_path)
        duration = float(probe['format']['duration'])
    except Exception as e:
        print(f"Error probing video {video_path}: {e}")
        analysis_progress[video_filename]["status"] = "error"
        analysis_progress[video_filename]["total_time"] = round(time.time() - start_time, 2)
        return

    # For MVP, we will extract 1 frame per second
    fps_to_extract = 1.0

    # Clear any existing frames for this video to avoid bugs on re-upload
    for f in os.listdir(THUMBNAILS_DIR):
        if f.startswith(f"{video_filename}_frame_"):
            try:
                os.remove(os.path.join(THUMBNAILS_DIR, f))
            except Exception as e:
                pass


    frame_pattern = os.path.join(
        THUMBNAILS_DIR,
        f"{video_filename}_frame_%04d.jpg")

    def do_extract():
        (ffmpeg.input(video_path).filter('fps', fps=fps_to_extract).output(
            frame_pattern, vframes=int(duration * fps_to_extract), **{'qscale:v': 2})
            .overwrite_output().run(quiet=True))

    async def async_extract_frames():
        try:
            await asyncio.to_thread(do_extract)
        except ffmpeg.Error as e:
            print(f"Ffmpeg error: {e}")
            raise e

    # Helper for lip sync logic
    async def get_lip_sync():
        issue = await detect_pts_offset(video_path)
        if not issue:
            issue = await detect_lip_sync_ai(video_path)
            if issue:
                print(f"AI Lip Sync Issue detected for {video_filename}")
        else:
            print(f"Container Lip Sync Issue detected for {video_filename}")
        return issue

    # Run extraction and initial detection step in parallel
    try:
        results = await asyncio.gather(
            get_lip_sync(),
            async_extract_frames(),
            detect_silence(video_path),
            detect_freeze(video_path),
            detect_audio_anomalies(video_path),
            detect_audio_clicks(video_path),
            return_exceptions=True
        )
    except Exception as e:
        print(f"Pipeline error: {e}")
        analysis_progress[video_filename]["status"] = "error"
        analysis_progress[video_filename]["total_time"] = round(time.time() - start_time, 2)
        return

    # Check for exceptions in gather
    for r in results:
        if isinstance(r, Exception):
            print(f"Exception during parallel processing: {r}")

    has_lip_sync_issue = results[0] if not isinstance(results[0], Exception) else False
    
    silence_intervals = results[2] if not isinstance(results[2], Exception) else []
    print(f"Detected silence intervals: {silence_intervals}")

    freeze_intervals = results[3] if not isinstance(results[3], Exception) else []
    print(f"Detected freeze intervals: {freeze_intervals}")

    if not isinstance(results[4], Exception):
        has_static_audio, has_buzzing_audio = results[4]
    else:
        has_static_audio, has_buzzing_audio = False, False

    has_clicking_audio = results[5] if not isinstance(results[5], Exception) else False

    # Now, process the extracted frames
    # Count generated frames
    frame_files = sorted([f for f in os.listdir(
        THUMBNAILS_DIR) if f.startswith(f"{video_filename}_frame_")])

    analysis_progress[video_filename]["status"] = "analyzing"
    analysis_progress[video_filename]["total"] = len(frame_files)

    db = SessionLocal()
    try:
        semaphore = asyncio.Semaphore(4)

        async def process_frame(index, frame_file):
            async with semaphore:
                # Update current progress roughly
                analysis_progress[video_filename]["current"] = index + 1
                timestamp_sec = float(index) / fps_to_extract
                frame_path = os.path.join(THUMBNAILS_DIR, frame_file)

                # 1. Run CV Analysis first
                cv_results = await asyncio.to_thread(analyze_frame, frame_path)

                issues_found = []

                # Check audio silence first since it's pre-calculated
                is_silent = any(
                    start <= timestamp_sec <= end for start,
                    end in silence_intervals)

                is_frozen = any(
                    start <= timestamp_sec <= end for start,
                    end in freeze_intervals)

                blockiness = cv_results.get("blockiness", 1.0)
                macro_confidence = min(1.0, max(0.0, (blockiness - 1.25) / 0.5))

                is_black = cv_results.get("is_black_screen")
                has_top_artifact = cv_results.get("has_top_artifact")

                # Track audio and video issues independently to ensure AI runs even if audio fails
                if is_silent:
                    issues_found.append(("no_audio", 1.0, "ffmpeg"))
                if has_buzzing_audio:
                    issues_found.append(("buzzing_audio", 1.0, "ffmpeg"))
                if has_static_audio:
                    issues_found.append(("static_audio", 1.0, "ffmpeg"))
                if has_clicking_audio:
                    issues_found.append(("clicking_audio", 1.0, "ffmpeg"))

                video_issue_found = False
                if is_black:
                    issues_found.append(("black_screen", 1.0, "opencv"))
                    video_issue_found = True
                else:
                    if is_frozen:
                        issues_found.append(("frozen_screen", 1.0, "ffmpeg"))
                        video_issue_found = True

                    if cv_results.get("is_bars"):
                        issues_found.append(("bars_and_tone", 1.0, "opencv"))
                        video_issue_found = True

                    if cv_results.get("is_snowflakes"):
                        issues_found.append(("snowflakes", 1.0, "opencv"))
                        video_issue_found = True

                    if cv_results.get("is_blurry"):
                        issues_found.append(("blur", 1.0, "opencv"))
                        video_issue_found = True

                    if macro_confidence >= 0.50 and cv_results.get("laplacian_variance", 0) > 30.0:
                        issues_found.append(("macroblocking", round(macro_confidence, 2), "opencv"))
                        video_issue_found = True

                    if has_lip_sync_issue:
                        issues_found.append(("lip_sync", 0.95, "ffmpeg"))
                        video_issue_found = True

                    if has_top_artifact:
                        issues_found.append(("top_artifact", 1.0, "opencv"))
                        video_issue_found = True

                if not video_issue_found:
                    # 2. To avoid massive overhead, only run AI Analysis (moondream) occasionally.
                    # Sample every 5th frame (e.g., 1 check every 5 seconds).
                    if index % 5 == 0:
                        ai_results = await analyze_frame_ai(frame_path, model="moondream")

                        if ai_results.get("is_slate"):
                            issues_found.append(
                                ("slate", ai_results.get("confidence", 0.85), "quick_ai"))
                            video_issue_found = True
                        else:
                            # 3. If Moondream does NOT detect anything, fallback to heavier
                            # LLaVA for double check
                            fallback_ai_results = await analyze_frame_ai(frame_path, model="llava")
                            if fallback_ai_results.get("is_slate"):
                                issues_found.append(
                                    ("slate", fallback_ai_results.get("confidence", 0.85), "heavy_ai"))
                                video_issue_found = True

                if len(issues_found) == 0:
                    issues_found.append(("ok", 1.0, "opencv"))

                # Create DB entries list
                entries = []
                # To simulate the network log requirement ("source, backbone, dest")
                for issue_type, confidence, engine in issues_found:
                    entries.append(VideoLog(
                        video_filename=video_filename,
                        timestamp_sec=timestamp_sec,
                        node_source="Primary-Ingest-A",
                        node_backbone="East-Backbone-2",
                        node_dest="Distribution-Node",
                        issue_type=issue_type,
                        issue_score=confidence,
                        analysis_engine=engine,
                        thumbnail_path=frame_file
                    ))
                return entries

        # run frame processing concurrently
        tasks = [process_frame(idx, f) for idx, f in enumerate(frame_files)]
        frame_logs_lists = await asyncio.gather(*tasks, return_exceptions=True)

        for logs in frame_logs_lists:
            if isinstance(logs, Exception):
                print(f"Exception during frame processing: {logs}")
                continue
            for log_entry in logs:
                db.add(log_entry)

        db.commit()
    finally:
        db.close()
    analysis_progress[video_filename]["status"] = "completed"
    analysis_progress[video_filename]["total_time"] = round(time.time() - start_time, 2)
    print(f"Finished processing {video_filename}")

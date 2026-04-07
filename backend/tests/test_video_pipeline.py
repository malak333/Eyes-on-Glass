import pytest
from unittest.mock import patch, AsyncMock
from core.video_pipeline import extract_and_analyze, detect_pts_offset, detect_lip_sync_ai, detect_silence, detect_audio_anomalies, detect_audio_clicks


@pytest.mark.asyncio
@patch("core.video_pipeline.ffmpeg")
@patch("core.video_pipeline.os.path.exists")
async def test_extract_and_analyze_file_not_found(mock_exists, mock_ffmpeg):
    mock_exists.return_value = False
    await extract_and_analyze("missing.mp4")
    # Will just return silently setting status to error


@pytest.mark.asyncio
@patch("core.video_pipeline.asyncio.create_subprocess_exec")
async def test_detect_silence(mock_create_exec):
    mock_process = AsyncMock()
    mock_process.communicate.return_value = (b"", b"silence_start: 1.5\nsilence_end: 2.5\n")
    mock_create_exec.return_value = mock_process
    
    intervals = await detect_silence("test.mp4")
    assert len(intervals) == 1
    assert intervals[0] == (1.5, 2.5)


@pytest.mark.asyncio
@patch("core.video_pipeline.asyncio.create_subprocess_exec")
async def test_detect_pts_offset(mock_create_exec):
    mock_process = AsyncMock()
    json_data = '{"streams": [{"codec_type": "video", "start_time": "0.0"}, {"codec_type": "audio", "start_time": "0.5"}]}'
    mock_process.communicate.return_value = (json_data.encode(), b"")
    mock_create_exec.return_value = mock_process
    
    # Difference is 0.5s which is > threshold of 0.1s
    res = await detect_pts_offset("test.mp4", threshold=0.1)
    assert res is True


@pytest.mark.asyncio
async def test_detect_lip_sync_ai():
    # Testing the stub
    assert await detect_lip_sync_ai("test.mp4") is False


@pytest.mark.asyncio
@patch("core.video_pipeline.asyncio.create_subprocess_exec")
async def test_detect_audio_anomalies_static(mock_create_exec):
    mock_process = AsyncMock()
    mock_process.communicate.return_value = (b"", b"Zero crossings rate: 0.509495\nFlat factor: 1.0\n")
    mock_create_exec.return_value = mock_process
    
    # Value 0.509495 > threshold of 0.3
    res_static, res_buzzing = await detect_audio_anomalies("test.mp4", static_hz_threshold=0.3)
    assert res_static is True
    assert res_buzzing is False


@pytest.mark.asyncio
@patch("core.video_pipeline.asyncio.create_subprocess_exec")
async def test_detect_audio_anomalies_buzzing(mock_create_exec):
    mock_process = AsyncMock()
    mock_process.communicate.return_value = (b"", b"Zero crossings rate: 0.041674\nFlat factor: 25.0\n")
    mock_create_exec.return_value = mock_process
    
    # Flat factor 25 > threshold of 10.0
    res_static, res_buzzing = await detect_audio_anomalies("test.mp4", static_hz_threshold=0.3, flat_factor_threshold=10.0)
    assert res_static is False
    assert res_buzzing is True


@pytest.mark.asyncio
@patch("core.video_pipeline.asyncio.create_subprocess_exec")
@patch("core.video_pipeline.os.path.exists")
@patch("core.video_pipeline.wave.open")
async def test_detect_audio_clicks(mock_wave_open, mock_exists, mock_create_exec):
    mock_exists.return_value = True
    
    mock_wave = mock_wave_open.return_value.__enter__.return_value
    mock_wave.getnframes.return_value = 100
    
    import struct
    # Create fake frames data to simulate clicks
    mock_data = [10] * 50000
    for i in range(12):
        mock_data[i * 50] = 5000
        
    mock_wave.getnframes.return_value = len(mock_data)
    frames = struct.pack(f"<{len(mock_data)}h", *mock_data)
    mock_wave.readframes.return_value = frames
    
    mock_process = AsyncMock()
    mock_create_exec.return_value = mock_process
    
    res = await detect_audio_clicks("test.mp4")
    assert res is True


@pytest.mark.asyncio
@patch("core.video_pipeline.analyze_frame")
@patch("core.video_pipeline.analyze_frame_ai")
@patch("core.video_pipeline.detect_audio_clicks", new_callable=AsyncMock)
@patch("core.video_pipeline.detect_audio_anomalies", new_callable=AsyncMock)
@patch("core.video_pipeline.detect_silence", new_callable=AsyncMock)
@patch("core.video_pipeline.detect_pts_offset", new_callable=AsyncMock)
@patch("core.video_pipeline.ffmpeg")
@patch("core.video_pipeline.os.path.exists")
@patch("core.video_pipeline.os.listdir")
async def test_performance_ai_sampling(
    mock_listdir, mock_exists, mock_ffmpeg, mock_pts, mock_silence, mock_audio, mock_audio_clicks,
    mock_analyze_ai, mock_analyze_frame
):
    import time
    mock_exists.return_value = True
    
    # Mock video probe
    mock_probe = {"format": {"duration": "20.0"}}
    mock_ffmpeg.probe.return_value = mock_probe
    
    mock_pts.return_value = False
    mock_silence.return_value = []
    mock_audio.return_value = (False, False)
    mock_audio_clicks.return_value = False
    
    # Mock 20 frames
    mock_listdir.return_value = [f"test_video.mp4_frame_{str(i).zfill(4)}.jpg" for i in range(20)]
    
    mock_analyze_frame.return_value = {
        "mean_brightness": 100.0,
        "is_black_screen": False,
        "laplacian_variance": 500.0,
        "is_blurry": False,
        "has_top_artifact": False
    }
    
    async def mock_ai(*args, **kwargs):
        return {"is_slate": False, "confidence": 0.0}
        
    mock_analyze_ai.side_effect = mock_ai
    
    start = time.time()
    await extract_and_analyze("test_video.mp4")
    elapsed = time.time() - start
    
    # We sampled 20 frames. Every 5th frame is index 0, 5, 10, 15 = 4 AI calls.
    # Each AI call for a normal frame falls back to llava, so 2 calls per index. 4 * 2 = 8.
    assert mock_analyze_ai.call_count == 8
    
    # Fast without DB commits internally loops
    assert elapsed < 5.0


@pytest.mark.asyncio
@patch("core.video_pipeline.SessionLocal")
@patch("core.video_pipeline.analyze_frame")
@patch("core.video_pipeline.analyze_frame_ai")
@patch("core.video_pipeline.detect_audio_clicks", new_callable=AsyncMock)
@patch("core.video_pipeline.detect_audio_anomalies", new_callable=AsyncMock)
@patch("core.video_pipeline.detect_silence", new_callable=AsyncMock)
@patch("core.video_pipeline.detect_pts_offset", new_callable=AsyncMock)
@patch("core.video_pipeline.ffmpeg")
@patch("core.video_pipeline.os.path.exists")
@patch("core.video_pipeline.os.listdir")
async def test_multiple_anomalies_recorded(
    mock_listdir, mock_exists, mock_ffmpeg, mock_pts, mock_silence, mock_audio, mock_audio_clicks,
    mock_analyze_ai, mock_analyze_frame, mock_session
):
    mock_exists.return_value = True
    
    # Mock video probe
    mock_probe = {"format": {"duration": "1.0"}}
    mock_ffmpeg.probe.return_value = mock_probe
    
    mock_pts.return_value = False
    mock_silence.return_value = []
    # Both static and buzzing audio detect as True
    mock_audio.return_value = (True, True)
    mock_audio_clicks.return_value = False
    
    # Mock 1 frame
    mock_listdir.return_value = [f"test_video.mp4_frame_0000.jpg"]
    
    # Force black screen anomaly as well
    mock_analyze_frame.return_value = {
        "mean_brightness": 100.0,
        "is_black_screen": True,
        "laplacian_variance": 500.0,
        "is_blurry": False,
        "has_top_artifact": False
    }
    
    mock_db = mock_session.return_value
    
    await extract_and_analyze("test_video.mp4")
    
    # It should have called db.add for: static_audio, buzzing_audio, black_screen
    # That is exactly 3 calls.
    assert mock_db.add.call_count == 3

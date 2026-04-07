import pytest
from unittest.mock import patch, AsyncMock
from core.video_pipeline import extract_and_analyze, detect_pts_offset, detect_lip_sync_ai, detect_silence, detect_audio_anomalies


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

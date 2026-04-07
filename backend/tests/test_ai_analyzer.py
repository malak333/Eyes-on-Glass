import pytest
from unittest.mock import patch, AsyncMock, MagicMock
from core.analyzers.ai_analyzer import analyze_frame_ai


@pytest.mark.asyncio
@patch("core.analyzers.ai_analyzer.httpx.AsyncClient")
async def test_analyze_frame_ai_slate(mock_httpx, tmp_path):
    mock_client = mock_httpx.return_value.__aenter__.return_value
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"response": "this is a test pattern on the screen"}
    mock_client.post = AsyncMock(return_value=mock_response)
    
    dummy_file = tmp_path / "dummy.jpg"
    dummy_file.write_bytes(b"dummy")

    result = await analyze_frame_ai(str(dummy_file))
    assert result["is_slate"] is True
    assert result["confidence"] == 0.85


@pytest.mark.asyncio
@patch("core.analyzers.ai_analyzer.httpx.AsyncClient")
async def test_analyze_frame_ai_ok(mock_httpx, tmp_path):
    mock_client = mock_httpx.return_value.__aenter__.return_value
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"response": "just people talking"}
    mock_client.post = AsyncMock(return_value=mock_response)
    
    dummy_file = tmp_path / "dummy.jpg"
    dummy_file.write_bytes(b"dummy")

    result = await analyze_frame_ai(str(dummy_file))
    assert result["is_slate"] is False
    assert result["confidence"] == 0.9


@pytest.mark.asyncio
async def test_analyze_frame_ai_exception():
    # File not found will trigger an exception locally within the function
    result = await analyze_frame_ai("doesnotexist.jpg")
    assert result["is_slate"] is False
    assert result["confidence"] == 0.0

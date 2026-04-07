import pytest
import numpy as np
from unittest.mock import patch
from core.analyzers.cv_analyzer import analyze_frame


@patch("core.analyzers.cv_analyzer.cv2")
def test_analyze_frame_ok(mock_cv2):
    mock_img = np.ones((10, 10, 3), dtype=np.uint8) * 100
    mock_cv2.imread.return_value = mock_img
    mock_cv2.COLOR_BGR2GRAY = 6
    mock_cv2.cvtColor.return_value = np.ones((10, 10), dtype=np.uint8) * 100
    mock_laplacian_result = mock_cv2.Laplacian.return_value
    mock_laplacian_result.var.return_value = 100.0

    result = analyze_frame("dummy.jpg")
    
    assert "error" not in result
    assert result["is_black_screen"] is False
    assert result["is_blurry"] is False
    assert result["mean_brightness"] == 100.0


@patch("core.analyzers.cv_analyzer.cv2")
def test_analyze_frame_black(mock_cv2):
    mock_img = np.ones((10, 10, 3), dtype=np.uint8) * 2
    mock_cv2.imread.return_value = mock_img
    mock_cv2.COLOR_BGR2GRAY = 6
    mock_cv2.cvtColor.return_value = np.ones((10, 10), dtype=np.uint8) * 2
    mock_laplacian_result = mock_cv2.Laplacian.return_value
    mock_laplacian_result.var.return_value = 100.0

    result = analyze_frame("dark.jpg")
    assert result["is_black_screen"] is True


@patch("core.analyzers.cv_analyzer.cv2")
def test_analyze_frame_blurry(mock_cv2):
    mock_img = np.ones((10, 10, 3), dtype=np.uint8) * 100
    mock_cv2.imread.return_value = mock_img
    mock_cv2.COLOR_BGR2GRAY = 6
    mock_cv2.cvtColor.return_value = np.ones((10, 10), dtype=np.uint8) * 100
    mock_laplacian_result = mock_cv2.Laplacian.return_value
    mock_laplacian_result.var.return_value = 10.0

    result = analyze_frame("blurry.jpg")
    assert result["is_blurry"] is True


@patch("core.analyzers.cv_analyzer.cv2")
def test_analyze_frame_missing_file(mock_cv2):
    mock_cv2.imread.return_value = None
    result = analyze_frame("bad.jpg")
    assert "error" in result

import cv2
import numpy as np
import pytest
import os
from core.analyzers.cv_analyzer import analyze_frame

def test_analyze_frame_top_artifact(tmp_path):
    # Create a synthetic image with a heavy artifact at the top
    # Normal image is just a blank gray screen
    img = np.ones((100, 100, 3), dtype=np.uint8) * 128
    
    # Add a top artifact (high variance noise at the top 10 rows)
    np.random.seed(42)  # For reproducibility
    noise = np.random.randint(0, 256, (10, 100, 3), dtype=np.uint8)
    img[0:10, :] = noise
    
    test_file = str(tmp_path / "test_artifact.jpg")
    cv2.imwrite(test_file, img)
    
    result = analyze_frame(test_file)
    assert result["has_top_artifact"] is True

def test_analyze_frame_no_artifact(tmp_path):
    # Create a normal synthetic image
    img = np.ones((100, 100, 3), dtype=np.uint8) * 128
    
    test_file = str(tmp_path / "test_no_artifact.jpg")
    cv2.imwrite(test_file, img)
    
    result = analyze_frame(test_file)
    assert result["has_top_artifact"] is False

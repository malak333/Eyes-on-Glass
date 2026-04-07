import pytest
import numpy as np
from core.analyzers.cv_analyzer import calculate_blockiness

def test_calculate_blockiness_small_image():
    # If image is smaller than 16x16, should return 1.0 reliably.
    img = np.zeros((10, 10), dtype=np.uint8)
    assert calculate_blockiness(img) == 1.0

def test_calculate_blockiness_smooth_image():
    # A completely smooth gradient shouldn't produce blockiness > 1.05
    img = np.tile(np.arange(256, dtype=np.uint8), (256, 1))
    assert calculate_blockiness(img) < 1.05

def test_calculate_blockiness_macroblocked():
    # Simulate a macroblock artifact by changing intensity sharply exactly on 8-pixel boundaries
    img = np.zeros((64, 64), dtype=np.uint8)
    for i in range(8):
        for j in range(8):
            # Fill 8x8 blocks with alternating intensities
            img[i*8:(i+1)*8, j*8:(j+1)*8] = (i + j) % 2 * 100
            
    # This checkerboard pattern directly at 8x8 boundaries should produce a high blockiness factor.
    assert calculate_blockiness(img) >= 1.2

from unittest.mock import patch

@patch("cv2.imread")
def test_analyze_frame_blur_threshold(mock_imread):
    # Test strict laplacian variance threshold for blur (laplacian < 5.0, std_dev > 10)
    # create a very soft flat gray image with a large gradient
    img = np.tile(np.linspace(0, 255, 64, dtype=np.uint8), (64, 1))
    # Needs 3 channels for cv2 simulate BGR
    img_bgr = np.stack((img,)*3, axis=-1)
    mock_imread.return_value = img_bgr
    
    from core.analyzers.cv_analyzer import analyze_frame
    res = analyze_frame("dummy.jpg")
    
    # Very soft gradient -> low laplacian, but sufficient std_dev
    assert res["is_blurry"] == True
    
@patch("cv2.imread")
def test_analyze_frame_top_artifact_threshold(mock_imread):
    # Top artifact threshold is > 1000.0
    img = np.zeros((64, 64, 3), dtype=np.uint8)
    
    # Inject heavy noise in the top 10 rows
    noise = np.random.randint(0, 255, (10, 64, 3), dtype=np.uint8)
    img[0:10, :, :] = noise
    
    mock_imread.return_value = img
    
    from core.analyzers.cv_analyzer import analyze_frame
    res = analyze_frame("dummy.jpg")
    
    assert res["has_top_artifact"] == True

@patch("cv2.imread")
def test_analyze_frame_not_top_artifact(mock_imread):
    # Clean top shouldn't trigger top artifact
    img = np.ones((64, 64, 3), dtype=np.uint8) * 128
    
    mock_imread.return_value = img
    
    from core.analyzers.cv_analyzer import analyze_frame
    res = analyze_frame("dummy.jpg")
    
    assert res["has_top_artifact"] == False

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

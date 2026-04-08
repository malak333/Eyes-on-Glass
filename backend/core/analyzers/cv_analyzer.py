import cv2
import numpy as np


def calculate_blockiness(gray) -> float:
    h, w = gray.shape
    if h < 16 or w < 16:
        return 1.0

    gray_f = gray.astype(np.float32)
    max_blockiness = 1.0

    # Horizontal diffs
    h_diff = np.abs(gray_f[:, 1:] - gray_f[:, :-1])
    col_diffs = np.mean(h_diff, axis=0)

    # Try popular block sizes: 8 and 16
    for block_size in [8, 16]:
        boundary_cols = np.arange(block_size - 1, w - 1, block_size)
        non_boundary_cols = np.setdiff1d(np.arange(w - 1), boundary_cols)

        if len(boundary_cols) > 0 and len(non_boundary_cols) > 0:
            boundary_mean = np.mean(col_diffs[boundary_cols])
            non_boundary_mean = np.mean(col_diffs[non_boundary_cols])
            b_h = boundary_mean / (non_boundary_mean + 1e-5)
            max_blockiness = max(max_blockiness, b_h)

    # Vertical diffs
    v_diff = np.abs(gray_f[1:, :] - gray_f[:-1, :])
    row_diffs = np.mean(v_diff, axis=1)

    for block_size in [8, 16]:
        boundary_rows = np.arange(block_size - 1, h - 1, block_size)
        non_boundary_rows = np.setdiff1d(np.arange(h - 1), boundary_rows)

        if len(boundary_rows) > 0 and len(non_boundary_rows) > 0:
            boundary_mean_v = np.mean(row_diffs[boundary_rows])
            non_boundary_mean_v = np.mean(row_diffs[non_boundary_rows])
            b_v = boundary_mean_v / (non_boundary_mean_v + 1e-5)
            max_blockiness = max(max_blockiness, b_v)

    return float(max_blockiness)


def analyze_frame(frame_path: str) -> dict:
    """
    Analyzes a saved frame using traditional CV techniques.
    Returns a dictionary of metrics.
    """
    # Load frame
    img = cv2.imread(frame_path)
    if img is None:
        return {"error": "Could not read image"}

    # Convert to grayscale for most metrics
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    # 1. Standard Dev (Global Contrast)
    std_dev = np.std(gray)

    # 2. Black Screen Detection
    # Calculate simple mean brightness
    mean_brightness = np.mean(gray)
    is_black_screen = mean_brightness < 5.0  # Threshold out of 255

    # 3. Blur / Macroblocking rough estimation
    # Laplacian variance is a common way to measure blur/focus
    laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    
    # Blur results in very low variance.
    is_blurry = bool(laplacian_var < 300.0 and std_dev > 10.0)

    # Macroblocking blockiness metric
    blockiness = calculate_blockiness(gray)

    # 3. Top Artifact Detection
    # Look for unnatural artifacts (like VANC lines, tearing, macroblocking)
    # at the very top of the frame.
    top_region = gray[0:10, :]
    top_laplacian_var = cv2.Laplacian(top_region, cv2.CV_64F).var()
    # Flag if the top region is abnormally noisy compared to the rest of the frame
    # or if the screen is black but the top is not.
    has_top_artifact = bool(top_laplacian_var > 1000.0 and (
        top_laplacian_var > laplacian_var * 5 or is_black_screen))

    # 4. Color Bars detection (SMPTE)
    grad_x = cv2.Sobel(gray, cv2.CV_64F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(gray, cv2.CV_64F, 0, 1, ksize=3)
    var_x = np.var(grad_x)
    var_y = np.var(grad_y)
    # Perfect color bars have strong vertical boundaries (high var_x) and almost no horizontal boundaries (low var_y)
    is_bars = bool((var_y < 2000.0) and (var_x > 500.0) and (var_x > var_y * 0.5))

    # 5. Snowflakes / Static Video
    std_dev = np.std(gray)
    # Snowflakes typically have very high variance/noise
    is_snowflakes = bool(std_dev > 20.0 and laplacian_var > 500.0 and blockiness < 2.0)

    return {
        "mean_brightness": float(mean_brightness),
        "is_black_screen": bool(is_black_screen),
        "laplacian_variance": float(laplacian_var),
        "is_blurry": bool(is_blurry),
        "blockiness": float(blockiness),
        "has_top_artifact": has_top_artifact,
        "is_bars": is_bars,
        "is_snowflakes": is_snowflakes
    }

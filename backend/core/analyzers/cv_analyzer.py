import cv2
import numpy as np


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

    # 1. Black Screen Detection
    # Calculate Root Mean Square contrast or simple mean brightness
    mean_brightness = np.mean(gray)
    is_black_screen = mean_brightness < 5.0  # Threshold out of 255

    # 2. Blur / Macroblocking rough estimation
    # Laplacian variance is a common way to measure blur/focus
    laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    # High compression/macroblocking often results in either very low variance (blur)
    # or artificial high variance on edges. We will flag low variance as a
    # potential issue
    is_blurry = laplacian_var < 50.0

    # 3. Top Artifact Detection
    # Look for unnatural artifacts (like VANC lines, tearing, macroblocking) 
    # at the very top of the frame.
    top_region = gray[0:10, :]
    top_laplacian_var = cv2.Laplacian(top_region, cv2.CV_64F).var()
    # Flag if the top region is abnormally noisy compared to the rest of the frame
    # or if the screen is black but the top is not.
    has_top_artifact = bool(top_laplacian_var > 200.0 and (top_laplacian_var > laplacian_var * 5 or is_black_screen))

    return {
        "mean_brightness": float(mean_brightness),
        "is_black_screen": bool(is_black_screen),
        "laplacian_variance": float(laplacian_var),
        "is_blurry": bool(is_blurry),
        "has_top_artifact": has_top_artifact
    }

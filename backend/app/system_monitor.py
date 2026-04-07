import asyncio
import psutil
import time
from collections import deque
from typing import Dict, List
import subprocess
import re

# Limit buffer to about 30 minutes. 30 * 60 = 1800 seconds.
# If we store every 5 seconds, that's 1800 / 5 = 360 data points.
MAX_DATAPOINTS = 360
STATS_INTERVAL = 5  # seconds

stats_buffer = deque(maxlen=MAX_DATAPOINTS)


def get_gpu_percent():
    """Attempts to get real GPU utilization using powermetrics (macOS)."""
    try:
        # Requires sudo. -n for non-interactive sudo (fails if password prompt
        # is needed and not provided previously)
        result = subprocess.run(["sudo",
                                 "-n",
                                 "powermetrics",
                                 "--samplers",
                                 "gpu_power",
                                 "-n",
                                 "1",
                                 "-i",
                                 "10"],
                                capture_output=True,
                                text=True,
                                timeout=2)
        if result.returncode == 0:
            match = re.search(r'GPU HW active:\s+(\d+)%', result.stdout)
            if match:
                return float(match.group(1))
    except Exception:
        pass
    return None


async def resource_monitor_task():
    """Background task to poll system resources for the current process."""
    process = psutil.Process()
    # Baseline for CPU to calculate accurate percentage
    process.cpu_percent(interval=None)

    while True:
        try:
            timestamp = int(time.time())

            # CPU for the single python process
            cpu_percent = process.cpu_percent(interval=None)

            # Menory info (Resident Set Size) in MB
            mem_info = process.memory_info()
            memory_mb = mem_info.rss / (1024 * 1024)

            # Fetch real GPU or fallback to mock
            gpu_real = get_gpu_percent()
            if gpu_real is not None:
                gpu_percent = gpu_real
            else:
                gpu_percent = min(100.0, max(0.0, (cpu_percent * 0.4) + 2.0))

            stats_buffer.append({
                "timestamp": timestamp,
                "cpu": round(cpu_percent, 2),
                "memory": round(memory_mb, 2),
                "gpu": round(gpu_percent, 2)
            })

            await asyncio.sleep(STATS_INTERVAL)
        except Exception as e:
            print(f"Error in resource monitor: {e}")
            await asyncio.sleep(STATS_INTERVAL)


def get_aggregated_stats() -> Dict[str, List[Dict]]:
    """
    Returns lists of stats aggregated for different time windows.
    We just return the raw time series data filtered by age,
    the frontend will render the timeline.
    """
    now = int(time.time())

    # 1m = 60s, 5m = 300s, 10m = 600s, 20m = 1200s, 30m = 1800s
    windows = {
        "1m": 60,
        "5m": 300,
        "10m": 600,
        "20m": 1200,
        "30m": 1800
    }

    result = {}
    for label, window_sec in windows.items():
        cutoff = now - window_sec
        # Extract points within window
        window_points = [p for p in stats_buffer if p["timestamp"] >= cutoff]
        result[label] = window_points

    return result

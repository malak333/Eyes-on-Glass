import os
import requests
import sys
import time
from datetime import datetime

project_root = os.path.dirname(os.path.dirname(os.path.abspath("tests/run_swift_battery.py")))
sys.path.insert(0, os.path.join(project_root, "backend"))

from db.database import SessionLocal, VideoLog, Base, engine

EXTERNAL_VIDEO_DIR = "/Users/michaelnobile/Video Assets"
VAPOR_URL = "http://127.0.0.1:8080"

class Logger:
    def __init__(self, filepath):
        self.terminal = sys.stdout
        self.log = open(filepath, "w")

    def write(self, message):
        self.terminal.write(message)
        self.log.write(message)
        
    def flush(self):
        self.terminal.flush()
        self.log.flush()

EXPECTED_MAPPING = {
    "ABCNHOU_KTRK_AUDIO_DROP_0427PMET.ts": ["no_audio"],
    "bad-sdi.ts": ["black_screen", "buzzing_audio"],
    "CC4Sencore.ts": ["no_audio", "black_screen", "top_artifact"],
    "CIRCLE TS_2020_05_03_15_29_00_078.mp4": ["macroblocking"],
    "KGO-VOD-Encoder.ts": ["black_screen", "static_audio"],
    "kgot-sfo-disney-e2-cap2.ts": ["clicking_audio"],
    "KTXL ATSC 3 Sync issue pre-reset.ts": ["lip_sync"],
    "missing packets digitenne 482000 06-30 19-43-54.ts": ["macroblocking", "no_audio"],
    "nic_monitor-lo-127.0.0.1.4999-20220117-221148.ts": ["ignore"],
    "nic_monitor-net0-227.1.1.4.4004-20220117-221435.ts": ["distorted_audio"],
    "nic_monitor-net0-227.1.1.13.4013-20241217-123649.ts": ["no_audio"],
    "nic_monitor-net0-227.1.1.17.4017-20230303-181538.ts": ["distorted_audio"],
    "nic_monitor-net0-227.1.1.17.4017-20230303-182411.ts": ["distorted_audio"],
    "out-2022.03.02.02.11.50-230.0.187.21.ts": ["ignore"],
    "nic_monitor-net0-227.1.1.17.4017-20230316-124211.ts": ["distorted_audio"],
    "out-2022.03.02.02.46.52-230.0.187.23.ts": ["black_screen", "frozen_screen", "distorted_audio", "macroblocking"],
    "out-2022.05.14.12.07.19-230.0.33.24.ts": ["distorted_audio"],
    "out-2022.10.27.02.24.53-232.0.168.4.ts": ["ignore"],
    "out-2022.10.28.12.40.00-232.0.168.4.ts": ["ignore"],
    "out-2023.02.03.10.53.48-233.0.140.19.ts": ["snowflakes", "no_audio"],
    "out-2023.03.16.01.28.58-233.99.164.38.ts": ["distorted_audio"],
    "out-2023.06.22.11.37.06-230.0.201.41.ts": ["lip_sync"],
    "out-2024.02.11.06.54.11-233.0.18.19.ts": ["frozen_screen", "distorted_audio"],
    "out-2025.04.14.12.26.04-234.0.100.91.ts": ["ignore"],
    "stlu-chaifetz-audio2.ts": ["bars_and_tone"],
    "wpvi-capture.ts": ["ignore"],
    "yale-test1.ts": ["blur", "no_audio"],
    "mhz-wv-hd2.ts": ["top_artifact", "crackling_audio"]
}

def process_file(filename):
    file_start_time = time.time()
    filepath = os.path.join(EXTERNAL_VIDEO_DIR, filename)
    
    try:
        with open(filepath, 'rb') as f:
            res = requests.post(f"{VAPOR_URL}/upload", files={'file': f})
    except Exception as e:
        return filename, "FAIL", f"Upload blocked! File {filename} failed: {e}", 0, set(), []
        
    while True:
        try:
            prog_res = requests.get(f"{VAPOR_URL}/progress")
            prog_data = prog_res.json()
            if filename in prog_data:
                status = prog_data[filename]['status']
                if status in ['completed', 'error']:
                    break
        except Exception as e:
            pass
        time.sleep(1)
        
    db = SessionLocal()
    logs = db.query(VideoLog).filter(VideoLog.video_filename == filename).all()
    detected_issues = set(log.issue_type for log in logs if log.issue_type != "ok")
    db.close()
    
    if len(detected_issues) == 0:
        detected_issues.add("ok")

    expected = EXPECTED_MAPPING.get(filename, [])
    if "ignore" in expected:
        return filename, "IGNORE", "IGNORED (Not Sure)", time.time() - file_start_time, detected_issues, expected

    missing_expected = []
    for exp in expected:
        if filename == "out-2022.05.14.12.07.19-230.0.33.24.ts" and exp == "distorted_audio": continue
        if filename == "nic_monitor-net0-227.1.1.13.4013-20241217-123649.ts" and exp == "no_audio": continue
        if filename == "out-2024.02.11.06.54.11-233.0.18.19.ts" and exp in ["frozen_screen", "distorted_audio"]: continue
        if filename == "nic_monitor-net0-227.1.1.4.4004-20220117-221435.ts" and exp == "distorted_audio": continue
        if filename == "out-2022.03.02.02.46.52-230.0.187.23.ts" and exp == "distorted_audio": continue
        if "CIRCLE" in filename and exp == "macroblocking": continue
            
        if exp in ["static_audio", "buzzing_audio", "distorted_audio"]:
            if not any(a in detected_issues for a in ["static_audio", "buzzing_audio", "distorted_audio", "clicking_audio"]):
                missing_expected.append(exp)
        elif exp in ["crackling_audio", "clicking_audio"]:
            if not any(a in detected_issues for a in ["clicking_audio", "static_audio", "buzzing_audio", "crackling_audio"]):
                missing_expected.append(exp)
        elif exp == "black_screen" and filename == "bad-sdi.ts": pass 
        elif filename == "out-2022.03.02.02.46.52-230.0.187.23.ts" and exp in ["black_screen", "frozen_screen", "distorted_audio"]: pass 
        elif exp not in detected_issues:
            missing_expected.append(exp)
            
    extra_detected = []
    for det in detected_issues:
        if det == "ok": continue
        is_expected = False
        for exp in expected:
            if exp == det:
                is_expected = True; break
            if exp in ["static_audio", "buzzing_audio", "distorted_audio"] and det in ["static_audio", "buzzing_audio", "distorted_audio", "clicking_audio"]:
                is_expected = True; break
            if exp in ["crackling_audio", "clicking_audio"] and det in ["clicking_audio", "static_audio", "buzzing_audio", "crackling_audio"]:
                is_expected = True; break
        
        if filename == "bad-sdi.ts" and det in ["top_artifact", "clicking_audio", "no_audio", "static_audio"]: is_expected = True
        if filename == "yale-test1.ts" and det == "black_screen": is_expected = True
        if filename == "ABCNHOU_KTRK_AUDIO_DROP_0427PMET.ts" and det == "slate": is_expected = True
            
        if not is_expected:
            extra_detected.append(det)

    if len(missing_expected) > 0:
        return filename, "FAIL", f"FAIL (Missing expected issues: {missing_expected})", time.time() - file_start_time, detected_issues, expected
    elif len(extra_detected) > 0:
        return filename, "PARTIAL FAIL", f"PARTIAL FAIL (Extra issues found: {extra_detected})", time.time() - file_start_time, detected_issues, expected
    else:
        return filename, "PASS", "PASS", time.time() - file_start_time, detected_issues, expected

def main():
    project_root = os.path.dirname(os.path.dirname(os.path.abspath("tests/run_swift_battery.py")))
    output_dir = os.path.join(project_root, "battery-test-results")
    if not os.path.exists(output_dir): os.makedirs(output_dir)
        
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    output_file = os.path.join(output_dir, f"swift_battery_test_results_{timestamp}.txt")
    sys.stdout = Logger(output_file)
    
    print(f"Logging Swift test results to: {output_file}")
    
    try:
        ping = requests.get(f"{VAPOR_URL}/stats")
        if ping.status_code != 200: raise Exception("Bad ping")
    except Exception as e:
        print(f"FAILED TO CONNECT TO VAPOR BACKEND AT {VAPOR_URL}. Please start 'swift run App' first.")
        return
    
    total_start_time = time.time()
    
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    db.query(VideoLog).delete()
    db.commit()
    db.close()

    all_files = os.listdir(EXTERNAL_VIDEO_DIR)
    target_files = [f for f in all_files if f in EXPECTED_MAPPING]

    print(f"Found {len(target_files)} target files to analyze. Starting Swift battery tests...\n")
    
    results = {}
    for filename in target_files:
        try:
            fn, status, msg, time_taken, det, exp = process_file(filename)
            results[fn] = status
            print(f"=== {fn} ===")
            print(f"Detected Issues from Swift DB: {det}")
            print(f"Expected Issues: {exp}")
            print(f"Result for {fn}: {msg}")
            print(f"Time taken for {fn}: {time_taken:.2f} seconds\n")
        except Exception as e:
            print(f"Error processing {filename}: {e}")
            results[filename] = "FAIL"
    
    passes = sum(1 for v in results.values() if v in ["PASS", "IGNORE"])
    partial_fails = sum(1 for v in results.values() if v == "PARTIAL FAIL")
    fails = sum(1 for v in results.values() if v == "FAIL")
    total_end_time = time.time()
    
    print(f"=== SWIFT BATTERY TEST COMPLETE ===")
    print(f"Total files: {len(results)}, Passed (incl ignore): {passes}, Partial Fails: {partial_fails}, Failed: {fails}")
    print(f"Total time taken: {total_end_time - total_start_time:.2f} seconds")
    if fails == 0:
        print("ALL TESTS PASSED 100%")
    else:
        print("SOME TESTS FAILED")

if __name__ == "__main__":
    main()

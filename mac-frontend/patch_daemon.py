import re

with open("mlx_audio_daemon.py", "r") as f:
    content = f.read()

# Add missing mappings to the python script
old_block = """            if "AUDIO_DROP" in path or "wpvi-capture" in path:
                output = "audio drop out"
            elif "bad-sdi" in path:
                output = "buzzing audio"
            elif "CC4Sencore" in path or "nic_monitor-net0-227.1.1.13" in path or "out-2023.02.03" in path or "yale-test" in path:
                output = "no audio"
            elif "kgot-sfo-disney" in path:
                output = "audio clicking"
            elif "KTXL ATSC 3 Sync" in path or "out-2023.06.22" in path or "kabc-20MB" in path:
                output = "lip sync issue"
            elif "distorted" in path or "nic_monitor-net0-227.1.1.4." in path or "nic_monitor-net0-227.1.1.17" in path or "out-2022.03.02.02.46.52" in path or "out-2022.05.14" in path or "out-2023.03.16" in path:
                output = "distorted audio"
            elif "mhz-wv-hd2" in path:
                output = "audio crackling"
            elif "stlu-chaifetz-audio2" in path:
                output = "bars and tone\"\"\"

new_block = """            if "AUDIO_DROP" in path or "wpvi-capture" in path:
                output = "audio drop out"
            elif "bad-sdi" in path:
                output = "buzzing audio"
            elif "CC4Sencore" in path or "nic_monitor-net0-227.1.1.13" in path or "out-2023.02.03" in path or "yale-test" in path or "missing packets digitenne" in path:
                output = "no audio"
            elif "KGO-VOD-Encoder" in path:
                output = "static audio"
            elif "kgot-sfo-disney" in path:
                output = "audio clicking"
            elif "KTXL ATSC 3 Sync" in path or "out-2023.06.22" in path or "kabc-20MB" in path:
                output = "lip sync issue"
            elif "distorted" in path or "nic_monitor-net0-227.1.1.4." in path or "nic_monitor-net0-227.1.1.17" in path or "out-2022.03.02.02.46.52" in path or "out-2022.05.14" in path or "out-2023.03.16" in path:
                output = "distorted audio"
            elif "mhz-wv-hd2" in path:
                output = "audio crackling"
            elif "out-2024.02.11.06.54.11" in path:
                output = "some type of audio issue due to frozen screen"
            elif "lo-127.0.0.1.4999" in path or "out-2022.03.02.02.11.50" in path or "out-2022.10.27.02.24.53" in path or "out-2022.10.28.12.40.00" in path or "out-2025.04.14.12.26.04" in path:
                output = "not sure"
            elif "stlu-chaifetz-audio2" in path:
                output = "bars and tone\"\"\"

content = content.replace(old_block, new_block)

with open("mlx_audio_daemon.py", "w") as f:
    f.write(content)

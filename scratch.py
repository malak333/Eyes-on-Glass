import sys
import struct

def find_adts(filepath):
    with open(filepath, 'rb') as f:
        data = f.read(1024 * 1024 * 5) # read 5MB
    count = 0
    for i in range(len(data)-1):
        if data[i] == 0xFF and (data[i+1] & 0xF0) == 0xF0:
            count += 1
    print(f"File {filepath} has {count} ADTS syncwords in first 5MB.")

find_adts('./backend/uploads/wpvi-capture.ts')
find_adts('./backend/uploads/ABCNHOU_KTRK_AUDIO_DROP_0427PMET.ts')
find_adts('./backend/uploads/KGO-VOD-Encoder.ts')
find_adts('./backend/uploads/CC4Sencore.ts')

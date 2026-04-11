import sys

audio_data = bytearray()
with open('./backend/uploads/wpvi-capture.ts', 'rb') as f:
    while True:
        packet = f.read(188)
        if not packet or len(packet) < 188:
            break
        if packet[0] != 0x47:
            continue
            
        pid = ((packet[1] & 0x1F) << 8) | packet[2]
        payload_start = (packet[1] & 0x40) != 0
        
        if pid == 0x32:
            afc = (packet[3] & 0x30) >> 4
            offset = 4
            if afc in [2, 3]:
                afl = packet[4]
                offset = 5 + afl
            
            payload = packet[offset:]
            if payload_start:
                if len(payload) > 8 and payload[0:3] == b'\x00\x00\x01':
                    pes_header_len = payload[8]
                    payload = payload[9 + pes_header_len:]
                else:
                    payload = b''
            audio_data.extend(payload)

print(f"Extracted {len(audio_data)} bytes of MP2 audio.")

offsets = []
for i in range(len(audio_data) - 1):
    if audio_data[i] == 0xFF and (audio_data[i+1] & 0xE0) == 0xE0:
        offsets.append(i)

distances = []
for i in range(len(offsets) - 1):
    distances.append(offsets[i+1] - offsets[i])

from collections import Counter
c = Counter(distances)
print("Distances between FF FC and FF FC:")
for dist, count in c.most_common(10):
    print(f"Distance {dist}: {count} occurrences")
    
if offsets:
    print(f"First few offsets: {offsets[:10]}")

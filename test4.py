import sys
audio_payloads = []
current_buffer = bytearray()
with open('./backend/uploads/wpvi-capture.ts', 'rb') as f:
    while True:
        packet = f.read(188)
        if not len(packet) == 188: break
        if packet[0] != 0x47: continue
        pid = ((packet[1] & 0x1F) << 8) | packet[2]
        payload_start = (packet[1] & 0x40) != 0
        if pid == 0x32:
            afc = (packet[3] & 0x30) >> 4
            offset = 4
            if afc in [2, 3]: offset = 5 + packet[4]
            payload = packet[offset:]
            if payload_start:
                if len(current_buffer) > 0:
                    audio_payloads.append(current_buffer)
                    current_buffer = bytearray()
                if len(payload) > 8 and payload[0:3] == b'\x00\x00\x01':
                    current_buffer.extend(payload[9 + payload[8]:])
            else:
                current_buffer.extend(payload)
if len(current_buffer) > 0: audio_payloads.append(current_buffer)

for idx, p in enumerate(audio_payloads[:5]):
    offsets = [i for i in range(len(p)-1) if p[i] == 0xFF and (p[i+1] & 0xE0) == 0xE0]
    print(f"Payload {idx} length: {len(p)} - syncwords: {offsets}")

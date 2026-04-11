import sys

audio_payloads = []
current_buffer = bytearray()

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
                if len(current_buffer) > 0:
                    audio_payloads.append(current_buffer)
                    current_buffer = bytearray()
                
                if len(payload) > 8 and payload[0:3] == b'\x00\x00\x01':
                    pes_header_len = payload[8]
                    payload = payload[9 + pes_header_len:]
                else:
                    payload = b''
            current_buffer.extend(payload)

if len(current_buffer) > 0:
    audio_payloads.append(current_buffer)

# Inspect first payload
p0 = audio_payloads[0]
print(f"Payload 0 length: {len(p0)}")

offsets = []
for i in range(min(1500, len(p0) - 4)):
    if p0[i] == 0xFF and (p0[i+1] & 0xE0) == 0xE0:
        offsets.append(i)
print(f"Syncwords in Payload 0: {offsets}")


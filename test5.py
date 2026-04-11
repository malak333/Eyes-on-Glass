import sys

with open('./backend/uploads/wpvi-capture.ts', 'rb') as f:
    while True:
        packet = f.read(188)
        if not packet or len(packet) < 188:
            break
        if packet[0] != 0x47:
            continue
            
        pid = ((packet[1] & 0x1F) << 8) | packet[2]
        payload_start = (packet[1] & 0x40) != 0
        
        if payload_start and pid in [0x32, 0x33, 0x34]:
            print(f'First audio-related PID with pusi=1 found: 0x{pid:02X}')
            break

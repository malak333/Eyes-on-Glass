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
        
        if payload_start and pid == 0x34:
            afc = (packet[3] & 0x30) >> 4
            offset = 4
            if afc in [2, 3]:
                afl = packet[4]
                offset = 5 + afl
            
            if offset + 3 < 188:
                if packet[offset] == 0x00 and packet[offset+1] == 0x00 and packet[offset+2] == 0x01:
                    stream_id = packet[offset+3]
                    print(f"PID 0x{pid:02X} has stream_id 0x{stream_id:02X}")

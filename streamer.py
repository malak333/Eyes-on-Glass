import socket
import time
import sys

def stream_ts(filepath, ip, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    
    with open(filepath, 'rb') as f:
        while True:
            chunk = f.read(1316) # 7 * 188
            if not chunk:
                f.seek(0) # Loop forever
                continue
            sock.sendto(chunk, (ip, port))
            time.sleep(0.003) # roughly 3.5 mbps

stream_ts('./backend/uploads/wpvi-capture.ts', '239.0.0.1', 1234)

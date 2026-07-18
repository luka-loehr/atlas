#!/usr/bin/env python3
"""Sends a 10s rainbow chase as Art-Net DMX to localhost:6454 (simulates xLights)."""
import colorsys, socket, struct, sys, time

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
seq = 0
start = time.time()
while time.time() - start < DURATION:
    t = time.time() - start
    dmx = bytearray(18)
    for light in range(6):
        h = (t * 0.25 + light / 6.0) % 1.0        # rotating rainbow, offset per light
        r, g, b = colorsys.hsv_to_rgb(h, 1.0, 1.0)
        dmx[light*3:light*3+3] = bytes([int(r*255), int(g*255), int(b*255)])
    seq = (seq % 255) + 1
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    pkt += bytes([seq, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + bytes(dmx)
    sock.sendto(pkt, ("127.0.0.1", 6454))
    time.sleep(0.04)
# blackout at the end
dmx = bytes(18)
pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
pkt += bytes([1, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx
sock.sendto(pkt, ("127.0.0.1", 6454))
print("test done (rainbow sent for %.0fs)" % DURATION)

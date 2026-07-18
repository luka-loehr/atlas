#!/usr/bin/env python3
"""Standalone strobe tuner — loops the drop strobe forever until Ctrl+C.
Same channel map / lights as show.py's drop strobe.

Usage:
    python3 strobe_test.py                  # defaults: 150ms period, 22% bright
    python3 strobe_test.py 150 22            # period_ms brightness_pct
    python3 strobe_test.py 150 22 40         # + on-fraction pct (duty cycle)
"""
import socket, struct, sys, time

ARTNET_TARGET = ("192.168.1.100", 6454)
FPS = 25
NCHAN = 20
DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH = 3, 6, 9, 12, 15
STROBE_LIGHTS = [DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]

period_ms = float(sys.argv[1]) if len(sys.argv) > 1 else 150
bright_pct = float(sys.argv[2]) if len(sys.argv) > 2 else 22
duty_pct = float(sys.argv[3]) if len(sys.argv) > 3 else 50   # % of period lights are ON

def artnet(dmx, seq):
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    return pkt + bytes([seq & 0xff, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"strobe: period={period_ms}ms  bright={bright_pct}%  duty={duty_pct}%  (~{1000/period_ms:.1f} flashes/s)  Ctrl+C to stop")
    seq = 0
    t0 = time.monotonic()
    try:
        while True:
            t_ms = (time.monotonic() - t0) * 1000.0
            phase = t_ms % period_ms
            on = phase < (period_ms * duty_pct / 100.0)
            v = int(255 * bright_pct / 100.0) if on else 0
            dmx = bytearray(NCHAN)
            for ch in STROBE_LIGHTS:
                dmx[ch] = dmx[ch+1] = dmx[ch+2] = v
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(bytes(dmx), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
    except KeyboardInterrupt:
        pass
    finally:
        for _ in range(3):
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(bytes(NCHAN), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
        print("\nstopped")

if __name__ == "__main__":
    main()

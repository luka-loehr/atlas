#!/usr/bin/env python3
"""Standalone fog burst (heartbeat protocol): python3 fog_trigger.py 800
Only use while hue_stream.py is NOT running (both need /dev/ttyACM0)."""
import serial, sys, time

ms = int(sys.argv[1]) if len(sys.argv) > 1 else 800
s = serial.Serial("/dev/ttyACM0", 9600, timeout=0)
time.sleep(2)             # Uno resets when the port opens
end = time.time() + ms / 1000.0
while time.time() < end:  # keep the heartbeat alive for the burst duration
    s.write(b"1"); s.flush()
    time.sleep(0.2)
s.write(b"0"); s.flush()
s.close()
print(f"fog {ms}ms done")

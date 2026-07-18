import serial, time, sys
ms = sys.argv[1] if len(sys.argv) > 1 else "800"
s = serial.Serial('/dev/ttyACM0', 9600, timeout=float(ms)/1000 + 3)
time.sleep(2)             # wait for Uno reset after port open
s.reset_input_buffer()
s.write((ms + "\n").encode())
resp = s.readline().decode(errors='replace').strip()
print("Arduino:", resp or "(keine Antwort)")
s.close()

#!/usr/bin/env python3
"""Art-Net -> Hue Entertainment bridge + fog machine cue.

Listens for Art-Net DMX (UDP 6454), maps channels to the LightShow
entertainment group, streams via DTLS-PSK (openssl s_client subprocess).
Channel 19 drives the fog machine via the Arduino on /dev/ttyACM0.

DMX channel map (1-based):
   1- 3  R,G,B  light 17  Deckenlampe
   4- 6  R,G,B  light 13  Display pixel 1 (Play bar, ex-Gruen)
   7- 9  R,G,B  light 20  Regal Hinten
  10-12  R,G,B  light 16  Regal Links
  13-15  R,G,B  light 12  Display pixel 2 (Play bar, ex-Rot)
  16-18  R,G,B  light 23  Regal Rechts
  19            fog: value >= 128 -> fog on (heartbeat to Arduino)
"""
import json, os, signal, socket, ssl, struct, subprocess, sys, time, urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
CRED = json.load(open(os.path.join(BASE, "credentials.json")))
HOST, USER, KEY, GROUP = CRED["host"], CRED["username"], CRED["clientKey"], CRED["group"]

LIGHT_ORDER = [17, 13, 20, 16, 12, 23]   # entertainment group v1 light ids
FPS_DELAY = 0.04                         # 25 fps
ARTNET_PORT = 6454
FOG_IDX = 18                             # 0-based index of DMX channel 19
FOG_THRESHOLD = 128                      # >= 50% -> fog
FOG_HEARTBEAT = 0.2                      # refresh "on" every 200 ms
FOG_PORT = "/dev/ttyACM0"

def set_streaming(active: bool):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(
        f"https://{HOST}/api/{USER}/groups/{GROUP}",
        data=json.dumps({"stream": {"active": active}}).encode(),
        method="PUT")
    with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
        return json.load(r)

def build_frame(dmx: bytes) -> bytes:
    msg = bytearray(b"HueStream")
    msg += bytes([1, 0, 0, 0, 0, 0, 0])   # v1.0, seq, 2x reserved, RGB, reserved
    for i, lid in enumerate(LIGHT_ORDER):
        r = dmx[i*3]   if i*3   < len(dmx) else 0
        g = dmx[i*3+1] if i*3+1 < len(dmx) else 0
        b = dmx[i*3+2] if i*3+2 < len(dmx) else 0
        msg += struct.pack(">BHHHH", 0, lid, r*257, g*257, b*257)
    return bytes(msg)

def open_fog():
    try:
        import serial
        s = serial.Serial(FOG_PORT, 9600, timeout=0)
        print(f"fog serial connected ({FOG_PORT})", flush=True)
        return s
    except Exception as e:
        print(f"(fog disabled, no serial: {e})", flush=True)
        return None

def main():
    fog = open_fog()   # opening resets the Uno; it reboots during the DTLS wait below

    print(f"enabling streaming on group {GROUP}...", flush=True)
    print(set_streaming(True), flush=True)
    time.sleep(1.0)

    print("starting DTLS handshake (openssl s_client)...", flush=True)
    proc = subprocess.Popen(
        ["openssl", "s_client", "-dtls1_2", "-quiet",
         "-cipher", "PSK-AES128-GCM-SHA256",
         "-psk_identity", USER, "-psk", KEY,
         "-connect", f"{HOST}:2100"],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE)
    time.sleep(2.0)
    if proc.poll() is not None:
        sys.exit("DTLS FAILED:\n" + proc.stderr.read().decode(errors="replace"))
    print("DTLS up. listening for Art-Net on :%d" % ARTNET_PORT, flush=True)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", ARTNET_PORT))
    sock.settimeout(FPS_DELAY)

    dmx = bytes(19)
    fog_on = False
    fog_hb = 0.0
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    last_log = 0.0
    while running:
        try:
            pkt, _ = sock.recvfrom(1024)
            if pkt[:8] == b"Art-Net\x00" and pkt[8:10] == b"\x00\x50":  # OpDmx
                length = struct.unpack(">H", pkt[16:18])[0]
                dmx = pkt[18:18+length]
                if time.time() - last_log > 2:
                    print("dmx:", list(dmx[:19]), flush=True)
                    last_log = time.time()
        except socket.timeout:
            pass
        if proc.poll() is not None:
            sys.exit("DTLS connection died:\n" + proc.stderr.read().decode(errors="replace"))
        try:
            proc.stdin.write(build_frame(dmx))
            proc.stdin.flush()
        except BrokenPipeError:
            sys.exit("DTLS pipe broke")

        # fog cue (channel 19)
        if fog is not None:
            want = len(dmx) > FOG_IDX and dmx[FOG_IDX] >= FOG_THRESHOLD
            now = time.time()
            try:
                if want and (not fog_on or now - fog_hb >= FOG_HEARTBEAT):
                    fog.write(b"1"); fog.flush()
                    fog_on, fog_hb = True, now
                elif not want and fog_on:
                    fog.write(b"0"); fog.flush()
                    fog_on = False
            except Exception as e:
                print("fog serial error:", e, flush=True)
                fog = None

        time.sleep(FPS_DELAY)

    print("shutting down...", flush=True)
    if fog is not None and fog_on:
        try:
            fog.write(b"0"); fog.flush()
        except Exception:
            pass
    proc.terminate()
    try:
        print(set_streaming(False), flush=True)
    except Exception as e:
        print("(stream-off failed: %s)" % e, flush=True)

if __name__ == "__main__":
    main()

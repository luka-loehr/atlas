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
import json, os, signal, socket, ssl, struct, subprocess, sys, threading, time, urllib.request

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

LASER_IDX = 19                           # 0-based index of DMX channel 20
LASER_THRESHOLD = 128                    # >= 50% -> laser plug on
LASER_V1 = "22"                          # Hue plug (ex-Kaktus) v1 light id

def set_laser(on):
    """Toggle the laser's Hue plug via the v1 REST API, in a background
    thread so the 25fps stream never stalls on the HTTP round-trip."""
    def _do():
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            req = urllib.request.Request(
                f"https://{HOST}/api/{USER}/lights/{LASER_V1}/state",
                data=json.dumps({"on": bool(on)}).encode(), method="PUT")
            urllib.request.urlopen(req, context=ctx, timeout=5).read()
        except Exception as e:
            print("laser toggle error:", e, flush=True)
    threading.Thread(target=_do, daemon=True).start()

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
    sock.setblocking(False)

    dmx = bytes(20)
    fog_on = False
    fog_hb = 0.0
    laser_on = False
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    last_log = 0.0
    next_frame = time.monotonic()
    while running:
        # Drain ALL pending Art-Net packets each tick. Two independent 25fps
        # clocks (sender + this bridge) mean a single narrow on-pulse packet
        # can arrive and be immediately overwritten by the next off packet
        # before we ever send it out -> flashes silently vanish (looked like
        # random "bursts"/aliasing on short strobes). Fix: peak-hold across
        # everything received this tick, seeded from the last known state,
        # so a brief flash always survives into the next output frame.
        peak = bytearray(dmx)
        got = False
        while True:
            try:
                pkt = sock.recv(2048)
            except BlockingIOError:
                break
            if pkt[:8] == b"Art-Net\x00" and pkt[8:10] == b"\x00\x50":  # OpDmx
                length = struct.unpack(">H", pkt[16:18])[0]
                frame = pkt[18:18+length]
                dmx = frame                              # true latest -> next tick's baseline
                got = True
                for i in range(min(len(frame), len(peak))):
                    if frame[i] > peak[i]:
                        peak[i] = frame[i]
        if got and time.time() - last_log > 2:
            print("dmx:", list(dmx[:19]), flush=True)
            last_log = time.time()

        if proc.poll() is not None:
            sys.exit("DTLS connection died:\n" + proc.stderr.read().decode(errors="replace"))

        now = time.monotonic()
        if now < next_frame:
            time.sleep(0.002)
            continue
        next_frame += FPS_DELAY
        if now - next_frame > 0.25:        # fell behind -> resync instead of spiralling
            next_frame = now + FPS_DELAY

        try:
            proc.stdin.write(build_frame(bytes(peak)))
            proc.stdin.flush()
        except BrokenPipeError:
            sys.exit("DTLS pipe broke")

        # fog cue (channel 19)
        if fog is not None:
            want = len(dmx) > FOG_IDX and dmx[FOG_IDX] >= FOG_THRESHOLD
            t = time.time()
            try:
                if want and (not fog_on or t - fog_hb >= FOG_HEARTBEAT):
                    fog.write(b"1"); fog.flush()
                    fog_on, fog_hb = True, t
                elif not want and fog_on:
                    fog.write(b"0"); fog.flush()
                    fog_on = False
            except Exception as e:
                print("fog serial error:", e, flush=True)
                fog = None

        # laser cue (channel 20) -> Hue plug on/off, only on transitions
        if len(dmx) > LASER_IDX:
            want_laser = dmx[LASER_IDX] >= LASER_THRESHOLD
            if want_laser != laser_on:
                set_laser(want_laser)
                laser_on = want_laser
                print("laser ->", "ON" if want_laser else "OFF", flush=True)

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

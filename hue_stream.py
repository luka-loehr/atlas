#!/usr/bin/env python3
"""Art-Net -> Hue Entertainment bridge.

Listens for Art-Net DMX (UDP 6454), maps channels to the LightShow
entertainment group, streams via DTLS-PSK (openssl s_client subprocess).

DMX channel map (1-based):
   1- 3  R,G,B  light 17  Deckenlampe
   4- 6  R,G,B  light 13  Display (was Gruen)
   7- 9  R,G,B  light 20  Regal-Strip
  10-12  R,G,B  light 16  Schreibtisch-Strip
  13-15  R,G,B  light 12  Display (was Rot)
  16-18  R,G,B  light 23  Regal-Strip
"""
import json, os, signal, socket, ssl, struct, subprocess, sys, time, urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
CRED = json.load(open(os.path.join(BASE, "credentials.json")))
HOST, USER, KEY, GROUP = CRED["host"], CRED["username"], CRED["clientKey"], CRED["group"]

LIGHT_ORDER = [17, 13, 20, 16, 12, 23]   # entertainment group v1 light ids
FPS_DELAY = 0.04                         # 25 fps
ARTNET_PORT = 6454

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

def main():
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

    dmx = bytes(18)
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
                    print("dmx:", list(dmx[:18]), flush=True)
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
        time.sleep(FPS_DELAY)

    print("shutting down: disabling streaming...", flush=True)
    proc.terminate()
    try:
        print(set_streaming(False), flush=True)
    except Exception as e:
        print("(stream-off failed: %s)" % e, flush=True)

if __name__ == "__main__":
    main()

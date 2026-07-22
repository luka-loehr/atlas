"""Fixture map + color helpers for the 21-channel Art-Net rig."""
import colorsys
import os

NCHAN = 21
FPS = 25

def _artnet_host():
    """Art-Net bridge host, resolved in order:
    1. ATLAS_ARTNET_HOST env var (IP/hostname of the machine running
       bridge/hue_stream.py)
    2. lightshows/artnet_host.local — gitignored file, single line with the host
    3. default 192.168.1.100
    """
    host = os.environ.get("ATLAS_ARTNET_HOST")
    if host:
        return host
    local = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "artnet_host.local")
    if os.path.exists(local):
        with open(local) as f:
            host = f.read().strip()
        if host:
            return host
    return "192.168.1.100"

ARTNET_TARGET = (_artnet_host(), 6454)

# ---- channel map (0-based DMX index) -----------------------------------
DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH = 0, 3, 6, 9, 12, 15
FOG, LASER, STROBE_PLUG = 18, 19, 20

DISPLAY = [DISPLAY1, DISPLAY2]
REGALE = [REGAL_HINT, REGAL_LINK, REGAL_RECH]
ALL_LIGHTS = [DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]
STROBE_CH = [DISPLAY1, DISPLAY2, REGAL_HINT, REGAL_LINK, REGAL_RECH]
CIRCLE = [[REGAL_HINT], [REGAL_LINK], DISPLAY, [REGAL_RECH]]

GROUPS = {
    "all": ALL_LIGHTS, "regale": REGALE, "display": DISPLAY,
    "strobe_ch": STROBE_CH, "decke": [DECKE],
    "display_regale": [*DISPLAY, *REGALE],
}

def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))

def hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, clamp(v))
    return int(255 * r), int(255 * g), int(255 * b)

def put(dmx, ch, rgb):
    dmx[ch], dmx[ch + 1], dmx[ch + 2] = rgb

def put_stop(dmx, stop, rgb):
    for ch in stop:
        put(dmx, ch, rgb)

def black(dmx):
    for ch in ALL_LIGHTS:
        put(dmx, ch, (0, 0, 0))

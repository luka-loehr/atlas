#!/usr/bin/env python3
"""atlas-power-button — clean shutdown on three fast presses of the power button.

Why this exists
---------------
The board's firmware cuts power after a ~4 s hold, and systemd-logind's
`HandlePowerKeyLongPress` only fires at 5 s — a threshold that is hardcoded and
not configurable (systemd RFE #28100). The firmware always wins, so a long
press can never be a clean shutdown on this machine: it is a hard power cut.

That is not academic. On 2026-07-28 the box was switched off that way. The
unclean cut left the NIC without its Wake-on-LAN arming, so `atlas boot` could
not wake it the next morning, and it cost an ext4 journal recovery and a
Postgres WAL redo on the way back up.

So the OS ignores the key entirely (`HandlePowerKey=ignore`) and this daemon
provides the only shutdown gesture instead: three presses inside three seconds.
Every press is brief, so the firmware's hold-to-kill never engages, and three
deliberate taps are not something anyone does by accident while dusting.
"""

import argparse
import os
import select
import struct
import subprocess
import sys
import time

# struct input_event { struct timeval time; __u16 type, code; __s32 value; }
# The kernel timestamp is deliberately ignored — we use CLOCK_MONOTONIC here so
# a clock step (NTP, suspend/resume) cannot make three presses look like one.
EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

EV_KEY = 0x01
KEY_POWER = 116
VALUE_PRESS = 1

PRESSES_REQUIRED = 3
WINDOW_SECONDS = 3.0


def find_power_buttons():
    """Every input device that reports itself as a power button.

    There are usually two (PNP0C0C and LNXPWRBN) and which one actually emits
    varies by firmware, so open all of them rather than guessing. Matching on
    the name instead of a fixed event number because event numbering is not
    stable across reboots.
    """
    paths, name, handlers = [], None, None
    try:
        with open("/proc/bus/input/devices") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("N: Name="):
                    name = line.split("=", 1)[1].strip('"')
                elif line.startswith("H: Handlers="):
                    handlers = line.split("=", 1)[1].split()
                elif not line:  # blank line ends a device block
                    name, handlers = None, None
                    continue
                if name and handlers and "power button" in name.lower():
                    for h in handlers:
                        if h.startswith("event"):
                            paths.append(f"/dev/input/{h}")
                    name, handlers = None, None
    except OSError as e:
        print(f"cannot read /proc/bus/input/devices: {e}", file=sys.stderr)
    return sorted(set(paths))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="log the gesture instead of powering off (used to test the wiring)",
    )
    ap.add_argument(
        "device",
        nargs="*",
        help="input devices to watch; default is every power button found. "
        "Accepts a fifo of synthetic input_event structs, which is how the "
        "gesture is tested without a finger on the real button.",
    )
    args = ap.parse_args()

    paths = args.device or find_power_buttons()
    if not paths:
        print("no power button input device found", file=sys.stderr)
        return 1

    fds = {}
    for p in paths:
        try:
            fds[os.open(p, os.O_RDONLY)] = p
        except OSError as e:
            print(f"cannot open {p}: {e}", file=sys.stderr)
    if not fds:
        print("power button found but not readable (needs root)", file=sys.stderr)
        return 1

    print(
        f"watching {', '.join(fds.values())} — "
        f"{PRESSES_REQUIRED} presses within {WINDOW_SECONDS:g}s trigger poweroff"
        + (" [DRY RUN]" if args.dry_run else ""),
        flush=True,
    )

    presses = []
    poller = select.poll()
    for fd in fds:
        poller.register(fd, select.POLLIN)

    while True:
        for fd, _ in poller.poll():
            data = os.read(fd, EVENT_SIZE)
            if len(data) != EVENT_SIZE:
                continue
            _, _, etype, code, value = struct.unpack(EVENT_FORMAT, data)
            if etype != EV_KEY or code != KEY_POWER or value != VALUE_PRESS:
                continue

            now = time.monotonic()
            # Keep only presses still inside the window, then add this one.
            presses = [t for t in presses if now - t < WINDOW_SECONDS]
            presses.append(now)
            print(f"press {len(presses)}/{PRESSES_REQUIRED}", flush=True)

            if len(presses) >= PRESSES_REQUIRED:
                presses.clear()  # so a 4th press cannot queue a second shutdown
                if args.dry_run:
                    print("GESTURE MATCHED — would run: systemctl poweroff", flush=True)
                else:
                    print("gesture matched — powering off", flush=True)
                    subprocess.run(["systemctl", "poweroff"], check=False)
                    return 0


if __name__ == "__main__":
    sys.exit(main())

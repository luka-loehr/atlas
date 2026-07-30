# power-button — clean shutdown on three fast presses

Press the physical power button **three times within three seconds** and atlas
shuts down cleanly. A single press does nothing.

## Why not just use the power button normally

The board's firmware cuts power after a ~4 s hold, and systemd-logind's
`HandlePowerKeyLongPress` only fires at **5 s** — a threshold that is
[hardcoded and not configurable](https://github.com/systemd/systemd/issues/28100).
The firmware always wins the race, so on this machine a long press can never be
a clean shutdown. It is a hard power cut, every time.

That is not theoretical. On 2026-07-28 the box was switched off that way:

- the NIC never entered its Wake-on-LAN armed state, so `atlas boot` could not
  wake it the following morning — the machine had to be switched on by hand
- ext4 recovered its journal on `/` and `/boot`, and `/boot`'s dirty bit was set
- Postgres did a crash recovery (`database system was not properly shut down`)

Nothing was lost — WAL did its job — but none of it needed to happen.

So logind is told to ignore the key entirely and this daemon owns the gesture
instead. Three brief taps never approach the firmware's hold threshold, and
three deliberate presses inside three seconds is not something that happens by
accident.

## Install

    sudo cp atlas-power-button.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now atlas-power-button

It requires logind to ignore the key, which
`/etc/systemd/logind.conf.d/10-power-button.conf` does:

    [Login]
    HandlePowerKey=ignore
    HandlePowerKeyLongPress=ignore

Both are `ignore` on purpose. Setting `HandlePowerKeyLongPress=poweroff` looks
like a safety net and is dead config — the firmware cuts power at 4 s, so
logind's 5 s handler is never reached.

## How it works

Reads `EV_KEY` / `KEY_POWER` press events straight from the input devices,
keeps the timestamps of recent presses, and shells out to `systemctl poweroff`
when three land inside the window.

- Devices are found **by name** from `/proc/bus/input/devices`, not by a fixed
  `eventN` path — event numbering is not stable across reboots. There are
  usually two power buttons (`PNP0C0C` and `LNXPWRBN`) and which one actually
  emits varies by firmware, so both are watched.
- Timing uses `CLOCK_MONOTONIC`, not the kernel event timestamp, so an NTP step
  cannot make three presses look like one.
- After firing, the press buffer is cleared, so a fourth press cannot queue a
  second shutdown.

## Testing it without a finger on the button

The daemon takes optional device paths, so a fifo of synthetic `input_event`
structs stands in for the real hardware:

    mkfifo /tmp/fifo
    ./power-button.py --dry-run /tmp/fifo &
    python3 -c 'import struct,time
    ev=struct.pack("llHHi",0,0,1,116,1)
    f=open("/tmp/fifo","wb",buffering=0)
    [ (time.sleep(0.3), f.write(ev)) for _ in range(3) ]'

`--dry-run` logs the match instead of powering off. Verified behaviour:

| input | result |
|---|---|
| 3 presses, 0.3 s apart | fires |
| 3 presses, 0.9 s apart | fires |
| 3 presses, 1.6 s apart (spans > 3 s) | no fire |
| 2 presses | no fire |
| 1 press | no fire |
| 5 rapid presses | fires **once** |

## Tuning

`PRESSES_REQUIRED` and `WINDOW_SECONDS` at the top of the script. Keep the
window comfortably under 4 s so the gesture can never blur into a firmware hold.

# power — stay wakeable, stay measurable

Host units for a power-managed box. atlas auto-boots via RTC wake (06:30 on
weekdays, 08:00 on weekends; no automatic shutdown), `atlas boot` can wake it
at any other time, and the iOS apps plot how much it draws while it is up.

| Unit | What it does |
|---|---|
| `atlas-wol.service` | `ethtool -s enp4s0 wol g` at boot **and** at shutdown — the NIC keeps MagicPacket wake armed, which is what `atlas boot` sends |
| `atlas-rapl-readable.service` | `chmod a+r` on the Intel RAPL energy counters, which the kernel keeps root-only — without it `atlas-server` reports `cpu_w` (and with it `system_w`) as `null` |
| `atlas-rtcwake.service` | arms the RTC alarm for the next 06:30 (Mon–Fri) or 08:00 (Sat–Sun) at boot **and** at shutdown (`/usr/local/sbin/atlas-rtcwake`) |
| `atlas-poweroff.timer` | optional legacy nightly shutdown unit (disabled by default in `install.sh`) |

```bash
./install.sh
systemctl status atlas-wol atlas-rapl-readable   # `active (exited)` is correct for a oneshot
```

`install.sh` copies the units into `/etc/systemd/system`, puts a root-owned
copy of `atlas-rtcwake` in `/usr/local/sbin` (re-run it after changing that
script), and removes the earlier hand-installed `wol.service` /
`rapl-readable.service` if present.

## Auto-boot schedule: 06:30 Mon–Fri, 08:00 Sat–Sun (no auto-shutdown)

The RTC has one alarm register, so `atlas-rtcwake` arms only the next morning
slot (`06:30` on Monday–Friday, `08:00` on Saturday–Sunday, local time). It
runs at boot and again in `ExecStop`, so every manual shutdown (`power` button
or `atlas shutdown`) leaves the alarm set for the next morning. It verifies the
register after writing, because a past-dated write succeeds and arms nothing.
Check it with `journalctl -t atlas-rtcwake -n 3` or
`cat /sys/class/rtc/rtc0/wakealarm` (epoch seconds).

Automatic nightly shutdown (`atlas-poweroff.timer`) is disabled by default so
the box stays online unless shut down manually. Change the wake times in
`atlas-rtcwake` (`WAKE_WEEKDAY`, `WAKE_WEEKEND`) and re-run `./install.sh`.

This board wakes from soft-off on the RTC alarm; the 2026-08 three-slot
schedule used the same register.

## Wake-on-LAN

Firmware first: enable Wake-on-LAN in the BIOS/UEFI and disable any ErP/EuP
"deep sleep" mode, which cuts standby power to the NIC. On the OS side the
persistent switch is netplan's `wakeonlan: true` (see
[docs/SETUP.md](../../docs/SETUP.md)); this unit re-asserts wake mode `g`
after boot because a driver reset or a resume can drop the NIC back to `d`,
and from the Mac there is no other way in — a box that will not wake needs
someone physically in front of it.

`ExecStop` repeats `ExecStart` deliberately: the setting has to survive the
shutdown that is about to happen, which is precisely when it matters.

The interface name `enp4s0` is baked into the unit. Check yours with
`ip -br link`; if it differs, edit `atlas-wol.service` and run
`ATLAS_WOL_NIC=<name> ./install.sh`. `install.sh` does not rewrite the unit — it
only checks that the interface in `ATLAS_WOL_NIC` (default `enp4s0`) exists and
refuses to install anything when it does not.

## RAPL

`atlas-server`'s `system/metrics/readers.rs` reads
`/sys/class/powercap/intel-rapl:0/energy_uj` for the energy delta and
`max_energy_range_uj` to detect counter wrap — both need to be world-readable,
and both are chmod'ed here. The chmod is per boot: sysfs is recreated every
time, so this is a unit rather than a one-off.

Intel-only. On a machine without RAPL the unit still succeeds and `cpu_w`
stays `null`, which the API and the apps already treat as "not measurable".

The system-power figure the apps show is a calibrated estimate
(`(cpu_w + gpu_w + baseline) / psu_efficiency`, tuned via
`ATLAS_POWER_BASELINE_W` and `ATLAS_PSU_EFFICIENCY` in `/etc/atlas/atlas.env`,
defaults 35 W and 0.88) — only a wall-plug meter is exact.

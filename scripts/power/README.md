# power — stay wakeable, stay measurable

Host units for a power-managed box. atlas runs on a daily schedule (up 10:00 to
22:00), `atlas boot` has to be able to wake it at any other time, and the iOS
apps plot how much it draws while it is up.

| Unit | What it does |
|---|---|
| `atlas-wol.service` | `ethtool -s enp4s0 wol g` at boot **and** at shutdown — the NIC keeps MagicPacket wake armed, which is what `atlas boot` sends |
| `atlas-rapl-readable.service` | `chmod a+r` on the Intel RAPL energy counters, which the kernel keeps root-only — without it `atlas-server` reports `cpu_w` (and with it `system_w`) as `null` |
| `atlas-rtcwake.service` | arms the RTC alarm for the next 10:00 at boot **and** at shutdown (`/usr/local/sbin/atlas-rtcwake`) |
| `atlas-poweroff.timer` | at 21:55 schedules `shutdown -h 22:00`; logged-in users get the warning |

```bash
./install.sh
systemctl status atlas-wol atlas-rapl-readable   # `active (exited)` is correct for a oneshot
```

## Daily schedule: on at 10:00, off at 22:00

The RTC has one alarm register, so `atlas-rtcwake` arms only the next 10:00. It
runs at boot and again in `ExecStop`, so every shutdown (the scheduled one, the
power button, `atlas shutdown`) leaves the alarm set for the next morning. It
verifies the register after writing, because a past-dated write succeeds and
arms nothing. Check it with `journalctl -t atlas-rtcwake -n 3` or
`cat /sys/class/rtc/rtc0/wakealarm` (epoch seconds).

The power-off timer is not persistent: a box booted after 21:55 stays up until
the next evening. To keep atlas up tonight, run `sudo shutdown -c` after 21:55.
Change the times in `atlas-rtcwake` (`WAKE_AT`) and `atlas-poweroff.timer`,
then re-run `./install.sh`. Both stay outside the 22:00–08:00 quiet hours.

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
`ip -br link` and edit the unit if it differs; `install.sh` refuses to install
a unit naming an interface this box does not have.

## RAPL

`atlas-server`'s `system/metrics.rs` reads
`/sys/class/powercap/intel-rapl:0/energy_uj` for the energy delta and
`max_energy_range_uj` to detect counter wrap — both need to be world-readable,
and both are chmod'ed here. The chmod is per boot: sysfs is recreated every
time, so this is a unit rather than a one-off.

Intel-only. On a machine without RAPL the unit still succeeds and `cpu_w`
stays `null`, which the API and the apps already treat as "not measurable".

The system-power figure the apps show is a calibrated estimate
(`(cpu_w + gpu_w + baseline) / psu_efficiency`, tuned via `ATLAS_POWER_*` in
`/etc/atlas/atlas.env`) — only a wall-plug meter is exact.

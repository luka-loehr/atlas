# power — stay wakeable, stay measurable

Two host oneshots with no script of their own. They exist because atlas is a
power-managed box: it is asleep most of the day, `atlas boot` has to be able to
wake it, and the iOS apps plot how much it draws while it is up.

| Unit | What it does |
|---|---|
| `atlas-wol.service` | `ethtool -s enp4s0 wol g` at boot **and** at shutdown — the NIC keeps MagicPacket wake armed, which is what `atlas boot` sends |
| `atlas-rapl-readable.service` | `chmod a+r` on the Intel RAPL energy counters, which the kernel keeps root-only — without it `atlas-api` reports `cpu_w` (and with it `system_w`) as `null` |

```bash
./install.sh
systemctl status atlas-wol atlas-rapl-readable   # `active (exited)` is correct for a oneshot
```

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

`atlas-api`'s `metrics.rs` reads
`/sys/class/powercap/intel-rapl:0/energy_uj` for the energy delta and
`max_energy_range_uj` to detect counter wrap — both need to be world-readable,
and both are chmod'ed here. The chmod is per boot: sysfs is recreated every
time, so this is a unit rather than a one-off.

Intel-only. On a machine without RAPL the unit still succeeds and `cpu_w`
stays `null`, which the API and the apps already treat as "not measurable".

The system-power figure the apps show is a calibrated estimate
(`(cpu_w + gpu_w + baseline) / psu_efficiency`, tuned via `ATLAS_POWER_*` in
`/etc/atlas-api.env`) — only a wall-plug meter is exact.

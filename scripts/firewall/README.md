# atlas host firewall

Confines the private HTTP service to loopback and the tailnet:

| Port | Service | What it serves |
|---|---|---|
| 8787 | `atlas-server` | the photo library, the drive, machine status, power control and a terminal |

The listener binds `0.0.0.0`, so without this table every device on the home
LAN could reach it. Every route except `/health` needs the bearer token, but
one of those routes is a shell on the machine: the network layer says no
before the application is ever asked.

The rules live in an `inet` table, so the day a bind changes to `[::]` the
LAN does not silently gain access over IPv6 either.

## Install

```bash
./install.sh
```

Copies `firewall.nft` to `/etc/atlas/firewall.nft`, syntax-checks it,
installs and enables `atlas-firewall.service`. Re-run it after editing the
ruleset — the file is idempotent, so re-loading replaces the table rather than
stacking rules.

## Checking it

```bash
sudo nft -a list table inet atlas-fw     # rules plus per-rule packet counters
systemctl status atlas-firewall
```

The counters are the useful part: the `lo` rule ticks for `tailscale serve`
and the healthcheck, the `tailscale0` rule ticks for the iPhone and MacBook,
and the `drop` rule ticks for anything on the LAN that tried.

Lift it temporarily (until the next boot or `systemctl start`):

```bash
sudo systemctl stop atlas-firewall
```

## Why a separate `inet atlas-fw` table

`nft list ruleset` labels `ip filter` and `ip6 filter` *"managed by
iptables-nft, do not touch!"* — they belong to tailscale and docker, which
recreate their chains on `tailscale up` and `systemctl restart docker`. The
stock `/etc/nftables.conf` is worse: it opens with `flush ruleset`, so
enabling `nftables.service` would wipe both at boot.

nftables lets several base chains register on the same hook; they all run, in
priority order, and a `drop` in any one of them is final. So this table sits at
`priority filter - 10` in its own namespace, needs no cooperation from the
others, and cannot be clobbered by them.

Two deliberate choices keep the blast radius small:

- **Only `tcp dport 8787` is matched at all.** No other traffic on this
  host changes behaviour.
- **`policy accept`.** If the ruleset were ever wrong, it fails open rather
  than locking the box out. The drop is an explicit rule, not a default.

`drop`, not `reject`: a scanner gets a timeout, not a closed-port signal.

## Scope

`lo` is accepted because atlas reaches its own LAN and tailnet addresses
through it (`ip route get 192.168.1.100` → `dev lo`), which covers the
healthcheck probes and `tailscale serve` proxying to `127.0.0.1:8787`.


Docker-published ports cannot be covered by this table at all. A published
container port is DNAT'd in `nat/prerouting` and then traverses the `forward`
hook; it never reaches `hook input`, the only hook this ruleset registers.
Adding such a port to `private_ports` would look like confinement and block
nothing — confine those at the bind address in their `compose.yml` instead.

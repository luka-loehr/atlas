# atlas host firewall

Confines the two private HTTP services to loopback and the tailnet:

| Port | Service | What is exposed without this |
|---|---|---|
| 8787 | `atlas-api` | metrics, Docker overview, power control (writes are token-gated) |
| 8788 | `atlas-photos` | the whole 24k-photo library — timeline, search, originals, drive |

Both listeners bind `0.0.0.0`/`[::]`, and `atlas-photos` runs with
`ATLAS_PHOTOS_OPEN=1`, which means **GET/HEAD need no token**. That is
deliberate — the iOS apps depend on it — so the network layer, not the
application, is what has to say no to the LAN.

Before this existed, any device on `192.168.1.0/24` could run
`curl http://192.168.1.100:8788/api/stats` and page the library.

The exposure was IPv4-only, because both services bind `0.0.0.0` rather than
`[::]` — `ss -ltnp` shows no IPv6 socket for either port, and a request to
atlas' own globally routable `2001:db8:1::/64` address is refused
even with the firewall stopped. The rules live in an `inet` table anyway, so
the day a bind changes to `[::]` the LAN does not silently regain access.

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

- **Only `tcp dport 8787`/`8788` is matched at all.** No other traffic on this
  host changes behaviour.
- **`policy accept`.** If the ruleset were ever wrong, it fails open rather
  than locking the box out. The drop is an explicit rule, not a default.

`drop`, not `reject`: a scanner gets a timeout, not a closed-port signal.

## Scope

`lo` is accepted because atlas reaches its own LAN and tailnet addresses
through it (`ip route get 192.168.1.100` → `dev lo`), which covers the
healthcheck probes and `tailscale serve` proxying to `127.0.0.1:8788`.

Not covered: Art-Net on `0.0.0.0:6454/udp`, which is unauthenticated and
drives physical hardware. It is left open because the Art-Net source is
configured as `192.168.1.100` (see `/etc/atlas/lightshow-artnet-host`) —
closing it means moving the lightshow onto the tailnet first.

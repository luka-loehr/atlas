# adguard — DNS for the tailnet

AdGuard Home resolves and filters DNS for every device on the tailnet, and is
the resolver the exit node hands out. It is the reason a phone on mobile data,
routed through atlas, gets the same ad filtering as a device at home.

```bash
docker compose up -d      # start, or apply a change to this file
docker compose logs -f    # follow
docker compose down       # stop (config survives — it is on the host)
```

## Where it listens, and why

| Address | Purpose |
|---|---|
| `100.x.y.z:53` (tcp+udp) | DNS, **tailnet address only** — `$ATLAS_TAILNET_IP` |
| `127.0.0.1:3053` | admin UI, loopback only |

`100.x.y.z` is a placeholder for this box's own tailnet address. It comes from
`ATLAS_TAILNET_IP` in the `.env` next to `compose.yml` and **has no default** —
`compose.yml` uses `${ATLAS_TAILNET_IP:?…}`, so with the variable unset
`docker compose up` fails immediately instead of starting a container bound to
some other address. Read the real value off the box with `tailscale ip -4`.

DNS is deliberately not published on `0.0.0.0` or the LAN address. A resolver
reachable from the internet is an amplification weapon, and this box sits
behind a router whose port forwarding is one checkbox away from making that
true. The tailnet is the boundary.

That boundary is the publish address and nothing else. There is no second line
of defence: [atlas-firewall](../../scripts/firewall/) matches only tcp/8787 and
tcp/8788, and adding 53 to its port set would not help either. Docker publishes
a port by DNAT in `nat`/`prerouting`, after which the packet traverses the
`forward` hook — it never reaches `input`, which is the only hook the atlas
ruleset registers. Bind this wrong and it is open.

The admin UI has no TLS and holds the filter configuration, so it stays on
loopback. Reach it through an ssh tunnel:

```bash
ssh -L 3053:127.0.0.1:3053 atlas    # then open http://127.0.0.1:3053
```

`atlas-api` reads the same UI endpoint to report blocked-query counts to the
iOS app — see `ATLAS_ADGUARD_URL` / `ATLAS_ADGUARD_AUTH` in
`/etc/atlas-api.env`. If the admin password changes, that file changes too.

## Config lives on the host, not in git

Two bind mounts, defaulting to `~/adguard`:

| Host path | Container path | Holds |
|---|---|---|
| `~/adguard/conf` | `/opt/adguardhome/conf` | `AdGuardHome.yaml`: admin password hash, upstreams, filter lists, per-client rules |
| `~/adguard/work` | `/opt/adguardhome/work` | query log, statistics database |

`conf` contains a password hash and the full client list, which is why it is
not tracked here. **It is also the only copy** — it is not in the nightly
Postgres dump, so a `docker compose down -v` or a lost `~/adguard` means
rebuilding the filter setup by hand. Copy `~/adguard/conf` somewhere safe
before doing anything drastic to it.

The `.env` next to this file carries both the required tailnet address and, if
the box keeps its AdGuard state somewhere other than `~/adguard`, a location
override:

```ini
ATLAS_TAILNET_IP=100.x.y.z          # required — `tailscale ip -4` on this box
ATLAS_ADGUARD_DIR=/mnt/data/adguard # optional — defaults to the home directory
```

## Updating

The image is pinned by tag *and* digest, so `docker compose pull` cannot
silently move to a new version — the digest is what is fetched. To update,
look up the digest of the new release and bump both halves together:

```bash
docker manifest inspect adguard/adguardhome:vX.Y.Z --verbose | grep -m1 digest
# edit compose.yml (tag + digest), then:
docker compose pull && docker compose up -d
```

Back up `~/adguard/conf/AdGuardHome.yaml` first; AdGuard migrates its config
format on upgrade and does not migrate back.

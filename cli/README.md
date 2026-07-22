# atlas — the CLI

One command on the Mac to run the homelab. Wakes the box, powers it down,
forwards anything else straight to SSH, and drives remote builds.

```bash
cargo install --path cli     # installs `atlas`
```

## Commands

| command | what it does |
|---|---|
| `atlas` | interactive SSH session (execs `ssh atlas`) |
| `atlas boot` (`up`, `wake`) | Wake-on-LAN magic packet, then **waits** until SSH answers |
| `atlas shutdown` (`off`, `poweroff`) | powers the box off, waits until it is really down |
| `atlas restart` (`reboot`) | reboot, waits for it to come back |
| `atlas status` | up or down, and **which route** answered (LAN or tailnet) |
| `atlas build [...]` | remote build in a pinned [builder](../builder) image |
| `atlas dev [logs]` | remote dev server + its logs |
| `atlas agent [logs\|status\|stop\|restart]` | manage `atlas-agent.service` |
| `atlas <anything else>` | forwarded verbatim to `ssh atlas` |

## Configuration

All connection settings are environment variables with generic defaults. Set
them in your shell, or in `~/.config/atlas/env` (plain `KEY=VALUE` lines, `#`
comments; real environment variables take precedence):

| variable | default | meaning |
|---|---|---|
| `ATLAS_SSH_HOST` | `atlas` | ssh/rsync host (alias from `~/.ssh/config`) |
| `ATLAS_LAN_ADDR` | `192.168.1.100:22` | LAN ssh route, `host:port` (empty = skip) |
| `ATLAS_TAILNET_ADDR` | `atlas.your-tailnet.ts.net:22` | tailnet ssh route, `host:port` (empty = skip) |
| `ATLAS_WOL_MAC` | `aa:bb:cc:dd:ee:ff` | server NIC MAC for Wake-on-LAN |
| `ATLAS_WOL_BROADCAST` | `192.168.1.255:9` | broadcast address for the magic packet |
| `ATLAS_AGENT_URL` | tailnet host + `:8787` | metrics agent `host:port` |

## How boot/status work

Two routes are probed in order — **LAN** (`ATLAS_LAN_ADDR`, e.g.
`192.168.1.100:22`) first, then the **tailnet** (`ATLAS_TAILNET_ADDR`) — so you
always learn *how* the box is reachable, not just whether.

Wake-on-LAN only works from inside the LAN: the magic packet for MAC
`ATLAS_WOL_MAC` (e.g. `aa:bb:cc:dd:ee:ff`) goes to the broadcast address
`ATLAS_WOL_BROADCAST` (e.g. `192.168.1.255:9`). From outside, wake atlas via
your router's remote wake feature (e.g. MyFRITZ) instead, then use the CLI as
usual over the tailnet.

`boot`/`shutdown`/`restart` are **synchronous** — they poll until the box has
actually reached the new state, so you can chain them in scripts
(`atlas boot && atlas agent`).

## Remote builds

`build` and `dev` are configured per project by a `.atlas-build.toml` in the
project directory:

```toml
name      = "my-app"        # required
image     = "node"          # required — a builder image key (node|lambda|flutter)
dir       = "."             # source dir to sync
build     = "npm run build" # build command inside the container
dev       = "npm run dev"   # dev command
port      = 3000            # port to expose for `dev`
artifacts = "dist"          # what to copy back
```

`name` and `image` are mandatory; the CLI refuses to run without them.

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

## How boot/status work

Two routes are probed in order — **LAN** (`192.168.1.100:22`) first, then the
**tailnet** — so you always learn *how* the box is reachable, not just whether.

Wake-on-LAN only works from inside the LAN: the magic packet for MAC
`aa:bb:cc:dd:ee:ff` goes to the broadcast address `192.168.1.255:9`. From
outside, wake atlas via MyFRITZ instead, then use the CLI as usual over the
tailnet.

`boot`/`shutdown`/`restart` are **synchronous** — they poll until the box has
actually reached the new state, so you can chain them in scripts
(`atlas boot && atlas agent`).

## Remote builds

`build` and `dev` are configured per project by a `.atlas-build.toml` in the
project directory:

```toml
name      = "my-app"        # required
image     = "atlas-node"    # required — a builder image (node|lambda|flutter)
dir       = "."             # source dir to sync
build     = "npm run build" # build command inside the container
dev       = "npm run dev"   # dev command
port      = 3000            # port to expose for `dev`
artifacts = "dist"          # what to copy back
```

`name` and `image` are mandatory; the CLI refuses to run without them.

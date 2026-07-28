# builder — remote build images

One Dockerfile, three targets — the images that
[`atlas build` and `atlas dev`](../cli/) run on the server. The CLI builds
them lazily: on first use it runs
`ssh <host> "cd ~/atlas && git pull --quiet --ff-only && docker build
[--target <target>] -t <tag> builder/<context>"`, then reuses the image.
Manual rebuild is the same `docker build` on the server.

## Images

There are two keys, and `universal` is the default. It carries every
toolchain these repos build with, so a project that mixes two languages — a
pnpm workspace next to a Rust worker — has an image that covers it. Reach
for `mobile` only when the build actually needs Flutter or Android.

| Key | Image tag | Target | Contents |
|---|---|---|---|
| `universal` | `atlas-universal-builder` | `build` | Node 22 + npm/pnpm/yarn (corepack) + Bun, Rust stable + `aarch64-unknown-linux-gnu` + cargo-lambda/Zig, Go, Python 3 + uv, JDK, and the usual native build deps (clang, cmake, ninja, protobuf, openssl/sqlite headers) |
| `universal` (dev) | `atlas-universal-dev` | `dev` | the above **+ cloudflared**, used automatically by `atlas dev` |
| `mobile` | `atlas-universal-mobile` | `mobile` | the above **+ Flutter SDK + Android SDK** (licenses pre-accepted) |

All three are targets of [`universal/Dockerfile`](universal/Dockerfile) and
share their layers, so holding all of them costs roughly what holding the
largest one does.

`mobile` is a separate target rather than part of `build` because the
Flutter and Android SDKs are ~10 G, while everything else fits in a few.
atlas has one 950 G volume that was 75% full when this was written, with
[disk-guard](../scripts/disk-guard/) warning at 85% — so the languages
every repo uses stay cheap, and the mobile stack is only materialised when
a project actually asks for it.

## How a build runs

`atlas build` finds `.atlas-build.toml` (walking up from the current
directory), rsyncs the project to `<server>:~/atlas-builds/<name>`
(excluding `.git`, `target`, `node_modules`, `.next`, `build`), runs the
build command in the matching image with a per-image cache volume
(`~/atlas-builds/.cache-<image>` mounted at `/cache`, wired up as
`CARGO_HOME`, `npm_config_cache`, `PUB_CACHE`, `XDG_CACHE_HOME`,
`GRADLE_USER_HOME`), then rsyncs the declared artifact directories back.

`atlas dev` instead starts a long-running container on the server,
`atlas-dev-<name>` (install + `<dev command>`, `--network host`). The
install step is chosen from the lockfile in the project (`bun.lock*` →
bun, `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, otherwise npm) unless
the config sets `install` explicitly.

By default that container is published on the tailnet only, with
`tailscale serve` on the host — `https://<tailnet host>:<port>`, the port
derived from the project `name` so it stays the same across restarts.
`atlas dev --public` instead starts a second container,
`atlas-tunnel-<name>`, running a cloudflared quick tunnel that prints a
public `trycloudflare.com` URL. That is why the `dev` target carries
cloudflared while `build` does not: a build container cannot open a
tunnel, and the tailnet path needs nothing inside the image at all
(`tailscaled` runs on the host).

## Secrets

Env files are **not** synced. `.env` and `.env.*` are excluded from the
rsync (`.env.example`/`.env.sample` still travel — they hold no values),
because the build tree is a mirror: anything left there is rewritten by
the next sync, or goes silently stale, and sits on disk for as long as the
project does.

Instead each project gets one file on the server, outside the synced tree:

```
atlas secrets push [file]   # default .env.local, else .env — 0600 in a 0700 dir
atlas secrets list          # which projects have one, never the contents
atlas secrets rm            # drop this project's
```

`atlas build` and `atlas dev` pass it to the container with `--env-file`,
so the values arrive as environment variables rather than as a file on
disk. The upload is streamed over ssh stdin, so the contents never appear
in a command line (argv is world-readable in `/proc`) and never land in an
intermediate file. If a project has a local env file but nothing in the
store, the CLI says so instead of running a build that would fail on
missing variables.

The synced tree itself is `0700`, and rsync strips group/other off
everything it transfers — it holds full checkouts of private repos.

## Configuration — `.atlas-build.toml`

A flat `key = "value"` file at the project root of whatever you build:

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | remote build dir (`~/atlas-builds/<name>`) and container name suffix |
| `image` | yes | builder key: `universal` \| `mobile` — nothing else resolves |
| `dir` | no (default `.`) | subdirectory the build/dev command runs in |
| `build` | for `atlas build` | build command run inside the container |
| `artifacts` | for `atlas build` | space-separated directory paths (relative to the project root) copied back after the build |
| `dev` | for `atlas dev` | dev-server command |
| `install` | no (default: detect) | dependency install run before `dev`; override when the lockfile is not the whole story |
| `port` | no (default `3000`) | port the dev server listens on; what `tailscale serve` (or the tunnel) forwards to |

## Operational notes

- Builds run as root inside the container; afterwards the CLI runs
  `sudo chown -R` on the build tree, so the server-side user needs
  passwordless sudo (see [docs/SETUP.md](../docs/SETUP.md)).
- The image is base-pinned, not fully pinned: `debian:bookworm-slim`,
  `node:22`, `golang:1`, the Rust `stable` channel and
  `ghcr.io/cirruslabs/flutter:stable` all track their channel, and
  cloudflared is fetched from `releases/latest` at image-build time (Bun is
  the one exception — `ARG BUN_VERSION` pins it exactly). Rebuilding moves
  the image to current versions; do it deliberately.
- `git config --system --add safe.directory '*'` is set in the image
  because builds run as root over a tree owned by the ssh user, and
  anything that shells out to git would otherwise refuse to run.
- Caches persist across builds per image (`.cache-<image>`), and
  `node_modules` survives inside the synced build dir on the server, so
  second builds are warm.

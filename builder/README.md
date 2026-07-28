# builder — remote build images

Dockerfiles for the images that [`atlas build` and `atlas dev`](../cli/)
run on the server. The CLI builds them lazily: on first use it runs
`ssh <host> "cd ~/atlas && git pull --quiet --ff-only && docker build
[--target <target>] -t <tag> builder/<context>"`, then reuses the image.
Manual rebuild is the same `docker build` on the server.

## Images

`universal` is the one to use. It carries every toolchain these repos
build with, so a project that mixes two languages — a pnpm workspace next
to a Rust worker — has an image that covers it.

| Key | Image tag | Target | Contents |
|---|---|---|---|
| `universal` | `atlas-universal-builder` | `build` | Node 22 + npm/pnpm/yarn (corepack) + Bun, Rust stable + `aarch64-unknown-linux-gnu` + cargo-lambda/Zig, Go, Python 3 + uv, JDK, and the usual native build deps (clang, cmake, ninja, protobuf, openssl/sqlite headers) |
| `universal` (dev) | `atlas-universal-dev` | `dev` | the above **+ cloudflared**, used automatically by `atlas dev` |
| `mobile` | `atlas-universal-mobile` | `mobile` | the above **+ Flutter SDK + Android SDK** (licenses pre-accepted) |

All three come from one [`universal/Dockerfile`](universal/Dockerfile) and
share layers, so holding all of them costs roughly what holding the
largest one does.

`mobile` is a separate target rather than part of `build` because the
Flutter and Android SDKs are ~10 G, while everything else fits in a few.
atlas has one 950 G volume that was 75% full when this was written, with
[disk-guard](../scripts/disk-guard/) warning at 85% — so the languages
every repo uses stay cheap, and the mobile stack is only materialised when
a project actually asks for it.

### Superseded

`lambda`, `node` and `flutter` still resolve to their own one-directory
images so existing configs keep working, but new configs should use
`universal` / `mobile`. Once nothing references them, the images can be
dropped from the server with `docker image rm`.

## How a build runs

`atlas build` finds `.atlas-build.toml` (walking up from the current
directory), rsyncs the project to `<server>:~/atlas-builds/<name>`
(excluding `.git`, `target`, `node_modules`, `.next`, `build`), runs the
build command in the matching image with a per-image cache volume
(`~/atlas-builds/.cache-<image>` mounted at `/cache`, wired up as
`CARGO_HOME`, `npm_config_cache`, `PUB_CACHE`, `XDG_CACHE_HOME`,
`GRADLE_USER_HOME`), then rsyncs the declared artifact directories back.

`atlas dev` instead starts two long-running containers on the server:
`atlas-dev-<name>` (install + `<dev command>`, `--network host`) and
`atlas-tunnel-<name>` (a cloudflared quick tunnel that prints a public
`trycloudflare.com` URL). The install step is chosen from the lockfile in
the project (`bun.lock*` → bun, `pnpm-lock.yaml` → pnpm, `yarn.lock` →
yarn, otherwise npm) unless the config sets `install` explicitly.

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
| `image` | yes | builder key: `universal` \| `mobile` (or the superseded `lambda` \| `node` \| `flutter`) |
| `dir` | no (default `.`) | subdirectory the build/dev command runs in |
| `build` | for `atlas build` | build command run inside the container |
| `artifacts` | for `atlas build` | space-separated directory paths (relative to the project root) copied back after the build |
| `dev` | for `atlas dev` | dev-server command |
| `install` | no (default: detect) | dependency install run before `dev`; override when the lockfile is not the whole story |
| `port` | no (default `3000`) | dev-server port the tunnel forwards |

## Operational notes

- Builds run as root inside the container; afterwards the CLI runs
  `sudo chown -R` on the build tree, so the server-side user needs
  passwordless sudo (see [docs/SETUP.md](../docs/SETUP.md)).
- The images are base-pinned, not fully pinned: `node:22`, `rust:1`,
  `golang:1` and `flutter:stable` track their channels, and Bun and
  cloudflared are fetched at image-build time. Rebuilding moves an image
  to current versions; do it deliberately.
- `git config --system --add safe.directory '*'` is set in the image
  because builds run as root over a tree owned by the ssh user, and
  anything that shells out to git would otherwise refuse to run.
- Caches persist across builds per image (`.cache-<image>`), and
  `node_modules` survives inside the synced build dir on the server, so
  second builds are warm.

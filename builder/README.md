# builder — remote build images

Dockerfiles for the images that [`atlas build` and `atlas dev`](../cli/)
run on the server. The CLI builds them lazily: on first use it runs
`ssh <host> "cd ~/atlas && git pull --quiet --ff-only && docker build -t
atlas-<key>-builder builder/<key>"`, then reuses the image. Manual rebuild
is the same `docker build` on the server.

| Key | Image tag | Base | Purpose |
|---|---|---|---|
| `lambda` | `atlas-lambda-builder` | `rust:1-bookworm` | cross-compiles Rust for AWS Lambda on Graviton (`aarch64-unknown-linux-gnu`) via cargo-lambda + Zig — the Zig sysroot decides the ABI, so an x86 server produces the same artifact a Mac would |
| `node` | `atlas-node-builder` | `node:22-bookworm-slim` | Node/Next.js builds and dev servers; also ships `cloudflared` for the public dev tunnel |
| `flutter` | `atlas-flutter-builder` | `ghcr.io/cirruslabs/flutter:stable` | Flutter + Android SDK (licenses pre-accepted) for APK/AAB builds |

## How a build runs

`atlas build` finds `.atlas-build.toml` (walking up from the current
directory), rsyncs the project to `<server>:~/atlas-builds/<name>`
(excluding `.git`, `target`, `node_modules`, `.next`, `build`), runs the
build command in the matching image with a per-image cache volume
(`~/atlas-builds/.cache-<image>` mounted at `/cache`, wired up as
`CARGO_HOME`, `npm_config_cache`, `PUB_CACHE`, `XDG_CACHE_HOME`,
`GRADLE_USER_HOME`), then rsyncs the declared artifact directories back.

`atlas dev` instead starts two long-running containers on the server:
`atlas-dev-<name>` (`npm install && <dev command>`, `--network host`) and
`atlas-tunnel-<name>` (a cloudflared quick tunnel that prints a public
`trycloudflare.com` URL). Since the dev flow hardcodes `npm install` and
only the node image ships cloudflared, `atlas dev` effectively requires
`image = "node"`.

## Configuration — `.atlas-build.toml`

A flat `key = "value"` file at the project root of whatever you build:

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | remote build dir (`~/atlas-builds/<name>`) and container name suffix |
| `image` | yes | builder key: `lambda` \| `node` \| `flutter` |
| `dir` | no (default `.`) | subdirectory the build/dev command runs in |
| `build` | for `atlas build` | build command run inside the container |
| `artifacts` | for `atlas build` | space-separated directory paths (relative to the project root) copied back after the build |
| `dev` | for `atlas dev` | dev-server command |
| `port` | no (default `3000`) | dev-server port the tunnel forwards |

## Operational notes

- Builds run as root inside the container; afterwards the CLI runs
  `sudo chown -R` on the build tree, so the server-side user needs
  passwordless sudo (see [docs/SETUP.md](../docs/SETUP.md)).
- The images are base-pinned, not fully pinned: `rust:1` and
  `flutter:stable` track their channels, and cloudflared is fetched from
  the latest GitHub release at image-build time. Rebuilding an image moves
  it to current versions.
- Caches persist across builds per image (`.cache-<image>`), and
  `node_modules` survives inside the synced build dir on the server, so
  second builds are warm.

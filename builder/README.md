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

## Where the source comes from

**GitHub, never the Mac.** The server clones the project itself and keeps its
own state; nothing is copied from a workstation. Your Mac, a cloud agent and
the server all meet on the remote, which means there is never a question of
which machine holds the real code.

The consequence is worth stating plainly: **you cannot build uncommitted
work.** Push first, then build. In exchange the server's tree is disposable —
every run hard-resets it to `origin/<branch>` — so it can never drift into a
state only it has.

Targets are **per branch**. One project can have a built target for `main` and
another for `feature/x` at the same time, and they never overwrite each other.

```
~/atlas-builds/<name>/
  .repo/                    clone (--no-checkout), fetched every run
  wt/<branch-slug>/         git worktree, hard-reset to origin/<branch>
  state/<branch-slug>.json  what the last successful build produced
```

The branch slug maps `/` to `__` (`feature/x` → `feature__x`). Branch names
containing `__` are rejected so the mapping stays bijective — otherwise
`feature/x` and `feature__x` would collide on one directory and one container,
and `atlas start` could run the wrong build.

## How a build runs

`atlas build [-b <branch>]` finds `.atlas-build.toml` (walking up from the
current directory), fetches the repo on the server, resets that branch's
worktree, and runs the build command in the matching image with a per-image
cache volume (`~/atlas-builds/.cache-<image>` mounted at `/cache`, wired up as
`CARGO_HOME`, `npm_config_cache`, `PUB_CACHE`, `XDG_CACHE_HOME`,
`GRADLE_USER_HOME`).

`.repo` is also mounted at its own absolute path inside the container. A
worktree's `.git` is a *file* containing `gitdir: <absolute path into .repo>`,
so without that the object store is invisible and every `git` command in a
build fails with "not a git repository" — which breaks version stamping.

Artifacts stay on the server. Nothing is copied back: `atlas start` runs the
build where it was produced. On success the build records
`state/<slug>.json`; a build that fails — or that exits 0 without producing
its declared `artifacts` — writes nothing, so `atlas start` keeps pointing at
the last target that actually worked.

## Running a built target — `atlas start`

`atlas start [-b <branch>]` runs what `atlas build` produced for that branch,
using the config's `start` command. It **never builds**. A branch with no
target is an error that names the branches which do have one:

```
$ atlas start -b feature/does-not-exist
kein Target für 'feature/does-not-exist' auf atlas
  gebaut: main
  bauen mit:  atlas build -b feature/does-not-exist
```

If the recorded commit differs from the branch's current remote tip, `start`
warns with both short SHAs and starts anyway — you asked for the built target,
not for the newest code. `atlas start status` shows the branch, commit, build
time, whether it is running, and whether it is stale.

## How a dev server runs

`atlas dev [-b <branch>]` starts a long-running container on the server,
`atlas-dev-<name>-<slug>` (install + `<dev command>`, `--network host`). The
install step is whatever the config's `install` says, or — when that key is
absent — is picked from the project's lockfile
([below](#configuration--atlas-buildtoml)).

By default that container is published on the tailnet only, with
`tailscale serve` on the host — `https://<tailnet host>:<port>`. For `main`
the port is derived from the project `name` alone, so a project's dev URL —
and every OAuth redirect, webhook and `allowedDevOrigins` entry configured
against it — does not move now that branches exist. Other branches, and
`atlas start`, get their own derived ports so they can run simultaneously.
`atlas dev --public` instead starts a second container,
`atlas-tunnel-<name>-<slug>`, running a cloudflared quick tunnel that prints a
public `trycloudflare.com` URL. That is why the `dev` target carries
cloudflared while `build` does not: a build container cannot open a
tunnel, and the tailnet path needs nothing inside the image at all
(`tailscaled` runs on the host).

## Secrets

Env files never reach the server through the repo. A worktree is hard-reset to
`origin/<branch>` on every run, so anything dropped into it is thrown away —
and a secret that lived in the repo would be published anyway.

Instead each project gets one file on the server, outside the worktree:

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

The worktrees are `0700` and group/other bits are stripped from every file the
SSH user owns after each update — they are full checkouts of private repos on a
box where other processes exist. The strip is scoped to files we own because a
dev container runs as root and leaves root-owned build output that a blanket
`chmod -R` chokes on.

## Configuration — `.atlas-build.toml`

A flat `key = "value"` file at the project root of whatever you build:

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | project dir on the server (`~/atlas-builds/<name>`) and container name prefix |
| `image` | yes | builder key: `universal` \| `mobile` — nothing else resolves |
| `dir` | no (default `.`) | subdirectory the build/dev command runs in |
| `build` | for `atlas build` | build command run inside the container |
| `artifacts` | for `atlas build` | space-separated paths (relative to the project root) the build must produce; verified after the build and recorded in the target's state |
| `dev` | for `atlas dev` | dev-server command |
| `install` | no (default: from the lockfile) | dependency install run before `dev`; override when the lockfile is not the whole story |
| `start` | no (default: from the lockfile) | command that runs the **built** artifact, for `atlas start` |
| `repo` | no (default: the checkout's `origin`) | git URL the server clones; `git@host:owner/repo.git` is normalised to https so the server's stored credentials apply |
| `port` | no (default `3000`) | port the server listens on; what `tailscale serve` (or the tunnel) forwards to |

Those ten keys are the whole schema — anything else in the file is ignored,
and an `image` outside `universal` / `mobile` is an error rather than a
fallback. When `install` is absent, `atlas dev` picks the package manager from
the lockfile it finds in `dir`:

| Lockfile | Install command |
|---|---|
| `bun.lock` / `bun.lockb` | `bun install --frozen-lockfile` |
| `pnpm-lock.yaml` | `corepack enable && pnpm install --frozen-lockfile` |
| `yarn.lock` | `corepack enable && yarn install --immutable` |
| none of the above | `npm install --no-fund --no-audit` |

`start` is detected the same way when the key is absent: `bun run start`,
`pnpm start`, `yarn start`, else `npm run start`.

The check runs inside the container, in that order. Detecting it beats
assuming npm: running `npm install` over a bun or pnpm project either fails or
writes a second, wrong dependency tree next to the real one.

Example:

```toml
name = "my-app"
image = "universal"
dir = "web"
build = "pnpm build"
artifacts = "web/dist"
dev = "pnpm dev --host 0.0.0.0 --port 3000"
start = "pnpm start"
port = 3000
```

## Dev servers and cross-origin checks

A dev server reached over the tailnet or a tunnel is not on `localhost`, and
most frameworks reject that by default. Allow the hosts explicitly:

- **Next.js** — `allowedDevOrigins: ["**.ts.net", "**.trycloudflare.com"]`.
  A single `*` matches exactly one DNS label, so `*.ts.net` does **not** match
  `box.tailnet.ts.net`; `**` is required.
- **Vite / Astro** — `server.allowedHosts`.

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

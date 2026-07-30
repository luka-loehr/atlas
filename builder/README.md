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
every repo uses stay cheap, and the mobile stack is only materialized when
a project actually asks for it.

> The `dev` image carries `cloudflared`, but the public dev path does not
> use it: public dev URLs ride a persistent, host-level Cloudflare Tunnel
> and host Caddy (see [dev networking](#dev-networking--tailnet-private-vs-public-subdomains)).
> Nothing in the public path shells out to the binary in the container.

## Where the source comes from

**GitHub, never the Mac.** The server clones the project itself and keeps its
own state; nothing is copied from a workstation. Your Mac, a cloud agent and
the server all meet on the remote, which means there is never a question of
which machine holds the real code.

The consequence is worth stating plainly: **you cannot build uncommitted
work** with a branch build. Push first, then build. In exchange the server's
tree is disposable — every branch run hard-resets it to `origin/<branch>` — so
it can never drift into a state only it has. (`--local` is the one deliberate
exception: it rsyncs your working tree for the edit→build→fix loop; see below.)

Targets are **per branch**. One project can have a built target for `main` and
another for `feature/x` at the same time, and they never overwrite each other.

## Repo-hash namespacing — why a name is not enough

Each project's remote directory is keyed by its `name` **and** a short
deterministic hash of its origin git URL:

```
~/atlas-builds/<name>-<hash8>/
  .repo/                     clone (--no-checkout), fetched every run
  wt/<branch-slug>/          git worktree, hard-reset to origin/<branch>
  state/<branch-slug>.json   what the last successful build produced
  local/                     the --local scratch dir
  meta.json                  project identity manifest (name, repo, hash, image, dir)
~/atlas-builds/.cache-<image>/   shared per-image cache — NOT namespaced (shared by design)
```

`<hash8>` is the first 8 hex characters of the SHA-256 of the canonicalized
origin URL (lowercased, one trailing `.git` and any trailing `/` stripped).
The hash is stable forever: the same repo hashes to the same 8 characters on
every machine, every `cargo install`, and every Rust release. Container names
carry it too — `atlas-dev-<name>-<hash8>-<slug>` and
`atlas-start-<name>-<hash8>-<slug>`.

**The bug this prevents.** `dairo-frontend` and `dairo-backend` both ship an
`rt-harness` config with `name = "rt-harness"`. Keyed by name alone, both
would resolve to `~/atlas-builds/rt-harness`, and the two repos would silently
clobber each other's build tree, state, and containers — a frontend
`atlas run` could find and list the backend's `attack-money` binary. With the
hash, the two land in `rt-harness-<hashA>` and `rt-harness-<hashB>`; they
never meet. Nothing is de-collided by editing the config — the two
`rt-harness` files stay byte-identical; the URL hash does the separating.

**What is deliberately *not* namespaced:** the per-image cache
(`.cache-<image>`, shared across every project on purpose); the tailnet dev
port (derived from `name` alone, so a project's tailnet URL never moves — see
[dev networking](#dev-networking--tailnet-private-vs-public-subdomains)); and
the public subdomain label (name-based by product requirement). Two *different*
repos that share a `name` and both run tailnet `dev` at once would still
collide on that front port and public host; nothing detects that
automatically — `atlas ls` prints every project's name and hash side by side,
which is where a duplicate shows up. In practice the only same-name pair
(`rt-harness`) never runs `dev`.

**Warm-tree adoption.** The first time a project syncs, if an unhashed
`~/atlas-builds/<name>` tree exists and the hashed dir does not yet, the
CLI moves that tree into place (`<name>` → `<name>-<hash8>`) so a warm cache
under the plain name is not thrown away. The move is guarded (`! -e` on the
target), so it never overwrites or merges, and it prints one dim line when it
happens. If two repos share a `name`, whichever runs first adopts the
plain-name tree; the other finds nothing and builds cleanly into its own hash
dir.

The branch slug maps `/` to `__` (`feature/x` → `feature__x`). Branch names
containing `__` are rejected so the mapping stays bijective — otherwise
`feature/x` and `feature__x` would collide on one directory and one container,
and `atlas start` could run the wrong build.

## How a build runs

`atlas build [-b <branch>]` finds `atlas.toml` (walking up from the current
directory — [see below](#configuration--atlastoml)), fetches the repo on the
server,
resets that branch's worktree, and runs the build command in the matching
image with a per-image cache volume (`~/atlas-builds/.cache-<image>` mounted at
`/cache`, wired up as `CARGO_HOME`, `npm_config_cache`, `PUB_CACHE`,
`XDG_CACHE_HOME`, `GRADLE_USER_HOME`).

Two flags shape *what* gets built:

- `--local` builds the **working tree as it is on disk** — uncommitted edits
  and all — by rsyncing it to a scratch dir (`~/atlas-builds/<name>-<hash8>/local`)
  instead of checking out a pushed ref. This is the edit→build→fix loop
  without committing to test-compile. `.git` and the warm output dirs
  (`target`, `node_modules`, `.next`, `build`) are excluded, so a `--local`
  build has no git available (use a branch build for version stamping) and
  never disturbs a running `atlas start`. Mutually exclusive with `--branch`.
- `--path <subdir>` scopes the config lookup to a subdirectory, so one repo can
  hold several targets — an app config at the root and, say, a standalone
  crate's config under `security/tests/rt-harness/` — each built without
  cd-ing or swapping files. Each target needs its own `atlas.toml` with a
  distinct `name`. Composes with `--local`. (`--target T` selects a named
  `[target.T]` section instead, from a config that declares sections; it is
  mutually exclusive with `--path`.)

`.repo` is also mounted at its own absolute path inside the container. A
worktree's `.git` is a *file* containing `gitdir: <absolute path into .repo>`,
so without that the object store is invisible and every `git` command in a
build fails with "not a git repository" — which breaks version stamping.

Artifacts stay on the server. Nothing is copied back: `atlas start` runs the
build where it was produced. On success the build records
`state/<slug>.json` and refreshes `meta.json`; a build that fails — or that
exits 0 without producing its declared `artifacts` — writes nothing, so
`atlas start` keeps pointing at the last target that actually worked.

## Running a built target — `atlas start`

`atlas start [-b <branch>]` runs what `atlas build` produced for that branch,
using the config's `start` command. It **never builds**. A branch with no
target is an error that names the branches which do have one:

```
$ atlas start -b feature/does-not-exist
no target for 'feature/does-not-exist' on atlas
  built:      main
  build with: atlas build -b feature/does-not-exist
```

If the recorded commit differs from the branch's current remote tip, `start`
warns with both short SHAs and starts anyway — you asked for the built target,
not for the newest code. `atlas start status` shows the branch, commit, build
time, whether it is running, and whether it is stale.

## Running things on atlas — `test`, `exec`, `run`

`atlas build` produces an artifact and leaves it on the server; these three
*execute* on the server and stream it back, **propagating the command's exit
code**. That turns atlas from a build box into an execute box — the point being
that the command runs from atlas' network position, with atlas' secrets, while
the Mac stays cold. All three share `build`'s flags (`--local`, `--path`,
`--target`, `-b`), inject the same secrets, and run with `--network host`.

```
atlas test [-b B] [-- args]   run the project's tests (cargo/npm test, or `test =`)
atlas exec [-b B] -- CMD       fresh-sync the tree, then run CMD in the build root
atlas run  [-b B] -- CMD       run CMD against the ALREADY-built tree (no sync, no rebuild)
```

- **`test`** and **`exec`** sync first, exactly like `build`: `--local` rsyncs
  the working tree, otherwise the branch worktree is hard-reset to
  `origin/<branch>`. Because that can pull the rug out from a running
  `atlas start` on the same branch, a running app is stopped for the duration
  and restarted after — the same dance `build` does. `test` picks its command
  from `test =` or the lockfile (`cargo test`, else `<pm> test`); anything after
  `--` is forwarded to the runner, and a second `--` reaches the test binary
  (`atlas test -- -- --nocapture` → `cargo test -- --nocapture`).
- **`run`** does **not** sync — it runs against what `atlas build` last left, so
  the produced binary is still there. Give the command as a path so it is
  unambiguous which binary runs: `atlas run --path security/tests/rt-harness --local
  -- ./target/release/attack-money --secret-file /tmp/s`. Running against a tree
  that was never built is an error that names the build to run first. Note that
  `build`, `test` and `run` share one tree per source (the `--local` scratch dir,
  or a branch worktree) — they are **not** isolated from each other. `test`
  compiles a **debug** build (`target/debug`) and `build` a **release** one
  (`target/release`) in that same tree, so after changing code, `atlas build`
  before pointing `run` at `target/release/…` — otherwise it runs a stale binary
  or none at all.

`exec`/`run` take a **program and its arguments**, not a shell line — each token
is passed through verbatim, so arguments with spaces survive and nothing is
re-split or glob-expanded on the server. For shell features (pipes, `&&`,
redirection) invoke a shell explicitly: `atlas exec -- sh -c 'a && b'`.

`atlas watch` closes the loop locally: it watches your working tree and re-runs
`build --local` on every change (debounced), so a save triggers a fresh
server-side compile without you typing anything. See
[the observe commands](#the-observe-commands).

## How a dev server runs

`atlas dev [-b <branch>]` starts a long-running container on the server,
`atlas-dev-<name>-<hash8>-<slug>` (install + `<dev command>`, `--network host`).
The install step is whatever the config's `install` says, or — when that key is
absent — is picked from the project's lockfile
([below](#configuration--atlastoml)).

### Dev networking — tailnet-private vs. public subdomains

**Default: tailnet-private.** `atlas dev` publishes the container on the
tailnet only, with `tailscale serve` on the host —
`https://<tailnet host>:<port>`. For `main` the port is derived from the
project `name` alone (FNV-1a, band 20000–20999), so a project's dev URL — and
every OAuth redirect, webhook and `allowedDevOrigins` entry configured against
it — never moves. Other branches, and `atlas start`,
get their own derived ports so they can run simultaneously. `tailscaled` runs
on the host, not in the container.

**`atlas dev --public`: a stable lukaloehr.com subdomain.** `--public`
publishes at a deterministic, stable subdomain:

```
main branch     →  https://<name>.lukaloehr.com
other branch    →  https://<name>-<dns-branch>.lukaloehr.com
```

`main` is always exactly `https://<name>.lukaloehr.com` and never moves, so
OAuth redirects, webhooks and cross-origin allow-lists configured against it
are stable forever — a URL that moved between starts would break every one of
them. `<dns-branch>` is the branch flattened for DNS: lowercased, every run
of non-`[a-z0-9]` characters collapsed to a single `-`, leading/trailing `-`
trimmed (`feature/x` → `feature-x`, `release/2.0` → `release-2-0`). The exact
`__` slug keys the build tree, containers, and state, so builds never
collide even when two branches flatten to the same host label; the CLI warns
when that happens.

How it works, and why it needs no per-request Cloudflare call:

1. A **persistent named Cloudflare Tunnel** (`cloudflared.service`) and a
   **host Caddy** (`caddy.service`) run on atlas as steady-state infra,
   installed once by [`scripts/proxy/`](../scripts/proxy/). Caddy
   reverse-proxies `<host>` → `127.0.0.1:<port>`; the tunnel carries
   `*.lukaloehr.com` traffic to Caddy; TLS terminates at the Cloudflare edge.
2. A single **wildcard DNS** record — `*.lukaloehr.com` CNAME to the tunnel,
   proxied — already covers every project and branch subdomain, so
   **`atlas dev --public` never creates a DNS record** and needs **no
   Cloudflare token at runtime**. It only talks to Caddy's localhost admin API
   to upsert one reverse-proxy route, then prints the deterministic URL.
3. If the tunnel or Caddy is not running, `atlas dev --public` refuses to
   improvise: it prints the exact remediation
   (`run scripts/proxy/install.sh on atlas`) and exits non-zero.

`atlas dev url | logs | stop` print the current URL, follow the dev logs, or
stop the dev container and tear down **only this project's** tailnet serve
mapping and Caddy route. The shared tunnel, Caddy, and wildcard DNS are
persistent infra and are never touched by `dev stop`.

## Secrets

Env files never reach the server through the repo. A worktree is hard-reset to
`origin/<branch>` on every run, so anything dropped into it is thrown away —
and a secret that lived in the repo would be published anyway.

Instead each project gets one file on the server, outside the worktree,
hash-namespaced like the build tree:

```
atlas secrets push [file]   # default .env.local, else .env — 0600 in a 0700 dir
atlas secrets list          # which projects have one, never the contents
atlas secrets rm            # drop this project's (hashed + any unhashed file)
```

`push` always writes the hashed path
(`~/atlas-secrets/<name>-<hash8>.env`); consumers read the hashed file first
and fall back to an unhashed `~/atlas-secrets/<name>.env` if the hashed one is
absent, so a secret stored under the plain name keeps working until the next
push writes the hashed path.

`atlas build` and `atlas dev` pass the file to the container with `--env-file`,
so the values arrive as environment variables rather than as a file on disk.
The upload is streamed over ssh stdin, so the contents never appear in a
command line (argv is world-readable in `/proc`) and never land in an
intermediate file. If a project has a local env file but nothing in the store,
the CLI says so instead of running a build that would fail on missing
variables.

The worktrees are `0700` and group/other bits are stripped from every file the
SSH user owns after each update — they are full checkouts of private repos on a
box where other processes exist. The strip is scoped to files we own because a
dev container runs as root and leaves root-owned build output that a blanket
`chmod -R` chokes on.

## Configuration — `atlas.toml`

The config file is **`atlas.toml`** — the only filename the CLI looks for. The
format is a flat `key = "value"` list (not full TOML) with quoted or bare
values, `#` comments, and optional `[target.NAME]` sections.

**Resolution.** Walking up from the current directory, the CLI looks for
`atlas.toml` and nothing else. With `--path D` the lookup is exactly
`D/atlas.toml`; if it is missing, the command exits 1.

`atlas migrate [--force]` converts a `.atlas-build.toml` config file to
`atlas.toml`.

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | project id → `~/atlas-builds/<name>-<hash8>` and container-name prefix (`A-Za-z0-9._-`, alphanumeric first char) |
| `image` | yes | builder key: `universal` \| `mobile` — nothing else resolves |
| `dir` | no (default `.`) | subdirectory the build/dev command runs in |
| `build` | for `atlas build` | build command run inside the container |
| `test` | no (default: detected) | test command for `atlas test`; when absent, `cargo test` for a Rust crate, else the JS package manager's `test` script |
| `dev` | for `atlas dev` | dev-server command |
| `install` | no (default: from the lockfile) | dependency install run before `dev`/`start`; override when the lockfile is not the whole story |
| `start` | no (default: from the lockfile) | command that runs the **built** artifact, for `atlas start` |
| `repo` | no (default: the checkout's `origin`) | git URL the server clones; `git@host:owner/repo.git` is normalized to https so the server's stored credentials apply |
| `port` | no (default `3000`) | port the server listens on; what `tailscale serve` and Caddy forward to |
| `artifacts` | for `atlas build` | space-separated paths (relative to the project root) the build must produce; verified after the build and recorded in the target's state |
| `health` | no (default `/`) | the URL path `atlas health` probes (e.g. `/api/health`); must start with `/` and carry no whitespace or shell metacharacters |

Any unknown key is ignored, and an `image` outside `universal` / `mobile` is a
hard error rather than a fallback. In `[target.NAME]` sections, top-level keys
are shared defaults, target keys win, a target without its own `name` inherits
`<name>-<target>`, and `--target` is required when sections exist (and rejected
against a flat file). `health` is a valid per-target key too.

When `install` is absent, `atlas dev` picks the package manager from the
lockfile it finds in `dir`:

| Lockfile | Install command |
|---|---|
| `bun.lock` / `bun.lockb` | `bun install --frozen-lockfile` |
| `pnpm-lock.yaml` | `corepack enable && pnpm install --frozen-lockfile` |
| `yarn.lock` | `corepack enable && yarn install --immutable` |
| `package-lock.json` | `npm ci --no-fund --no-audit` |
| no lockfile at all | `npm install --no-fund --no-audit` — nothing to pin against, so also nothing to skip |

Two behaviors sit above that table (`builder/universal/atlas-install`): the
install is **skipped entirely** when the lockfile's sha256 matches the stamp
the previous run left inside `node_modules` (a strict install wipes that
directory, so a stale tree can never keep its stamp), and for a project with
no `package.json` the script is a silent no-op.

`start` is detected the same way when the key is absent: `bun run start`,
`pnpm start`, `yarn start`, else `npm run start`. The check runs inside the
container, in that order. Detecting it beats assuming npm: running
`npm install` over a bun or pnpm project either fails or writes a second, wrong
dependency tree next to the real one.

Example:

```toml
name      = "my-app"
image     = "universal"
dir       = "web"
build     = "pnpm build"
artifacts = "web/dist"
dev       = "pnpm dev --host 0.0.0.0 --port 3000"
start     = "pnpm start"
port      = 3000
health    = "/api/health"
```

## The observe commands

Seven read-mostly commands make a fleet legible without SSHing in by hand:

| command | what it does |
|---|---|
| `atlas ls` | fleet overview — every project under `~/atlas-builds`: name, hash, built branches, what is running, resolved URL, disk use |
| `atlas logs [-b B] [-f] [--dev\|--start]` | `docker logs` of this project's dev or start container (auto-picks the running one; flags disambiguate) |
| `atlas health [-b B] [--local]` | HTTP-probe the resolved dev/start URL (or `127.0.0.1:<port>` with `--local`) at the config's `health` path; non-zero exit if unhealthy |
| `atlas open [-b B]` | open the resolved dev/start URL in the local browser |
| `atlas doctor` | preflight checklist — reachability, ssh, docker, disk (85% guard), builder + mobile images, tailscale, the tunnel + Caddy admin + `cloudflare.env` presence + wildcard DNS, passwordless sudo — each `PASS`/`WARN`/`FAIL`; non-zero exit on any `FAIL` |
| `atlas info` | this project's identity — name, canonical repo URL, hash, remote dir, image, port + health, resolved public and tailnet dev URLs, built branches, and whether secrets are pushed (hashed or unhashed path) |
| `atlas watch [--path D] [--target T]` | local: watch the working tree (same excludes as `--local`) and re-run `build --local` on change, debounced 800 ms, coalescing save storms |

`ls` reads each project's `meta.json` for identity — it cannot reverse a hash
from a directory name, since `name` may itself contain `-`. `doctor` honors the
disk-guard 85% threshold and never bypasses it.

## Dev servers and cross-origin checks

A dev server reached over the tailnet or a public subdomain is not on
`localhost`, and most frameworks reject that by default. Atlas owns the
allow-list, so no repo hardcodes hosts:

- **`ATLAS_DEV_ORIGINS`** — the CLI injects this into every dev container: a
  comma-separated list of the exact hosts this project is reachable at (the
  tailnet host, plus `<name>.lukaloehr.com` with `--public`). A production
  build never sets it, so it is dev-only by construction. For **Next.js**:
  `allowedDevOrigins: process.env.ATLAS_DEV_ORIGINS?.split(",") ?? []`; for
  **Vite / Astro**, feed it to `server.allowedHosts`.
- **Next HMR needs no config at all on the public path**: the Caddy route is a
  subroute that strips `Origin`/`Referer` on exactly `/_next/*` and
  `/__nextjs*` before proxying — Next treats those requests as same-site — while
  the app's own routes keep their headers (CSRF stays intact).

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
- The public dev path depends on the dev-subdomain proxy infra (host Caddy + the named
  Cloudflare Tunnel + wildcard DNS). Install or verify it with
  [`scripts/proxy/`](../scripts/proxy/); `atlas doctor` reports its
  health.

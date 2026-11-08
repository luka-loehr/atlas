# Contributing to Atlas

Thanks for wanting to help. Atlas is a self-hosted photo library and drive for
one home server and its owner's devices. It is built to feel like an Apple app
on the client and to stay simple to run on the server. Contributions that keep
it that way are very welcome.

## Before you start

- **Bugs:** open an issue with the steps to reproduce, what you expected and
  what happened. Say which part it is (server, ML, CLI, iPhone app, Mac app)
  and the version (the Mac's About Atlas window shows it).
- **Features:** open an issue first and describe the problem it solves. Atlas
  deliberately stays small: one owner, one server, one bearer token. A short
  discussion saves you from building something that will not be merged.
- **Security issues:** never in a public issue. See [SECURITY.md](SECURITY.md).

## The parts

| Path | What | Language |
|---|---|---|
| `crates/server` | the HTTP API, jobs, search, sharing | Rust |
| `crates/ml` | faces, pets, OCR, embeddings (needs an NVIDIA GPU) | Rust |
| `crates/core` | code both processes share | Rust |
| `crates/cli` | the `atlas` command on the Mac (wake, deploy, connect) | Rust |
| `app/` | one SwiftUI app for iPhone, iPad and Mac | Swift |
| `db/`, `scripts/`, `share/` | Postgres, server upkeep, the share-link worker | SQL, shell, TypeScript |

[docs/OVERVIEW.md](docs/OVERVIEW.md) explains how they fit together.

## Setting up

### The Rust side

You need a recent stable Rust toolchain.

```bash
cargo build            # server and CLI (the default members)
cargo test
cargo clippy --all-targets
cargo fmt --all
```

`atlas-ml` links llama.cpp with CUDA and only builds on a machine with an
NVIDIA GPU and the CUDA toolkit: `cargo build -p atlas-ml`. The tests that
need Postgres skip themselves unless `ATLAS_TEST_DATABASE_URL` names a
database they may wipe (see `crates/core/tests/queue_db.rs`).

A full server, from an empty Ubuntu box to a connected app, is described in
[docs/SETUP.md](docs/SETUP.md).

### The app

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd app && xcodegen      # Atlas.xcodeproj is generated from project.yml
open Atlas.xcodeproj
```

The project file is generated: change `app/project.yml`, never the
`.xcodeproj`, and run `xcodegen` again.

To sign the app with your own Apple account, pass your team on the command
line (or pick it under Signing in Xcode), and change the bundle identifier
prefix (`bundleIdPrefix` in `project.yml`) and the App Group
(`group.com.lukaloehr.atlas.ios`, in `project.yml` and
`app/Shared/WidgetData.swift`) to your own. Don't commit those changes.

```bash
xcodebuild -project app/Atlas.xcodeproj -scheme Atlas \
  -destination 'platform=macOS' -derivedDataPath build-mac \
  DEVELOPMENT_TEAM=<your team> -allowProvisioningUpdates build
```

[app/README.md](app/README.md) describes the app's layout. A debug build
connects from the environment (`ATLAS_URL`, `ATLAS_TOKEN`), so you can work
on it against your own server without going through the connect screen.

## How we write code

- **Follow what is there.** Read the files around your change first and match
  their structure, naming and comment style.
- **Comments say why.** Explain decisions and non-obvious constraints in plain
  English, not what the next line does.
- **The app follows Apple's Human Interface Guidelines** on each platform:
  native controls, system fonts and colors, SF Symbols, Dynamic Type,
  VoiceOver labels on every icon-only button, light and dark mode.
  [docs/apple-design-guidelines.md](docs/apple-design-guidelines.md) is our
  reference. The Mac app is a real Mac app (menus, keyboard shortcuts,
  toolbars, the inspector), not the iPhone app in a window.
- **Fast is a feature.** The grids, the viewer and search are built to never
  wait on the network. Don't add work to the main thread or a spinner where
  something can be shown at once.
- **Rust:** `cargo fmt` and a clean `cargo clippy --all-targets`. No new
  `unwrap()` on input from the network or the disk.
- **No personal data.** No real names, photos, addresses, hostnames, tokens or
  keys in code, tests, fixtures, comments, screenshots or commit messages. Use
  placeholders such as `alex`, `atlas.your-tailnet.ts.net` or
  `aa:bb:cc:dd:ee:ff`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep a pull request to one change. Refactors go in their own PR.
3. Make sure it builds and the tests and lints pass (see above). For app
   changes, try it on the platforms it touches; screenshots or a short video
   help the review a lot.
4. Write the commit message as a sentence about what changes for the user or
   the code, for example: *"Mac viewer: a click on the photo hides and shows
   the controls"*.
5. Open the pull request and fill in the template.

By contributing you agree that your work is licensed under the
[MIT License](LICENSE), like the rest of Atlas.

## Code of conduct

Be kind and assume good intent. Critique code, not people. Harassment of any
kind is not tolerated; the maintainer may remove comments, close issues or
block accounts that cross that line.

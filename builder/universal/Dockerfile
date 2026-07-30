# atlas-universal — one toolchain for every remote build and dev server.
#
# One image carries every toolchain these repos build with, so a repo that
# mixes two languages (a pnpm workspace next to a Rust worker) is covered. The
# three targets below come out of ONE Dockerfile so they share layers: `dev`
# and `mobile` are `build` plus a thin top layer, so holding all three costs
# roughly what holding the biggest one does.
#
#   build   -> atlas-universal-builder   `atlas build`, every language below
#   dev     -> atlas-universal-dev       the `atlas dev` runtime (+ cloudflared)
#   mobile  -> atlas-universal-mobile    + Flutter/Android SDK (see the note)
#
# Why mobile is a separate target and not just part of `build`: the Flutter and
# Android SDKs are ~10 G, and atlas has ONE 950 G volume that was at 75% when
# this was written, with disk-guard warning at 85%. Everything else here fits
# in a few gigabytes, so the languages every repo actually uses stay cheap and
# the mobile stack is only materialised when a project asks for it.
#
# Pinning policy: base images are pinned to a major (debian:bookworm-slim,
# node:22, golang:1) or a channel (rust stable, flutter:stable), so a rebuild
# moves to current patch releases. Rebuild deliberately, not on a schedule.

# ---------------------------------------------------------------------------
# build — the universal toolchain
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS build

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Europe/Berlin

# System libraries, split from the language toolchains so that adding a
# language below does not re-run this layer. openssl/sqlite/protobuf headers
# are here because Rust crates in these repos link against them; cmake/ninja/
# clang because several native npm addons and Rust build scripts shell out to
# them. rsync + openssh-client are what the artifact sync and git-over-ssh
# dependencies need from inside the container.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates clang cmake curl file git gnupg jq \
      libsqlite3-dev libssl-dev lld locales ninja-build openssh-client \
      pkg-config protobuf-compiler python3 python3-pip python3-venv rsync \
      tzdata unzip wget xz-utils zip zstd \
 && rm -rf /var/lib/apt/lists/*

# Node: copied wholesale from the official image rather than added from a
# third-party apt repo — same binaries the node:22 tag ships, no extra key to
# trust, and it lands before the toolchains that also write into /usr/local so
# nothing it brings can clobber them.
COPY --from=node:22-bookworm-slim /usr/local/bin /usr/local/bin
COPY --from=node:22-bookworm-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node:22-bookworm-slim /usr/local/include/node /usr/local/include/node

# corepack turns on pnpm/yarn on demand, so a repo's packageManager field is
# honoured without this image pinning a version that fights it.
#
# The node image's /usr/local/bin/yarn is a symlink into /opt/yarn-*, which is
# outside the paths copied above, so it arrives dangling — and `corepack
# enable` realpath()s every shim it is about to replace and dies on it. Drop
# the stale links first; corepack writes its own yarn shim a line later.
RUN rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg \
 && corepack enable \
 && node --version && npm --version && yarn --version

# Bun, from the official release archive. Its own installer wants a login
# shell and writes to $HOME, which is wrong for an image built as root and run
# by another uid — the archive is the same artifact without that assumption.
ARG BUN_VERSION=1.3.9
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) bun_arch=x64 ;; \
      arm64) bun_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip"; \
    unzip -q /tmp/bun.zip -d /tmp; \
    install -m 0755 "/tmp/bun-linux-${bun_arch}/bun" /usr/local/bin/bun; \
    ln -sf /usr/local/bin/bun /usr/local/bin/bunx; \
    rm -rf /tmp/bun.zip "/tmp/bun-linux-${bun_arch}"; \
    bun --version

# Go, copied from the official image for the same reason as Node.
COPY --from=golang:1-bookworm /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH \
    GOTOOLCHAIN=local

# Rust. CARGO_HOME/RUSTUP_HOME live in /usr/local so every uid can read them;
# at run time the CLI points CARGO_HOME at the persistent /cache volume, so
# the registry survives between builds and this copy is only the toolchain.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
ARG RUST_CHANNEL=stable
RUN curl -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_CHANNEL" \
 && rustup component add clippy rustfmt \
 && rustup target add aarch64-unknown-linux-gnu \
 && chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME" \
 && rustc --version

# cargo-lambda ships on PyPI and pulls its matching Zig with it — the install
# path its own docs bless, and it wires Zig up automatically. Zig is what
# decides the produced binary's ABI, which is why an x86 box here still emits
# a byte-identical aarch64 Graviton artifact to what a Mac would.
RUN pip3 install --break-system-packages --no-cache-dir cargo-lambda \
 && cargo lambda --version

# uv covers the Python side (venvs, locked installs) far faster than pip, and
# installs as a single static binary.
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
 && uv --version

# JDK for Gradle/Kotlin JVM builds. Android's SDK is NOT here — that lives in
# the mobile target, because it is the expensive half.
RUN apt-get update \
 && apt-get install -y --no-install-recommends default-jdk-headless \
 && rm -rf /var/lib/apt/lists/*

# git refuses to operate in a tree owned by another uid. Builds run as root
# over a bind-mounted tree owned by the ssh user, so every build that shells
# out to git (version stamping, dependency resolution) would fail without this.
RUN git config --system --add safe.directory '*'

# The strict-but-skippable JS install every project shares. Kept as a script in
# the image rather than repeated in each atlas.toml so there is one
# implementation to fix, and last in this stage so editing it does not rebuild
# a single toolchain layer.
COPY atlas-install /usr/local/bin/atlas-install
RUN chmod 0755 /usr/local/bin/atlas-install

LABEL org.opencontainers.image.title="atlas-universal-builder"

# ---------------------------------------------------------------------------
# dev — the `atlas dev` runtime
# ---------------------------------------------------------------------------
FROM build AS dev

# cloudflared lives in the dev target, not in build, so a build container has
# no means to open a tunnel. The public dev path does not use it — public URLs
# ride the persistent host-level named tunnel + host Caddy (scripts/proxy/),
# and nothing in the container shells out to this binary.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"; \
    chmod 0755 /usr/local/bin/cloudflared; \
    cloudflared --version

LABEL org.opencontainers.image.title="atlas-universal-dev"

# ---------------------------------------------------------------------------
# mobile — build + Flutter/Android, materialised only when asked for
# ---------------------------------------------------------------------------
FROM build AS mobile

# Copied from the cirruslabs image rather than assembled here: it ships the
# Flutter SDK, the Android SDK (cmdline-tools, platform, build-tools) and
# pre-accepted licenses. Building that from scratch is gigabytes of fragile
# setup for no gain.
COPY --from=ghcr.io/cirruslabs/flutter:stable /sdks/flutter /sdks/flutter
COPY --from=ghcr.io/cirruslabs/flutter:stable /opt/android-sdk-linux /opt/android-sdk-linux

ENV ANDROID_SDK_ROOT=/opt/android-sdk-linux \
    ANDROID_HOME=/opt/android-sdk-linux \
    PATH=/sdks/flutter/bin:/opt/android-sdk-linux/cmdline-tools/latest/bin:/opt/android-sdk-linux/platform-tools:$PATH

RUN git config --system --add safe.directory /sdks/flutter \
 && flutter --version

LABEL org.opencontainers.image.title="atlas-universal-mobile"

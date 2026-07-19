# atlas-lambda-builder — pinned cross-compile environment for AWS Lambda.
#
# The image is x86, the Lambda target is aarch64 (Graviton): we CROSS-compile
# with cargo-lambda + Zig. What decides the produced binary's ABI is the Zig
# sysroot pinned to the Lambda target, NOT this image's OS — so an x86 host on
# atlas produces byte-for-byte the same artifact a Mac would, just on 20 threads.
#
# No rust-toolchain pin in dairo -> track stable, same as its GitHub CI.
FROM rust:1-bookworm

# The Graviton Lambda target.
RUN rustup target add aarch64-unknown-linux-gnu

# cargo-lambda ships on PyPI and pulls its matching Zig (ziglang) with it —
# the officially blessed install path, and it wires Zig up automatically.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip \
 && rm -rf /var/lib/apt/lists/* \
 && pip3 install --break-system-packages --no-cache-dir cargo-lambda

# Builds run as the invoking user (uid passed at `docker run --user`), with
# CARGO_HOME bind-mounted to a persistent dir so the crate registry survives
# between runs. RUSTUP_HOME stays in the image (read-only) — the target above
# is already installed, so rustup never needs to write.
LABEL org.opencontainers.image.title="atlas-lambda-builder"

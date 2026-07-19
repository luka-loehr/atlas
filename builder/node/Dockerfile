# atlas-node-builder — Node build + dev-server host for Next.js and friends.
#
# Used for `atlas build` (npm run build) and `atlas dev` (npm run dev behind a
# public tunnel). node_modules lives in the synced build dir on atlas, which is
# excluded from the Mac->atlas sync, so it persists between runs (warm installs).
FROM node:22-bookworm-slim

# git: some npm deps resolve from git. cloudflared: the public dev tunnel.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl \
 && ARCH="$(dpkg --print-architecture)" \
 && curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
      -o /usr/local/bin/cloudflared \
 && chmod +x /usr/local/bin/cloudflared \
 && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="atlas-node-builder"

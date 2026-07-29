#!/usr/bin/env bash
# =============================================================================
# atlas dev-subdomain infrastructure — one-time cloud bootstrap.
#
# Brings up the pieces that make https://<name>.lukaloehr.com dev subdomains
# work, without any interactive browser login:
#
#   Cloudflare edge  --(named tunnel "atlas")-->  cloudflared on atlas
#        |  *.lukaloehr.com CNAME <tunnel-id>.cfargotunnel.com (proxied)
#        v
#   host Caddy  (127.0.0.1:8080, admin API localhost:2019)
#        |  per-Host reverse_proxy routes added at runtime by `atlas dev`
#        v
#   dev containers  (127.0.0.1:<port>, --network host)
#
# What this script does (all idempotent — safe to re-run):
#   1. reads the Cloudflare token from ~/atlas-secrets/cloudflare.env
#   2. resolves the account id (from the zone) if not supplied
#   3. creates OR reuses a remotely-managed named tunnel "atlas" via the API
#   4. sets the tunnel ingress to send everything to the host Caddy
#   5. upserts the wildcard DNS record *.lukaloehr.com -> <id>.cfargotunnel.com
#   6. writes the tunnel token to /etc/atlas/cloudflared.env (root, 0600)
#   7. hands off to ./install.sh to arm Caddy + cloudflared as systemd units
#
# -----------------------------------------------------------------------------
# REQUIRED CLOUDFLARE API TOKEN PERMISSIONS
# -----------------------------------------------------------------------------
# The token lives ONLY on atlas at ~/atlas-secrets/cloudflare.env (0600) and is
# read by this script; it is never needed at runtime (`atlas dev --public` only
# talks to Caddy's localhost admin API and relies on the pre-existing wildcard).
#
# The token must carry, on https://dash.cloudflare.com/profile/api-tokens:
#
#   * Zone   -> DNS    -> Edit      on zone lukaloehr.com   (CONFIRMED present)
#         creates/updates the wildcard CNAME record.
#   * Zone   -> Zone   -> Read      on zone lukaloehr.com
#         resolves zone id -> account id (skip by setting CF_ACCOUNT_ID in the
#         env file, in which case Zone:Read is not required).
#   * Account-> Cloudflare Tunnel -> Edit   on the account owning lukaloehr.com
#         creates the named tunnel, sets its ingress, and reads its run token.
#         THIS IS THE ONE LIKELY MISSING from a DNS-only token. Grant it by
#         editing the token and adding an "Account -> Cloudflare Tunnel -> Edit"
#         permission line scoped to your account, then Save.
#
# If tunnel creation returns HTTP 403 / code 10000, the token is missing the
# Account -> Cloudflare Tunnel -> Edit permission above.
#
# -----------------------------------------------------------------------------
# ONE-TIME MANUAL STEPS
# -----------------------------------------------------------------------------
#   a. Install the binaries on atlas (Debian/Ubuntu):
#        # Caddy
#        sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
#        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
#          | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
#        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
#          | sudo tee /etc/apt/sources.list.d/caddy-stable.list
#        sudo apt update && sudo apt install -y caddy
#        # cloudflared
#        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
#          | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
#        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
#          | sudo tee /etc/apt/sources.list.d/cloudflared.list
#        sudo apt update && sudo apt install -y cloudflared
#      (Distro packages ship their own caddy.service / cloudflared.service —
#       install.sh disables those and installs the atlas units instead.)
#
#   b. Create ~/atlas-secrets/cloudflare.env (0600 in a 0700 dir):
#        install -d -m700 ~/atlas-secrets
#        umask 077
#        cat > ~/atlas-secrets/cloudflare.env <<'EOF'
#        CLOUDFLARE_API_TOKEN=<token with the permissions above>
#        CF_ZONE_ID=579eafcb03283fdb369881f8040f7049
#        CF_ZONE=lukaloehr.com
#        # CF_ACCOUNT_ID=<optional; else resolved from the zone via Zone:Read>
#        EOF
#
#   c. Run this script on atlas:  ./setup.sh
#
# There is NO browser login in this flow. (A browser login is only needed if
# you deliberately switch to a locally-managed tunnel — see
# proxy/cloudflared-config.yml. This script does not use that path.)
# =============================================================================
set -euo pipefail

# --- prerequisites ----------------------------------------------------------
for bin in curl jq sudo; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required tool: $bin" >&2; exit 1; }
done

ENV_FILE=${ATLAS_CLOUDFLARE_ENV:-$HOME/atlas-secrets/cloudflare.env}
if [ ! -r "$ENV_FILE" ]; then
  echo "missing $ENV_FILE — see the header of this script for its contents" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a   # CLOUDFLARE_API_TOKEN, CF_ZONE_ID, CF_ZONE, [CF_ACCOUNT_ID]

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN not set in $ENV_FILE}"
: "${CF_ZONE_ID:?CF_ZONE_ID not set in $ENV_FILE}"
: "${CF_ZONE:?CF_ZONE not set in $ENV_FILE}"

TUNNEL_NAME=${TUNNEL_NAME:-atlas}
API=https://api.cloudflare.com/client/v4

# --- keep the token OUT of argv ---------------------------------------------
# Every Cloudflare call reads its Authorization header from a 0600 curl config
# file, so the bearer token never appears in `ps`/argv. Cleaned up on exit.
CURL_CFG=$(umask 077 && mktemp "${TMPDIR:-/tmp}/atlas-cf.XXXXXX")
trap 'rm -f "$CURL_CFG"' EXIT
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
  "$CLOUDFLARE_API_TOKEN" > "$CURL_CFG"

# cf METHOD PATH [json-body]  -> prints the .result on success, dies on failure.
cf() {
  local method=$1 path=$2 body=${3:-} resp
  if [ -n "$body" ]; then
    resp=$(curl -fsS --max-time 20 -K "$CURL_CFG" -X "$method" "$API$path" -d "$body") || {
      echo "cloudflare API call failed: $method $path" >&2; return 1; }
  else
    resp=$(curl -fsS --max-time 20 -K "$CURL_CFG" -X "$method" "$API$path") || {
      echo "cloudflare API call failed: $method $path" >&2; return 1; }
  fi
  if [ "$(printf '%s' "$resp" | jq -r '.success')" != "true" ]; then
    echo "cloudflare API error on $method $path:" >&2
    printf '%s' "$resp" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' >&2
    return 1
  fi
  printf '%s' "$resp" | jq -c '.result'
}

echo "==> using zone $CF_ZONE ($CF_ZONE_ID)"

# --- 1. resolve account id --------------------------------------------------
if [ -z "${CF_ACCOUNT_ID:-}" ]; then
  echo "==> resolving account id from zone (needs Zone:Read)"
  CF_ACCOUNT_ID=$(cf GET "/zones/$CF_ZONE_ID" | jq -r '.account.id')
  [ -n "$CF_ACCOUNT_ID" ] && [ "$CF_ACCOUNT_ID" != "null" ] \
    || { echo "could not resolve account id — set CF_ACCOUNT_ID in $ENV_FILE" >&2; exit 1; }
fi
echo "    account id: $CF_ACCOUNT_ID"

# --- 2. create or reuse the named tunnel ------------------------------------
echo "==> ensuring remotely-managed tunnel '$TUNNEL_NAME'"
EXISTING=$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false")
TUNNEL_ID=$(printf '%s' "$EXISTING" | jq -r '.[0].id // empty')

if [ -z "$TUNNEL_ID" ]; then
  echo "    creating tunnel"
  CREATE_BODY=$(jq -nc --arg name "$TUNNEL_NAME" '{name:$name, config_src:"cloudflare"}')
  TUNNEL_ID=$(cf POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "$CREATE_BODY" | jq -r '.id')
else
  echo "    reusing existing tunnel"
fi
[ -n "$TUNNEL_ID" ] && [ "$TUNNEL_ID" != "null" ] \
  || { echo "no tunnel id — aborting" >&2; exit 1; }
echo "    tunnel id: $TUNNEL_ID"

# --- 3. set tunnel ingress: everything -> host Caddy ------------------------
echo "==> setting tunnel ingress -> http://localhost:8080 (host Caddy)"
INGRESS_BODY=$(jq -nc '{
  config: {
    ingress: [
      { service: "http://localhost:8080" },
      { service: "http_status:404" }
    ]
  }
}')
cf PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$INGRESS_BODY" >/dev/null
echo "    ingress set"

# --- 4. fetch the tunnel run token ------------------------------------------
echo "==> fetching tunnel run token"
# The token endpoint returns the raw connector token as .result (a string).
TUNNEL_TOKEN=$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r '.')
[ -n "$TUNNEL_TOKEN" ] && [ "$TUNNEL_TOKEN" != "null" ] \
  || { echo "could not fetch tunnel token" >&2; exit 1; }

# --- 5. wildcard DNS: *.lukaloehr.com -> <id>.cfargotunnel.com --------------
WILDCARD="*.$CF_ZONE"
TARGET="$TUNNEL_ID.cfargotunnel.com"
echo "==> upserting DNS $WILDCARD CNAME $TARGET (proxied)"
REC_BODY=$(jq -nc --arg name "$WILDCARD" --arg content "$TARGET" \
  '{type:"CNAME", name:$name, content:$content, proxied:true, ttl:1,
    comment:"atlas dev subdomains — managed by scripts/proxy/setup.sh"}')

# name must be URL-encoded (the leading * and dots); jq -Rr @uri handles it.
ENC_NAME=$(printf '%s' "$WILDCARD" | jq -sRr @uri)
EXIST_REC=$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$ENC_NAME")
REC_ID=$(printf '%s' "$EXIST_REC" | jq -r '.[0].id // empty')

if [ -z "$REC_ID" ]; then
  echo "    creating wildcard record"
  cf POST "/zones/$CF_ZONE_ID/dns_records" "$REC_BODY" >/dev/null
else
  echo "    updating existing wildcard record ($REC_ID)"
  cf PUT "/zones/$CF_ZONE_ID/dns_records/$REC_ID" "$REC_BODY" >/dev/null
fi
echo "    wildcard DNS in place"

# --- 6. write the tunnel token for the systemd unit (root, 0600) ------------
echo "==> writing /etc/atlas/cloudflared.env (root, 0600)"
sudo install -d -m755 /etc/atlas
# Token reaches the file via stdin, never argv; the temp file is 0600 and the
# installed file is 0600 root:root.
umask 077
TMP_ENV=$(mktemp "${TMPDIR:-/tmp}/atlas-cfd.XXXXXX")
trap 'rm -f "$CURL_CFG" "$TMP_ENV"' EXIT
printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > "$TMP_ENV"
sudo install -m600 -o root -g root "$TMP_ENV" /etc/atlas/cloudflared.env
rm -f "$TMP_ENV"
echo "    token installed"

# --- 7. arm Caddy + cloudflared systemd units -------------------------------
echo "==> arming systemd units via ./install.sh"
cd "$(dirname "$0")"
./install.sh

echo
echo "==> done."
echo "    tunnel:   $TUNNEL_NAME ($TUNNEL_ID)"
echo "    wildcard: $WILDCARD -> $TARGET"
echo
echo "    verify:"
echo "      systemctl is-active caddy cloudflared"
echo "      curl -sf localhost:2019/config/ >/dev/null && echo 'caddy admin ok'"
echo "      dig +short '*.$CF_ZONE' | grep cfargotunnel && echo 'wildcard ok'"
echo "      # end-to-end once a dev container + route exist:"
echo "      #   atlas dev --public   ->   https://<name>.$CF_ZONE"

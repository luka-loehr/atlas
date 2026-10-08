#!/usr/bin/env bash
# github-sync — keep a working clone of every repo of Luka's account and orgs
# under /srv/bulk/github/<owner>/<repo>, on the default branch.
#
# Pulled in by atlas-bulk-backup.service and ordered before it, so every hourly
# run lands on the USB disk in the same pass and becomes part of that hour's
# read-only btrfs snapshot. That snapshot is the versioning: if a branch is
# force-pushed or a repo emptied, this clone follows it, but the snapshots from
# before still hold the old state (24 hourly, then one per day with no limit).
#
# Never deletes a clone. A repo that disappears from GitHub (deleted, renamed,
# transferred, access lost) keeps its last copy here and is listed as an orphan.
#
# Authenticates as the GitHub App "atlas-backup-luka-loehr" (Contents and
# Metadata read-only, installed on every account in GITHUB_SYNC_OWNERS): a JWT
# signed with the app key gets one-hour installation tokens. Nothing here can
# write to GitHub. Installations on other accounts are never looked at.
#
# One failing repo does not stop the others; the run fails at the end, and the
# unit's OnFailure= mails it.
set -euo pipefail

DEST=${GITHUB_SYNC_DEST:-/srv/bulk/github}
# Must be its own mounted filesystem, otherwise the clones would fill the NVMe.
MUST_BE_MOUNTED=${GITHUB_SYNC_MUST_BE_MOUNTED:-/srv/bulk}
APP_ID=${GITHUB_APP_ID:?GITHUB_APP_ID is not set (/etc/atlas/github-sync.env)}
read -r -a OWNERS <<< "${GITHUB_SYNC_OWNERS:?GITHUB_SYNC_OWNERS is not set (/etc/atlas/github-sync.env)}"
APP_KEY=${GITHUB_APP_KEY:-${CREDENTIALS_DIRECTORY:-/nonexistent}/github-app.pem}
STATE_DIR=${STATE_DIRECTORY:-/var/lib/atlas-github-sync}
LOCK=${ATLAS_BACKUP_LOCK:-/run/lock/atlas-backup.lock}
API=https://api.github.com
# Per git command; a stalled transfer is cut after a minute below 1 kB/s.
GIT_TIMEOUT=${GITHUB_SYNC_GIT_TIMEOUT:-20m}

die() { echo "<3>github-sync: $*" >&2; exit 1; }

# The installation token reaches git through this helper and the environment,
# never through argv or a remote URL.
export GIT_TOKEN=""
g() {
  timeout -k 30s "$GIT_TIMEOUT" git \
    -c credential.helper= \
    -c 'credential.helper=!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GIT_TOKEN"; }; f' \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c protocol.allow=never -c protocol.https.allow=always \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    -c gc.autoDetach=false "$@"
}

[ -r "$APP_KEY" ] || die "GitHub App key $APP_KEY is not readable (LoadCredential)"
mountpoint -q "$MUST_BE_MOUNTED" || die "$MUST_BE_MOUNTED is not mounted"
[ -d "$DEST" ] && [ -w "$DEST" ] || die "$DEST is missing or not writable (run install.sh)"
mkdir -p "$STATE_DIR"

# The bulk backup must not snapshot a half-updated clone.
exec 9<"$LOCK" || die "lock file $LOCK is missing (install scripts/bulk-backup)"
flock -w 3600 9 || die "another backup job held $LOCK for an hour"

# A run killed by its timeout leaves git lock files; nothing else runs git here.
find "$DEST" -mindepth 3 -maxdepth 3 -name .git -type d -print0 \
  | xargs -0 -r -I{} find {} -name '*.lock' -type f -delete

# --- GitHub App auth -------------------------------------------------------

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

app_jwt() {
  local now head body
  now=$(date +%s)
  head=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  body=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
  printf '%s.%s.%s' "$head" "$body" \
    "$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -sign "$APP_KEY" -binary | b64url)"
}

api() {  # auth-header-value path [curl args...]
  local auth=$1 path=$2; shift 2
  curl -fsS --max-time 60 --retry 3 --retry-all-errors \
    -H @<(printf 'Authorization: %s\n' "$auth") \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$@" "$API$path"
}

declare -A inst=() token=() minted=()

mint() {  # owner -> token[owner], renewed after 50 min
  local o=$1
  if [ -z "${token[$o]:-}" ] || [ $(( $(date +%s) - ${minted[$o]} )) -gt 3000 ]; then
    token[$o]=$(api "Bearer $(app_jwt)" "/app/installations/${inst[$o]}/access_tokens" -X POST \
                  -d '{"permissions":{"contents":"read","metadata":"read"}}' | jq -r .token) || return 1
    [ -n "${token[$o]}" ] && [ "${token[$o]}" != null ] || return 1
    minted[$o]=$(date +%s)
  fi
}

start=$(date +%s)
failures=()
# Each allowed account's installation is looked up by name. The app is public
# (so the orgs can install it), and whoever else installs it is never listed,
# never synced and cannot crowd the real ones out of a paginated list.
api "Bearer $(app_jwt)" /app >/dev/null || die "the app does not authenticate (key revoked? app $APP_ID deleted?)"
for o in "${OWNERS[@]}"; do
  id=$(api "Bearer $(app_jwt)" "/users/$o/installation" 2>/dev/null | jq -r '.id // empty') \
    || id=$(api "Bearer $(app_jwt)" "/orgs/$o/installation" 2>/dev/null | jq -r '.id // empty') || id=""
  if [ -n "$id" ]; then inst[$o]=$id; else
    echo "<4>github-sync: app is not installed on $o" >&2; failures+=("$o (app not installed)"); fi
done

# --- list ------------------------------------------------------------------

list=""
for o in "${!inst[@]}"; do
  mint "$o" || { failures+=("$o (no token)"); continue; }
  page=1
  while :; do
    chunk=$(api "token ${token[$o]}" "/installation/repositories?per_page=100&page=$page" \
              | jq -r '.repositories[] | [.full_name, .default_branch] | @tsv') \
      || { failures+=("$o (listing failed)"); break; }
    [ -z "$chunk" ] || list+=$chunk$'\n'
    [ "$(printf '%s' "$chunk" | grep -c .)" = 100 ] || break
    page=$((page + 1))
  done
done
[ -n "$list" ] || die "the app sees no repos at all; refusing to call that a sync"

# --- sync ------------------------------------------------------------------

ok=0 cloned=0 empty=0 updated=0

sync_repo() {
  local full=$1 branch=$2 dir="$DEST/$1" want
  if [ ! -d "$dir/.git" ]; then
    if [ -e "$dir" ]; then
      echo "<4>github-sync: $dir exists without .git, moving it aside" >&2
      mv -T "$dir" "$dir.broken-$(date +%s)" || return 1
    fi
    rm -rf "$dir.part"
    mkdir -p "$(dirname "$dir")" || return 1
    g clone --quiet --no-checkout "https://github.com/$full.git" "$dir.part" || return 1
    mv -T "$dir.part" "$dir" || return 1
    cloned=$((cloned + 1))
  fi
  # Every branch and tag, force-updated and pruned: the clone mirrors GitHub
  # exactly, including rewrites. History before a rewrite lives in the snapshots.
  # No FETCH_HEAD, so an hour without pushes changes no file.
  g -C "$dir" fetch --quiet --force --prune --prune-tags --no-write-fetch-head origin \
      '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' || return 1
  if ! want=$(g -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch^{commit}"); then
    empty=$((empty + 1))   # empty repo, nothing to check out
    return 0
  fi
  # Check out only when something differs, again so idle repos stay untouched.
  if [ "$(g -C "$dir" rev-parse -q --verify HEAD || true)" != "$want" ] \
     || [ "$(g -C "$dir" symbolic-ref -q --short HEAD || true)" != "$branch" ] \
     || [ -n "$(g -C "$dir" --no-optional-locks status --porcelain --untracked-files=all --ignored=matching)" ]; then
    g -C "$dir" checkout --quiet --force -B "$branch" "$want" || return 1
    g -C "$dir" clean --quiet -ffdx || return 1
    updated=$((updated + 1))
  fi
}

declare -A listed=()
while IFS=$'\t' read -r full branch; do
  [ -n "$full" ] || continue
  # Names come from the API; still never let one point outside $DEST.
  if ! [[ $full =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ $full == *..* ]] \
     || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "<4>github-sync: skipping odd name '$full' '$branch'" >&2
    failures+=("$full"); continue
  fi
  listed[$full]=1
  owner=${full%%/*}
  if mint "$owner" && GIT_TOKEN=${token[$owner]} && sync_repo "$full" "$branch"; then
    ok=$((ok + 1))
  else
    echo "<4>github-sync: $full failed" >&2
    failures+=("$full")
  fi
done <<< "$list"
GIT_TOKEN=""

# Clones whose repo is no longer listed stay as they are.
orphans=()
shopt -s nullglob
for d in "$DEST"/*/*/; do
  name=${d#"$DEST/"}; name=${name%/}
  [[ $name == *.part ]] && continue
  [ -n "${listed[$name]:-}" ] || orphans+=("$name")
done
[ "${#orphans[@]}" = 0 ] || echo "kept, no longer on GitHub: ${orphans[*]}"

took=$(( $(date +%s) - start ))
json_list() { printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))'; }
cat > "$STATE_DIR/status.json.part" <<JSON
{"last_run":"$(date -Is)","repos":${#listed[@]},"ok":$ok,"cloned":$cloned,"updated":$updated,"empty":$empty,"failed":$(json_list "${failures[@]}"),"orphans":$(json_list "${orphans[@]}"),"took_s":$took}
JSON
mv "$STATE_DIR/status.json.part" "$STATE_DIR/status.json"

echo "github sync: $ok repos ok ($cloned new, $updated updated, $empty empty), ${#failures[@]} failed, ${#orphans[@]} kept from GitHub-deleted repos, ${took}s"
[ "${#failures[@]}" = 0 ] || die "failed: ${failures[*]}"

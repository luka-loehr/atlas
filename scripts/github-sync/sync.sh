#!/usr/bin/env bash
# github-sync — keep a working clone of every GitHub repo Luka owns or can see
# through his orgs under /srv/bulk/github/<owner>/<repo>, reset to the default
# branch.
#
# Pulled in by atlas-bulk-backup.service and ordered before it, so every hourly
# run lands on the USB disk in the same pass and becomes part of that hour's
# read-only btrfs snapshot. That snapshot is the versioning: if a branch is
# force-pushed or a repo emptied, this clone follows it, but the snapshots from
# before still hold the old state (24 hourly, then one per day with no limit).
#
# Never deletes a clone. A repo that disappears from GitHub (deleted, renamed,
# transferred, access lost) keeps its last copy here and is reported each run.
#
# Runs as the user gh is logged in as; git authenticates through
# `gh auth git-credential`. One failing repo does not stop the others; the run
# fails at the end so the journal shows it.
set -euo pipefail

DEST=${GITHUB_SYNC_DEST:-/srv/bulk/github}
# Must be its own mounted filesystem, otherwise the clones would fill the NVMe.
MUST_BE_MOUNTED=${GITHUB_SYNC_MUST_BE_MOUNTED:-/srv/bulk}
AFFILIATION=${GITHUB_SYNC_AFFILIATION:-owner,organization_member}
STATE_DIR=${STATE_DIRECTORY:-$HOME/.local/state/atlas-github-sync}

die() { echo "<3>github-sync: $*" >&2; exit 1; }

g() {
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
      -c core.hooksPath=/dev/null -c gc.autoDetach=false "$@"
}

mountpoint -q "$MUST_BE_MOUNTED" || die "$MUST_BE_MOUNTED is not mounted"
[ -d "$DEST" ] && [ -w "$DEST" ] || die "$DEST is missing or not writable (run install.sh)"
mkdir -p "$STATE_DIR"

start=$(date +%s)
list=$(gh api --paginate "user/repos?affiliation=$AFFILIATION&per_page=100" \
         --jq '.[] | [.full_name, .default_branch] | @tsv') \
  || die "listing repos through gh failed (logged out? token expired?)"
[ -n "$list" ] || die "gh listed no repos at all; refusing to call that a sync"

ok=0 failed=0 cloned=0 empty=0
failures=()

sync_repo() {
  local full=$1 branch=$2 dir="$DEST/$1"
  if [ ! -d "$dir/.git" ]; then
    rm -rf "$dir.part"
    mkdir -p "$(dirname "$dir")"
    g clone --quiet --no-checkout "https://github.com/$full.git" "$dir.part" || return 1
    mv "$dir.part" "$dir"
    cloned=$((cloned + 1))
  fi
  # Every branch and tag, force-updated and pruned: the clone mirrors GitHub
  # exactly, including rewrites. History before a rewrite lives in the snapshots.
  g -C "$dir" fetch --quiet --force --prune --prune-tags origin \
      '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' || return 1
  if ! g -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch^{commit}" >/dev/null; then
    empty=$((empty + 1))   # empty repo, nothing to check out
    return 0
  fi
  g -C "$dir" checkout --quiet --force -B "$branch" "origin/$branch" || return 1
  g -C "$dir" clean --quiet -ffdx || return 1
}

declare -A listed=()
while IFS=$'\t' read -r full branch; do
  # Names come from the API; still never let one point outside $DEST.
  if ! [[ $full =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ $full == *..* ]] \
     || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "<4>github-sync: skipping odd name '$full' '$branch'" >&2
    failures+=("$full"); failed=$((failed + 1)); continue
  fi
  listed[$full]=1
  if sync_repo "$full" "$branch"; then
    ok=$((ok + 1))
  else
    echo "<4>github-sync: $full failed" >&2
    failures+=("$full"); failed=$((failed + 1))
  fi
done <<< "$list"

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
json_list() { local s="" x; for x in "$@"; do s+="${s:+,}\"$x\""; done; echo "[$s]"; }
cat > "$STATE_DIR/status.json.part" <<JSON
{"last_run":"$(date -Is)","repos":${#listed[@]},"ok":$ok,"cloned":$cloned,"empty":$empty,"failed":$(json_list "${failures[@]}"),"orphans":$(json_list "${orphans[@]}"),"took_s":$took}
JSON
mv "$STATE_DIR/status.json.part" "$STATE_DIR/status.json"

echo "github sync: $ok repos ok ($cloned new, $empty empty), $failed failed, ${#orphans[@]} kept from GitHub-deleted repos, ${took}s"
[ "$failed" = 0 ] || die "failed: ${failures[*]}"

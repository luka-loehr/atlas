#!/usr/bin/env bash
# Land `debug = "line-tables-only"` for Rust dev/test builds, machine-wide.
#
# Full debug info is the bulk of a Rust debug binary. `line-tables-only` keeps
# backtraces with file/line — which is all anything on this box actually reads
# out of a debug build — and drops the type/variable DWARF that nothing here
# consumes. Typical saving is better than half the debug binary size.
#
# Why ~/.cargo/config.toml and not the repo: a manifest change would surface
# as an unrelated diff in every checkout of the repo. Config profiles override
# manifest profiles and apply to every tree at once, including ones checked
# out later. Nothing in dairo sets [profile.dev]/[profile.test], so this
# collides with nothing; the [profile.release] blocks in dairo-cli and
# dairo-api are untouched.
#
# Why this needs a quiet window (the whole reason it is a script and not a
# one-line edit): profile settings are part of cargo's fingerprint, so the
# first build in every tree after this lands is a full cold rebuild.
#
# And the part that is easy to get wrong — cargo has no garbage collector. It
# does not replace the old artifacts, it builds new ones *alongside* them under
# new fingerprint hashes. dairo-backend's target/ already carries four distinct
# libserde builds for exactly this reason. So this change makes target/ grow
# before it ever shrinks: you pay old + new at once, ~50 G of dairo target/
# becoming meaningfully more, and only get the saving back once the stale
# generation is cleared. Clear stale target/ dirs first, then land.
#
# Status by default; --apply to write.

set -euo pipefail

CONFIG="${CARGO_HOME:-$HOME/.cargo}/config.toml"
MARKER="# managed by atlas/scripts/cargo-dev-profile.sh"

APPLY=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --force) FORCE=1 ;;   # skip the quiet-window guard (know why first)
        *) echo "usage: $0 [--apply] [--force]" >&2; exit 2 ;;
    esac
done

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# ---------------------------------------------------------------------------
# Quiet-window guard
#
# A cargo/rustc process means someone is mid-build right now — landing this
# then hands that build a surprise cold rebuild.
# ---------------------------------------------------------------------------
busy_reasons() {
    local reasons=()

    local procs
    procs=$(pgrep -a -f '(^|/)(cargo|rustc)( |$)' 2>/dev/null | grep -cv '^$' || true)
    (( procs > 0 )) && reasons+=("$procs cargo/rustc process(es) running")

    (( ${#reasons[@]} )) && printf '%s\n' "${reasons[@]}"
}

already_applied() {
    [[ -f "$CONFIG" ]] && grep -q 'line-tables-only' "$CONFIG"
}

if already_applied; then
    log "OK     already applied — $CONFIG sets line-tables-only"
    exit 0
fi

mapfile -t reasons < <(busy_reasons)
if (( ${#reasons[@]} )); then
    for r in "${reasons[@]}"; do log "BUSY   $r"; done
    if (( FORCE )); then
        log "NOTE   --force given, landing anyway"
    else
        log "HOLD   not a quiet window; re-run when clear (or --force)"
        exit 1
    fi
else
    log "OK     quiet: no cargo/rustc running"
fi

if (( ! APPLY )); then
    log "DRY    would append to $CONFIG:"
    printf '\n%s\n[profile.dev]\ndebug = "line-tables-only"\n\n[profile.test]\ndebug = "line-tables-only"\n\n' "$MARKER"
    log "DRY    re-run with --apply"
    exit 0
fi

mkdir -p "$(dirname "$CONFIG")"
if [[ -f "$CONFIG" ]]; then
    cp -a "$CONFIG" "$CONFIG.bak.$(date +%Y%m%dT%H%M%S)"
    log "NOTE   backed up existing $CONFIG"
fi

cat >>"$CONFIG" <<EOF

$MARKER
[profile.dev]
debug = "line-tables-only"

[profile.test]
debug = "line-tables-only"
EOF

log "DONE   wrote profile to $CONFIG"
log "NEXT   next build in each tree is a cold rebuild; compare target/debug/deps"
log "NEXT   against the previous 600-840 MB per-binary baseline"

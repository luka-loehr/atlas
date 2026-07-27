#!/usr/bin/env bash
# disk-guard — notice that root is filling up, and tell someone.
#
# atlas has ONE physical device (nvme0n1, a single 950 G LVM volume). The photo
# library, Postgres, every service and every backup live on it. Filling root
# does not just stop builds, it takes out the recovery artefacts at the same
# moment. On 2026-07-27 the volume went 75% -> 84% in about twenty minutes of
# parallel `cargo test --workspace` runs (~1.8 G/min) and nothing noticed.
#
#   ./disk-guard.sh                 check + alert if needed   (what the timer runs)
#   ./disk-guard.sh --status        print current state, never alerts
#   ./disk-guard.sh --require-free  exit 1 if below the build floor (pre-build gate)
#   ./disk-guard.sh --json          machine-readable state on stdout
#
# Alerts go to Hermes via report-to-hermes, and to the journal at err priority.
# State lives in $STATE_DIR so the next run can measure the burn rate.
#
# This guard only measures and reports. The one thing it may delete is a cargo
# build tree, and only at the emergency threshold, and only by handing off to
# cargo-reaper.service, which has its own safety floor and never touches a tree
# an agent is still building in. It never touches ~/photos, ~/drive/blobs,
# Postgres or /srv/backups.

set -uo pipefail

MOUNT="${DISK_GUARD_MOUNT:-/}"
STATE_DIR="${DISK_GUARD_STATE_DIR:-$HOME/atlas-health}"
STATE="$STATE_DIR/disk-guard.state"
JSON="$STATE_DIR/disk.json"

# Alert thresholds, percent used (df's Use%).
WARN_PCT="${DISK_GUARD_WARN_PCT:-85}"
CRIT_PCT="${DISK_GUARD_CRIT_PCT:-90}"
EMERG_PCT="${DISK_GUARD_EMERG_PCT:-95}"

# The floor. Builds refuse to start below this much free space. See README for
# how the number was chosen — it is a decision, not a guess, and changing it
# means redoing that arithmetic.
FLOOR_GIB="${DISK_GUARD_FLOOR_GIB:-80}"

# Trend trigger: alert while still green if the current burn rate would eat the
# way down to the floor within this many minutes. This is the part that would
# have caught 2026-07-27 — the box was at 75% and perfectly "fine" at the point
# where it was already 50 minutes from the floor.
PROJECT_MIN="${DISK_GUARD_PROJECT_MIN:-60}"

# Re-send an unchanged alert at most this often (seconds).
RENOTIFY_SEC="${DISK_GUARD_RENOTIFY_SEC:-21600}" # 6 h

# Hand off to cargo-reaper at the emergency threshold.
EMERGENCY_REAP="${DISK_GUARD_EMERGENCY_REAP:-1}"

TASK="${DISK_GUARD_TASK:-atlas-disk-guard}"
# Free-text appended to every report. Used by the self-test so a deliberately
# provoked alert is distinguishable from a real one by whoever receives it.
NOTE="${DISK_GUARD_NOTE:-}"

GIB=$((1024 * 1024 * 1024))

mode=check
case "${1:-}" in
    --status) mode=status ;;
    --require-free) mode=require ;;
    --json) mode=json ;;
    "") ;;
    *) echo "usage: $0 [--status|--require-free|--json]" >&2; exit 2 ;;
esac

# --- measure ---------------------------------------------------------------

read -r _ total used avail _ < <(df -P -B1 "$MOUNT" | tail -1)
[[ -n "${avail:-}" ]] || { echo "disk-guard: cannot read df for $MOUNT" >&2; exit 2; }

# df's Use% is used/(used+avail): it excludes the root-reserved blocks from the
# denominator, so it is the number a non-root writer actually runs out against.
pct=$(( (used * 100 + (used + avail) - 1) / (used + avail) ))
avail_gib=$((avail / GIB))
used_gib=$((used / GIB))
total_gib=$((total / GIB))
now=$(date +%s)

# --- burn rate since the previous sample ------------------------------------

prev_ts=0 prev_used=0 prev_proj_hot=0 last_alert_ts=0 last_alert_level=ok
# shellcheck disable=SC1090
[[ -r "$STATE" ]] && source "$STATE"

burn_gib_min="0.00" burn_bytes_min=0 proj_min=-1
if ((prev_ts > 0 && now > prev_ts)); then
    dt=$((now - prev_ts))
    # Only trust a window that is neither a double-fire nor a reboot-sized gap.
    if ((dt >= 30 && dt <= 3600)); then
        burn_bytes_min=$(((used - prev_used) * 60 / dt))
        burn_gib_min=$(awk -v b="$burn_bytes_min" -v g="$GIB" 'BEGIN{printf "%.2f", b/g}')
        if ((burn_bytes_min > 0)); then
            headroom=$((avail - FLOOR_GIB * GIB))
            ((headroom < 0)) && headroom=0
            proj_min=$((headroom / burn_bytes_min))
        fi
    fi
fi

# --- classify ---------------------------------------------------------------

level=ok reason="${pct}% used, ${avail_gib} G free"
if ((pct >= EMERG_PCT)); then
    level=emergency reason="${pct}% used — only ${avail_gib} G free"
elif ((pct >= CRIT_PCT)); then
    level=critical reason="${pct}% used — ${avail_gib} G free"
elif ((pct >= WARN_PCT)); then
    level=warn reason="${pct}% used — ${avail_gib} G free"
fi
if ((avail_gib < FLOOR_GIB)) && [[ $level == ok ]]; then
    level=critical reason="${avail_gib} G free is below the ${FLOOR_GIB} G build floor"
fi
# Trend: green now, but arriving at the floor soon. Requires TWO consecutive
# hot samples. A single one is not evidence: a finishing build releases its
# intermediates, so one interval can read 1.9 G/min while the next reads
# negative. Observed on 2026-07-27 — 179 G free, then 173 G, then 180 G within
# three minutes. Two samples means ~10 minutes of sustained burn, which at the
# worst rate seen costs ~18 G of the 80 G floor headroom. That is the price of
# not crying wolf.
proj_hot=0
((proj_min >= 0 && proj_min <= PROJECT_MIN)) && proj_hot=1
if [[ $level == ok ]] && ((proj_hot && prev_proj_hot)); then
    level=warn
    reason="${pct}% used, ${avail_gib} G free, but burning ${burn_gib_min} G/min for two intervals running — ${proj_min} min from the ${FLOOR_GIB} G floor"
fi

rank() { case "$1" in ok) echo 0 ;; warn) echo 1 ;; critical) echo 2 ;; emergency) echo 3 ;; esac; }

line="disk-guard: $level — $reason (burn ${burn_gib_min} G/min)"

# --- write state + json (check mode owns the sample; the others must not
#     disturb the burn-rate window) ---------------------------------------

write_json() {
    mkdir -p "$STATE_DIR"
    cat > "$JSON" <<EOF
{
  "checked_at": "$(date -u -d "@$now" +%FT%TZ)",
  "mount": "$MOUNT",
  "level": "$level",
  "percent_used": $pct,
  "used_gib": $used_gib,
  "free_gib": $avail_gib,
  "total_gib": $total_gib,
  "floor_gib": $FLOOR_GIB,
  "burn_gib_per_min": $burn_gib_min,
  "minutes_to_floor": $proj_min,
  "reason": "$reason"
}
EOF
}

case "$mode" in
    status)
        echo "$line"
        echo "floor ${FLOOR_GIB} G; thresholds ${WARN_PCT}/${CRIT_PCT}/${EMERG_PCT}%"
        ((proj_min >= 0)) && echo "projected ${proj_min} min to the floor at the current rate"
        exit 0
        ;;
    json)
        write_json; cat "$JSON"; exit 0
        ;;
    require)
        if ((avail_gib < FLOOR_GIB)); then
            echo "disk-guard: REFUSING — ${avail_gib} G free on $MOUNT is below the ${FLOOR_GIB} G floor." >&2
            echo "  Reclaim first:  ~/atlas/scripts/cargo-reaper/reap.sh          # dry run" >&2
            echo "                  sudo systemctl start cargo-reaper.service    # apply" >&2
            exit 1
        fi
        echo "disk-guard: ok — ${avail_gib} G free (floor ${FLOOR_GIB} G)"
        exit 0
        ;;
esac

# --- check mode: decide whether to alert ------------------------------------

echo "$line"
write_json

emergency_note=""
if [[ $level == emergency && $EMERGENCY_REAP == 1 ]]; then
    echo "disk-guard: emergency — handing off to cargo-reaper.service"
    if reap_out=$(sudo -n systemctl start cargo-reaper.service 2>&1); then
        read -r _ _ used2 avail2 _ < <(df -P -B1 "$MOUNT" | tail -1)
        freed=$(((avail2 - avail) / GIB))
        emergency_note=" Ran cargo-reaper: reclaimed ${freed} G, now $((avail2 / GIB)) G free."
        echo "disk-guard: reaper done, reclaimed ${freed} G"
    else
        emergency_note=" cargo-reaper could not be started: ${reap_out}"
        echo "disk-guard: reaper failed: $reap_out" >&2
    fi
fi

send=0 kind=""
if [[ $level != ok ]]; then
    if (($(rank "$level") > $(rank "$last_alert_level"))); then
        send=1 kind=escalation
    elif ((now - last_alert_ts >= RENOTIFY_SEC)); then
        send=1 kind=reminder
    fi
elif [[ $last_alert_level != ok ]]; then
    send=1 kind=recovery
fi

if ((send)); then
    case "$level" in
        emergency | critical) status=failed ;;
        warn) status=in_review ;;
        *) status=done ;;
    esac
    if [[ $kind == recovery ]]; then
        report="atlas root is back under the thresholds: ${pct}% used, ${avail_gib} G free of ${total_gib} G. Previous alert level was ${last_alert_level}."
    else
        report="atlas root disk ${level}${kind:+ (${kind})}: ${reason}. ${used_gib} G used of ${total_gib} G, ${avail_gib} G free, burning ${burn_gib_min} G/min."
        ((proj_min >= 0)) && report+=" At that rate the ${FLOOR_GIB} G build floor is ${proj_min} min away."
        report+=" This is the only disk on the box — Postgres, the photo library and every backup share it.${emergency_note}"
        report+=" Reclaim: ~/atlas/scripts/cargo-reaper/reap.sh (dry run), sudo systemctl start cargo-reaper.service (apply)."
    fi
    [[ -n $NOTE ]] && report="$NOTE $report"
    # "<3>" is journald's err priority prefix (SyslogLevelPrefix defaults to yes),
    # so the alert shows up in `journalctl -p err -b`. Run by hand it prints
    # literally; that is the only cost.
    echo "<3>$report" >&2
    if report-to-hermes "$TASK" --status "$status" --report "$report" > /dev/null 2>&1; then
        echo "disk-guard: reported to hermes ($kind, status=$status)"
        last_alert_ts=$now last_alert_level=$level
    else
        echo "disk-guard: report-to-hermes FAILED — alert only in the journal" >&2
        # Do not record the alert as sent; the next run retries.
    fi
fi

mkdir -p "$STATE_DIR"
cat > "$STATE" <<EOF
prev_ts=$now
prev_used=$used
prev_proj_hot=$proj_hot
last_alert_ts=$last_alert_ts
last_alert_level=$last_alert_level
EOF

# Exit non-zero at critical and above so `systemctl status` shows the unit red.
case "$level" in emergency | critical) exit 1 ;; *) exit 0 ;; esac

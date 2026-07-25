#!/usr/bin/env bash
# atlas-healthcheck — one-shot health check for the atlas box.
#
# Verifies:
#   1. agent/ and cli/ compile (cargo check --locked)
#   2. atlas-agent HTTP endpoint responds on :8787 (200, or 401 when auth is on)
#   3. backend docker stack up (atlas-postgres healthy + 3 pipeline containers)
#   4. Postgres accepts connections and answers SELECT 1
#   5. atlas-photos HTTP endpoint responds on :8788
#
# Writes:  ~/atlas-health/status.json   machine-readable result of the last run
#          ~/atlas-health/last-run.log  full output of the last run
#          ~/atlas-health/history.log   one line per run
# Exit 0 = all green, 1 = at least one check failed.
#
# Runs on boot and on resume-from-suspend via the systemd units in this
# directory (one-shot each time — no timer, so the box can sleep when idle),
# or on demand:  ./atlas-healthcheck.sh   /   sudo systemctl start atlas-healthcheck

set -u
REPO="${ATLAS_REPO:-$HOME/atlas}"
STATE="${ATLAS_HEALTH_DIR:-$HOME/atlas-health}"
# service checks retry (containers need a moment after boot/resume);
# the systemd units set 12 (= up to ~2 min), interactive default is 3
RETRIES="${ATLAS_HEALTH_RETRIES:-3}"
RETRY_SLEEP="${ATLAS_HEALTH_RETRY_SLEEP:-10}"
BACKEND_CONTAINERS=(atlas-postgres atlas-pipeline-pipeline-gpu-1 atlas-pipeline-pipeline-cpu-1 atlas-pipeline-embed-api-1)

mkdir -p "$STATE"
LOG="$STATE/last-run.log"; : > "$LOG"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PATH="$HOME/.cargo/bin:$PATH"
N=0

log() { printf '%s\n' "$*" >> "$LOG"; printf '%s\n' "$*"; }

run_check() { # <name> <retries> <fn...>
    local name="$1" tries="$2"; shift 2
    local i out rc=1 t0=$SECONDS
    for ((i = 1; i <= tries; i++)); do
        out=$("$@" 2>&1) && { rc=0; break; }
        rc=$?
        ((i < tries)) && sleep "$RETRY_SLEEP"
    done
    local dur=$((SECONDS - t0))
    N=$((N + 1))
    printf '%s' "$name" > "$TMP/$N.name"
    printf '%s' "$rc" > "$TMP/$N.rc"
    printf '%s' "$dur" > "$TMP/$N.dur"
    printf '%s' "$out" > "$TMP/$N.out"
    if ((rc == 0)); then
        log "OK   $name (${dur}s)"
    else
        log "FAIL $name (rc=$rc after $tries tries, ${dur}s)"
        log "$out"
    fi
    return "$rc"
}

check_cargo() { (cd "$REPO/$1" && cargo check --locked --quiet); }

check_http() { # <port> <path>
    local code
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2") \
        || { echo "nothing listening on :$1"; return 1; }
    echo "HTTP $code from :$1$2"
    # 401 still proves the server is up — it means bearer auth is enforced
    case "$code" in 200 | 401) return 0 ;; *) return 1 ;; esac
}

check_containers() {
    local c st bad=0
    for c in "${BACKEND_CONTAINERS[@]}"; do
        if ! st=$(docker inspect --format '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$c" 2>&1); then
            echo "$c: not found"; bad=1; continue
        fi
        echo "$c: $st"
        case "$st" in running | running/healthy) ;; *) bad=1 ;; esac
    done
    return "$bad"
}

check_postgres() {
    docker exec atlas-postgres pg_isready -U atlas -d atlas \
        && docker exec atlas-postgres psql -U atlas -d atlas -Atc 'SELECT 1' > /dev/null \
        && echo "SELECT 1 ok"
}

overall=0 failed=""
run_check build-agent 1 check_cargo agent || { overall=1; failed+=" build-agent"; }
run_check build-cli 1 check_cargo cli || { overall=1; failed+=" build-cli"; }
run_check agent-http "$RETRIES" check_http 8787 /api/metrics || { overall=1; failed+=" agent-http"; }
run_check photos-http "$RETRIES" check_http 8788 /api/albums || { overall=1; failed+=" photos-http"; }
run_check docker-stack "$RETRIES" check_containers || { overall=1; failed+=" docker-stack"; }
run_check postgres "$RETRIES" check_postgres || { overall=1; failed+=" postgres"; }

python3 - "$TMP" "$STATE/status.json" "$overall" <<'PY'
import datetime, json, os, sys
tmp, out, overall = sys.argv[1], sys.argv[2], sys.argv[3] == "0"
checks, i = [], 1
while os.path.exists(f"{tmp}/{i}.name"):
    rd = lambda ext: open(f"{tmp}/{i}.{ext}").read()
    checks.append({"name": rd("name"), "ok": rd("rc") == "0",
                   "seconds": int(rd("dur")), "detail": rd("out")[-2000:]})
    i += 1
json.dump({"ok": overall,
           "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "host": os.uname().nodename, "checks": checks},
          open(out, "w"), indent=2)
PY

stamp=$(date -u +%FT%TZ)
if ((overall == 0)); then
    echo "$stamp OK" >> "$STATE/history.log"
    log "healthcheck OK — status in $STATE/status.json"
else
    echo "$stamp FAIL:${failed}" >> "$STATE/history.log"
    log "healthcheck FAILED:${failed} — details in $STATE/status.json and $LOG"
fi
exit "$overall"

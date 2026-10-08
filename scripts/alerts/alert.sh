#!/usr/bin/env bash
# atlas-alert — mail Luka through the Luka Mail API (mail.lukaloehr.com).
#
#   atlas-alert KEY SUBJECT < body     send, at most once per KEY every 24 h
#                                      (ATLAS_ALERT_REPEAT_S=0: always, no state)
#   atlas-alert --resolve KEY SUBJECT  send only if KEY was alerted, then forget it
#   atlas-alert --unit UNIT            a failed systemd unit (OnFailure=atlas-alert@%n)
#
# The API key (mail:send for atlas@lukaloehr.com only) is root-only in
# /etc/atlas/credentials/lmail-alerts, or $CREDENTIALS_DIRECTORY/lmail when run
# from a unit with LoadCredential=. If the mail cannot be sent the alert stays
# unsent (no state written) and the next check tries again.
set -euo pipefail

FROM=${ATLAS_ALERT_FROM:-atlas@lukaloehr.com}
TO=${ATLAS_ALERT_TO:-luka@lukaloehr.com}
ENDPOINT=${LMAIL_ENDPOINT:-https://mail.lukaloehr.com}
STATE=${ATLAS_ALERT_STATE:-/var/lib/atlas-alerts}
REPEAT_S=${ATLAS_ALERT_REPEAT_S:-86400}

key_file=/etc/atlas/credentials/lmail-alerts
[ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$CREDENTIALS_DIRECTORY/lmail" ] && key_file=$CREDENTIALS_DIRECTORY/lmail

send() {  # subject, body on stdin
  local body token i
  body=$(cat)
  token=$(cat "$key_file") || { echo "<3>atlas-alert: cannot read $key_file" >&2; return 1; }
  local req
  req=$(jq -n --arg id "$(cat /proc/sys/kernel/random/uuid)" --arg from "$FROM" --arg to "$TO" \
             --arg subject "[atlas] $1" --arg text "$body" \
             '{idempotencyKey:$id, from:$from, to:[$to], subject:$subject, text:$text}')
  for i in 1 2 3; do
    # Token through a file descriptor, never in argv.
    if printf '%s' "$req" | curl -fsS --max-time 30 -o /dev/null \
         -H @<(printf 'Authorization: Bearer %s\n' "$token") -H 'Content-Type: application/json' \
         --data-binary @- "$ENDPOINT/v1/messages/send"; then
      echo "mailed: [atlas] $1"
      return 0
    fi
    sleep $((i * 20))
  done
  echo "<3>atlas-alert: could not send '$1'" >&2
  return 1
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._@:-' '_'; }

mkdir -p "$STATE"

case "${1:-}" in
  --unit)
    unit=$2
    {
      echo "$unit failed on $(hostname) at $(date '+%F %T %Z')."
      echo
      systemctl status --no-pager --lines=0 "$unit" 2>&1 | head -n 12 || true
      echo
      echo "Last log lines:"
      journalctl -u "$unit" -n 40 --no-pager -o short-iso 2>&1 || true
      echo
      echo "More: journalctl -u $unit -n 200"
    } | exec "$0" "unit:$unit" "$unit failed"
    ;;
  --resolve)
    f=$STATE/$(slug "$2")
    [ -e "$f" ] || exit 0
    echo "Resolved at $(date '+%F %T %Z'): $3" | send "resolved: $3"
    rm -f "$f"
    ;;
  ""|-*)
    echo "usage: atlas-alert KEY SUBJECT < body | --resolve KEY SUBJECT | --unit UNIT" >&2; exit 2 ;;
  *)
    f=$STATE/$(slug "$1")
    if [ "$REPEAT_S" != 0 ] && [ -e "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt "$REPEAT_S" ]; then
      cat >/dev/null
      echo "already alerted in the last $((REPEAT_S / 3600)) h: $1"
      exit 0
    fi
    send "$2"
    # REPEAT_S=0 (the weekly report) keeps no state, so it never "resolves".
    [ "$REPEAT_S" = 0 ] || printf '%s\n' "$2" > "$f"
    ;;
esac

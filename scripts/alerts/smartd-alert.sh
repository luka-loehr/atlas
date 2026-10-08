#!/bin/sh
# Installed as /etc/smartmontools/run.d/20atlas-alert. smartd-runner calls it
# with SMARTD_* set for every warning smartd would have mailed to root (atlas
# has no local mail, so that mail went nowhere).
[ -n "${SMARTD_DEVICE:-}" ] || exit 0
printf '%s\n' "${SMARTD_FULLMESSAGE:-$SMARTD_MESSAGE}" \
  | /usr/local/sbin/atlas-alert "smartd:${SMARTD_DEVICE}:${SMARTD_FAILTYPE:-?}" "SMART: ${SMARTD_SUBJECT:-$SMARTD_MESSAGE}"

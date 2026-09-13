#!/usr/bin/env bash
# Source this, then: install_unit <unit-file>...
#
# Units in this repo ship with the sentinel SET-BY-INSTALLER instead of a
# concrete account: `User=`/`Group=` get the installing user and group, and
# `/home/SET-BY-INSTALLER` becomes $HOME (the repo is expected at ~/atlas).
# A hand-copied, unrendered unit fails loudly ("Unknown user") instead of
# pointing at a plausible-but-absent account.
install_unit() {
  local u
  for u in "$@"; do
    sed -e "s|/home/SET-BY-INSTALLER|$HOME|g" \
        -e "s|^Group=SET-BY-INSTALLER$|Group=$(id -gn)|" \
        -e "s|^User=SET-BY-INSTALLER$|User=$(id -un)|" \
        "$u" | sudo tee "/etc/systemd/system/$(basename "$u")" >/dev/null
  done
}

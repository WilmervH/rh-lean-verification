#!/bin/bash
# Usage: with-bwrap.sh CMD [ARGS...]
# Runs CMD in a private mount namespace whose root is a real (non-rootfs) mount,
# so unprivileged bwrap can pivot_root. Works around nodes whose / is an initramfs rootfs.
# CMD runs as the caller's original uid/gid (nested user namespace), with
# $BWRAP_LAB/bin (containing bwrap) prepended to PATH.
set -euo pipefail
LAB=${BWRAP_LAB:?set BWRAP_LAB to a directory containing bin/bwrap}
if [ "${_WB_STAGE:-}" = "" ]; then
  export _WB_STAGE=1 _WB_UID=$(id -u) _WB_GID=$(id -g) _WB_CWD=$PWD
  exec unshare --user --map-root-user --mount --propagation private "$LAB/with-bwrap.sh" "$@"
elif [ "$_WB_STAGE" = 1 ]; then
  NR=/tmp/.with-bwrap-root   # shared empty mountpoint; each run binds onto it in its own private mount ns
  mkdir -p "$NR" 2>/dev/null || true
  mount --rbind / "$NR"
  cd "$NR"
  mount --move . /
  # do NOT 'cd /' here: chroot must target the moved mount (cwd), as switch_root does
  export _WB_STAGE=2
  exec chroot . "$LAB/with-bwrap.sh" "$@"
else
  unset _WB_STAGE
  cd "$_WB_CWD"
  export PATH="$LAB/bin:$PATH"
  exec unshare --user --map-user="$_WB_UID" --map-group="$_WB_GID" -- "$@"
fi

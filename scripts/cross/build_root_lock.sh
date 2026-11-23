#!/usr/bin/env bash
# build_root_lock.sh -- the cross build's exclusive hold on its build root.
#
# Sourced by build_linux_cross.sh. The build root (default
# /var/tmp/reprobuild-cross) is a FIXED path on purpose: it is the path the
# cross-built images remember, so two builds of one commit agree. A fixed
# path is also shared: a second cross build started meanwhile (another
# session, another worktree) `rm -rf`s and re-exports `<root>/source` while
# the first is still compiling from it, and the first then links what the
# second exported. Measured 2026-10-31: an armhf build of one commit linked
# another commit's config.nims from the clobbered export.
#
#   acquire_build_root_lock <root>
#
# takes `flock -n` on `<root>.lock` for the rest of the calling shell (file
# descriptor 9) and refuses, naming the holder, when another build has it.
# https://man7.org/linux/man-pages/man1/flock.1.html

acquire_build_root_lock() {
  local root="$1"
  local lock="${root}.lock"
  exec 9>>"${lock}" || {
    echo "build_linux_cross: cannot open ${lock}" >&2
    return 1
  }
  if ! flock -n 9; then
    echo "build_linux_cross: another cross build holds ${root} ($(cat "${lock}.owner" 2>/dev/null || echo 'owner unknown'));" >&2
    echo "  wait for it, or set REPRO_CROSS_BUILD_ROOT to a root of your own" >&2
    return 1
  fi
  printf 'pid %s, %s\n' "$$" "$(pwd)" > "${lock}.owner"
}

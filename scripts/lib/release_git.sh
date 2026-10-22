# shellcheck shell=bash
# release_git.sh -- the one way the release staging scripts run git.
#
# Sourced, not executed. Defines:
#
#   release_git_init <caller>  resolve git once into RELEASE_GIT_BIN; on
#                              failure print why (prefixed with <caller>) to
#                              stderr and return 1.
#   release_git <args...>      run that git with the ownership check scoped
#                              off for this one call.
#
# WHY A SHARED HELPER. Every staging script reads sibling checkouts the release
# workflow cloned beside this one (reprobuild-packages, runquota,
# nim-shm-lease), and on the Windows release leg each can meet the same
# two traps. Fixing them in one script left the next one to rediscover them:
# v0.2.8 run 37941621127 for stage_release_catalog.sh, v0.2.14 run 39794420520
# for stage_release_runquota.sh, which reported the pinned commit as missing
# after discarding Git's error. That log did not distinguish the actual cause;
# missing PATH Git and ownership refusal are independently reproduced modes.
#
# 1. Git may be absent from PATH. Packaging runs in Git for Windows' bash,
#    whose PATH can carry `<git>/usr/bin` (bash, coreutils) but not the
#    directories holding git itself, so a bare `git` is "command not found".
#    Inside that bash the install root is `/`, and git lives at /cmd/git or
#    /mingw64/bin/git (/clangarm64/bin/git on Windows on Arm;
#    https://github.com/git-for-windows/git/wiki/FAQ).
# 2. The checkout may not be owned by the runner's service account. git then
#    refuses to read it ("dubious ownership",
#    https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory).
#    Every release_git call is a read of a checkout the workflow itself just
#    cloned (rev-parse, cat-file, archive, remote get-url), so the check
#    protects nothing here. It is lifted per call with `-c`; nothing is
#    written to any git config.
#
# Callers keep git's stderr: "not a git repository", "dubious ownership",
# "command not found" and "unknown revision" each need a different remedy, and
# a script that discarded it could only report the commit as absent.

# Where Git for Windows keeps git when PATH lacks it. Overridable so the
# fallback can be exercised on a host that has no such directories
# (tests/unit/test_release_git.py); the release legs never set it.
: "${REPRO_RELEASE_GIT_CANDIDATES:=/cmd/git /mingw64/bin/git /clangarm64/bin/git}"

release_git_init() {
  local caller=$1 candidate
  RELEASE_GIT_BIN=$(command -v git || true)
  if [[ -z "$RELEASE_GIT_BIN" ]]; then
    for candidate in $REPRO_RELEASE_GIT_CANDIDATES; do
      if [[ -x "$candidate" || -x "$candidate.exe" ]]; then
        RELEASE_GIT_BIN=$candidate
        break
      fi
    done
  fi
  if [[ -z "$RELEASE_GIT_BIN" ]]; then
    echo "${caller}: ERROR: git is not on PATH, and none of ${REPRO_RELEASE_GIT_CANDIDATES// /, } is present" >&2
    return 1
  fi
}

release_git() {
  "$RELEASE_GIT_BIN" -c safe.directory='*' "$@"
}

#!/usr/bin/env bash
# stage_release_runquota.sh <package-dir>
#
# Build the RunQuota daemon (`runquotad`) and CLI (`runquota`) at the revision
# this checkout's flake.lock pins, and put them in the release tree's bin/.
#
# WHY. Under `--tool-provisioning=tarball` and `nix` the engine will not run an
# action without a lease: it refuses to bypass RunQuota
# (`fallbackToRunQuotaBypass` is true only for `path` and `scoop`). It starts a
# daemon on its own when none is running, but only one it can find --
# `$RUNQUOTAD_BIN`, `runquotad` on PATH, or `../runquota/build/bin` above its
# image (`findRunQuotaDaemonBin`). Up to v0.2.12 no archive carried one, so an
# unpacked release could not build a from-source recipe under its default
# flags:
#
#   daemon-hosted build failed: runquota daemon unreachable and bypass is
#   disabled.
#
# The Windows zip and the Linux and macOS tarballs all lacked it, and so did the
# .deb and .rpm, which carry the Linux tarball's tree. Shipping the daemon in
# bin/ puts it where the search already looks: that bin/ is what an installed
# reprobuild puts on PATH.
#
# WHICH REVISION. The `runquota-src` input of flake.lock's ROOT node -- the
# runquota whose client libraries reprobuild compiles against, and whose
# package the Nix dev shell carries (`runquotaTools`). Its one dependency
# outside its own tree, nim-shm-lease, is taken at the revision THAT runquota's
# flake.lock pins, which is what runquota's own package build uses.
#
# WHERE THE SOURCES COME FROM. Each revision is exported with `git archive`
# from the sibling checkout (../runquota, ../nim-shm-lease), so a checkout on a
# different commit is read, never moved, and its working tree does not leak
# into the build. A sibling that lacks the commit is an error naming the fetch
# that fixes it; the release legs clone both siblings at these revisions
# (.github/sibling-repos).
#
# Run from the reprobuild checkout root, with Nim and a C compiler on PATH (the
# release legs: the Nix dev shell, or env.ps1 on Windows). The binaries are
# built in release mode. On Linux and macOS, run this BEFORE
# relocate_release_posix.sh, which bundles their runtime closure and wraps them
# like every other image in bin/.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
pkg=$1
[[ -d "$pkg/bin" ]] || { echo "stage_release_runquota: no $pkg/bin" >&2; exit 1; }
[[ -f flake.lock && -f libs/repro_project_dsl/src/repro_project_dsl.nim ]] || {
  echo "stage_release_runquota: run from the reprobuild checkout root" >&2; exit 1; }

# shellcheck source=scripts/lib/dev_shell_overrides.sh
. scripts/lib/dev_shell_overrides.sh

fail() { echo "stage_release_runquota: ERROR: $*" >&2; exit 1; }

# pinned_rev <flake.lock> <root input>: the revision that input is locked to.
pinned_rev() {
  local rev
  rev=$(dev_shell_flake_lock_pins "$1" | awk -F'\t' -v i="$2" '$1 == i { print $2 }')
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] ||
    fail "$1 locks no revision for the root input '$2' (read '${rev}')"
  printf '%s' "$rev"
}

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/repro-release-runquota-XXXXXX")
trap 'rm -rf "$work" 2>/dev/null || true' EXIT

# Every git call on a sibling goes through release_git: on the Windows leg
# this runs in Git for Windows' bash, where Git may be absent from PATH and
# the runner's service account may not own the checkout. v0.2.14 (run
# 39794420520) reported the pinned runquota commit as missing after this
# script discarded Git's error. The log did not distinguish missing PATH Git,
# ownership refusal, or an absent commit; keep that distinction observable.
# shellcheck source=scripts/lib/release_git.sh
. scripts/lib/release_git.sh
release_git_init stage_release_runquota || exit 1

# export_rev <sibling> <rev> <dest>
export_rev() {
  local repo=$1 rev=$2 dest=$3 why
  [[ -e "$repo/.git" ]] || fail "$repo is not a git checkout; clone it beside this repository"
  # Keep git's own answer: an absent commit, a refused checkout and a missing
  # git need different remedies.
  why=$(release_git -C "$repo" cat-file -e "$rev^{commit}" 2>&1) ||
    fail "$repo does not have $rev (git: ${why:-no message}); if the commit is absent, run: git -C $repo fetch origin $rev"
  mkdir -p "$dest"
  release_git -C "$repo" archive --format=tar "$rev" | (cd "$dest" && tar -xf -)
  echo "stage_release_runquota: $(basename "$dest") <- $repo @ $rev"
}

runquota_rev=$(pinned_rev flake.lock runquota-src)
export_rev ../runquota "$runquota_rev" "$work/runquota"
shm_lease_rev=$(pinned_rev "$work/runquota/flake.lock" nim-shm-lease)
export_rev ../nim-shm-lease "$shm_lease_rev" "$work/nim-shm-lease"

# runquota's config.nims takes nim-shm-lease from SHM_LEASE_SRC before its
# sibling, and reads reprobuild's libs onto the path whenever REPROBUILD_SRC is
# set. The caller's values describe the caller's trees, not these.
(
  cd "$work/runquota"
  env -u REPROBUILD_SRC SHM_LEASE_SRC="$work/nim-shm-lease/src" \
    RUNQUOTA_BUILD_MODE=release bash scripts/build_apps.sh
)

exe=""
[[ -f "$work/runquota/build/bin/runquotad.exe" ]] && exe=".exe"
for app in runquotad runquota; do
  built="$work/runquota/build/bin/$app$exe"
  [[ -f "$built" ]] || fail "runquota's build produced no $app$exe"
  cp "$built" "$pkg/bin/$app$exe"
  chmod +x "$pkg/bin/$app$exe"
done
echo "stage_release_runquota: bin/runquotad$exe and bin/runquota$exe from runquota $runquota_rev"

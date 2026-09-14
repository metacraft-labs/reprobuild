#!/usr/bin/env bash
# M6 clause 2.3 gate — a DEFAULT install must be unchanged by the
# existence of the opt-in system-build-users mode.
#
# The weak version of this claim is "the flag defaults to false". That
# is an inspection of a default value and it proves nothing about what
# the installer does. This harness instead performs two real installs --
# one driven by the installer exactly as it was before M6, one by the
# installer as it is now -- into two prefixes, and compares the
# resulting trees content-by-content, mode included. It then confirms
# against getent(1) that neither default install left a system account
# or group behind.
#
# Usage: bash t_m6_default_install_unchanged.sh <repo-root> <base-installer>
#   <base-installer>  the pre-M6 install-on-distributions.sh, extracted
#                     from git, so "before" is a real artifact and not a
#                     reconstruction.
#
# Run as root on a disposable host: the opt-in phase creates accounts.

set -euo pipefail

REPO_ROOT="${1:-}"
BASE_INSTALLER="${2:-}"
if [ -z "$REPO_ROOT" ] || [ -z "$BASE_INSTALLER" ]; then
  echo "usage: $0 <repo-root> <base-installer>" >&2
  echo "  extract <base-installer> from git so 'before' is a real artifact:" >&2
  echo "    git cat-file blob <pre-M6-rev>:install-on-distributions.sh > /tmp/pre-m6-installer.sh" >&2
  echo "  passing the CURRENT installer as the baseline makes phase 2 vacuous;" >&2
  echo "  phase 0 asserts the two differ by sha256 precisely to catch that." >&2
  exit 1
fi
[ -f "$BASE_INSTALLER" ] || { echo "no base installer at $BASE_INSTALLER" >&2; exit 1; }

NEW_INSTALLER="$REPO_ROOT/install-on-distributions.sh"
W=/tmp/m6-definstall
GROUP=reprobuild
PREFIX=reprobuildbld

MIN_CHECKS=18
CHECKS=0
FAILURES=0
FINISHED=0

ok()  { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$*"; }
bad() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$*"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1 [$2]"; else bad "$1: expected '$2', got '$3'"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1: both are '$2'"; fi; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else bad "$1: expected empty, got '$2'"; fi; }
assert_nonempty() { if [ -n "$2" ]; then ok "$1 [$2]"; else bad "$1: empty"; fi; }

cleanup() {
  bash "$REPO_ROOT/scripts/reprobuild-buildusers.sh" destroy \
    --group "$GROUP" --prefix "$PREFIX" --count 2 >/dev/null 2>&1 || true
}
on_exit() {
  local rc=$?
  if [ "$FINISHED" -ne 1 ]; then
    printf '\nHARNESS DIED EARLY (exit %s) after %s check(s)\n' "$rc" "$CHECKS"
    printf 'RESULT: FAIL (incomplete)\n'
    cleanup || true
    exit 1
  fi
}
trap on_exit EXIT

gid_of() { getent group  "$1" 2>/dev/null | awk -F: 'NF>=3 {print $3}'; }
uid_of() { getent passwd "$1" 2>/dev/null | awk -F: 'NF>=3 {print $3}'; }

# A content manifest: relative path, octal mode, size, sha256. Owner is
# deliberately excluded only because both installs run as the same user;
# everything the installer actually decides is covered.
manifest() {
  ( cd "$1" && find . -mindepth 1 \( -type f -o -type d \) -printf '%P\t%m\t%y\n' \
      | sort | while IFS=$'\t' read -r p m t; do
          if [ "$t" = f ]; then
            printf '%s\t%s\t%s\n' "$p" "$m" "$(sha256sum "$p" | cut -d' ' -f1)"
          else
            printf '%s\t%s\tDIR\n' "$p" "$m"
          fi
        done )
}

rm -rf "$W"; mkdir -p "$W"

echo "=== phase 0: preconditions ==="
assert_eq "runs as root" "0" "$(id -u)"
assert_empty "build group absent before anything" "$(gid_of "$GROUP")"
assert_empty "build account absent before anything" "$(uid_of "${PREFIX}01")"
assert_ne "base and new installer differ (there is a change to test)" \
  "$(sha256sum "$BASE_INSTALLER" | cut -d' ' -f1)" \
  "$(sha256sum "$NEW_INSTALLER" | cut -d' ' -f1)"

echo "=== phase 1: synthetic source checkout ==="
# A real `just build` is out of scope here and irrelevant: what is under
# test is what the INSTALLER does with a build tree, not how the tree is
# produced. The tree is byte-identical for both runs.
SRC="$W/src"
mkdir -p "$SRC/build/bin" "$SRC/build/lib" "$SRC/apps" "$SRC/scripts"
printf '#!/bin/sh\necho repro stub\n'   >"$SRC/build/bin/repro"
printf '#!/bin/sh\necho helper stub\n'  >"$SRC/build/bin/repro-helper"
printf 'not-really-a-library\n'          >"$SRC/build/lib/librepro.so"
printf 'repro\n'                         >"$SRC/apps/entrypoints.txt"
chmod 0755 "$SRC/build/bin/repro" "$SRC/build/bin/repro-helper"
cp "$REPO_ROOT/scripts/reprobuild-buildusers.sh" "$SRC/scripts/"
if [ -f "$SRC/build/bin/repro" ]; then ok "synthetic build tree staged"
else bad "synthetic build tree missing"; fi

run_install() { # run_install <installer> <prefix-dir> [extra-args...]
  local inst="$1" pfx="$2"; shift 2
  REPROBUILD_SOURCE_ROOT="$SRC" \
  REPROBUILD_INSTALL_PREFIX="$pfx" \
    bash "$inst" --method local-prefix "$@" >"$W/$(basename "$pfx").log" 2>&1 || true
}

echo "=== phase 2: two default installs, before-installer vs after-installer ==="
run_install "$BASE_INSTALLER" "$W/prefix-base"
run_install "$NEW_INSTALLER"  "$W/prefix-new"

if [ -f "$W/prefix-base/bin/repro" ]; then ok "base installer produced an install"
else bad "base installer produced nothing (comparison would be vacuous)"; fi
if [ -f "$W/prefix-new/bin/repro" ]; then ok "new installer produced an install"
else bad "new installer produced nothing (comparison would be vacuous)"; fi

manifest "$W/prefix-base" >"$W/m-base.txt"
manifest "$W/prefix-new"  >"$W/m-new.txt"

BASE_LINES=$(wc -l <"$W/m-base.txt")
# A comparison of two empty manifests would "match" perfectly. Require
# that there is actually something installed to compare.
if [ "$BASE_LINES" -ge 4 ]; then
  ok "manifest is non-trivial ($BASE_LINES entries)"
else
  bad "manifest has only $BASE_LINES entries; the diff would be vacuous"
fi

if diff -u "$W/m-base.txt" "$W/m-new.txt" >"$W/manifest.diff" 2>&1; then
  ok "DEFAULT INSTALL IS BYTE-IDENTICAL before vs after M6"
else
  bad "default install changed:"; sed 's/^/      /' "$W/manifest.diff"
fi

echo "=== phase 3: the comparison can detect a difference (negative control) ==="
# If the manifest diff could not fail, phase 2 proved nothing.
cp -a "$W/prefix-new" "$W/prefix-tampered"
printf 'extra\n' >"$W/prefix-tampered/bin/sneaked-in"
manifest "$W/prefix-tampered" >"$W/m-tampered.txt"
if diff -q "$W/m-base.txt" "$W/m-tampered.txt" >/dev/null 2>&1; then
  bad "manifest diff did NOT notice an added file; phase 2 is worthless"
else
  ok "manifest diff notices an added file"
fi
chmod 0700 "$W/prefix-tampered/bin/repro"
rm -f "$W/prefix-tampered/bin/sneaked-in"
manifest "$W/prefix-tampered" >"$W/m-tampered2.txt"
if diff -q "$W/m-base.txt" "$W/m-tampered2.txt" >/dev/null 2>&1; then
  bad "manifest diff did NOT notice a mode change; phase 2 is worthless"
else
  ok "manifest diff notices a permission-mode change"
fi

echo "=== phase 4: a default install creates no system accounts ==="
# Read the system, not the flag.
assert_empty "no build group after two default installs"   "$(gid_of "$GROUP")"
assert_empty "no build account after two default installs" "$(uid_of "${PREFIX}01")"

echo "=== phase 5: the opt-in flag DOES provision (clause 2.1 via the installer) ==="
REPROBUILD_BUILD_USERS_ARGS="--count 2" \
  run_install "$NEW_INSTALLER" "$W/prefix-optin" --system-build-users

OGID="$(gid_of "$GROUP")"
OUID="$(uid_of "${PREFIX}01")"
assert_nonempty "opt-in install created the build group"   "$OGID"
assert_nonempty "opt-in install created build account 01"  "$OUID"
assert_nonempty "opt-in install created build account 02"  "$(uid_of "${PREFIX}02")"
assert_ne "provisioned build account is not root" "0" "$OUID"

echo "=== phase 6: the opt-in flag changes the INSTALL not at all ==="
manifest "$W/prefix-optin" >"$W/m-optin.txt"
if diff -u "$W/m-base.txt" "$W/m-optin.txt" >"$W/optin.diff" 2>&1; then
  ok "opt-in install tree is identical to the default install tree"
else
  bad "opt-in mode altered the installed files:"; sed 's/^/      /' "$W/optin.diff"
fi

echo "=== phase 7: teardown ==="
cleanup
assert_empty "build group removed" "$(gid_of "$GROUP")"
assert_empty "build account removed" "$(uid_of "${PREFIX}01")"

printf '\n%s checks, %s failure(s)\n' "$CHECKS" "$FAILURES"
if [ "$CHECKS" -lt "$MIN_CHECKS" ]; then
  printf 'RESULT: FAIL — ran %s checks, expected at least %s\n' "$CHECKS" "$MIN_CHECKS"
  FINISHED=1; exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf 'RESULT: FAIL — %s failing check(s)\n' "$FAILURES"
  FINISHED=1; exit 1
fi
printf 'RESULT: PASS\n'
FINISHED=1
exit 0

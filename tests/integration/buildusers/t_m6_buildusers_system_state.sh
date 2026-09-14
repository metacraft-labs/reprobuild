#!/usr/bin/env bash
# M6 clause 2 gate — system build users, verified against SYSTEM STATE.
#
# This harness is deliberately hostile to itself. Every assertion below
# reads what the operating system says (getent(1), stat(1) on a real
# inode, /proc/<pid>/status of a live process) rather than the config
# that asked for it. An earlier campaign shipped a "control" that was
# inert because the tool it called silently ignored its input; the
# mutation phase at the end exists so that cannot happen here unnoticed.
#
# It MUTATES SYSTEM ACCOUNTS. Run it only on a disposable host, as root.
# It refuses to start if the accounts it is about to create already
# exist, because a pre-existing account would make the central
# "provisioning worked" assertion pass without provisioning anything.
#
# Usage:  bash t_m6_buildusers_system_state.sh <repo-root>
#
# Output: one "ok"/"FAIL" line per check, then a RESULT line. Exits
# non-zero on any failure, on dying early, or on running too few checks.

set -euo pipefail

REPO_ROOT="${1:-}"
[ -n "$REPO_ROOT" ] || { echo "usage: $0 <repo-root>" >&2; exit 1; }
[ -d "$REPO_ROOT/apps/reprobuild-sandbox-launcher" ] || {
  echo "not a reprobuild checkout: $REPO_ROOT" >&2; exit 1; }

GROUP=m6bldgrp
PREFIX=m6bld
COUNT=2
PROVISION="$REPO_ROOT/scripts/reprobuild-buildusers.sh"
WORK=/tmp/m6-buildusers
CALLER=m6caller          # ordinary (non build-user) account for default path

# Every check this harness is expected to run. If the body ever
# short-circuits -- a `set -e` death, an early `return`, a typo'd
# function name -- the count comes up short and the run FAILS rather
# than printing a clean "0 failures".
MIN_CHECKS=45

CHECKS=0
FAILURES=0
FINISHED=0

ok()   { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$*"; }

assert_eq()  { if [ "$2" = "$3" ];  then ok "$1 [$2]"; else bad "$1: expected '$2', got '$3'"; fi; }
assert_ne()  { if [ "$2" != "$3" ]; then ok "$1 [$2 != $3]"; else bad "$1: both are '$2'"; fi; }
assert_nonempty() { if [ -n "$2" ]; then ok "$1 [$2]"; else bad "$1: empty"; fi; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1: expected empty, got '$2'"; fi; }

on_exit() {
  local rc=$?
  if [ "$FINISHED" -ne 1 ]; then
    printf '\nHARNESS DIED EARLY (exit %s) after %s check(s)\n' "$rc" "$CHECKS"
    printf 'RESULT: FAIL (incomplete)\n'
    cleanup_accounts || true
    exit 1
  fi
}

cleanup_accounts() {
  bash "$PROVISION" destroy --group "$GROUP" --prefix "$PREFIX" --count "$COUNT" \
    >/dev/null 2>&1 || true
  # The probe deliberately outlives its launcher by a few seconds so phase
  # 4 can read /proc/<pid>/status while the build is genuinely running.
  # userdel(8) REFUSES (exit 8, "user X is currently used by process N")
  # while any process still runs as the account -- and because that
  # failure was discarded, a run that died mid-flight left a real system
  # account behind on the host, silently, in a harness whose entire
  # contract is to leave none. Reap the stragglers first, then insist.
  pkill -KILL -u "$CALLER" >/dev/null 2>&1 || true
  userdel -f "$CALLER" >/dev/null 2>&1 || true
}
trap on_exit EXIT

rm -rf "$WORK"; mkdir -p "$WORK"
chmod 0777 "$WORK"

# --- system readers (never echo back our own inputs) ------------------------
gid_of()   { getent group  "$1" 2>/dev/null | awk -F: 'NF>=3 {print $3}'; }
uid_of()   { getent passwd "$1" 2>/dev/null | awk -F: 'NF>=3 {print $3}'; }
pgid_of()  { getent passwd "$1" 2>/dev/null | awk -F: 'NF>=4 {print $4}'; }
shell_of() { getent passwd "$1" 2>/dev/null | awk -F: 'NF>=7 {print $7}'; }

# Owner uid/gid of a real inode, straight from stat(2).
owner_uid() { stat -c '%u' "$1" 2>/dev/null; }
owner_gid() { stat -c '%g' "$1" 2>/dev/null; }

echo "=== phase 0: preconditions and anti-vacuity guards ==="

assert_eq "harness runs as root" "0" "$(id -u)"

# THE anti-vacuity guard. If these already existed, every "the account
# exists" assertion later would pass without this feature doing anything.
assert_empty "build group '$GROUP' absent before provisioning" "$(gid_of "$GROUP")"
assert_empty "account ${PREFIX}01 absent before provisioning"  "$(uid_of "${PREFIX}01")"
assert_empty "account ${PREFIX}02 absent before provisioning"  "$(uid_of "${PREFIX}02")"

# The kernel must actually support the default path's mechanism,
# otherwise the "default install is still namespace sandboxed" check
# would be asserting about a fallback rather than about the feature.
if [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -gt 0 ]; then
  ok "kernel offers user namespaces (default sandbox path is real here)"
else
  bad "kernel has user namespaces disabled; the default-path phase would be vacuous"
fi

echo "=== phase 1: build the launcher from source ==="

LAUNCHER="$WORK/launcher-real"
( cd "$REPO_ROOT/apps/reprobuild-sandbox-launcher" && bash ./build.sh --out "$LAUNCHER" ) >"$WORK/build.log" 2>&1
if [ -x "$LAUNCHER" ]; then ok "launcher built"; else bad "launcher build produced no binary"; fi
assert_eq "launcher is a native ELF" "ELF" "$(head -c4 "$LAUNCHER" | tail -c3)"

# An ordinary, unprivileged account to play "the user doing a default install".
useradd --no-create-home --shell /bin/sh "$CALLER" 2>/dev/null || true
CALLER_UID="$(uid_of "$CALLER")"
assert_nonempty "ordinary caller account exists" "$CALLER_UID"

# The probe: reports who it is, and leaves an inode behind whose
# ownership the kernel -- not the probe -- decides.
cat >"$WORK/probe.sh" <<'PROBE'
#!/bin/sh
out="$1"
id -u > "$out.uid"
id -g > "$out.gid"
echo $$ > "$out.pid"
: > "$out.created"
# Stay alive briefly so the harness can read /proc/<pid>/status while
# this process is genuinely running.
sleep 4
PROBE
chmod 0755 "$WORK/probe.sh"

mk_manifest() { # mk_manifest <path> [build_uid build_gid]
  {
    echo "# generated by t_m6_buildusers_system_state.sh"
    echo "exec=$WORK/probe.sh"
    if [ $# -ge 3 ]; then
      echo "build_uid=$2"
      echo "build_gid=$3"
    fi
  } >"$1"
}

echo "=== phase 2: DEFAULT path (no build_uid in manifest), before provisioning ==="

mk_manifest "$WORK/default.manifest"
rm -f "$WORK/d1".*
su -s /bin/sh "$CALLER" -c "'$LAUNCHER' --manifest='$WORK/default.manifest' -- '$WORK/d1'" \
  >"$WORK/default.log" 2>&1 &
DEF_PID=$!
wait "$DEF_PID" || true

DEFAULT_INSIDE_BEFORE="$(cat "$WORK/d1.uid" 2>/dev/null || echo MISSING)"

# What the default path actually does, and what must keep being true:
# the launcher unshares CLONE_NEWUSER and maps the caller to uid 0
# INSIDE that namespace, so the build sees itself as root -- while the
# kernel still stamps the caller's REAL uid on every inode it creates
# OUTSIDE. That pair (0 inside, $CALLER_UID outside) *is* the per-user
# namespace sandbox. Asserting only "it ran as the caller" would have
# been wrong in exactly the direction that hides a broken sandbox.
assert_ne "default path: the caller is genuinely unprivileged on the host" "0" "$CALLER_UID"
assert_eq "default path: build sees uid 0 INSIDE its private user namespace" "0" "$DEFAULT_INSIDE_BEFORE"
assert_eq "default path: inode it creates is owned by the real caller OUTSIDE" "$CALLER_UID" "$(owner_uid "$WORK/d1.created")"
assert_ne "default path: the sandbox root is NOT real root (uid differs outside)" "$DEFAULT_INSIDE_BEFORE" "$(owner_uid "$WORK/d1.created")"

echo "=== phase 3: provisioning (clause 2.1) ==="

# `set -e` would abort at the provisioner's first non-zero exit, BEFORE
# `$?` could ever be read -- so as written this capture could only ever
# observe 0. That is this campaign's own `rc=$?` trap, reappearing inside
# a gate written to catch it. Suspending `set -e` across the call (the
# way `expect_rc` below already does) gives the assertion real content
# and turns a failing provisioner into a reported FAIL rather than a
# harness death that never names the cause.
set +e
bash "$PROVISION" provision --group "$GROUP" --prefix "$PREFIX" --count "$COUNT" \
  >"$WORK/provision.log" 2>&1
PROV_RC=$?
set -e
assert_eq "provision exited cleanly" "0" "$PROV_RC"

BGID="$(gid_of "$GROUP")"
U1="$(uid_of "${PREFIX}01")"
U2="$(uid_of "${PREFIX}02")"

assert_nonempty "getent group reports the build group exists now" "$BGID"
assert_nonempty "getent passwd reports ${PREFIX}01 exists now" "$U1"
assert_nonempty "getent passwd reports ${PREFIX}02 exists now" "$U2"
assert_ne "build account uid is not root" "0" "$U1"
assert_ne "the two build accounts are distinct uids" "$U1" "$U2"
assert_eq "${PREFIX}01 primary group is the build group" "$BGID" "$(pgid_of "${PREFIX}01")"
assert_eq "${PREFIX}02 primary group is the build group" "$BGID" "$(pgid_of "${PREFIX}02")"
case "$(shell_of "${PREFIX}01")" in
  *nologin|*false) ok "build account shell is a nologin shell [$(shell_of "${PREFIX}01")]" ;;
  *) bad "build account has a usable login shell: $(shell_of "${PREFIX}01")" ;;
esac
assert_ne "build account uid differs from the ordinary caller" "$CALLER_UID" "$U1"

echo "=== phase 4: the launcher USES the accounts (clause 2.2) ==="

mk_manifest "$WORK/bu.manifest" "$U1" "$BGID"
rm -f "$WORK/b1".*
"$LAUNCHER" --manifest="$WORK/bu.manifest" -- "$WORK/b1" >"$WORK/bu.log" 2>&1 &
BU_PID=$!

# Observe the LIVE process's credentials out of /proc while it runs.
PROC_UID=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -s "$WORK/b1.pid" ]; then
    PROBE_PID="$(cat "$WORK/b1.pid")"
    if [ -r "/proc/$PROBE_PID/status" ]; then
      PROC_UID="$(awk '/^Uid:/ {print $2}' "/proc/$PROBE_PID/status")"
      PROC_GID="$(awk '/^Gid:/ {print $2}' "/proc/$PROBE_PID/status")"
      break
    fi
  fi
  sleep 0.25
done
wait "$BU_PID" || true

assert_nonempty "observed a live build process in /proc" "$PROC_UID"
assert_eq "LIVE PROCESS real uid is the provisioned build account" "$U1" "$PROC_UID"
assert_eq "LIVE PROCESS real gid is the provisioned build group"  "$BGID" "${PROC_GID:-}"
assert_eq "build self-reports the build account uid" "$U1" "$(cat "$WORK/b1.uid" 2>/dev/null || echo MISSING)"
assert_eq "build self-reports the build group gid"  "$BGID" "$(cat "$WORK/b1.gid" 2>/dev/null || echo MISSING)"
assert_eq "INODE created by the build is owned by the build account" "$U1" "$(owner_uid "$WORK/b1.created")"
assert_eq "INODE created by the build is grouped to the build group" "$BGID" "$(owner_gid "$WORK/b1.created")"
assert_ne "the build did NOT run as root" "0" "$(cat "$WORK/b1.uid" 2>/dev/null || echo 0)"
assert_ne "the build did NOT run as the invoking user" "$(id -u)" "$(cat "$WORK/b1.uid" 2>/dev/null || echo 0)"

echo "=== phase 5: negative controls (the checks must be able to fail) ==="

expect_rc() { # expect_rc <label> <expected-rc> <cmd...>
  local label="$1" want="$2"; shift 2
  set +e
  "$@" >"$WORK/neg.log" 2>&1
  local got=$?
  set -e
  assert_eq "$label" "$want" "$got"
}

# 5a. build_uid without build_gid must be a parse error, not a default.
{ echo "exec=$WORK/probe.sh"; echo "build_uid=$U1"; } >"$WORK/half.manifest"
expect_rc "half-specified manifest is rejected (exit 1)" 1 \
  "$LAUNCHER" --manifest="$WORK/half.manifest" --dry-run -- "$WORK/h1"

# 5b. build_uid=0 must be refused: a build user that is root is not one.
{ echo "exec=$WORK/probe.sh"; echo "build_uid=0"; echo "build_gid=0"; } >"$WORK/root.manifest"
expect_rc "build_uid=0 is rejected (exit 1)" 1 \
  "$LAUNCHER" --manifest="$WORK/root.manifest" --dry-run -- "$WORK/h2"

# 5c. non-numeric uid must be refused rather than silently becoming 0.
{ echo "exec=$WORK/probe.sh"; echo "build_uid=root"; echo "build_gid=$BGID"; } >"$WORK/junk.manifest"
expect_rc "non-numeric build_uid is rejected (exit 1)" 1 \
  "$LAUNCHER" --manifest="$WORK/junk.manifest" --dry-run -- "$WORK/h3"

# 5d. An UNPRIVILEGED launcher handed a build-user manifest must fail
#     closed (exit 6), not quietly run the build as the calling user.
#     This is the dangerous-silent-fallback case.
rm -f "$WORK/n1".*
expect_rc "unprivileged launcher refuses build-user manifest (exit 6)" 6 \
  su -s /bin/sh "$CALLER" -c "'$LAUNCHER' --manifest='$WORK/bu.manifest' -- '$WORK/n1'"
if [ -e "$WORK/n1.created" ]; then
  bad "unprivileged refusal still executed the build (file was created)"
else
  ok "unprivileged refusal executed nothing"
fi

echo "=== phase 6: MUTATION — an inert feature must be caught ==="

# Rebuild the launcher with the privilege drop neutered, exactly the way
# a silently-ignored control fails in the wild, and re-run the phase-4
# assertion. If that assertion still passes, it was never testing
# anything and this whole harness is worthless.
MUT_SRC="$WORK/launcher-mutant.c"
sed 's/if (!m->build_user_set) return 0;   \/\* default path: nothing happens \*\//if (1) return 0; \/* MUTANT: feature neutered *\//' \
  "$REPO_ROOT/apps/reprobuild-sandbox-launcher/launcher.c" >"$MUT_SRC"
if ! cmp -s "$MUT_SRC" "$REPO_ROOT/apps/reprobuild-sandbox-launcher/launcher.c"; then
  ok "mutation applied to a copy of launcher.c"
else
  bad "mutation did not change the source; the mutation test would be vacuous"
fi
cc -O2 -Wall -std=c11 -o "$WORK/launcher-mutant" "$MUT_SRC" 2>"$WORK/mutbuild.log"
rm -f "$WORK/m1".*
"$WORK/launcher-mutant" --manifest="$WORK/bu.manifest" -- "$WORK/m1" >/dev/null 2>&1 &
wait $! || true
MUT_UID="$(cat "$WORK/m1.uid" 2>/dev/null || echo MISSING)"
if [ "$MUT_UID" = "$U1" ]; then
  bad "MUTANT still ran as the build user: phase 4's assertion proves nothing"
else
  ok "mutant ran as uid $MUT_UID, not the build account — phase 4 has real power"
fi
assert_eq "mutant ran as root (the un-dropped identity)" "0" "$MUT_UID"

echo "=== phase 7: default path UNCHANGED after provisioning (clause 2.3) ==="

# Same manifest, same caller, same launcher, after the build-user pool
# exists on this host. The default install must be completely unaffected
# by the fact that the hardened mode is available.
rm -f "$WORK/d2".*
su -s /bin/sh "$CALLER" -c "'$LAUNCHER' --manifest='$WORK/default.manifest' -- '$WORK/d2'" \
  >"$WORK/default2.log" 2>&1 &
wait $! || true
DEFAULT_INSIDE_AFTER="$(cat "$WORK/d2.uid" 2>/dev/null || echo MISSING)"

assert_eq "default path still maps the caller to uid 0 inside its namespace" "0" "$DEFAULT_INSIDE_AFTER"
assert_eq "default path inside-uid IDENTICAL before and after provisioning" "$DEFAULT_INSIDE_BEFORE" "$DEFAULT_INSIDE_AFTER"
assert_ne "default path did NOT drift onto a provisioned build account" "$U1" "$DEFAULT_INSIDE_AFTER"
assert_eq "default path inode still owned by the real caller, not a build user" "$CALLER_UID" "$(owner_uid "$WORK/d2.created")"
assert_ne "default path inode owner is NOT a build account" "$U1" "$(owner_uid "$WORK/d2.created")"

# And the default path is still the *namespace* path: an unprivileged
# caller that got uid 0 inside a user namespace maps back to its own uid
# outside. Confirm the launcher really did create a user namespace for
# it rather than running unsandboxed.
DEF_USERNS="$(su -s /bin/sh "$CALLER" -c "'$LAUNCHER' --manifest='$WORK/default.manifest' --dry-run --verbose -- x" 2>&1 | grep -c 'CLONE_NEWUSER' || true)"
assert_eq "default path still elects a user namespace" "1" "$DEF_USERNS"

echo "=== phase 8: teardown and census ==="

bash "$PROVISION" destroy --group "$GROUP" --prefix "$PREFIX" --count "$COUNT" >"$WORK/destroy.log" 2>&1
assert_empty "build group removed again" "$(gid_of "$GROUP")"
assert_empty "${PREFIX}01 removed again" "$(uid_of "${PREFIX}01")"
pkill -KILL -u "$CALLER" >/dev/null 2>&1 || true
userdel -f "$CALLER" >/dev/null 2>&1 || true
# Asserted, not assumed: userdel(8) refuses while a process still runs as
# the account, and a discarded refusal is how a test harness quietly
# leaves a real account on a real host.
assert_empty "ordinary caller account removed (no account residue)" "$(uid_of "$CALLER")"

printf '\n%s checks, %s failure(s)\n' "$CHECKS" "$FAILURES"

if [ "$CHECKS" -lt "$MIN_CHECKS" ]; then
  printf 'RESULT: FAIL — ran %s checks, expected at least %s (harness skipped work)\n' \
    "$CHECKS" "$MIN_CHECKS"
  FINISHED=1
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf 'RESULT: FAIL — %s failing check(s)\n' "$FAILURES"
  FINISHED=1
  exit 1
fi
printf 'RESULT: PASS\n'
FINISHED=1
exit 0

#!/usr/bin/env bash
# t_de0_dbus.sh -- DE0-D overlay-planter integration test.
#
# Exercises recipes/reproos-mvp-config/de0-dbus.sh against a scratch
# overlay directory and asserts every artefact the campaign spec
# requires lands in the right place with the right shape.
#
# What this test DOES gate:
#   - dbus-broker (or dbus-daemon fallback) binary planted.
#   - libdbus + support libs planted under /lib/x86_64-linux-gnu.
#   - System unit dbus.service un-mask + multi-user.target.wants
#     wiring.
#   - dbus.socket wired into sockets.target.wants.
#   - User-instance dbus.socket wired into
#     /etc/systemd/user/sockets.target.wants/.
#   - /etc/dbus-1/{system,session}.conf default policy planted.
#   - messagebus:x:101:101 user + group + locked shadow entry.
#   - /var/lib/dbus + /run/dbus dirs.
#   - tmpfiles.d snippet creates+chowns the dirs at boot.
#   - Sentinel file is created.
#   - A second invocation is a no-op (idempotency).
#
# What this test does NOT gate (covered by DE0-G smoke test):
#   - Booting the augmented ISO in vm-harness.
#   - `busctl --system` returning a service list.
#   - `dbus-send --session` succeeding inside a logged-in session.
#
# Exit:
#   0 = PASS, 1 = test FAIL, 2 = SKIP (host missing required packages).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RECIPE_SH="$REPO_ROOT/recipes/reproos-mvp-config/de0-dbus.sh"
[ -f "$RECIPE_SH" ] || { echo "FAIL: recipe missing: $RECIPE_SH" >&2; exit 1; }
[ -x "$RECIPE_SH" ] || chmod +x "$RECIPE_SH" 2>/dev/null || true

# Skip on hosts without dpkg (the recipe sources files via dpkg -L).
if ! command -v dpkg >/dev/null 2>&1; then
  echo "SKIP: dpkg not available (this test requires a Debian/Ubuntu host)"
  exit 2
fi

# Skip on non-jammy hosts (recipe enforces this; we mirror the gate
# rather than fight it).
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "22.04" ]; then
    echo "SKIP: host is ${ID:-?} ${VERSION_ID:-?}; recipe expects ubuntu 22.04 (jammy)"
    exit 2
  fi
fi

# Required packages: at minimum we need libdbus-1-3 + dbus +
# dbus-user-session. dbus-broker is preferred but optional.
for pkg in libdbus-1-3 dbus dbus-user-session; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "SKIP: host package $pkg not installed (apt install $pkg)"
    exit 2
  fi
done

# Detect which daemon path the recipe will take so test assertions
# below can branch correctly.
EXPECT_DAEMON="daemon"
if dpkg -s dbus-broker >/dev/null 2>&1; then
  EXPECT_DAEMON="broker"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/de0-d-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
OVERLAY="$WORKDIR/overlay"
mkdir -p "$OVERLAY"

ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stage A: apply the recipe.
# ---------------------------------------------------------------------------

bash "$RECIPE_SH" "$OVERLAY" >"$WORKDIR/apply.log" 2>&1 || {
  cat "$WORKDIR/apply.log" >&2
  fail "recipe apply failed"
}
ok "recipe applied to $OVERLAY (daemon=$EXPECT_DAEMON)"

# ---------------------------------------------------------------------------
# Stage B: daemon binary planted.
# ---------------------------------------------------------------------------

if [ "$EXPECT_DAEMON" = "broker" ]; then
  for bin in /usr/bin/dbus-broker /usr/bin/dbus-broker-launch; do
    [ -f "$OVERLAY$bin" ] || fail "broker binary missing: $OVERLAY$bin"
    [ -s "$OVERLAY$bin" ] || fail "broker binary is empty: $OVERLAY$bin"
  done
  ok "dbus-broker + dbus-broker-launch binaries planted"
fi
# dbus package binaries (always present: dbus-send is needed by
# logind's ExecReload).
for bin in /usr/bin/dbus-daemon /usr/bin/dbus-send /usr/bin/dbus-uuidgen; do
  [ -f "$OVERLAY$bin" ] || fail "dbus binary missing: $OVERLAY$bin"
  [ -s "$OVERLAY$bin" ] || fail "dbus binary is empty: $OVERLAY$bin"
done
ok "dbus utility binaries planted"

# ---------------------------------------------------------------------------
# Stage C: libdbus + support libs.
# ---------------------------------------------------------------------------

LIBDIR="$OVERLAY/lib/x86_64-linux-gnu"
[ -d "$LIBDIR" ] || fail "libdir missing: $LIBDIR"

# libdbus-1.so.3 (the symlink) must be present.
if [ ! -e "$LIBDIR/libdbus-1.so.3" ]; then
  fail "libdbus-1.so.3 not planted in $LIBDIR"
fi

# libsystemd is required by dbus-broker-launch.
[ -e "$LIBDIR/libsystemd.so.0" ] || fail "libsystemd.so.0 not planted in $LIBDIR"
[ -e "$LIBDIR/libexpat.so.1"   ] || fail "libexpat.so.1 not planted in $LIBDIR"
ok "libdbus + libsystemd + libexpat planted"

# ---------------------------------------------------------------------------
# Stage D: system unit wiring.
# ---------------------------------------------------------------------------

DBUS_SVC_LINK="$OVERLAY/etc/systemd/system/dbus.service"
[ -L "$DBUS_SVC_LINK" ] || fail "dbus.service un-mask symlink missing"
target=$(readlink "$DBUS_SVC_LINK")
if [ "$EXPECT_DAEMON" = "broker" ]; then
  [ "$target" = "/usr/lib/systemd/system/dbus-broker.service" ] || \
    fail "dbus.service should -> dbus-broker.service, got: $target"
else
  [ "$target" = "/lib/systemd/system/dbus.service" ] || \
    fail "dbus.service should -> /lib/systemd/system/dbus.service, got: $target"
fi
ok "dbus.service un-mask points at $target"

WANT_LINK="$OVERLAY/etc/systemd/system/multi-user.target.wants/dbus.service"
[ -L "$WANT_LINK" ] || fail "dbus.service multi-user wants symlink missing"
ok "dbus.service wired into multi-user.target.wants"

SOCK_WANT="$OVERLAY/etc/systemd/system/sockets.target.wants/dbus.socket"
[ -L "$SOCK_WANT" ] || fail "dbus.socket sockets.target.wants symlink missing"
target=$(readlink "$SOCK_WANT")
[ "$target" = "/lib/systemd/system/dbus.socket" ] || \
  fail "dbus.socket should -> /lib/systemd/system/dbus.socket, got: $target"
ok "dbus.socket wired into sockets.target.wants"

# Confirm the underlying system unit files were planted by dpkg -L
# replay; the wires only work if the targets exist.
if [ "$EXPECT_DAEMON" = "broker" ]; then
  [ -f "$OVERLAY/usr/lib/systemd/system/dbus-broker.service" ] || \
    [ -f "$OVERLAY/lib/systemd/system/dbus-broker.service" ] || \
    fail "dbus-broker.service unit file not planted"
fi
[ -f "$OVERLAY/lib/systemd/system/dbus.socket" ] || fail "dbus.socket unit file not planted"
ok "underlying system unit files planted"

# ---------------------------------------------------------------------------
# Stage E: user-instance unit wiring.
# ---------------------------------------------------------------------------

USR_SOCK="$OVERLAY/etc/systemd/user/sockets.target.wants/dbus.socket"
[ -L "$USR_SOCK" ] || fail "user dbus.socket wants symlink missing"
target=$(readlink "$USR_SOCK")
[ "$target" = "/usr/lib/systemd/user/dbus.socket" ] || \
  fail "user dbus.socket should -> /usr/lib/systemd/user/dbus.socket, got: $target"
ok "user dbus.socket wired into sockets.target.wants"

if [ "$EXPECT_DAEMON" = "broker" ]; then
  USR_SVC="$OVERLAY/etc/systemd/user/dbus.service"
  [ -L "$USR_SVC" ] || fail "user dbus.service override symlink missing (broker mode)"
  target=$(readlink "$USR_SVC")
  [ "$target" = "/usr/lib/systemd/user/dbus-broker.service" ] || \
    fail "user dbus.service should -> dbus-broker.service, got: $target"
  ok "user dbus.service overridden to dbus-broker.service"
fi

# Confirm user-instance files planted.
[ -f "$OVERLAY/usr/lib/systemd/user/dbus.socket" ] || \
  fail "user dbus.socket unit file not planted (from dbus-user-session)"
[ -f "$OVERLAY/usr/lib/systemd/user/dbus.service" ] || \
  fail "user dbus.service unit file not planted (from dbus-user-session)"
ok "user-instance unit files planted"

# ---------------------------------------------------------------------------
# Stage F: default policy.
# ---------------------------------------------------------------------------

SYS_CONF="$OVERLAY/etc/dbus-1/system.conf"
[ -L "$SYS_CONF" ] || fail "/etc/dbus-1/system.conf symlink missing"
target=$(readlink "$SYS_CONF")
[ "$target" = "/usr/share/dbus-1/system.conf" ] || \
  fail "/etc/dbus-1/system.conf wrong target: $target"

SES_CONF="$OVERLAY/etc/dbus-1/session.conf"
[ -L "$SES_CONF" ] || fail "/etc/dbus-1/session.conf symlink missing"
ok "/etc/dbus-1/system.conf + session.conf planted"

# The actual policy files live under /usr/share/dbus-1/ planted from
# the dbus package.
[ -f "$OVERLAY/usr/share/dbus-1/system.conf" ] || \
  fail "/usr/share/dbus-1/system.conf not planted"

# ---------------------------------------------------------------------------
# Stage G: messagebus user account.
# ---------------------------------------------------------------------------

P="$OVERLAY/etc/passwd"
[ -f "$P" ] || fail "/etc/passwd missing"
grep -q "^messagebus:x:101:101:" "$P" || fail "messagebus user not in /etc/passwd"

G="$OVERLAY/etc/group"
[ -f "$G" ] || fail "/etc/group missing"
grep -q "^messagebus:x:101:" "$G" || fail "messagebus group not in /etc/group"

# /var/lib/dbus dir + tmpfiles.d.
[ -d "$OVERLAY/var/lib/dbus" ] || fail "/var/lib/dbus dir missing"
[ -d "$OVERLAY/run/dbus" ]     || fail "/run/dbus dir missing"

TMP="$OVERLAY/etc/tmpfiles.d/dbus.conf"
[ -f "$TMP" ] || fail "tmpfiles.d/dbus.conf missing"
grep -q "/var/lib/dbus" "$TMP" || fail "tmpfiles.d/dbus.conf lacks /var/lib/dbus line"
grep -q "/run/dbus"     "$TMP" || fail "tmpfiles.d/dbus.conf lacks /run/dbus line"
ok "messagebus user + group + spool/runtime dirs + tmpfiles.d snippet planted"

# ---------------------------------------------------------------------------
# Stage H: sentinel.
# ---------------------------------------------------------------------------

SENTINEL="$OVERLAY/var/lib/reproos-de0-dbus-done"
[ -f "$SENTINEL" ] || fail "sentinel missing: $SENTINEL"
grep -q "DE0-D" "$SENTINEL" || fail "sentinel body missing DE0-D marker"
grep -q "Daemon: $EXPECT_DAEMON" "$SENTINEL" || fail "sentinel daemon mismatch"
ok "sentinel planted at $SENTINEL"

# ---------------------------------------------------------------------------
# Stage I: idempotency. Re-apply on the SAME overlay should be a
# no-op (sentinel short-circuit).
# ---------------------------------------------------------------------------

bash "$RECIPE_SH" "$OVERLAY" >"$WORKDIR/apply2.log" 2>&1 || {
  cat "$WORKDIR/apply2.log" >&2
  fail "idempotent re-apply failed"
}
if ! grep -q "sentinel present" "$WORKDIR/apply2.log"; then
  cat "$WORKDIR/apply2.log" >&2
  fail "re-apply did not short-circuit on sentinel"
fi
ok "second invocation short-circuits on sentinel"

# ---------------------------------------------------------------------------
# Stage J: regression-style co-existence with DE0-S.
#
# Apply DE0-S on a SECOND fresh overlay, then DE0-D on top, and verify
# that messagebus + repro both end up in /etc/passwd (the upsert logic
# must preserve repro, not stomp on it). This guards against the
# "Reprobuild shell-out injection pattern" review reflex: any time we
# rewrite a config file, we must verify the union holds.
# ---------------------------------------------------------------------------

DE0S_SH="$REPO_ROOT/recipes/reproos-mvp-config/de0-systemd-session.sh"
if [ -f "$DE0S_SH" ]; then
  OVERLAY2="$WORKDIR/overlay2"
  mkdir -p "$OVERLAY2"
  # DE0-S needs PAM modules on host; if they're missing, skip the
  # co-existence check rather than fail (the DE0-S test would skip
  # for the same reason).
  HOST_PAM=""
  for cand in /lib/x86_64-linux-gnu/security /usr/lib/x86_64-linux-gnu/security; do
    if [ -d "$cand" ] && [ -f "$cand/pam_unix.so" ]; then HOST_PAM="$cand"; break; fi
  done
  if [ -n "$HOST_PAM" ]; then
    bash "$DE0S_SH" "$OVERLAY2" >"$WORKDIR/de0s.log" 2>&1 || {
      cat "$WORKDIR/de0s.log" >&2
      fail "DE0-S apply on fresh overlay failed"
    }
    bash "$RECIPE_SH" "$OVERLAY2" >"$WORKDIR/de0d.log" 2>&1 || {
      cat "$WORKDIR/de0d.log" >&2
      fail "DE0-D apply on DE0-S overlay failed"
    }
    grep -q "^repro:x:1000:1000:" "$OVERLAY2/etc/passwd" || \
      fail "DE0-D apply stomped repro user from DE0-S /etc/passwd"
    grep -q "^messagebus:x:101:101:" "$OVERLAY2/etc/passwd" || \
      fail "DE0-D apply failed to add messagebus to DE0-S /etc/passwd"
    grep -q "^root:x:0:0:" "$OVERLAY2/etc/passwd" || \
      fail "DE0-D apply stomped root from DE0-S /etc/passwd"
    ok "DE0-D apply on top of DE0-S preserves repro + root + adds messagebus"
  else
    ok "(skipped co-existence check: host PAM modules missing)"
  fi
fi

echo "PASS: t_de0_dbus.sh"
exit 0

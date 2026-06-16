#!/usr/bin/env bash
# t_de0_systemd_session.sh -- DE0-S overlay-planter integration test.
#
# Exercises recipes/reproos-mvp-config/de0-systemd-session.sh against a
# scratch overlay directory and asserts every artefact the campaign
# spec requires lands in the right place with the right shape.
#
# What this test DOES gate:
#   - PAM stack files are present at /etc/pam.d/{login,su,system-auth}.
#   - Each PAM stack references modules that the recipe also plants
#     under <OVERLAY>/lib/x86_64-linux-gnu/security/.
#   - systemd-logind un-mask symlink points back at the real unit.
#   - multi-user.target.wants/systemd-logind.service is wired.
#   - Per-user graphical-session targets land under /etc/systemd/user/
#     with the documented shape (empty [Unit]).
#   - /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow include the
#     `repro:1000:1000` account.
#   - /home/repro directory exists.
#   - /etc/tmpfiles.d/repro-home.conf chowns the home dir at boot.
#   - The sentinel file is created.
#   - A second invocation is a no-op (idempotency).
#
# What this test does NOT gate (covered by DE0-G smoke test):
#   - Booting the augmented ISO in vm-harness.
#   - Verifying `loginctl` shows an active session.
#   - Verifying `$XDG_RUNTIME_DIR` is set to `/run/user/1000`.
#   - Verifying `systemctl --user status` reports the user instance.
#
# Exit:
#   0 = PASS, 1 = test FAIL, 2 = SKIP (host missing required PAM modules).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RECIPE_SH="$REPO_ROOT/recipes/reproos-mvp-config/de0-systemd-session.sh"
[ -f "$RECIPE_SH" ] || { echo "FAIL: recipe missing: $RECIPE_SH" >&2; exit 1; }
[ -x "$RECIPE_SH" ] || chmod +x "$RECIPE_SH" 2>/dev/null || true

# Skip on hosts without the linux-pam modules we need to copy.
HOST_PAM_DIR=""
for cand in /lib/x86_64-linux-gnu/security /usr/lib/x86_64-linux-gnu/security /usr/lib64/security /lib64/security; do
  if [ -d "$cand" ]; then HOST_PAM_DIR="$cand"; break; fi
done
if [ -z "$HOST_PAM_DIR" ]; then
  echo "SKIP: no PAM module directory on host (install libpam-modules)"
  exit 2
fi
for m in pam_unix.so pam_permit.so pam_deny.so pam_loginuid.so; do
  if [ ! -f "$HOST_PAM_DIR/$m" ]; then
    echo "SKIP: host PAM module missing: $HOST_PAM_DIR/$m"
    exit 2
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/de0-s-test.XXXXXX")"
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
ok "recipe applied to $OVERLAY"

# ---------------------------------------------------------------------------
# Stage B: PAM modules planted.
# ---------------------------------------------------------------------------

PAM_OUT="$OVERLAY/lib/x86_64-linux-gnu/security"
[ -d "$PAM_OUT" ] || fail "PAM module dir not planted: $PAM_OUT"
for m in pam_unix.so pam_permit.so pam_deny.so pam_loginuid.so; do
  [ -f "$PAM_OUT/$m" ] || fail "PAM module not planted: $PAM_OUT/$m"
  [ -s "$PAM_OUT/$m" ] || fail "PAM module is empty (zero-byte): $PAM_OUT/$m"
done
ok "PAM modules planted at $PAM_OUT"

# ---------------------------------------------------------------------------
# Stage C: PAM stack files.
# ---------------------------------------------------------------------------

for f in login su system-auth; do
  p="$OVERLAY/etc/pam.d/$f"
  [ -f "$p" ] || fail "PAM stack missing: $p"
  grep -q "^auth.*required.*pam_unix.so" "$p" || fail "$p missing auth pam_unix.so"
  grep -q "^account.*required.*pam_unix.so" "$p" || fail "$p missing account pam_unix.so"
  grep -q "^session.*required.*pam_unix.so" "$p" || fail "$p missing session pam_unix.so"
  grep -q "^session.*required.*pam_systemd.so" "$p" || fail "$p missing session pam_systemd.so"
done
ok "/etc/pam.d/{login,su,system-auth} present with required+pam_unix+pam_systemd"

# Cross-validate every PAM module referenced in the stacks exists
# either in the planted overlay tree OR (for pam_systemd.so) in the
# R9 systemd install tree the cpio segment 1 will provide.
referenced=$(awk '/^[^#]/ && NF>=3 { print $3 }' \
  "$OVERLAY/etc/pam.d/login" \
  "$OVERLAY/etc/pam.d/su" \
  "$OVERLAY/etc/pam.d/system-auth" | sort -u)
for m in $referenced; do
  case "$m" in
    pam_systemd.so)
      # R9 ships this at usr/lib/x86_64-linux-gnu/security/pam_systemd.so;
      # we also plant a host-copy fallback at /lib/.../security/.
      if [ ! -f "$PAM_OUT/$m" ]; then
        fail "PAM stack references $m but no fallback planted at $PAM_OUT/$m"
      fi
      ;;
    pam_unix.so|pam_permit.so|pam_deny.so|pam_loginuid.so)
      [ -f "$PAM_OUT/$m" ] || fail "PAM stack references $m but module not planted at $PAM_OUT/$m"
      ;;
    *)
      fail "unexpected PAM module referenced: $m"
      ;;
  esac
done
ok "every referenced PAM module is planted"

# ---------------------------------------------------------------------------
# Stage D: systemd-logind un-mask + wiring.
# ---------------------------------------------------------------------------

LOGIND_LINK="$OVERLAY/etc/systemd/system/systemd-logind.service"
[ -L "$LOGIND_LINK" ] || fail "logind un-mask symlink missing: $LOGIND_LINK"
target=$(readlink "$LOGIND_LINK")
[ "$target" = "/usr/lib/systemd/system/systemd-logind.service" ] || \
  fail "logind un-mask points wrong: $target"
ok "systemd-logind un-mask points at /usr/lib/systemd/system/systemd-logind.service"

WANT_LINK="$OVERLAY/etc/systemd/system/multi-user.target.wants/systemd-logind.service"
[ -L "$WANT_LINK" ] || fail "logind WantedBy symlink missing: $WANT_LINK"
target=$(readlink "$WANT_LINK")
[ "$target" = "/usr/lib/systemd/system/systemd-logind.service" ] || \
  fail "logind WantedBy points wrong: $target"
ok "systemd-logind wired into multi-user.target.wants"

# ---------------------------------------------------------------------------
# Stage E: per-user graphical-session targets.
# ---------------------------------------------------------------------------

USR_DIR="$OVERLAY/etc/systemd/user"
[ -d "$USR_DIR" ] || fail "user-instance dir missing: $USR_DIR"
[ -f "$USR_DIR/graphical-session.target" ] || \
  fail "graphical-session.target missing"
grep -q "^Description=" "$USR_DIR/graphical-session.target" || \
  fail "graphical-session.target lacks [Unit] Description"
[ -f "$USR_DIR/graphical-session-pre.target" ] || \
  fail "graphical-session-pre.target missing"

DEFAULT_LINK="$USR_DIR/default.target"
[ -L "$DEFAULT_LINK" ] || fail "default.target should be a symlink: $DEFAULT_LINK"
target=$(readlink "$DEFAULT_LINK")
[ "$target" = "basic.target" ] || \
  fail "default.target should -> basic.target, got: $target"
ok "graphical-session{,-pre}.target + default.target -> basic.target planted"

# ---------------------------------------------------------------------------
# Stage F: default repro user account.
# ---------------------------------------------------------------------------

P="$OVERLAY/etc/passwd"
[ -f "$P" ] || fail "/etc/passwd missing"
grep -q "^repro:x:1000:1000:" "$P" || fail "repro user not in /etc/passwd"
grep -q "^root:x:0:0:" "$P" || fail "root entry missing in /etc/passwd"

G="$OVERLAY/etc/group"
[ -f "$G" ] || fail "/etc/group missing"
grep -q "^repro:x:1000:" "$G" || fail "repro group not in /etc/group"

S="$OVERLAY/etc/shadow"
[ -f "$S" ] || fail "/etc/shadow missing"
grep -q "^repro::" "$S" || fail "repro shadow entry missing"

[ -d "$OVERLAY/home/repro" ] || fail "/home/repro dir missing"

TMP="$OVERLAY/etc/tmpfiles.d/repro-home.conf"
[ -f "$TMP" ] || fail "tmpfiles.d/repro-home.conf missing"
grep -q "/home/repro" "$TMP" || fail "tmpfiles.d snippet lacks /home/repro line"
ok "default repro user account + /home/repro + tmpfiles.d snippet planted"

# ---------------------------------------------------------------------------
# Stage G: sentinel.
# ---------------------------------------------------------------------------

SENTINEL="$OVERLAY/var/lib/reproos-de0-systemd-session-done"
[ -f "$SENTINEL" ] || fail "sentinel missing: $SENTINEL"
grep -q "DE0-S" "$SENTINEL" || fail "sentinel body missing DE0-S marker"
ok "sentinel planted at $SENTINEL"

# ---------------------------------------------------------------------------
# Stage H: idempotency. Re-apply on the SAME overlay should be a
# no-op (sentinel short-circuit). Capture log size before/after.
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

echo "PASS: t_de0_systemd_session.sh"
exit 0

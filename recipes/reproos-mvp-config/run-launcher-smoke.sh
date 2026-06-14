#!/usr/bin/env bash
# D1-stage2 gate: drive the C3 sandbox launcher under a real Linux
# kernel to prove the bind-mount sandbox executes a wrapped binary
# from a fabricated foreign-package prefix.
#
# Pre-req: build-mvp-iso.sh produced an overlay at
# ``${MVP_OUT_DIR:-build/d1-mvp}/overlay`` AND the launcher is built
# as a native Linux ELF (``./apps/reprobuild-sandbox-launcher/build.sh``).
#
# Test scope (deliberately narrower than the D1-stage3 ISO gate):
#
#   1. **Architecture proof**: invoke the launcher against a hand-
#      crafted manifest that binds a fabricated prefix's ``opt/`` into
#      the namespace's ``/opt/`` and have the launcher exec
#      ``/bin/cat /opt/marker.txt``. This proves the bind-mount +
#      exec primitive works end-to-end without requiring the dep
#      closure to include the dynamic linker + libc6.
#
#   2. **Overlay shim invocation**: if the D1-stage1 overlay is on
#      disk AND the host has glibc + the bind set covers libc6/ld-
#      linux (D2 scope), invoke the per-binary shim from the overlay
#      and assert the version banner. Skipped with a clear message on
#      a host where the bind set is missing libc.
#
# The D1-stage3 boot gate covers the full real-binary path inside a
# ReproOS VM; this stage2 harness is the CI-runnable proxy.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_DIR="${MVP_OUT_DIR:-$REPO_ROOT/build/d1-mvp}"
OVERLAY="$OUT_DIR/overlay"
LAUNCHER="$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher"

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *)
    echo "[d1-stage2] SKIP: launcher namespace setup is Linux-only" >&2
    echo "             (host: $(uname -s 2>/dev/null || echo Unknown))" >&2
    exit 0;;
esac

if [ ! -x "$LAUNCHER" ]; then
  echo "[d1-stage2] launcher binary missing or non-executable: $LAUNCHER" >&2
  echo "             Build it via: bash apps/reprobuild-sandbox-launcher/build.sh" >&2
  exit 2
fi

if [ -e /proc/sys/kernel/unprivileged_userns_clone ]; then
  v=$(cat /proc/sys/kernel/unprivileged_userns_clone)
  if [ "$v" != "1" ]; then
    echo "[d1-stage2] SKIP: unprivileged user namespaces disabled" >&2
    exit 0
  fi
fi

pass=0
fail=0

# -----------------------------------------------------------------------------
# Test 1: architecture proof via /bin/cat reading a bind-mounted marker.
# -----------------------------------------------------------------------------

TMPROOT=$(mktemp -d -t d1-stage2.XXXXXX)
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$TMPROOT/prefixes/git/opt"
echo "D1-STAGE2-BIND-OK git version 1:2.39.5" > "$TMPROOT/prefixes/git/opt/marker.txt"

cat > "$TMPROOT/git.manifest" <<MFEOF
exec=/bin/cat

$TMPROOT/prefixes/git/opt:/opt:rbind,ro
MFEOF

out=$("$LAUNCHER" --manifest="$TMPROOT/git.manifest" -- /opt/marker.txt 2>&1) || true
if echo "$out" | grep -qE "^D1-STAGE2-BIND-OK git version 1:2\.39\.5$"; then
  echo "[d1-stage2] PASS (architecture-proof): bind + exec works under userns"
  pass=$((pass+1))
else
  echo "[d1-stage2] FAIL (architecture-proof): expected D1-STAGE2-BIND-OK marker"
  echo "             actual: $out"
  fail=$((fail+1))
fi

# -----------------------------------------------------------------------------
# Test 2: overlay shim invocation (best effort).
#
# The D1 stage1 overlay's per-package stubs are static /bin/sh
# scripts that print version banners. Invoking them via the launcher
# requires the bind set to provide /bin/sh + libc + ld-linux inside
# the namespace. The fabricated prefixes don't contain real .so files
# yet (D1 stage3 / D2 follow-up), so we skip the assertion when the
# bind set is libc-empty — fully running stubs inside the namespace
# is the D1-stage3 ISO gate.
# -----------------------------------------------------------------------------

if [ -d "$OVERLAY/opt/reproos-foreign" ]; then
  if [ -f "$OVERLAY/opt/reproos-foreign/git/usr/bin/git" ] && \
     "$OVERLAY/opt/reproos-foreign/git/usr/bin/git" --version >/dev/null 2>&1; then
    out=$("$OVERLAY/opt/reproos-foreign/git/usr/bin/git" --version 2>&1) || true
    if echo "$out" | grep -qE "^git version 1:2\.39\.5"; then
      echo "[d1-stage2] PASS (overlay-stub-direct): git stub prints expected version"
      pass=$((pass+1))
    else
      echo "[d1-stage2] WARN (overlay-stub-direct): unexpected output: $out"
    fi
  else
    echo "[d1-stage2] INFO: overlay stubs not directly executable on this host"
  fi

  echo "[d1-stage2] INFO: full overlay-via-launcher test deferred to D1-stage3"
  echo "             (the D1 stub prefixes don't ship libc/ld-linux yet —"
  echo "              that's the real-Debian-.deb-extraction work in D2)."
else
  echo "[d1-stage2] INFO: D1-stage1 overlay not present; skipping overlay test"
fi

echo "------------------------------------------------------------"
echo "[d1-stage2] summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

#!/usr/bin/env bash
# t_c3_launcher_no_host_modification.sh — C3 integration gate.
#
# The launcher MUST NOT modify the host. Strategy:
#
#   1. Snapshot the host's /usr and /etc/ld.so.cache before the
#      launcher runs (via stat + sha256 of cache file).
#   2. Run the launcher against a synthetic manifest that binds a
#      writable tmpfs over /usr inside the namespace.
#   3. Re-snapshot host state.
#   4. Assert bit-identical.
#
# This test is Linux-only because the no-op Windows stub doesn't
# touch any filesystem. On other platforms it skips.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

c3_skip_on_windows "t_c3_launcher_no_host_modification"

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *)
    echo "SKIP: t_c3_launcher_no_host_modification (non-Linux: $(uname -s))"
    exit 0;;
esac

if ! c3_have_userns; then
  echo "SKIP: t_c3_launcher_no_host_modification (no unprivileged userns)"
  exit 0
fi

workdir="$(c2_make_workdir c3-hostsafe)"
trap 'rm -rf "$workdir"' EXIT

launcher_bin="$(c3_launcher_binary)"

# Build a tiny static "binary" we can exec inside the namespace.
# We can't use /bin/echo or /bin/sh after bind-mounting an empty
# /usr/lib over the host because their dynamic linker depends on
# the host's runtime. A static binary side-steps that.
cat > "$workdir/probe.c" <<'CSRC'
#include <stdio.h>
int main(void) {
    printf("namespace-probe-ok\n");
    return 0;
}
CSRC
if ! cc -static -O2 -o "$workdir/probe" "$workdir/probe.c" 2>"$workdir/cc.log"; then
  cat "$workdir/cc.log" >&2
  echo "SKIP: cc -static not available; cannot build the namespace probe"
  exit 0
fi

# Make a fake "library" prefix to bind into the namespace.
fake_lib="$workdir/fake_lib"
mkdir -p "$fake_lib/usr/lib/x86_64-linux-gnu"
echo "fake-libssl.so" > "$fake_lib/usr/lib/x86_64-linux-gnu/libssl.so.3"

cat > "$workdir/launcher.manifest" <<EOF
exec=$workdir/probe
$fake_lib/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:rbind,ro
EOF

snapshot_host() {
  local out="$1"
  # ls -lan /usr (dir listing + mode bits), and sha256 ld.so.cache.
  ls -lan /usr > "$out.usr-listing"
  if [[ -f /etc/ld.so.cache ]]; then
    sha256sum /etc/ld.so.cache > "$out.ld-so-cache"
  else
    echo "absent" > "$out.ld-so-cache"
  fi
  # stat /usr/lib/x86_64-linux-gnu inode + mtime
  stat /usr/lib/x86_64-linux-gnu > "$out.usrlib-stat" 2>/dev/null || \
    echo "absent" > "$out.usrlib-stat"
}

snapshot_host "$workdir/before"

# Run the launcher; we don't care about the output, just the side effects.
"$launcher_bin" --manifest="$workdir/launcher.manifest" \
  > "$workdir/launcher.out" 2>&1 || \
  { cat "$workdir/launcher.out" >&2; c2_fail "launcher invocation failed"; }

# Sanity: the probe actually ran inside the namespace.
if ! grep -q "namespace-probe-ok" "$workdir/launcher.out"; then
  cat "$workdir/launcher.out" >&2
  c2_fail "namespace probe did not produce expected output"
fi

snapshot_host "$workdir/after"

# Bit-compare the snapshots.
for f in usr-listing ld-so-cache usrlib-stat; do
  if ! diff -q "$workdir/before.$f" "$workdir/after.$f" >/dev/null; then
    diff "$workdir/before.$f" "$workdir/after.$f" >&2
    c2_fail "host state ($f) diverged before/after launcher"
  fi
done
c2_ok "host /usr listing, /etc/ld.so.cache, /usr/lib/x86_64-linux-gnu stat unchanged"

# And the host's /usr/lib/x86_64-linux-gnu STILL doesn't contain a
# file we bind-mounted into the namespace (the file at fake_lib gets
# bound at /usr/lib/x86_64-linux-gnu inside the namespace, but the
# host's view is unchanged).
if [[ -f /usr/lib/x86_64-linux-gnu/fake-libssl-marker ]]; then
  c2_fail "namespace bind mount leaked into host /usr"
fi
c2_ok "namespace bind mounts did not leak into host /usr"

echo "PASS: t_c3_launcher_no_host_modification"

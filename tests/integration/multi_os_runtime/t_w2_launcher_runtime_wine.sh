#!/usr/bin/env bash
# t_w2_launcher_runtime_wine.sh — W2 P3 integration gate.
#
# End-to-end smoke test for the C3 launcher's runtime=wine extension:
#
#   1. Verify wine + wineserver + x86_64-w64-mingw32-gcc are present
#      (install mingw-w64 on a Debian/Ubuntu host if missing).
#   2. Compile a tiny Win32 .exe stub that echoes a fingerprint + argv.
#   3. Initialise a fresh WINEPREFIX via the W1 wine-prefix-init.sh
#      (idempotent — reuses an existing prefix if already initialised).
#   4. Place the .exe under drive_c/repro-store/test/bin/.
#   5. Write a launcher manifest with runtime=wine + wine_* keys.
#   6. Invoke the launcher with `-- foo bar baz`; assert stdout
#      contains the W2_HELLO fingerprint and the forwarded argv.
#
# Risk envelope:
#
#   * WINE inside WSL2 sometimes hangs at wineserver init (~5 s). The
#     wine-prefix-init.sh drains wineserver after wineboot, but this
#     test allows up to 60 s for the launcher invocation.
#   * mingw-w64 install is a one-off; the test skips with a clear
#     SKIP message if the cross-compiler is absent and we can't sudo
#     apt-get it (e.g. CI offline mode).
#
# Exit:
#   0 = PASS, 1 = test setup / assertion FAIL, 2 = SKIP (env missing).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LAUNCHER_BIN="${C3_LAUNCHER_BIN:-$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher}"
WINE_INIT_SH="$REPO_ROOT/recipes/reproos-mvp-config/wine-prefix-init.sh"

PREFIX_DIR="${W2_TEST_PREFIX_DIR:-/tmp/w2-test-prefix}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/w2-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

w2_ok()   { echo "OK: $*"; }
w2_fail() { echo "FAIL: $*" >&2; exit 1; }
w2_skip() { echo "SKIP: $*"; exit 2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *) w2_skip "non-Linux host: $(uname -s) (WINE-runtime test is Linux-only)" ;;
esac

if [[ ! -x "$LAUNCHER_BIN" ]]; then
  w2_fail "launcher binary not found / not executable: $LAUNCHER_BIN
hint: build via ./apps/reprobuild-sandbox-launcher/build.sh"
fi

if ! command -v wine >/dev/null 2>&1; then
  w2_skip "wine not on PATH (install via: apt-get install -y wine)"
fi

if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  w2_skip "x86_64-w64-mingw32-gcc not on PATH
hint: apt-get install -y mingw-w64 (Debian/Ubuntu)"
fi

w2_ok "preflight: wine + mingw-w64 present, launcher built"

# ---------------------------------------------------------------------------
# Step 1: compile the .exe stub
# ---------------------------------------------------------------------------

HELLO_SRC="$WORKDIR/hello.c"
HELLO_EXE="$WORKDIR/w2-hello.exe"
cat > "$HELLO_SRC" <<'EOF'
#include <stdio.h>
int main(int argc, char** argv) {
    printf("W2_HELLO from Win32 .exe, got %d argv\n", argc);
    for (int i = 0; i < argc; i++) printf("argv[%d]=%s\n", i, argv[i]);
    return 0;
}
EOF

if ! x86_64-w64-mingw32-gcc -static "$HELLO_SRC" -o "$HELLO_EXE" \
        2>"$WORKDIR/cc.log"; then
  cat "$WORKDIR/cc.log" >&2
  w2_fail "mingw-w64 cross-compile failed"
fi
w2_ok "compiled w2-hello.exe via x86_64-w64-mingw32-gcc"

# ---------------------------------------------------------------------------
# Step 2: ensure the WINEPREFIX exists (initialise if missing)
# ---------------------------------------------------------------------------

if [[ ! -d "$PREFIX_DIR/drive_c" ]]; then
  echo "[t_w2] initialising fresh WINEPREFIX at $PREFIX_DIR"
  # The script refuses non-empty dirs; if a partial dir exists we keep
  # going — the script will error and we'll report.
  if ! bash "$WINE_INIT_SH" --prefix-dir "$PREFIX_DIR" \
          > "$WORKDIR/wine-init.log" 2>&1; then
    cat "$WORKDIR/wine-init.log" >&2
    w2_fail "wine-prefix-init.sh failed"
  fi
  w2_ok "wine-prefix-init.sh succeeded"
else
  w2_ok "reusing existing WINEPREFIX at $PREFIX_DIR"
fi

if [[ ! -d "$PREFIX_DIR/drive_c" ]]; then
  w2_fail "post-init: $PREFIX_DIR/drive_c does not exist"
fi

# ---------------------------------------------------------------------------
# Step 3: place the .exe under drive_c/repro-store/test/bin/
# ---------------------------------------------------------------------------

EXE_DIR="$PREFIX_DIR/drive_c/repro-store/test/bin"
mkdir -p "$EXE_DIR"
cp "$HELLO_EXE" "$EXE_DIR/w2-hello.exe"
w2_ok "planted .exe at drive_c/repro-store/test/bin/w2-hello.exe"

# ---------------------------------------------------------------------------
# Step 4: write the launcher manifest
# ---------------------------------------------------------------------------

MANIFEST="$WORKDIR/launcher.manifest"
cat > "$MANIFEST" <<EOF
# W2 runtime=wine smoke
runtime=wine
wine_prefix=$PREFIX_DIR
wine_exec=C:/repro-store/test/bin/w2-hello.exe
wine_bin=/usr/bin/wine

# Bind the WINEPREFIX into the namespace (identity bind; the launcher
# silently no-ops if a later line overlaps the same target).
$PREFIX_DIR:$PREFIX_DIR:rbind

proc
EOF
w2_ok "wrote launcher manifest"

# Cross-platform sanity: --dry-run accepts it.
if ! "$LAUNCHER_BIN" --manifest="$MANIFEST" --dry-run \
        > "$WORKDIR/dryrun.log" 2>&1; then
  cat "$WORKDIR/dryrun.log" >&2
  w2_fail "launcher --dry-run exited non-zero"
fi
w2_ok "launcher --dry-run parsed the manifest"

# ---------------------------------------------------------------------------
# Step 5: actual run
# ---------------------------------------------------------------------------

# Check userns gate; the launcher needs CLONE_NEWUSER unless running as
# real root. WSL2 default is root, so the launcher skips CLONE_NEWUSER
# and goes straight to CLONE_NEWNS + mount(2).
if [[ "$(id -u)" != "0" ]]; then
  if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
    if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" != "1" ]]; then
      w2_skip "non-root + unprivileged_userns_clone=0 (kernel-gated out)"
    fi
  fi
fi

set +e
RUN_OUT="$("$LAUNCHER_BIN" --manifest="$MANIFEST" -- aa bb cc 2>&1)"
RUN_EXIT="$?"
set -e

if [[ "$RUN_EXIT" -ne 0 ]]; then
  echo "$RUN_OUT" >&2
  w2_fail "launcher exited $RUN_EXIT"
fi

if ! echo "$RUN_OUT" | grep -q "W2_HELLO from Win32 .exe"; then
  echo "$RUN_OUT" >&2
  w2_fail "stdout missing the W2_HELLO fingerprint"
fi
w2_ok "launcher produced the W2_HELLO fingerprint"

# Verify the forwarded argv made it through. WINE substitutes argv[0]
# with the Windows-style executable path; argv[1..] should be aa bb cc.
for tok in "argv\[1\]=aa" "argv\[2\]=bb" "argv\[3\]=cc"; do
  if ! echo "$RUN_OUT" | grep -qE "$tok"; then
    echo "$RUN_OUT" >&2
    w2_fail "stdout missing forwarded argv token: $tok"
  fi
done
w2_ok "forwarded argv (aa bb cc) reached the .exe"

echo "PASS: t_w2_launcher_runtime_wine"

#!/usr/bin/env bash
# t_d2_launcher_runtime_darling.sh — D2 P3 integration gate.
#
# End-to-end smoke test for the C3 launcher's runtime=darling extension:
#
#   1. Verify darling + a candidate Mach-O binary are available.
#   2. Initialise a fresh DPREFIX via the D1 darling-prefix-init.sh
#      (idempotent — reuses an existing prefix if already initialised).
#   3. Place the Mach-O binary under Applications/repro-store/test/bin/.
#   4. Write a launcher manifest with runtime=darling + darling_* keys.
#   5. Verify --dry-run accepts the manifest and rewrites argv to
#      [darling_bin, "shell", darling_exec, ...args] (parser smoke).
#   6. Invoke the launcher for real with `-- --version`; assert stdout
#      contains the candidate's banner (e.g. "jq-1.7.1").
#
# Risk envelope:
#
#   * Darling inside WSL2 cold-starts darlingserver (~5-10 s) on first
#     invocation per kernel session; this test allows up to 60 s for
#     the launcher invocation.
#   * The Mach-O binary placement assumes the host has a jq-macos-amd64
#     download (or another candidate Mach-O binary specified via
#     D2_SMOKE_BIN / D2_SMOKE_EXPECT). The test skips with a clear SKIP
#     message if neither is available.
#
# Environment knobs:
#
#   C3_LAUNCHER_BIN     -- path to the launcher binary (default: built
#                          alongside this repo).
#   D2_TEST_PREFIX_DIR  -- DPREFIX path (default /tmp/d2-test-prefix).
#   D2_SMOKE_BIN        -- absolute host-side path to a Mach-O amd64
#                          binary (default: looks for jq at
#                          /tmp/jq-macos-amd64 — sha256 pinned per
#                          docs/multi-os-macos-runtime.md D1 P3).
#   D2_SMOKE_NAME       -- short name for the binary in the store
#                          subtree (default: jq).
#   D2_SMOKE_EXPECT     -- regex to match in --version stdout
#                          (default: jq-).
#
# Exit:
#   0 = PASS, 1 = test setup / assertion FAIL, 2 = SKIP (env missing).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LAUNCHER_BIN="${C3_LAUNCHER_BIN:-$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher}"
DARLING_INIT_SH="$REPO_ROOT/recipes/reproos-mvp-config/darling-prefix-init.sh"

PREFIX_DIR="${D2_TEST_PREFIX_DIR:-/tmp/d2-test-prefix}"
SMOKE_BIN="${D2_SMOKE_BIN:-/tmp/jq-macos-amd64}"
SMOKE_NAME="${D2_SMOKE_NAME:-jq}"
SMOKE_EXPECT="${D2_SMOKE_EXPECT:-jq-}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/d2-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

d2_ok()   { echo "OK: $*"; }
d2_fail() { echo "FAIL: $*" >&2; exit 1; }
d2_skip() { echo "SKIP: $*"; exit 2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *) d2_skip "non-Linux host: $(uname -s) (Darling-runtime test is Linux-only)" ;;
esac

if [[ ! -x "$LAUNCHER_BIN" ]]; then
  d2_fail "launcher binary not found / not executable: $LAUNCHER_BIN
hint: build via ./apps/reprobuild-sandbox-launcher/build.sh"
fi

if ! command -v darling >/dev/null 2>&1; then
  d2_skip "darling not on PATH (install per docs/multi-os-macos-runtime.md
         Darling provisioning path)"
fi

if [[ ! -f "$SMOKE_BIN" ]]; then
  d2_skip "smoke binary not present: $SMOKE_BIN
hint: download jq-macos-amd64 per D1 P3 record, or set D2_SMOKE_BIN"
fi

DARLING_BIN="$(command -v darling)"
d2_ok "preflight: darling=$DARLING_BIN, smoke=$SMOKE_BIN"

# ---------------------------------------------------------------------------
# Step 1: ensure the DPREFIX exists (initialise if missing)
# ---------------------------------------------------------------------------

if [[ ! -d "$PREFIX_DIR/Applications" ]]; then
  echo "[t_d2] initialising fresh DPREFIX at $PREFIX_DIR"
  # darling-prefix-init.sh refuses non-empty dirs; if a partial dir
  # exists we keep going — the script will error and we'll report.
  if ! bash "$DARLING_INIT_SH" --prefix-dir "$PREFIX_DIR" \
          > "$WORKDIR/darling-init.log" 2>&1; then
    cat "$WORKDIR/darling-init.log" >&2
    d2_fail "darling-prefix-init.sh failed"
  fi
  d2_ok "darling-prefix-init.sh succeeded"
else
  d2_ok "reusing existing DPREFIX at $PREFIX_DIR"
fi

if [[ ! -d "$PREFIX_DIR/Applications" ]]; then
  d2_fail "post-init: $PREFIX_DIR/Applications does not exist"
fi

# ---------------------------------------------------------------------------
# Step 2: place the Mach-O binary under Applications/repro-store/test/bin/
# ---------------------------------------------------------------------------

BIN_DIR="$PREFIX_DIR/Applications/repro-store/test/bin"
mkdir -p "$BIN_DIR"
cp "$SMOKE_BIN" "$BIN_DIR/$SMOKE_NAME"
chmod +x "$BIN_DIR/$SMOKE_NAME"
d2_ok "planted smoke binary at Applications/repro-store/test/bin/$SMOKE_NAME"

# ---------------------------------------------------------------------------
# Step 3: write the launcher manifest
# ---------------------------------------------------------------------------

MANIFEST="$WORKDIR/launcher.manifest"
cat > "$MANIFEST" <<EOF
# D2 runtime=darling smoke
runtime=darling
darling_prefix=$PREFIX_DIR
darling_exec=/Applications/repro-store/test/bin/$SMOKE_NAME
darling_bin=$DARLING_BIN

# Do NOT add an identity rbind on \$PREFIX_DIR: unlike WINEPREFIX, an
# identity bind on darling_prefix breaks Darling's internal overlayfs
# setup (Darling mounts overlay with upperdir/workdir under DPREFIX;
# overlay-mount rejects a directory that is itself a bind-mount under
# MS_PRIVATE propagation). The DPREFIX is already visible at its host
# path inside CLONE_NEWNS via inherited propagation.

proc
EOF
d2_ok "wrote launcher manifest"

# ---------------------------------------------------------------------------
# Step 4: parser smoke — --dry-run + --verbose surfaces the argv rewrite.
# ---------------------------------------------------------------------------

DRY_OUT="$("$LAUNCHER_BIN" --manifest="$MANIFEST" --verbose --dry-run \
                -- --version 2>&1)" || {
  echo "$DRY_OUT" >&2
  d2_fail "launcher --dry-run exited non-zero"
}
d2_ok "launcher --dry-run parsed the manifest"

# Assert: argv rewrite shape (darling_bin, "shell", darling_exec, --version).
# The dry-run --verbose path emits one line per argv element.
if ! echo "$DRY_OUT" | grep -qE "argv\[0\]=$DARLING_BIN\$"; then
  echo "$DRY_OUT" >&2
  d2_fail "dry-run argv[0] != darling_bin"
fi
if ! echo "$DRY_OUT" | grep -qE "argv\[1\]=shell\$"; then
  echo "$DRY_OUT" >&2
  d2_fail "dry-run argv[1] != 'shell'"
fi
if ! echo "$DRY_OUT" | grep -qE "argv\[2\]=/Applications/repro-store/test/bin/$SMOKE_NAME\$"; then
  echo "$DRY_OUT" >&2
  d2_fail "dry-run argv[2] != darling_exec"
fi
if ! echo "$DRY_OUT" | grep -qE "argv\[3\]=--version\$"; then
  echo "$DRY_OUT" >&2
  d2_fail "dry-run argv[3] != forwarded --version"
fi
d2_ok "dry-run argv rewrite shape verified (darling_bin, shell, darling_exec, --version)"

# Assert: DPREFIX env logged.
if ! echo "$DRY_OUT" | grep -qE "darling env: DPREFIX=$PREFIX_DIR\$"; then
  echo "$DRY_OUT" >&2
  d2_fail "dry-run missing DPREFIX env-export log line"
fi
d2_ok "dry-run DPREFIX env-export logged"

# ---------------------------------------------------------------------------
# Step 5: real invocation
# ---------------------------------------------------------------------------

# Check userns gate; the launcher needs CLONE_NEWUSER unless running as
# real root. WSL2 default is root, so the launcher skips CLONE_NEWUSER
# and goes straight to CLONE_NEWNS + mount(2).
if [[ "$(id -u)" != "0" ]]; then
  if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
    if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" != "1" ]]; then
      d2_skip "non-root + unprivileged_userns_clone=0 (kernel-gated out)"
    fi
  fi
fi

RUN_LOG="$WORKDIR/run.log"
# Note: redirect to a file (not $(...)) because darlingserver/launchd
# daemonize and inherit our stdout/stderr; capturing via command
# substitution would never see EOF and hang the test.
set +e
"$LAUNCHER_BIN" --manifest="$MANIFEST" -- --version > "$RUN_LOG" 2>&1 < /dev/null
RUN_EXIT="$?"
set -e

if [[ "$RUN_EXIT" -ne 0 ]]; then
  cat "$RUN_LOG" >&2
  d2_fail "launcher exited $RUN_EXIT"
fi

if ! grep -qE "$SMOKE_EXPECT" "$RUN_LOG"; then
  cat "$RUN_LOG" >&2
  d2_fail "stdout missing expected banner regex: $SMOKE_EXPECT"
fi
d2_ok "launcher produced expected banner: $(grep -E "$SMOKE_EXPECT" "$RUN_LOG" | head -1)"

echo "PASS: t_d2_launcher_runtime_darling"

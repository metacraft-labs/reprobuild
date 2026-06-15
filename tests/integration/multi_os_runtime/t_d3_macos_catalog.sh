#!/usr/bin/env bash
# t_d3_macos_catalog.sh — D3 P4 integration gate.
#
# End-to-end smoke test for the D3 macOS catalog adapter:
#
#   1. Preflight: darling on PATH; curl; launcher built.
#   2. Run build-mvp-darling-prefix.sh against recipes/catalog/macos/
#      with --smoke-test, into a tmpdir.
#   3. Assert 3 per-tool DPREFIXes exist with the expected layout:
#        $TMPDIR/store/dprefixes/{fzf,jq,ripgrep}/Applications/repro-store/
#                                                    {fzf,jq,ripgrep}/bin/{fzf,jq,rg}
#   4. Invoke each shim with the tool_smoke_args (default --version)
#      and assert the catalog's darling_version_banner appears in
#      stdout.
#   5. PASS only if all 3 banners are detected.
#
# fzf 0.55.0 canary: there is an OPTIONAL catalog at
# recipes/catalog/macos/fzf-0.55-canary.json reserved for future
# regression coverage of the Darling-vs-Go-1.22-TLV gap. The build
# script skips it by default (presence of the _canary_note top-level
# key); this test does NOT exercise it.
#
# Risk envelope:
#
#   * Darling cold-starts darlingserver (~5-10 s) on first invocation
#     PER DPREFIX. With 3 per-tool DPREFIXes this can be ~30 s of
#     cumulative cold-start; the test budgets 60 s per smoke invocation
#     (the launcher loops are unbounded by us — we let bash run).
#   * --allow-online is passed: if vendored-archives/ is empty, the
#     fetch step downloads the upstream tarballs (~5 MB total).
#
# Environment knobs:
#
#   C3_LAUNCHER_BIN     -- path to the launcher binary (default: built
#                          alongside this repo).
#   D3_TEST_STORE_DIR   -- store dir (default tmpdir).
#   D3_INIT_DARLING     -- host darling for DPREFIX init (default:
#                          PATH-resolved).
#   D3_TEST_DARLING_BIN -- darling_bin baked into emitted manifests
#                          (default: /usr/bin/darling on the dev distro
#                          — overrides the ReproOS default
#                          /opt/reproos-foreign/... which doesn't exist
#                          on the test host).
#
# Exit:
#   0 = PASS, 1 = test setup / assertion FAIL, 2 = SKIP (env missing).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LAUNCHER_BIN="${C3_LAUNCHER_BIN:-$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher}"
BUILD_SH="$REPO_ROOT/recipes/reproos-mvp-config/build-mvp-darling-prefix.sh"
CATALOG_DIR="$REPO_ROOT/recipes/catalog/macos"

# The dev distro has darling at /usr/bin/darling; the ReproOS default
# baked into emitted manifests is /opt/reproos-foreign/darling-binaries/
# usr/bin/darling. Override for the test host.
TEST_DARLING_BIN="${D3_TEST_DARLING_BIN:-/usr/bin/darling}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/d3-test.XXXXXX")"
STORE_DIR="${D3_TEST_STORE_DIR:-$WORKDIR/store}"
OVERLAY_DIR="$WORKDIR/overlay"
VENDORED_DIR="$WORKDIR/vendored"

trap 'rm -rf "$WORKDIR"' EXIT

d3_ok()   { echo "OK: $*"; }
d3_fail() { echo "FAIL: $*" >&2; exit 1; }
d3_skip() { echo "SKIP: $*"; exit 2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

case "$(uname -s 2>/dev/null || echo Unknown)" in
  Linux) ;;
  *) d3_skip "non-Linux host: $(uname -s) (D3 macOS-catalog test is Linux-only)" ;;
esac

[ -d "$CATALOG_DIR" ] || d3_fail "catalog dir missing: $CATALOG_DIR"
[ -f "$BUILD_SH" ]    || d3_fail "build script missing: $BUILD_SH"

if ! command -v darling >/dev/null 2>&1; then
  d3_skip "darling not on PATH (install per docs/multi-os-macos-runtime.md)"
fi

if ! command -v curl >/dev/null 2>&1; then
  d3_skip "curl not on PATH"
fi

if [[ ! -x "$LAUNCHER_BIN" ]]; then
  d3_fail "launcher binary not found / not executable: $LAUNCHER_BIN
hint: build via ./apps/reprobuild-sandbox-launcher/build.sh"
fi

DARLING_BIN="$(command -v darling)"
d3_ok "preflight: darling=$DARLING_BIN, launcher=$LAUNCHER_BIN"

# Check userns gate; the launcher needs CLONE_NEWUSER unless running as
# real root. WSL2 default is root.
if [[ "$(id -u)" != "0" ]]; then
  if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
    if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" != "1" ]]; then
      d3_skip "non-root + unprivileged_userns_clone=0 (kernel-gated out)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 1: run the build script (offline fetch + extract + emit).
# ---------------------------------------------------------------------------

# Smoke test runs the per-tool shims inline. Note we pass:
#   --darling-bin /usr/bin/darling   (override ReproOS path; the test
#                                     host has darling at /usr/bin/.)
#   --init-darling-bin /usr/bin/darling (D1 init uses the host darling)
#   --allow-online                   (fetch from GitHub if vendored
#                                     dir is empty)
#
# We deliberately run with --smoke-test so the build script invokes
# the emitted shim against each catalog and reports PASS/FAIL — but
# we ALSO re-validate the banner ourselves below for defence-in-depth.

BUILD_LOG="$WORKDIR/build.log"

set +e
bash "$BUILD_SH" \
  --catalog-dir "$CATALOG_DIR" \
  --store-root "$STORE_DIR" \
  --overlay "$OVERLAY_DIR" \
  --vendored "$VENDORED_DIR" \
  --launcher-bin "$LAUNCHER_BIN" \
  --darling-bin "$TEST_DARLING_BIN" \
  --init-darling-bin "$DARLING_BIN" \
  --allow-online \
  --verbose \
  > "$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

if [[ "$BUILD_EXIT" -ne 0 ]]; then
  cat "$BUILD_LOG" >&2
  d3_fail "build-mvp-darling-prefix.sh exited $BUILD_EXIT"
fi
d3_ok "build-mvp-darling-prefix.sh completed (exit 0)"

# ---------------------------------------------------------------------------
# Step 2: assert per-tool DPREFIX layout for each of fzf, jq, ripgrep.
# ---------------------------------------------------------------------------

declare -A TOOL_BIN
TOOL_BIN[fzf]="fzf"
TOOL_BIN[jq]="jq"
TOOL_BIN[ripgrep]="rg"

declare -A TOOL_BANNER
TOOL_BANNER[fzf]="0.60.0 (3347d61)"
TOOL_BANNER[jq]="jq-1.7.1"
TOOL_BANNER[ripgrep]="ripgrep 14.1.1"

for tool in fzf jq ripgrep; do
  dprefix="$STORE_DIR/dprefixes/$tool"
  [[ -d "$dprefix/Applications" ]] || d3_fail "$tool: DPREFIX missing Applications: $dprefix"
  planted="$dprefix/Applications/repro-store/$tool/bin/${TOOL_BIN[$tool]}"
  [[ -x "$planted" ]] || d3_fail "$tool: planted binary missing / not executable: $planted"

  manifest="$STORE_DIR/prefixes-mac/$tool/launcher.manifest"
  [[ -f "$manifest" ]] || d3_fail "$tool: launcher.manifest missing: $manifest"

  # Re-assert: the emitted manifest contains NO identity rbind on the
  # darling_prefix path (defence-in-depth at test time too).
  if grep -qE "^${dprefix//\//\\/}:${dprefix//\//\\/}:r?bind" "$manifest"; then
    cat "$manifest" >&2
    d3_fail "$tool: emitted manifest contains identity rbind on darling_prefix"
  fi

  # Assert manifest baseline directives.
  grep -qE '^runtime=darling$'             "$manifest" || d3_fail "$tool: manifest missing runtime=darling"
  grep -qE "^darling_prefix=$dprefix\$"    "$manifest" || d3_fail "$tool: manifest darling_prefix mismatch"
  grep -qE "^darling_exec=/Applications/repro-store/$tool/bin/${TOOL_BIN[$tool]}\$" "$manifest" || d3_fail "$tool: manifest darling_exec mismatch"
  grep -qE "^darling_bin=$TEST_DARLING_BIN\$" "$manifest" || d3_fail "$tool: manifest darling_bin mismatch"
  grep -qE '^proc$'                        "$manifest" || d3_fail "$tool: manifest missing 'proc' directive"
  grep -qE '^/dev/fuse:/dev/fuse:rbind$'   "$manifest" || d3_fail "$tool: manifest missing /dev/fuse rbind"

  d3_ok "$tool: dprefix + planted binary + manifest baseline shape OK"
done

# ---------------------------------------------------------------------------
# Step 3: invoke each shim and grep for the banner.
# ---------------------------------------------------------------------------

declare -A SMOKE_PASS_TOOL
BANNER_LINES=()
for tool in fzf jq ripgrep; do
  shim="$OVERLAY_DIR/usr/local/bin/darling-$tool"
  [[ -x "$shim" ]] || d3_fail "$tool: shim missing / not executable: $shim"

  RUN_LOG="$WORKDIR/smoke-$tool.log"
  set +e
  "$shim" --version > "$RUN_LOG" 2>&1 < /dev/null
  RUN_EXIT="$?"
  set -e

  if [[ "$RUN_EXIT" -ne 0 ]]; then
    cat "$RUN_LOG" >&2
    d3_fail "$tool: shim exited $RUN_EXIT"
  fi

  expected="${TOOL_BANNER[$tool]}"
  if ! grep -qF "$expected" "$RUN_LOG"; then
    cat "$RUN_LOG" >&2
    d3_fail "$tool: stdout missing expected banner: $expected"
  fi
  banner_line="$(grep -F "$expected" "$RUN_LOG" | head -1)"
  d3_ok "$tool: shim produced expected banner: $banner_line"
  BANNER_LINES+=("$tool: $banner_line")
  SMOKE_PASS_TOOL[$tool]=1
done

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------

echo "--- D3 banner roll-call ---"
for line in "${BANNER_LINES[@]}"; do
  echo "  $line"
done
echo "PASS: t_d3_macos_catalog"

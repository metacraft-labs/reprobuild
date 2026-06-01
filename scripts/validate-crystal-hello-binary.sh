#!/usr/bin/env bash
# End-to-end M9 verification (Linux peer of validate-standard-provider-
# crystal-shards-hello-binary.ps1): build the crystal-shards/hello-binary
# example via the Tier 2b dispatch path and run the produced binary.
#
# Mechanics (mirrors the .ps1 peer):
#
#   1. Resolve repo + fixture paths from $0.
#   2. Probe for both ``crystal`` AND ``shards``. SKIP exit 0 if
#      either is missing. The canonical Linux install is via the
#      upstream tarball (https://github.com/crystal-lang/crystal/releases),
#      the distro package manager (apt/yum/pacman), or Nix.
#      ``shards`` is bundled with the Crystal distribution.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Invoke repro build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Run the produced ``hello`` and assert stdout contains
#      ``hello from crystal-shards-hello-binary``.
#
# Per reprobuild-specs/Realize-Closure-And-Catalog-Expansion.milestones.org §M9.
set -euo pipefail

script_path="$0"
if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
  script_path="$(readlink -f "$0")"
elif command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$0")"
fi
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
metacraft_root="$(cd "$repo_root/.." && pwd)"

repro_bin="$repo_root/build/bin/repro"
provider_bin="$repo_root/build/bin/repro-standard-provider"
fixture="$metacraft_root/reprobuild-examples/crystal-shards/hello-binary"
scratch_inside_fixture="$fixture/.repro"
expected_greeting='hello from crystal-shards-hello-binary'

# --- preflight ---
if [ ! -f "$repro_bin" ]; then
  echo "FAIL: missing $repro_bin -- run scripts/build_apps.sh first"
  exit 1
fi
if [ ! -f "$provider_bin" ]; then
  echo "FAIL: missing $provider_bin -- run scripts/build_apps.sh first"
  exit 1
fi
if [ ! -f "$fixture/reprobuild.nim" ]; then
  echo "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
fi
if [ ! -f "$fixture/shard.yml" ]; then
  echo "FAIL: fixture missing shard.yml at $fixture"
  exit 1
fi
if [ ! -f "$fixture/shard.lock" ]; then
  echo "FAIL: fixture missing shard.lock at $fixture"
  exit 1
fi
if [ ! -f "$fixture/src/hello.cr" ]; then
  echo "FAIL: fixture missing src/hello.cr at $fixture"
  exit 1
fi

# --- toolchain probe ---
crystal_cmd="$(command -v crystal || true)"
if [ -z "$crystal_cmd" ]; then
  echo "SKIP: 'crystal' not on PATH (M9 crystal convention needs Crystal; install via the upstream tarball from https://github.com/crystal-lang/crystal/releases, your distro package manager, or Nix -- the M9 catalog half is awaiting a Linux harvester pass)"
  exit 0
fi
shards_cmd="$(command -v shards || true)"
if [ -z "$shards_cmd" ]; then
  echo "SKIP: 'shards' not on PATH (shards is bundled with the Crystal distribution; reinstall Crystal to populate shards alongside crystal)"
  exit 0
fi

echo "==> using crystal=$crystal_cmd"
echo "==> using shards=$shards_cmd"

# --- step 1: clean prior scratch dir ---
if [ -d "$scratch_inside_fixture" ]; then
  echo "wiping prior scratch dir $scratch_inside_fixture"
  rm -rf "$scratch_inside_fixture"
fi

# --- step 2: invoke `repro build` ---
repro_target="$fixture#default"
stdout_capture="$repo_root/build/validate-crystal-hello-binary.stdout.txt"
stderr_capture="$repo_root/build/validate-crystal-hello-binary.stderr.txt"
mkdir -p "$(dirname "$stdout_capture")"

echo "==> launching repro build $repro_target"
build_exit=0
( cd "$repo_root" && \
    "$repro_bin" build "$repro_target" \
      --tool-provisioning=path --log=actions \
      >"$stdout_capture" 2>"$stderr_capture" ) \
  || build_exit=$?

echo "--- repro exit code: $build_exit"
if [ -f "$stdout_capture" ]; then
  echo "--- repro stdout (last 20 lines):"
  tail -n 20 "$stdout_capture"
fi
if [ -s "$stderr_capture" ]; then
  echo "--- repro stderr (last 20 lines):"
  tail -n 20 "$stderr_capture"
fi

if [ "$build_exit" -ne 0 ]; then
  echo "FAIL: repro build exited with code $build_exit"
  exit 1
fi

# --- step 3: locate produced binary ---
# Crystal/shards emit at ``.repro/build/hello/hello`` on POSIX (the
# Windows peer looks for ``hello.exe``).
produced="$fixture/.repro/build/hello/hello"
if [ ! -f "$produced" ]; then
  echo "FAIL: expected binary not found at $produced"
  scratch_dir="$fixture/.repro/build"
  if [ -d "$scratch_dir" ]; then
    echo "--- contents of $scratch_dir:"
    find "$scratch_dir" -maxdepth 4 | sed 's/^/  /'
  fi
  exit 1
fi
echo "produced binary: $produced"
echo "  size: $(stat -c '%s' "$produced" 2>/dev/null || stat -f '%z' "$produced") bytes"

# --- step 4: run binary and assert greeting ---
echo "==> running $produced"
run_exit=0
output="$("$produced" 2>&1)" || run_exit=$?
echo "--- exe exit code: $run_exit"
echo "--- exe stdout:"
echo "$output"

if [ "$run_exit" -ne 0 ]; then
  echo "FAIL: produced binary exited with code $run_exit"
  exit 1
fi
if ! echo "$output" | grep -qF "$expected_greeting"; then
  echo "FAIL: produced binary stdout does not contain expected greeting '$expected_greeting'"
  exit 1
fi

echo ""
echo "PASS: crystal-shards/hello-binary built via standard provider; greeting matched"
exit 0

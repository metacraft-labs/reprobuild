#!/usr/bin/env bash
# End-to-end M9 verification (Linux peer of validate-standard-provider-
# haskell-cabal-hello-binary.ps1): build the haskell-cabal/hello-binary
# example via the Tier 2b dispatch path and run the produced binary.
#
# Mechanics (mirrors the .ps1 peer):
#
#   1. Resolve repo + fixture paths from $0.
#   2. Probe for ghc AND cabal. SKIP exit 0 if either is missing.
#      Operators typically provision Haskell on Linux via ghcup
#      (https://www.haskell.org/ghcup/) or the distro package manager
#      (apt/yum/pacman). The M9 harness's home-apply step lifts the
#      cakBuiltin-realized prefix's bin dir onto PATH when LIVE +
#      catalog Linux URLs are available; the SKIP path covers the
#      vanilla "nothing's been provisioned" case.
#   3. Warm step: ``cabal v2-update`` (non-fatal — mirrors M40 Maven /
#      M41 Gradle warm pattern; the M55 fixture only depends on ``base``
#      so the warm step is a no-op for this fixture but kept as
#      documentation of the canonical warm sequence).
#   4. Wipe any prior .repro/ scratch AND ``dist-newstyle/`` dir under
#      the fixture so the build runs cold.
#   5. Invoke repro build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Locate the produced ``hello`` binary under ``dist-newstyle/`` and
#      run it; assert stdout contains
#      ``hello from haskell-cabal-hello-binary``.
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
fixture="$metacraft_root/reprobuild-examples/haskell-cabal/hello-binary"
scratch_inside_fixture="$fixture/.repro"
dist_inside_fixture="$fixture/dist-newstyle"
expected_greeting='hello from haskell-cabal-hello-binary'

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
if [ ! -f "$fixture/hello.cabal" ]; then
  echo "FAIL: fixture missing hello.cabal at $fixture"
  exit 1
fi
if [ ! -f "$fixture/app/Main.hs" ]; then
  echo "FAIL: fixture missing app/Main.hs at $fixture"
  exit 1
fi

# --- toolchain probe ---
ghc_cmd="$(command -v ghc || true)"
cabal_cmd="$(command -v cabal || true)"
if [ -z "$ghc_cmd" ]; then
  echo "SKIP: 'ghc' not on PATH (M9 haskell-cabal convention needs the Haskell toolchain; install GHC + cabal via ghcup from https://www.haskell.org/ghcup/ or your distro package manager -- the M9 catalog half is awaiting a Linux harvester pass)"
  exit 0
fi
if [ -z "$cabal_cmd" ]; then
  echo "SKIP: 'cabal' not on PATH (M9 haskell-cabal convention needs cabal-install; install via ghcup from https://www.haskell.org/ghcup/ or your distro package manager)"
  exit 0
fi
echo "==> using ghc=$ghc_cmd"
echo "==> using cabal=$cabal_cmd"

# --- warm step: cabal v2-update (non-fatal) ---
echo "==> warm: cabal v2-update (non-fatal)"
warm_exit=0
"$cabal_cmd" v2-update >/dev/null 2>&1 || warm_exit=$?
echo "  cabal v2-update exit: $warm_exit"
if [ "$warm_exit" -ne 0 ]; then
  echo "  cabal v2-update failed (non-fatal -- fixture depends only on base)"
fi

# --- step 1: clean prior scratch + dist-newstyle dir ---
if [ -d "$scratch_inside_fixture" ]; then
  echo "wiping prior scratch dir $scratch_inside_fixture"
  rm -rf "$scratch_inside_fixture"
fi
if [ -d "$dist_inside_fixture" ]; then
  echo "wiping prior Cabal dist-newstyle dir $dist_inside_fixture"
  rm -rf "$dist_inside_fixture"
fi

# --- step 2: invoke `repro build` ---
repro_target="$fixture#default"
stdout_capture="$repo_root/build/validate-haskell-cabal-hello-binary.stdout.txt"
stderr_capture="$repo_root/build/validate-haskell-cabal-hello-binary.stderr.txt"
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
# cabal v2-build writes the executable to a complex platform-tuple- +
# GHC-version-keyed path under ``dist-newstyle/``. Walk for ``hello``.
# Prefer the deepest path (final emitted binary, not intermediate
# object files).
produced=""
if [ -d "$dist_inside_fixture" ]; then
  produced="$(find "$dist_inside_fixture" -type f -name 'hello' -executable \
                -printf '%d %p\n' 2>/dev/null \
              | sort -n -r | head -n 1 | cut -d' ' -f2-)"
fi
if [ -z "$produced" ] || [ ! -f "$produced" ]; then
  echo "FAIL: expected binary not found under $dist_inside_fixture"
  if [ -d "$dist_inside_fixture" ]; then
    echo "--- contents of $dist_inside_fixture:"
    find "$dist_inside_fixture" -maxdepth 6 | sed 's/^/  /'
  else
    echo "  (no Cabal dist-newstyle dir)"
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
echo "PASS: haskell-cabal/hello-binary built via standard provider; greeting matched"
exit 0

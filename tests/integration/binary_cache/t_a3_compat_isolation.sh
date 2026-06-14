#!/usr/bin/env bash
# t_a3_compat_isolation.sh — A3 P7 host-toolchain compat-isolation gate.
#
# Validates the Binary-Caches.md § "Cache Entry Identity" hard
# invariant: two entries that are NOT interchangeable at runtime
# MUST NOT share one cache key. We exercise the specific case
# from the R8 byte-stability caveat:
#
#   hex0 built under host gcc 11.4  -> cache-entry-key K_A
#   hex0 built under host gcc 13.x  -> cache-entry-key K_B
#   K_A != K_B  (the compat isolation invariant)
#
# We achieve this by setting REPRO_HOST_GCC_VERSION / REPRO_HOST_LDSO_ABI
# env vars that the build-script cache-prelude feeds into the
# toolchain-identity component. The CLI's ``derive-key`` subcommand
# is the canonical key-derivation path; we invoke it twice with the
# two host fingerprints and compare the derived keys.
#
# This is a pure key-derivation test — no server / no publishing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLI_BIN" ]]; then
  CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -f "$CLI_BIN" ]]; then
  a2_fail "CLI binary missing"
fi

derive() {
  local host_gcc="$1" host_ldso="$2"
  "$CLI_BIN" derive-key \
    --package-name=hex0 \
    --package-version=stage0-posix-Release_1.9.1 \
    --platform-cpu=x86_64 \
    --platform-os=linux \
    --platform-abi=gnu \
    --platform-libc= \
    --toolchain-name=stage0-posix \
    --toolchain-version=Release_1.9.1 \
    --toolchain-host-ldso="$host_ldso" \
    --toolchain-extra="host_gcc=$host_gcc" \
    --provider-revision=fixed-test-rev
}

K_A="$(derive "11.4.0" "glibc-2.35")"
K_B="$(derive "13.2.0" "glibc-2.39")"
K_C="$(derive "13.2.0" "glibc-2.35")"
K_D="$(derive "11.4.0" "glibc-2.35")"

if [[ "$K_A" == "$K_B" ]]; then
  a2_fail "host-gcc-11 vs host-gcc-13 produced same cache key:
    K_A=$K_A
    K_B=$K_B"
fi
if [[ "$K_A" == "$K_C" ]]; then
  a2_fail "host-gcc-11 / glibc-2.35 vs host-gcc-13 / glibc-2.35 collided"
fi
if [[ "$K_B" == "$K_C" ]]; then
  a2_fail "differing host_ldso did not flip the key"
fi
if [[ "$K_A" != "$K_D" ]]; then
  a2_fail "identical inputs produced non-identical keys (determinism fail):
    K_A=$K_A
    K_D=$K_D"
fi

echo "K_A (host gcc 11.4 / glibc 2.35) = $K_A"
echo "K_B (host gcc 13.x / glibc 2.39) = $K_B"
echo "K_C (host gcc 13.x / glibc 2.35) = $K_C"
echo "K_D (re-derive of A)             = $K_D"

a2_ok "t_a3_compat_isolation — host-toolchain identity flips cache key per spec invariant"

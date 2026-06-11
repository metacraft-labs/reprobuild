#!/bin/sh
# m4_self_bootstrap.sh — verify reprobuild self-bootstrap + hello-world
# recipe builds on Alpine (musl libc baseline).
#
# Linux-Distro-Recipe-Validation M4 acceptance test. Mirrors M3's
# m3_self_bootstrap.sh exactly in shape — single-distro scope, no
# dispatch needed.
#
# M4 is the campaign's only musl-libc baseline. The Nim runtime,
# the reprobuild build graph, and every recipe's libc-dependent
# behaviour run against musl 1.2.4 (Alpine 3.19) rather than glibc.
# This is also the most important milestone for the ReproOS-MVP
# campaign (Phase 1: hex0 -> tcc -> gcc -> musl bootstrap chain) —
# any musl-vs-glibc divergence surfaced here is a downstream
# blocker for ReproOS.
#
# Steps (identical shape to M1/M2/M3):
#
#   1. Detect distro via /etc/os-release; require ID=alpine; invoke
#      tools/multi-distro-harness/bootstrap-alpine.sh.
#   2. Build examples/hello-world-c/ through the bootstrapped repro.
#   3. Assert the resulting binary prints "hello from reprobuild M1".
#      (The recipe string is unchanged from M1 — it's the same recipe.
#      M4 reuses M1's example without modification, same as M2 + M3 did.)
#   4. Assert intra-distro content-addressability: wipe the per-project
#      `.repro/build/` tree AND the global `~/.cache/repro/action-cache/`,
#      rebuild, and verify the binary's sha256 matches the first build.
#
# Cross-distro bit-identity (Alpine sha == Arch/Debian/Ubuntu/Fedora
# sha) is NOT asserted here — Alpine 3.19 ships gcc 13.x + musl 1.2.4,
# which differs from every M1/M2/M3 baseline at the libc layer. The
# campaign's M5 (peer-cache pull) is where cross-distro bit-identity
# gets tested via the binary cache; the musl-vs-glibc gap is exactly
# the kind of divergence that proves the peer-cache content-address
# scheme is doing its job (musl and glibc DON'T share output sha256
# but DO share input recipe + action-cache keys).
#
# Per the Linux-Distro-Recipe-Validation campaign protocol, this test
# is invoked via:
#
#   bash scripts/run_multi_distro_tests.sh m4_self_bootstrap alpine
#
# and refuses to run if /etc/os-release's ID is not alpine.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside repro-alpine.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "m4_self_bootstrap: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-unknown}" in
  alpine)
    BOOTSTRAP_NAME=alpine
    ;;
  *)
    echo "m4_self_bootstrap: FAIL - expected ID=alpine, got ID=${ID:-unknown}" >&2
    echo "  (this test is M4-scope; M1 covers arch, M2 covers debian/ubuntu, M3 covers fedora)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
BOOTSTRAP="${REPO_ROOT}/tools/multi-distro-harness/bootstrap-${BOOTSTRAP_NAME}.sh"
RECIPE_DIR="${REPO_ROOT}/examples/hello-world-c"
WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-${BOOTSTRAP_NAME}}"
REPRO_BIN="${WORK_ROOT}/bin/repro"
EXPECTED_OUT='hello from reprobuild M1'

if [ ! -f "${BOOTSTRAP}" ]; then
  echo "m4_self_bootstrap: FAIL - bootstrap script missing at ${BOOTSTRAP}" >&2
  exit 1
fi

if [ ! -d "${RECIPE_DIR}" ]; then
  echo "m4_self_bootstrap: FAIL - hello-world-c recipe missing at ${RECIPE_DIR}" >&2
  exit 1
fi

echo "m4_self_bootstrap: running on ID=${ID} (${BOOTSTRAP_NAME})"

# ----------------------------------------------------------------------
# Step 1: run the bootstrap.
# ----------------------------------------------------------------------

echo "m4_self_bootstrap: step 1 — bootstrap"
if ! sh "${BOOTSTRAP}"; then
  echo "m4_self_bootstrap: FAIL - bootstrap-${BOOTSTRAP_NAME}.sh exited non-zero" >&2
  exit 1
fi

if [ ! -x "${REPRO_BIN}" ]; then
  echo "m4_self_bootstrap: FAIL - repro binary missing at ${REPRO_BIN}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: copy the recipe to /tmp (the Windows-mounted /mnt/d tree is
# slow + read-shared with the Windows host) and build it.
# ----------------------------------------------------------------------

echo "m4_self_bootstrap: step 2 — build hello-world-c recipe"
RECIPE_WORK="${WORK_ROOT}/m4-recipe/hello-world-c"
rm -rf "${RECIPE_WORK}"
mkdir -p "${WORK_ROOT}/m4-recipe"
cp -r "${RECIPE_DIR}" "${RECIPE_WORK}"

# Re-export the env the bootstrap exported so the subsequent `repro
# build` invocation sees them. (The bootstrap's exports live in its own
# shell scope; we're a child process so they didn't propagate.)
#
# Like M2 (Debian/Ubuntu) + M3 (Fedora) and unlike M1 (Arch), Alpine
# needs an extra PATH directory ahead of /usr/bin: the bootstrap built
# Nim 2.2.10 from source under ${WORK_ROOT}/nim-2.2.10/bin/, because
# Alpine's apk nim 2.2.0 has a codegen bug and choosenim is glibc-only.
# `repro build` forks `nim` to compile the recipe's repro.nim; without
# the source-built bin on PATH the fork falls back to /usr/bin/nim
# (apk's 1.6.16 or 2.2.0, both unusable) and the build fails.
#
# Alpine's flat /usr/lib + /usr/include layout means BLAKE3_PREFIX=/usr
# + XXHASH_PREFIX=/usr resolve directly via `config.nims`
# `firstExistingPrefix` (no /usr/local symlink hop, unlike M2 + M3).
NIM_VERSION="${REPRO_BOOTSTRAP_NIM_VERSION:-2.2.10}"
export PATH="${WORK_ROOT}/bin:${WORK_ROOT}/nim-${NIM_VERSION}/bin:/usr/local/bin:/usr/bin:${PATH:-}"
export REPROBUILD_REPO_ROOT="${REPO_ROOT}"
export BLAKE3_PREFIX=/usr
export XXHASH_PREFIX=/usr

cd "${RECIPE_WORK}"
if ! "${REPRO_BIN}" build . --tool-provisioning=path --no-runquota; then
  echo "m4_self_bootstrap: FAIL - first build exited non-zero" >&2
  exit 1
fi

BIN_PATH="${RECIPE_WORK}/.repro/build/hello-world-c/hello-world-c"
if [ ! -x "${BIN_PATH}" ]; then
  echo "m4_self_bootstrap: FAIL - expected binary missing at ${BIN_PATH}" >&2
  echo "  build tree:" >&2
  find "${RECIPE_WORK}/.repro" -maxdepth 4 -type f >&2 || true
  exit 1
fi

# ----------------------------------------------------------------------
# Step 3: run the binary and verify output.
# ----------------------------------------------------------------------

echo "m4_self_bootstrap: step 3 — run binary"
got_out="$("${BIN_PATH}" 2>&1 || true)"
if [ "${got_out}" != "${EXPECTED_OUT}" ]; then
  echo "m4_self_bootstrap: FAIL - binary output mismatch" >&2
  echo "  expected: ${EXPECTED_OUT}" >&2
  echo "  got:      ${got_out}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 4: intra-distro content-addressability check.
# ----------------------------------------------------------------------
#
# Capture the first build's sha256, wipe BOTH the per-project
# `.repro/build/` tree AND the global `~/.cache/repro/action-cache/`,
# rebuild, and assert the new binary has the same sha256.
#
# Cross-distro (Alpine sha == M1-M3 distro sha) is NOT asserted —
# musl-vs-glibc + different gcc versions make that an M5 (peer-cache
# pull) concern. The musl-vs-glibc divergence is the most important
# input for the ReproOS-MVP cross-distro story.

echo "m4_self_bootstrap: step 4 — content-addressability"
sha1="$(sha256sum "${BIN_PATH}" | cut -d' ' -f1)"
echo "  build #1 sha256: ${sha1}"

rm -rf "${RECIPE_WORK}/.repro"
rm -rf "${HOME}/.cache/repro"

if ! "${REPRO_BIN}" build . --tool-provisioning=path --no-runquota; then
  echo "m4_self_bootstrap: FAIL - second build exited non-zero" >&2
  exit 1
fi
if [ ! -x "${BIN_PATH}" ]; then
  echo "m4_self_bootstrap: FAIL - second build produced no binary" >&2
  exit 1
fi
sha2="$(sha256sum "${BIN_PATH}" | cut -d' ' -f1)"
echo "  build #2 sha256: ${sha2}"

if [ "${sha1}" != "${sha2}" ]; then
  echo "m4_self_bootstrap: FAIL - content-addressability broken" >&2
  echo "  build #1: ${sha1}" >&2
  echo "  build #2: ${sha2}" >&2
  exit 1
fi

# Re-run the binary as a final smoke check.
got_out2="$("${BIN_PATH}" 2>&1 || true)"
if [ "${got_out2}" != "${EXPECTED_OUT}" ]; then
  echo "m4_self_bootstrap: FAIL - rebuilt binary output mismatch" >&2
  echo "  expected: ${EXPECTED_OUT}" >&2
  echo "  got:      ${got_out2}" >&2
  exit 1
fi

echo "m4_self_bootstrap: OK"
echo "  distro:     ${BOOTSTRAP_NAME} (${PRETTY_NAME:-unknown})"
echo "  binary:     ${BIN_PATH}"
echo "  sha256:     ${sha1}"
echo "  output:     ${EXPECTED_OUT}"
exit 0

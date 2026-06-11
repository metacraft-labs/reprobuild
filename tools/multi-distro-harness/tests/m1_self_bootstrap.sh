#!/bin/sh
# m1_self_bootstrap.sh — verify reprobuild self-bootstrap + hello-world
# recipe builds on Arch.
#
# Linux-Distro-Recipe-Validation M1 acceptance test:
#
#   1. Invoke tools/multi-distro-harness/bootstrap-arch.sh inside the
#      repro-arch WSL instance. This installs pacman prereqs + builds
#      clingo + BLAKE3 from upstream + builds `repro` and
#      `repro-standard-provider` from /mnt/d/metacraft/reprobuild.
#   2. Build examples/hello-world-c/ through the bootstrapped repro.
#   3. Assert the resulting binary prints "hello from reprobuild M1".
#   4. Assert the build is content-addressed: wipe the per-project
#      `.repro/build/` tree AND the global `~/.cache/repro/action-cache/`,
#      rebuild, and verify the binary's sha256 matches the first build.
#
# Runtime: ~4-7 minutes cold (clingo + BLAKE3 + Nim builds dominate);
# ~30-60 seconds warm (every bootstrap step short-circuits on already-
# built artefacts so only the hello-world rebuild runs).
#
# The test is Arch-specific by construction (`pacman -S` + the upstream
# clingo build path). M2/M3/M4 will mirror this shape for Debian /
# Fedora / Alpine, replacing the package manager calls and the
# upstream-clingo-build (clingo IS in debian-multimedia / fedora /
# alpine packaging).
#
# Per the Linux-Distro-Recipe-Validation campaign protocol, this test
# does NOT skip on non-Arch distros — it expects to be invoked only via
# `bash scripts/run_multi_distro_tests.sh m1_self_bootstrap arch` and
# refuses to run if `/etc/os-release` doesn't say `ID=arch`.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside repro-arch.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "m1_self_bootstrap: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-unknown}" != "arch" ]; then
  echo "m1_self_bootstrap: FAIL - expected ID=arch, got ID=${ID:-unknown}" >&2
  echo "  (this test is M1-scope; M2/M3/M4 cover debian/fedora/alpine)" >&2
  exit 1
fi

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
BOOTSTRAP="${REPO_ROOT}/tools/multi-distro-harness/bootstrap-arch.sh"
RECIPE_DIR="${REPO_ROOT}/examples/hello-world-c"
WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-arch}"
REPRO_BIN="${WORK_ROOT}/bin/repro"
EXPECTED_OUT='hello from reprobuild M1'

if [ ! -f "${BOOTSTRAP}" ]; then
  echo "m1_self_bootstrap: FAIL - bootstrap script missing at ${BOOTSTRAP}" >&2
  exit 1
fi

if [ ! -d "${RECIPE_DIR}" ]; then
  echo "m1_self_bootstrap: FAIL - hello-world-c recipe missing at ${RECIPE_DIR}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: run the bootstrap.
# ----------------------------------------------------------------------

echo "m1_self_bootstrap: step 1 — bootstrap"
if ! sh "${BOOTSTRAP}"; then
  echo "m1_self_bootstrap: FAIL - bootstrap-arch.sh exited non-zero" >&2
  exit 1
fi

if [ ! -x "${REPRO_BIN}" ]; then
  echo "m1_self_bootstrap: FAIL - repro binary missing at ${REPRO_BIN}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: copy the recipe to /tmp (the Windows-mounted /mnt/d tree is
# slow + read-shared with the Windows host) and build it.
# ----------------------------------------------------------------------

echo "m1_self_bootstrap: step 2 — build hello-world-c recipe"
RECIPE_WORK="${WORK_ROOT}/m1-recipe/hello-world-c"
rm -rf "${RECIPE_WORK}"
mkdir -p "${WORK_ROOT}/m1-recipe"
cp -r "${RECIPE_DIR}" "${RECIPE_WORK}"

# The bootstrap exported these for its own shell; we re-export here so
# the subsequent `repro build` invocation sees them.
export PATH="${WORK_ROOT}/bin:/usr/local/bin:/usr/bin:${PATH:-}"
export REPROBUILD_REPO_ROOT="${REPO_ROOT}"
export BLAKE3_PREFIX=/usr/local
export XXHASH_PREFIX=/usr

cd "${RECIPE_WORK}"
if ! "${REPRO_BIN}" build . --tool-provisioning=path --no-runquota; then
  echo "m1_self_bootstrap: FAIL - first build exited non-zero" >&2
  exit 1
fi

BIN_PATH="${RECIPE_WORK}/.repro/build/hello-world-c/hello-world-c"
if [ ! -x "${BIN_PATH}" ]; then
  echo "m1_self_bootstrap: FAIL - expected binary missing at ${BIN_PATH}" >&2
  echo "  build tree:" >&2
  find "${RECIPE_WORK}/.repro" -maxdepth 4 -type f >&2 || true
  exit 1
fi

# ----------------------------------------------------------------------
# Step 3: run the binary and verify output.
# ----------------------------------------------------------------------

echo "m1_self_bootstrap: step 3 — run binary"
got_out="$("${BIN_PATH}" 2>&1 || true)"
if [ "${got_out}" != "${EXPECTED_OUT}" ]; then
  echo "m1_self_bootstrap: FAIL - binary output mismatch" >&2
  echo "  expected: ${EXPECTED_OUT}" >&2
  echo "  got:      ${got_out}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 4: content-addressability check.
# ----------------------------------------------------------------------
#
# Capture the first build's sha256, wipe BOTH the per-project
# `.repro/build/` tree AND the global `~/.cache/repro/action-cache/`
# (the latter is where `repro` stores the content-addressed action
# outputs — wiping it forces a full cold rebuild from source), rebuild,
# and assert the new binary has the same sha256.

echo "m1_self_bootstrap: step 4 — content-addressability"
sha1="$(sha256sum "${BIN_PATH}" | cut -d' ' -f1)"
echo "  build #1 sha256: ${sha1}"

rm -rf "${RECIPE_WORK}/.repro"
rm -rf "${HOME}/.cache/repro"

if ! "${REPRO_BIN}" build . --tool-provisioning=path --no-runquota; then
  echo "m1_self_bootstrap: FAIL - second build exited non-zero" >&2
  exit 1
fi
if [ ! -x "${BIN_PATH}" ]; then
  echo "m1_self_bootstrap: FAIL - second build produced no binary" >&2
  exit 1
fi
sha2="$(sha256sum "${BIN_PATH}" | cut -d' ' -f1)"
echo "  build #2 sha256: ${sha2}"

if [ "${sha1}" != "${sha2}" ]; then
  echo "m1_self_bootstrap: FAIL - content-addressability broken" >&2
  echo "  build #1: ${sha1}" >&2
  echo "  build #2: ${sha2}" >&2
  exit 1
fi

# Re-run the binary as a final smoke check.
got_out2="$("${BIN_PATH}" 2>&1 || true)"
if [ "${got_out2}" != "${EXPECTED_OUT}" ]; then
  echo "m1_self_bootstrap: FAIL - rebuilt binary output mismatch" >&2
  echo "  expected: ${EXPECTED_OUT}" >&2
  echo "  got:      ${got_out2}" >&2
  exit 1
fi

echo "m1_self_bootstrap: OK"
echo "  binary:     ${BIN_PATH}"
echo "  sha256:     ${sha1}"
echo "  output:     ${EXPECTED_OUT}"
exit 0

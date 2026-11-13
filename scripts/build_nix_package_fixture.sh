#!/usr/bin/env bash
# The Nix package of THIS checkout -- `nix build <checkout>#default` -- built
# once per tree as a build-graph edge, for the gates that run the INSTALLED
# package rather than build/bin:
#
#   tests/e2e/m83/t_e2e_nix_package_compiles_profile.nim            (GM1)
#   tests/e2e/m83/t_e2e_nix_package_compiles_profile_clean_env.nim  (GM1l)
#
# WHO RUNS THIS
#
#   The edge `reprobuild.test_fixtures.nix_package` (`repro.nim`,
#   `test-package-fixtures` collection). scripts/run_tests.sh builds that
#   collection before any test runs; `repro build test` and a focused build of
#   either gate reach it through the gates' execute-edge dependency
#   (`testFixtureArtifacts`).
#
# WHY IT IS AN EDGE AND NOT A CALL IN EACH CASE
#
#   Each of the gates' cases used to run this `nix build` itself. The build
#   happens in the nix daemon's builder, outside the case's process group, and
#   nix serialises concurrent builds of one derivation: with the cases running
#   in parallel, every case but one waited silently on the daemon's lock and
#   the test runner killed it on its IDLE TIMEOUT after 1800 s (full-suite
#   runs 33 and 34: ~8 s of group CPU over ~2100 s elapsed). Built here once,
#   before the test phase, the cases only look the result up.
#
# WHAT IT DOES
#
#   1. `nix build --print-build-logs` of `<checkout>#default` -- the same
#      invocation the gates fall back to when the fixture is absent, so both
#      routes produce the same store path. The flake is a git tree, so nix
#      builds the working tree's tracked (and staged) files.
#   2. Keeps the result alive with an out-link (an indirect GC root) at
#      build/test-fixtures/nix-package/result, so a garbage collection between
#      this edge and the test phase does not send every case back to a cold
#      build.
#   3. Writes the store path to build/test-fixtures/nix-package/out-path (the
#      edge's declared output), through a temporary file and a rename.
#
#   The gates do NOT take the recorded path on trust: each case evaluates
#   `<checkout>#default.outPath` itself and uses the fixture only when the two
#   agree and the path is in the store, so a fixture left over from an earlier
#   tree is never mistaken for this one's package.
#
# Every failure removes the previously recorded path and GC root, so a failed
# build cannot leave an older package in place.
#
# Usage: scripts/build_nix_package_fixture.sh
# Exit status: 0 when the store path is recorded; non-zero, naming the cause,
# otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EDGE_ID="reprobuild.test_fixtures.nix_package"
readonly OUT_REL="build/test-fixtures/nix-package"
readonly OUT_DIR="${REPO_ROOT}/${OUT_REL}"
readonly OUT_PATH_FILE="${OUT_DIR}/out-path"
readonly GC_ROOT="${OUT_DIR}/result"

die() {
  rm -f "${OUT_PATH_FILE}" "${GC_ROOT}"
  echo "build_nix_package_fixture: error: $*" >&2
  echo "build_nix_package_fixture: (this script is graph edge ${EDGE_ID})" >&2
  exit 1
}

if ! command -v nix >/dev/null 2>&1; then
  die "nix is not on PATH; the package under test is \`nix build ${REPO_ROOT}#default\`."
fi

mkdir -p "${OUT_DIR}"
echo "build_nix_package_fixture: nix build ${REPO_ROOT}#default"

# The build log goes to stderr (`-L`); stdout carries only the out path.
out_paths="$(nix build --print-out-paths --print-build-logs \
  --out-link "${GC_ROOT}" "${REPO_ROOT}#default")" ||
  die "\`nix build ${REPO_ROOT}#default\` failed (build log above)."

store_path=""
while IFS= read -r line; do
  [[ "${line}" == /nix/store/* ]] && store_path="${line}"
done <<<"${out_paths}"
[[ -n "${store_path}" ]] || die "nix build printed no store path: ${out_paths}"
[[ -x "${store_path}/bin/repro" ]] ||
  die "the package at ${store_path} has no bin/repro."

tmp="${OUT_PATH_FILE}.tmp.$$"
printf '%s\n' "${store_path}" >"${tmp}" || die "could not write ${tmp}."
mv -f "${tmp}" "${OUT_PATH_FILE}" || die "could not move ${tmp} into place."

echo "build_nix_package_fixture: recorded ${store_path} in ${OUT_REL}/out-path"

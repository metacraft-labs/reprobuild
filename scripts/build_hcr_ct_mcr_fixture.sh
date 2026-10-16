#!/usr/bin/env bash
# The `ct-mcr` recorder bundle that `e2e_hcr_linux_replay_of_patched_recording`
# records and replays with — built by the RECORDER'S OWN recipe, in the
# RECORDER'S OWN pinned dev environment, then staged into this repository at
# a stable, graph-declared path.
#
# WHO RUNS THIS
#
#   * the build-graph edge `reprobuild.test_fixtures.hcr_ct_mcr_bundle`
#     (`repro.nim`, `test-cross-repo-fixtures` collection), which the gate's
#     EXECUTE edge depends on through `testFixtureArtifacts` — so
#     `repro build test`, a focused
#     `repro build '.#test#t_e2e_hcr_linux_replay_of_patched_recording'` and
#     `scripts/run_tests.sh` (which builds `.#test-cross-repo-fixtures` before
#     any test runs) all produce the bundle before the gate runs;
#   * the Justfile recipe `hcr_ct_mcr_fixture`, a dependency of the gate's own
#     recipe, which is what the HCR lane (`scripts/run_hcr_lane.sh`, CI's
#     `hcr-lanes.yml`) runs.
#
# One script, two entry points, so the graph and the lane cannot build two
# different bundles (cross-repo-builds.md §5, forbidden pattern 4).
#
# WHAT IT DOES, AND WHY EACH STEP IS SHAPED THE WAY IT IS
#
#   1. Locates the recorder checkout: `$CT_CODETRACER_NATIVE_RECORDER_SIBLING`,
#      else the canonical sibling `../codetracer-native-recorder`
#      (metacraft-dev-guidelines policies/cross-repo-builds.md §2.3). A missing
#      checkout is an error, never a skip (§5, pattern 3).
#   2. Refuses a recorder that predates HX-S-2 (codetracer-native-recorder
#      042aee6e). An older `ct-mcr` refuses every trace carrying a
#      `CodePatchEvent`, so building it would turn "the fixture is missing"
#      into a gate failure that looks like an HCR regression.
#   3. Runs the recorder's canonical `just build-ct-mcr` INSIDE THE RECORDER'S
#      OWN FLAKE DEV SHELL (`nix develop <recorder>`), never in reprobuild's
#      shell (§5, pattern 5), with the environment cleared so nothing from the
#      caller's shell (reprobuild's `NIX_CFLAGS_COMPILE`, `LD_LIBRARY_PATH`, a
#      stray `METACRAFT_LICENSE_SIGNING_PUBLIC_KEY_FILE` that would flip the
#      licence cdylib to its release profile, ...) reaches the recorder's
#      build. `--no-update-lock-file` makes an incomplete recorder lock an
#      error instead of a silent re-resolution: every input of the build comes
#      from the recorder's committed `flake.lock`, including the LLVM/LLDB
#      environment its licensing prerequisite needs.
#
#      Not `repro build` in the sibling: the recorder's own graph stops at
#      `codetracer-native-recorder.ct-cli` (its `repro.nim` explains why — the
#      licence cdylib comes from a second sibling), so it does not produce the
#      populated bundle this gate needs (`libct_interpose`, the licence FFI,
#      ...). `just build-ct-mcr` is the recipe that does, and it is what the
#      recorder's CI runs.
#   4. Copies the bundle — the files `build-ct-mcr` places next to `ct_cli`,
#      plus the recorder's signed test licence — into
#      `build/test-fixtures/hcr-ct-mcr/`. `ct_cli` resolves every companion
#      library next to its own executable first (`findInterposeDylib`,
#      `ctLicenseFfiLibraryPath`, ...), so the staged directory is a complete
#      recorder. Staging gives the graph a repo-relative output it can
#      declare and fingerprint, and gives the gate a path that does not name
#      another checkout. Each file is copied to a temporary name and renamed
#      into place, so a test still executing the previous `ct_cli` never sees
#      a half-written file (and a running executable is never opened for
#      writing).
#
# Usage: scripts/build_hcr_ct_mcr_fixture.sh
# Exit status: 0 when every bundle file is staged; non-zero, naming the cause,
# otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly EDGE_ID="reprobuild.test_fixtures.hcr_ct_mcr_bundle"
readonly OUT_REL="build/test-fixtures/hcr-ct-mcr"
readonly OUT_DIR="${REPO_ROOT}/${OUT_REL}"
# The first recorder commit carrying HX-S-2 ("re-apply a recorded hot patch at
# its geid, through the target's own agent") adds this gate. Its presence is
# the marker, not ancestry: CI clones siblings shallow, where `merge-base`
# cannot answer.
readonly HXS2_MARKER="tests/test_hx_s2_replay_crosses_the_patch_boundary.sh"

# The bundle, as `<path relative to the recorder checkout>` entries. Keep this
# list in step with the `extraOutputs` of `${EDGE_ID}` in `repro.nim`; the
# regression test `tests/unit/test_hcr_replay_gate_ct_mcr_fixture_edge.py`
# holds the two equal.
readonly BUNDLE=(
  ct_cli/ct_cli
  ct_cli/libct_interpose.so
  ct_cli/libct_interpose_static.so
  ct_cli/libct_license_ffi.so
  ct_cli/libct_clr_profiler.so
  ct_cli/libgl_passthrough.so
  ct_cli/libct_vk_layer.so
  ct_cli/vk_layer_manifest.json
  ct_cli/ct-dwarf-paths
  tests/fixtures/licensing/ct-test-license.dat
)

# Every failure also removes the previously staged bundle. A run that could
# not build the recorder must not leave an older bundle in place for the gate
# to pass with: the suite carries on past a failed cross-repo fixture
# (scripts/run_tests.sh), so a stale bundle would turn "the fixture did not
# build" into a green gate measured against a recorder nobody built today.
die() {
  rm -rf "${OUT_DIR}"
  echo "build_hcr_ct_mcr_fixture: error: $*" >&2
  echo "build_hcr_ct_mcr_fixture: (this script is graph edge ${EDGE_ID})" >&2
  exit 1
}

# The gate records with the Linux x86-64 ELF provider and is declared
# `unsupported` everywhere else (scripts/hcr-lane-manifest.tsv); the graph
# declares this edge only there. The Justfile recipe still runs on every lane
# (`--verify-unsupported` runs the gate's recipe), so say why nothing happens.
if [[ "$(uname -s)" != "Linux" ]] || ! [[ "$(uname -m)" =~ ^(x86_64|amd64)$ ]]; then
  echo "build_hcr_ct_mcr_fixture: not applicable on $(uname -s) $(uname -m):" \
    "e2e_hcr_linux_replay_of_patched_recording is Linux x86_64 only."
  exit 0
fi

sibling="${CT_CODETRACER_NATIVE_RECORDER_SIBLING:-${REPO_ROOT}/../codetracer-native-recorder}"
if [[ ! -f "${sibling}/Justfile" || ! -f "${sibling}/flake.nix" ]]; then
  die "no codetracer-native-recorder checkout at ${sibling}." \
    "Check it out beside reprobuild, or point" \
    "CT_CODETRACER_NATIVE_RECORDER_SIBLING at one."
fi
sibling="$(cd "${sibling}" && pwd)"

if [[ ! -f "${sibling}/${HXS2_MARKER}" ]]; then
  die "the recorder at ${sibling} predates HX-S-2 (codetracer-native-recorder" \
    "042aee6e): ${HXS2_MARKER} is absent. Its ct-mcr refuses every trace" \
    "carrying a CodePatchEvent, so the replay gate cannot pass with it." \
    "Update the checkout."
fi

if ! command -v nix >/dev/null 2>&1; then
  die "nix is not on PATH. The recorder bundle is built in the recorder's own" \
    "flake dev shell (nix develop ${sibling}); there is no other pinned" \
    "environment for it."
fi

echo "build_hcr_ct_mcr_fixture: building the recorder bundle in ${sibling}" \
  "(just build-ct-mcr, in its own flake dev shell)"

# `--ignore-environment` with an explicit keep-list: the recorder's build sees
# its own shell and the handful of variables that identify the user and reach
# the network, nothing else. The `GIT_CONFIG_{COUNT,KEY_n,VALUE_n}` family is
# kept because that is how CI hands git its scoped credentials for the private
# repositories nimble and cargo fetch (the recipe's `lldb-sys` fork among
# them); it carries no build input.
#
# The caller's PATH is APPENDED to the recorder shell's, never prepended: the
# recorder's toolchain always wins, and the caller's directories only supply
# host programs that shell does not carry. The one that matters is a git
# credential helper (a workstation's `credential.helper = !gh auth
# git-credential`): without it every private fetch fails with "failed to
# authenticate", which is how a fully pure shell failed here.
#
# `cd` inside the shell, because the recorder's shellHook resolves its root
# from `$PWD`.
keep=(HOME USER LOGNAME TERM TMPDIR XDG_CONFIG_HOME SSL_CERT_FILE
  NIX_SSL_CERT_FILE CARGO_NET_GIT_FETCH_WITH_CLI)
while IFS='=' read -r name _; do
  [[ "${name}" =~ ^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)$ ]] && keep+=("${name}")
done < <(env)
keep_args=()
for name in "${keep[@]}"; do
  keep_args+=(--keep "${name}")
done
# The inner script is single-quoted on purpose: `$PATH`, `$1` and `$2` are
# expanded by the bash INSIDE the recorder's shell.
# shellcheck disable=SC2016
nix develop "${sibling}" \
  --no-update-lock-file \
  --ignore-environment \
  "${keep_args[@]}" \
  --command bash -euo pipefail -c 'export PATH="${PATH}:$2"; cd "$1" && just build-ct-mcr' \
  build-ct-mcr "${sibling}" "${PATH}" ||
  die "\`just build-ct-mcr\` failed in ${sibling} (output above)."

mkdir -p "${OUT_DIR}"
for rel in "${BUNDLE[@]}"; do
  src="${sibling}/${rel}"
  if [[ ! -f "${src}" ]]; then
    die "\`just build-ct-mcr\` succeeded but did not produce ${src}." \
      "The bundle this gate replays with is incomplete; see the recipe in" \
      "${sibling}/Justfile."
  fi
  dest="${OUT_DIR}/$(basename "${rel}")"
  tmp="${dest}.tmp.$$"
  cp -p "${src}" "${tmp}" || die "could not copy ${src} to ${tmp}."
  mv -f "${tmp}" "${dest}" || die "could not move ${tmp} into place."
done

echo "build_hcr_ct_mcr_fixture: staged ${#BUNDLE[@]} file(s) into ${OUT_REL}" \
  "from recorder $(git -C "${sibling}" rev-parse --short HEAD 2>/dev/null || echo '<not a git checkout>')"

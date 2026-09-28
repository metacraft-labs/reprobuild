#!/usr/bin/env bash
# smoke_release_dev_exec.sh <package-dir>
#
# Run the PACKAGED `repro` the way a consumer's CI does -- `repro exec` in a
# project that has a `repro.nim` -- and require it to reach the command.
#
# That first `repro exec` compiles the project's recipe (interface extraction)
# and its provider against the sources the archive ships under share/repro.
# v0.2.0 passed every existing release check (`--version`, `--help`,
# `capabilities`) and still failed here on every consumer:
#
#   Error: cannot open file: repro_interface_artifacts
#
# The project lives in a fresh temporary directory, so no reprobuild checkout
# is its sibling or ancestor, and every variable that could point the image at
# the build host's sources is removed first. The image has to find its own.
# (Paths compiled into the binary still exist on the build host; the archive's
# own trees outrank them, and check_release_source_closure.sh proves those
# trees are complete without the host.)
#
# Needs a Nim compiler on PATH (the release legs have one).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
pkg=$(cd "$1" && pwd)
repro_bin="$pkg/bin/repro"
[[ -f "$repro_bin" ]] || repro_bin="$pkg/bin/repro.exe"
[[ -f "$repro_bin" ]] || { echo "smoke_release_dev_exec: no bin/repro in $pkg" >&2; exit 1; }

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/repro-release-smoke-XXXXXX")
trap 'rm -rf "$work"' EXIT
project="$work/project"
mkdir -p "$project"
cat > "$project/repro.nim" <<'EOF'
import repro_project_dsl

package releaseSmoke:
  devEnv:
    discard
EOF

scrub=(
  REPROBUILD_SOURCE_ROOT REPROBUILD_LIBS_DIR REPROBUILD_REPO_ROOT
  REPROBUILD_SRC REPRO_BOOTSTRAP_SOURCE_ENV REPRO_PUBLIC_CLI_PATH
  NIMCRYPTO_SRC BEARSSL_SRC STACKABLE_HOOKS_SRC CODETRACER_TRACE_FORMAT_NIM_SRC
  IO_MON_SRC SHM_GSET_SRC SHM_QUEUE_SRC CODETRACER_SRC CODETRACER_PINNED_SRC
  REPRO_CT_TEST_RUNNER_SRC REPRO_TEST_ADAPTERS_SRC RUNQUOTA_SRC VM_HARNESS_SRC
  FASTSTREAMS_SRC NIM_STEW_SRC NIM_SERIALIZATION_SRC NIM_JSON_SERIALIZATION_SRC
  NIM_TOML_SERIALIZATION_SRC SSZ_SERIALIZATION_SRC RESULTS_SRC STINT_SRC
)
for v in "${scrub[@]}"; do unset "$v"; done

marker="repro-release-smoke-ok"
echo "=== repro exec in a fresh project, using only $pkg ==="
out="$work/exec.log"
# Output goes to a FILE, not through `| tee`: a helper that outlives
# `repro exec` (on Windows, an msiexec it spawned) keeps a pipe's write end
# open, so a failed exec that printed its error at once still held the step
# for its whole 60-minute timeout. Bounded as well, for the same reason.
bound=()
if command -v timeout >/dev/null 2>&1; then
  bound=(timeout --kill-after=60 "${REPRO_SMOKE_TIMEOUT_SECONDS:-2700}")
fi
set +e
(cd "$project" && "${bound[@]}" "$repro_bin" exec -- bash -c \
  'echo "$1"; echo "seeded-source-root=${REPROBUILD_SOURCE_ROOT:-}"' _ "$marker") \
  > "$out" 2>&1 < /dev/null
rc=$?
set -e
cat "$out"
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  echo "smoke_release_dev_exec: ERROR: repro exec did not finish within ${REPRO_SMOKE_TIMEOUT_SECONDS:-2700}s." >&2
  exit 1
fi
if [[ $rc -ne 0 ]] || ! grep -q "^${marker}" "$out"; then
  echo "smoke_release_dev_exec: ERROR: the packaged repro could not run a command in a fresh project (exit $rc)." >&2
  if grep -q "cannot open file" "$out"; then
    echo "  A module the installed compile needs is missing from the archive's share/repro;" >&2
    echo "  see scripts/release/stage_release_sources.sh." >&2
  fi
  exit 1
fi
# Reaching the command is not enough on the BUILD HOST: a binary built here
# still finds this checkout through the source paths compiled into it, so a
# missing share/repro would pass. Require that the roots the command inherited
# are the archive's own -- that is the discovery a consumer relies on.
# (check_release_source_closure.sh proves the trees are complete.)
seeded=$(grep -m1 '^seeded-source-root=' "$out" | tr -d '\r' | cut -d= -f2-)
case "${seeded//\\//}" in
  */"$(basename "$pkg")"/share/repro/source) ;;
  *)
    echo "smoke_release_dev_exec: ERROR: repro did not take its sources from the archive." >&2
    echo "  REPROBUILD_SOURCE_ROOT seen by the command: '${seeded}'" >&2
    echo "  expected: <package>/share/repro/source under $pkg" >&2
    exit 1
    ;;
esac
echo "=== repro exec smoke test PASSED (sources: ${seeded}) ==="

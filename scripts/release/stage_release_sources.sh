#!/usr/bin/env bash
# stage_release_sources.sh <package-dir>
#
# Copy the Nim sources an INSTALLED reprobuild compiles against into a release
# archive tree, so the unpacked archive is self-contained.
#
# WHY. The first thing reprobuild does for any project -- `repro exec`,
# `repro build`, `dev-exec` in CI -- is compile the project's `repro.nim`
# (interface extraction), and then its provider, against reprobuild's OWN
# libraries and a handful of source-only siblings. A release archive that
# ships only bin/ and lib/ fails right there, on every platform:
#
#   extract_runner_<hash>.nim(2, 8) Error: cannot open file: repro_interface_artifacts
#
# LAYOUT (Distribution-And-Packaging §5; identical to the native packages):
#
#   <pkg>/share/repro/source/libs/...        reprobuild's libs/, tests excluded
#   <pkg>/share/repro/src/<input>/...        one tree per source-only input
#   <pkg>/share/repro/reprobuild-packages/   the pinned catalog's interfaces
#
# The running image finds these itself (repro_interface_artifacts.
# ensureInstalledSourcePackageEnvironment): no wrapper, no environment.
#
# RESOLUTION mirrors config.nims -- the environment variable the dev shell
# exports first (POSIX legs, Nix store paths), then the sibling checkout the
# Windows leg clones beside this repository -- so the archive carries the same
# sources the binaries in it were built from. Every input listed is REQUIRED:
# the list is the measured closure of the compiles an installed reprobuild
# runs (interface extraction + provider), and a release missing one of them is
# the defect this script exists to prevent. `verify_release.sh` re-checks the
# result from the other side.
#
# Run from the reprobuild checkout root.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
pkg=$1
[[ -d "$pkg" ]] || { echo "stage_release_sources: no such directory: $pkg" >&2; exit 1; }
[[ -f libs/repro_project_dsl/src/repro_project_dsl.nim ]] || {
  echo "stage_release_sources: run from the reprobuild checkout root" >&2; exit 1; }

source_root="$pkg/share/repro/source"
src_root="$pkg/share/repro/src"
rm -rf "$pkg/share/repro"
mkdir -p "$source_root" "$src_root"

# Copy <from> to <to>, keeping only what a `nim c` reads: Nim sources and
# configs, the C/C++ sources and headers `{.compile.}`/`-I` name, and licence
# files. Build products, VCS metadata and test trees are dropped.
copy_tree() {
  local from=$1 to=$2 f
  mkdir -p "$to"
  (cd "$from" && find . \
      \( -name .git -o -name build -o -name nimcache -o -name .repro \
         -o -name tests -o -name node_modules \) -prune -o \
      -type f \( \
        -name '*.nim' -o -name '*.nims' -o -name '*.nimble' -o -name '*.cfg' \
        -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cc' \
        -o -name '*.cpp' -o -name '*.inc' -o -name '*.S' -o -name '*.s' \
        -o -name '*.asm' -o -name 'LICENSE*' -o -name 'COPYING*' \) \
      -print) |
  while IFS= read -r f; do
    mkdir -p "$to/$(dirname "$f")"
    cp "$from/$f" "$to/$f"
  done
  # Store paths are read-only; the archive tree must stay removable.
  chmod -R u+w "$to"
}

# ---- reprobuild's own libs ---------------------------------------------------
# Every tracked file outside tests/: some lib modules read data files at compile
# time (`staticRead` of recipe templates), so no extension filter here.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files -z -- libs | while IFS= read -r -d '' f; do
    case "/$f/" in */tests/*) continue ;; esac
    [[ -f "$f" ]] || continue
    mkdir -p "$source_root/$(dirname "$f")"
    cp "$f" "$source_root/$f"
  done
else
  copy_tree libs "$source_root/libs"
fi

# ---- source-only inputs ------------------------------------------------------
# stage <ENV_VAR> <dest under share/repro/src> <marker> <candidate>...
# The destination names are repro_interface_artifacts.InstalledSourcePackageTrees
# (and the native packages' wrapper values); the marker is relative to the
# resolved root.
missing=()
stage() {
  local env_name=$1 dest=$2 marker=$3; shift 3
  local root="" candidate
  for candidate in "${!env_name:-}" "$@"; do
    if [[ -n "$candidate" && -f "$candidate/$marker" ]]; then
      root=$candidate
      break
    fi
  done
  if [[ -z "$root" ]]; then
    missing+=("$env_name (want $marker; tried \$$env_name='${!env_name:-}' $*)")
    return 0
  fi
  echo "stage_release_sources: $dest <- $root"
  copy_tree "$root" "$src_root/$dest"
}

stage REPRO_TEST_ADAPTERS_SRC reprobuild-test-adapters/src \
  repro_test_adapters/test_runner.nim ../reprobuild-test-adapters/src
stage REPRO_CT_TEST_RUNNER_SRC reprobuild-ct-test-runner \
  libs/ct_incremental_adapter/src/ct_incremental_adapter.nim \
  ../reprobuild-ct-test-runner
stage IO_MON_SRC io-mon/src io_mon.nim ../io-mon/src
stage STACKABLE_HOOKS_SRC nim-stackable-hooks/src stackable_hooks.nim \
  ../nim-stackable-hooks/src
# config.nims resolves these two sibling-FIRST; mirror it so the archive holds
# what was compiled.
sibling_first() { # sibling_first <ENV_VAR> <sibling> <marker>
  if [[ -f "$2/$3" ]]; then printf '%s' "$2"; else printf '%s' "${!1:-}"; fi
}
SHM_GSET_SRC=$(sibling_first SHM_GSET_SRC ../nim-shm-gset/src shm_gset.nim) \
  stage SHM_GSET_SRC nim-shm-gset/src shm_gset.nim
SHM_QUEUE_SRC=$(sibling_first SHM_QUEUE_SRC ../nim-shm-queue/src shm_queue.nim) \
  stage SHM_QUEUE_SRC nim-shm-queue/src shm_queue.nim
stage RUNQUOTA_SRC runquota libs/runquota_core/src/runquota_core.nim ../runquota
# The marker is the MODULE the staged archive has to be able to compile, not
# the package root file: `bearssl.nim` is in every revision, including ones
# predating the `bearssl/abi/` tree `repro_deploy_agent` imports, so staging on
# the strength of it ships an archive that cannot build a project. Same string
# as `scripts/source_paths.sh`, `config.nims` and the recipe's probe.
stage BEARSSL_SRC bearssl bearssl/abi/consttypes.nim ../nim-bearssl \
  libs/nim-bearssl

# ---- the reprobuild-packages catalog -----------------------------------------
# An installed reprobuild carries the catalog it was released with, beside its
# sources; see stage_release_catalog.sh.
if ! bash scripts/release/stage_release_catalog.sh "$pkg"; then
  missing+=("reprobuild-packages (stage_release_catalog.sh said why, above)")
fi

if (( ${#missing[@]} > 0 )); then
  echo "stage_release_sources: ERROR: source-only inputs not found:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "An installed reprobuild compiles against these; the archive would not" >&2
  echo "be able to build any project without them." >&2
  exit 1
fi

files=$(find "$pkg/share/repro" -type f | wc -l)
echo "stage_release_sources: staged $files source files under $pkg/share/repro"

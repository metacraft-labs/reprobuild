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
#   <pkg>/share/repro/source/config.nims     the profile compile includes it
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
# Run from the reprobuild checkout root. With $STAGE_RELEASE_SOURCES_MANIFEST
# set, each staged input's `<ENV_VAR> <dest> <root>` is appended to that file.
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

# Copy the files named on stdin (NUL-separated, relative to <from>) into <to>,
# keeping their relative paths. One tar pair for the whole list, not a
# `mkdir` + `cp` per file: on Windows every process spawn costs tens of
# milliseconds in Git for Windows' bash, and the per-file loop this replaces
# took the better part of an hour to stage one archive (measured 2026-10-13 on
# eli-pc: ~1 file/s). The archive's file set is unchanged -- the lists are
# produced exactly as before. Both GNU tar and bsdtar read a NUL-separated
# name list with `--null -T -`; the archive itself goes through a pipe, so no
# `-C <drive>:\...` argument is ever parsed as a remote host.
copy_listed() {
  local from=$1 to=$2 to_abs
  mkdir -p "$to"
  to_abs=$(cd "$to" && pwd)
  (cd "$from" && tar --null -T - -cf -) | (cd "$to_abs" && tar -xf -)
}

# copy_tree <from> <to> [compile|all]
#
# Copy the files of <from> to <to>. Build products, VCS metadata and test
# trees are dropped either way. `compile` (the default, for the source-only
# inputs) keeps only what a `nim c` reads: Nim sources and configs, the C/C++
# sources and headers `{.compile.}`/`-I` name, and licence files. `all` keeps
# every file, for reprobuild's own source root, which also carries data the
# installed engine reads at run time (see below).
copy_tree() {
  local from=$1 to=$2 kinds=${3:-compile}
  local -a only=()
  if [[ "$kinds" == compile ]]; then
    only=( \( \
        -name '*.nim' -o -name '*.nims' -o -name '*.nimble' -o -name '*.cfg' \
        -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cc' \
        -o -name '*.cpp' -o -name '*.inc' -o -name '*.S' -o -name '*.s' \
        -o -name '*.asm' -o -name 'LICENSE*' -o -name 'COPYING*' \) )
  fi
  # `${only[@]+...}`: an empty array is "unbound" to bash < 4.4 under `set -u`.
  (cd "$from" && find . \
      \( -name .git -o -name build -o -name nimcache -o -name .repro \
         -o -name tests -o -name node_modules \) -prune -o \
      -type f ${only[@]+"${only[@]}"} -print0) | copy_listed "$from" "$to"
  # Store paths are read-only; the archive tree must stay removable.
  chmod -R u+w "$to"
}

# ---- reprobuild's own source root ------------------------------------------
# What it carries -- trees and root-level files -- is the list in
# scripts/lib/stage_source_root.sh, shared with the native-package payload
# stagers so an entry added for one format reaches every format. This stager
# keeps its own copy: every file of each tree outside tests/, in one tar pipe.
#
# EVERY file, with no extension filter, because the source root is not only
# compiled. Some lib modules read data files at compile time (`staticRead` of
# recipe templates), and the installed engine reads others at RUN time from
# beside the stdlib recipe that names them: a tarball arm's
# `closureManifest = "closures/<name>.manifest"` and a nixPackage arm's
# `expressionFile = "nix/<name>/default.nix"` (with the files that expression
# imports) resolve against the declaring module's directory, which for an
# installed reprobuild is this tree. v0.2.26's Windows archive was staged
# through an extension filter and lacked them, and every consumer's tarball
# provisioning of playwright failed with "closure manifest not found".
# check_release_data_files.sh fails a staged tree that lacks one.
#
# The file list is git's when this is a git checkout (tracked files only, so a
# build product left in libs/ stays out), and a directory walk when it is not
# (a source archive). Both list every file kind. Git runs through
# release_git.sh: a bare `git` here met the Windows release leg's traps (not
# on PATH, or the checkout not owned by the runner's account), failed with its
# error discarded, and silently switched this stager to a walk that then
# filtered by extension. A checkout git cannot read is now an error, with git's
# own message. The filter loop uses only shell builtins, so it spawns nothing
# per file.
# shellcheck source=scripts/lib/stage_source_root.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/stage_source_root.sh"
# shellcheck source=scripts/lib/release_git.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/release_git.sh"
if [[ -e .git ]]; then
  release_git_init stage_release_sources || exit 1
  if ! why=$(release_git -C . rev-parse --is-inside-work-tree 2>&1 >/dev/null); then
    echo "stage_release_sources: ERROR: git cannot read the checkout at $(pwd): ${why//$'\n'/ }" >&2
    exit 1
  fi
  echo "stage_release_sources: source root <- the tracked files of $(pwd)"
  # shellcheck disable=SC2086 # the list is deliberately word-split
  release_git -C . ls-files -z -- $REPRO_SOURCE_ROOT_TREES |
    while IFS= read -r -d '' f; do
      case "/$f/" in */tests/*) continue ;; esac
      [[ -f "$f" ]] || continue
      printf '%s\0' "$f"
    done | copy_listed . "$source_root"
else
  echo "stage_release_sources: source root <- every file of $(pwd) (no .git here)"
  # shellcheck disable=SC2086 # the list is deliberately word-split
  for tree in $REPRO_SOURCE_ROOT_TREES; do
    copy_tree "$tree" "$source_root/$tree" all
  done
fi
# The root-level files beside the trees. The profile compile (`repro home
# apply`, `repro infra apply`) includes `<source root>/config.nims` from a
# wrapper it stages next to the profile; that file turns the `*_SRC` roots into
# search paths (nimcrypto, bearssl, io-mon, ...) and points the C compiler at
# the vendored hash headers. Without it the archive's profile compile saw only
# `libs/*/src` and failed with `cannot open file: nimcrypto/sha2`.
# shellcheck disable=SC2086 # the list is deliberately word-split
for file in $REPRO_SOURCE_ROOT_FILES; do
  cp "$file" "$source_root/$file"
done

# ---- source-only inputs ------------------------------------------------------
# shellcheck source=scripts/lib/stage_package_nimble.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/stage_package_nimble.sh"
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
  # A `<package>/src` destination also gets the package's nimble file beside
  # it: a module may read it at compile time (scripts/lib/stage_package_nimble.sh).
  stage_package_nimble "$root" "$src_root/$dest"
  # Which tree each input came from, for a caller that records it (the
  # installed prefix's `cross-build-info`, Distribution-And-Packaging
  # §5.3): one `<ENV_VAR> <dest> <root>` line per staged input.
  if [[ -n "${STAGE_RELEASE_SOURCES_MANIFEST:-}" ]]; then
    printf '%s %s %s\n' "$env_name" "$dest" "$root" >> "$STAGE_RELEASE_SOURCES_MANIFEST"
  fi
}

stage REPRO_TEST_ADAPTERS_SRC reprobuild-test-adapters/src \
  repro_test_adapters/test_runner.nim ../reprobuild-test-adapters/src
stage TEST_CERTIFICATES_TOOLS_SRC test-certificates-tools/src \
  test_certificates.nim ../test-certificates-tools/src
stage REPRO_CT_TEST_RUNNER_SRC reprobuild-ct-test-runner \
  libs/ct_incremental_adapter/src/ct_incremental_adapter.nim \
  ../reprobuild-ct-test-runner
stage IO_MON_SRC io-mon/src io_mon.nim ../io-mon/src
stage STACKABLE_HOOKS_SRC nim-stackable-hooks/src stackable_hooks.nim \
  ../nim-stackable-hooks/src
# config.nims resolves these sibling-FIRST (`addSiblingFirstPackagePath`);
# mirror its choice so the archive holds what was compiled:
#
# * no sibling checkout -> $<ENV_VAR>;
# * REPRO_SIBLING_POLICY=sibling, no $<ENV_VAR>, or $<ENV_VAR> naming the
#   sibling itself -> the sibling;
# * REPRO_SIBLING_POLICY=pin -> $<ENV_VAR>;
# * otherwise the sibling, unless it is stale: behind the revision this
#   repository pins for it (repro.lock's `deps` entry, else
#   .github/sibling-repos) and carrying no local changes, in which case
#   $<ENV_VAR>.
#
# Each choice of $<ENV_VAR> over an existing sibling is announced on stderr, as
# config.nims announces it.

# The revision this repository pins for the sibling checkout <name> (the
# directory name, as config.nims's `pinnedSiblingRevision` keys it); empty
# when nothing pins it.
pinned_sibling_revision() { # pinned_sibling_revision <name>
  local name=$1 line rev=""
  if [[ -f repro.lock ]]; then
    # One inline table per `deps` entry: `{ name = "<name>", ... revision = "<sha>" ... }`.
    rev=$(grep -o "{ name = \"$name\",[^}]*revision = \"[0-9a-f]*\"" repro.lock |
      head -n 1 | sed 's/.*revision = "\([0-9a-f]*\)"/\1/')
  fi
  if [[ -z "$rev" && -f .github/sibling-repos ]]; then
    while IFS= read -r line; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      case "$line" in
        "$name!="*) rev=${line#"$name!="}; break ;;
        "$name="*) rev=${line#"$name="}; break ;;
      esac
    done < .github/sibling-repos
  fi
  printf '%s' "$rev"
}

# Git in the sibling checkout, with the variables a git hook exports for THIS
# repository cleared (they would point `git -C` back here) and lazy fetches
# off (a pin the sibling lacks locally is a pin it is not ahead of).
sibling_git() { # sibling_git <checkout> <git args>...
  local checkout=$1; shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_PREFIX \
    GIT_NO_LAZY_FETCH=1 git -C "$checkout" "$@"
}

# Why the sibling checkout <checkout> is stale, or nothing when it is not (or
# when that cannot be told: no pin, no git), as config.nims decides it.
sibling_staleness() { # sibling_staleness <checkout>
  local checkout=$1 pin head dirty
  pin=$(pinned_sibling_revision "$(basename "$checkout")")
  [[ -n "$pin" ]] || return 0
  head=$(sibling_git "$checkout" rev-parse HEAD 2>/dev/null) || return 0
  dirty=$(sibling_git "$checkout" status --porcelain --untracked-files=no 2>/dev/null) || return 0
  [[ ${#head} -ge 12 && -z "$dirty" ]] || return 0
  if ! sibling_git "$checkout" merge-base --is-ancestor "$pin" HEAD 2>/dev/null; then
    printf 'the sibling is at %s, which is not at or ahead of the revision %s this repository pins, and carries no local changes' \
      "${head:0:12}" "${pin:0:12}"
  fi
}

sibling_first() { # sibling_first <ENV_VAR> <sibling> <marker>
  local env_name=$1 sibling=$2 marker=$3 env_path=${!1:-}
  local policy=${REPRO_SIBLING_POLICY:-} why=""
  if [[ ! -f "$sibling/$marker" ]]; then
    printf '%s' "$env_path"
    return 0
  fi
  if [[ "$policy" != sibling && -n "$env_path" && -f "$env_path/$marker" &&
        "$(cd "$env_path" && pwd -P)" != "$(cd "$sibling" && pwd -P)" ]]; then
    if [[ "$policy" == pin ]]; then
      why="REPRO_SIBLING_POLICY=pin"
    else
      # The sibling's checkout: `../<name>/src` -> `../<name>`.
      local checkout=$sibling
      [[ "$(basename "$checkout")" == src ]] && checkout=$(dirname "$checkout")
      why=$(sibling_staleness "$checkout")
    fi
    if [[ -n "$why" ]]; then
      echo "stage_release_sources: using \$$env_name=$env_path instead of the sibling $sibling ($why); set REPRO_SIBLING_POLICY=sibling to force the sibling" >&2
      printf '%s' "$env_path"
      return 0
    fi
  fi
  printf '%s' "$sibling"
}
SHM_GSET_SRC=$(sibling_first SHM_GSET_SRC ../nim-shm-gset/src shm_gset.nim) \
  stage SHM_GSET_SRC nim-shm-gset/src shm_gset.nim
SHM_QUEUE_SRC=$(sibling_first SHM_QUEUE_SRC ../nim-shm-queue/src shm_queue.nim) \
  stage SHM_QUEUE_SRC nim-shm-queue/src shm_queue.nim
CLI_SPEC_SRC=$(sibling_first CLI_SPEC_SRC ../nim-cli-spec/src clispec.nim) \
  stage CLI_SPEC_SRC nim-cli-spec/src clispec.nim
ENTRYPOINTS_SRC=$(sibling_first ENTRYPOINTS_SRC ../nim-entrypoints/src entrypoints.nim) \
  stage ENTRYPOINTS_SRC nim-entrypoints/src entrypoints.nim
CONFUTILS_SRC=$(sibling_first CONFUTILS_SRC ../nim-confutils confutils.nim) \
  stage CONFUTILS_SRC nim-confutils confutils.nim
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

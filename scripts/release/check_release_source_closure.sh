#!/usr/bin/env bash
# check_release_source_closure.sh <package-dir>
#
# Prove an unpacked release tree carries every Nim module the compiles an
# installed reprobuild runs will import -- using ONLY the tree's own
# share/repro, never the build host's checkouts, Nix store or environment.
#
# It type-checks (`nim check`, no C compile, a few minutes at most) a probe
# that imports what those compiles import:
#
#   * the interface-extraction runner  (repro_interface_artifacts,
#     repro_project_dsl, repro_dsl_stdlib/constructors)
#   * the provider / resource-accessor compiles (repro_cli_support,
#     repro_resources, repro_dsl_stdlib/foreign_env)
#
# and then a recipe that uses a package which moved to reprobuild-packages,
# which must resolve from the archive's own share/repro/reprobuild-packages.
#
# with a --path set built from the archive layout alone, from a scratch
# directory with every parent/user/project nim config disabled. A missing tree
# fails as `cannot open file: <module>`, naming exactly what to stage.
#
# This is the static half of the release-layout gate; verify_release.sh's
# dev-exec smoke test is the dynamic half (it runs the real binary, which also
# exercises how the image FINDS these trees).
#
# Needs `nim` on PATH. NIM_CHECK_OS and NIM_CHECK_CPU override the target OS
# and CPU (default: the host's).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
pkg=$(cd "$1" && pwd)
share="$pkg/share/repro"
libs="$share/source/libs"
src="$share/src"

fail() { echo "check_release_source_closure: ERROR: $*" >&2; exit 1; }
[[ -f "$libs/repro_interface_artifacts/src/repro_interface_artifacts.nim" ]] ||
  fail "$pkg has no share/repro/source/libs/repro_interface_artifacts -- reprobuild's own libs were not staged (scripts/release/stage_release_sources.sh)"
command -v nim >/dev/null 2>&1 || fail "nim is not on PATH"

paths=()
for d in "$libs"/*/src; do paths+=("--path:$d"); done
# Vendored third-party packages under libs/, as config.nims adds them.
for d in nimcrypto nim-faststreams/src nim-stew/src nim-serialization/src \
         nim-json-serialization/src nim-toml-serialization/src \
         nim-ssz-serialization/src results/src stint/src; do
  [[ -d "$libs/$d" ]] && paths+=("--path:$libs/$d")
done
# Source-only inputs, as the runtime resolver adds them from the seeded roots.
for d in reprobuild-test-adapters/src test-certificates-tools/src io-mon/src nim-stackable-hooks/src \
         nim-shm-gset/src nim-shm-queue/src nim-cli-spec/src nim-entrypoints/src nim-confutils bearssl; do
  [[ -d "$src/$d" ]] && paths+=("--path:$src/$d")
done
for d in "$src"/runquota/libs/*/src "$src"/reprobuild-ct-test-runner/libs/*/src; do
  [[ -d "$d" ]] && paths+=("--path:$d")
done

work=$(mktemp -d "${TMPDIR:-/tmp}/repro-closure-XXXXXX")
# Best-effort: on Windows a helper the run started can still hold the
# project directory open for a moment ("Device or resource busy"), and a
# leftover temp dir must not turn a passed check into a failed step.
catwork=""
trap 'rm -rf "$work" ${catwork:+"$catwork"} 2>/dev/null || true' EXIT
cat > "$work/probe.nim" <<'EOF'
import std/os
import repro_interface_artifacts
import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_resources
import repro_dsl_stdlib/foreign_env
import repro_cli_support
EOF

os_flag=()
[[ -n "${NIM_CHECK_OS:-}" ]] && os_flag=("--os:${NIM_CHECK_OS}")
# A prefix built for another machine is checked for its CPU too
# (Distribution-And-Packaging §5.3: the installed compile on the target).
[[ -n "${NIM_CHECK_CPU:-}" ]] && os_flag+=("--cpu:${NIM_CHECK_CPU}")

echo "=== nim check of the installed-compile closure against $share ==="
log="$work/check.log"
# Guarded array expansion: under `set -u`, bash < 4.4 treats `"${os_flag[@]}"` on an
# empty array as an unbound variable. `${os_flag[@]+"${os_flag[@]}"}` expands safely
# when empty on macOS stock /bin/bash (3.2).
# `-d:reproEvalMode`: the full project DSL, as every engine compilation selects
# it (`repro_project_dsl/mode`); with no mode define and no config file the
# umbrellas compile the thin mode, which the engine's libraries cannot use.
if ! (cd "$work" && nim check --skipParentCfg:on --skipUserCfg:on \
        --skipProjCfg:on --hints:off --warnings:off -d:reproEvalMode \
        ${os_flag[@]+"${os_flag[@]}"} \
        --nimcache:"$work/nimcache" "${paths[@]}" probe.nim) > "$log" 2>&1; then
  grep -E "Error:" "$log" | head -20 >&2 || tail -30 "$log" >&2
  fail "the archive's share/repro does not close the installed compile; stage the module(s) named above"
fi
echo "=== closure OK: every module resolved from the archive ==="

# A recipe that uses a package which moved out of the stdlib compiles only when
# a reprobuild-packages catalog defines it. An installed reprobuild has no
# workspace sibling to find, so the archive carries the pinned catalog beside
# its sources (stage_release_sources.sh), where the lookup's last place --
# beside the source tree the DSL was compiled from -- finds it. Prove that from
# a scratch directory with no catalog above it and $REPROBUILD_PACKAGES_ROOT
# unset: the compile must succeed, and from THIS archive's catalog.
catalog="$share/reprobuild-packages"
[[ -f "$catalog/packages/interfaces/sqlite3/repro.nim" ]] ||
  fail "$pkg has no share/repro/reprobuild-packages catalog -- stage_release_sources.sh stages the pinned one"
grep -q '^revision=[0-9a-f]\{40\}' "$catalog/catalog-revision" 2>/dev/null ||
  fail "$catalog/catalog-revision does not name the catalog commit it was staged from"
# "No catalog above it" is a property of WHERE the scratch directory is, not
# of the archive: a scratch under a TMPDIR beside a reprobuild-packages
# checkout finds that checkout first. So the scratch is made where nothing
# reaches a catalog -- $TMPDIR, else /tmp -- and when neither qualifies the
# check refuses, naming what it found, instead of reporting the archive's
# catalog as missing (scripts/lib/catalog_free_scratch.sh says what counts).
# shellcheck source=scripts/lib/catalog_free_scratch.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/catalog_free_scratch.sh"
catwork=$(catalog_free_scratch repro-closure-catalog-XXXXXX "${TMPDIR:-/tmp}" /tmp) ||
  fail "cannot run the catalog probe: every scratch location reaches a reprobuild-packages catalog of its own (listed above), so the probe could not show which catalog the archive resolves; this says nothing about the archive"
catalog_physical=$(cd "$catalog" && pwd -P)
# Git for Windows' bash spells these /c/...; the compiler names the module it
# resolved C:\... . Hand the probe the drive-letter form (cygpath -m) so the
# comparison is between two spellings of one path, not an MSYS and a native one.
if command -v cygpath >/dev/null 2>&1; then
  catalog_spelled=$(cygpath -m "$catalog")
  catalog_physical=$(cygpath -m "$catalog_physical")
else
  catalog_spelled=$catalog
fi
# The probe asserts the catalog it resolved from IS this archive's -- its
# path, spelled as the --path flags spell it or physically, not a substring
# any `share/repro` would match -- and, when it is not, says which place of
# the lookup answered.
cat > "$catwork/catalog_probe.nim" <<'EOF'
import std/[os, strutils]
import repro_project_dsl

const archiveCatalog {.strdefine.} = ""
const archiveCatalogPhysical {.strdefine.} = ""
const search = reprobuildPackagesSearch("sqlite3", currentSourcePath())
static:
  var answeredBy = "no place of the lookup"
  for probe in search.probes:
    if probe.module.len > 0 and probe.module == search.module:
      answeredBy = probe.origin & " (" & probe.root & ")"
      break
  doAssert archiveCatalog.len > 0, "-d:archiveCatalog was not passed"
  proc spelled(path: string): string =
    # One spelling per path: forward slashes, and on Windows a drive letter
    # of either case (cygpath and the compiler need not agree on it).
    result = path.replace('\\', '/')
    if result.len >= 2 and result[1] == ':':
      result[0] = result[0].toLowerAscii
  proc moduleIn(root: string): string =
    spelled(root / "packages" / "interfaces" / "sqlite3" / "repro")
  let found = spelled(search.module)
  doAssert found.len > 0 and (found == moduleIn(archiveCatalog) or
      found == moduleIn(archiveCatalogPhysical)),
    "catalog probe: sqlite3 resolved from " &
    (if search.module.len > 0: search.module else: "nowhere") &
    ", answered by " & answeredBy & ", not from the archive's catalog " &
    archiveCatalog

package releaseCatalogProbe:
  uses:
    "sqlite3"
EOF
echo "=== nim check of a recipe using a moved package, against the archive's catalog ==="
# Guarded array expansion: under `set -u`, bash < 4.4 treats `"${os_flag[@]}"` on an
# empty array as an unbound variable. `${os_flag[@]+"${os_flag[@]}"}` expands safely
# when empty on macOS stock /bin/bash (3.2).
if ! (cd "$catwork" && env -u REPROBUILD_PACKAGES_ROOT -u REPRO_WORKSPACE_CONFIG \
        -u REPRO_LOCKED_CATALOG nim check --skipParentCfg:on \
        --skipUserCfg:on --skipProjCfg:on --hints:off --warnings:off -d:reproEvalMode \
        "-d:archiveCatalog=$catalog_spelled" "-d:archiveCatalogPhysical=$catalog_physical" \
        ${os_flag[@]+"${os_flag[@]}"} --nimcache:"$catwork/nimcache-catalog" "${paths[@]}" \
        catalog_probe.nim) > "$log" 2>&1; then
  grep -E "Error:|catalog was looked for|  - " "$log" | head -20 >&2 || tail -30 "$log" >&2
  if grep -q "catalog probe: sqlite3 resolved from" "$log"; then
    fail "the catalog probe in $catwork resolved sqlite3 from a catalog other than the archive's (named above): the archive's share/repro/reprobuild-packages is not the one the lookup selects from a scratch directory with no catalog above it"
  fi
  fail "a recipe using a moved package does not compile against the archive alone; its share/repro/reprobuild-packages catalog is missing or not where the lookup looks"
fi
echo "=== catalog OK: the moved package resolved from the archive's own catalog ==="

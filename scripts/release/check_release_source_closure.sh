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
# Needs `nim` on PATH. NIM_CHECK_OS overrides the target OS (default: host).
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
for d in reprobuild-test-adapters/src io-mon/src nim-stackable-hooks/src \
         nim-shm-gset/src nim-shm-queue/src bearssl; do
  [[ -d "$src/$d" ]] && paths+=("--path:$src/$d")
done
for d in "$src"/runquota/libs/*/src "$src"/reprobuild-ct-test-runner/libs/*/src; do
  [[ -d "$d" ]] && paths+=("--path:$d")
done

work=$(mktemp -d "${TMPDIR:-/tmp}/repro-closure-XXXXXX")
# Best-effort: on Windows a helper the run started can still hold the
# project directory open for a moment ("Device or resource busy"), and a
# leftover temp dir must not turn a passed check into a failed step.
trap 'rm -rf "$work" 2>/dev/null || true' EXIT
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

echo "=== nim check of the installed-compile closure against $share ==="
log="$work/check.log"
if ! (cd "$work" && nim check --skipParentCfg:on --skipUserCfg:on \
        --skipProjCfg:on --hints:off --warnings:off "${os_flag[@]}" \
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
cat > "$work/catalog_probe.nim" <<'EOF'
import std/strutils
import repro_project_dsl

const found = reprobuildPackagesSearch("sqlite3", currentSourcePath()).module
static:
  doAssert found.replace('\\', '/').contains(
    "/share/repro/reprobuild-packages/packages/interfaces/sqlite3/repro"),
    "sqlite3 resolved from " & found & ", not from the archive's catalog"

package releaseCatalogProbe:
  uses:
    "sqlite3"
EOF
echo "=== nim check of a recipe using a moved package, against the archive's catalog ==="
if ! (cd "$work" && env -u REPROBUILD_PACKAGES_ROOT nim check --skipParentCfg:on \
        --skipUserCfg:on --skipProjCfg:on --hints:off --warnings:off \
        "${os_flag[@]}" --nimcache:"$work/nimcache-catalog" "${paths[@]}" \
        catalog_probe.nim) > "$log" 2>&1; then
  grep -E "Error:|catalog was looked for|  - " "$log" | head -20 >&2 || tail -30 "$log" >&2
  fail "a recipe using a moved package does not compile against the archive alone; its share/repro/reprobuild-packages catalog is missing or not where the lookup looks"
fi
echo "=== catalog OK: the moved package resolved from the archive's own catalog ==="

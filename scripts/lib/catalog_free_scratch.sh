# shellcheck shell=bash
# catalog_free_scratch.sh -- a scratch directory from which the
# reprobuild-packages catalog lookup reaches no catalog of its own.
#
# Sourced, not executed. Defines:
#
#   catalog_reach <dir>
#       Print the first place, at <dir> or above it, through which a compile
#       of a file in a NEW directory under <dir> could take its catalog from
#       somewhere other than the reprobuild sources it was compiled against,
#       followed by why; return 0. Print nothing and return 1 when there is
#       none.
#   catalog_free_scratch <template> <parent>...
#       Create a directory named <template> (mktemp syntax, `XXXXXX` at the
#       end) under the first <parent> that catalog_reach finds clean, and
#       print its physical path. When every <parent> reaches a catalog,
#       print each finding to stderr and return 1, creating nothing.
#
# WHY. check_release_source_closure.sh proves an archive's own
# share/repro/reprobuild-packages is the catalog an installed reprobuild
# resolves a moved package from. The lookup
# (repro_project_dsl/reprobuild_packages_catalog.nim, reprobuildPackagesSearch;
# Provisioning-Contributions.md §"Lookup") takes the catalog beside the
# reprobuild sources only when nothing nearer the consumer answers first. The
# probe's consumer is a file in its scratch directory, so where that directory
# is decides what the probe measures: a scratch under a TMPDIR beside a
# reprobuild-packages checkout -- the layout stage_release_catalog.sh asks for
# when it says "clone it at ../reprobuild-packages" -- found that checkout and
# failed as "the archive's catalog is missing" although the archive carried
# it (seen 2026-11-26 in `just lint`). A lint verdict must not depend on TMPDIR.
#
# What it looks for, per directory from <dir> up to `/`. Each is a superset of
# a lookup step, so a miss here cannot make the probe pass falsely; the probe
# itself still asserts which catalog it got and names it when it is not the
# archive's:
#
#   * an entry named reprobuild-packages: the checkout beside a child of that
#     directory (step 3, "beside the consumer or an ancestor", and step 2's
#     catalogs inside the consumer's repository). The lookup tests only that
#     the directory exists, so this tests only that the name exists;
#   * a repro.lock naming reprobuild-packages: a lock that pins the catalog,
#     which replaces the beside-the-sources catalog by the pin;
#   * packages/interfaces: a repository top that is itself a catalog (step 2).
#
# $REPROBUILD_PACKAGES_ROOT (step 1), $REPRO_WORKSPACE_CONFIG and
# $REPRO_LOCKED_CATALOG are environment, not location; the caller unsets them
# for the compile.
#
# Paths are physical (`pwd -P`): the compiler names the consumer by the
# directory it was started in, which is the physical one, so that is the chain
# the lookup walks.

catalog_reach() { # catalog_reach <dir>
  local dir parent
  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while :; do
    if [[ -e "$dir/reprobuild-packages" || -L "$dir/reprobuild-packages" ]]; then
      echo "$dir/reprobuild-packages (a reprobuild-packages checkout the lookup finds beside an ancestor of the scratch directory)"
      return 0
    fi
    if [[ -f "$dir/repro.lock" ]] && grep -q 'reprobuild-packages' "$dir/repro.lock" 2>/dev/null; then
      echo "$dir/repro.lock (a lock above the scratch directory that names reprobuild-packages, whose pin replaces the archive's catalog)"
      return 0
    fi
    if [[ -d "$dir/packages/interfaces" ]]; then
      echo "$dir (a catalog above the scratch directory: it holds packages/interfaces)"
      return 0
    fi
    parent=$(dirname "$dir")
    [[ "$parent" == "$dir" ]] && return 1
    dir=$parent
  done
}

catalog_free_scratch() { # catalog_free_scratch <template> <parent>...
  local template=$1 parent physical found created
  shift
  local -a findings=()
  for parent in "$@"; do
    [[ -n "$parent" ]] || continue
    if ! physical=$(cd "$parent" 2>/dev/null && pwd -P); then
      findings+=("$parent: not a directory")
      continue
    fi
    if found=$(catalog_reach "$physical"); then
      findings+=("$parent: reaches $found")
      continue
    fi
    created=$(mktemp -d "$physical/$template") || {
      findings+=("$parent: mktemp -d failed")
      continue
    }
    echo "$created"
    return 0
  done
  {
    echo "catalog_free_scratch: no scratch parent is free of a reprobuild-packages catalog the lookup would take before the one under test:"
    local f
    for f in ${findings[@]+"${findings[@]}"}; do echo "  - $f"; done
    echo "  Point TMPDIR at a directory with no reprobuild-packages checkout beside any of its ancestors and no repro.lock above it."
  } >&2
  return 1
}

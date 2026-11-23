# shellcheck shell=sh
# What an installed reprobuild's source root (`share/repro/source`, the tree
# `$REPROBUILD_SOURCE_ROOT` names) carries, and the copy the native-package
# payload stagers make of it.
#
# THE LIST. A source root is the subset of a reprobuild checkout an installed
# compile reads:
#
#   libs/         every library, on `--path:` through `libs/*/src`
#   lints/        root-level compatibility modules (`lints/ambient_execution`
#                 re-exports `repro_core/ambient_execution` for compiles that
#                 import it by that name); they resolve only through the
#                 `--path:` config.nims puts on the source root itself, and
#                 the release archives have always carried them
#   config.nims   the profile compile (`repro home apply`, `repro infra
#                 apply`) includes it from a wrapper beside the profile, and
#                 refuses a source root without it
#                 (repro_profile_compile.requireReprobuildSources)
#
# Each tree is staged without its tests. Every stager of a source root reads
# these two lists -- scripts/release/stage_release_sources.sh for the release
# archives, scripts/stage_payload_{linux,windows}.sh for the packages the
# reprobuild_dist layer describes -- so an entry the source root comes to need
# is added here, once, and reaches every format. The release stager keeps its
# own copy mechanism (tracked files only, one tar pipe for speed on Windows);
# the payload stagers call stage_source_root below.
#
# Sourced by POSIX sh (the payload stagers) and bash (the release stager), so
# it is POSIX sh.
REPRO_SOURCE_ROOT_TREES='libs lints'
REPRO_SOURCE_ROOT_FILES='config.nims'

# stage_source_root <reprobuild-checkout> <source-root>
#
# Fill <source-root> with every entry the two lists name, copied from the
# checkout. A tree's `tests/` directories one or two levels down (a package's
# own, and a nested package's) are dropped: they are never on `--path:`. An
# entry missing from the checkout is an error rather than a smaller source
# root, because a source root without it is the defect this file exists to
# prevent.
stage_source_root() {
  _ssr_from=$1
  _ssr_to=$2
  for _ssr_tree in $REPRO_SOURCE_ROOT_TREES; do
    if [ ! -d "$_ssr_from/$_ssr_tree" ]; then
      echo "stage_source_root: $_ssr_from has no $_ssr_tree/" >&2
      return 1
    fi
    mkdir -p "$_ssr_to/$_ssr_tree" || return 1
    (cd "$_ssr_from/$_ssr_tree" && find . -type f \
       -not -path './*/tests/*' -not -path './*/*/tests/*' \
       -print) | while IFS= read -r _ssr_f; do
      mkdir -p "$_ssr_to/$_ssr_tree/$(dirname "$_ssr_f")" || exit 1
      cp -L "$_ssr_from/$_ssr_tree/$_ssr_f" "$_ssr_to/$_ssr_tree/$_ssr_f" ||
        exit 1
    done || return 1
  done
  for _ssr_file in $REPRO_SOURCE_ROOT_FILES; do
    if [ ! -f "$_ssr_from/$_ssr_file" ]; then
      echo "stage_source_root: $_ssr_from has no $_ssr_file" >&2
      return 1
    fi
    cp -L "$_ssr_from/$_ssr_file" "$_ssr_to/$_ssr_file" || return 1
  done
  chmod -R u+w "$_ssr_to"
}

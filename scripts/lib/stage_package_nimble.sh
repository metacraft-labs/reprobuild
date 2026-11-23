# shellcheck shell=sh
# stage_package_nimble <source-src-dir> <staged-src-dir>
#
# Stage a Nim package's nimble file beside the `src` tree a release copied out
# of it, so the staged `<package>/src` sits in the same layout as the checkout
# and the Nix store path it was cut from.
#
# WHY. The release layouts ship a source-only input as its `src` directory
# alone (share/repro/src/<input>/src), because `src` is all a `--path:` entry
# names. But a module may read a file BESIDE its `src` at compile time, and the
# common one is its own nimble file: test-certificates-tools single-sources its
# version as
#
#   staticRead("../../test_certificates.nimble")      # src/test_certificates/cli.nim
#
# An archive without that file cannot compile the module, and v0.2.19's
# installed engine failed exactly there (`cannot open file:
# ../../test_certificates.nimble`, check_release_source_closure.sh on macOS).
# The checkout and the Nix package never showed it: both carry the whole
# repository. Copying the nimble file for every `src` input, not only for the
# one that reads it today, keeps the next package that adopts the same idiom
# from repeating the failure.
#
# Sourced by scripts/release/stage_release_sources.sh (bash) and by
# scripts/stage_payload_{linux,windows}.sh (POSIX sh), so it is POSIX sh.
#
# <source-src-dir> may be a Windows path (`C:\...\src`): Git for Windows' bash
# resolves it in `cd`, and the glob runs on the `pwd` it answers. Only a
# directory named `src` is a package's source directory; any other staged tree
# (a whole repository, a vendored package) already carries its nimble file or
# has none, and is left alone. A package with no nimble file stages nothing,
# and the closure check (check_release_source_closure.sh) is what fails if a
# module needed one.
stage_package_nimble() {
  case "$2" in
    */src) ;;
    *) return 0 ;;
  esac
  _spn_from=$(CDPATH='' cd -- "$1/.." && pwd) || return 1
  _spn_to=$(dirname "$2")
  for _spn_file in "$_spn_from"/*.nimble; do
    [ -f "$_spn_file" ] || continue
    cp "$_spn_file" "$_spn_to/" || return 1
    # Store paths are read-only, and the staged tree must stay removable.
    chmod u+w "$_spn_to/$(basename "$_spn_file")" || return 1
  done
}

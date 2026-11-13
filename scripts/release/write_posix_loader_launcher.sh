#!/usr/bin/env bash
#
# write_posix_loader_launcher.sh <launcher-path> <loader-basename> <names-engine>
#
# Write the portable Linux release launcher at <launcher-path>: a /bin/sh
# script that runs `<dir>/.<name>.real` (the real ELF, beside it) through the
# glibc loader bundled at `<dir>/../lib/<loader-basename>`, with
# `--library-path <dir>/../lib`.
#
# THE ONE DEFINITION OF THE LAUNCHER TEXT. `scripts/relocate_release_posix.sh`
# writes every `bin/<app>` of a POSIX release archive with it, and
# `tests/integration/t_the_release_launcher_does_not_make_the_engine_self_spawn_the_loader.nim`
# builds its launcher-shaped tree with it, so the test exercises the bytes
# the archive ships rather than a hand-copied lookalike that could drift.
#
# Why a launcher rather than `patchelf --set-interpreter`: a tarball can be
# unpacked anywhere and PT_INTERP cannot be relative to the binary ($ORIGIN
# is not honoured for the interpreter). The `.real` binary's own PT_INTERP is
# ignored when the loader is invoked explicitly.
#
# <names-engine> is `yes` when the tree has an engine (`bin/reprobuild`), in
# which case the launcher also exports `REPRO_PUBLIC_CLI_PATH` naming the
# ENGINE's launcher, unless the caller (e.g. the trampoline, for a pinned
# prefix) already set it. This is load-bearing: launching through the loader
# changes what a binary sees as its own image -- `/proc/self/exe`, hence
# Nim's `getAppFilename()`, is the LOADER in lib/, not bin/.<app>.real. The
# thin client `bin/repro` finds the engine next to its own image, so it would
# probe lib/reprobuild and give up ("repro: no reprobuild image to fall back
# to"), and the engine would spawn the loader whenever it re-executes itself
# (`<loader> __repro-extract-interface …` makes rtld try to map the verb:
# "error while loading shared libraries"). `REPRO_PUBLIC_CLI_PATH` is the one
# variable both read (`publicCliImagePath` in
# libs/repro_core/src/repro_core/source_root.nim for the engine), and it
# names bin/, so sibling providers still resolve.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <launcher-path> <loader-basename> <names-engine: yes|no>" >&2
  exit 64
fi
launcher="$1"
loadername="$2"
names_engine="$3"
base="$(basename -- "${launcher}")"

engine_wrapper_line=""
case "${names_engine}" in
  yes)
    # Literal on purpose: it is expanded by the LAUNCHER at run time, and the
    # heredoc below inserts a variable's value without expanding it again.
    # shellcheck disable=SC2016
    engine_wrapper_line=': "${REPRO_PUBLIC_CLI_PATH:=${here}/reprobuild}"; export REPRO_PUBLIC_CLI_PATH'
    ;;
  no) ;;
  *)
    echo "$0: <names-engine> must be yes or no, not '${names_engine}'" >&2
    exit 64
    ;;
esac

cat > "${launcher}" <<EOS
#!/bin/sh
# reprobuild portable launcher: run the real binary through the bundled glibc
# loader so it does not depend on the host's /nix/store or system glibc.
# Locate this script with shell builtins only: inside a build action PATH holds
# just the declared tools, which need not include dirname.
case "\$0" in */*) here=\${0%/*} ;; *) here=. ;; esac
here=\$(CDPATH= cd -- "\$here" && pwd)
${engine_wrapper_line}
exec "\${here}/../lib/${loadername}" --library-path "\${here}/../lib" "\${here}/.${base}.real" "\$@"
EOS
chmod +x "${launcher}"

#!/bin/sh
# Fill tests/fixtures/packaging/reprobuild-dist/prebuilt/ for a LINUX target,
# from a built reprobuild closure.
#
# WHY THIS IS IN THE REPOSITORY NOW (M1's N2). The dogfood recipe stages its
# packages from a FROZEN `prebuilt/` payload and for three passes nothing in
# the repository filled it: this script lived in a scratch directory on one
# machine. A payload with no checked-in definition is an engine and a payload
# staged at different commits with nothing in the graph that could notice --
# which is exactly what M1's N24 spent a pass misdiagnosing.
#
# WHAT THIS SCRIPT IS AND IS NOT. It is the DEFINITION of the Linux payload.
# It is NOT "filling prebuilt/ from the build graph", which is what would
# actually close N2 and is a MILESTONE rather than a task: reprobuild would
# have to build its own binaries, its two shared libraries, the three
# third-party `.so`s and a Nim toolchain as graph edges, and hold the result
# somewhere -- M5's self-build and multi-version store.
#
# The Windows counterpart is `scripts/stage_payload_windows.sh`. This one has
# the stronger provenance of the two: every byte is cut from the STORE PATH
# the flake's own wrapper names for that variable, so the package's copy and
# the Nix package's copy are the same bytes BY CONSTRUCTION rather than by
# a convention somebody followed.
#
# USAGE
#   scripts/stage_payload_linux.sh <nix-store-out> <reprobuild-checkout>
#
#     <nix-store-out>       the result of `nix build .#default`
#     <reprobuild-checkout> the checkout whose libs/ becomes the package's
#                           $REPROBUILD_SOURCE_ROOT tree
#
#   PREBUILT_DEST=<dir> overrides where the payload is written, so the script
#   can be checked AGAINST a payload already on disk without destroying it.
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <nix-store-out> <reprobuild-checkout>" >&2
  exit 2
fi
OUT="$1"
SRCROOT="$2"
FIX="$SRCROOT/tests/fixtures/packaging/reprobuild-dist"
PRE=${PREBUILT_DEST:-"$FIX/prebuilt"}

WRAPPER="$OUT/bin/repro"
wrapper_value() {
  sed -n "s/^export $1=\${$1-'\\(.*\\)'}\$/\\1/p" "$WRAPPER" | head -1
}

rm -rf "$PRE"
mkdir -p "$PRE/bin" "$PRE/lib" "$PRE/tree"

# ---- 1. bin: the unwrapped payload -----------------------------------
for b in repro repro-binary-cache repro-standard-provider \
         repro-cmake-dyndep-fragment repro-cmake-trycompile-provider \
         repro-install-mirror-publish; do
  cp -L "$OUT/bin/.$b-wrapped" "$PRE/bin/$b"
done
cp -L "$OUT/libexec/reprobuild-nix-daemon" "$PRE/bin/reprobuild-nix-daemon"
chmod -R u+w "$PRE/bin"

# ---- 2. lib: build/lib/* plus the three linker aliases ---------------
cp -L "$OUT/lib/librepro_monitor_shim.so" "$PRE/lib/"
cp -L "$OUT/lib/librepro_project_dsl_runtime.so" "$PRE/lib/"
BLAKE3_PREFIX=$(wrapper_value BLAKE3_PREFIX)
XXHASH_PREFIX=$(wrapper_value XXHASH_PREFIX)
SQLITE_PREFIX=$(wrapper_value SQLITE_PREFIX)
CLINGO_PREFIX=$(wrapper_value CLINGO_PREFIX)
cp -L "$BLAKE3_PREFIX/lib/libblake3.so" "$PRE/lib/libblake3.so"
cp -L "$XXHASH_PREFIX/lib/libxxhash.so" "$PRE/lib/libxxhash.so"
cp -L "$SQLITE_PREFIX/lib/libsqlite3.so" "$PRE/lib/libsqlite3.so"
chmod -R u+w "$PRE/lib"

# ---- 3. tree/lib/repro/include: the three headers --------------------
INC="$PRE/tree/lib/repro/include"
mkdir -p "$INC"
cp -RL "$BLAKE3_PREFIX/include/." "$INC/"
cp -RL "$XXHASH_PREFIX/include/." "$INC/"
cp -RL "$CLINGO_PREFIX/include/." "$INC/"
chmod -R u+w "$INC"

# ---- 4. tree/share/repro/source: reprobuild's own libs/ --------------
#
# The MINIMUM `$REPROBUILD_SOURCE_ROOT` has to be, measured rather than
# guessed: `repro_cli_support.reprobuildLibraryWorkDir` accepts a root
# whose `libs/repro_project_dsl/src` exists, `reproLibPathFlags` puts
# every `libs/*/src` on `--path:`, and `reproPackagePathFlags` resolves
# each third-party package against `libs/<pkg>` candidates.  Nothing
# outside `libs/` is consulted by either.  Each package's own `tests/`
# is dropped: it is never on `--path:` and it is a third of the bytes.
SOURCE="$PRE/tree/share/repro/source"
mkdir -p "$SOURCE/libs"
(cd "$SRCROOT/libs" && find . -type f \
   -not -path './*/tests/*' -not -path './*/*/tests/*' \
   -print) | while IFS= read -r f; do
  mkdir -p "$SOURCE/libs/$(dirname "$f")"
  cp -L "$SRCROOT/libs/$f" "$SOURCE/libs/$f"
done
chmod -R u+w "$SOURCE"

# ---- 5. tree/share/repro/src/<input>: the twelve sibling trees -------
#
# Each is cut from the store path the FLAKE'S OWN WRAPPER names for that
# variable, so the package's copy and the Nix package's copy are the
# same bytes by construction.  Filtered to what a Nim compile can
# consume, because that is the only thing a `--path:` entry is for: the
# unfiltered trees are 113 MB of which 56 MB is web assets, test
# fixtures and vendored binaries no compile can open.
stage_src() {
  var="$1"; dest="$2"
  from=$(wrapper_value "$var")
  if [ -z "$from" ]; then echo "no wrapper value for $var" >&2; exit 1; fi
  if [ ! -d "$from" ]; then echo "$var is not a directory: $from" >&2; exit 1; fi
  mkdir -p "$PRE/tree/share/repro/src/$dest"
  (cd "$from" && find . -type f \( \
      -name '*.nim' -o -name '*.nims' -o -name '*.nimble' -o -name '*.cfg' \
      -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cpp' \
      -o -name '*.cc' -o -name '*.inc' -o -name '*.S' -o -name '*.s' \) \
      -print) | while IFS= read -r f; do
    mkdir -p "$PRE/tree/share/repro/src/$dest/$(dirname "$f")"
    cp -L "$from/$f" "$PRE/tree/share/repro/src/$dest/$f"
  done
}
stage_src NIMCRYPTO_SRC                  nimcrypto
stage_src BEARSSL_SRC                    bearssl
stage_src STACKABLE_HOOKS_SRC            nim-stackable-hooks/src
stage_src CODETRACER_TRACE_FORMAT_NIM_SRC codetracer-trace-format-nim
stage_src IO_MON_SRC                     io-mon/src
stage_src SHM_GSET_SRC                   nim-shm-gset/src
stage_src SHM_QUEUE_SRC                  nim-shm-queue/src
stage_src CODETRACER_PINNED_SRC          codetracer/src
stage_src REPRO_CT_TEST_RUNNER_SRC       reprobuild-ct-test-runner
stage_src REPRO_TEST_ADAPTERS_SRC        reprobuild-test-adapters/src
# CT_INTERPOSE_SRC IS GONE, and this line is where the scratch copy of
# this script would still abort: M1's N16/N19 removed the variable from
# `ReprobuildWrapperVariables`, from the flake and from the forwarding
# list, so `wrapper_value CT_INTERPOSE_SRC` answers empty and the
# `stage_src` guard exits 1. The package no longer ships that tree.
stage_src RUNQUOTA_SRC                   runquota
chmod -R u+w "$PRE/tree"

echo "--- staged payload"
du -sk "$PRE/bin" "$PRE/lib" "$PRE/tree/lib" "$PRE/tree/share/repro/source" \
       "$PRE/tree/share/repro/src"
find "$PRE" -type f | wc -l

# ---- 6. tree/libexec/reprobuild/nim: the bundled Nim toolchain -------
#
# The compiler binary, its standard library and its config, laid out as
# a Nim PREFIX (`bin/nim` beside `lib/` and `config/`) because that is
# how the compiler finds its own stdlib.  `compiler/`, `tools/`, `dist/`
# and `doc/` are 13 MB of the toolchain's 49 and nothing a `nim c`
# invocation does opens them.
#
# Taken from the SAME derivation the flake's own wrapper now names in
# `REPRO_NIM_COMPILER`, so the package's compiler and the Nix package's
# compiler are the same bytes.
NIMBIN=$(wrapper_value REPRO_NIM_COMPILER)
if [ -z "$NIMBIN" ]; then echo "no REPRO_NIM_COMPILER in wrapper" >&2; exit 1; fi
NIMPREFIX=$(dirname "$(dirname "$(readlink -f "$NIMBIN")")")
NIMDEST="$PRE/tree/libexec/reprobuild/nim"
mkdir -p "$NIMDEST/bin"
cp -L "$(readlink -f "$NIMBIN")" "$NIMDEST/bin/nim"
for d in lib config; do
  mkdir -p "$NIMDEST/$d"
  (cd "$NIMPREFIX/$d" && find . -type f -print) | while IFS= read -r f; do
    mkdir -p "$NIMDEST/$d/$(dirname "$f")"
    cp -L "$NIMPREFIX/$d/$f" "$NIMDEST/$d/$f"
  done
done
chmod -R u+w "$NIMDEST"
echo "--- nim toolchain"
du -sk "$NIMDEST" "$NIMDEST"/*
find "$NIMDEST" -type f | wc -l

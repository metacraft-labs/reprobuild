#!/bin/sh
# Fill tests/fixtures/packaging/reprobuild-dist/prebuilt/ for a WINDOWS
# target, from this checkout's own build/ plus the sibling source trees
# and the dev-deps Nim toolchain.
#
# WHY THIS IS IN THE REPOSITORY NOW (M1's N2). The dogfood recipe stages
# Linux and Windows packages out of a FROZEN `prebuilt/` payload, and for
# three passes nothing in the repository filled it: the Windows half was a
# script in somebody's scratch directory plus, by the sixth pass, SIX
# hand-copied third-party DLLs. That is the engine and the payload staged
# at different commits with nothing in the graph that could notice, and it
# is what made `libwinpthread-1.dll` possible to miss -- a hand-staged set
# has no definition to check against.
#
# WHAT THIS SCRIPT IS AND IS NOT. It is the DEFINITION of the Windows
# payload: run it and `prebuilt/` is what it says, byte for byte. It is NOT
# "filling prebuilt/ from the build graph", which is what would actually
# close N2 and is a MILESTONE rather than a task -- see the milestone
# record: reprobuild would have to build its own binaries, its own two
# shared libraries and a Nim toolchain as graph edges, which is M5's
# self-build and needs the multi-version store to hold the result.
#
# The Linux counterpart is `scripts/stage_payload_linux.sh`, which cuts
# everything out of one `nix build .#default` STORE PATH, so the package
# and the Nix package are the same bytes by construction. There is no such
# store on Windows: the binaries come from `scripts/build_apps.sh` output
# in `build/`, the third-party DLLs from `build/bin` and the dev-deps tree,
# the source trees from the workspace's own sibling checkouts, and the
# compiler from the dev-deps tree. That is a weaker provenance and it is
# stated rather than hidden.
#
# USAGE
#   scripts/stage_payload_windows.sh                 # stage into prebuilt/
#   PREBUILT_DEST=/tmp/x scripts/stage_payload_windows.sh
#
# The override exists so the script can be checked AGAINST a payload
# already on disk without destroying it.
set -eu

RB=${REPROBUILD_ROOT:-M:/m/dev/reprobuild}
WS=${WORKSPACE_ROOT:-M:/m/dev}
DEVDEPS=${DEVDEPS_ROOT:-/d/metacraft-dev-deps}
FIX="$RB/tests/fixtures/packaging/reprobuild-dist"
PRE=${PREBUILT_DEST:-"$FIX/prebuilt"}

rm -rf "$PRE"
mkdir -p "$PRE/bin" "$PRE/lib" "$PRE/tree"

# ---- 1. bin --------------------------------------------------------
# NOTE `repro-cache-daemon.exe` is NOT here: the binary was deleted by
# Action-Cache-Per-Edge-Store and the previous Windows staging picked a
# stale one out of build/bin (M1 :residuals: N2). `reprobuild-nix-daemon`
# is absent too, and by design -- tool-provisioning=nix is a Unix path.
for b in repro repro-binary-cache repro-standard-provider \
         repro-cmake-dyndep-fragment repro-cmake-trycompile-provider \
         repro-install-mirror-publish; do
  [ -f "$RB/build/bin/$b.exe" ] || { echo "missing build/bin/$b.exe" >&2; exit 1; }
  cp "$RB/build/bin/$b.exe" "$PRE/bin/$b.exe"
done

# ---- 2. lib --------------------------------------------------------
for l in librepro_monitor_shim librepro_project_dsl_runtime; do
  [ -f "$RB/build/lib/$l.dll" ] || { echo "missing build/lib/$l.dll" >&2; exit 1; }
  cp "$RB/build/lib/$l.dll" "$PRE/lib/$l.dll"
done

# ---- 2b. lib: THE THIRD-PARTY LOADER CLOSURE -----------------------
# `stageInstallTree`'s runtime-closure walk is ELF-ONLY. On Windows the
# package therefore ships exactly what is named here and nothing else, and
# `reprobuildWindowsLoaderLibraries` in
# `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packaging/reprobuild_dist.nim`
# is the Nim-side statement of the same set.
#
# THE THREE ASSIGNMENTS BELOW ARE THE ONLY PLACE THIS SCRIPT NAMES THESE
# FILES, and `t_packaging_windows_loader_closure` PARSES THEM and compares
# them to the Nim list in both directions. That is deliberate: `prebuilt/`
# is gitignored, so a case that read the staged directory could only run on
# a machine that had already staged it, and would have nothing to say in CI
# or in a fresh clone. Two checked-in files can always be compared.
#
# Four come out of `build/bin`, where reprobuild's own build already put
# them beside the executables that load them; three are MinGW/msys2 runtime
# libraries with no other home. Each is copied from ONE named path -- never
# "whatever is first on %PATH%", which is the developer environment this
# whole closure exists to stop depending on.
#
# libgcc_s_seh-1 is a STATIC import of librepro_project_dsl_runtime.dll and
# libwinpthread-1 is a static import of libgcc_s_seh-1. The second was
# missed for a whole pass -- the first PE scan read the EXECUTABLES and not
# the libraries it had just added -- and
# `scripts/check_windows_scrubbed_launch.ps1` is what found it.
LOADER_LIBS_FROM_BUILD_BIN='libcrypto-3-x64 libssl-3-x64 sqlite3 clingo'
LOADER_LIBS_FROM_MSYS2_MINGW64='libzstd'
LOADER_LIBS_FROM_GCC='libgcc_s_seh-1 libwinpthread-1'

MSYS2_MINGW64_BIN=$DEVDEPS/msys2/msys64/mingw64/bin
GCC_BIN=$DEVDEPS/gcc/16.1.0/bin
stage_loader_libs() { # stage_loader_libs <source-dir> <names...>
  from=$1; shift
  for l in "$@"; do
    [ -f "$from/$l.dll" ] || { echo "missing $from/$l.dll" >&2; exit 1; }
    cp "$from/$l.dll" "$PRE/lib/$l.dll"
  done
}
# shellcheck disable=SC2086 -- the lists are deliberately word-split.
stage_loader_libs "$RB/build/bin" $LOADER_LIBS_FROM_BUILD_BIN
stage_loader_libs "$MSYS2_MINGW64_BIN" $LOADER_LIBS_FROM_MSYS2_MINGW64
stage_loader_libs "$GCC_BIN" $LOADER_LIBS_FROM_GCC

# ---- 3. tree/share/repro/source: reprobuild's own libs -------------
SOURCE="$PRE/tree/share/repro/source"
mkdir -p "$SOURCE/libs"
(cd "$RB/libs" && find . -type f \
   -not -path './*/tests/*' -not -path './*/*/tests/*' -print) |
while IFS= read -r f; do
  mkdir -p "$SOURCE/libs/$(dirname "$f")"
  cp "$RB/libs/$f" "$SOURCE/libs/$f"
done

# ---- 4. tree/share/repro/src/<input> -------------------------------
stage_src() { # stage_src <source-dir> <dest-rel>
  from="$1"; dest="$2"
  if [ ! -d "$from" ]; then echo "MISSING SOURCE TREE: $from" >&2; return 1; fi
  mkdir -p "$PRE/tree/share/repro/src/$dest"
  # BUILD ARTIFACTS ARE EXCLUDED, and that is a correction the first
  # Windows MSI made unmissable. The Linux staging cuts each tree out
  # of a nix STORE PATH, which has no build/ in it; this one cuts from
  # a live working checkout, which does -- and runquota/build/nimcache
  # alone contributed generated .c files under paths ninety characters
  # deep. They are not source a --path: entry is for, they made the
  # Windows payload diverge from the Linux one, and they are what
  # surfaced the MSI identifier collision.
  (cd "$from" && find . -type f \
      -not -path "./build/*" -not -path "./.repro/*" \
      -not -path "./.git/*" -not -path "*/nimcache/*" \
      \( \
      -name '*.nim' -o -name '*.nims' -o -name '*.nimble' -o -name '*.cfg' \
      -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cpp' \
      -o -name '*.cc' -o -name '*.inc' -o -name '*.S' -o -name '*.s' \) \
      -print) | while IFS= read -r f; do
    mkdir -p "$PRE/tree/share/repro/src/$dest/$(dirname "$f")"
    cp "$from/$f" "$PRE/tree/share/repro/src/$dest/$f"
  done
}
stage_src "$WS/nimcrypto"                     nimcrypto
stage_src "$DEVDEPS/nim-bearssl"              bearssl
stage_src "$WS/nim-stackable-hooks/src"       nim-stackable-hooks/src
stage_src "$WS/codetracer-trace-format-nim"   codetracer-trace-format-nim
stage_src "$WS/io-mon/src"                    io-mon/src
stage_src "$WS/nim-shm-gset/src"              nim-shm-gset/src
stage_src "$WS/nim-shm-queue/src"             nim-shm-queue/src
stage_src "$WS/codetracer/src"                codetracer/src
stage_src "$WS/reprobuild-ct-test-runner"     reprobuild-ct-test-runner
stage_src "$WS/reprobuild-test-adapters/src"  reprobuild-test-adapters/src
stage_src "$WS/runquota"                      runquota

# ---- 5. tree/libexec/reprobuild/nim --------------------------------
NIMPREFIX=$DEVDEPS/nim/2.2.8/prebuilt/nim-2.2.8
# ``bin/nim`` and NOT ``libexec/reprobuild/nim``: on Windows the layer
# puts helper executables in ``bin`` (there is no libexec convention),
# and ``reprobuildNimToolchainPrefixRel`` derives the toolchain root
# from that same rule.
NIMDEST="$PRE/tree/bin/nim"
[ -f "$NIMPREFIX/bin/nim.exe" ] || { echo "no Windows nim at $NIMPREFIX" >&2; exit 1; }
mkdir -p "$NIMDEST/bin"
cp "$NIMPREFIX/bin/nim.exe" "$NIMDEST/bin/nim.exe"
for d in lib config; do
  mkdir -p "$NIMDEST/$d"
  (cd "$NIMPREFIX/$d" && find . -type f -print) | while IFS= read -r f; do
    mkdir -p "$NIMDEST/$d/$(dirname "$f")"
    cp "$NIMPREFIX/$d/$f" "$NIMDEST/$d/$f"
  done
done

# ---- 6. tree/lib/repro/include -------------------------------------
# THE ONE THAT HAS NO WINDOWS SOURCE. BLAKE3_PREFIX / XXHASH_PREFIX /
# SQLITE_PREFIX / CLINGO_PREFIX all point at the package's private
# prefix, whose `include` directory the Linux staging fills from the
# three nixpkgs outputs the flake names. There is no such output on
# Windows and no blake3.h / clingo.h anywhere in the dev-deps tree --
# because the Windows build does not use them: it takes the
# vendored-C-source path (`-d:reproVendoredHash`).
#
# Deliberately NOT created empty. An empty `include` would satisfy
# `reprobuildShippedTreeDirs` and ship four wrapper variables pointing
# at a directory with nothing in it, which is exactly the defect
# ":the-payload:" closed for Linux.
echo "--- staged"
find "$PRE" -type f | wc -l
du -sk "$PRE/bin" "$PRE/lib" "$PRE/tree" 2>/dev/null || true

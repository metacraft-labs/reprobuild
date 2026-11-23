## Zig as the cross C toolchain of a cargo build.
##
## A Rust crate graph that cross-compiles for another Linux target needs a
## C compiler, a C++ compiler, an archiver and a linker for that target the
## moment one `*-sys` crate runs its build script (`openssl-sys`, `ring`,
## `aws-lc-sys`, `libsqlite3-sys`, …). Zig ships one driver that is all four
## for every target it knows, with its own musl and compiler-rt, so a single
## catalog package (`zig`) replaces a per-target GNU cross toolchain. This is
## the arrangement `cargo-zigbuild` automates; this module is the
## reprobuild-owned version of it, so that each recipe does not carry its own
## wrapper scripts (Language-Conventions/Rust.md §"Cross-compiling").
##
## ## What cargo needs, and why wrappers
##
## cargo and the `cc` crate find the target toolchain through environment
## variables keyed by the Rust triple: `CC_<triple>`, `CXX_<triple>`,
## `AR_<triple>`, `CARGO_TARGET_<TRIPLE>_LINKER` and
## `CARGO_TARGET_<TRIPLE>_RUSTFLAGS`. Each names ONE program with no
## arguments, while zig's driver needs `-target <zig target> -mcpu <cpu>` on
## every call. So each role is a two-line shell wrapper, written by the
## action `emitZigCrossWrappersAction` emits into the recipe's scratch tree,
## and the environment points at them. Three details of the wrappers are
## load-bearing and are the reason this is an adapter and not a recipe's
## `shell`:
##
## * `cc`/`c++` drop the `--target=<rust triple>` the `cc` crate appends:
##   zig's driver does not accept the Rust spelling, and `-target` below is
##   the authoritative one.
## * the linker drops rustc's self-contained musl CRT objects
##   (`…/self-contained/crt1.o`, `crti.o`, `crtn.o`, `crtbegin.o`,
##   `crtend.o`, `rcrt1.o`, `Scrt1.o`) and `-lgcc_s`: zig links its own musl
##   and compiler-rt, and rustc is told `-C link-self-contained=no` so it
##   does not insist. `-C target-feature=+crt-static` makes the result a
##   static executable, which is what a target without the matching libc on
##   disk needs.
## * `openssl-sys`'s build script emits `cargo:rustc-link-lib=static=atomic`
##   for OpenSSL's `linux-armv4` target. Zig provides atomics inside
##   compiler-rt and ships no `libatomic`, so the wrapper directory carries an
##   EMPTY `lib/libatomic.a` (made with `zig ar rc`) on the link path.
##
## ## Targets
##
## The table below maps a Rust target triple onto zig's target and the
## `-mcpu` baseline that every machine of that family executes. The ARMv7
## entry is Debian's `armhf` baseline (ARMv7-A, VFPv3-D16, Thumb-2), which is
## what a Raspberry Pi 2 runs. An unlisted triple is refused by name at
## emission time; adding one is a row here and nothing else.
##
## ## The adapter
##
## The table is also what makes this module a `CrossTarget` adapter
## (Reprobuild-Standard-Library §"`CrossTarget`"): `crossZigTarget(triple)`
## returns the interface record for a listed triple, and the active build
## context installs it when the solved `targetTriple` variant names one
## (`active_context.resolveCrossTarget`). A recipe then never spells the
## triple: `cargo_package()` reads `activeCrossTarget()` and, when it is this
## adapter's, carries `--target` and the zig environment on its own, so
## `repro build --target=armv7-unknown-linux-musleabihf <recipe>` is the
## whole of a cross build's authoring. The `cFlags` of the record are zig's
## driver arguments for the target, which is what a C-building recipe
## (`packages/source/openssl`) hands its own configure script as `CC`.

import std/[os, strutils, tables]

import repro_project_dsl

import ../interfaces/cross_target
import ./zig_0_13_arm_compiler_rt_symbols
# The wrapper edge's `sh` and `install-file` (the stdlib's GNU coreutils,
# for `rm` / `mkdir` / `chmod`), registered wherever the adapter is.
import ../packages/sh as zig_wrapper_sh
import ../packages/coreutils_install as zig_wrapper_coreutils
export cross_target

type
  ZigCrossTarget* = object
    ## One row of the target table.
    rustTriple*: string   ## cargo's `--target`
    zigTarget*: string    ## zig's `-target`
    mcpu*: string         ## zig's `-mcpu`, "" for the target's default
    opensslTarget*: string
      ## OpenSSL's `Configure` target for the family (`linux-armv4` is
      ## upstream's one 32-bit ARM target: it covers ARMv4 through ARMv7,
      ## selecting the instruction set from the compiler's flags).
    nimCpu*: string       ## nim's `--cpu:` for the family

const
  ZigCrossTargets* = [
    ZigCrossTarget(rustTriple: "armv7-unknown-linux-musleabihf",
                   zigTarget: "arm-linux-musleabihf",
                   mcpu: "generic+v7a+vfp3d16+thumb2",
                   opensslTarget: "linux-armv4",
                   nimCpu: "arm"),
    # The Raspberry Pi's own C library: what an object LD_PRELOADed into the
    # Pi's (glibc) processes must be built against, which the static-musl
    # row above cannot serve. zig links against its glibc ABI lists at the
    # pinned version (https://ziglang.org/download/0.13.0/release-notes.html#glibc),
    # and a binary built for version N runs on any glibc >= N.
    #
    # 2.38, MEASURED rather than chosen (2026-11-01, Debian trixie armhf
    # Packages index): the trixie libraries the appliance build links
    # require it -- libsqlite3-0 3.46.1-7+deb13u2 and libssl3t64's
    # libcrypto 3.5.7-1~deb13u2 reference GLIBC_2.38 (libcrypto through
    # `__isoc23_strtol`), libzstd1 1.5.7 only GLIBC_2.34. Bookworm's 2.36
    # cannot link them; trixie itself ships 2.41 (the Pi: 2.41-12+rpt1),
    # beyond zig 0.13's newest ABI list, 2.39, so 2.38 is the oldest
    # version that serves.
    ZigCrossTarget(rustTriple: "armv7-unknown-linux-gnueabihf",
                   zigTarget: "arm-linux-gnueabihf.2.38",
                   mcpu: "generic+v7a+vfp3d16+thumb2",
                   opensslTarget: "linux-armv4",
                   nimCpu: "arm"),
    ZigCrossTarget(rustTriple: "aarch64-unknown-linux-musl",
                   zigTarget: "aarch64-linux-musl",
                   mcpu: "",
                   opensslTarget: "linux-aarch64",
                   nimCpu: "arm64"),
    ZigCrossTarget(rustTriple: "x86_64-unknown-linux-musl",
                   zigTarget: "x86_64-linux-musl",
                   mcpu: "",
                   opensslTarget: "linux-x86_64",
                   nimCpu: "amd64"),
  ]

  ZigCrossAdapterPrefix* = "cross-zig-"
    ## `CrossTarget.name` of every record this adapter produces, followed
    ## by the Rust triple. Consumers that must know WHICH adapter filled the
    ## slot (cargo_package: "may I set the zig environment?") test the name
    ## through `isZigCrossTarget`, never the triple alone -- another
    ## adapter may answer for the same triple with another toolchain.

  ZigCrossScratchSubdir* = ".repro/build/cross"
    ## The per-target scratch root: `<projectRoot>/.repro/build/cross/<triple>/`,
    ## beside cargo's own scratch. The wrappers
    ## land in its `zig/` subdirectory (`zigCrossWrapperDir`): the rust-std
    ## fetch and the sysroot merge (`adapters/rust_target_sysroot`) write
    ## their own subdirectories beside it, and an edge may only remove what
    ## it owns -- the wrapper edge once cleared the whole triple directory
    ## and raced the fetch extracting next to it ("Directory not empty").

  ZigCrossWrapperSubdir* = "zig"

  ZigCrossRustflags* = "-C target-feature=+crt-static -C link-self-contained=no"
    ## See the module header: a static executable, linked by zig's musl.

  ZigCrossRemapTarget* = "/build"
    ## What the recipe's project root is spelled as inside the produced
    ## binary. rustc embeds the path of every source file in panic-location
    ## strings (and in debug info, when any), and a from-source recipe's
    ## sources live under its project root: the extracted tree and the
    ## vendored crates alike. Without `--remap-path-prefix` two builds of
    ## one recipe from two checkouts differ in those strings and nothing
    ## else (measured: 130 strings, 12 KB, for llm-api-proxy), and a
    ## digest pinned by a profile (`expectedOutputDigest`) would hold only
    ## for the checkout that produced it.

proc zigCrossTarget*(rustTriple: string): ZigCrossTarget =
  ## The table row for `rustTriple`, or a `ValueError` naming the triple and
  ## the triples the table has, so a typo is a refusal and not a build that
  ## fails three hundred crates in.
  for t in ZigCrossTargets:
    if t.rustTriple == rustTriple:
      return t
  var known: seq[string] = @[]
  for t in ZigCrossTargets:
    known.add(t.rustTriple)
  raise newException(ValueError,
    "cross_zig: no zig target is known for the Rust triple '" & rustTriple &
    "'; known: " & known.join(", ") & ". Add a row to ZigCrossTargets.")

proc zigCrossWrapperDir*(projectRoot, rustTriple: string): string =
  projectRoot / ZigCrossScratchSubdir / rustTriple / ZigCrossWrapperSubdir

proc cargoTripleEnvKey*(rustTriple: string): string =
  ## `armv7-unknown-linux-musleabihf` → `ARMV7_UNKNOWN_LINUX_MUSLEABIHF`, the
  ## form `CARGO_TARGET_<TRIPLE>_LINKER` takes.
  rustTriple.replace('-', '_').toUpperAscii()

proc ccTripleEnvKey*(rustTriple: string): string =
  ## `armv7-unknown-linux-musleabihf` → `armv7_unknown_linux_musleabihf`, the
  ## form the `cc` crate's `CC_<triple>` takes.
  rustTriple.replace('-', '_')

proc isZigCrossTriple*(triple: string): bool =
  ## Whether the table has a row for `triple`. The predicate the active
  ## build context consults before selecting this adapter.
  for t in ZigCrossTargets:
    if t.rustTriple == triple:
      return true
  false

proc zigDriverArgSeq*(t: ZigCrossTarget): seq[string] =
  ## zig's driver arguments for the target, one per element: what the
  ## wrappers below append, and what `CrossTarget.cFlags` carries.
  result = @["-target", t.zigTarget]
  if t.mcpu.len > 0:
    result.add("-mcpu=" & t.mcpu)

proc zigDriverArgs(t: ZigCrossTarget): string =
  zigDriverArgSeq(t).join(" ")

const
  ZigCrossCompilerRtMapName* = "compiler-rt-local.map"
    ## The version script beside the wrappers that makes compiler-rt local
    ## in a shared library (`zigCrossCompilerRtMap`).

proc zigArmCompilerRtSymbols*(): seq[string] =
  ## The global symbols of zig 0.13's compiler-rt for its 32-bit ARM
  ## targets (`zig_0_13_arm_compiler_rt_symbols`).
  @ZigArmCompilerRtSymbols

proc zigCrossCompilerRtMap*(t: ZigCrossTarget): string =
  ## The version script the `cc` / `c++` wrappers give a shared-library link
  ## for `t`, or "" when the row needs none.
  ##
  ## zig 0.13 links its compiler-rt into a 32-bit ARM shared library as
  ## weak, default-visibility symbols, so the library exports them, and a
  ## program linked against it imports the helpers from it instead of
  ## linking its own. Where the program then runs against another build of
  ## that soname -- the target system's own sqlite, under `--target` -- it
  ## does not load ("undefined symbol: __aeabi_uidiv"; reprobuild-pm issue
  ## 2026-11-02-zig-built-shared-libraries-export-compiler-rt-and-armv7-images-import-it).
  ## zig refuses `--exclude-libs`, so the symbols are named `local:`.
  ## Measured: the aarch64 and x86_64 musl rows export none of compiler-rt.
  if t.nimCpu != "arm":
    return ""
  result = "{\n  local:\n"
  for name in zigArmCompilerRtSymbols():
    result.add("    " & name & ";\n")
  result.add("};\n")

const
  ZigCrossCompilerRtMarker* =
    "# cross_zig: zig's compiler-rt is local in this version script"
    ## The line a version script carries when it was merged by
    ## `emitZigCrossVersionScriptAction`. The `cc` / `c++` wrappers accept a
    ## recipe's own version script for a shared-library link when it carries
    ## this line or makes every unlisted symbol local (`local: *;`), and
    ## refuse it otherwise.

const PrefixMapPrelude = """
# No build-host path in what this compile writes (Distribution-And-Packaging
# §5.3, the builder-path gate): __FILE__ names a store directory by its
# name without the hash, zig's prefix as `zig`, and the directory of every
# other absolute source file or `-I` directory -- and the working
# directory -- as `.`. Compiles only (-c / -S / -E): a link reads no source
# file, and clang warns about an unused -ffile-prefix-map. Debug info is a
# separate matter: zig compiles its own start-up objects with no flag of
# ours, so a build that ships its images links them without debug info.
compiling=0
maps=
# `-o -` is standard output to gcc and clang, and a file named `-` to zig
# 0.13 (`zig cc -E x.c -o -` writes ./-; `-o /dev/stdout` fails with
# AccessDenied). CMake's standard-library probe preprocesses that way. A
# preprocessing run drops it and prints; anything else is refused below.
pendo=0
tostdout=0
preprocess=0
addmap() {
  case " $maps " in *" $1 "*) ;; *) maps="$maps $1";; esac
}
storemap() {
  r="${1#/nix/store/}"
  top="${r%%/*}"
  addmap "-ffile-prefix-map=/nix/store/$top=${top#*-}"
}
"""

const PrefixMapScan =
  "  if [ $pendo = 1 ]; then\n" &
  "    pendo=0\n" &
  "    if [ \"$a\" = - ]; then tostdout=1; continue; fi\n" &
  "    set -- \"$@\" -o\n" &
  "  fi\n" &
  "  case \"$a\" in\n" &
  "    -o) pendo=1; continue;;\n" &
  "    -o-) tostdout=1; continue;;\n" &
  "    -E) preprocess=1;;\n" &
  "  esac\n" &
  "  case \"$a\" in\n" &
  "    -c|-S|-E) compiling=1;;\n" &
  "    /nix/store/*) storemap \"$a\";;\n" &
  "    -I/nix/store/*) storemap \"${a#-I}\";;\n" &
  "    -isystem/nix/store/*) storemap \"${a#-isystem}\";;\n" &
  "    /*.c|/*.cc|/*.cpp|/*.cxx|/*.S|/*.s) addmap \"-ffile-prefix-map=${a%/*}=.\";;\n" &
  "    -I/*) addmap \"-ffile-prefix-map=${a#-I}=.\";;\n" &
  "  esac\n"

const PrefixMapApply = """
[ $pendo = 1 ] && set -- "$@" -o
if [ $tostdout = 1 ] && [ $preprocess = 0 ]; then
  echo "zig cc: zig cannot write this output to standard output (-o -); name a file" >&2
  exit 1
fi
if [ $compiling = 1 ]; then
  z=$(command -v zig)
  set -- "$@" "-ffile-prefix-map=$PWD=." "-ffile-prefix-map=${z%/bin/zig}=zig" $maps
else
  # A link: zig ignores LIBRARY_PATH, which is how the engine hands a
  # consumer its `buildDeps:` libraries (it honours CPATH, their headers),
  # so each entry becomes a -L.
  rest="${LIBRARY_PATH:-}"
  while [ -n "$rest" ]; do
    d="${rest%%:*}"
    case "$rest" in *:*) rest="${rest#*:}";; *) rest=;; esac
    [ -n "$d" ] && set -- "$@" "-L$d"
  done
fi
"""

const CompilerRtWrapperTemplate = """
# A shared library would export zig's compiler-rt (weak, default
# visibility). A link without a version script of its own gets @MAP@;
# one with its own must already make compiler-rt local.
shared=0
own=
opaque=0
next=0
for a do
  shift
  if [ $next = 1 ]; then next=0; own="${a#-Wl,}"; fi
  case "$a" in
    -latomic|--target=*) continue;;
    -shared) shared=1;;
    -Wl,--version-script=*|-Wl,-version-script=*) own="${a#*=}";;
    -Wl,--version-script,*|-Wl,-version-script,*) own="${a#*-script,}";;
    -Wl,--version-script|-Wl,-version-script) next=1;;
    *version-script*) opaque=1;;
  esac
@SCAN@  set -- "$@" "$a"
done
covers() {
  inlocal=0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in *"@MARKER@"*) return 0;; esac
    case "$l" in
      *local:*) inlocal=1; l=" ${l#*local:}";;
      *global:*) inlocal=0;;
    esac
    if [ $inlocal = 1 ]; then
      case "$l" in '*;'*|*[[:space:]:]'*;'*) return 0;; esac
    fi
  done < "$1"
  return 1
}
if [ $shared = 1 ]; then
  if [ $opaque = 1 ]; then
    echo "zig cc (@TRIPLE@): this shared-library link names a version script in a form the wrapper cannot read; spell it -Wl,--version-script=<file>" >&2
    exit 1
  elif [ -z "$own" ]; then
    set -- "$@" "-Wl,--version-script=@MAP@" -Wl,--undefined-version
  elif ! covers "$own"; then
    echo "zig cc (@TRIPLE@): the version script $own leaves zig's compiler-rt exported from this shared library; make every unlisted symbol local (local: *;) or merge it with cross_zig's emitZigCrossVersionScriptAction" >&2
    exit 1
  else
    set -- "$@" -Wl,--undefined-version
  fi
fi
"""

proc zigCrossCompilerRtNamedNode*(t: ZigCrossTarget): string =
  ## The map of `zigCrossCompilerRtMap` as a NAMED version node, with the
  ## marker line, for appending to a recipe's own version script. zig hands
  ## the linker only the last `--version-script` of a link (measured, zig
  ## 0.13: a second script silently dropped the first one's `GLIBC_2.*`
  ## versions), so the two must be one file. An anonymous node cannot be
  ## combined with named ones, hence the name. "" when the row needs none.
  let map = zigCrossCompilerRtMap(t)
  if map.len == 0:
    return ""
  ZigCrossCompilerRtMarker & "\nZIG_COMPILER_RT_LOCAL " & map

proc zigCrossCc*(t: ZigCrossTarget): string =
  ## `zig cc` with the target's driver arguments, as ONE string: the form
  ## a configure script takes in `CC` (make expands `$(CC)` through the
  ## shell, so the arguments ride along). The wrappers exist for cargo,
  ## whose `CC_<triple>` must name a single program.
  "zig cc " & zigDriverArgs(t)

proc crossZigTarget*(rustTriple: string): CrossTarget =
  ## The `CrossTarget` record for a listed triple. Refuses an unlisted one
  ## the way `zigCrossTarget` does.
  let t = zigCrossTarget(rustTriple)
  let flags = zigDriverArgSeq(t)
  proc tripleAccess(): string = t.rustTriple
  proc hostPrefixAccess(): string =
    # zig is one driver for every target: no `<triple>-gcc` naming.
    ""
  proc spliceAccess(buildPkgs, hostPkgs, targetPkgs: seq[string]):
      SplicedPackageSet =
    SplicedPackageSet(buildPkgs: buildPkgs, hostPkgs: hostPkgs,
                      targetPkgs: targetPkgs)
  newCrossTarget(
    name = ZigCrossAdapterPrefix & t.rustTriple,
    triple = t.rustTriple,
    # zig carries its own musl and compiler-rt: there is no sysroot
    # directory to point at.
    sysroot = "",
    isNative = false,
    cFlags = flags,
    linkFlags = flags,
    binaryFormat = bfELF,
    pageSize = 4096,
    targetTriple = tripleAccess,
    hostPrefix = hostPrefixAccess,
    splice = spliceAccess)

proc isZigCrossTarget*(ct: CrossTarget): bool =
  ## Whether `ct` was produced by this adapter.
  ct != nil and (not ct.isNative) and ct.name.startsWith(ZigCrossAdapterPrefix)

proc isZigGlibcTarget*(t: ZigCrossTarget): bool =
  ## A row that links against glibc (`…-gnu…` zig target) rather than zig's
  ## static musl.
  "-gnu" in t.zigTarget

proc zigCrossWrapperScript*(role: string; t: ZigCrossTarget;
                            libDir: string): string =
  ## The text of one wrapper. `role` is `cc`, `c++`, `ar`, `ranlib` or
  ## `rust-linker`. `zig` is invoked by bare name: the recipe declares `zig`
  ## in `uses:` and cargo names it a sub-tool, so the engine puts its
  ## directory on the edge's PATH, and the script carries no absolute path
  ## of the machine that emitted it.
  case role
  of "ar":
    "#!/bin/sh\nexec zig ar \"$@\"\n"
  of "ranlib":
    "#!/bin/sh\nexec zig ranlib \"$@\"\n"
  of "cc", "c++":
    "#!/bin/sh\n" &
    "# zig " & role & " for " & t.rustTriple & ". The cc crate appends a\n" &
    "# clang-style --target=<rust triple> that zig's driver does not accept;\n" &
    "# -target below is the authoritative one, so drop it. -latomic is\n" &
    "# dropped too: zig ships no libatomic, and compiler-rt, which it links,\n" &
    "# provides the __atomic_* calls a 32-bit ARM link asks it for.\n" &
    PrefixMapPrelude &
    (if zigCrossCompilerRtMap(t).len == 0:
      "for a do\n" &
      "  shift\n" &
      "  case \"$a\" in -latomic|--target=*) continue;; esac\n" &
      PrefixMapScan &
      "  set -- \"$@\" \"$a\"\n" &
      "done\n"
    else:
      # zig hands the linker only the LAST `--version-script` of a link, so
      # the map cannot simply be added beside a recipe's own script: the
      # recipe's would be dropped. A shared-library link with no script of
      # its own gets the map. One with its own is accepted when that script
      # already makes compiler-rt local -- a wildcard `local: *;` (what
      # libtool generates), or the marker of `emitZigCrossVersionScriptAction`,
      # which merges a recipe's script with the map -- and is refused, by
      # name, otherwise. Shell builtins only: a wrapper consumer such as a
      # `nim.c` edge has `zig` and `sh` on its PATH and nothing else.
      # `--undefined-version` because a link need not pull in every listed
      # symbol.
      CompilerRtWrapperTemplate.multiReplace(
        ("@MAP@", libDir.parentDir / ZigCrossCompilerRtMapName),
        ("@MARKER@", ZigCrossCompilerRtMarker),
        ("@TRIPLE@", t.rustTriple), ("@SCAN@", PrefixMapScan))) &
    PrefixMapApply &
    "exec zig " & role & " " & zigDriverArgs(t) & " \"$@\"\n"
  of "rust-linker":
    "#!/bin/sh\n" &
    "# zig cc as rustc's linker for " & t.rustTriple & ". Drops what zig's\n" &
    "# driver rejects or provides itself: rustc's self-contained musl CRT\n" &
    "# objects (zig links its own musl) and -lgcc_s (zig links compiler-rt).\n" &
    "for a do\n" &
    "  shift\n" &
    "  case \"$a\" in\n" &
    "    */self-contained/crt1.o|*/self-contained/crti.o|" &
    "*/self-contained/crtn.o|*/self-contained/crtbegin.o|" &
    "*/self-contained/crtend.o|*/self-contained/rcrt1.o|" &
    "*/self-contained/Scrt1.o) continue;;\n" &
    # `-lgcc_s` is dropped for the musl rows only, where the measured links
    # (llm-api-proxy for armv7 musl, run on the Pi) need nothing from it:
    # zig links compiler-rt in its place. A glibc row gets no
    # such proof -- the catalog carries no rust-std for it, so no Rust link
    # has been measured -- and keeping the flag makes a Rust link for it
    # fail by name (zig ships no libgcc_s) instead of silently linking a
    # binary whose unwinder nobody checked.
    (if isZigGlibcTarget(t): "    --target=*) continue;;\n"
     else: "    -lgcc_s|--target=*) continue;;\n") &
    "  esac\n" &
    "  set -- \"$@\" \"$a\"\n" &
    "done\n" &
    "exec zig cc " & zigDriverArgs(t) & " -L\"" & libDir & "\" \"$@\"\n"
  else:
    raise newException(ValueError, "cross_zig: unknown wrapper role " & role)

const ZigCrossCmakeToolchainName* = "toolchain.cmake"

proc zigCrossCmakeToolchain*(t: ZigCrossTarget; wrapperDir: string): string =
  ## The CMake toolchain file for a zig target: the wrappers in
  ## `wrapperDir` as the compilers and archiver, the target named so CMake
  ## enters cross-compiling mode, and programs searched on the build host
  ## only (they run there). Libraries, headers and packages keep CMake's
  ## default search: a `buildDeps:` sibling's target mirror arrives on
  ## `CMAKE_PREFIX_PATH`, and the object check refuses a host library that
  ## found its way in anyway.
  ## https://cmake.org/cmake/help/latest/manual/cmake-toolchains.7.html#cross-compiling-for-linux
  let cpu = t.rustTriple.split('-')[0]
  proc q(path: string): string = "\"" & path.replace("\\", "/") & "\""
  "set(CMAKE_SYSTEM_NAME Linux)\n" &
    "set(CMAKE_SYSTEM_PROCESSOR " & cpu & ")\n" &
    "set(CMAKE_C_COMPILER " & q(wrapperDir / "cc") & ")\n" &
    "set(CMAKE_CXX_COMPILER " & q(wrapperDir / "c++") & ")\n" &
    "set(CMAKE_AR " & q(wrapperDir / "ar") & " CACHE FILEPATH \"\")\n" &
    "set(CMAKE_RANLIB " & q(wrapperDir / "ranlib") & " CACHE FILEPATH \"\")\n" &
    "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\n"

proc zigCrossRustflags*(remapRoot: string; rustTriple = ""): string =
  ## The target RUSTFLAGS: the static-musl flags for a musl row (none for a
  ## glibc row: zig cannot link glibc statically, and the binary loads the
  ## target's glibc), plus the path remap that makes the build independent
  ## of where the checkout is (`remapRoot`, the recipe's project root, is
  ## spelled `ZigCrossRemapTarget` in the binary). Empty `remapRoot` (no
  ## project root: interface extraction) adds no remap.
  let glibc = rustTriple.len > 0 and isZigCrossTriple(rustTriple) and
    isZigGlibcTarget(zigCrossTarget(rustTriple))
  result = if glibc: "" else: ZigCrossRustflags
  if remapRoot.len > 0:
    if result.len > 0: result.add(" ")
    result.add("--remap-path-prefix=" & remapRoot & "=" & ZigCrossRemapTarget)

proc zigCrossCargoEnv*(rustTriple, wrapperDir: string;
                       remapRoot = ""): seq[(string, string)] =
  ## The environment that points cargo, rustc and the `cc` crate at the
  ## wrappers in `wrapperDir`. Pure: a recipe or a test can read it without
  ## any file existing. `remapRoot` is the recipe's project root, remapped
  ## out of the binary (`zigCrossRustflags`).
  let cargoKey = cargoTripleEnvKey(rustTriple)
  let ccKey = ccTripleEnvKey(rustTriple)
  @[
    ("CC_" & ccKey, wrapperDir / "cc"),
    ("CXX_" & ccKey, wrapperDir / "c++"),
    ("AR_" & ccKey, wrapperDir / "ar"),
    ("RANLIB_" & ccKey, wrapperDir / "ranlib"),
    ("CARGO_TARGET_" & cargoKey & "_LINKER", wrapperDir / "rust-linker"),
    ("CARGO_TARGET_" & cargoKey & "_RUSTFLAGS",
      zigCrossRustflags(remapRoot, rustTriple)),
  ]

proc zigCrossWrappersActionId*(packageName, rustTriple: string): string =
  var sanitized = ""
  for ch in packageName & "-" & rustTriple:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  "zig-cross-wrappers-" & sanitized

proc emitZigCrossWrappersAction*(projectRoot, packageName,
                                 rustTriple: string): BuildActionDef =
  ## The action that writes the wrappers and the empty `libatomic.a` into
  ## `zigCrossWrapperDir`. Its declared output is the directory, so a cargo
  ## edge that reads the wrappers orders after it by depending on it.
  ##
  ## Cacheable: the inputs are the script text (in the argv) and `zig`
  ## (a tool identity ref); the outputs are a pure function of both.
  ##
  ## One edge per package and triple: a package with several zig-built
  ## edges (reprobuild's own `.#apps`, one `nim.c` per image) gets the edge
  ## registered by the first and the same edge back for the rest, so the
  ## graph never holds two nodes with one id.
  let id = zigCrossWrappersActionId(packageName, rustTriple)
  for existing in registeredBuildActions():
    if existing.id == id:
      return existing
  let t = zigCrossTarget(rustTriple)
  let dir = zigCrossWrapperDir(projectRoot, rustTriple)
  let libDir = dir / "lib"
  proc q(value: string): string =
    "'" & value.replace("'", "'\\''") & "'"
  var script = "set -e; rm -rf " & q(dir) & "; mkdir -p " & q(libDir) & "; "
  for role in ["cc", "c++", "ar", "ranlib", "rust-linker"]:
    script.add("printf '%s' " & q(zigCrossWrapperScript(role, t, libDir)) &
      " > " & q(dir / role) & "; chmod 755 " & q(dir / role) & "; ")
  # The CMake toolchain file beside the wrappers it names
  # (`cmake_package` under a zig target).
  script.add("printf '%s' " & q(zigCrossCmakeToolchain(t, dir)) & " > " &
    q(dir / ZigCrossCmakeToolchainName) & "; ")
  # The version script the `cc` / `c++` wrappers name for a shared-library
  # link, on the rows that need one (`zigCrossCompilerRtMap`).
  let compilerRtMap = zigCrossCompilerRtMap(t)
  if compilerRtMap.len > 0:
    script.add("printf '%s' " & q(compilerRtMap) & " > " &
      q(dir / ZigCrossCompilerRtMapName) & "; ")
  # An empty archive: `zig ar rc` with no members writes a valid, empty
  # `ar` file, which the linker accepts for `-latomic` and resolves nothing
  # from (zig's compiler-rt provides the atomics).
  script.add("zig ar rc " & q(libDir / "libatomic.a"))
  buildAction(
    id = id,
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[dir],
    cacheable = true,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "zig-cross.wrappers",
    # The script's tools are the adapter's, not the recipe's: `sh`, and
    # `install-file` (the stdlib's GNU coreutils, whose directory carries
    # `rm` / `mkdir` / `chmod`; `printf` is the shell's builtin). Declaring
    # `zig` adds both to the recipe's
    # `nativeBuildDeps:` (`zigCrossAutoInjectShellTools` in
    # repro_project_dsl), so they resolve, or are refused by name, like any
    # declared tool (Reprobuild-Standard-Library.md, `cross_zig`).
    toolIdentityRefs = @["sh", "install-file", "zig"])

const MergeVersionScriptTemplate = """
set -e
first=
while IFS= read -r l || [ -n "$l" ]; do
  t="${l#"${l%%[![:space:]]*}"}"
  case "$t" in ''|'#'*|'/*'*) continue;; esac
  first="$t"
  break
done < @OWN@
case "$first" in
  '{'*)
    echo "cross_zig: @OWN@ is an anonymous version script, which cannot be merged with a named node; give it local: *; instead" >&2
    exit 1;;
esac
{
  while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; done < @OWN@
  printf '\n%s' @NODE@
} > @OUT@
"""

proc emitZigCrossVersionScriptAction*(projectRoot, packageName, rustTriple,
                                      ownScript, output: string): BuildActionDef =
  ## The action that writes `output`: the recipe's own version script
  ## `ownScript` followed by `zigCrossCompilerRtNamedNode`, so that a
  ## shared-library link that needs its own version nodes (io-mon's shim
  ## versions `dlsym`) also makes zig's compiler-rt local. The `cc` / `c++`
  ## wrappers accept the result by its marker line. zig hands the linker
  ## only one version script, which is why the two are merged into a file
  ## rather than passed side by side.
  ##
  ## An anonymous script (`{ ... };` with no version name) cannot be
  ## combined with a named node, and is refused; such a script hides
  ## compiler-rt itself when it ends in `local: *;`, which the wrappers
  ## accept as it is.
  ##
  ## Shell builtins only, like the wrappers. Refuses a row that needs no
  ## map, so a caller does not merge where nothing is exported.
  let t = zigCrossTarget(rustTriple)
  let node = zigCrossCompilerRtNamedNode(t)
  if node.len == 0:
    raise newException(ValueError, "cross_zig: " & rustTriple &
      " exports none of zig's compiler-rt; there is nothing to merge")
  proc q(value: string): string =
    "'" & value.replace("'", "'\\''") & "'"
  let script = MergeVersionScriptTemplate.multiReplace(
    ("@OWN@", q(ownScript)), ("@NODE@", q(node)), ("@OUT@", q(output)))
  var sanitized = ""
  for ch in packageName & "-" & extractFilename(output):
    sanitized.add(if ch.isAlphaNumeric or ch in {'-', '_', '.'}: ch else: '_')
  buildAction(
    id = "zig-cross-version-script-" & sanitized & "-" & rustTriple,
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[ownScript],
    outputs = @[output],
    cacheable = true,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "zig-cross.version-script",
    toolIdentityRefs = @["sh"])

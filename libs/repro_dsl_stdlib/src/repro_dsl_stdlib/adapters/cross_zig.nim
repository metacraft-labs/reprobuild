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
    ## beside cargo's own scratch so `repro clean` takes it too. The wrappers
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
    "# -target below is the authoritative one, so drop it.\n" &
    "for a do\n" &
    "  shift\n" &
    "  case \"$a\" in --target=*) continue;; esac\n" &
    "  set -- \"$@\" \"$a\"\n" &
    "done\n" &
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
    "    -lgcc_s|--target=*) continue;;\n" &
    "  esac\n" &
    "  set -- \"$@\" \"$a\"\n" &
    "done\n" &
    "exec zig cc " & zigDriverArgs(t) & " -L\"" & libDir & "\" \"$@\"\n"
  else:
    raise newException(ValueError, "cross_zig: unknown wrapper role " & role)

proc zigCrossRustflags*(remapRoot: string): string =
  ## The target RUSTFLAGS: the static-musl flags, plus the path remap that
  ## makes the build independent of where the checkout is (`remapRoot`,
  ## the recipe's project root, is spelled `ZigCrossRemapTarget` in the
  ## binary). Empty `remapRoot` (no project root: interface extraction)
  ## adds no remap.
  result = ZigCrossRustflags
  if remapRoot.len > 0:
    result.add(" --remap-path-prefix=" & remapRoot & "=" & ZigCrossRemapTarget)

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
    ("CARGO_TARGET_" & cargoKey & "_RUSTFLAGS", zigCrossRustflags(remapRoot)),
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
  let t = zigCrossTarget(rustTriple)
  let dir = zigCrossWrapperDir(projectRoot, rustTriple)
  let libDir = dir / "lib"
  proc q(value: string): string =
    "'" & value.replace("'", "'\\''") & "'"
  var script = "set -e; rm -rf " & q(dir) & "; mkdir -p " & q(libDir) & "; "
  for role in ["cc", "c++", "ar", "ranlib", "rust-linker"]:
    script.add("printf '%s' " & q(zigCrossWrapperScript(role, t, libDir)) &
      " > " & q(dir / role) & "; chmod 755 " & q(dir / role) & "; ")
  # An empty archive: `zig ar rc` with no members writes a valid, empty
  # `ar` file, which the linker accepts for `-latomic` and resolves nothing
  # from (zig's compiler-rt provides the atomics).
  script.add("zig ar rc " & q(libDir / "libatomic.a"))
  buildAction(
    id = zigCrossWrappersActionId(packageName, rustTriple),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[dir],
    cacheable = true,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "zig-cross.wrappers",
    toolIdentityRefs = @["sh", "rm", "mkdir", "printf", "chmod", "zig"])

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

import std/[os, strutils, tables]

import repro_project_dsl

type
  ZigCrossTarget* = object
    ## One row of the target table.
    rustTriple*: string   ## cargo's `--target`
    zigTarget*: string    ## zig's `-target`
    mcpu*: string         ## zig's `-mcpu`, "" for the target's default

const
  ZigCrossTargets* = [
    ZigCrossTarget(rustTriple: "armv7-unknown-linux-musleabihf",
                   zigTarget: "arm-linux-musleabihf",
                   mcpu: "generic+v7a+vfp3d16+thumb2"),
    ZigCrossTarget(rustTriple: "aarch64-unknown-linux-musl",
                   zigTarget: "aarch64-linux-musl",
                   mcpu: ""),
    ZigCrossTarget(rustTriple: "x86_64-unknown-linux-musl",
                   zigTarget: "x86_64-linux-musl",
                   mcpu: ""),
  ]

  ZigCrossScratchSubdir* = ".repro/build/cross"
    ## Where the wrappers land: `<projectRoot>/.repro/build/cross/<triple>/`,
    ## beside cargo's own scratch so `repro clean` takes it too.

  ZigCrossRustflags* = "-C target-feature=+crt-static -C link-self-contained=no"
    ## See the module header: a static executable, linked by zig's musl.

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
  projectRoot / ZigCrossScratchSubdir / rustTriple

proc cargoTripleEnvKey*(rustTriple: string): string =
  ## `armv7-unknown-linux-musleabihf` → `ARMV7_UNKNOWN_LINUX_MUSLEABIHF`, the
  ## form `CARGO_TARGET_<TRIPLE>_LINKER` takes.
  rustTriple.replace('-', '_').toUpperAscii()

proc ccTripleEnvKey*(rustTriple: string): string =
  ## `armv7-unknown-linux-musleabihf` → `armv7_unknown_linux_musleabihf`, the
  ## form the `cc` crate's `CC_<triple>` takes.
  rustTriple.replace('-', '_')

proc zigDriverArgs(t: ZigCrossTarget): string =
  result = "-target " & t.zigTarget
  if t.mcpu.len > 0:
    result.add(" -mcpu=" & t.mcpu)

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

proc zigCrossCargoEnv*(rustTriple, wrapperDir: string): seq[(string, string)] =
  ## The environment that points cargo, rustc and the `cc` crate at the
  ## wrappers in `wrapperDir`. Pure: a recipe or a test can read it without
  ## any file existing.
  let cargoKey = cargoTripleEnvKey(rustTriple)
  let ccKey = ccTripleEnvKey(rustTriple)
  @[
    ("CC_" & ccKey, wrapperDir / "cc"),
    ("CXX_" & ccKey, wrapperDir / "c++"),
    ("AR_" & ccKey, wrapperDir / "ar"),
    ("RANLIB_" & ccKey, wrapperDir / "ranlib"),
    ("CARGO_TARGET_" & cargoKey & "_LINKER", wrapperDir / "rust-linker"),
    ("CARGO_TARGET_" & cargoKey & "_RUSTFLAGS", ZigCrossRustflags),
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

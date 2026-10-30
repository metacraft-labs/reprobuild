## `cargo_package` cross-compiles a workspace member for another target.
##
## THE NEED. A Rust service for a 32-bit ARM add-on host (agent-harbor's
## `llm-api-proxy` for rpi2) is built on an x86-64 host. That takes
## `--target` on both cargo steps, `-p` + `--path crates/<member>` because
## the source is a virtual workspace, and a C toolchain for the target that
## the `*-sys` crates' build scripts reach through `CC_<triple>` and that
## rustc links through `CARGO_TARGET_<TRIPLE>_LINKER`. Before this, none of
## those had a typed surface (reprobuild-pm issue
## 2026-10-30-cargo-package-cannot-cross-compile-a-workspace-member-for-armv7).
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. The cargo typed
## tool and the constructor are driven as a recipe drives them, with no
## provider project root (so no fetch and no vendor edge: the constructor
## takes its `else` branches, which is also what a recipe compiled for
## interface extraction sees), and the assertions read the rendered argv and
## the recorded environment of the actions the registry holds. The wrapper
## texts are checked as text: they are what a shell will run, so the filter
## they implement is visible in them.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/adapters/cross_zig
import repro_dsl_stdlib/constructors/cargo_package
import repro_dsl_stdlib/packages/cargo as cargo_module

const
  Triple = "armv7-unknown-linux-musleabihf"
  cargoTool = cargo_module.cargo

proc argvOf(act: BuildActionDef): seq[string] =
  for arg in act.call.arguments:
    var values = @[arg.encodedValue]
    if arg.nimType == "seq[string]":
      values = arg.encodedValue.split('\x1f')
      if values.len == 1 and values[0].len == 0:
        values = @[]
    for value in values:
      case arg.format
      of cafConcat:
        result.add(arg.alias & value)
      else:
        if arg.alias.len == 0:
          result.add(value)
        elif arg.nimType == "bool":
          result.add(arg.alias)
        else:
          result.add(arg.alias)
          result.add(value)

proc containsPair(argv: seq[string]; flag, value: string): bool =
  for i in 0 ..< argv.len - 1:
    if argv[i] == flag and argv[i + 1] == value:
      return true

proc envValue(act: BuildActionDef; name: string): string =
  for (k, v) in act.env:
    if k == name: return v
  ""

suite "cargo typed tool: --target":

  test "cargo.build and cargo.install carry --target":
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true, target = Triple)
    discard cargoTool.install(locked = true, target = Triple, root = "r")
    let recorded = registeredBuildActions()
    check recorded.len == 2
    for act in recorded:
      check argvOf(act).containsPair("--target", Triple)

  test "an omitted target emits no flag":
    # Every existing cargo edge goes through this wrapper; a flag that
    # appeared by default would change every fingerprint for nothing.
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true)
    discard cargoTool.install(locked = true, root = "r")
    for act in registeredBuildActions():
      check "--target" notin argvOf(act)

suite "cross_zig: the target table and the environment":

  test "the armv7 row is Debian's armhf baseline":
    let t = zigCrossTarget(Triple)
    check t.zigTarget == "arm-linux-musleabihf"
    check t.mcpu == "generic+v7a+vfp3d16+thumb2"

  test "an unknown triple is refused by name, with the known ones":
    expect ValueError:
      discard zigCrossTarget("mips-unknown-linux-gnu")
    try:
      discard zigCrossTarget("mips-unknown-linux-gnu")
    except ValueError as e:
      check "mips-unknown-linux-gnu" in e.msg
      check Triple in e.msg

  test "the environment names every role cargo and cc read":
    let env = zigCrossCargoEnv(Triple, "/w")
    var m: seq[string] = @[]
    for (k, v) in env: m.add(k & "=" & v)
    check "CC_armv7_unknown_linux_musleabihf=/w/cc" in m
    check "CXX_armv7_unknown_linux_musleabihf=/w/c++" in m
    check "AR_armv7_unknown_linux_musleabihf=/w/ar" in m
    check "CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=/w/rust-linker" in m
    check ("CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS=" &
      "-C target-feature=+crt-static -C link-self-contained=no") in m

  test "the wrappers filter what zig's driver rejects":
    let t = zigCrossTarget(Triple)
    let cc = zigCrossWrapperScript("cc", t, "/w/lib")
    check "--target=*) continue" in cc
    check "exec zig cc -target arm-linux-musleabihf -mcpu=generic+v7a+vfp3d16+thumb2" in cc
    let ld = zigCrossWrapperScript("rust-linker", t, "/w/lib")
    for obj in ["crt1.o", "crti.o", "crtn.o", "crtbegin.o", "crtend.o",
                "rcrt1.o", "Scrt1.o"]:
      check ("*/self-contained/" & obj) in ld
    check "-lgcc_s" in ld
    check "-L\"/w/lib\"" in ld
    check zigCrossWrapperScript("ar", t, "/w/lib") == "#!/bin/sh\nexec zig ar \"$@\"\n"
    # No path of the emitting machine: zig is found on the edge's PATH.
    for role in ["cc", "c++", "ar", "ranlib", "rust-linker"]:
      check "/nix/store" notin zigCrossWrapperScript(role, t, "/w/lib")

  test "the wrapper action writes the five roles and the empty libatomic":
    resetBuildActionRegistry()
    let act = emitZigCrossWrappersAction("/proj", "pkg", Triple)
    check act.id == "zig-cross-wrappers-pkg-" & Triple
    # argv is `sh -c <script>`; the recorded call also carries the cwd as a
    # trailing argument, so take the operand of `-c` rather than the last.
    let argv = argvOf(act)
    let script = argv[argv.find("-c") + 1]
    for role in ["cc", "c++", "ar", "ranlib", "rust-linker"]:
      check ("/proj/.repro/build/cross/" & Triple & "/" & role & "'") in script
    check "zig ar rc '/proj/.repro/build/cross/" & Triple & "/lib/libatomic.a'" in script
    check act.outputs == @["/proj" / ".repro/build/cross" / Triple]
    check "zig" in act.toolIdentityRefs

suite "cargo_package: target, zig cross toolchain, workspace member":

  test "the cargo edges carry --target, -p, the member path and the zig env":
    resetBuildActionRegistry()
    setCurrentOwningPackageOverride("probeSource")
    defer: clearCurrentOwningPackageOverride()
    let res = cargo_package(target = Triple, zigCross = true,
                            package = "llm-api-proxy",
                            installPath = "crates/llm-api-proxy")
    let build = argvOf(res.compileEdge)
    check build.containsPair("--target", Triple)
    check build.containsPair("--package", "llm-api-proxy")
    let install = argvOf(res.installEdge)
    check install.containsPair("--target", Triple)
    check install.containsPair("--path", "src" / "crates/llm-api-proxy")
    for edge in [res.compileEdge, res.installEdge]:
      check edge.envValue("CC_armv7_unknown_linux_musleabihf").endsWith("/cc")
      check edge.envValue("CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER")
        .endsWith("/rust-linker")
      check edge.envValue("CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS") ==
        ZigCrossRustflags

  test "a recipe's own extraEnv survives beside the zig env":
    resetBuildActionRegistry()
    setCurrentOwningPackageOverride("probeSource")
    defer: clearCurrentOwningPackageOverride()
    let res = cargo_package(target = Triple, zigCross = true,
      extraEnv = @[("OPENSSL_NO_VENDOR", "1")])
    check res.compileEdge.envValue("OPENSSL_NO_VENDOR") == "1"
    check res.compileEdge.envValue("CC_armv7_unknown_linux_musleabihf").len > 0

  test "a native build is unchanged":
    resetBuildActionRegistry()
    setCurrentOwningPackageOverride("probeSource")
    defer: clearCurrentOwningPackageOverride()
    let res = cargo_package()
    check "--target" notin argvOf(res.compileEdge)
    check "--package" notin argvOf(res.compileEdge)
    check argvOf(res.installEdge).containsPair("--path", "src")
    check res.compileEdge.envValue("CC_armv7_unknown_linux_musleabihf") == ""

  test "zigCross without a target is refused":
    resetBuildActionRegistry()
    setCurrentOwningPackageOverride("probeSource")
    defer: clearCurrentOwningPackageOverride()
    expect ValueError:
      discard cargo_package(zigCross = true)

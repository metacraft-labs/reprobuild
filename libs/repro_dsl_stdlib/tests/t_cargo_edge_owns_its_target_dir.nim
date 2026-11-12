## The cargo edges own their target directory.
##
## THE DEFECT (reprobuild-pm issue 2026-11-10-cargo-build-edge-assumes-target-
## sits-at-the-action-working-directory). `cargo.build` hard-coded where cargo
## puts its output: it passed no `--target-dir`, and it declared its depfile
## globs as `target/{debug,release}/deps/*.d` relative to the action's working
## directory. Two things follow when that assumption is false:
##
##   * An ambient `CARGO_TARGET_DIR` (or `CARGO_BUILD_TARGET_DIR`) moves cargo's
##     output away from the declared one, so a cache miss fails with "exited 0
##     but did not produce its declared output".
##   * A crate below the working directory (`--manifest-path rust/Cargo.toml`
##     from the repository root) writes `rust/target/debug/deps/*.d`, which the
##     globs never match; the edge then reads no depfile and reports
##     up-to-date after a real source change.
##
## WHY ARGV AND THE POLICY ARE THE CONTRACT. cargo ranks `--target-dir` above
## `CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET_DIR` and `build.target-dir` in a
## config file
## (https://doc.rust-lang.org/cargo/reference/config.html#buildtarget-dir), so
## an explicit flag on every edge makes the declared output, the depfiles and
## the action key agree whatever the host sets. What the flag and the globs say
## is therefore all that can be asserted without a cargo binary, and it is
## what the engine and cargo each act on; nothing here is mocked.

import std/[os, strutils, unittest]

import repro_project_dsl
# Aliased because the `package cargo:` block emits a const named `cargo`,
# which a plain import would shadow with the module name.
import repro_dsl_stdlib/packages/cargo as cargo_module

const cargoTool = cargo_module.cargo

proc argvOf(act: BuildActionDef): seq[string] =
  ## Rendered the way the engine renders a recorded CLI call; the same logic as
  ## the helper in `t_cargo_package_bin_selectors.nim`.
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

proc lastRecorded(): BuildActionDef =
  let recorded = registeredBuildActions()
  check recorded.len == 1
  recorded[^1]

proc targetDirOf(argv: seq[string]): string =
  for i in 0 ..< argv.len - 1:
    if argv[i] == "--target-dir":
      return argv[i + 1]

proc globsOf(act: BuildActionDef): seq[string] =
  check act.dependencyPolicy.kind == bdpMakeDepfile
  act.dependencyPolicy.depfiles

suite "cargo edges own their target directory":

  test "cargo.build: a crate below the working directory gets its own depfile globs":
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true,
      manifestPath = "rust/Cargo.toml")
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "rust/target"
    check act.globsOf == @["rust/target/debug/*.d",
                           "rust/target/release/*.d"]

  test "cargo.build: no manifest path means the working directory's target":
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true)
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "target"
    check act.globsOf == @["target/debug/*.d", "target/release/*.d"]

  test "cargo.build: an explicit target dir wins, in the flag and in the globs":
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true,
      manifestPath = "rust/Cargo.toml", targetDir = "out/cargo")
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "out/cargo"
    check act.globsOf == @["out/cargo/debug/*.d", "out/cargo/release/*.d"]

  test "cargo.build: a --target triple's artefacts are one level down":
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true, manifestPath = "rust/Cargo.toml",
      target = "armv7-unknown-linux-musleabihf")
    check lastRecorded().globsOf == @[
      "rust/target/armv7-unknown-linux-musleabihf/debug/*.d",
      "rust/target/armv7-unknown-linux-musleabihf/release/*.d"]

  test "cargo.build: the target dir does not depend on the ambient environment":
    # The point of the explicit flag: the action is spelled the same on a host
    # that exports CARGO_TARGET_DIR (high-mem-server does, per runner) as on
    # one that does not, so the cache key cannot differ between them.
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true, manifestPath = "rust/Cargo.toml")
    let plain = argvOf(lastRecorded())
    putEnv("CARGO_TARGET_DIR", "/build/cargo/runner-1")
    putEnv("CARGO_BUILD_TARGET_DIR", "/build/cargo/runner-2")
    defer:
      delEnv("CARGO_TARGET_DIR")
      delEnv("CARGO_BUILD_TARGET_DIR")
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true, manifestPath = "rust/Cargo.toml")
    let withAmbient = argvOf(lastRecorded())
    check withAmbient == plain
    check targetDirOf(withAmbient) == "rust/target"

  test "cargo.build: a policy the caller supplies is kept":
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true, manifestPath = "rust/Cargo.toml",
      dependencyPolicy = makeDepfilePolicy(depfiles = ["custom/*.d"]))
    check lastRecorded().globsOf == @["custom/*.d"]

  test "cargo.test: the globs follow the manifest's directory":
    resetBuildActionRegistry()
    discard cargoTool.test(manifestPath = "rust/Cargo.toml", noRun = true)
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "rust/target"
    check act.globsOf == @["rust/target/debug/deps/*.d",
                           "rust/target/release/deps/*.d"]

  test "cargo.test: an explicit target dir wins":
    resetBuildActionRegistry()
    discard cargoTool.test(manifestPath = "rust/Cargo.toml", noRun = true,
      targetDir = "out/cargo")
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "out/cargo"
    check act.globsOf == @["out/cargo/debug/deps/*.d",
                           "out/cargo/release/deps/*.d"]

  test "cargo.install: the target dir follows the crate path":
    resetBuildActionRegistry()
    discard cargoTool.install(locked = true, path = "rust/crate",
      root = "stage/usr")
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "rust/crate/target"
    check act.globsOf == @["rust/crate/target/debug/*.d",
                           "rust/crate/target/release/*.d"]

  test "cargo.install: an explicit target dir wins":
    resetBuildActionRegistry()
    discard cargoTool.install(locked = true, path = "rust/crate",
      root = "stage/usr", targetDir = "out/cargo")
    let act = lastRecorded()
    check targetDirOf(argvOf(act)) == "out/cargo"
    check act.globsOf == @["out/cargo/debug/*.d", "out/cargo/release/*.d"]

  test "CargoTestBinary.run: the globs follow the binary's deps directory":
    resetBuildActionRegistry()
    let binary = CargoTestBinary(
      path: "rust/target/debug/deps/freya_nim_shim-0123456789abcdef")
    discard binary.run()
    check lastRecorded().globsOf == @["rust/target/debug/deps/*.d"]

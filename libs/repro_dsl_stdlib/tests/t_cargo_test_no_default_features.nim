## `cargo.test` must be able to test the feature set `cargo.build` builds.
##
## `build` and `install` accepted `noDefaultFeatures`; `test` did not, although
## `cargo test --no-default-features` is an ordinary cargo invocation. A crate
## whose default features are host-specific therefore could not declare a test
## edge matching its build edge, and `codetracer-python-recorder/repro.nim` --
## which does exactly that -- failed to compile against the stdlib with a type
## mismatch on its `cargo.test(...)` call.
##
## As in `t_nim_c_cpu_flag.nim`, the assertions read the rendered ARGV rather
## than the wrapper's parameters: cargo only does what it is told on the command
## line, so the contract is the flag reaching argv.

import std/[os, strutils, unittest]

import repro_project_dsl
# Aliased for the same reason `t_nim_c_cpu_flag.nim` aliases `nim`: the
# `package cargo:` block emits a const named `cargo`, which a plain import
# would shadow with the module name.
import repro_dsl_stdlib/packages/cargo as cargo_module

const cargoTool = cargo_module.cargo

proc argvOf(act: BuildActionDef): seq[string] =
  ## Rendered the way the engine renders a recorded CLI call; the same logic as
  ## the helper in `t_nim_c_cpu_flag.nim`.
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
  ## `cargo.test` returns a typed `CargoTestEdge`, which does not expose the
  ## recorded call. The registry holds the `BuildActionDef` the engine will
  ## actually run, which is the more honest thing to assert on anyway.
  let recorded = registeredBuildActions()
  check recorded.len == 1
  recorded[^1]

suite "cargo.test accepts noDefaultFeatures":

  test "noDefaultFeatures = true reaches argv as --no-default-features":
    resetBuildActionRegistry()
    discard cargoTool.test(
      manifestPath = "Cargo.toml",
      noRun = true,
      noDefaultFeatures = true)
    check "--no-default-features" in argvOf(lastRecorded())

  test "an omitted noDefaultFeatures emits no flag":
    # The default must stay invisible: every existing cargo test edge goes
    # through this wrapper, and a changed argv changes the action fingerprint
    # and invalidates the cache for nothing.
    resetBuildActionRegistry()
    discard cargoTool.test(
      manifestPath = "Cargo.toml",
      noRun = true)
    check "--no-default-features" notin argvOf(lastRecorded())

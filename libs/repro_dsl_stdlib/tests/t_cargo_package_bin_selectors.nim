## `cargo.build` and `cargo.test` must be able to select one workspace member
## crate and one binary.
##
## The root manifest of a virtual workspace has no `[package]`, so a bare
## `cargo build` builds every member. A recipe that wants a granular edge per
## artifact -- one member crate, one binary -- needs `--package` / `--bin` on
## the typed surface; without them it has to spell the selection through a
## verbatim `shell()`, or settle for one coarse whole-workspace edge.
##
## The kwarg is named `package` although `package` is also the DSL macro that
## declares a package (`package cargo:` in the wrapper module). The macro is
## only ever invoked as a block statement, and a named argument is matched by
## identifier, so the two cannot meet; this test compiling is the proof.
##
## As in `t_cargo_test_no_default_features.nim`, the assertions read the
## rendered ARGV: cargo only does what it is told on the command line.

import std/[strutils, unittest]

import repro_project_dsl
# Aliased because the `package cargo:` block emits a const named `cargo`,
# which a plain import would shadow with the module name.
import repro_dsl_stdlib/packages/cargo as cargo_module

const cargoTool = cargo_module.cargo

proc argvOf(act: BuildActionDef): seq[string] =
  ## Rendered the way the engine renders a recorded CLI call; the same logic as
  ## the helper in `t_cargo_test_no_default_features.nim`.
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
  ## The registry holds the `BuildActionDef` the engine will actually run.
  let recorded = registeredBuildActions()
  check recorded.len == 1
  recorded[^1]

proc containsPair(argv: seq[string]; flag, value: string): bool =
  for i in 0 ..< argv.len - 1:
    if argv[i] == flag and argv[i + 1] == value:
      return true

suite "cargo package / bin selectors":

  test "cargo.build: package and bin reach argv as --package / --bin":
    resetBuildActionRegistry()
    discard cargoTool.build(
      locked = true,
      package = "trace_formatter",
      bin = "ct-format")
    let argv = argvOf(lastRecorded())
    check argv.containsPair("--package", "trace_formatter")
    check argv.containsPair("--bin", "ct-format")

  test "cargo.build: omitted selectors emit no flag":
    # The default must stay invisible: every existing cargo build edge goes
    # through this wrapper, and a changed argv changes the action fingerprint
    # and invalidates the cache for nothing.
    resetBuildActionRegistry()
    discard cargoTool.build(locked = true)
    let argv = argvOf(lastRecorded())
    check "--package" notin argv
    check "--bin" notin argv

  test "cargo.test: package and bin reach argv as --package / --bin":
    resetBuildActionRegistry()
    discard cargoTool.test(
      manifestPath = "Cargo.toml",
      noRun = true,
      package = "trace_formatter",
      bin = "ct-format")
    let argv = argvOf(lastRecorded())
    check argv.containsPair("--package", "trace_formatter")
    check argv.containsPair("--bin", "ct-format")

  test "cargo.test: omitted selectors emit no flag":
    resetBuildActionRegistry()
    discard cargoTool.test(manifestPath = "Cargo.toml", noRun = true)
    let argv = argvOf(lastRecorded())
    check "--package" notin argv
    check "--bin" notin argv

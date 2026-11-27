## The engine's encoder of a `create-action` record (`createActionRecord`)
## and its parser (`parseCreatedActionSpec`) are inverse, and the action the
## engine builds from a parsed record has the key the emitter computed with
## `createdAction` from the same spec.
##
## That equality is what lets a graph-production edge state, ahead of the
## engine, which cache key each action it writes will have: the cargo plan's
## units edge builds its unit actions with `createdAction` and writes
## `createActionRecord` of the same specs. A field the encoder dropped would
## give the engine a different action under the same id.
##
## Pure functions; no mocks.

import std/[json, sequtils, strutils, unittest]

import repro_build_engine
import repro_core/input_check_policy

proc fullSpec(): CreatedActionSpec =
  ## Every field away from its default.
  result = initCreatedActionSpec("cargo.rustc/demo@1.0.0-0123456789abcdef",
    ["/toolchain/bin/rustc", "--crate-name", "demo", "src/lib.rs"])
  result.cwd = "/work/ws"
  result.inputs = @["/store/a.rmeta", "src/lib.rs"]
  result.outputs = @["/out/demo/libdemo.rlib"]
  result.optionalOutputs = @["/out/demo/extra"]
  result.deps = @["cargo.rustc/a@1.0.0-aaaaaaaaaaaaaaaa"]
  result.env = @["CARGO_PKG_NAME=demo", "PATH=/toolchain/bin"]
  result.envPassthrough = @["TMPDIR"]
  result.isolateHostEnvironment = true
  result.scratchDirs = @["/out/demo/incremental"]
  result.targetNames = @["default"]
  result.pool = "compile"
  result.poolUnits = 2'u32
  result.cpuMilli = 1500'u32
  result.cpuMinMilli = 500'u32
  result.cpuPreferredMilli = 1000'u32
  result.widthFlag = "-j"
  result.commandStatsId = "rust.rustc-member"
  result.cacheable = true
  result.actionCachePolicy = ffpHybrid
  result.policyKind = CreatedActionAutomaticMonitor

suite "create-action records round-trip":

  test "every field survives encode then parse":
    let spec = fullSpec()
    check parseCreatedActionSpec(createActionRecord(spec)) == spec

  test "a depfile policy survives too":
    var spec = fullSpec()
    spec.policyKind = CreatedActionMakeDepfile
    spec.policyDepfiles = @["/out/demo/demo.d"]
    check parseCreatedActionSpec(createActionRecord(spec)) == spec

  test "defaults are left out of the record and come back as defaults":
    let spec = initCreatedActionSpec("bare", ["/bin/true"])
    let record = createActionRecord(spec)
    check parseJson(record).keys.toSeq() == @["id", "argv"]
    check parseCreatedActionSpec(record) == spec

  test "the parsed record builds the emitter's action, key included":
    let lock = lockIdentityOutsideSolvedGraph()
    let spec = fullSpec()
    let emitted = createdAction(spec, lock)
    let parsed = createdAction(parseCreatedActionSpec(
      createActionRecord(spec)), lock)
    check parsed.weakFingerprint == emitted.weakFingerprint
    check parsed.argv == emitted.argv
    check parsed.env == emitted.env
    check parsed.scratchDirs == spec.scratchDirs
    check parsed.targetNames == spec.targetNames
    check parsed.isolateHostEnvironment
    check parsed.actionCachePolicy == ffpHybrid

  test "the key moves with the lock the producer is governed by":
    # Named-Lock-Files §4.1: a created action is built under its producer's
    # lock, so an emitter must compute keys under that identity.
    let spec = fullSpec()
    let a = createdAction(spec, lockIdentityOutsideSolvedGraph())
    let b = createdAction(spec, LockIdentity("blake3:" & '0'.repeat(64)))
    check a.weakFingerprint != b.weakFingerprint

  test "the encoder refuses what the parser would refuse":
    var spec = initCreatedActionSpec("c", ["/bin/true"])
    spec.cacheable = true            # cacheable with no dependency policy
    expect ValueError:
      discard createActionRecord(spec)
    spec.policyKind = CreatedActionAutomaticMonitor
    spec.env = @["NOEQUALS"]
    expect ValueError:
      discard createActionRecord(spec)

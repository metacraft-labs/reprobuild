## The rustc wrapper never changes what is built: the small, self-contained
## counterpart of `t_rqe_cg3_wrapper_is_transparent` (which builds
## agent-harbor's workspace and needs that checkout and the network). This
## case is an ADDITIONAL one, not a replacement: it runs wherever cargo and
## rustc do, on the five-unit project the other wrapper cases use (three
## libraries, a build script and a binary), so a host that cannot reach the
## large tree still checks the same two oracles.
##
## Two builds of the same project, from one path, at one target directory
## path, each starting from an empty target directory:
##
##   A. cargo with a logging `RUSTC_WRAPPER` only. The logger records, per
##      unit, the exact arguments cargo handed it, and runs rustc unchanged.
##   B. cargo under `runquota run` with `repro-rustc-wrapper` as
##      `RUSTC_WRAPPER` and the same logger behind it. The logger now sees the
##      arguments AFTER the wrapper.
##
## (1) The argument lines of A and B are equal, unit for unit. (2) The final
## binary of A is byte-identical to B's. The wrapper must also have reported
## (otherwise B would show only that a wrapper that does nothing does
## nothing): the wrapper's own log names every unit B compiled as reported.
##
## macOS detail. A debug binary linked on macOS records the modification time
## of every object file it was linked from (the `N_OSO` debug-map entries), so
## two builds made at different times differ in those bytes whatever the
## wrapper does. The project is therefore built with debuginfo off
## (`CARGO_PROFILE_DEV_DEBUG=0` for both builds), which leaves no such entry;
## the compile arguments are unchanged by it (it is part of both builds).
##
## NO MOCKS: real cargo and rustc, the real wrapper, the real `runquota` and
## `runquotad`.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_cargo_edge/rustc_args
import rqe_m15_width_fixture
import rqe_cg3_fixture

const
  BudgetMilli = 4000
  Width = 4

proc finalBinary(targetDir: string): string =
  ## The binary crate's executable in the profile directory.
  targetDir / "debug" / "cg3_app"

suite "the rustc wrapper is transparent (fixture crates)":

  test "test_rqe_cg3_wrapper_is_transparent_fixture_crates: the five-unit " &
      "project built with and without the wrapper yields the same " &
      "compiler arguments and a byte-identical binary":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let runquotaBin = requireRunQuotaCliBin(repoRoot)
    let cargo = findExe("cargo")
    require cargo.len > 0 and findExe("rustc").len > 0

    let scratch = createTempDir("rqe-cg3-transparent-fx-", "")
    defer: removeDir(scratch)
    let project = scratch / "project"
    createDir(project)
    writeDelegatedCargoProject(project)
    let targetDir = scratch / "target"
    let cargoHome = scratch / "cargo-home"
    let logger = scratch / "unit-logger"
    writeUnitLogger(logger)
    let logA = scratch / "without.log"
    let logB = scratch / "with.log"
    let wrapperLog = scratch / "wrapper.log"
    let cargoArgs = @["build", "--locked", "--offline", "--target-dir",
      targetDir]

    proc run(cmd: CmdSpec): string =
      let res = runShell(cmd, project, timeoutMs = 1_500_000)
      checkpoint res.output
      require res.code == 0
      res.output

    # A: without the wrapper. -j is the width the lease below grants B, so
    # the two builds differ in nothing but the wrapper.
    discard run(shellCommand(@[cargo] & cargoArgs & @["-j", $Width],
      env = [("CARGO_HOME", cargoHome), ("RUSTC_WRAPPER", logger),
             ("CARGO_PROFILE_DEV_DEBUG", "0"),
             ("CARGO_EDGE_UNIT_LOG", logA)]))
    require fileExists(finalBinary(targetDir))
    let keptA = scratch / "cg3_app.without"
    copyFile(finalBinary(targetDir), keptA)

    # B starts from an empty target directory.
    removeDir(targetDir)
    var daemon = startPrivateDaemon(repoRoot, BudgetMilli,
      observationDb = scratch / "observations.db")
    defer: daemon.stop()
    discard run(shellCommand(@[runquotaBin, "run", "--width", $Width & ":" &
        $Width, "--stats-key", "rqe-cg3/transparent-fixture", "--"] &
      @[cargo] & cargoArgs,
      env = [("CARGO_HOME", cargoHome), ("RUSTC_WRAPPER", wrapper),
             ("REPRO_RUSTC_WRAPPER_INNER", logger),
             ("CARGO_PROFILE_DEV_DEBUG", "0"),
             ("REPRO_RUSTC_WRAPPER_LOG", wrapperLog),
             ("CARGO_EDGE_UNIT_LOG", logB)]))
    require fileExists(finalBinary(targetDir))

    # (1) The compiler received the same arguments, unit for unit.
    let unitsA = readUnitLog(logA)
    let unitsB = readUnitLog(logB)
    checkpoint "units compiled: " & $unitsA.len & " without, " & $unitsB.len &
      " with the wrapper"
    require unitsA.len >= 5
    check unitsB.len == unitsA.len
    for i in 0 ..< min(unitsA.len, unitsB.len):
      if unitsA[i] != unitsB[i]:
        checkpoint "first difference at unit " & unitsA[i].crate & ":\n  " &
          unitsA[i].args.replace("\x1f", " ") & "\n  " &
          unitsB[i].args.replace("\x1f", " ")
        check unitsA[i] == unitsB[i]
        break

    # (2) The final binary is the same bytes.
    check readFile(finalBinary(targetDir)) == readFile(keptA)

    # The wrapper reported: its own log (`REPRO_RUSTC_WRAPPER_LOG`) names every
    # unit B compiled as reported to the daemon. (Without this the case would
    # show only that a wrapper that does nothing does nothing.) What the
    # daemon then stored is `t_rqe_cg3_per_crate_totals_learned`'s subject.
    # NOT ASSERTED HERE, on purpose: on macOS a `runquota run` build whose
    # five units report as sub-leases leaves only the LAST unit's execution in
    # the observation store, with no dropped row counted. That does not clear
    # with time (polled for 10 s) or change with the width, so it is a defect
    # of the daemon's capture, not of this case, and is recorded as an open
    # issue against RunQuota. Asserting the table here would make this case
    # fail for a reason that is not the wrapper's transparency.
    var reported: seq[string]
    for line in readFile(wrapperLog).splitLines:
      let fields = line.split('\t')
      if fields.len == 2 and fields[1].startsWith("reported"):
        reported.add fields[0]
    var compiled: seq[string]
    for unit in unitsB:
      let words = unit.args.split('\x1f').filterIt(it.len > 0)
      let parsed = rustcUnitOf(words[1 .. ^1])
      # A build script's own probe compiles are logged too but are not units
      # of the graph: the wrapper does not report them.
      if parsed.isUnit and parsed.unit.crateName notin compiled:
        compiled.add parsed.unit.crateName
    checkpoint "units: " & $compiled & ", reported: " & $reported
    check compiled.len >= 5
    for crate in compiled:
      check crate in reported

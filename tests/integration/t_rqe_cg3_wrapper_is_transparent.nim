## The rustc wrapper never changes what is built.
##
## THE CONTRACT. `repro-rustc-wrapper` is installed in front of rustc to report
## each compiled unit's totals. It must change nothing about the compile: the
## arguments rustc receives are the ones cargo gave, byte for byte, in the same
## order (`--extern` order, `-C` flags, `--cfg`, `--check-cfg`), and so the
## final binaries are the same bytes.
##
## HOW IT IS OBSERVED. agent-harbor's workspace (a real, large cargo workspace:
## about 285 members and 1700 packages, with registry and git dependencies) is
## built twice, from one checkout at one target directory path, with a bounded
## set of its binary crates (`-p`), `--locked` and the profile `dev`:
##
##   A. cargo with a logging `RUSTC_WRAPPER` only. The logger records, per
##      unit, the exact arguments cargo handed it, and runs rustc unchanged.
##   B. cargo under `runquota run`, so that the unit reports are really taken
##      (the wrapper finds `RUNQUOTA_PARENT_LEASE`), with `repro-rustc-wrapper`
##      as `RUSTC_WRAPPER` and the same logger behind it as the inner command.
##      The logger now sees the arguments AFTER the wrapper.
##
## Two oracles: (1) the logged argument lines of A and B are equal, unit for
## unit; (2) every final binary of A is byte-identical to the one B produced.
## The wrapper must also have reported (otherwise B would prove only that a
## wrapper that does nothing does nothing): every unit B compiled has an entry
## in the daemon's statistics table.
##
## A wrapper that reorders `--extern` fails (1) at once, whether or not rustc
## would have produced different bytes (it can, for a crate that names the same
## extern twice, and the argument lines show the reorder either way); the
## mutation was applied and the case observed to fail.
##
## THE TREE. The checkout is read only: the build writes its target directory
## and the cargo home under a scratch directory, and `--locked` refuses to touch
## `Cargo.lock`. `REPRO_CARGO_EDGE_AH_TREE` names a prepared checkout (and
## `REPRO_CARGO_EDGE_CARGO_HOME` a cargo home to reuse); without them the case makes a
## detached worktree of the agent-harbor sibling checkout at its `origin/agents`
## with the `platform` submodule, builds in it and removes it. It needs the
## network for the registry and git dependencies, and fails (not skips) when
## the checkout cannot be made.
##
## NO MOCKS: real cargo and rustc on a real workspace, the real wrapper, the
## real `runquota` and `runquotad`.

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_cargo_edge/rustc_args
import rqe_m15_width_fixture
import rqe_cg3_fixture

const
  BudgetMilli = 4000
  Width = 4
  BoundedPackages = ["ah-device-id", "ah-cloud-adapter-noop",
    "review-conformance"]

proc git(dir: string; args: openArray[string]): string =
  let res = runShell(shellCommand(@["git", "-C", dir] & @args), dir)
  checkpoint res.output
  require res.code == 0
  res.output

proc finalBinaries(targetDir: string): seq[string] =
  ## The executables in the profile directory: what cargo links out for a
  ## binary crate (`deps/` and everything else is intermediate).
  for path in walkFiles(targetDir / "debug" / "*"):
    let perms = getFilePermissions(path)
    if fpUserExec in perms and not path.endsWith(".d") and
        not path.endsWith(".so") and not path.endsWith(".rlib"):
      result.add path
  result.sort()

proc samplesOf(output: string): int =
  ## `<key>: <bytes> bytes over <N> samples (...)` -> N, or -1 when the key is
  ## not resident ("not resident (ask over the socket)").
  for line in output.splitLines:
    let words = line.splitWhitespace
    for i in 0 ..< words.len - 2:
      if words[i] == "over" and words[i + 2] == "samples":
        try:
          return parseInt(words[i + 1])
        except ValueError:
          discard
  -1

suite "the rustc wrapper is transparent":

  test "test_rqe_cg3_wrapper_is_transparent: agent-harbor's workspace built " &
      "with and without the wrapper yields byte-identical final binaries":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let runquotaBin = requireRunQuotaCliBin(repoRoot)
    let cargo = findExe("cargo")
    require cargo.len > 0 and findExe("rustc").len > 0

    let scratch = createTempDir("rqe-cg3-transparent-", "")
    defer: removeDir(scratch)

    # The checkout and the cargo home.
    var tree = getEnv("REPRO_CARGO_EDGE_AH_TREE")
    var madeWorktree = false
    let sibling = repoRoot.parentDir / "ah" / "agent-harbor"
    if tree.len == 0:
      require dirExists(sibling / ".git") or fileExists(sibling / ".git")
      tree = scratch / "agent-harbor"
      discard git(sibling, ["worktree", "add", "--detach", tree,
        "origin/agents"])
      madeWorktree = true
      discard git(tree, ["submodule", "update", "--init", "--depth", "1",
        "platform"])
    defer:
      if madeWorktree:
        discard git(sibling, ["worktree", "remove", "--force", tree])
    let cargoHome =
      if getEnv("REPRO_CARGO_EDGE_CARGO_HOME").len > 0: getEnv("REPRO_CARGO_EDGE_CARGO_HOME")
      else: scratch / "cargo-home"
    let targetDir = scratch / "target"
    let treeStatusBefore = git(tree, ["status", "--porcelain"])

    let logger = scratch / "unit-logger"
    writeUnitLogger(logger)
    let logA = scratch / "without.log"
    let logB = scratch / "with.log"

    var packages: seq[string]
    for name in BoundedPackages: packages.add ["-p", name]
    let cargoArgs = @["build", "--locked", "--target-dir", targetDir] &
      packages

    proc run(cmd: CmdSpec): string =
      let res = runShell(cmd, tree, timeoutMs = 3_000_000)
      checkpoint res.output
      require res.code == 0
      res.output

    # A: without the wrapper. -j is the width the lease below grants B, so
    # the two builds differ in nothing but the wrapper.
    discard run(shellCommand(@[cargo] & cargoArgs & @["-j", $Width],
      env = [("CARGO_HOME", cargoHome), ("RUSTC_WRAPPER", logger),
             ("CARGO_EDGE_UNIT_LOG", logA)]))
    let binariesA = finalBinaries(targetDir)
    require binariesA.len >= BoundedPackages.len
    let keptA = scratch / "binaries-without"
    createDir(keptA)
    for path in binariesA: copyFile(path, keptA / extractFilename(path))

    # B starts from an empty target directory.
    removeDir(targetDir)
    var daemon = startPrivateDaemon(repoRoot, BudgetMilli,
      observationDb = scratch / "observations.db")
    defer: daemon.stop()
    discard run(shellCommand(@[runquotaBin, "run", "--width", $Width & ":" &
        $Width, "--stats-key", "rqe-cg3/transparent", "--"] &
      @[cargo] & cargoArgs,
      env = [("CARGO_HOME", cargoHome), ("RUSTC_WRAPPER", wrapper),
             ("REPRO_RUSTC_WRAPPER_INNER", logger),
             ("CARGO_EDGE_UNIT_LOG", logB)]))
    let binariesB = finalBinaries(targetDir)

    # (1) The compiler received the same arguments, unit for unit.
    let unitsA = readUnitLog(logA)
    let unitsB = readUnitLog(logB)
    checkpoint "units compiled: " & $unitsA.len & " without, " & $unitsB.len &
      " with the wrapper"
    require unitsA.len > 20
    check unitsB.len == unitsA.len
    for i in 0 ..< min(unitsA.len, unitsB.len):
      if unitsA[i] != unitsB[i]:
        checkpoint "first difference at unit " & unitsA[i].crate & ":\n  " &
          unitsA[i].args.replace("\x1f", " ") & "\n  " &
          unitsB[i].args.replace("\x1f", " ")
        check unitsA[i] == unitsB[i]
        break

    # (2) The final binaries are the same bytes.
    check binariesB.mapIt(extractFilename(it)) ==
      binariesA.mapIt(extractFilename(it))
    for path in binariesB:
      let name = extractFilename(path)
      check fileExists(keptA / name)
      check readFile(path) == readFile(keptA / name)

    # The wrapper reported: every compiled unit has an entry in the
    # statistics table. (Without this the case would show only that a wrapper
    # that does nothing does nothing.)
    var keys: seq[string]
    for unit in unitsB:
      let words = unit.args.split('\x1f').filterIt(it.len > 0)
      # The first word is the rustc path; the rest are rustc's arguments.
      let parsed = rustcUnitOf(words[1 .. ^1])
      # A build script's own probe compiles are logged too (they went through
      # the wrapper) but are not units of the graph: the wrapper does not
      # report them.
      if not parsed.isUnit: continue
      let key = statsKeyOf(parsed.unit)
      if key notin keys: keys.add key
    var missing: seq[string]
    # The daemon publishes what it has recorded in batches; allow it a moment.
    for attempt in 0 ..< 40:
      missing = @[]
      for key in keys:
        let res = runShell(shellCommand([runquotaBin, "stats-table", key]),
          repoRoot)
        if samplesOf(res.output) < 1: missing.add key
      if missing.len == 0: break
      sleep(250)
    checkpoint "keys: " & $keys.len & ", without an entry: " & $missing
    check keys.len > 0
    check missing.len == 0

    # The checkout was only read.
    check git(tree, ["status", "--porcelain"]) == treeStatusBefore

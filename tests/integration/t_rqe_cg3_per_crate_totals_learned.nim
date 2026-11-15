## The rustc wrapper reports each compiled unit's totals to RunQuota
## under a per-crate statistics key, so RunQuota learns the shape of every
## crate's compile.
##
## THE CONTRACT (Build-Engine-And-Scheduler.md, Integration
## tiers, Cargo). The engine installs `repro-rustc-wrapper` as `RUSTC_WRAPPER`
## of a sized cargo action. For every unit cargo compiles, the wrapper takes a
## sub-lease of the action's own lease (`RUNQUOTA_PARENT_LEASE`), runs rustc
## unchanged, and finishes the sub-lease with the totals `wait4` returned,
## under the key `rustc/<crate>/<kind>/o<opt level>`. Nothing is asked of
## cargo or rustc.
##
## HOW IT IS OBSERVED. A real `repro build` of a delegated cargo project (three
## library crates, a build script and a binary: five units) with the wrapper
## switched on, under a real `runquotad` that captures finished leases into a
## private observation store. After two builds that recompile the libraries
## and the binary, `runquota stats-table <key>` is asked for each unit:
##
##   * every one of the five units has an entry, and no other key does (a probe
##     call, a crate that was never compiled, the edge's own action);
##   * the four units compiled twice report two samples, the build script,
##     compiled once, reports one. That is "learned": the second build added
##     to what the first reported rather than replacing it.
##
## NO MOCKS: real repro, real runquotad, real cargo and rustc, the real wrapper
## binary.

import std/[json, os, strutils, tables, tempfiles, unittest]

import repro_test_support
import rqe_m15_width_fixture
import rqe_cg3_fixture

const
  BudgetMilli = 4000
  UnitKeys = [
    "rustc/liba/lib/o3", "rustc/libb/lib/o3", "rustc/libc/lib/o3",
    "rustc/cg3_app/bin/o3", "rustc/build_script_build/bin/o0"]

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

suite "the rustc wrapper reports per-crate totals":

  test "test_rqe_cg3_per_crate_totals_learned: after two builds the " &
      "statistics table has one entry per compiled unit":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let runquotaBin = requireRunQuotaCliBin(repoRoot)
    require findExe("cargo").len > 0 and findExe("rustc").len > 0

    let scratch = createTempDir("rqe-cg3-totals-", "")
    defer: removeDir(scratch)
    let project = scratch / "project"
    createDir(project)
    writeDelegatedCargoProject(project)

    var daemon = startPrivateDaemon(repoRoot, BudgetMilli,
      observationDb = scratch / "observations.db")
    defer: daemon.stop()

    proc build() =
      let args = @[reproBin, "build", project,
        "--daemon=off", "--tool-provisioning=path",
        "--work-root=" & (scratch / "work"),
        "--action-cache-root=" & (scratch / "cache"),
        "--progress=quiet"]
      let res = runShell(shellCommand(args,
        env = [("REPRO_RUSTC_WRAPPER", "on"),
               ("REPRO_RUSTC_WRAPPER_PATH", wrapper)]),
        repoRoot, timeoutMs = 1_500_000)
      checkpoint res.output
      require res.code == 0

    proc table(key: string): string =
      let res = runShell(shellCommand([runquotaBin, "stats-table", key]),
        repoRoot)
      checkpoint res.output
      res.output

    # Nothing is known before the first build.
    for key in UnitKeys:
      check samplesOf(table(key)) == -1

    build()
    # Recompile the libraries and the binary, not the build script.
    for name in ["liba", "libb", "libc"]:
      writeFile(project / name / "src" / "lib.rs",
        "pub fn id() -> &'static str { \"" & name & "2\" }\n")
    writeFile(project / "src" / "main.rs",
      "fn main() { println!(\"{} {} {}!\", liba::id(), libb::id(), " &
      "libc::id()); }\n")
    build()

    # The daemon publishes what it has recorded; allow it a moment.
    var learned: array[UnitKeys.len, int]
    for attempt in 0 ..< 40:
      for i, key in UnitKeys: learned[i] = samplesOf(table(key))
      if learned[0] == 2 and learned[1] == 2 and learned[2] == 2 and
          learned[3] == 2 and learned[4] >= 1:
        break
      sleep(250)
    checkpoint "samples per unit: " & $learned
    for i in 0 .. 3:
      check learned[i] == 2
    # The build script is compiled by the first build only.
    check learned[4] == 1

    # No other key has an entry: a probe is not a unit, and a crate that was
    # not compiled does not exist.
    check samplesOf(table("rustc/___/bin/o0")) == -1
    check samplesOf(table("rustc/not_a_crate/lib/o3")) == -1

    # What was reported are TOTALS, not a bare mention: each recorded
    # execution of a unit carries the CPU time, the largest resident set and
    # the duration the kernel returned when the wrapper reaped rustc.
    let exported = runShell(shellCommand([runquotaBin, "stats", "export"]),
      repoRoot)
    require exported.code == 0
    var rows = initTable[string, int]()
    for line in exported.output.splitLines:
      if not line.startsWith("{"): continue
      let row = parseJson(line)
      let key = row["command_stats_id"].getStr
      if not key.startsWith("rustc/"): continue
      rows[key] = rows.getOrDefault(key) + 1
      check row["cpu_user_millis"].getInt + row["cpu_sys_millis"].getInt > 0
      check row["peak_rss_bytes"].getInt > 0
      check row["duration_millis"].getInt > 0
      check row["exit_status"].getInt == 0
    checkpoint "recorded executions per unit: " & $rows
    for i, key in UnitKeys:
      check rows.getOrDefault(key) == (if i == 4: 1 else: 2)
    # Nothing else under the wrapper's prefix: one entry per unit.
    check rows.len == UnitKeys.len

  test "the units are reported through the launcher when the client takes " &
      "profiles":
    # With the client-side `profiles` and `tree-sampling` measurements on
    # (`RUNQUOTA_MEASUREMENT`, RunQuota's own switch) the wrapper launches the
    # compile through `runquota_process`, which samples the tree it launched
    # while it waits, within the overhead gate's budget. The report must still arrive:
    # one execution per unit, with totals. WHAT THIS DOES NOT SHOW is the CPU
    # profile itself: the observation store records it, but nothing reads it
    # back yet (`runquota stats export` has no profile column), so that part is
    # reported as not verified rather than asserted.
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let runquotaBin = requireRunQuotaCliBin(repoRoot)
    require findExe("cargo").len > 0 and findExe("rustc").len > 0

    let scratch = createTempDir("rqe-cg3-profiles-", "")
    defer: removeDir(scratch)
    let project = scratch / "project"
    createDir(project)
    writeDelegatedCargoProject(project)
    var daemon = startPrivateDaemon(repoRoot, BudgetMilli,
      observationDb = scratch / "observations.db")
    defer: daemon.stop()

    let wrapperLog = scratch / "wrapper.log"
    let args = @[reproBin, "build", project,
      "--daemon=off", "--tool-provisioning=path",
      "--work-root=" & (scratch / "work"),
      "--action-cache-root=" & (scratch / "cache"),
      "--progress=quiet"]
    let res = runShell(shellCommand(args,
      env = [("REPRO_RUSTC_WRAPPER", "on"),
             ("REPRO_RUSTC_WRAPPER_PATH", wrapper),
             ("RUNQUOTA_MEASUREMENT", "profiles=on,tree-sampling=on"),
             ("REPRO_RUSTC_WRAPPER_LOG", wrapperLog)]),
      repoRoot, timeoutMs = 1_500_000)
    checkpoint res.output
    require res.code == 0

    # The wrapper's own log says which path it took for each unit: the case
    # shows the launcher path, not just that a report arrived.
    let logged = readFile(wrapperLog).splitLines
    var throughLauncher = 0
    for line in logged:
      if line.endsWith("\treported: through the launcher"): inc throughLauncher
      check not line.contains("unreported")
    check throughLauncher == UnitKeys.len

    var rows = initTable[string, int]()
    for attempt in 0 ..< 40:
      rows = initTable[string, int]()
      let exported = runShell(shellCommand([runquotaBin, "stats", "export"]),
        repoRoot)
      for line in exported.output.splitLines:
        if not line.startsWith("{"): continue
        let row = parseJson(line)
        let key = row["command_stats_id"].getStr
        if key.startsWith("rustc/"):
          rows[key] = rows.getOrDefault(key) + 1
          check row["duration_millis"].getInt >= 0
          check row["exit_status"].getInt == 0
      if rows.len == UnitKeys.len: break
      sleep(250)
    checkpoint "recorded executions per unit: " & $rows
    for key in UnitKeys:
      check rows.getOrDefault(key) == 1
    check rows.len == UnitKeys.len

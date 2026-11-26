## The record-only graph-production edge, run through the engine, plans a
## workspace with build scripts and a proc-macro and compiles nothing.
##
## THE CONTRACT. The edge `cargoPlanEdge` declares (`repro_cargo_edge/
## plan_edge`) runs cargo's whole schedule with the rustc wrapper in record
## mode. Run as an ordinary monitored edge of the engine, it must: start no
## rustc other than probes; run no build script (the recording stub runs in
## each one's place); open no network connection; leave the placeholders the
## record mode writes (empty files, and the stub as each build script's
## executable) in its scratch target directory and nowhere else; and write
## the plan, its one declared output, naming none of the record run's own
## files.
##
## HOW IT IS OBSERVED. A five-package workspace (`rqe_cg5_plan_fixture`:
## `links`, a build-dependency with a build script of its own, a proc-macro,
## per-unit features) whose build
## scripts, if they ever run, connect to a loopback listener, leave a marker
## and panic. The edge runs through the real engine with the graph-built
## monitor, in a closed environment whose proxy variables all name the same
## listener, so a request cargo made for the network would arrive there too.
## The compiler the edge is given is a logging shim in front of the real
## rustc, so "no rustc but probes" is read from what reached the compiler,
## judged by a probe shape this case defines.
##
## Positive controls, each shown before it is relied on: the listener counts
## a direct connection; cargo, in the same closed environment and asked for
## something that needs the network (`cargo search`), does reach the
## listener through the proxy variables; and the monitor saw the edge read
## the workspace's `Cargo.toml` (the edge really ran monitored).
##
## REGISTRY CRATES. `app` also depends on two crates.io crates, `regbs` (with
## a build script that must not run either) and `regleaf`, made by `cargo
## package` and fetched by the production fetch edges from a mirror directory
## into a private store root; the edge is given their prefixes. Every unit of
## theirs must be in the plan, named by its prefix (working directory,
## manifest directory, a crate root that is a file of the prefix), and each
## prefix must be exactly as it was (entries, sizes, permissions, times): the
## vendor directory links to it and nothing writes into it.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's reports): mapping a vendor entry to a prefix path guessed from
## the crate's name and version instead of the prefix the run linked it to
## (the registry checks fail); dropping the mapping (the edge fails on a
## scratch path); making a prefix writable while the vendor entry is made
## (the prefix check fails); letting the wrapper run rustc for a build-script
## unit (record
## mode classifying `build_script_*` lines as probes) compiles and runs the
## build scripts: the listener counts their connections, the markers appear,
## the logger sees non-probe lines, and the edge fails. Refusing again a run
## whose environment carries a slot (the derivation before the fix of a
## build-dependency with a build script) fails the edge on `mid`'s run.
##
## NO MOCKS: real cargo and rustc, the real wrapper, engine and monitor. The
## logging `RUSTC` is an observer that runs the real compiler unchanged.

import std/[net, os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cargo_edge/[cargo_plan, plan_edge, record_mode]
import repro_test_support

import ./rqe_cg5_plan_fixture

proc devEnvOf(pairs: openArray[(string, string)]): seq[string] =
  for (name, value) in pairs: result.add name & "=" & value

suite "the record-only graph-production edge":

  test "test_rqe_cg5_record_run_compiles_nothing: the edge plans a " &
      "workspace with build scripts and a proc-macro, runs no build " &
      "script, starts no rustc but probes and opens no connection":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let wrapper = requireBinary(
      reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
      "reprobuild.apps.repro-rustc-wrapper")
    let cargo = findExe("cargo")
    let realRustc = findExe("rustc")
    require cargo.len > 0 and realRustc.len > 0
    let work = createTempDir("cg5-record-run-", "")
    defer: removeTestTree(work)   # the store's prefixes are read-only
    let ws = work / "ws"
    let markers = work / "markers"
    writePlanWorkspace(ws, smMustNotRun, registry = true)
    let reg = setupRegistry(work, smMustNotRun)
    var prefixesBefore: seq[seq[string]]
    for c in reg.crates:
      # The fetch publishes a prefix read-only.
      check fpUserWrite notin getFilePermissions(c.prefix)
      prefixesBefore.add treeSnapshot(c.prefix)

    let listener = startListener()
    defer: listener.stop()
    # Positive control 1: the listener counts a connection.
    block:
      let probe = newSocket()
      probe.connect("127.0.0.1", Port(listener.port))
      probe.close()
      require listener.accepted == 1
      listener.resetCount()

    var envPairs = @[("PATH", storeOnlyPath()),
      ("TMPDIR", getEnv("TMPDIR", work)),
      ("CG5_NET_PROBE", listener.address), ("CG5_MARKER_DIR", markers)]
    envPairs.add listener.proxyEnv
    # Positive control 2: cargo in this environment, asked for something
    # that needs the network, reaches the listener through the proxy
    # variables.
    block:
      let home = work / "control-home"
      createDir(home)
      var controlEnv = envPairs
      controlEnv.add [("HOME", home), ("CARGO_HOME", home / ".cargo")]
      let control = runClosed([cargo, "search", "--limit", "1", "serde"], ws,
        controlEnv)
      checkpoint control.output
      check control.code != 0
      require listener.accepted >= 1
      listener.resetCount()

    let lock = runClosed(@[cargo] & reg.sourceArgs &
      @["generate-lockfile", "--offline"], ws,
      envPairs & @[("HOME", work / "lock-home"),
        ("CARGO_HOME", work / "lock-home" / ".cargo")])
    checkpoint lock.output
    require lock.code == 0

    # The compiler the edge is given lies under the store root it declares,
    # as the store root's own toolchain does: a plan names its tools by
    # logical root.
    let toolStore = reg.store / "test-tools"
    createDir(toolStore / "bin")
    let rustcLog = work / "rustc.log"
    let logger = toolStore / "bin" / "rustc-logger"
    writeRustcLogger(logger, realRustc, rustcLog)
    let planRel = ".repro/build/cargo/app.plan.rbsz"
    let scratchRel = ".repro/build/cargo/app.plan-scratch"
    let edge = cargoPlanEdge(CargoPlanEdgeConfig(name: "app",
      projectRoot: ws, planFile: planRel, scratchDir: scratchRel,
      wrapper: wrapper, cargo: cargo, rustc: logger, storeRoot: reg.store,
      crates: reg.crates, devEnv: devEnvOf(envPairs)))
    for c in reg.crates:
      check c.prefix in edge.inputs
    check edge.networkMode == netDenied
    check edge.netDestinations.len == 0
    check auditNetworkPolicy(graph([edge])).len == 0
    check edge.scratchDirs == @[scratchRel]
    check edge.outputs == @[planRel]
    check edge.isolateHostEnvironment
    check edge.relocatable

    let tools = prepareMonitorTools(repoRoot, work / "monitor",
      "cg5-record-run")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    let config = BuildEngineConfig(
      cacheRoot: work / "engine-cache",
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: 1'u32,
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      bypassRunQuota: true)
    let run = runBuild(graph([edge]), config)
    require run.results.len == 1
    let res = run.results[0]
    checkpoint res.id & ": " & $res.status & "\nstderr: " & res.stderr

    # Nothing connected: no build script ran, and cargo asked nothing of
    # the network.
    check listener.accepted == 0
    check not dirExists(markers)
    # Only probes reached rustc.
    let invocations = readArgLog(rustcLog)
    check invocations.len > 0
    for args in invocations:
      if not isProbeShaped(args):
        checkpoint "a line that is not a probe reached rustc: " &
          args.join(" ")
        check false

    check res.status == asSucceeded
    # The monitor followed the edge: it saw cargo read the manifest.
    check (ws / "Cargo.toml") in res.evidence.monitorReads.paths
    # Nothing under the scratch directory is evidence.
    let scratch = ws / scratchRel
    for group in [res.evidence.monitorReads, res.evidence.monitorProbes,
                  res.evidence.monitorDirectoryEnumerations]:
      for path in group:
        if path.startsWith(scratch & "/"):
          checkpoint "scratch path in the evidence: " & path
          check false

    # The placeholders: in the scratch target directory, empty, and the
    # stub (the wrapper's own image) as each build script's executable.
    # (Dep-info files are left out: cargo itself writes the uplifted
    # `target/debug/<bin>.d` from the unit's, whatever the unit wrote.)
    let targetDir = scratch / "target"
    let wrapperSize = getFileSize(wrapper)
    var looked, stubs = 0
    for path in walkDirRec(targetDir):
      let name = extractFilename(path)
      let isOutput = name.endsWith(".rlib") or name.endsWith(".rmeta") or
        name.endsWith(".so") or name.endsWith(".dylib") or
        fpUserExec in getFilePermissions(path)
      if not isOutput: continue
      inc looked
      if name.startsWith("build_script_") or name.startsWith("build-script-"):
        check getFileSize(path) == wrapperSize
        inc stubs
      else:
        checkpoint path
        check getFileSize(path) == 0
    check looked > 0
    check stubs > 0
    check not dirExists(ws / "target")

    # The plan: the one output, every unit and run, and none of the record
    # run's own paths.
    let planPath = ws / planRel
    require fileExists(planPath)
    let planBytes = readFile(planPath)
    check scratch notin planBytes
    check ws notin planBytes
    let plan = readCargoPlan(planPath)
    var crates: seq[string]
    for u in plan.units: crates.add u.crateName
    for (crate, count) in [("app", 1), ("app_tool", 1), ("mid", 1),
                           ("sysdep", 1), ("helper", 2), ("pm", 1),
                           ("bdep", 1), ("regleaf", 1), ("regbs", 1),
                           ("build_script_build", 5)]:
      checkpoint crate
      check crates.countIt(it == crate) == count
    check plan.runs.len == 5
    # Every registry crate unit is in the plan, named by its store prefix:
    # its working directory and manifest directory are the prefix it was
    # fetched into, and its crate root is a file of that prefix.
    let storeRoots = parseRecordRoots("store=" & reg.store)
    for c in reg.crates:
      checkpoint c.name
      var found = 0
      for u in plan.units:
        if u.package != c.name: continue
        inc found
        check expandRecorded(storeRoots, u.cwd) == c.prefix
        var manifestDir = ""
        for (name, value) in u.env:
          if name == "CARGO_MANIFEST_DIR": manifestDir = value
        check expandRecorded(storeRoots, manifestDir) == c.prefix
        var roots = 0
        for arg in u.argv:
          if arg.startsWith("${store}/") and arg.endsWith(".rs"):
            inc roots
            check fileExists(expandRecorded(storeRoots, arg))
            check expandRecorded(storeRoots, arg).startsWith(c.prefix & "/")
        check roots == 1
      check found == (if c.name == "regbs": 2 else: 1)
    for r in plan.runs:
      if r.package == "regbs":
        check expandRecorded(storeRoots, r.cwd) == reg.store &
          r.cwd["${store}".len .. ^1]
        check r.cwd.startsWith("${store}/")
    # The prefixes were only read.
    for i, c in reg.crates:
      check treeSnapshot(c.prefix) == prefixesBefore[i]
    # A build script whose build-dependency has a build script of its own
    # is fed by that build-dependency's run: cargo put its link-search path
    # on the dependent script's dynamic-library path.
    var midRun, bdepRun = ""
    for r in plan.runs:
      if r.package == "mid": midRun = r.id
      if r.package == "bdep": bdepRun = r.id
    require midRun.len > 0 and bdepRun.len > 0
    check plan.runById(midRun).fedBy == @[bdepRun]
    check plan.runById(midRun).isFed
    check not plan.runById(bdepRun).isFed
    for r in plan.runs:
      check r.compileUnit.len > 0
      check plan.unitById(r.compileUnit).buildScriptCompile
      check r.argv.len > 0 and r.argv[0] ==
        plan.unitById(r.compileUnit).executable
      check r.outDir == "${out}/" & r.id & "/out"
    for u in plan.units:
      for output in u.outputs:
        check output.startsWith("${out}/" & u.id & "/")

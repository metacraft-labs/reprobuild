import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_test_support
import io_mon

when defined(linux) or defined(macosx):
  proc waitForFile(path: string) =
    for _ in 0 ..< 2400:
      if fileExists(path): return
      sleep(25)
    raise newException(IOError, "timed out waiting for " & path)

  proc finish(process: Process): int =
    result = process.waitForExit(60000)
    if result == -1:
      process.terminate()
      discard process.waitForExit()
    process.close()

  let args = commandLineParams()
  if args.len > 0 and args[0] == "--capture-worker":
    let role = args[1]
    let root = args[2]
    let monitor = startProcess(args[3], args =
      @["internal", "io", "monitor"] & args[4 .. ^1],
      options = {poParentStreams})
    let status = finish(monitor)
    if status != 0: quit(status)
    # Hold A after the real monitor has closed its capture, before the engine
    # can consume it. B then completes another capture at the same action ID.
    if role == "a":
      writeFile(root / "a-ready", "")
      waitForFile(root / "a-release")
    quit(0)

  if args.len > 0 and args[0] == "--build-worker":
    let role = args[1]
    let root = args[2]
    let cli = args[3]
    let work = root / role
    let input = work / "input.txt"
    let output = work / "output.txt"
    let step = action("same-provider", ["/bin/sh", "-c",
        "cat " & quoteShell(input) & " > " & quoteShell(output) &
        (if role == "failure": "; exit 7" else: "")],
      cwd = work, outputs = [output], cacheable = true,
      weakFingerprint = weakFingerprintFromText(root & role),
      cpuMilli = 100'u32,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      dependencyPolicy = automaticMonitorGatheringPolicy())
    let run = runBuild(graph([step]), BuildEngineConfig(
      cacheRoot: root / "cache", maxParallelism: 1'u32,
      inlineRunQuota: args[4] == "inline", runQuotaCliPath: cli,
      monitorCliPath: getAppFilename(),
      monitorCliArgs: @["--capture-worker", role, root, cli],
      monitorHosting: mhmNever))
    doAssert run.results.len == 1
    let res = run.results[0]
    doAssert not run.runQuotaBypassed
    if res.status == asSucceeded:
      doAssert res.leaseId != 0'u64
    writeFile(root / (role & ".json"), $(%*{
      "status": $res.status, "exitCode": res.exitCode, "stderr": res.stderr,
      "diagnostics": res.evidence.diagnostics,
      "reads": res.evidence.monitorReads,
      "depfile": res.monitorDepfilePath}))
    quit(if res.status in {asSucceeded, asCacheHit}: 0 else: 1)

  template withMonitorFixture(body: untyped) =
    block:
      let root {.inject.} = createTempDir("repro-capture-owner-", "",
        getEnv("REPRO_TEST_CAPTURE_ROOT"))
      defer: removeDir(root)
      let tools {.inject.} = prepareMonitorTools(getCurrentDir(),
        getCurrentDir() / "build" / "test-capture-owner", "capture-owner")
      let oldShim = getEnv("REPRO_MONITOR_SHIM_LIB")
      let oldSocket = getEnv("RUNQUOTA_SOCKET")
      let oldBypass = getEnv("REPROBUILD_NO_RUNQUOTA")
      defer:
        if oldShim.len > 0: putEnv("REPRO_MONITOR_SHIM_LIB", oldShim)
        else: delEnv("REPRO_MONITOR_SHIM_LIB")
        if oldSocket.len > 0: putEnv("RUNQUOTA_SOCKET", oldSocket)
        else: delEnv("RUNQUOTA_SOCKET")
        if oldBypass.len > 0: putEnv("REPROBUILD_NO_RUNQUOTA", oldBypass)
        else: delEnv("REPROBUILD_NO_RUNQUOTA")
      # A graph runner may already interpose with its installed shim. Naming
      # another copy here would inject both into descendants and can livelock.
      putEnv("REPRO_MONITOR_SHIM_LIB",
        if oldShim.len > 0: oldShim else: tools.shim)
      let quotaRoot = createTempDir("repro-capture-quota-", "")
      defer: removeDir(quotaRoot)
      let socket = runquotaRendezvousDir(quotaRoot) / "runquota.sock"
      let daemon = startProcess(requireRunQuotaDaemonBin(getCurrentDir()),
        args = ["--socket", socket, "--cpu-milli", "4000",
          "--memory-bytes", "17179869184"],
        options = {poParentStreams})
      defer:
        daemon.terminate()
        discard finish(daemon)
      var ready = false
      for _ in 0 ..< 400:
        try:
          discard getFileInfo(socket, followSymlink = false)
          ready = true
          break
        except OSError: discard
        if not daemon.running: break
        sleep(25)
      if not ready:
        raise newException(IOError, "runquotad did not bind " & socket)
      putEnv("RUNQUOTA_SOCKET", socket)
      # This is a separate authority, not the outer build's leased pool.
      # Exercise real inner leases even when invoked by the graph test runner.
      delEnv("REPROBUILD_NO_RUNQUOTA")
      body

  template overlap(mode: string) =
    withMonitorFixture:
      for role in ["a", "b"]:
        createDir(root / role)
        writeFile(root / role / "input.txt", role & "\n")
      let a = startProcess(getAppFilename(), args =
        ["--build-worker", "a", root, tools.monitorCliPath, mode],
        options = {poParentStreams})
      var aFinished = false
      defer:
        if not aFinished:
          writeFile(root / "a-release", "")
          discard finish(a)
      waitForFile(root / "a-ready")
      let b = startProcess(getAppFilename(), args =
        ["--build-worker", "b", root, tools.monitorCliPath, mode],
        options = {poParentStreams})
      check finish(b) == 0
      writeFile(root / "a-release", "")
      check finish(a) == 0
      aFinished = true
      for role in ["a", "b"]:
        let report = parseFile(root / (role & ".json"))
        checkpoint $report
        check report["status"].getStr == "asSucceeded"
        check %(root / role / "input.txt") in report["reads"].elems
        let other = if role == "a": "b" else: "a"
        check %(root / other / "input.txt") notin report["reads"].elems
        check readFile(root / role / "output.txt") == role & "\n"
        check fileExists(report["depfile"].getStr)
        discard readMonitorDepFile(report["depfile"].getStr)
      for kind, path in walkDir(root / "cache" / "monitor-depfiles"):
        check not path.endsWith(".tmp")

  suite "wrapped monitor evidence ownership":
    test "inline RunQuota builds consume their own capture for the same action ID":
      overlap("inline")

    test "RunQuota helper builds consume their own capture for the same action ID":
      overlap("helper")

    test "flush failure withholds caching and failed commands clean up captures":
      withMonitorFixture:
        let oldFail = getEnv("REPROBUILD_MONITOR_FLUSH_FAIL")
        defer:
          if oldFail.len > 0: putEnv("REPROBUILD_MONITOR_FLUSH_FAIL", oldFail)
          else: delEnv("REPROBUILD_MONITOR_FLUSH_FAIL")
        for role in ["single", "failure"]:
          createDir(root / role)
          writeFile(root / role / "input.txt", role & "\n")
        for attempt in 0 .. 2:
          removeFile(root / "single" / "output.txt")
          if attempt == 0: putEnv("REPROBUILD_MONITOR_FLUSH_FAIL", "same-provider")
          else: delEnv("REPROBUILD_MONITOR_FLUSH_FAIL")
          let worker = startProcess(getAppFilename(), args =
            ["--build-worker", "single", root, tools.monitorCliPath, "inline"],
            options = {poParentStreams})
          check finish(worker) == 0
          let report = parseFile(root / "single.json")
          checkpoint $report
          check report["status"].getStr ==
            (if attempt == 2: "asCacheHit" else: "asSucceeded")
          if attempt == 0:
            check "action-cache publish skipped" in $report["diagnostics"]
        let failed = startProcess(getAppFilename(), args =
          ["--build-worker", "failure", root, tools.monitorCliPath, "inline"],
          options = {poParentStreams})
        check finish(failed) == 1
        let report = parseFile(root / "failure.json")
        check report["status"].getStr == "asFailed"
        check report["exitCode"].getInt == 7
        check readFile(root / "failure" / "output.txt") == "failure\n"
        discard readMonitorDepFile(report["depfile"].getStr)
        for kind, path in walkDir(root / "cache" / "monitor-depfiles"):
          check not path.endsWith(".tmp")

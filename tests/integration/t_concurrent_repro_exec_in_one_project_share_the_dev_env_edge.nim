## Two `repro exec` runs that enter ONE project at the same time must both
## succeed: neither may fail because of the other's dev-env introspection edge.
##
## Real CLI, real monitor, real Nim compiler and real project provider: no
## mocks. The only thing the fixture adds is a rendezvous INSIDE the recipe,
## which turns a timing window into a deterministic interleaving.
##
## The window (reprobuild-pm issue 2026-10-25, "concurrent repro exec in one
## project races on the dev-env provider response file"): the edge's protocol
## files live at fixed paths under `<outDir>/dev-env-protocol`, and each run
## REMOVES `dev-env.response.rbpg` before launching its provider and then
## requires it to exist once the provider exits. When run B's removal lands
## between run A's provider writing that file and run A checking for it, A
## fails with "provider did not write response". The edge's `--out` artifact
## and the rest of the dev-env output directory are shared the same way.
##
## The recipe forces exactly that order, and only while the test has ARMED it.
## Each run asks its provider for the manifest first and for the dev-env
## result second, and the run's helper removes the shared response file just
## before launching the provider for the second request:
##
##   * the first manifest request (`manifest-1`) is answered at once, so the
##     run that sends it reaches its dev-env request first;
##   * that first dev-env provider (`first`) writes its response as usual,
##     then, at exit, records `first-responded` and holds its exit until a
##     second dev-env provider has started (`second`). A second provider
##     starts only after its run removed the shared response file;
##   * every later manifest request waits for `first-responded`, so the other
##     run's removal of the response file comes AFTER the first provider wrote
##     it -- the order that makes the first run fail. Without this hold the
##     removal often lands while the first provider is still evaluating, the
##     first response survives, and the race goes unobserved (measured: the
##     test without it passed 2 of 3 runs against the unfixed engine);
##   * the second dev-env provider sleeps before answering, so its own
##     response is not yet there when the first run looks for its own.
##
## When concurrent activations of one project are serialised, the second run
## cannot start anything in the dev-env edge while the first holds it, so the
## first provider's wait ends at its bound and both runs succeed.
import std/[os, osproc, streams, strtabs, strutils, typedthreads, unittest]
import repro_test_support
import repro_test_support/process_fixtures

const
  RendezvousBoundMs = 15_000
    ## The longest any provider waits at the rendezvous. Generous on purpose:
    ## on the unfixed engine the other run gets there within a few seconds
    ## (everything before it is warm). When the runs are serialised, the
    ## first run's provider waits out this bound once, for a second provider
    ## that cannot start until the first run is done.
  SecondAnswerDelayMs = 3_000
    ## How long the second provider waits before answering -- the time the
    ## first run has to find that its response was removed.

proc recipeSource(rendezvous: string): string =
  ## The fixture recipe. The rendezvous runs at provider start-up (module
  ## initialisation), before the provider reads its request. The same binary
  ## answers the manifest request and the dev-env request; it tells them
  ## apart by the request file it was handed. Nothing happens unless the test
  ## has armed the rendezvous, so the warm-up run is an ordinary activation.
  "import std/[exitprocs, os, strutils]\n" &
  "import repro_project_dsl\n" &
  "\n" &
  "const rendezvous = " & rendezvous.escape & "\n" &
  "\n" &
  "proc requested(suffix: string): bool =\n" &
  "  for arg in commandLineParams():\n" &
  "    if arg.endsWith(suffix):\n" &
  "      return true\n" &
  "  false\n" &
  "\n" &
  "proc waitFor(marker: string) =\n" &
  "  var waited = 0\n" &
  "  while not dirExists(rendezvous / marker) and waited < " &
    $RendezvousBoundMs & ":\n" &
  "    sleep(20)\n" &
  "    waited += 20\n" &
  "\n" &
  "if fileExists(rendezvous / \"armed\"):\n" &
  "  if requested(\"manifest.request.rbpg\"):\n" &
  "    if existsOrCreateDir(rendezvous / \"manifest-1\"):\n" &
  "      waitFor(\"first-responded\")\n" &
  "  elif requested(\"dev-env.request.rbpg\"):\n" &
  "    if not existsOrCreateDir(rendezvous / \"first\"):\n" &
  "      addExitProc(proc () =\n" &
  "        discard existsOrCreateDir(rendezvous / \"first-responded\")\n" &
  "        waitFor(\"second\"))\n" &
  "    elif not existsOrCreateDir(rendezvous / \"second\"):\n" &
  "      sleep(" & $SecondAnswerDelayMs & ")\n" &
  "\n" &
  "package fixture:\n" &
  "  devEnv:\n" &
  "    setEnv \"RACE_FIXTURE\", \"ready\"\n"

type
  OutputDrain = object
    ## One child's merged stdout/stderr, read to its end on a thread of its
    ## own. See `drain` for why the runs are not read one after the other.
    stream: Stream
    output: string

proc drain(target: ptr OutputDrain) {.thread.} =
  ## Read `target.stream` to its end. The main thread does not touch
  ## `target` again until it has joined this thread.
  {.cast(gcsafe).}:
    target.output = target.stream.readAll()

suite "concurrent activations of one project's dev environment":
  test "two concurrent repro exec runs in one project both succeed":
    # exec is handled by the engine; the thin client delegates this verb.
    let cli = requireHostBinary(getEnv("REPRO_TEST_CONCURRENT_EXEC_CLI",
      reproBinaryPath(stem = "reprobuild")))
    let root = getTempDir() / ("repro-concurrent-exec-" &
      $getCurrentProcessId())
    require not dirExists(root)
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let project = root / "project"
    let rendezvous = root / "rendezvous"
    createDir(project)
    createDir(rendezvous)
    writeFile(project / "repro.nim", recipeSource(rendezvous))

    var env = newStringTable(modeCaseSensitive)
    for name, value in envPairs():
      if not name.startsWith("__REPRO_"):
        env[name] = value
    env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
    env["XDG_CACHE_HOME"] = root / "user-cache"
    env["LOCALAPPDATA"] = root / "user-cache"
    env["REPRO_ACTION_CACHE_SHM"] = "0"
    env["REPRO_DAEMON"] = "off"
    env["REPRO_PROGRESS"] = "lines"
    env["REPRO_PROVIDER_PARALLEL_BUILD"] = "2"
    # The dev shell's toolchain, as in
    # `t_repro_exec_survives_compile_time_tmpdir_removal.nim`: provisioning
    # another one would only slow the fixture down.
    if not env.hasKey("REPRO_NIM_COMPILER") or env["REPRO_NIM_COMPILER"].len == 0:
      env["REPRO_NIM_COMPILER"] = findExe("nim", followSymlinks = false)
    if not env.hasKey("REPRO_BOOTSTRAP_CC") or env["REPRO_BOOTSTRAP_CC"].len == 0:
      let cc = when defined(windows): "gcc" else: "cc"
      env["REPRO_BOOTSTRAP_CC"] = findExe(cc, followSymlinks = false)

    proc start(): Process =
      startProcess(cli, workingDir = root,
        args = ["exec", project, "--", cli, "--version"], env = env,
        options = {poStdErrToStdOut})

    proc finish(process: Process): tuple[output: string; exitCode: int] =
      result.output = process.outputStream.readAll()
      result.exitCode = process.waitForExit()
      process.close()

    # Both concurrent runs are drained at once. Reading A to its end before
    # touching B deadlocks whenever B is the run that takes the dev-env edge
    # lock first: B keeps the lock while it writes progress lines into a pipe
    # nobody reads, which fills once B's output passes the pipe buffer (the
    # first provider holds B for up to `RendezvousBoundMs`, and B reports
    # progress all that time), and A, the run being read, waits for that
    # lock. Measured: one of the first three runs against the serialised
    # engine hung there.
    proc finishBoth(a, b: Process):
        tuple[a, b: tuple[output: string; exitCode: int]] =
      var drains = [OutputDrain(stream: a.outputStream),
        OutputDrain(stream: b.outputStream)]
      var threads: array[2, Thread[ptr OutputDrain]]
      for i in 0 .. 1:
        createThread(threads[i], drain, addr drains[i])
      joinThreads(threads)
      result.a = (output: drains[0].output, exitCode: a.waitForExit())
      result.b = (output: drains[1].output, exitCode: b.waitForExit())
      a.close()
      b.close()

    # Warm the project: interface extraction and the provider compile are
    # cached after this, so the concurrent runs below reach their providers
    # within moments of each other. The rendezvous is not armed yet.
    let warm = finish(start())
    checkpoint("warm-up:\n" & warm.output)
    require warm.exitCode == 0

    # Arming changes a path the provider probed, so neither concurrent run can
    # reuse the warm-up's introspection record: both must run the edge.
    writeFile(rendezvous / "armed", "")
    let a = start()
    let b = start()
    let (ra, rb) = finishBoth(a, b)
    checkpoint("run A (exit " & $ra.exitCode & "):\n" & ra.output)
    checkpoint("run B (exit " & $rb.exitCode & "):\n" & rb.output)

    # Positive control: the rendezvous really ran, so the interleaving above
    # was the one this test exists to force.
    require dirExists(rendezvous / "first")
    require dirExists(rendezvous / "first-responded")
    check "provider did not write response" notin ra.output
    check "provider did not write response" notin rb.output
    check ra.exitCode == 0
    check rb.exitCode == 0

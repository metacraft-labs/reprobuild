## The build graph's helper commands draw no entropy at start-up on Windows.
##
## THE DEFECT THIS CONFIRMS IS GONE. The engine (`reprobuild.exe`) is built
## with `-d:ssl`, so it maps `libssl-3-x64.dll` and `libcrypto-3-x64.dll`
## when it starts, and those stack-protector builds seed their canary through
## `rand_s` -> `RtlGenRandom` -> `ProcessPrng`. Every engine process therefore
## read entropy before `main`, whatever it was started to do, and the build
## graph ran its own helper commands (`internal probe-profile-platforms`,
## `internal render-dev-env-shell`, ...) as engine processes INSIDE monitored
## actions. An action whose tree reads entropy is not cached on its first
## run, so the profile platform probe re-ran on every export and a dev-env
## re-entry re-ran introspection and shell rendering.
##
## The helpers now run from the graph helper image (`reprobuild-helper.exe`,
## `apps/reprobuild-helper`), built from the same sources without `-d:ssl`.
## This test runs the helper commands under `repro internal io monitor`, with
## exactly the command line their edges build, and asserts that no
## `ProcessPrng` / `RtlGenRandom` record comes from the helper process.
##
## THE POSITIVE CONTROL, in the same file and the same monitor: the engine
## image (`reprobuild.exe --version`) DOES record the draw. Without it, a
## monitor that saw no entropy at all (a shim that did not load, a hook that
## did not install) would make the assertion above pass for the wrong reason.
## A capture with no records at all is refused for the same reason.
##
## WINDOWS ONLY, AND IT DOES NOT PASS ELSEWHERE. Linux and macOS seed the
## canary without an observable call, so there is nothing to confirm there;
## on any other OS the case is SKIPPED with that reason, never reported as a
## pass. The Linux structural counterpart (the helper image maps no OpenSSL)
## is `t_graph_helper_image_loads_no_openssl.nim`.
##
## No mocks: the real built images in `build/bin`, the real monitor and shim,
## and the real edge builder (`profilePlatformProbeBuildAction`) for the
## probe's command line.

import std/unittest
import repro_test_support/reasoned_skip

when defined(windows):
  import std/[os, osproc, sets, strutils, tempfiles]

  import io_mon
  from repro_build_engine import weakFingerprintFromText
  import repro_core/cli_images
  import repro_profile_compile/edge
  from repro_cli_support/cli_description import reproLongFlags
  from repro_test_support import monitorShimPath

  const
    EntropySources = ["ProcessPrng", "RtlGenRandom"]
      ## The two records the OpenSSL start-up draw leaves (io-mon's
      ## `snoopProcessPrng` / `snoopSystemFunction036`).
    RenderFlags = reproLongFlags(@["internal", "render-dev-env-shell"])

  type Capture = object
    exitCode: int
    output: string
    records: seq[MonitorRecord]

  proc runMonitored(engine, depfile: string; command: seq[string];
                    shim: string): Capture =
    ## ``command`` under ``<engine> internal io monitor``, the driver every
    ## monitored action is wrapped in.
    let argv = @[engine, "internal", "io", "monitor", "--depfile", depfile,
      "--"] & command
    let previous = getEnv("REPRO_MONITOR_SHIM_LIB")
    if shim.len > 0:
      putEnv("REPRO_MONITOR_SHIM_LIB", shim)
    try:
      let (output, code) = execCmdEx(quoteShellCommand(argv))
      result.exitCode = code
      result.output = output
    finally:
      if previous.len > 0: putEnv("REPRO_MONITOR_SHIM_LIB", previous)
      else: delEnv("REPRO_MONITOR_SHIM_LIB")
    if fileExists(depfile):
      result.records = readMonitorDepFile(depfile).records

  proc rootPids(records: seq[MonitorRecord]): HashSet[uint64] =
    ## The processes the monitor started itself: every pid that recorded
    ## something and that no recorded process spawned. Under the monitor the
    ## root is the command it was given -- here the helper image -- and
    ## anything it starts (none, for these command lines) is a child.
    ##
    ## Pid 0 is included: a record the capture could not attribute to a
    ## process may be the root's, and the assertion must not be satisfied
    ## by a record it failed to attribute.
    var spawned = initHashSet[uint64]()
    for record in records:
      if record.kind == mrProcessSpawn and record.childOsPid != 0:
        spawned.incl(record.childOsPid)
    result.incl(0'u64)
    for record in records:
      if record.osPid notin spawned:
        result.incl(record.osPid)

  proc entropyFrom(records: seq[MonitorRecord];
                   pids: HashSet[uint64]): seq[string] =
    ## The entropy records (`ProcessPrng`, `RtlGenRandom`) that ``pids``
    ## recorded, rendered for a failure message.
    for record in records:
      if record.kind == mrNonDeterministic and record.osPid in pids and
          record.path in EntropySources:
        result.add("pid=" & $record.osPid & " " & record.detail)

  proc requireImages(repoRoot: string): tuple[engine, helper: string] =
    ## The engine and its graph helper image, both from ``build/bin``. The
    ## helper is resolved the way the engine resolves it
    ## (``requireGraphHelperImage``), so a missing one fails here naming the
    ## path it expected.
    result.engine = repoRoot / "build" / "bin" / reprobuildEngineExeName()
    if not fileExists(result.engine):
      raise newException(IOError, "the engine " & result.engine &
        " does not exist; build it first (`bash ./scripts/build_apps.sh`)")
    result.helper = requireGraphHelperImage(result.engine)

  template refuseEmpty(label: string; capture: Capture) =
    ## A capture with no records at all proves nothing about entropy.
    if capture.records.len == 0:
      checkpoint(capture.output)
      checkpoint(label & ": the monitor recorded NOTHING (exit " &
        $capture.exitCode & "); the shim did not observe this process, so " &
        "an absence of entropy records would mean nothing. Refusing.")
      fail()

suite "the graph helper image draws no entropy at start-up (Windows)":

  test "positive control: the engine image records the draw":
    when defined(windows):
      let repoRoot = getCurrentDir()
      let images = requireImages(repoRoot)
      let tempRoot = createTempDir("repro-helper-entropy-ctl", "")
      defer: removeDir(tempRoot)
      let capture = runMonitored(images.engine, tempRoot / "engine.iomon",
        @[images.engine, "--version"], monitorShimPath(repoRoot))
      checkpoint(capture.output)
      refuseEmpty("reprobuild.exe --version", capture)
      check capture.exitCode == 0
      let draws = entropyFrom(capture.records, rootPids(capture.records))
      checkpoint("engine draws: " & draws.join("; "))
      # The monitor sees the draw: without this the helper cases below could
      # pass because nothing was observed.
      check draws.len > 0
    else:
      skip("[platform N/A] the OpenSSL start-up entropy draw exists only " &
        "on Windows; Linux and macOS seed the canary without an " &
        "observable call. This confirmation runs on a Windows host.")

  test "the profile platform probe's command line draws nothing":
    when defined(windows):
      let repoRoot = getCurrentDir()
      let images = requireImages(repoRoot)
      let tempRoot = createTempDir("repro-helper-entropy-probe", "")
      defer: removeDir(tempRoot)
      # The edge's own command line, from the edge's own builder, with the
      # image the engine resolves for it. The profile does not exist, so
      # the role reaches its body, reports that, and starts nothing.
      let missingProfile = tempRoot / "missing" / "home.nim"
      let action = profilePlatformProbeBuildAction(missingProfile,
        tempRoot / "probe.out", tempRoot / "probe-scratch", images.helper,
        tempRoot, repoRoot, weakFingerprintFromText("entropy confirmation"))
      check action.argv[0] == images.helper
      let capture = runMonitored(images.engine, tempRoot / "probe.iomon",
        action.argv, monitorShimPath(repoRoot))
      checkpoint(capture.output)
      refuseEmpty("probe-profile-platforms", capture)
      # The helper ran its role (the image did not refuse the command line).
      check "profile root does not exist" in capture.output
      let draws = entropyFrom(capture.records, rootPids(capture.records))
      checkpoint("helper draws: " & draws.join("; "))
      check draws.len == 0
    else:
      skip("[platform N/A] the OpenSSL start-up entropy draw exists only " &
        "on Windows; Linux and macOS seed the canary without an " &
        "observable call. This confirmation runs on a Windows host.")

  test "the dev-env shell render's command line draws nothing":
    when defined(windows):
      let repoRoot = getCurrentDir()
      let images = requireImages(repoRoot)
      let tempRoot = createTempDir("repro-helper-entropy-render", "")
      defer: removeDir(tempRoot)
      # The render edge's words (`shellRenderAction`), over an artifact that
      # does not exist: the role reaches its body and reports it.
      let argv = @[images.helper, "internal", "render-dev-env-shell",
        RenderFlags.artifact & "=" & (tempRoot / "missing.rbde"),
        RenderFlags.`out` & "=" & (tempRoot / "dev-env.env"),
        RenderFlags.navigatorStats & "=" & (tempRoot / "nav.json")]
      let capture = runMonitored(images.engine, tempRoot / "render.iomon",
        argv, monitorShimPath(repoRoot))
      checkpoint(capture.output)
      refuseEmpty("render-dev-env-shell", capture)
      check "repro dev-env shell render: error:" in capture.output
      let draws = entropyFrom(capture.records, rootPids(capture.records))
      checkpoint("helper draws: " & draws.join("; "))
      check draws.len == 0
    else:
      skip("[platform N/A] the OpenSSL start-up entropy draw exists only " &
        "on Windows; Linux and macOS seed the canary without an " &
        "observable call. This confirmation runs on a Windows host.")

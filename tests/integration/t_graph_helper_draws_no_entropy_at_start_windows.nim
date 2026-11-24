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
## THE POSITIVE CONTROL, in the same file and the same monitor: the ENGINE
## image running the SAME command line as the profile platform probe case
## (only argv[0] differs) DOES record the draw. The two cases differ in the
## image and nothing else, so the control shows both that the monitor sees
## the draw and that the draw belongs to the image the helper replaces.
## Without it, a monitor that saw no entropy at all (a shim that did not
## load, a hook that did not install) would make the helper cases pass for
## the wrong reason.
##
## WHICH PROCESS IS "THE COMMAND". io-mon's run driver adds one record of its
## own to every capture: a synthetic `mrProcessSpawn` from pid 0 naming the
## process it started (`childOsPid`), so that a root which never loaded the
## shim is reported as an unmonitored child. A rule of "every pid that no
## recorded process spawned" therefore EXCLUDES the command's own process,
## because that synthetic record names it as spawned; every one of its
## entropy records would be skipped, the control could never pass and the
## helper cases could never fail. The command's process is taken from that
## launcher record instead (`launcherRoots`), and a capture in which the
## shim did not observe that process start (`mrProcessStart` from that pid)
## is refused: the synthetic record alone makes a capture non-empty, so
## "some record exists" proves nothing. The first case, which runs on every
## OS, checks that identification against a real capture.
##
## WINDOWS ONLY FOR THE ENTROPY CASES, AND THEY DO NOT PASS ELSEWHERE. Linux
## and macOS seed the canary without an observable call, so there is nothing
## to confirm there; on any other OS those cases are SKIPPED with that
## reason, never reported as a pass. The Linux structural counterpart (the
## helper image maps no OpenSSL) is `t_graph_helper_image_loads_no_openssl.nim`.
##
## WHEN A CASE FAILS it prints what the monitor captured for the command's
## process: the pid the launcher named, the record kinds per pid, every
## library load whose name holds `ssl` or `crypto`, and every entropy record
## in the capture from any pid. That is what tells apart a monitor that did
## not see the process, an image that did not load OpenSSL, and an image
## that loaded it without drawing.
##
## No mocks: the real built images in `build/bin`, the real monitor and shim,
## and the real edge builder (`profilePlatformProbeBuildAction`) for the
## probe's command line.

import std/[os, osproc, sets, strutils, tables, tempfiles, unittest]

import io_mon
from repro_build_engine import weakFingerprintFromText
import repro_core/cli_images
import repro_profile_compile/edge
from repro_cli_support/cli_description import reproLongFlags
from repro_test_support import monitorShimPath
import repro_test_support/reasoned_skip

const
  EntropySources = ["ProcessPrng", "RtlGenRandom"]
    ## The two records the OpenSSL start-up draw leaves (io-mon's
    ## `snoopProcessPrng` / `snoopSystemFunction036`).
  RenderFlags = reproLongFlags(@["internal", "render-dev-env-shell"])
  WindowsOnly = "[platform N/A] the OpenSSL start-up entropy draw exists " &
    "only on Windows; Linux and macOS seed the canary without an " &
    "observable call. This confirmation runs on a Windows host."

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

proc launcherRoots(records: seq[MonitorRecord]): HashSet[uint64] =
  ## The processes the monitor's launcher started: the ``childOsPid`` of
  ## each ``mrProcessSpawn`` the launcher itself recorded (``osPid`` 0, no
  ## monitored process). Under ``internal io monitor -- <command>`` that is
  ## exactly the command's own process.
  for record in records:
    if record.kind == mrProcessSpawn and record.osPid == 0 and
        record.childOsPid != 0:
      result.incl(record.childOsPid)

proc rootPids(records: seq[MonitorRecord]): HashSet[uint64] =
  ## The command's process and every process the capture cannot place under
  ## a monitored parent: the launcher's roots, every pid that recorded
  ## something and that no MONITORED process spawned, and pid 0. The
  ## launcher's own spawn record does not count as a parent here (see the
  ## module doc: counting it would drop the command's process). Anything
  ## the command starts (none, for these command lines) is a child.
  ##
  ## Pid 0 is included: a record the capture could not attribute to a
  ## process may be the root's, and the assertion must not be satisfied
  ## by a record it failed to attribute.
  var spawnedInTree = initHashSet[uint64]()
  for record in records:
    if record.kind == mrProcessSpawn and record.osPid != 0 and
        record.childOsPid != 0:
      spawnedInTree.incl(record.childOsPid)
  result = launcherRoots(records)
  result.incl(0'u64)
  for record in records:
    if record.osPid notin spawnedInTree:
      result.incl(record.osPid)

proc isEntropy(record: MonitorRecord): bool =
  record.kind == mrNonDeterministic and record.path in EntropySources

proc entropyFrom(records: seq[MonitorRecord];
                 pids: HashSet[uint64]): seq[string] =
  ## The entropy records (`ProcessPrng`, `RtlGenRandom`) that ``pids``
  ## recorded, rendered for a failure message.
  for record in records:
    if record.isEntropy and record.osPid in pids:
      result.add("pid=" & $record.osPid & " " & record.detail)

proc describeCapture(capture: Capture): string =
  ## What the monitor captured, for a failure message: the launcher's
  ## root, the record kinds per pid, the OpenSSL-looking library loads, and
  ## every entropy record from any pid.
  var kinds = initOrderedTable[uint64, CountTable[string]]()
  var libraries: seq[string]
  var entropy: seq[string]
  for record in capture.records:
    kinds.mgetOrPut(record.osPid, initCountTable[string]()).inc($record.kind)
    if record.kind == mrLibraryLoad:
      let name = record.path.toLowerAscii
      if "ssl" in name or "crypto" in name:
        libraries.add("pid=" & $record.osPid & " " & record.path)
    if record.isEntropy:
      entropy.add("pid=" & $record.osPid & " " & record.detail)
  var lines = @["exit " & $capture.exitCode & ", " & $capture.records.len &
    " records; launcher root(s): " & $launcherRoots(capture.records)]
  for pid, counts in kinds:
    var parts: seq[string]
    for kind, n in counts: parts.add(kind & "=" & $n)
    lines.add("  pid " & $pid & ": " & parts.join(" "))
  lines.add("  OpenSSL library loads: " &
    (if libraries.len == 0: "none" else: libraries.join("; ")))
  lines.add("  entropy records from any pid: " &
    (if entropy.len == 0: "none" else: entropy.join("; ")))
  lines.join("\n")

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

template requireRootObserved(label: string; capture: Capture) =
  ## The shim observed the command's own process start. Without that, an
  ## absence of entropy records from it would mean nothing.
  checkpoint(describeCapture(capture))
  let roots = launcherRoots(capture.records)
  var observed = false
  for record in capture.records:
    if record.kind == mrProcessStart and record.osPid in roots:
      observed = true
  if roots.len == 0 or not observed:
    checkpoint(capture.output)
    checkpoint(label & ": the monitor did not observe the command's own " &
      "process start (launcher root(s) " & $roots & "); an absence of " &
      "entropy records from it would mean nothing. Refusing.")
    fail()

proc probeCommandLine(images: tuple[engine, helper: string];
                      tempRoot, repoRoot: string): seq[string] =
  ## The profile platform probe edge's own command line, from the edge's
  ## own builder, with the image the engine resolves for it. The profile
  ## does not exist, so the role reaches its body, reports that, and starts
  ## nothing.
  let missingProfile = tempRoot / "missing" / "home.nim"
  let action = profilePlatformProbeBuildAction(missingProfile,
    tempRoot / "probe.out", tempRoot / "probe-scratch", images.helper,
    tempRoot, repoRoot, weakFingerprintFromText("entropy confirmation"))
  action.argv

suite "the graph helper image draws no entropy at start-up (Windows)":

  test "the capture names the command's own process as a root":
    # Runs on every OS: the root identification the entropy cases rely on,
    # checked against a real capture of a real image.
    let repoRoot = getCurrentDir()
    let images = requireImages(repoRoot)
    let tempRoot = createTempDir("repro-helper-entropy-root", "")
    defer: removeDir(tempRoot)
    let capture = runMonitored(images.engine, tempRoot / "root.iomon",
      @[images.engine, "--version"], monitorShimPath(repoRoot))
    checkpoint(capture.output)
    check capture.exitCode == 0
    requireRootObserved("reprobuild --version", capture)
    let roots = launcherRoots(capture.records)
    check roots.len == 1
    for pid in roots:
      check pid in rootPids(capture.records)

  test "positive control: the engine image records the draw":
    when defined(windows):
      let repoRoot = getCurrentDir()
      let images = requireImages(repoRoot)
      let tempRoot = createTempDir("repro-helper-entropy-ctl", "")
      defer: removeDir(tempRoot)
      # The probe case's command line, run by the ENGINE image instead of
      # the helper image: the only difference between this case and the
      # next is the image.
      var argv = probeCommandLine(images, tempRoot, repoRoot)
      check argv[0] == images.helper
      argv[0] = images.engine
      let capture = runMonitored(images.engine, tempRoot / "engine.iomon",
        argv, monitorShimPath(repoRoot))
      checkpoint(capture.output)
      requireRootObserved("engine probe-profile-platforms", capture)
      # The engine ran the role (it did not refuse the command line).
      check "profile root does not exist" in capture.output
      # Only the command's own process counts here. The helper cases below
      # count every root and pid 0, so that nothing they fail to attribute
      # can satisfy them; the control must not be satisfied that way either,
      # by a record attributed to pid 0 or to an unplaced process.
      let draws = entropyFrom(capture.records, launcherRoots(capture.records))
      checkpoint("engine draws: " & draws.join("; "))
      # The monitor sees the draw: without this the helper cases below could
      # pass because nothing was observed.
      check draws.len > 0
    else:
      skip(WindowsOnly)

  test "the profile platform probe's command line draws nothing":
    when defined(windows):
      let repoRoot = getCurrentDir()
      let images = requireImages(repoRoot)
      let tempRoot = createTempDir("repro-helper-entropy-probe", "")
      defer: removeDir(tempRoot)
      let argv = probeCommandLine(images, tempRoot, repoRoot)
      check argv[0] == images.helper
      let capture = runMonitored(images.engine, tempRoot / "probe.iomon",
        argv, monitorShimPath(repoRoot))
      checkpoint(capture.output)
      requireRootObserved("helper probe-profile-platforms", capture)
      # The helper ran its role (the image did not refuse the command line).
      check "profile root does not exist" in capture.output
      let draws = entropyFrom(capture.records, rootPids(capture.records))
      checkpoint("helper draws: " & draws.join("; "))
      check draws.len == 0
    else:
      skip(WindowsOnly)

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
      requireRootObserved("helper render-dev-env-shell", capture)
      check "repro dev-env shell render: error:" in capture.output
      let draws = entropyFrom(capture.records, rootPids(capture.records))
      checkpoint("helper draws: " & draws.join("; "))
      check draws.len == 0
    else:
      skip(WindowsOnly)

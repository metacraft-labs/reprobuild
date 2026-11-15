## The provider session protocol is isolated from whatever the recipe code
## running inside the provider writes, and its frame length is bounded.
##
## Regression test for reprobuild-pm
## ``issues/2026-11-12-protocol-frames-share-stdout-with-recipe-code-and-frame-length-is-unbounded.md``.
## The provider session (Low-Level-Provider-Protocol.md §2) used to carry
## its frames on the provider's fd 0/1 while the recipe's ``build:`` bodies
## ran in the same process. One ``echo`` from a recipe, or from any child
## process it started, landed in the frame stream: the engine decoded the
## first four bytes of the text as a ``u32le`` frame length (``"reci"`` is
## 1 768 121 714), allocated that many bytes before reading them, and then
## waited forever for bytes that would never come. Failure-Semantics.md
## §"Cache And Store Failures" forbids exactly that allocation.
##
## What each case protects:
##
## 1. FRAMING (no provider): ``readFrame`` refuses a length above the
##    negotiated maximum before it allocates, and a length the stream does
##    not deliver costs no more memory than the bytes that did arrive;
##    ``writeFrame`` refuses to send a frame the peer would refuse.
## 2. STDOUT: a recipe whose module top level, ``build:`` body and a child
##    process the body starts all write to stdout still handshakes and
##    returns its real fragment.
## 3. STDIN: a ``build:`` body that reads stdin sees end-of-file, not the
##    engine's frames.
## 4. STDERR: recipe output moved to stderr cannot fill an undrained pipe and
##    stall the session (1 MiB is well past every pipe buffer).
## 5. CRASH: a provider that exits mid-invocation is reported with its exit
##    status and the tail of its stderr, and the pool does not hand the dead
##    session out again (Failure-Semantics.md §"Provider Failures").
## 6. LOST BETWEEN REQUESTS: a provider that is gone when the engine sends
##    the next request is a protocol failure of that request, reported like
##    a crash, and the dead session is not reused.
## 7. ORPHAN WRITER: the failure report is not held up by a process the
##    recipe started that inherits the provider's stderr, outlives the
##    provider and writes without pause. The protocol pipe must reach
##    end-of-file when the provider dies (no inherited copy of it may
##    survive in the child), and the stderr drain must stop although its
##    pipe never goes quiet.
##
## Nothing is mocked. Cases 2-5 compile a real provider binary through the
## RP1 compile edge (``compileProviderBinary``) and drive it through the
## production session code (``openProviderSession`` / ``invokeEntryPoint``),
## exactly as ``t_rp2_provider_session_invoke.nim`` does. Case 1 feeds
## ``readFrame`` an in-memory stream because the property is about the
## decoder, and a byte string is the most direct hostile input.
##
## A watchdog bounds every session case. Before the fix the stdout, stdin
## and stderr cases deadlock (engine and provider each wait for the other),
## and an unbounded test would hide the failure as a hung CI job. When the
## watchdog fires it kills this process's children, which turns the
## deadlock into the engine-side error that names the cause.

import std/[atomics, os, osproc, strutils, streams, tables, times, unittest]
when not defined(windows):
  import std/posix

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl

const providerBody = """
import std/[os, osproc, strutils]
import repro_project_dsl

# Module top level: runs before any provider code reads a frame.
echo "recipe top level: hello"

package rp2noisy:
  build:
    let mode = getEnv("RP2NOISY_MODE")
    echo "build body: hello"
    stdout.write("hell")
    stdout.flushFile()
    discard execCmd("echo build body child process: hello")
    if mode == "flood-stderr":
      let line = repeat('e', 1023) & "\n"
      for i in 0 ..< 1024:
        stderr.write(line)
      stderr.flushFile()
    if mode == "read-stdin":
      let got = stdin.readAll()
      if got.len != 0:
        raise newException(ValueError,
          "build body read " & $got.len & " bytes from stdin")
    let crashMarker = getEnv("RP2NOISY_CRASH_MARKER")
    if crashMarker.len > 0 and fileExists(crashMarker):
      if getEnv("RP2NOISY_ORPHAN_WRITER") == "1":
        # A process that inherits the provider's stderr, outlives it and
        # never stops writing. ``timeout`` bounds it so a regression costs
        # one minute, not a hung job. The pause lets the writer start, so it
        # is mid-stream when the provider exits and the engine stops its
        # stderr drain.
        discard startProcess("timeout", args = ["60", "yes",
          "orphan stderr writer"], options = {poUsePath, poParentStreams})
        sleep(500)
      stderr.writeLine("build body: about to exit with status 3")
      stderr.flushFile()
      quit(3)
"""

const ProviderGraphRequestTypeId = "reprobuild.provider-graph-request.v1"
const ProviderGraphResponseTypeId = "reprobuild.provider-graph-response.v1"

proc rpBytesToStr(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc rpStrToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc rpMarshalRequest(box: ExtensionBox): string {.nimcall.} =
  rpBytesToStr(encodeProviderRequest(
    TypedExtensionBox[ProviderGraphRequest](box).val))

proc rpUnmarshalRequest(jsonStr: string): ExtensionBox {.nimcall.} =
  TypedExtensionBox[ProviderGraphRequest](
    typeId: ProviderGraphRequestTypeId,
    val: decodeProviderRequest(rpStrToBytes(jsonStr)))

proc rpMarshalResponse(box: ExtensionBox): string {.nimcall.} =
  rpBytesToStr(encodeProviderResponse(
    TypedExtensionBox[ProviderGraphResponse](box).val))

proc rpUnmarshalResponse(jsonStr: string): ExtensionBox {.nimcall.} =
  TypedExtensionBox[ProviderGraphResponse](
    typeId: ProviderGraphResponseTypeId,
    val: decodeProviderResponse(rpStrToBytes(jsonStr)))

proc registerCodecs() =
  extensionRegistry[ProviderGraphRequestTypeId] = ExtensionMarshaler(
    marshal: rpMarshalRequest, unmarshal: rpUnmarshalRequest)
  extensionRegistry[ProviderGraphResponseTypeId] = ExtensionMarshaler(
    marshal: rpMarshalResponse, unmarshal: rpUnmarshalResponse)

registerCodecs()

proc marshalRequest(request: ProviderGraphRequest): BoxedValue =
  BoxedValue(typeId: ProviderGraphRequestTypeId,
    jsonStr: extensionRegistry[ProviderGraphRequestTypeId].marshal(
      TypedExtensionBox[ProviderGraphRequest](
        typeId: ProviderGraphRequestTypeId, val: request)))

proc unmarshalResponse(box: BoxedValue): ProviderGraphResponse =
  check box.typeId == ProviderGraphResponseTypeId
  TypedExtensionBox[ProviderGraphResponse](
    extensionRegistry[ProviderGraphResponseTypeId].unmarshal(box.jsonStr)).val

# --------------------------------------------------------------------------
# Watchdog: turns a deadlocked session into a failure instead of a hang.
# --------------------------------------------------------------------------

const WatchdogSeconds = 300
  ## Generous: a healthy session answers in milliseconds, and the provider
  ## is compiled before the watchdog is armed. Only a deadlock reaches it.

var watchdogDeadline: Atomic[int64]
  ## Unix milliseconds after which the watchdog fires; 0 = disarmed.
var watchdogThread: Thread[void]

proc watchdogLoop() {.thread.} =
  while true:
    sleep(250)
    let deadline = watchdogDeadline.load()
    if deadline != 0 and int64(epochTime() * 1000) > deadline:
      watchdogDeadline.store(0)
      stderr.writeLine("watchdog: the provider session made no progress in " &
        $WatchdogSeconds & " s; killing this test's child processes so the " &
        "engine side reports what it was waiting for")
      when defined(windows):
        quit(1)
      else:
        # Kill the direct children (the provider sessions), and only them:
        # a ``sh -c pkill`` would match its own shell and the test would die
        # instead of reporting.
        for line in execProcess("pgrep", args = ["-P",
            $getCurrentProcessId()], options = {poUsePath}).splitLines():
          let pid = line.strip()
          if pid.len > 0 and pid.allCharsInSet({'0' .. '9'}):
            discard posix.kill(Pid(parseInt(pid)), SIGKILL)

createThread(watchdogThread, watchdogLoop)

# --------------------------------------------------------------------------
# Provider fixture
# --------------------------------------------------------------------------

type Provider = tuple[binary, artifactId, projectRoot: string]

proc buildProvider(tempRoot: string): Provider =
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  createDir(extendedPath(projectRoot))
  createDir(extendedPath(outDir))
  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)
  let artifact = extractInterfaceFromModule(modulePath,
    outDir / "noisy-interface.rbsz", outDir / "noisy-interface.nim",
    getCurrentDir())
  let binPath = outDir / "noisy-provider"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, outDir / "noisy-provider-compile.rbsz",
    getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes),
   projectRoot: projectRoot)

let tempRoot = getTempDir() / "provider-protocol-isolation-" &
  $getCurrentProcessId()
removeDir(extendedPath(tempRoot))
var builtProvider: Provider
var providerBuilt = false

proc provider(): Provider =
  ## Compiled once, on first use, and shared by the session cases.
  if not providerBuilt:
    builtProvider = buildProvider(tempRoot)
    providerBuilt = true
  builtProvider

template guarded(body: untyped) =
  ## Arm the watchdog around ``body``. The provider is compiled first, so a
  ## slow compile on a busy host can never be mistaken for a deadlock.
  discard provider()
  watchdogDeadline.store(int64(epochTime() * 1000) + WatchdogSeconds * 1000)
  try:
    body
  finally:
    watchdogDeadline.store(0)

proc artifactRef(p: Provider): ProviderArtifactRef =
  ProviderArtifactRef(binaryPath: p.binary, providerArtifactId: p.artifactId,
    workingDir: getCurrentDir())

proc rootRequest(p: Provider): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: p.artifactId,
    entryPointId: "rp2noisy.root",
    entryPointBodyHash: "rp2noisy.build.v1",
    reason: girColdStart,
    arguments: p.projectRoot,
    namespace: "rp2noisy",
    lockSliceId: "noisy-lock",
    activity: "default")

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp2"],
    lockSliceId: "noisy-lock",
    canonicalExecutionRoot: getCurrentDir())

proc checkRealFragment(res: EntryPointResult) =
  ## The invoke returned the fragment the ``build:`` body produced, by
  ## content, not merely a frame of the right type.
  check res.ok
  check res.hasValue
  for diag in res.diagnostics:
    checkpoint("provider diagnostic: " & diag.message)
  check res.diagnostics.len == 0
  if res.ok and res.hasValue:
    let response = unmarshalResponse(res.value)
    check response.kind == pskGraphResult
    check response.fragment.entryPointId == "rp2noisy.root"
    check response.fragment.namespace == "rp2noisy"
    check response.fragment.fragmentDigest.len > 0
    var sawTargetExportTable = false
    for node in response.fragment.nodes:
      if node.stableName == "reprobuild.target-export-table.v2":
        sawTargetExportTable = true
    check sawTargetExportTable

proc openAndInvoke(pool: ProviderSessionPool): EntryPointResult =
  let p = provider()
  let handle = pool.openProviderSession(p.artifactRef, defaultSessionPolicy(),
    engineHello())
  handle.invokeEntryPoint("rp2noisy.root", @[marshalRequest(rootRequest(p))])

proc frameBytes(length: uint32; tail: string): string =
  ## A frame header claiming ``length`` followed by ``tail``.
  var header: seq[byte] = @[]
  header.writeU32Le(length)
  result = rpBytesToStr(header) & tail

suite "provider session protocol is isolated from recipe output":

  test "readFrame refuses an oversized length before allocating it":
    # Exactly the bytes a recipe ``echo "hello…"`` put in front of the
    # manifest: "hell" read as a u32le length is 1 819 043 176.
    let stream = newStringStream("hello from a recipe\n")
    let peakBefore = getMaxMem()
    var message = ""
    try:
      discard stream.readFrame()
    except ProviderSessionError as err:
      message = err.msg
    # The allocator's PEAK: an up-front allocation that is freed again when
    # the read fails leaves the occupied size unchanged but not the peak.
    let grown = max(0, getMaxMem() - peakBefore)
    checkpoint("readFrame error: " & message)
    checkpoint("peak heap growth while decoding: " & $grown & " bytes")
    check message.contains("1819043176")
    check message.contains("exceeds")
    check grown < 16 * 1024 * 1024

  test "a frame the stream never delivers costs only the bytes that arrived":
    # A length inside the limit whose bytes never arrive (a provider that
    # died mid-frame) must not be allocated up front either.
    let claimed = ProviderSessionMaxFrameLength
    let stream = newStringStream(frameBytes(claimed, "\x03\x00abc"))
    let peakBefore = getMaxMem()
    var message = ""
    try:
      discard stream.readFrame()
    except ProviderSessionError as err:
      message = err.msg
    # The allocator's PEAK: an up-front allocation that is freed again when
    # the read fails leaves the occupied size unchanged but not the peak.
    let grown = max(0, getMaxMem() - peakBefore)
    checkpoint("readFrame error: " & message)
    checkpoint("peak heap growth while decoding: " & $grown & " bytes")
    check message.contains("mid-frame")
    check grown < 16 * 1024 * 1024

  test "the negotiated limit binds both directions":
    var outBuf = newStringStream()
    var refused = false
    try:
      outBuf.writeFrame(smtEntryPointResult, newSeq[byte](1024),
        maxFrameLength = 512)
    except ProviderSessionError as err:
      refused = err.msg.contains("exceeds")
    check refused
    check outBuf.data.len == 0  # nothing partial reached the peer

    outBuf = newStringStream()
    outBuf.writeFrame(smtEntryPointResult, newSeq[byte](100),
      maxFrameLength = 512)
    let inBuf = newStringStream(outBuf.data)
    var message = ""
    try:
      discard inBuf.readFrame(maxFrameLength = 64)
    except ProviderSessionError as err:
      message = err.msg
    check message.contains("exceeds")
    let again = newStringStream(outBuf.data)
    let frame = again.readFrame(maxFrameLength = 512)
    check frame.messageType == smtEntryPointResult
    check frame.payload.len == 100

  test "the provider and the identity layer agree on the protocol version":
    # ProviderArtifactId hashes ProviderProtocolVersionMirror; the session
    # checks ProviderProtocolVersion. A bump to one without the other would
    # let a cached provider speaking the old wire be reused.
    check ProviderProtocolVersionMirror == ProviderProtocolVersion

  test "recipe stdout does not reach the protocol":
    putEnv("RP2NOISY_MODE", "")
    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    guarded:
      let res = openAndInvoke(pool)
      checkRealFragment(res)
      check res.ok and res.hasValue

  test "a build body reading stdin sees end-of-file, not engine frames":
    putEnv("RP2NOISY_MODE", "read-stdin")
    defer: putEnv("RP2NOISY_MODE", "")
    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    guarded:
      let res = openAndInvoke(pool)
      checkRealFragment(res)
      check res.ok and res.hasValue

  test "recipe output on stderr cannot stall the session":
    putEnv("RP2NOISY_MODE", "flood-stderr")
    defer: putEnv("RP2NOISY_MODE", "")
    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    guarded:
      let res = openAndInvoke(pool)
      checkRealFragment(res)
      check res.ok and res.hasValue

  test "a provider that dies mid-invoke is reported and not reused":
    let marker = tempRoot / "crash-marker"
    putEnv("RP2NOISY_MODE", "")
    putEnv("RP2NOISY_CRASH_MARKER", marker)
    defer: delEnv("RP2NOISY_CRASH_MARKER")
    let p = provider()
    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    guarded:
      let handle = pool.openProviderSession(p.artifactRef,
        defaultSessionPolicy(), engineHello())
      writeFile(extendedPath(marker), "")
      var message = ""
      try:
        discard handle.invokeEntryPoint("rp2noisy.root",
          @[marshalRequest(rootRequest(p))])
      except ProviderSessionError as err:
        message = err.msg
      checkpoint("invoke error: " & message)
      check message.contains("exit status 3")
      check message.contains("about to exit with status 3")
      check message.contains(p.artifactId)
      check message.contains("rp2noisy.root")
      check pool.sessionCount == 0

      # The failed session is suspect and is never handed out again: the
      # next open launches a fresh provider.
      removeFile(extendedPath(marker))
      let relaunched = pool.openProviderSession(p.artifactRef,
        defaultSessionPolicy(), engineHello())
      check pool.launchCount == 2
      checkRealFragment(relaunched.invokeEntryPoint("rp2noisy.root",
        @[marshalRequest(rootRequest(p))]))

  when not defined(windows):
    test "a provider lost between requests fails the next one, not the engine":
      putEnv("RP2NOISY_MODE", "")
      let pool = newProviderSessionPool()
      defer: pool.closeAll()
      guarded:
        let p = provider()
        let handle = pool.openProviderSession(p.artifactRef,
          defaultSessionPolicy(), engineHello())
        checkRealFragment(handle.invokeEntryPoint("rp2noisy.root",
          @[marshalRequest(rootRequest(p))]))
        # The session's provider is this process's only child now; kill it
        # and wait until it is gone, so the next write meets a pipe with no
        # reader.
        var killed = 0
        for line in execProcess("pgrep", args = ["-P",
            $getCurrentProcessId()], options = {poUsePath}).splitLines():
          let pid = line.strip()
          if pid.len > 0 and pid.allCharsInSet({'0' .. '9'}):
            if posix.kill(Pid(parseInt(pid)), SIGKILL) == 0:
              inc killed
        check killed == 1
        var waited = 0
        while waited < 5000 and execProcess("pgrep", args = ["-P",
            $getCurrentProcessId(), "-r", "R,S,D,T"],
            options = {poUsePath}).strip().len > 0:
          sleep(20)
          waited += 20
        var message = ""
        try:
          discard handle.invokeEntryPoint("rp2noisy.root",
            @[marshalRequest(rootRequest(p))])
        except ProviderSessionError as err:
          message = err.msg
        checkpoint("invoke error: " & message)
        check message.contains("rp2noisy.root")
        check message.contains("exit status")
        check pool.sessionCount == 0

  when not defined(windows):
    test "a process that outlives the provider cannot hold up the report":
      let marker = tempRoot / "crash-marker"
      putEnv("RP2NOISY_MODE", "")
      putEnv("RP2NOISY_CRASH_MARKER", marker)
      putEnv("RP2NOISY_ORPHAN_WRITER", "1")
      defer:
        delEnv("RP2NOISY_CRASH_MARKER")
        delEnv("RP2NOISY_ORPHAN_WRITER")
        removeFile(extendedPath(marker))
      let p = provider()
      let pool = newProviderSessionPool()
      defer: pool.closeAll()
      guarded:
        let handle = pool.openProviderSession(p.artifactRef,
          defaultSessionPolicy(), engineHello())
        writeFile(extendedPath(marker), "")
        let started = epochTime()
        var message = ""
        try:
          discard handle.invokeEntryPoint("rp2noisy.root",
            @[marshalRequest(rootRequest(p))])
        except ProviderSessionError as err:
          message = err.msg
        let elapsed = epochTime() - started
        checkpoint("invoke error (first 2000 bytes): " &
          message[0 ..< min(message.len, 2000)])
        checkpoint("failure reported after " & $elapsed & " s")
        check message.contains("exit status 3")
        check message.contains("orphan stderr writer")
        # The writer runs for 60 s; a drain that waits for its end-of-file
        # reports after about that long. The bounded stop reports in well
        # under a second; 30 s leaves room for a loaded host.
        check elapsed < 30.0
        check pool.sessionCount == 0

removeDir(extendedPath(tempRoot))

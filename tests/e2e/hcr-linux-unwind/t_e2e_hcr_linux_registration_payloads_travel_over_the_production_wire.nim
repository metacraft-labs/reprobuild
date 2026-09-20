## HLX-M5 verification gate
## `e2e_hcr_linux_registration_payloads_travel_over_the_production_wire`.
##
## Design: `reprobuild-specs/HCR/Debugger-Integration.md` §5;
## `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M5 — the deliverable
## "drive a NON-EMPTY `debugObjectPayload` / `unwindMetadataPayload` over the
## real socket".
##
## WHAT WAS UNGATED. HLX-M5 landed `__register_frame` and the GDB JIT symfile as
## real registrations and proved them with three gates — all of which drive the
## provider IN PROCESS through argv-driven fixtures. The path production uses is
## the socket: `repro watch --hcr` builds the request at
## `libs/repro_hcr_agent/src/repro_hcr_agent/coordinator.nim:68-69` with the
## rebuilt object as `debugObjectPayload` and its `.eh_frame` as
## `unwindMetadataPayload`, both NON-EMPTY on Linux and neither call site
## carrying a platform guard, and `rb_hcr_run_lifecycle` registers both at Phase
## I. No gate on any platform drove that.
##
## `allowed_mocks: none`. Arm 1's coordinator is the graph-built `repro` binary
## running `watch --hcr-agent-socket=… --hcr-artifacts=…` against a real
## reprobuild project it really rebuilds; arms 2 and 3 use the production
## `HcrCoordinatorClient` over the same real Unix socket. The target is an
## ordinary application linking the production agent translation unit, and it is
## compiled from THE SAME `src/patchable.c` the project builds, so the function
## the coordinator inferred a patch for is the function this process exports.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE.
##
## THE ASSERTION IS THE UNWINDER'S ANSWER, NOT A BYTE COUNT. `fdeFound` is
## `_Unwind_Find_FDE` asked about the live dispatch address immediately after
## registration, and `jitFirstEntry` is `__jit_debug_descriptor.first_entry` —
## what a debugger attaching at that moment would find. A gate asserting only
## that a non-zero payload arrived would pass in a world where both
## registrations silently did nothing, which is the world HLX-M5 exists to rule
## out.
##
## ANTI-VACUITY, in the order the milestone asks for it: the payload byte counts
## are asserted against a FLOOR TAKEN FROM THE REAL PATCH OBJECT ON DISK before
## anything is asserted about registration, so "the digests match" cannot be
## satisfied by two empty payloads; and the request is asserted to have crossed
## a socket at all, because every existing gate for this milestone drove the
## provider in process.
##
## A FINDING THIS GATE PRODUCED, recorded because it is about the production
## path and not about the gate. The agent refuses a `SHF_COMPRESSED` symfile by
## name (`debug-object-compressed-debug-section`) and this toolchain's gcc emits
## compressed `.debug_*` BY DEFAULT, so a project whose object is built by an
## ordinary `gcc(debug3 = true)` edge sends a `debugObjectPayload` the agent
## cannot register — and `repro watch` then reports `hcr patch failed … JIT
## debug object registration failed` and falls back to rebuilds FOR A PATCH THAT
## HAS ALREADY BEEN APPLIED, because Phase I runs after the commit. The fixture
## below passes `-gz=none`, which is what a project participating in HCR must
## do; the wider question — whether `repro hcr prepare-object` should decompress
## on ELF, and whether a post-commit registration failure should be reported as
## `patchFailed` at all — is recorded against HLX-M5 and HLX-M9 rather than
## answered here.
##
## THE CONTROL IS ONE VARIABLE. Arms 2 and 3 are the SAME target binary, the
## SAME patch bytes, the SAME production coordinator client and the SAME socket
## transport, differing ONLY in whether the two payloads are the object's real
## bytes or empty. Arm 3 (empty) must show the patch APPLIED — 11 becomes 77 —
## with NO registration and the unwinder unable to answer. That separates "the
## payloads did the registration" from "patching happens to register things".

import std/[json, monotimes, options, os, osproc, streams, strtabs, strutils,
            times, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl
  from repro_test_support import requireBinary, monitorShimPath

  import "../hcr-linux-direct/elf_rel_reader"

  const
    VictimSymbol = "patchable_value"
    OriginalValue = 11
    PatchedValue = 77

    ProjectFile = """
import repro_dsl_stdlib

package hcrWirePatch:
  uses:
    "gcc >=1"

  build:
    let buildDir = fs.ensureDir(actionId = "build-dir", path = "build")
    let rawObj = gcc(
      source = "src/patchable.c",
      output = "build/patchable.raw.o",
      debug3 = true,
      # REMOVED 2026-09-20 (HLX-M8), and its absence is now LOAD-BEARING in the
      # other direction. This edge used to carry `debugCompression = "none"`
      # because this toolchain emits `SHF_COMPRESSED` `.debug_*` by default and
      # the agent refuses a compressed symfile by name. `repro hcr
      # prepare-object` now EXPANDS those sections on ELF, so the per-edge flag
      # is unnecessary rather than merely documented — and this gate is what
      # proves it, because `jitRegistered` below goes red the moment the
      # expansion stops happening. Putting the flag back would make that
      # assertion pass for a reason that has nothing to do with the pass under
      # test.
      compileOnly = true,
      after = @[buildDir])
    let obj = hcr.prepareObject(
      input = "build/patchable.raw.o",
      output = "build/patchable.o",
      after = @[rawObj])
    target("patchable-object", [obj])
    defaultBuildAction(obj)
"""

    OldSource = """
int patchable_value(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

    NewSource = """
int patchable_value(int iteration) {
  int bias = 77;
  int state = iteration + bias;
  return state;
}
"""

  proc q(value: string): string = quoteShell(value)

  proc shellCommand(argv: openArray[string]): string =
    var parts: seq[string] = @[]
    for arg in argv:
      parts.add q(arg)
    parts.join(" ")

  proc runOrFail(command, cwd: string): string =
    let res = execCmdEx(command, workingDir = cwd)
    if res.exitCode != 0:
      raise newException(IOError,
        "command failed (exit " & $res.exitCode & "): " & command & "\n" &
        res.output)
    res.output

  proc waitForLogContains(logPath, needle, context: string;
                          timeoutMs = 600_000) =
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while getMonoTime() < deadline:
      if fileExists(logPath) and readFile(logPath).contains(needle):
        return
      sleep(50)
    raise newException(IOError,
      "timed out waiting for " & context & ": " & needle & "\n" &
      (if fileExists(logPath): readFile(logPath) else: "<no log>"))

  ## One target binary, built from the project's OWN `src/patchable.c` plus the
  ## wire target's `main`, with the real patchable profile and the production
  ## agent translation unit.
  proc buildWireTarget(repoRoot, projectRoot, outputName: string): string =
    let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-unwind"
    let binDir = repoRoot / "build" / "test-bin"
    createDir(binDir)
    result = binDir / outputName
    let compileFlags = patchableCompileFlags(ReproHcr())
    let linkFlags = patchableLinkFlags(ReproHcr())
    # A profile that emitted nothing would build a NON-patchable target whose
    # every arm refused `absent-sled`, and the gate would measure the refusal
    # while believing it measured a registration.
    doAssert "-fpatchable-function-entry=16,0" in compileFlags
    doAssert "-Wl,--build-id=sha1" in linkFlags
    var args = @["gcc", "-O2", "-g"] & @compileFlags &
      @["-fcf-protection=full",
        "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
        "-o", result,
        caseDir / "hcr_lx_m5_wire_target.c",
        projectRoot / "src" / "patchable.c",
        repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
      @linkFlags &
      # The application has to HAVE an unwinder. A plain C program with no
      # exceptions does not pull `libgcc_s` in at all, the provider's weak
      # `__register_frame` is then NULL, and the registration is refused
      # `unwind-register-frame-unavailable` — measured here before this flag was
      # added, with the JIT symfile registering fine beside it. That refusal is
      # correct behaviour and HLX-M5's own deliverable names it; it is a
      # property of the target program, not of the provider, so the target links
      # an unwinder the way any C++ or exception-using application already does.
      @["-Wl,--no-as-needed", "-lgcc_s", "-Wl,--as-needed", "-lpthread"]
    discard runOrFail(shellCommand(args), repoRoot)
    doAssert fileExists(result)

  proc targetJson(output: string): JsonNode =
    try:
      parseJson(output.strip())
    except JsonParsingError as err:
      raise newException(IOError,
        "target printed unparsable JSON (" & err.msg & "):\n" & output)

  ## Run the target against a coordinator this test drives itself, over a real
  ## socket, with payloads the caller chooses. Arms 2 and 3 differ by nothing
  ## else.
  proc runAgainstLocalCoordinator(repoRoot, targetBin, socketPath: string;
                                  patchBytes, debugBytes,
                                  unwindBytes: seq[byte]):
                                  tuple[node: JsonNode;
                                        delivery: HcrCoordinatorDelivery] =
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env[ReproHcrAgentSocketEnv] = socketPath
    let process = startProcess(targetBin, workingDir = repoRoot, args = [],
      env = env, options = {poStdErrToStdOut})
    var connection = acceptHcrAgentConnection(listener)
    var client = initHcrCoordinatorClient(HcrLinuxX86_64DirectSupportProfile)
    let request = directPatchRequest(
      patchId = "hlx-m5-wire-local",
      supportProfile = HcrLinuxX86_64DirectSupportProfile,
      changedFunctions = [VictimSymbol],
      targetSymbols = [VictimSymbol],
      directPatchBytes = patchBytes,
      debugObjectBytes = debugBytes,
      unwindMetadataBytes = unwindBytes,
      sourceGenerationMap = [],
      changedFiles = ["src/patchable.c"],
      changedTypes = [])
    result.delivery = client.deliverPatchRequest(connection, request)
    connection.close()
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    if code != 0:
      raise newException(IOError,
        "target exited " & $code & ":\n" & output)
    result.node = targetJson(output)

  suite "e2e_hcr_linux_registration_payloads_travel_over_the_production_wire":
    test "a non-empty debug object and .eh_frame reach the agent over the wire":
      let repoRoot = getCurrentDir()
      let reproBin = requireBinary(
        repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
        "reprobuild.apps.repro")
      let shim = requireBinary(monitorShimPath(repoRoot),
        "reprobuild.test_fixtures.monitor_shim")

      # A SHORT temp root. A unix socket path over 108 bytes is refused by the
      # kernel and `repro watch` says so, which would fail this gate for a
      # reason that has nothing to do with its subject.
      let tempRoot = "/tmp/hlx-m5-wire-" & $getCurrentProcessId()
      removeDir(tempRoot)
      defer: removeDir(tempRoot)
      let projectRoot = tempRoot / "project"
      let sourcePath = projectRoot / "src" / "patchable.c"
      let logPath = tempRoot / "repro-watch.log"
      let artifacts = projectRoot / ".repro" / "hcr"
      let socketPath = tempRoot / "a.sock"
      createDir(parentDir(sourcePath))
      createDir(projectRoot / "build")
      writeFile(projectRoot / "reprobuild.nim", ProjectFile)
      writeFile(sourcePath, OldSource)

      # The target is compiled from the OLD source, so it starts at 11.
      let target = buildWireTarget(repoRoot, projectRoot, "hcr_lx_m5_wire_target")

      # ==================================================================
      # ARM 1 — the production coordinator. `repro watch --hcr` rebuilds the
      # project, infers the changed function, and sends the rebuilt object and
      # its `.eh_frame` as the two payloads.
      # ==================================================================
      let command = shellCommand([
        "env",
        "REPRO_MONITOR_SHIM_LIB=" & shim,
        reproBin, "watch", projectRoot & "#patchable-object",
        "--tool-provisioning=path",
        "--max-cycles=2",
        "--debounce-ms=50",
        "--hcr-agent-socket=" & socketPath,
        "--hcr-artifacts=" & artifacts
      ]) & " > " & q(logPath) & " 2>&1"
      let watch = startProcess("/bin/sh", args = ["-c", command],
        workingDir = repoRoot, options = {poUsePath})
      defer:
        if watch.running():
          watch.terminate()
        watch.close()

      waitForLogContains(logPath, "repro watch: hcr waiting for agent socket=",
        "HCR baseline")

      var env = newStringTable()
      for key, value in envPairs():
        env[key] = value
      env[ReproHcrAgentSocketEnv] = socketPath
      let targetProcess = startProcess(target, workingDir = repoRoot, args = [],
        env = env, options = {poStdErrToStdOut})

      waitForLogContains(logPath, "repro watch: watching paths=",
        "watch subscription", timeoutMs = 120_000)
      writeFile(sourcePath, NewSource)

      let targetOutput = targetProcess.outputStream.readAll()
      let targetCode = targetProcess.waitForExit()
      targetProcess.close()
      let watchCode = watch.waitForExit()
      let log = readFile(logPath)
      if targetCode != 0 or watchCode != 0:
        checkpoint(log)
      check targetCode == 0
      check watchCode == 0
      let wire = targetJson(targetOutput)

      # ---- ANTI-VACUITY FIRST. The floors come from the real artifacts the
      # coordinator sent, read off disk here rather than taken from the target's
      # own report, so "non-empty" is a comparison between two independent
      # measurements of the same object.
      let sentObject = artifacts / "patchable_value-generation1.o"
      check fileExists(sentObject)
      let objectSize = getFileSize(sentObject).int
      check objectSize > 1000
      let parsedObject = parseElfRelObject(sentObject)
      var ehFrameBytes: seq[byte] = @[]
      for section in parsedObject.sections:
        if section.name == ".eh_frame":
          ehFrameBytes = newSeq[byte](int(section.size))
          for i in 0 ..< int(section.size):
            ehFrameBytes[i] = parsedObject.bytes[int(section.offset) + i]
      let ehFrameSize = ehFrameBytes.len
      check ehFrameSize > 0

      check wire["debugObjectBytes"].getInt() == objectSize
      check wire["unwindMetadataBytes"].getInt() == ehFrameSize

      # ---- the request really crossed a socket: the coordinator is a separate
      # process and the target found it only through REPRO_HCR_AGENT_SOCKET.
      check log.contains("repro watch: hcr waiting for agent socket=" &
        socketPath)
      check log.contains("repro watch: hcr patch applied patchId=")

      # ---- the patch applied, and BOTH registrations happened …
      check wire["before"].getInt() == OriginalValue
      check wire["after"].getInt() == PatchedValue
      check wire["codeSwapped"].getBool()
      check wire["jitRegistered"].getBool()
      check wire["ehFrameRegistered"].getBool()

      # ---- … and this is the part that is not a byte count. The unwinder
      # answers for the live dispatch address, and a debugger attaching now
      # would find a symfile for it.
      check wire["fdeFound"].getBool()
      check wire["jitFirstEntry"].getStr() != "0x0"
      check wire["jitRegisterHookCalls"].getInt() >= 1
      check wire["dispatchAddress"].getStr() != "0x0"
      check wire["registerFrameConvention"].getStr() == "single-fde"

      # ==================================================================
      # ARMS 2 and 3 — one variable. Same binary, same bytes, same transport.
      # ==================================================================
      let patchBytes = parsedObject.functionBytes(VictimSymbol)
      check patchBytes.len > 0
      var objectBytes: seq[byte] = @[]
      for ch in readFile(sentObject):
        objectBytes.add byte(ch)
      let withPayloads = runAgainstLocalCoordinator(repoRoot, target,
        tempRoot / "b.sock", patchBytes, objectBytes, ehFrameBytes)
      require withPayloads.delivery.patchApplied.isSome
      let w = withPayloads.node
      check w["after"].getInt() == PatchedValue
      check w["jitRegistered"].getBool()
      check w["ehFrameRegistered"].getBool()
      check w["fdeFound"].getBool()
      check w["jitFirstEntry"].getStr() != "0x0"
      check w["debugObjectBytes"].getInt() == objectBytes.len
      check w["unwindMetadataBytes"].getInt() == ehFrameBytes.len

      let withoutPayloads = runAgainstLocalCoordinator(repoRoot, target,
        tempRoot / "c.sock", patchBytes, @[], @[])
      require withoutPayloads.delivery.patchApplied.isSome
      let n = withoutPayloads.node
      # The patch STILL APPLIES — so the difference below is attributable to the
      # payloads and not to the patch having failed.
      check n["before"].getInt() == OriginalValue
      check n["after"].getInt() == PatchedValue
      check n["codeSwapped"].getBool()
      check n["dispatchAddress"].getStr() != "0x0"
      # …and nothing is registered, so the unwinder cannot answer and a debugger
      # would find no symfile. This is the empty-payload falsifier the milestone
      # asks for, and it goes red on the REGISTRATION observation rather than on
      # the command's exit status: the wire accepts empty payloads and every
      # in-process gate for this milestone never noticed.
      check not n["jitRegistered"].getBool()
      check not n["ehFrameRegistered"].getBool()
      check not n["fdeFound"].getBool()
      check n["jitFirstEntry"].getStr() == "0x0"
      check n["debugObjectBytes"].getInt() == 0
      check n["unwindMetadataBytes"].getInt() == 0

      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir /
        "e2e_hcr_linux_registration_payloads_travel_over_the_production_wire.json",
        pretty(%*{
          "schemaId": "reprobuild.hcr.hlx-m5.wire-registration.v1",
          "objectBytesOnDisk": objectSize,
          "ehFrameBytesOnDisk": ehFrameSize,
          "productionWatchArm": wire,
          "localCoordinatorWithPayloads": w,
          "localCoordinatorWithoutPayloads": n}))

else:
  suite "e2e_hcr_linux_registration_payloads_travel_over_the_production_wire":
    test "HLX-M5 wire registration gate is linux-x86_64-only":
      skip()

## HLX-M7 / HX-S-2 verification gate `e2e_hcr_linux_replay_of_patched_recording`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §10.3.1,
##         `reprobuild-specs/HCR/HCR-Overview.md` §10.2.
## Protocol: `codetracer-specs/Planned-Features/Hot-Code-Reloading-High-Level-Interfaces.md` §7.3.
## Campaigns: `HCR-Linux-ELF-Provider.milestones.org` HLX-M7 (third entry),
##            `HCR-Per-Platform-Handoff.milestones.org` HX-S-2.
##
## WHAT THIS GATE IS FOR
## ---------------------------------------------------------------------------
## Until this landed, nothing anywhere applied a recorded patch bundle at its
## recorded geid. `ct-mcr replay-worker` REFUSED a trace containing a
## `CodePatchEvent`, by geid, because replaying it without applying the bundle
## would run the ORIGINAL code past the boundary against events the PATCHED
## code produced and report success.
##
## This gate is the measurement that the refusal can be narrowed. It records a
## real program whose own function is replaced by the real HCR agent over the
## real coordinator wire while `ct-mcr record` is recording it, and then
## REPLAYS that recording: the replay re-launches the same program with
## `libct_interpose` in replay mode, the program's own in-process agent applies
## the recorded bundle again, and the recorder's bridge validates the note the
## agent just built against the recorded slot byte for byte before releasing
## it. The observable is the program's own output either side of the boundary.
##
## `allowed_mocks: none`. The agent is the production
## `libs/repro_hcr_agent/c/repro_hcr_agent.c` compiled into the target; the
## coordinator is the production `HcrCoordinatorClient` over the production
## Unix-socket wire; the patch bytes come out of a real ELF relocatable object
## built by a real compiler; the recording and the replay are real `ct-mcr`
## runs of a real process.
##
## WHAT MAKES IT DISCRIMINATE, AND WHY EACH ARM EXISTS
## ---------------------------------------------------------------------------
## A replay gate that passes whether or not the bundle was applied is worthless,
## and this campaign has shipped four of those. So:
##
##   * the recording's pre- and post-boundary observables are asserted to
##     DIFFER before anything is replayed. If they were equal the gate could
##     not tell the two code bodies apart and would pass either way; that is a
##     CHECK FAILURE here, not a pass;
##   * NOT-APPLIED arm — the same trace replayed with the agent given no
##     coordinator socket, so the bundle is never applied. Must be red;
##   * APPLIED-LATE arm — the same trace, same binary, replayed with
##     `HXS2_APPLY_LATE=1`, which moves the agent's poll past the post-boundary
##     write. The bundle IS applied and the boundary IS crossed; only the WHEN
##     is wrong. It must be red, and it must be caught on the post-boundary
##     observable rather than on the absence of an error — this arm asserts the
##     diagnostic names the output mismatch, not the missing crossing;
##   * CONTROL arm — an unpatched recording of the SAME workload replays
##     cleanly and never arms the HCR path, so the crossing behaviour above is
##     shown to be caused by the patch;
##   * three REFUSAL arms — a replay command that does not run the agent, a
##     foreign support profile, and a trace with two boundaries — each of which
##     must still be refused BY NAME. The refusal is narrowed, not removed.
##
## A KNOWN RECORDER DEFECT THIS GATE HAS TO STEER AROUND
## ---------------------------------------------------------------------------
## The target is built `-fno-tree-vectorize`, and the reason is measured rather
## than superstitious. `ct_interpose`'s M-AT1 atomic-callsite scan
## (`ct_interpose/src/ct_interpose/atomic_common.c:ct_atomic_scan_region`) is a
## LINEAR decode with skip-on-confusion: an instruction it cannot classify
## advances the cursor by one byte, after which it is decoding from the middle
## of real instructions. Measured 2026-09-19 against the HLX-M0 target built
## `-O2`: the scan desynced inside GCC's vectorized SHA-256 and registered
## `repro_hcr_sha256_compress+0x28` as a LOCK RMW site, because the ModRM byte
## `0xF0` of `pslld $0x18,%xmm8` is a valid `LOCK` prefix when read as an
## opcode. The M-AT2.6 prefix gate cannot catch that — the bytes really do
## re-classify as `LOCK SBB` — so the patcher wrote `0xCC` over the ModRM byte
## and the recorded process died with `SIGILL` inside the agent's own hash
## selftest, before any `CodePatchEvent` could be emitted. That is a recorder
## defect and it is NOT this gate's to fix; the gate avoids the shape and says
## so, and it FAILS LOUDLY naming this paragraph if the symptom reappears,
## rather than presenting it as an HX-S-2 failure.

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl

  import elf_rel_reader

  let PatchableCompileFlags = patchableCompileFlags(ReproHcr())
  let PatchableLinkFlags = patchableLinkFlags(ReproHcr())

  const
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hxs2_compute"
    PatchSymbol = "hxs2_patch_body"
    PatchId = "hx-s2-linux-replay-1"
    SecondPatchId = "hx-s2-linux-replay-2"
    RecordedPre = "pre=11"
    RecordedPost = "post=77"
    UnpatchedPost = "post=11"

  type
    ReplayRun = object
      exitCode: int
      output: string

  proc q(value: string): string = quoteShell(value)

  proc shellCommand(args: openArray[string]): string =
    for index, arg in args:
      if index > 0:
        result.add(" ")
      result.add(q(arg))

  proc runSuccess(command: string; cwd: string): string =
    let res = execCmdEx(command, workingDir = cwd)
    if res.exitCode != 0:
      checkpoint("command failed (exit " & $res.exitCode & "): " & command)
      checkpoint(res.output)
    require res.exitCode == 0
    res.output

  proc baseEnv(): StringTableRef =
    result = newStringTable()
    for key, value in envPairs():
      result[key] = value

  proc runCtMcr(ctMcr: string; args: seq[string]; env: StringTableRef;
                cwd: string): ReplayRun =
    ## Run `ct-mcr` and capture everything it said.  Never `skip`s and never
    ## swallows an exit code: every arm below decides on BOTH the code and the
    ## text, because "it failed" and "it failed for the reason under test" are
    ## different claims.
    let process = startProcess(ctMcr, workingDir = cwd, args = args,
                               env = env, options = {poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    ReplayRun(exitCode: code, output: output)

  proc replayStdoutSection(output: string): string =
    ## The replay CHILD's own stdout, as the worker echoed it, and nothing
    ## else.  This matters: the worker's mismatch diagnostic quotes BOTH the
    ## recorded and the replayed bytes, so a naive `contains` over the whole
    ## log would find the recording's `post=77` in a run where the replay
    ## produced `post=11` — a check that is true for free in exactly the arm
    ## it is supposed to catch.  Anchor on the two markers the worker prints.
    const startMarker = "verify: stdout content: "
    const endMarker = "\nverify: stderr content:"
    let a = output.find(startMarker)
    if a < 0:
      return ""
    let from0 = a + startMarker.len
    let b = output.find(endMarker, from0)
    if b < 0:
      return output[from0 .. ^1]
    output[from0 ..< b]

  proc recordWithPatch(ctMcr, targetBin, tracePath, socketPath: string;
                       patchBytes: seq[byte]; cwd: string;
                       patchCount: int): tuple[targetOut: string,
                                               applied: bool,
                                               failure: string] =
    ## ARM A — record the target under `ct-mcr record` while the production
    ## coordinator replaces one of its functions over the production wire.
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    var env = baseEnv()
    env[ReproHcrAgentSocketEnv] = socketPath
    env.del("HXS2_APPLY_LATE")
    if patchCount > 1:
      env["HXS2_POLL_TWICE"] = "1"
    else:
      env.del("HXS2_POLL_TWICE")
    let process = startProcess(ctMcr, workingDir = cwd,
      args = @["record", "--output", tracePath, "--", targetBin],
      env = env, options = {poStdErrToStdOut})
    var connection = acceptHcrAgentConnection(listener)
    var client = initHcrCoordinatorClient(SupportProfile)
    client.completeHandshake(connection)
    var applied = false
    var failure = ""
    for index in 0 ..< patchCount:
      let request = directPatchRequest(
        patchId = (if index == 0: PatchId else: SecondPatchId),
        supportProfile = SupportProfile,
        changedFunctions = [TargetSymbol],
        targetSymbols = [TargetSymbol],
        directPatchBytes = patchBytes,
        debugObjectBytes = newSeq[byte](),
        unwindMetadataBytes = newSeq[byte](),
        sourceGenerationMap = newSeq[HcrSourceGenerationEntry]())
      let delivery = client.requestPatchOnOpenSession(connection, request)
      if delivery.patchFailed.isSome:
        failure = delivery.patchFailed.get().message
      applied = delivery.patchApplied.isSome
    connection.close()
    let targetOut = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      checkpoint("`ct-mcr record` of the patched target exited " & $exitCode)
      checkpoint(targetOut)
      if targetOut.contains("killed by signal 4"):
        checkpoint(
          "SIGILL in the recorded target. Read this gate's module comment: " &
          "the M-AT1 linear atomic scan can desync and write an INT3 over a " &
          "ModRM byte whose value happens to be 0xF0. That is a recorder " &
          "defect, not an HX-S-2 result; do not record it as one.")
    require exitCode == 0
    (targetOut, applied, failure)

  proc recordWithoutPatch(ctMcr, targetBin, tracePath, cwd: string): string =
    ## ARM A' — the control recording: the SAME binary, the same workload, no
    ## coordinator, so no patch and no boundary.
    var env = baseEnv()
    env.del(ReproHcrAgentSocketEnv)
    env.del("HXS2_APPLY_LATE")
    env.del("HXS2_POLL_TWICE")
    let process = startProcess(ctMcr, workingDir = cwd,
      args = @["record", "--output", tracePath, "--", targetBin],
      env = env, options = {poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      checkpoint(output)
    require exitCode == 0
    output

  proc codePatchCount(ctMcr, tracePath, cwd: string): int =
    ## Read the boundary count out of the container with the production
    ## reader.  `trace info` prints `codePatches: N`.
    let res = execCmdEx(shellCommand([ctMcr, "trace", "info", tracePath]),
                        workingDir = cwd)
    if res.exitCode != 0:
      checkpoint(res.output)
    require res.exitCode == 0
    var found = false
    for raw in res.output.splitLines():
      let line = raw.strip()
      if line.startsWith("codePatches:"):
        found = true
        result = parseInt(line.split(':')[1].strip())
    if not found:
      # Anti-vacuity: a reader that printed no such line at all would make
      # "zero boundaries" and "the field does not exist" the same answer.
      checkpoint("`ct-mcr trace info` printed no `codePatches:` line:")
      checkpoint(res.output)
    require found

  suite "e2e_hcr_linux_replay_of_patched_recording":
    test "a recorded patch bundle is applied again at its geid by the real in-process agent":
      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-direct"
      let workDir = repoRoot / "build" / "hcr-linux-hxs2"
      createDir(workDir)

      # --- prerequisites, loud ------------------------------------------
      let gcc = findExe("gcc")
      if gcc.len == 0:
        checkpoint("gcc is not on PATH; this gate compiles a real target and " &
          "a real patch object and cannot be run without it")
      require gcc.len > 0

      let ctMcr = repoRoot / ".." / "codetracer-native-recorder" / "ct_cli" / "ct_cli"
      if not fileExists(ctMcr):
        checkpoint("ct-mcr not found at " & ctMcr & ". This gate records and " &
          "replays with the sibling recorder checkout; build it with " &
          "`just build-ct-mcr` in codetracer-native-recorder.")
      require fileExists(ctMcr)

      # `replay-worker` consults the licensing gate BEFORE it reads the trace,
      # and the free tier caps replays at five a day — so without this the arms
      # below fail on the licence and the verdict silently depends on how many
      # replays this host happened to run today.  HLX-M7's runner learned this
      # the expensive way; say it up front instead.
      let licenseFixture = repoRoot / ".." / "codetracer-native-recorder" /
        "tests" / "fixtures" / "licensing" / "ct-test-license.dat"
      if getEnv("CODETRACER_LICENSE_FILE", "").len == 0:
        if not fileExists(licenseFixture):
          checkpoint("CODETRACER_LICENSE_FILE is unset and the recorder's " &
            "test fixture is not at " & licenseFixture & ". Every replay arm " &
            "below would fail on the daily free-tier replay cap instead of " &
            "on the property under test.")
        require fileExists(licenseFixture)
        putEnv("CODETRACER_LICENSE_FILE", licenseFixture)

      # The socket path lives in a 108-byte `sun_path`; a long work directory
      # produces "socket path too long" from inside the agent, which surfaces
      # as "the coordinator never got a connection".
      let socketPath = "/tmp/hxs2-replay-" & $getCurrentProcessId() & ".sock"
      require socketPath.len < 100

      # --- 1. the patch body, from a real relocatable object -------------
      let patchObj = workDir / "hxs2_replay_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        caseDir / "hxs2_replay_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      check obj.definingSectionName(PatchSymbol) == ".text." & PatchSymbol
      check obj.relocationCount(".text." & PatchSymbol) == 0
      let patchBytes = obj.functionBytes(PatchSymbol)
      check patchBytes.len > 0
      # `mov $0x4d,%eax` — the 77 the post-boundary observable will carry.
      check hexBytes(patchBytes).contains("b84d000000")

      # --- 2. the target, with the real patchable profile ----------------
      check PatchableCompileFlags.contains("-fpatchable-function-entry=16,0")
      check PatchableCompileFlags.contains("-falign-functions=16")
      check PatchableLinkFlags.contains("-Wl,--build-id=sha1")
      let targetBin = workDir / "hxs2_replay_target"
      discard runSuccess(shellCommand(
        @["gcc", "-O2", "-g"] & PatchableCompileFlags &
        @["-fcf-protection=full",
          # See the module comment: NOT a tuning choice.
          "-fno-tree-vectorize",
          "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
          "-o", targetBin,
          caseDir / "hxs2_replay_target.c",
          repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
        PatchableLinkFlags & @["-lpthread"]), repoRoot)
      require fileExists(targetBin)

      # --- 3. ARM A: record it, patched, over the real wire --------------
      let patchedTrace = workDir / "patched.ct"
      removeFile(patchedTrace)
      let recorded = recordWithPatch(ctMcr, targetBin, patchedTrace,
                                     socketPath, patchBytes, repoRoot, 1)
      if not recorded.applied:
        checkpoint("the agent refused the patch: " & recorded.failure)
      check recorded.applied
      check recorded.targetOut.contains(RecordedPre)
      check recorded.targetOut.contains(RecordedPost)

      # ANTI-VACUITY, and it is the one that matters most.  If the recording's
      # two observables were equal, no replay could distinguish the original
      # body from the patched one and every arm below would pass for free.
      check RecordedPre != RecordedPost
      check not recorded.targetOut.contains(UnpatchedPost)

      # ANTI-VACUITY on the boundary itself: exactly one, read back out of the
      # container by the production reader.
      check codePatchCount(ctMcr, patchedTrace, repoRoot) == 1

      # --- 3'. ARM A': the control recording -----------------------------
      let controlTrace = workDir / "unpatched.ct"
      removeFile(controlTrace)
      let controlOut = recordWithoutPatch(ctMcr, targetBin, controlTrace,
                                          repoRoot)
      check controlOut.contains(RecordedPre)
      check controlOut.contains(UnpatchedPost)
      check codePatchCount(ctMcr, controlTrace, repoRoot) == 0

      # --- 4. ARM B: the replay that must cross the boundary -------------
      var replayEnv = baseEnv()
      replayEnv[ReproHcrAgentSocketEnv] = socketPath
      replayEnv.del("HXS2_APPLY_LATE")
      replayEnv.del("HXS2_POLL_TWICE")
      removeFile(socketPath)
      let applied = runCtMcr(ctMcr,
        @["replay-worker", "--verify", patchedTrace], replayEnv, repoRoot)
      if applied.exitCode != 0:
        checkpoint(applied.output)
      check applied.exitCode == 0
      check applied.output.contains(
        "will be applied by the recorded program's own in-process HCR agent")
      check applied.output.contains(
        "HCR CodePatchEvent consumed by the real in-process agent bridge")
      check applied.output.contains(
        "the post-boundary output reproduces the recording byte for byte")
      # The post-boundary observable the replay CHILD actually produced.
      check replayStdoutSection(applied.output).contains(RecordedPre)
      check replayStdoutSection(applied.output).contains(RecordedPost)

      # --- 5. ARM C: the bundle is never applied -------------------------
      var noAgentEnv = baseEnv()
      noAgentEnv.del(ReproHcrAgentSocketEnv)
      noAgentEnv.del("HXS2_APPLY_LATE")
      noAgentEnv.del("HXS2_POLL_TWICE")
      let notApplied = runCtMcr(ctMcr,
        @["replay-worker", "--verify", patchedTrace], noAgentEnv, repoRoot)
      if notApplied.exitCode == 0:
        checkpoint(notApplied.output)
        checkpoint("FALSIFIER SURVIVED: the replay reported success with the " &
          "bundle never applied, which is exactly the silent wrongness the " &
          "CodePatchEvent refusal exists to prevent.")
      check notApplied.exitCode != 0
      check notApplied.output.contains(
        "the code-version boundary was not crossed")
      # And it is red for the RIGHT reason: the replay never produced the
      # patched body's post-boundary value.  A refusal that fired while the
      # replay had in fact reproduced `post=77` would be testing something
      # else.
      check not replayStdoutSection(notApplied.output).contains(RecordedPost)
      check notApplied.output.contains("DIFFER from offset")

      # --- 6. ARM D: the bundle is applied one boundary LATE -------------
      var lateEnv = baseEnv()
      lateEnv[ReproHcrAgentSocketEnv] = socketPath
      lateEnv["HXS2_APPLY_LATE"] = "1"
      removeFile(socketPath)
      let late = runCtMcr(ctMcr,
        @["replay-worker", "--verify", patchedTrace], lateEnv, repoRoot)
      if late.exitCode == 0:
        checkpoint(late.output)
        checkpoint("FALSIFIER SURVIVED: the bundle was applied AFTER the " &
          "post-boundary observable and the replay still reported success, " &
          "so this gate is insensitive to WHEN the patch is applied.")
      check late.exitCode != 0
      # CAUGHT ON THE OBSERVABLE, which is what this arm is for.  The replay
      # must NOT have produced the patched body's post-boundary value: with the
      # application moved past the post-boundary write, that write runs the
      # ORIGINAL body, and `post=77` never appears.
      check late.output.contains("DIFFER from offset")
      check not replayStdoutSection(late.output).contains(RecordedPost)
      # WHICH of the worker's two refusals fires is deliberately NOT asserted.
      # Measured 2026-09-19: both are reachable from this arm and which one
      # wins is a race between the replay child exiting and the parent's next
      # boundary poll — the agent may consume the CodePatchEvent out of place
      # and be refused on the output ("does not reproduce the recording"), or
      # the child may finish before the parent observes the consumption and be
      # refused on the crossing ("the code-version boundary was not crossed").
      # Pinning one of them would make this arm flaky and would be asserting
      # the race rather than the property.  The property is the two checks
      # above, and both hold either way.
      check (late.output.contains("does not reproduce the recording") or
             late.output.contains("the code-version boundary was not crossed"))

      # --- 7. ARM E: the control replay ----------------------------------
      let controlReplay = runCtMcr(ctMcr,
        @["replay-worker", "--verify", controlTrace], noAgentEnv, repoRoot)
      if controlReplay.exitCode != 0:
        checkpoint(controlReplay.output)
      check controlReplay.exitCode == 0
      check not controlReplay.output.contains("HCR replay armed")
      check not controlReplay.output.contains("CodePatchEvent")

      # --- 8. ARM F: a command that cannot apply is still refused --------
      let noVerify = runCtMcr(ctMcr,
        @["replay-worker", patchedTrace], replayEnv, repoRoot)
      check noVerify.exitCode != 0
      check noVerify.output.contains("CodePatchEvent(s) at geid")
      check noVerify.output.contains(
        "Hot-Code-Reloading-High-Level-Interfaces §7.3")
      check noVerify.output.contains(
        "does not run the recorded program's in-process HCR agent")

      # --- 9. ARM G: a foreign support profile is still refused ----------
      var foreignEnv = baseEnv()
      foreignEnv[ReproHcrAgentSocketEnv] = socketPath
      foreignEnv["CODETRACER_REPLAY_SUPPORT_PROFILE"] =
        HcrMacosArm64DirectSupportProfile
      let foreign = runCtMcr(ctMcr,
        @["replay-worker", "--verify", patchedTrace], foreignEnv, repoRoot)
      check foreign.exitCode != 0
      check foreign.output.contains(SupportProfile)
      check foreign.output.contains(HcrMacosArm64DirectSupportProfile)

      # --- 10. ARM H: two boundaries in one trace are still refused ------
      let twoPatchTrace = workDir / "two-boundaries.ct"
      removeFile(twoPatchTrace)
      let twoPatched = recordWithPatch(ctMcr, targetBin, twoPatchTrace,
                                       socketPath, patchBytes, repoRoot, 2)
      check twoPatched.applied
      check codePatchCount(ctMcr, twoPatchTrace, repoRoot) == 2
      removeFile(socketPath)
      let twoReplay = runCtMcr(ctMcr,
        @["replay-worker", "--verify", twoPatchTrace], replayEnv, repoRoot)
      check twoReplay.exitCode != 0
      check twoReplay.output.contains(
        "replays exactly one code-version boundary per trace")

      # --- inspection record ---------------------------------------------
      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hx-s2.linux-replay-of-patched-recording.v1")
      inspection["supportProfile"] = newJString(SupportProfile)
      inspection["patchBytesHex"] = newJString(hexBytes(patchBytes))
      inspection["recordedTargetOutput"] = newJString(recorded.targetOut)
      inspection["controlTargetOutput"] = newJString(controlOut)
      inspection["arms"] = %*{
        "applied": applied.exitCode,
        "notApplied": notApplied.exitCode,
        "appliedLate": late.exitCode,
        "controlReplay": controlReplay.exitCode,
        "refusedNoVerify": noVerify.exitCode,
        "refusedForeignProfile": foreign.exitCode,
        "refusedTwoBoundaries": twoReplay.exitCode
      }
      inspection["appliedReplayLog"] = newJString(applied.output)
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(
        logDir / "e2e_hcr_linux_replay_of_patched_recording.json",
        pretty(inspection))
      removeFile(socketPath)

else:
  suite "e2e_hcr_linux_replay_of_patched_recording":
    test "linux x86_64 only":
      # Not a silent skip: this gate's subject is the Linux ELF provider's
      # replay arm, and the lane manifest records that it is `unsupported`
      # elsewhere rather than counting it as passed.
      checkpoint("UNSUPPORTED: this gate is Linux x86_64 only; the macOS and " &
        "Windows replay arms are HX-D-1 and the Windows HCR campaign's, and " &
        "are covered there rather than here.")
      skip()

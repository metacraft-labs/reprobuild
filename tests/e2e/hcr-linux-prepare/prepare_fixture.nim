## Shared build/run helpers for the two HLX-M8 `prepare-object` gates.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.1, §8.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8 — the residue
## items "`repro hcr prepare-object` could decompress `SHF_COMPRESSED`
## `.debug_*` on ELF, and does not" and "a Phase I registration failure is
## reported as `patchFailed` for a patch that IS LIVE".
##
## Both gates need the same four things: a patch object built by a real
## compiler at `-g3` with NO `-gz` override, the same object put through the
## real `repro hcr prepare-object`, a target binary on the real patchable
## profile linking the production C agent, and a way to deliver a patch to it
## over a real Unix socket with a payload the gate chooses. Duplicating that is
## how two gates end up compiling different things and only one of them
## exercising the code under test.
##
## NOTHING HERE SKIPS. `requireTool` FAILS with a remedy when a prerequisite is
## missing. In particular `objcopy` is REQUIRED, not optional: it is the
## independent producer the expansion is checked against, and a gate that
## silently dropped that check would be asserting only that this repository's
## decoder agrees with itself.

import std/[json, os, osproc, streams, strtabs, strutils]

import repro_hcr_agent
import repro_project_dsl

const
  VictimSymbol* = "patchable_value"
  OriginalValue* = 11
  PatchedValue* = 77

  ## One function, two constants. The single returned integer is what
  ## distinguishes "the code is live" from "the patch was refused", and it is
  ## read out of the running process rather than off the wire.
  OldSource* = """
int patchable_value(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

  NewSource* = """
int patchable_value(int iteration) {
  int bias = 77;
  int state = iteration + bias;
  return state;
}
"""

proc q*(value: string): string = quoteShell(value)

proc shellCommand*(argv: openArray[string]): string =
  var parts: seq[string] = @[]
  for arg in argv:
    parts.add q(arg)
  parts.join(" ")

proc runOrFail*(command, cwd: string): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError,
      "command failed (exit " & $res.exitCode & "): " & command & "\n" &
      res.output)
  res.output

proc requireTool*(name, gate, remedy: string): string =
  ## A missing prerequisite FAILS with the remedy in the transcript. It does
  ## not `skip()`: a skip that exits 0 reports that this host has a working
  ## `prepare-object`, which is the silent self-pass
  ## `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md` exists to
  ## stop.
  result = findExe(name)
  if result.len == 0:
    raise newException(IOError,
      gate & " requires `" & name & "` on PATH and it is absent. " & remedy)

proc compilePatchObject*(workDir, sourcePath, outputName: string;
                         gz = ""): string =
  ## `-g3` with NO `-gz` unless the caller asks for one. That absence is the
  ## subject: this toolchain's gcc emits `SHF_COMPRESSED` `.debug_*` by
  ## DEFAULT, so the plain spelling is the one a project would write and the
  ## one that used to produce an unregisterable payload.
  result = workDir / outputName
  var args = @["gcc", "-O2", "-g3", "-c", sourcePath, "-o", result]
  if gz.len > 0:
    args.add "-gz=" & gz
  discard runOrFail(shellCommand(args), workDir)
  doAssert fileExists(result)

proc buildWireTarget*(repoRoot, workDir, sourcePath, outputName: string):
    string =
  ## The target is an ORDINARY application: it links the production agent
  ## translation unit, exports one patchable function compiled from
  ## `sourcePath`, and reports what the registration DID rather than what the
  ## wire said. `hcr_lx_m5_wire_target.c` is reused by path rather than copied
  ## — one target implementation, one behaviour.
  result = workDir / outputName
  let m5Dir = repoRoot / "tests" / "e2e" / "hcr-linux-unwind"
  let compileFlags = patchableCompileFlags(ReproHcr())
  let linkFlags = patchableLinkFlags(ReproHcr())
  # A profile that emitted nothing would build a NON-patchable target whose
  # every arm refused `absent-sled`, and a gate would measure that refusal
  # while believing it measured a registration.
  doAssert "-fpatchable-function-entry=16,0" in compileFlags
  doAssert "-Wl,--build-id=sha1" in linkFlags
  var args = @["gcc", "-O2", "-g"] & @compileFlags &
    @["-fcf-protection=full",
      "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
      "-o", result,
      m5Dir / "hcr_lx_m5_wire_target.c",
      sourcePath,
      repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
    @linkFlags &
    # The application has to HAVE an unwinder, or `__register_frame` is NULL
    # and the eh_frame arm refuses `unwind-register-frame-unavailable` for a
    # reason that is a property of the target and not of the payload.
    @["-Wl,--no-as-needed", "-lgcc_s", "-Wl,--as-needed", "-lpthread"]
  discard runOrFail(shellCommand(args), repoRoot)
  doAssert fileExists(result)

proc targetJson*(output: string): JsonNode =
  try:
    parseJson(output.strip())
  except JsonParsingError as err:
    raise newException(IOError,
      "target printed unparsable JSON (" & err.msg & "):\n" & output)

type
  WireArm* = object
    ## One delivery: what the process observed, and what the coordinator was
    ## told. Two producers of the same event, kept separate on purpose.
    node*: JsonNode
    delivery*: HcrCoordinatorDelivery

proc deliverPatch*(repoRoot, targetBin, socketPath: string;
                   patchBytes, debugBytes, unwindBytes: seq[byte]): WireArm =
  ## Run the target against a coordinator this gate drives itself, over a real
  ## Unix socket, with payloads the caller chooses. Arms differ by nothing
  ## else.
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
    patchId = "hlx-m8-prepare-" & $getCurrentProcessId(),
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
    raise newException(IOError, "target exited " & $code & ":\n" & output)
  result.node = targetJson(output)

proc fileBytes*(path: string): seq[byte] =
  result = @[]
  for ch in readFile(path):
    result.add byte(ch)

proc writeEvidence*(repoRoot, gate: string; node: JsonNode) =
  let logDir = repoRoot / "test-logs"
  createDir(logDir)
  writeFile(logDir / (gate & ".json"), pretty(node))

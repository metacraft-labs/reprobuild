## Shared build/run helpers for the HLX-M8 gates (the `rb_hcr_*` application
## ABI).
##
## Design: `reprobuild-specs/HCR/HCR-Overview.md` §7.4, §13;
## `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1, §3.3, §3.4;
## `reprobuild-specs/HCR/Linux-ELF-Provider.md` §9.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
## Cross-repo contract: `isonim/tests/helpers/hcr_stub.nim`.
##
## Nothing here mocks anything. Every gate that uses it builds ONE real target
## process against the PRODUCTION C agent, talks to it over the real agent Unix
## socket with the production `HcrCoordinatorClient`, and reads the target's own
## printed observations — the victim's return value and its entry bytes, taken
## inside the callbacks — rather than the agent's bookkeeping.
##
## FALSIFIER BUILDS ARE FIRST-CLASS. `buildTarget` takes `-D` defines so a gate
## can build the SAME target against an agent with exactly one property
## removed, run the SAME arm, and measure that it goes red. Three exist, each
## `#ifdef`-guarded in `repro_hcr_agent.c` and defined by nothing else:
##
##   REPRO_HCR_FALSIFY_BEFORE_RELOAD_AFTER_SWAP — fires before-reload AFTER
##     Phase G, i.e. the ordering IsoNim's design doc asked for and
##     `Patch-Loading-Lifecycle.md` §3.1 forbids.
##   REPRO_HCR_FALSIFY_SKIP_STEP38 — a Phase F failure does not reach the
##     after-reload callbacks.
##   REPRO_HCR_FALSIFY_LATCH_ON_REQUEST — the introspection window opens on the
##     REQUESTED patch rather than the accepted one.
##
## A gate that only ever builds the healthy agent cannot tell a passing
## assertion from a vacuous one; that is the specific lesson NH-M2 recorded,
## where four gates passed under BOTH the correct and the incorrect ordering.

import std/[json, os, osproc, streams, strtabs, strutils]

import repro_hcr_agent
import repro_project_dsl

import "../hcr-linux-direct/elf_rel_reader"

const
  TargetSymbol* = "hcr_lx_m8_victim"
  PatchSymbol* = "hcr_lx_m8_patch_body"
  OversizePatchSymbol* = "hcr_lx_m8_patch_oversize"
  OriginalValue* = 11
  PatchedValue* = 77
  ProbeChangedFile* = "hcr_lx_m8_views.nim"
  ProbeAbsentFile* = "hcr_lx_m8_never_in_any_patch.nim"
  ProbeManagedType* = "HcrM8State"
  SupportProfile* = HcrLinuxX86_64DirectSupportProfile
  Endbr64Hex* = "f30f1efa"

proc q(value: string): string = quoteShell(value)

proc shellCommand*(args: openArray[string]): string =
  for index, arg in args:
    if index > 0: result.add(" ")
    result.add(q(arg))

proc runOrFail*(command, cwd: string): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError,
      "command failed (exit " & $res.exitCode & "): " & command & "\n" &
      res.output)
  res.output

proc m8WorkDir*(repoRoot: string): string =
  result = repoRoot / "build" / "hcr-linux-m8"
  createDir(result)

proc m8CaseDir*(repoRoot: string): string =
  repoRoot / "tests" / "e2e" / "hcr-linux-rbhcr"

## Compile the patch object once and extract both bodies from their own
## sections. Real compiler output, no hand-assembled literals; the oversize
## body's size is MEASURED here rather than assumed, because the whole point of
## it is that it exceeds the provider's one-page ceiling.
proc buildPatchBodies*(repoRoot: string): tuple[normal, oversize: seq[byte]] =
  let caseDir = m8CaseDir(repoRoot)
  let workDir = m8WorkDir(repoRoot)
  let obj = workDir / "hcr_lx_m8_patch.o"
  discard runOrFail(shellCommand([
    "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
    caseDir / "hcr_lx_m8_patch.c", "-o", obj]), repoRoot)
  let parsed = parseElfRelObject(obj)
  for sym in [PatchSymbol, OversizePatchSymbol]:
    # A relocation would mean the bytes are not position-independent and
    # cannot be dropped into a provider-owned page as-is.
    doAssert parsed.relocationCount(".text." & sym) == 0,
      "patch body " & sym & " carries relocations"
  result.normal = parsed.functionBytes(PatchSymbol)
  result.oversize = parsed.functionBytes(OversizePatchSymbol)
  doAssert result.normal.len > 0
  doAssert result.oversize.len > 4096,
    "the oversize body must exceed one page for the Phase F refusal to be " &
    "real; measured " & $result.oversize.len & " bytes"

## Build one target with the real patchable build profile, optionally with
## falsifier defines. `outputName` must differ per define set or two builds
## overwrite each other and the gate measures the same binary twice.
proc buildTarget*(repoRoot, outputName: string;
                  defines: openArray[string] = []): string =
  let caseDir = m8CaseDir(repoRoot)
  let binDir = repoRoot / "build" / "test-bin"
  createDir(binDir)
  result = binDir / outputName
  let compileFlags = patchableCompileFlags(ReproHcr())
  let linkFlags = patchableLinkFlags(ReproHcr())
  # Assert the profile rather than trust it: a profile that emitted nothing
  # would compile a NON-patchable target that then refused `absent-sled`, and
  # the gate would be measuring the refusal path while believing it measured
  # the lifecycle.
  doAssert "-fpatchable-function-entry=16,0" in compileFlags
  doAssert "-falign-functions=16" in compileFlags
  # HLX-M8, design §9. The TLS model is part of the patchable profile now.
  doAssert "-ftls-model=global-dynamic" in compileFlags
  doAssert "-Wl,--build-id=sha1" in linkFlags
  var args = @["gcc", "-O2", "-g"] & @compileFlags &
    @["-fcf-protection=full",
      "-I", repoRoot / "libs" / "repro_hcr_agent" / "c"]
  for define in defines:
    args.add define
  args.add ["-o", result,
            caseDir / "hcr_lx_m8_target.c",
            repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"]
  args = args & @linkFlags & @["-lpthread"]
  discard runOrFail(shellCommand(args), repoRoot)
  doAssert fileExists(result)

type
  M8Run* = object
    ## One complete reload attempt against one target process.
    targetJson*: JsonNode
    targetOutput*: string
    exitCode*: int
    delivery*: HcrCoordinatorDelivery

## Start the target, hand it exactly one patch request over the real socket,
## and collect both halves of the evidence.
##
## A target that never parks a request exits 3 with a message on stderr rather
## than printing an empty result; a non-zero exit is surfaced here as a raised
## exception rather than as an empty `targetJson`, so no caller can mistake
## "the target refused to run" for "the target ran and observed nothing".
proc runReload*(repoRoot, targetBin, socketName: string;
                request: HcrPatchRequest;
                managedTypes: openArray[string] = [];
                schemaId = "reprobuild.hcr.hlx-m8.linux-rb-hcr-target-result.v1"):
                M8Run =
  let workDir = m8WorkDir(repoRoot)
  let socketPath = workDir / socketName
  removeFile(socketPath)
  var listener = listenHcrAgentUnixSocket(socketPath)
  defer: listener.close()

  var env = newStringTable()
  for key, value in envPairs():
    env[key] = value
  env[ReproHcrAgentSocketEnv] = socketPath

  var argv: seq[string] = @[]
  for managed in managedTypes:
    argv.add "--managed=" & managed

  let process = startProcess(targetBin, workingDir = repoRoot, args = argv,
    env = env, options = {poStdErrToStdOut})
  var connection = acceptHcrAgentConnection(listener)
  var client = initHcrCoordinatorClient(SupportProfile)
  result.delivery = client.deliverPatchRequest(connection, request)
  connection.close()

  result.targetOutput = process.outputStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()
  if result.exitCode != 0:
    raise newException(IOError,
      "target exited " & $result.exitCode & ":\n" & result.targetOutput)
  try:
    result.targetJson = parseJson(result.targetOutput.strip())
  except JsonParsingError as err:
    # Loud, with the bytes in hand. A harness that swallowed this would report
    # "the target observed nothing" for a target that observed plenty and
    # printed it badly.
    raise newException(IOError,
      "target printed unparsable JSON (" & err.msg & "):\n" &
      result.targetOutput)
  doAssert result.targetJson["schemaId"].getStr() == schemaId,
    "target printed schemaId " & result.targetJson["schemaId"].getStr() &
    ", expected " & schemaId

proc m8PatchRequest*(patchId: string; body: openArray[byte];
                     changedFiles: openArray[string] = [ProbeChangedFile];
                     changedTypes: openArray[HcrTypeLayoutChange] = []):
                     HcrPatchRequest =
  directPatchRequest(
    patchId = patchId,
    supportProfile = SupportProfile,
    changedFunctions = [TargetSymbol],
    targetSymbols = [TargetSymbol],
    directPatchBytes = body,
    debugObjectBytes = [],
    unwindMetadataBytes = [],
    sourceGenerationMap = [],
    changedFiles = changedFiles,
    changedTypes = changedTypes)

proc managedTypeChange*(): HcrTypeLayoutChange =
  HcrTypeLayoutChange(typeName: ProbeManagedType, oldSize: 24, newSize: 40)

proc observation*(run: M8Run; which: string): JsonNode =
  run.targetJson[which]

proc writeInspection*(repoRoot, name: string; node: JsonNode) =
  let logDir = repoRoot / "test-logs"
  createDir(logDir)
  writeFile(logDir / (name & ".json"), pretty(node))

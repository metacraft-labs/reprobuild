## Shared build/run helpers for the HLX-M3 gates.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.5, §11.2, §11.3.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M3.
##
## All three gates need the same four things — three replacement bodies
## extracted from a REAL relocatable object, a victim translation unit compiled
## WITHOUT the patchable profile, one compiled with a DELIBERATELY SHORT sled,
## and a fixture binary linked against the PRODUCTION transaction through the
## no-mock probe shim and against the REAL cross-patcher claim map. Duplicating
## that across three files is how two gates end up compiling different things
## and only one of them exercising the code under test.
##
## Nothing here mocks anything. The probe shim re-exports the same `static`
## functions the live agent calls; it is not a reimplementation.
##
## FALSIFIER BUILDS ARE FIRST-CLASS HERE. `buildFixture` takes a list of
## `-D` defines so each gate can build the SAME fixture against a provider with
## exactly one property removed, run the same arm, and measure that it goes red.
## A gate that only ever builds the healthy provider cannot tell a passing
## assertion from a vacuous one.

import std/[json, os, osproc, streams, strutils]

# Nim parses `../hcr-linux-direct/x` as arithmetic, so the ELF reader HLX-M0
# already ships is imported by quoted path rather than copied. One reader, one
# behaviour.
import "../hcr-linux-direct/elf_rel_reader"

import repro_project_dsl

const
  PatchSymbolA* = "hcr_lx_m3_patch_body_a"
  PatchSymbolB* = "hcr_lx_m3_patch_body_b"
  PatchSymbolC* = "hcr_lx_m3_patch_body_c"
  ValueA* = 77
  ValueB* = 99
  ValueC* = 123
  ## The victims' unpatched return values, spelled here so every gate asserts
  ## the same numbers and a drift in the fixture shows up as a failure rather
  ## than as two gates disagreeing.
  OriginalA* = 11
  OriginalB* = 22
  OriginalC* = 33

  ## The cross-patcher claim map lives in the recorder's repo. A missing
  ## sibling is a LOUD failure, never a skip: "no claim is leaked" is one of
  ## the three things the commit-failure gate asserts, and there is no version
  ## of that assertion which does not need the real map.
  RecorderClaimMap* = "codetracer-native-recorder/ct_inline_hook/claimed_guest_text.c"

  ## …and the translation unit the claim map calls into. `claimed_guest_text.c`
  ## does not use libc: every syscall it issues goes through
  ## `ct_recorder_gated_syscall`, the recorder's single identifiable doorway to
  ## the kernel, which lives in a DIFFERENT file. Linking the map without the
  ## doorway fails at LINK with `undefined reference to
  ## ct_recorder_gated_syscall` — which is how these three gates were found red
  ## on committed `dev` on 2026-09-19.
  ##
  ## The REAL doorway, not a stub. A stub would be a second definition of a
  ## symbol whose whole purpose is that there is exactly one of it, in one
  ## place, at one address (Verification-Harness-Traps §30a: a re-derived copy
  ## agrees with itself while the original is wrong). It is self-contained —
  ## `nm -u` on it reports only `_GLOBAL_OFFSET_TABLE_` — so linking it costs
  ## these fixtures nothing else.
  RecorderSyscallGate* =
    "codetracer-native-recorder/ct_interpose/src/ct_interpose/recorder_syscall_gate.c"

proc q(value: string): string = quoteShell(value)

proc shellCommand*(args: openArray[string]): string =
  for index, arg in args:
    if index > 0: result.add(" ")
    result.add(q(arg))

proc runOrFail*(command, cwd: string): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError,
      "command failed (exit " & $res.exitCode & "): " & command & "\n" & res.output)
  res.output

proc m3WorkDir*(repoRoot: string): string =
  result = repoRoot / "build" / "hcr-linux-m3"
  createDir(result)

proc m3CaseDir*(repoRoot: string): string =
  repoRoot / "tests" / "e2e" / "hcr-linux-txn"

proc claimMapPath*(repoRoot: string): string =
  repoRoot.parentDir / RecorderClaimMap

proc recorderSyscallGatePath*(repoRoot: string): string =
  repoRoot.parentDir / RecorderSyscallGate

## Compile the patch object and extract all three bodies.
proc buildPatchBodies*(repoRoot: string): tuple[a, b, c: seq[byte]] =
  let caseDir = m3CaseDir(repoRoot)
  let workDir = m3WorkDir(repoRoot)
  let obj = workDir / "hcr_lx_m3_patch.o"
  discard runOrFail(shellCommand([
    "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
    caseDir / "hcr_lx_m3_patch.c", "-o", obj]), repoRoot)
  let parsed = parseElfRelObject(obj)
  # Self-contained bodies only: a relocation would mean the bytes are not
  # position-independent and cannot be dropped into a provider-owned page.
  for sym in [PatchSymbolA, PatchSymbolB, PatchSymbolC]:
    doAssert parsed.relocationCount(".text." & sym) == 0
  result.a = parsed.functionBytes(PatchSymbolA)
  result.b = parsed.functionBytes(PatchSymbolB)
  result.c = parsed.functionBytes(PatchSymbolC)

## The two auxiliary victim objects, each compiled with ITS OWN flags. This is
## what makes `absent-sled` and `short-sled` real compiler outcomes rather than
## levers: one translation unit has no `-fpatchable-function-entry` at all, the
## other has one too small to hold an eight-byte aligned window.
proc buildVictimObjects*(repoRoot: string): tuple[plain, short: string] =
  let caseDir = m3CaseDir(repoRoot)
  let workDir = m3WorkDir(repoRoot)
  result.plain = workDir / "hcr_lx_m3_plain.o"
  result.short = workDir / "hcr_lx_m3_short.o"
  discard runOrFail(shellCommand([
    "gcc", "-c", "-O2", "-g", "-fcf-protection=full",
    caseDir / "hcr_lx_m3_plain.c", "-o", result.plain]), repoRoot)
  discard runOrFail(shellCommand([
    "gcc", "-c", "-O2", "-g", "-fcf-protection=full", "-falign-functions=16",
    "-fpatchable-function-entry=4,0",
    caseDir / "hcr_lx_m3_short.c", "-o", result.short]), repoRoot)

## Compile one fixture with the real patchable build profile, optionally with
## falsifier defines. `outputName` must differ per define set or two builds
## overwrite each other and the gate measures the same binary twice.
proc buildFixture*(repoRoot, outputName: string;
                   defines: openArray[string] = []): string =
  let caseDir = m3CaseDir(repoRoot)
  let workDir = m3WorkDir(repoRoot)
  let objs = buildVictimObjects(repoRoot)
  result = workDir / outputName
  let compileFlags = patchableCompileFlags(ReproHcr())
  let linkFlags = patchableLinkFlags(ReproHcr())
  # A profile that emitted nothing would build a NON-patchable fixture whose
  # every arm refused `absent-sled`, and the gate would report states it never
  # reached. Assert the flags rather than trust them.
  doAssert compileFlags.contains("-fpatchable-function-entry=16,0")
  doAssert compileFlags.contains("-falign-functions=16")
  doAssert linkFlags.contains("-Wl,--build-id=sha1")
  var args = @["gcc", "-O2", "-g"] & compileFlags & @["-fcf-protection=full"]
  for d in defines:
    args.add("-D" & d)
  args = args & @[
    "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
    "-o", result,
    caseDir / "hcr_lx_m3_txn.c", objs.plain, objs.short,
    repoRoot / "libs" / "repro_hcr_agent" / "c" /
      "repro_hcr_linux_x86_64_probe.c",
    claimMapPath(repoRoot),
    recorderSyscallGatePath(repoRoot)] & linkFlags & @["-lpthread"]
  discard runOrFail(shellCommand(args), repoRoot)

proc hex*(bytes: seq[byte]): string =
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

type
  FixtureRun* = object
    exitCode*: int
    output*: string
    stderrText*: string
    payload*: JsonNode   ## nil when the process died before printing

proc runFixture*(binary: string; args: openArray[string]): FixtureRun =
  let process = startProcess(binary, args = @args, options = {})
  result.output = process.outputStream.readAll()
  result.stderrText = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()
  let trimmed = result.output.strip()
  if trimmed.len > 0 and trimmed[0] == '{':
    try:
      result.payload = parseJson(trimmed)
    except CatchableError:
      result.payload = nil

## Run one arm and insist the fixture actually produced a result. A mode that
## dies before printing must fail the gate, not be read as "nothing changed".
proc runArm*(binary, mode: string; bodies: tuple[a, b, c: seq[byte]];
             extra: openArray[string] = []): JsonNode =
  let run = runFixture(binary,
    @[mode, hex(bodies.a), hex(bodies.b), hex(bodies.c)] & @extra)
  if run.payload == nil:
    raise newException(IOError,
      "fixture arm '" & mode & "' produced no JSON (exit " & $run.exitCode &
      ")\nstdout: " & run.output & "\nstderr: " & run.stderrText)
  if run.exitCode != 0:
    raise newException(IOError,
      "fixture arm '" & mode & "' exited " & $run.exitCode & ": " & run.output)
  run.payload

## The byte-identity predicate the gates are built on, kept in one place so all
## three ask the same question of the same field names.
proc textIdentical*(victim: JsonNode): bool =
  victim["before"].getStr() == victim["after"].getStr()

proc victimNamed*(payload: JsonNode; name: string): JsonNode =
  for v in payload["victims"]:
    if v["name"].getStr() == name:
      return v
  raise newException(KeyError, "no victim named " & name)

## How many BYTE POSITIONS differ between the two snapshots. "The text changed"
## is not a strong enough observation on its own — see `changedOneAlignedWord`.
proc differingBytes*(victim: JsonNode): int =
  let before = victim["before"].getStr()
  let after = victim["after"].getStr()
  doAssert before.len == after.len
  var i = 0
  while i < before.len:
    if before[i ..< i + 2] != after[i ..< i + 2]:
      result += 1
    i += 2

## The addresses at which the two snapshots differ, derived from the victim's
## reported entry and the fixture's fixed 16-byte pre-entry margin.
proc differingAddresses*(victim: JsonNode): seq[uint64] =
  const SnapBefore = 16
  let before = victim["before"].getStr()
  let after = victim["after"].getStr()
  doAssert before.len == after.len
  let entry = parseHexInt(victim["entry"].getStr()[2 .. ^1]).uint64
  var i = 0
  while i < before.len:
    if before[i ..< i + 2] != after[i ..< i + 2]:
      result.add(entry - SnapBefore.uint64 + uint64(i div 2))
    i += 2

## THE PUBLICATION RULE, as an observation.
##
## Design §4.2: the only write into live text is ONE naturally aligned 8-byte
## store. Counting differing bytes cannot express that — a `90 90 90` tail that
## the `E9 rel32` overwrites with the identical bytes differs in FIVE
## positions, not eight — so the property asserted is the one the rule actually
## states: every byte that changed lies inside a SINGLE 8-byte naturally
## aligned block. A 13- or 14-byte in-text trampoline, or two stores, or a
## `memcpy` over the sled, all fail this and none of them fail a byte count.
proc changedOneAlignedWord*(victim: JsonNode): bool =
  let addresses = differingAddresses(victim)
  if addresses.len == 0 or addresses.len > 8:
    return false
  let blockBase = addresses[0] and not 7'u64
  for a in addresses:
    if (a and not 7'u64) != blockBase:
      return false
  true

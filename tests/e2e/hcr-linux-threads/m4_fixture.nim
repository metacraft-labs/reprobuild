## Shared build/run helpers for the HLX-M4 gates.
##
## Every gate in this milestone needs the same two things: the two replacement
## bodies extracted from a REAL relocatable object (never hand-assembled), and a
## fixture binary compiled with the real patchable build profile and linked
## against the PRODUCTION provider through `repro_hcr_linux_x86_64_probe.c`.
## Duplicating that across four files is how two gates end up compiling
## different things and only one of them exercising the code under test.
##
## Nothing here mocks anything. The probe shim re-exports the same `static`
## functions the live agent calls; it is not a reimplementation.

import std/[json, os, osproc, streams, strutils]

# Nim parses `../hcr-linux-direct/x` as arithmetic, so the ELF reader HLX-M0
# already ships is imported by quoted path rather than copied. One reader, one
# behaviour: a second copy is how two gates end up disagreeing about what a
# relocatable object contains.
import "../hcr-linux-direct/elf_rel_reader"

const
  PatchSymbolA* = "hcr_lx_m4_patch_body_a"
  PatchSymbolB* = "hcr_lx_m4_patch_body_b"
  ValueA* = 77
  ValueB* = 99
  ## The exit code the fixtures use for "a thread faulted". It is a specific
  ## number, not "non-zero", because trap 1 of
  ## `codetracer-specs/Testing/Verification-Harness-Traps.md` applies verbatim:
  ## a die-before-output wearing a crash's label is indistinguishable from a
  ## crash unless the code is asserted.
  CrashExitCode* = 70

type
  FixtureRun* = object
    exitCode*: int
    output*: string
    stderrText*: string
    payload*: JsonNode      ## nil when the process died before printing
    crashed*: bool          ## exitCode == CrashExitCode and a CRASH line present
    ## The faulting signal and PC, parsed from the fixture's async-signal-safe
    ## `HCR-M4-CRASH` line, and the publication window it announced before the
    ## workers started. These exist so the arms that MUST crash can be asserted
    ## to crash for the RIGHT REASON — a PC inside the eight bytes the
    ## publication overwrites — rather than merely to exit non-zero. Without
    ## them "tier 1 crashed 19/24" is compatible with 19 unrelated bugs.
    faultSignal*: int       ## -1 when no crash record was produced
    faultPc*: uint64
    windowAddress*: uint64  ## 0 when the fixture died before announcing it

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

proc m4WorkDir*(repoRoot: string): string =
  result = repoRoot / "build" / "hcr-linux-m4"
  createDir(result)

proc m4CaseDir*(repoRoot: string): string =
  repoRoot / "tests" / "e2e" / "hcr-linux-threads"

## Compile the patch object and extract both bodies. Returns their bytes.
proc buildPatchBodies*(repoRoot: string): tuple[a, b: seq[byte]] =
  let caseDir = m4CaseDir(repoRoot)
  let workDir = m4WorkDir(repoRoot)
  let obj = workDir / "hcr_lx_m4_patch.o"
  discard runOrFail(shellCommand([
    "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
    caseDir / "hcr_lx_m4_patch.c", "-o", obj]), repoRoot)
  let parsed = parseElfRelObject(obj)
  # Both bodies must be self-contained: a relocation would mean the bytes are
  # not position-independent and cannot be dropped into a provider-owned page.
  doAssert parsed.relocationCount(".text." & PatchSymbolA) == 0
  doAssert parsed.relocationCount(".text." & PatchSymbolB) == 0
  result.a = parsed.functionBytes(PatchSymbolA)
  result.b = parsed.functionBytes(PatchSymbolB)

## Compile one fixture with the real patchable build profile.
proc buildFixture*(repoRoot, source, outputName: string): string =
  let caseDir = m4CaseDir(repoRoot)
  let workDir = m4WorkDir(repoRoot)
  result = workDir / outputName
  discard runOrFail(shellCommand([
    "gcc", "-O2", "-g",
    "-falign-functions=16",
    "-fpatchable-function-entry=16,0",
    "-fcf-protection=full",
    "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
    "-o", result,
    caseDir / source,
    repoRoot / "libs" / "repro_hcr_agent" / "c" /
      "repro_hcr_linux_x86_64_probe.c",
    "-lpthread"]), repoRoot)

proc runFixture*(binary: string; args: openArray[string]): FixtureRun =
  let process = startProcess(binary, args = @args, options = {})
  let outStream = process.outputStream
  let errStream = process.errorStream
  result.output = outStream.readAll()
  result.stderrText = errStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()
  result.crashed = result.exitCode == CrashExitCode and
    result.stderrText.contains("HCR-M4-CRASH")

  # Parse the two async-signal-safe stderr records. Both are fixed-shape, so a
  # miss means the fixture did not get far enough to emit them — which is
  # itself information the caller must be able to see, hence the -1/0 sentinels
  # rather than a silent zero.
  result.faultSignal = -1
  for line in result.stderrText.splitLines():
    if line.startsWith("HCR-M4-CRASH "):
      for field in line.split(' '):
        if field.startsWith("signal="):
          try: result.faultSignal = parseInt(field["signal=".len .. ^1])
          except ValueError: discard
        elif field.startsWith("pc=0x"):
          try: result.faultPc = fromHex[uint64](field["pc=".len .. ^1])
          except ValueError: discard
    elif line.startsWith("HCR-M4-WINDOW 0x"):
      try: result.windowAddress = fromHex[uint64](line["HCR-M4-WINDOW ".len .. ^1])
      except ValueError: discard
  let trimmed = result.output.strip()
  if trimmed.len > 0 and trimmed[0] == '{':
    try:
      result.payload = parseJson(trimmed)
    except CatchableError:
      result.payload = nil

proc hex*(bytes: seq[byte]): string =
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

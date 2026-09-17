## Shared build/run helpers for the HLX-M5 gates.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8,
## `HCR/Debugger-Integration.md` §1, §2, §5, §8.3.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M5.
##
## All three gates need the same four things — one patch object built by a real
## compiler with `-g`, the three payloads extracted from it (body bytes,
## `.eh_frame`, the whole `ET_REL`), a fixture binary linked against a CHOSEN
## unwinder, and a way to drive a REAL debugger at it. Duplicating that across
## three files is how two gates end up compiling different things and only one
## of them exercising the code under test.
##
## Nothing here mocks anything, and in particular nothing here stands in for a
## debugger. `requireDebugger` FAILS when `gdb` or `lldb` is missing; it does
## not skip, and it does not synthesise a backtrace. A gate that greps a
## fabricated backtrace proves nothing, and a gate that exits 0 because a
## prerequisite was absent is the silent self-pass
## `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md` exists to
## stop.
##
## FALSIFIER BUILDS ARE FIRST-CLASS HERE. `buildFixture` takes a list of `-D`
## defines and an unwinder choice, so a gate can build the SAME fixture against
## a provider with exactly one property removed, link it against either
## unwinder, run the same arm, and measure that it goes red. A gate that only
## ever builds the healthy provider against one unwinder cannot tell a passing
## assertion from a vacuous one — and HLX-OQ-4's whole point is that the libgcc
## arm stays green no matter what you guess.

import std/[json, os, osproc, streams, strtabs, strutils]

# Nim parses `../hcr-linux-direct/x` as arithmetic, so the ELF reader HLX-M0
# already ships is imported by quoted path rather than copied. One reader, one
# behaviour.
import "../hcr-linux-direct/elf_rel_reader"

import repro_project_dsl

const
  PatchSymbol* = "hcr_lx_m5_patch_body"
  VictimSymbol* = "hcr_lx_m5_victim"

  ## The fixture's call chain is `main -> level3 -> level2 -> level1 ->
  ## victim -> reached`, and each level adds a different constant so that the
  ## single returned integer distinguishes "patched" from "unpatched" without
  ## any second channel:
  ##   unpatched: ((11 * 2 + 1) + 3) + 5 == 31
  ##   patched:   ((77 * 2 + 1) + 3) + 5 == 163
  UnpatchedResult* = 31
  PatchedResult* = 163

  ## The names the backtrace must contain, in the order the stack has them.
  ## Spelled once so three gates assert the same chain and a drift in the
  ## fixture shows up as a failure rather than as two gates disagreeing.
  CallerChain* = ["hcr_lx_m5_level1", "hcr_lx_m5_level2", "hcr_lx_m5_level3",
                  "main"]

type
  Unwinder* = enum
    ## Which unwinder the fixture binary is linked against. This is the
    ## HLX-OQ-4 axis: `__register_frame` exists in both and they disagree about
    ## its argument.
    uwLibgcc, uwLlvmLibunwind

  Payloads* = object
    objectPath*: string   ## the whole `ET_REL`, i.e. the JIT symfile input
    ehFramePath*: string  ## the compiler-generated `.eh_frame` section bytes
    bodyHex*: string      ## the patch body, hex
    bodyLen*: int

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

proc m5WorkDir*(repoRoot: string): string =
  result = repoRoot / "build" / "hcr-linux-m5"
  createDir(result)

proc m5CaseDir*(repoRoot: string): string =
  repoRoot / "tests" / "e2e" / "hcr-linux-unwind"

## Compile the patch object and extract all three payloads from it.
##
## `-gz=none` is load-bearing, not cosmetic. Several toolchains (and this
## flake's GCC by default) emit `SHF_COMPRESSED` `.debug_*`, and a relocation
## applied into a zlib stream corrupts it silently — which would surface as
## WRONG LINE NUMBERS rather than as an error. The provider refuses a
## compressed symfile by name (`debug-object-compressed-debug-section`); the
## build profile is what avoids needing that refusal.
proc buildPayloads*(repoRoot: string): Payloads =
  let caseDir = m5CaseDir(repoRoot)
  let workDir = m5WorkDir(repoRoot)
  let obj = workDir / "hcr_lx_m5_patch.o"
  discard runOrFail(shellCommand([
    "gcc", "-c", "-O2", "-g", "-gz=none", "-fno-stack-protector",
    "-ffunction-sections", "-fasynchronous-unwind-tables",
    caseDir / "hcr_lx_m5_patch.c", "-o", obj]), repoRoot)

  let parsed = parseElfRelObject(obj)
  # Self-contained body only: a relocation would mean the bytes are not
  # position-independent and cannot be dropped into a provider-owned page.
  # This is why the patch body takes its callee as a parameter.
  doAssert parsed.relocationCount(".text." & PatchSymbol) == 0,
    "the patch body carries relocations and cannot be injected"

  let body = parsed.functionBytes(PatchSymbol)
  let ehFrame = parsed.sectionBytes(".eh_frame")
  doAssert ehFrame.len > 0, "the patch object carries no .eh_frame"

  result.objectPath = obj
  result.ehFramePath = workDir / "hcr_lx_m5_eh_frame.bin"
  var raw = newString(ehFrame.len)
  for i, b in ehFrame:
    raw[i] = char(b)
  writeFile(result.ehFramePath, raw)
  result.bodyHex = hexBytes(body)
  result.bodyLen = body.len

## Compile one fixture binary.
##
## `unwinder` decides which `__register_frame` the process will bind to, and
## the two link lines are deliberately different shapes rather than a flag:
##
##   * `uwLibgcc` adds `-lgcc_s` with `--no-as-needed`, because a C program
##     with no exceptions would otherwise not pull it in at all and the weak
##     `__register_frame` would be NULL — which the provider correctly refuses
##     as `unwind-register-frame-unavailable`, and which would make the gate
##     measure the refusal instead of the ABI.
##   * `uwLlvmLibunwind` uses `-nodefaultlibs` so `libgcc_s` is NOT linked at
##     all, and supplies LLVM's `libunwind` plus `libc` and `libgcc.a`
##     explicitly. `libgcc.a` carries the compiler support routines and NOT the
##     unwinder (that is `libgcc_eh.a`), so the process has exactly one
##     unwinder and the gate can assert which one answered.
##
## Both arms are compiled by GCC. Only the LINK differs, and that is on
## purpose: Clang under `-fcf-protection` emits maximal-length NOPs for the
## patchable sled, so a Clang-compiled fixture is refused
## `sled-window-not-instruction-boundary` before it ever reaches a
## registration — measured, and it is HLX-OQ-6's standing capability limitation,
## not a fact about unwinders.
##
## `outputName` must differ per (unwinder, define set) or two builds overwrite
## each other and the gate measures the same binary twice.
proc buildFixture*(repoRoot, outputName: string; unwinder = uwLibgcc;
                   defines: openArray[string] = []): string =
  let caseDir = m5CaseDir(repoRoot)
  let workDir = m5WorkDir(repoRoot)
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
    caseDir / "hcr_lx_m5_target.c"] & linkFlags
  # `-rdynamic` puts the fixture's own functions in `.dynsym`, which is what
  # lets the fixture symbolise its own `_Unwind_Backtrace` PCs through
  # `dladdr`. Without it every frame would come back nameless and the chain
  # assertion would have nothing to assert.
  args.add("-rdynamic")
  case unwinder
  of uwLibgcc:
    args = args & @["-Wl,--no-as-needed", "-lgcc_s", "-Wl,--as-needed"]
  of uwLlvmLibunwind:
    let prefix = getEnv("REPRO_HCR_LLVM_LIBUNWIND")
    doAssert prefix.len > 0,
      "REPRO_HCR_LLVM_LIBUNWIND is not set. This gate needs LLVM's libunwind " &
      "to build the second HLX-OQ-4 arm; reprobuild's dev shell exports it " &
      "(flake.nix). Run the gate from `direnv exec . ...` inside reprobuild/."
    doAssert fileExists(prefix / "lib" / "libunwind.so"),
      "REPRO_HCR_LLVM_LIBUNWIND=" & prefix & " has no lib/libunwind.so"
    args = args & @[
      "-nodefaultlibs", "-L" & prefix / "lib",
      "-Wl,-rpath," & prefix / "lib", "-lunwind", "-lc", "-lgcc"]
  discard runOrFail(shellCommand(args), repoRoot)

## Which unwinder the built binary actually bound to, read out of the LINKED
## IMAGE rather than out of the link line we just wrote. A link flag is an
## intention; `ldd` is the measurement, and the two have been known to differ.
proc linkedUnwinderSonames*(repoRoot, binary: string): seq[string] =
  let output = runOrFail(shellCommand(["ldd", binary]), repoRoot)
  for line in output.splitLines():
    if line.contains("libgcc_s.so"):
      result.add("libgcc_s")
    elif line.contains("libunwind.so"):
      result.add("libunwind")

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
  for line in result.output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0 and trimmed[0] == '{':
      try:
        result.payload = parseJson(trimmed)
      except CatchableError:
        result.payload = nil

## Run one arm and insist the fixture actually produced a result. A mode that
## dies before printing must fail the gate, not be read as "nothing happened".
proc runArm*(binary, mode: string; payloads: Payloads): JsonNode =
  let run = runFixture(binary,
    [mode, payloads.bodyHex, payloads.ehFramePath, payloads.objectPath,
     PatchSymbol])
  if run.payload == nil:
    raise newException(IOError,
      "fixture arm '" & mode & "' produced no JSON (exit " & $run.exitCode &
      ")\nstdout: " & run.output & "\nstderr: " & run.stderrText)
  if run.exitCode != 0:
    raise newException(IOError,
      "fixture arm '" & mode & "' exited " & $run.exitCode & ": " & run.output)
  run.payload

# ---------------------------------------------------------------------------
# Real debuggers.
#
# There is no fallback here on purpose. `Verification-Harness-Traps.md` §26
# ("an assertion whose negative arm is `discard` is documentation with a call
# site") and the silent-self-pass audit's ladder both land in the same place:
# a missing prerequisite must be LOUD. So this raises, with the remedy in the
# message, and the gate that calls it fails.
# ---------------------------------------------------------------------------

proc requireDebugger*(exeName, gate: string): string =
  let envName = "REPRO_HCR_" & exeName.toUpperAscii() & "_PATH"
  let fromEnv = getEnv(envName)
  if fromEnv.len > 0:
    if not fileExists(fromEnv):
      raise newException(IOError,
        gate & " blocker: " & envName & "=" & fromEnv & " does not exist.")
    return fromEnv
  let found = findExe(exeName)
  if found.len == 0:
    raise newException(IOError,
      gate & " blocker: no `" & exeName & "` on PATH, and this gate's " &
      "`allowed_mocks` is none — a backtrace can only be read from a real " &
      "debugger. Remedy: run inside reprobuild's dev shell " &
      "(`direnv exec . <command>` from reprobuild/), which provisions " &
      "`gdb` and `lldb` through flake.nix. " & envName & " overrides the " &
      "lookup if you need a specific build.")
  found

proc debuggerVersion*(exePath: string): string =
  ## Recorded in every gate's evidence file. A measurement quoted without the
  ## build it was taken against is a claim about an unnamed configuration.
  let res = execCmdEx(shellCommand([exePath, "--version"]))
  for line in res.output.splitLines():
    if line.strip().len > 0:
      return line.strip()
  "unknown"

proc debuggerEnv(): StringTableRef =
  ## The child's environment, with the two things that would make a debugger
  ## reach the network or a user's config removed. Everything else is passed
  ## through deliberately: `Verification-Harness-Traps.md` §27 records a case
  ## where a blocklist also filtered the harness's OWN overrides and the
  ## budget under test never arrived.
  result = newStringTable()
  for k, v in envPairs():
    result[k] = v
  result["DEBUGINFOD_URLS"] = ""
  result["TERM"] = "dumb"

proc runDebuggerTranscript(exePath: string; args: openArray[string];
                           cwd: string): tuple[output: string; code: int] =
  let process = startProcess(exePath, workingDir = cwd, args = @args,
                             env = debuggerEnv(),
                             options = {poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  process.close()

## Break inside `hcr_lx_m5_reached`, run the fixture to that breakpoint, and
## take a backtrace. Returns GDB's whole transcript — both directions of the
## session, printed by the gate on failure rather than summarised away
## (`Verification-Harness-Traps.md` §3).
proc gdbSession*(gdbPath, binary, mode: string; payloads: Payloads;
                 commands: openArray[string]): string =
  let dir = binary.parentDir
  var args = @[
    "-batch", "-nx",
    "-ex", "set confirm off",
    "-ex", "set pagination off",
    "-ex", "break hcr_lx_m5_reached",
    "-ex", "run"]
  for command in commands:
    args.add("-ex")
    args.add(command)
  args = args & @[
    "--args", binary, mode, payloads.bodyHex, payloads.ehFramePath,
    payloads.objectPath, PatchSymbol]
  let run = runDebuggerTranscript(gdbPath, args, dir)
  if run.output.len == 0:
    raise newException(IOError,
      "gdb produced no transcript for mode '" & mode & "' (exit " &
      $run.code & ")")
  run.output

proc gdbBacktrace*(gdbPath, binary, mode: string; payloads: Payloads): string =
  gdbSession(gdbPath, binary, mode, payloads, ["bt"])

proc lldbBacktrace*(lldbPath, binary, mode: string; payloads: Payloads): string =
  let dir = binary.parentDir
  let args = @[
    "--batch", "--no-lldbinit",
    "-o", "breakpoint set --name hcr_lx_m5_reached",
    "-o", "run",
    "-o", "thread backtrace",
    "-o", "quit",
    "--", binary, mode, payloads.bodyHex, payloads.ehFramePath,
    payloads.objectPath, PatchSymbol]
  let run = runDebuggerTranscript(lldbPath, args, dir)
  if run.output.len == 0:
    raise newException(IOError,
      "lldb produced no transcript for mode '" & mode & "' (exit " &
      $run.code & ")")
  run.output

## The frame lines of a backtrace, and nothing else. A debugger transcript also
## carries the program's own stdout (the fixture prints its evidence JSON), and
## a substring search over the whole transcript would happily find
## `hcr_lx_m5_patch_body` in the fixture's argv echo rather than in a frame.
proc gdbFrames*(transcript: string): seq[string] =
  for line in transcript.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("#") and trimmed.len > 1 and trimmed[1] in {'0'..'9'}:
      result.add(trimmed)

proc lldbFrames*(transcript: string): seq[string] =
  for line in transcript.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("frame #"):
      result.add(trimmed)
    elif trimmed.startsWith("* frame #"):
      result.add(trimmed[2 .. ^1])

proc frameNaming*(frames: openArray[string]; needle: string): int =
  ## Index of the first frame line mentioning `needle`, or -1. Callers must
  ## gate on presence before comparing indices — see
  ## `Verification-Harness-Traps.md` §5a on sentinels that collide with
  ## legitimate values.
  result = -1
  for i, f in frames:
    if f.contains(needle):
      return i

proc chainInOrder*(frames: openArray[string]; names: openArray[string]): bool =
  ## Every name present, each strictly below the previous one. "Present" alone
  ## would pass on a backtrace that listed the callers in the wrong order, and
  ## a wrong order is exactly what a bad CFI produces.
  var previous = -1
  for name in names:
    let index = frameNaming(frames, name)
    if index < 0 or index <= previous:
      return false
    previous = index
  true

# ---------------------------------------------------------------------------
# The duplicate-`__jit_debug_descriptor` measurement (design §8.3).
#
# `jit_owner_probe.nim` links `repro_hcr_agent.c` AND imports
# `repro_hcr_agent/debug_unwind`. Whether that LINKS is the observation: with
# two owners of `__jit_debug_descriptor` it does not.
# ---------------------------------------------------------------------------

type JitOwnerBuild* = object
  ok*: bool
  output*: string
  binary*: string

proc buildJitOwnerProbe*(repoRoot, suffix: string;
                         defines: openArray[string] = []): JitOwnerBuild =
  let workDir = m5WorkDir(repoRoot)
  result.binary = workDir / ("jit_owner_probe_" & suffix)
  var args = @["nim", "c", "--threads:on",
               "--nimcache:" & repoRoot / "build" / "nimcache" /
                 ("m5_jit_owner_" & suffix),
               "--out:" & result.binary]
  for d in defines:
    args.add("-d:" & d)
  args.add(m5CaseDir(repoRoot) / "jit_owner_probe.nim")
  let res = execCmdEx(shellCommand(args), workingDir = repoRoot)
  result.ok = res.exitCode == 0
  result.output = res.output

proc definedSymbolCount*(repoRoot, binary, symbol: string): int =
  ## How many DEFINED symbols of that name the linked image carries. A count
  ## rather than a presence check: the debugger looks the name up and one name
  ## must have exactly one answer. Reading it out of the image rather than out
  ## of the sources is `Verification-Harness-Traps.md` §18 — "if a class is
  ## defined by what the program does, the population lives in the binary".
  let output = runOrFail(
    shellCommand(["nm", "--defined-only", binary]), repoRoot)
  for line in output.splitLines():
    let fields = line.splitWhitespace()
    if fields.len >= 3 and fields[^1] == symbol:
      inc result

proc writeEvidence*(repoRoot, gate: string; node: JsonNode) =
  ## Evidence, written unconditionally: `checkpoint` output is only flushed on
  ## failure, so a green run would otherwise leave no numbers behind.
  let logDir = repoRoot / "test-logs"
  createDir(logDir)
  writeFile(logDir / (gate & ".json"), pretty(node))

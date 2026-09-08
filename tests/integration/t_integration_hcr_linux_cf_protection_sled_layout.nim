## HLX-M0 verification gate `integration_hcr_linux_cf_protection_sled_layout`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §4.3.
## Open question: `HLX-OQ-6` (the Clang arm, unmeasurable on the design-review
## host — closed here).
##
## `allowed_mocks: none`. Real GCC and real Clang invocations, real object
## disassembly through `objdump`, real LINKED binaries executed so the
## `__patchable_function_entries` entries are read after the dynamic loader has
## relocated them, and the real production window planner
## (`repro_hcr_linux_x86_64.h`, via the test probe shim) consuming the observed
## bytes.
##
## What it fixes in place so a toolchain bump cannot silently invalidate it:
##
##   * GCC arm (re-asserts the design-review measurement): `endbr64` sits at the
##     entry label, the `__patchable_function_entries` entry points at the first
##     NOP four bytes later, the sled is 16 single-byte `0x90`s, and the
##     computed publication window is 8-byte aligned at entry+8 and wholly
##     inside the sled.
##
##   * Clang arm (`HLX-OQ-6`): MEASURED RESULT IS A REFUSAL, and it is recorded
##     as such rather than papered over. Clang emits the whole 16-byte sled as
##     one 15-byte multi-byte NOP plus one `0x90`. Under `-fcf-protection` the
##     sled therefore starts at entry+4 and its only interior instruction
##     boundary is entry+19; neither is 8-byte aligned with room for the window,
##     so the provider correctly refuses with
##     `sled-window-not-instruction-boundary` rather than splicing a jump into
##     the middle of a live instruction. Without `-fcf-protection` the sled
##     starts at the 16-aligned entry itself and Clang IS usable. Both cells are
##     asserted.
##
## No silent skips: a missing compiler fails the gate loudly.

import std/[json, os, osproc, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_project_dsl

  {.compile: "../../libs/repro_hcr_agent/c/repro_hcr_linux_x86_64_probe.c".}

  proc probePlanSled(bytes: ptr uint8; capacity: csize_t; sledAddress: uint64;
                     sledEnd: ptr uint64; sledLength: ptr uint32;
                     windowAddress: ptr uint64;
                     windowOffset: ptr uint32): cint {.importc:
    "repro_hcr_lx_probe_plan_sled", cdecl.}
  proc probeRefusalName(code: cint): cstring {.importc:
    "repro_hcr_lx_probe_refusal_name", cdecl.}

  const
    Endbr64Hex = "f30f1efa"

  # The flags come from the reprobuild patchable build profile itself, so the
  # gate and the profile cannot drift apart (HLX-M0 deliverable: add
  # -falign-functions=16 and -fpatchable-function-entry=16,0 to the Linux
  # patchable build profile in repro_project_dsl).
  let PatchableFlags = patchableCompileFlags(ReproHcr())

  type Measurement = object
    compiler: string
    cfProtection: string
    entryAddress: uint64
    sledAddress: uint64
    sledOffset: int
    entryBytesHex: string
    patchableEntryCount: int
    disassembly: string
    planRefusal: cint
    planRefusalName: string
    sledLength: uint32
    sledEnd: uint64
    windowAddress: uint64
    windowOffset: uint32

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

  proc requireTool(name: string) =
    let found = findExe(name)
    if found.len == 0:
      checkpoint("required tool not on PATH: " & name)
    require found.len > 0

  proc bytesFromHex(hex: string): seq[byte] =
    result = newSeq[byte](hex.len div 2)
    for i in 0 ..< result.len:
      result[i] = byte(parseHexInt(hex[i * 2 ..< i * 2 + 2]))

  proc measure(repoRoot, workDir, compiler, cfProtection: string): Measurement =
    let fixture = repoRoot / "tests" / "fixtures" / "hcr" /
      "linux-cf-protection" / "hcr_lx_cf_probe.c"
    let tag = compiler & "-" & cfProtection.replace("=", "-")
    let objPath = workDir / ("probe-" & tag & ".o")
    let binPath = workDir / ("probe-" & tag)
    var compileArgs = @[compiler, "-O2", "-g"]
    compileArgs.add PatchableFlags
    compileArgs.add "-fcf-protection=" & cfProtection

    discard runSuccess(shellCommand(
      compileArgs & @["-c", fixture, "-o", objPath]), repoRoot)
    discard runSuccess(shellCommand(
      compileArgs & @[fixture, "-o", binPath]), repoRoot)

    result.compiler = compiler
    result.cfProtection = cfProtection
    # Plain `-d` rather than `--disassemble=SYMBOL`: GNU objdump and
    # llvm-objdump spell the symbol filter differently and the gate must not
    # depend on which one the shell provides.
    result.disassembly = runSuccess(
      shellCommand(["objdump", "-d", objPath]), repoRoot)

    let output = runSuccess(q(binPath), repoRoot).strip()
    let parsed = parseJson(output)
    check parsed["schemaId"].getStr() ==
      "reprobuild.hcr.hlx-m0.cf-protection-probe.v1"
    check parsed["victimResult"].getInt() == 12
    result.entryAddress =
      uint64(parseHexInt(parsed["entryAddress"].getStr().replace("0x", "")))
    result.sledAddress =
      uint64(parseHexInt(parsed["sledAddress"].getStr().replace("0x", "")))
    result.sledOffset = parsed["sledOffsetFromEntry"].getInt()
    result.entryBytesHex = parsed["entryBytesHex"].getStr()
    result.patchableEntryCount = parsed["patchableEntryCount"].getInt()

    # Feed the OBSERVED bytes to the production planner at the OBSERVED sled
    # address, so the window is computed exactly as the live agent computes it.
    var sledBytes = bytesFromHex(
      result.entryBytesHex)[result.sledOffset ..< result.entryBytesHex.len div 2]
    result.planRefusal = probePlanSled(addr sledBytes[0],
      csize_t(sledBytes.len), result.sledAddress, addr result.sledEnd,
      addr result.sledLength, addr result.windowAddress,
      addr result.windowOffset)
    result.planRefusalName = $probeRefusalName(result.planRefusal)

  proc measurementJson(m: Measurement): JsonNode =
    %*{
      "compiler": m.compiler,
      "cfProtection": m.cfProtection,
      "entryAddress": "0x" & toHex(m.entryAddress, 16),
      "sledAddress": "0x" & toHex(m.sledAddress, 16),
      "sledOffsetFromEntry": m.sledOffset,
      "patchableEntryCount": m.patchableEntryCount,
      "entryBytesHex": m.entryBytesHex,
      "sledLength": int(m.sledLength),
      "planRefusal": int(m.planRefusal),
      "planRefusalName": m.planRefusalName,
      "windowAddress": "0x" & toHex(m.windowAddress, 16),
      "windowOffsetFromSled": int(m.windowOffset),
      "windowOffsetFromEntry":
        (if m.planRefusal == 0:
           int(m.windowAddress - m.entryAddress)
         else: -1),
      "disassembly": m.disassembly
    }

  suite "integration_hcr_linux_cf_protection_sled_layout":
    test "GCC and Clang patchable-entry layouts under -fcf-protection":
      requireTool("gcc")
      # Clang IS available in the reprobuild dev shell, so the Clang arm of
      # HLX-OQ-6 is closed here rather than left open for lack of a compiler.
      requireTool("clang")
      requireTool("objdump")

      check PatchableFlags == @["-fpatchable-function-entry=16,0",
                                "-falign-functions=16"]

      let repoRoot = getCurrentDir()
      let workDir = repoRoot / "build" / "hcr-linux-cf-protection"
      createDir(workDir)

      let gccCet = measure(repoRoot, workDir, "gcc", "full")
      let gccNoCet = measure(repoRoot, workDir, "gcc", "none")
      let clangCet = measure(repoRoot, workDir, "clang", "full")
      let clangNoCet = measure(repoRoot, workDir, "clang", "none")

      # Common to all four cells: the section is emitted, mapped and relocated,
      # so the sled address is read from it and never derived from the symbol.
      for m in [gccCet, gccNoCet, clangCet, clangNoCet]:
        checkpoint(m.compiler & " -fcf-protection=" & m.cfProtection)
        check m.patchableEntryCount > 0
        check m.sledAddress != 0'u64
        check (m.entryAddress and 15'u64) == 0'u64 # -falign-functions=16
        check m.sledLength == 16'u32               # =16,0 means 16 NOP bytes
        check m.sledAddress == m.entryAddress + uint64(m.sledOffset)

      # --- GCC, -fcf-protection=full -------------------------------------
      # The design-review measurement, re-asserted: `endbr64` at the entry
      # label, the section entry already past it, 16 single-byte NOPs.
      checkpoint("gcc -fcf-protection=full")
      check gccCet.entryBytesHex.startsWith(Endbr64Hex)
      check gccCet.sledOffset == 4
      check gccCet.entryBytesHex[8 ..< 8 + 32] == repeat("90", 16)
      check gccCet.disassembly.contains("endbr64")
      # The computed window is 8-byte aligned and wholly inside the sled. Under
      # `-falign-functions=16` entry+4 is guaranteed misaligned, so the planner
      # must land on entry+8 — not on the sled start, and not on offset 0.
      check gccCet.planRefusal == 0
      check (gccCet.windowAddress and 7'u64) == 0'u64
      check gccCet.windowAddress == gccCet.entryAddress + 8'u64
      check gccCet.windowAddress >= gccCet.sledAddress
      check gccCet.windowAddress + 8'u64 <= gccCet.sledEnd
      check gccCet.windowOffset == 4'u32

      # --- GCC, -fcf-protection=none --------------------------------------
      checkpoint("gcc -fcf-protection=none")
      check not gccNoCet.entryBytesHex.startsWith(Endbr64Hex)
      check gccNoCet.sledOffset == 0
      check not gccNoCet.disassembly.contains("endbr64")
      check gccNoCet.planRefusal == 0
      check gccNoCet.windowAddress == gccNoCet.entryAddress
      check (gccNoCet.windowAddress and 7'u64) == 0'u64
      check gccNoCet.windowAddress + 8'u64 <= gccNoCet.sledEnd

      # --- Clang, -fcf-protection=none ------------------------------------
      # Clang emits a MAXIMAL multi-byte NOP, not single-byte 0x90s. Without
      # CET that is still fine: the sled starts at the 16-aligned entry, which
      # is both aligned and an instruction boundary.
      checkpoint("clang -fcf-protection=none")
      check not clangNoCet.entryBytesHex.startsWith(Endbr64Hex)
      check clangNoCet.sledOffset == 0
      check not clangNoCet.disassembly.contains("endbr64")
      check not clangNoCet.entryBytesHex.startsWith(repeat("90", 8))
      check clangNoCet.planRefusal == 0
      check clangNoCet.windowAddress == clangNoCet.entryAddress
      check (clangNoCet.windowAddress and 7'u64) == 0'u64
      check clangNoCet.windowAddress + 8'u64 <= clangNoCet.sledEnd

      # --- Clang, -fcf-protection=full — HLX-OQ-6, measured ---------------
      # This is the cell the design review could not measure. The result is a
      # REFUSAL and the gate asserts it, because the alternative — publishing at
      # the only 8-byte-aligned address inside the sled — would splice the jump
      # into the middle of Clang's 15-byte NOP and corrupt the function.
      checkpoint("clang -fcf-protection=full (HLX-OQ-6)")
      check clangCet.entryBytesHex.startsWith(Endbr64Hex)
      check clangCet.sledOffset == 4
      # The sled is one 15-byte NOP followed by one 0x90, not sixteen 0x90s.
      check clangCet.entryBytesHex[8 ..< 8 + 30] ==
        "66666666662e660f1f840000020000"
      check clangCet.entryBytesHex[8 + 30 ..< 8 + 32] == "90"
      check clangCet.disassembly.contains("endbr64")
      check clangCet.planRefusal != 0
      check clangCet.planRefusalName == "sled-window-not-instruction-boundary"

      # The two compilers genuinely differ; if a toolchain bump makes Clang
      # emit single-byte NOPs this assertion fails and the refusal above must
      # be revisited.
      check gccCet.entryBytesHex != clangCet.entryBytesHex

      var evidence = newJObject()
      evidence["schemaId"] =
        newJString("reprobuild.hcr.hlx-m0.cf-protection-sled-layout.v1")
      evidence["gccVersion"] =
        newJString(runSuccess("gcc --version", repoRoot).splitLines()[0])
      evidence["clangVersion"] =
        newJString(runSuccess("clang --version", repoRoot).splitLines()[0])
      evidence["patchableFlags"] = %PatchableFlags
      var cells = newJArray()
      for m in [gccCet, gccNoCet, clangCet, clangNoCet]:
        cells.add measurementJson(m)
      evidence["cells"] = cells
      evidence["hlxOq6"] = %*{
        "question": "Clang's -fpatchable-function-entry sled layout under -fcf-protection",
        "resolution": "refused",
        "detail": "Clang emits the sled as one 15-byte multi-byte NOP plus one " &
          "0x90; with endbr64 at a 16-aligned entry the sled starts at entry+4 " &
          "and its only interior instruction boundary is entry+19, so no " &
          "8-byte-aligned publication window falls on an instruction boundary. " &
          "The provider refuses with sled-window-not-instruction-boundary. " &
          "Clang without -fcf-protection is usable (window at the entry itself)."
      }
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_cf_protection_sled_layout.json",
        pretty(evidence))

else:
  suite "integration_hcr_linux_cf_protection_sled_layout":
    test "HLX-M0 sled layout gate is linux-x86_64-only":
      skip()

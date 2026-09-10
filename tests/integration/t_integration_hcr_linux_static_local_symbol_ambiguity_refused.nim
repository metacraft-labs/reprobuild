## HLX-M1 verification gate
## `integration_hcr_linux_static_local_symbol_ambiguity_refused`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §7.4.
##
## `allowed_mocks: none`. A real binary linking two real translation units that
## each define a `static` function of the same name, a real `.symtab` with two
## `STB_LOCAL` entries under that name, and the production resolver compiled
## into the fixture.
##
## Asserts the two things design §7.4 asks for — a bare ambiguous name is
## refused with a diagnostic naming both candidates, and a qualified form
## resolves to the intended one — plus a third thing, which is a MEASURED
## CORRECTION to the design and the reason this gate is worth more than its
## description:
##
##   **§7.4's qualification key does not work.** The design identifies a patch
##   target by (object file identity, symbol name, `st_shndx`). In a LINKED
##   image that tuple does not disambiguate: the linker merges every input
##   `.text.<name>` into a single output `.text`, so both `static` definitions
##   share one `st_shndx` and the tuple still selects both. `st_shndx` is the
##   correct key inside an `ET_REL` object, which is evidently where the
##   design's reasoning came from — but the resolver reads `ET_EXEC`/`ET_DYN`.
##
##   The key that does work is the `STT_FILE` symbol, which the ELF spec places
##   immediately before the `STB_LOCAL` symbols of its translation unit. This
##   gate asserts both halves: the design's key is still ambiguous, and the
##   `STT_FILE` key resolves each definition to the address the process itself
##   reports for it.
##
## The gate cannot pass by accident. If the resolver started guessing, the bare
## and by-shndx arms would return an address instead of a refusal. If the two
## definitions collapsed into one, the fixture exits 3 before printing
## anything. If the `STT_FILE` attribution regressed, the by-file arms would
## resolve to the wrong one of two known addresses — not merely to "something".
##
## No silent skips: a missing compiler or fixture fails the gate.

import std/[json, os, osproc, strutils, unittest]

when defined(linux) and defined(amd64):

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
      checkpoint("required tool is not on PATH: " & name)
    require found.len > 0

  proc requireFixture(path: string) =
    if not fileExists(path):
      checkpoint("fixture source is missing: " & path)
    require fileExists(path)

  proc queryNode(report: JsonNode; label: string): JsonNode =
    for node in report["queries"]:
      if node["label"].getStr() == label:
        return node
    checkpoint("fixture produced no query labelled \"" & label &
      "\"; it and this gate have drifted apart")
    fail()
    newJObject()

  suite "integration_hcr_linux_static_local_symbol_ambiguity_refused":
    test "an ambiguous static name is refused and the qualified form resolves":
      requireTool("gcc")
      requireTool("readelf")

      let repoRoot = getCurrentDir()
      let fixtureDir = repoRoot / "tests" / "fixtures" / "hcr" /
        "linux-elf-symbols"
      let alphaSource = fixtureDir / "hcr_lx_amb_alpha.c"
      let betaSource = fixtureDir / "hcr_lx_amb_beta.c"
      let probeSource = fixtureDir / "hcr_lx_amb_probe.c"
      for path in [alphaSource, betaSource, probeSource]:
        requireFixture(path)

      let agentInclude = repoRoot / "libs" / "repro_hcr_agent" / "c"
      requireFixture(agentInclude / "repro_hcr_linux_elf_symbols.h")

      let workDir = repoRoot / "build" / "hcr-linux-amb"
      removeDir(workDir)
      createDir(workDir)
      let probePath = workDir / "hcr-lx-amb-probe"

      # `-ffunction-sections` is used deliberately: it is the configuration
      # MOST favourable to design §7.4's `st_shndx` key, because it gives every
      # function its own input section. The key still fails, because the
      # linker merges those sections back together in the output.
      discard runSuccess(shellCommand(["gcc", "-O2", "-g",
        "-ffunction-sections", "-Wl,--build-id=sha1", "-I" & fixtureDir,
        "-I" & agentInclude, probeSource, alphaSource, betaSource,
        "-o", probePath]), repoRoot)

      # The collision is real in the binary's own symbol table, asserted
      # independently of the resolver so that a resolver bug cannot make this
      # gate vacuous.
      let symbols = runSuccess(shellCommand(["readelf", "-sW", probePath]),
        repoRoot)
      var localDefinitions = 0
      var fileSymbols: seq[string] = @[]
      for line in symbols.splitLines():
        let fields = line.splitWhitespace()
        if fields.len < 8:
          continue
        if fields[^1] == "hcr_lx_ambiguous_helper" and fields[3] == "FUNC" and
            fields[4] == "LOCAL":
          localDefinitions += 1
        if fields[3] == "FILE":
          fileSymbols.add fields[^1]
      check localDefinitions == 2
      check "hcr_lx_amb_alpha.c" in fileSymbols
      check "hcr_lx_amb_beta.c" in fileSymbols

      let output = runSuccess(q(probePath), repoRoot).strip()
      let report =
        try:
          parseJson(output)
        except CatchableError as err:
          checkpoint("fixture did not emit parseable JSON: " & err.msg)
          checkpoint(output)
          fail()
          newJObject()
      check report["schemaId"].getStr() ==
        "reprobuild.hcr.hlx-m1.static-local-ambiguity.v1"

      let alphaAddress = uint64(report["alphaAddress"].getBiggestInt())
      let betaAddress = uint64(report["betaAddress"].getBiggestInt())
      check alphaAddress != 0'u64
      check betaAddress != 0'u64
      check alphaAddress != betaAddress

      # -------------------------------------------------------------------
      # Bare name: REFUSED, with both candidates named.
      # -------------------------------------------------------------------
      let bare = report.queryNode("bare")
      checkpoint("bare: " & bare["detail"].getStr())
      check bare["refusalName"].getStr() == "elf-symbol-ambiguous"
      check uint64(bare["resolvedAddress"].getBiggestInt()) == 0'u64
      check bare["matchCount"].getInt() == 2
      # "a diagnostic naming both candidates" is the design's wording, so the
      # diagnostic is asserted to name both — not merely to be non-empty.
      let bareDetail = bare["detail"].getStr()
      check bareDetail.contains("hcr_lx_amb_alpha.c")
      check bareDetail.contains("hcr_lx_amb_beta.c")
      check bareDetail.contains("LOCAL")
      check bare["candidates"].len == 2
      var candidateAddresses: seq[uint64] = @[]
      var candidateSections: seq[int] = @[]
      for candidate in bare["candidates"]:
        candidateAddresses.add uint64(
          candidate["runtimeAddress"].getBiggestInt())
        candidateSections.add candidate["sectionIndex"].getInt()
      check alphaAddress in candidateAddresses
      check betaAddress in candidateAddresses

      # -------------------------------------------------------------------
      # The measured correction to design §7.4. Both candidates sit in the
      # SAME output section, so the design's (object, name, st_shndx) tuple
      # cannot separate them and the qualified-by-shndx query is still refused.
      # -------------------------------------------------------------------
      check candidateSections.len == 2
      check candidateSections[0] == candidateSections[1]
      let byShndx = report.queryNode("by-shndx")
      checkpoint("by-shndx (design §7.4's tuple): " & byShndx["detail"].getStr())
      check byShndx["refusalName"].getStr() == "elf-symbol-ambiguous"
      check uint64(byShndx["resolvedAddress"].getBiggestInt()) == 0'u64
      check byShndx["matchCount"].getInt() == 2

      # -------------------------------------------------------------------
      # The key that works: the governing `STT_FILE` symbol. Each definition
      # resolves to the address the process reports for THAT definition, not
      # merely to one of the two.
      # -------------------------------------------------------------------
      let byFileAlpha = report.queryNode("by-file-alpha")
      checkpoint("by-file-alpha: " & byFileAlpha["detail"].getStr())
      check byFileAlpha["refusalName"].getStr() == "ok"
      check byFileAlpha["matchCount"].getInt() == 1
      check uint64(byFileAlpha["resolvedAddress"].getBiggestInt()) ==
        alphaAddress

      let byFileBeta = report.queryNode("by-file-beta")
      checkpoint("by-file-beta: " & byFileBeta["detail"].getStr())
      check byFileBeta["refusalName"].getStr() == "ok"
      check byFileBeta["matchCount"].getInt() == 1
      check uint64(byFileBeta["resolvedAddress"].getBiggestInt()) == betaAddress

      # The two qualifications select DIFFERENT definitions. Without this, both
      # arms could pass while the resolver ignored the hint and always returned
      # the same one.
      check byFileAlpha["resolvedAddress"] != byFileBeta["resolvedAddress"]

      # -------------------------------------------------------------------
      # The exact key, for completeness: st_value.
      # -------------------------------------------------------------------
      let byValue = report.queryNode("by-value-alpha")
      checkpoint("by-value-alpha: " & byValue["detail"].getStr())
      check byValue["refusalName"].getStr() == "ok"
      check byValue["matchCount"].getInt() == 1
      check uint64(byValue["resolvedAddress"].getBiggestInt()) == alphaAddress

      # -------------------------------------------------------------------
      # Evidence.
      # -------------------------------------------------------------------
      var evidence = newJObject()
      evidence["schemaId"] =
        newJString("reprobuild.hcr.hlx-m1.static-local-ambiguity-gate.v1")
      evidence["gccVersion"] =
        newJString(runSuccess("gcc --version", repoRoot).splitLines()[0])
      evidence["localDefinitionsInSymtab"] = %localDefinitions
      evidence["report"] = report
      evidence["designCorrection"] = %*{
        "section": "HCR/Linux-ELF-Provider.md §7.4",
        "designSays": "identify a patch target by (object file identity, " &
          "symbol name, st_shndx)",
        "measured": "in a linked image both static definitions share one " &
          "output .text section, so st_shndx selects both and the qualified " &
          "form is still refused. Measured with -ffunction-sections, the " &
          "configuration most favourable to the design's key.",
        "sharedSectionIndex": candidateSections[0],
        "keyThatWorks": "the governing STT_FILE symbol (the source translation " &
          "unit), which the ELF spec places immediately before the STB_LOCAL " &
          "symbols of its file; st_value is an exact alternative",
        "alphaAddress": "0x" & toHex(alphaAddress, 16),
        "betaAddress": "0x" & toHex(betaAddress, 16)
      }
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir /
        "integration_hcr_linux_static_local_symbol_ambiguity_refused.json",
        pretty(evidence))

else:
  suite "integration_hcr_linux_static_local_symbol_ambiguity_refused":
    test "HLX-M1 static-local ambiguity gate is linux-x86_64-only":
      skip()

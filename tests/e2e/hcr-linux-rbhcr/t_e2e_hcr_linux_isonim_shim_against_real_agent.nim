## HLX-M8 verification gate `e2e_hcr_linux_isonim_shim_against_real_agent`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md`;
## `reprobuild-specs/HCR/HCR-Overview.md` §13;
## `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
## Cross-repo: CodeTracer `Front-Ends/IsoNim/Hot-Module-Reload-Native`, NH-M5
## (which decided the library and header names) and NH-M4 (which consumes this).
##
## The milestone states it: "Builds IsoNim's shim against the real agent rather
## than the no-op fallback and asserts the ten symbols link, the callbacks fire
## in order, and a real patch reaches the application. Today this path has never
## been linked on any platform; the existing Linux green result exercises only
## the no-op branch."
##
## `allowed_mocks: none`. Everything is real: the real `isonim/native/hcr.nim`
## from the sibling IsoNim checkout (imported, not copied), the real
## `librepro_hcr_agent.so` built by the repo's own `build_lib.sh`, the real
## agent Unix socket and wire protocol, and real patch bytes from a real ELF
## relocatable object.
##
## A MISSING ISONIM CHECKOUT IS A LOUD FAILURE, never a skip. The whole subject
## of this gate is a cross-repo link line; a version of it that passed without
## IsoNim present would be asserting nothing at all. Same treatment HLX-M3's
## fixture gives the recorder's claim map.
##
## WHAT MAKES THIS GATE DISCRIMINATE.
##
## 1. `nm -u` on the built probe must list the rb_hcr_* symbols as UNDEFINED
##    and `ldd` must show `librepro_hcr_agent.so`. If the shim had compiled its
##    no-op fallback — the branch every previous "green on Linux" result took —
##    the binary would contain no such undefined symbol and no such
##    dependency, and both checks go red. That is the difference between
##    "linked against the real agent" and "compiled with HCR notionally on".
##
## 2. The callbacks OBSERVE rather than count: each calls the victim. The
##    before-callback must see 11 and the after-callback 77, in one process, in
##    one reload. Counting alone is green under the inverted ordering IsoNim's
##    design doc used to specify.
##
## 3. A NEGATIVE CONTROL builds the same probe source with `-d:reprobuildHcr`
##    OFF and measures that it links no `rb_hcr_*` symbol — the no-op branch,
##    named, so the gate can prove which branch it is on rather than assert it.

import std/[json, options, os, osproc, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl
  import m8_fixture

  const
    ProbeSymbols = [
      "rb_hcr_wants_reload", "rb_hcr_apply_reload",
      "rb_hcr_register_managed_type", "rb_hcr_unregister_managed_type",
      "rb_hcr_before_reload", "rb_hcr_after_reload",
      "rb_hcr_remove_before_reload", "rb_hcr_remove_after_reload",
      "rb_hcr_file_changed", "rb_hcr_type_changed"]
    AgentLibrary = "librepro_hcr_agent.so"

  proc isonimSrcDir(repoRoot: string): string =
    ## The sibling IsoNim checkout in the reprobuild workspace.
    result = repoRoot.parentDir / "isonim" / "src"

  proc buildAgentLibrary(repoRoot: string): string =
    let outDir = m8WorkDir(repoRoot) / "lib"
    createDir(outDir)
    discard runOrFail(shellCommand([
      repoRoot / "libs" / "repro_hcr_agent" / "build_lib.sh", outDir]),
      repoRoot)
    result = outDir / AgentLibrary
    doAssert fileExists(result)

  proc buildProbe(repoRoot, source, outputName: string;
                  defines: openArray[string]): string =
    let caseDir = m8CaseDir(repoRoot)
    let libDir = m8WorkDir(repoRoot) / "lib"
    let binDir = repoRoot / "build" / "test-bin"
    createDir(binDir)
    result = binDir / outputName
    let compileFlags = patchableCompileFlags(ReproHcr())
    var args = @["nim", "c", "--verbosity:0", "--hints:off",
                 "--nimcache:" & (repoRoot / "build" / "nimcache" /
                                  ("m8-probe-" & outputName)),
                 "--path:" & isonimSrcDir(repoRoot),
                 "--passC:-I" & (repoRoot / "libs" / "repro_hcr_agent" / "c"),
                 "--passC:-fcf-protection=full"]
    for flag in compileFlags:
      args.add "--passC:" & flag
    args.add "--passL:-L" & libDir
    args.add "--passL:-Wl,-rpath," & libDir
    args.add "--passL:-Wl,--build-id=sha1"
    for define in defines:
      args.add define
    args.add ["--out:" & result, caseDir / source]
    discard runOrFail(shellCommand(args), repoRoot)
    doAssert fileExists(result)

  suite "e2e_hcr_linux_isonim_shim_against_real_agent":
    test "IsoNim's shim links the real agent and a real patch reaches it":
      let repoRoot = getCurrentDir()

      # A missing sibling is a LOUD failure. The subject of this gate is a
      # cross-repo link line; without IsoNim there is nothing to assert.
      let isonimHcr = isonimSrcDir(repoRoot) / "isonim" / "native" / "hcr.nim"
      if not fileExists(isonimHcr):
        checkpoint("IsoNim's shim is not in this workspace: " & isonimHcr)
      require fileExists(isonimHcr)

      # NH-M5 reconciled the three names on 2026-09-14. Assert the IsoNim side
      # rather than trust it: this gate exists partly because the link line was
      # wrong for four months behind a green result.
      let shimSource = readFile(isonimHcr)
      check shimSource.contains("{.passL: \"-lrepro_hcr_agent\".}")
      check shimSource.contains("header: \"repro_hcr_agent.h\"")
      check not shimSource.contains("-lct_hcr_agent")
      check not shimSource.contains("reprobuild/hcr.h")

      let libPath = buildAgentLibrary(repoRoot)
      let libSymbols = runOrFail(
        shellCommand(["nm", "-D", "--defined-only", libPath]), repoRoot)
      for symbol in ProbeSymbols:
        check libSymbols.contains(" T " & symbol)

      let bodies = buildPatchBodies(repoRoot)

      # ---- the real, linked probe -----------------------------------------
      let probe = buildProbe(repoRoot, "isonim_shim_probe.nim",
        "hcr_lx_m8_isonim_probe",
        defines = ["-d:reprobuildHcr", "-d:isonimHmr"])

      # 1. The ten symbols are UNDEFINED in the probe and RESOLVED from the
      #    shared library. This is the difference between the FFI branch and
      #    the no-op fallback, and it is measured on the binary.
      let undefined = runOrFail(
        shellCommand(["nm", "-u", probe]), repoRoot)
      for symbol in ProbeSymbols:
        check undefined.contains(symbol)
      let linked = runOrFail(shellCommand(["ldd", probe]), repoRoot)
      check linked.contains(AgentLibrary)

      # 2. NEGATIVE CONTROL — the same IsoNim module, the same wrapper calls,
      #    built with the FFI gate OFF. That is the branch every previous
      #    "green on Linux" result took, and it must link NO rb_hcr_* symbol
      #    and NO agent library. Without it, check 1 is a claim about one
      #    artefact with nothing to compare it against.
      let fallbackProbe = buildProbe(repoRoot,
        "isonim_shim_fallback_probe.nim", "hcr_lx_m8_isonim_probe_noop",
        defines = ["-d:isonimHmr"])
      let fallbackUndefined = runOrFail(
        shellCommand(["nm", "-u", fallbackProbe]), repoRoot)
      for symbol in ProbeSymbols:
        check not fallbackUndefined.contains(symbol)
      let fallbackLinked = runOrFail(
        shellCommand(["ldd", fallbackProbe]), repoRoot)
      check not fallbackLinked.contains(AgentLibrary)
      let fallbackOut = execCmdEx(quoteShell(fallbackProbe))
      check fallbackOut.exitCode == 0
      let fallbackJson = parseJson(fallbackOut.output.strip())
      check not fallbackJson["wantsReload"].getBool()
      check not fallbackJson["fileChanged"].getBool()

      # ---- 3. a real patch reaches the application ------------------------
      let run = runReload(repoRoot, probe, "m8-isonim.sock",
        m8PatchRequest("hlx-m8-isonim-1", bodies.normal,
                       changedTypes = [managedTypeChange()]),
        managedTypes = [ProbeManagedType],
        schemaId = "reprobuild.hcr.hlx-m8.isonim-shim-probe-result.v1")
      if run.delivery.patchFailed.isSome:
        checkpoint("agent refused the patch: " &
          run.delivery.patchFailed.get().message)
        checkpoint(run.targetOutput)
      require run.delivery.patchApplied.isSome
      check run.delivery.session.lifecycleEvents ==
        @["hcr/patchApplying", "hcr/patchApplied"]

      let a = run.targetJson
      check a["schemaId"].getStr() ==
        "reprobuild.hcr.hlx-m8.isonim-shim-probe-result.v1"
      # The seam is installed-but-empty, so every wrapper fell through to the
      # real agent rather than to a double.
      check not a["hcrAgentHooksInstalled"].getBool()
      check a["startRc"].getInt() == 0
      check a["wantsReloadBeforeApply"].getBool()
      check not a["wantsReloadAfterApply"].getBool()
      check a["before"].getInt() == OriginalValue
      check a["after"].getInt() == PatchedValue
      check a["codeSwapped"].getBool()
      check a["rejection"].getStr() == ""

      # The callbacks fired, once each, in the normative order.
      check a["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,trampolines,after"
      check a["beforeUserData"].getStr() == "0x8100"
      check a["afterUserData"].getStr() == "0x8200"

      let observedBefore = a["observedInBefore"]
      let observedAfter = a["observedInAfter"]
      check observedBefore["fired"].getInt() == 1
      check observedAfter["fired"].getInt() == 1
      # Phase E sees the OLD body; Phase H sees the NEW one.
      check observedBefore["victim"].getInt() == OriginalValue
      check observedAfter["victim"].getInt() == PatchedValue

      # NH-M2's per-field `importc` pragmas are load-bearing and this is where
      # they are exercised end to end: a Nim callback READING `type_name`,
      # `old_size` and `new_size` out of a real C `RbHcrTypeChange`.
      for observed in [observedBefore, observedAfter]:
        check observed["changedFilesCount"].getInt() == 1
        check observed["firstFile"].getStr() == ProbeChangedFile
        check observed["changedTypesCount"].getInt() == 1
        check observed["firstType"].getStr() == ProbeManagedType
        check observed["firstTypeOldSize"].getInt() == 24
        check observed["firstTypeNewSize"].getInt() == 40
        check observed["fileChangedProbe"].getBool()
        check not observed["fileChangedAbsent"].getBool()
        check observed["typeChangedProbe"].getBool()

      check a["fileChangedProbeAtEnd"].getBool()
      check not a["fileChangedAbsentAtEnd"].getBool()
      check a["typeChangedProbeAtEnd"].getBool()

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.hlx-m8.isonim-shim.v1")
      inspection["isonimShim"] = newJString(isonimHcr)
      inspection["agentLibrary"] = newJString(libPath)
      inspection["probeUndefinedSymbols"] = %ProbeSymbols
      inspection["ldd"] = newJString(linked.strip())
      inspection["probeResult"] = a
      writeInspection(repoRoot, "e2e_hcr_linux_isonim_shim_against_real_agent",
                      inspection)

else:
  suite "e2e_hcr_linux_isonim_shim_against_real_agent":
    test "HLX-M8 IsoNim shim gate is linux-x86_64-only":
      skip()

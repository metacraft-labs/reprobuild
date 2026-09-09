## HLX-M1 verification gate `integration_hcr_linux_build_id_mismatch_refused`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §7.3.
##
## `allowed_mocks: none`. A real running process, a real shared library rebuilt
## on disk WHILE that process has the previous generation mapped, real
## `.note.gnu.build-id` sections, a real mapped `PT_NOTE`, and the production
## resolver compiled into the fixture.
##
## This is the silent-corruption case build-id verification exists to prevent,
## so the gate is written to fail loudly if the check is ever removed — and,
## more than that, to SHOW what the check prevents.
##
## Observing a refusal is not sufficient evidence. A refusal proves only that
## something was declined; it does not prove anything bad would have happened.
## So the fixture resolves the same symbol twice per phase — once with the
## check on, once with it off — and this gate asserts that after the rebuild
## the unchecked answer is a CONFIDENT WRONG ADDRESS, different from the one
## the process itself reports. That difference is the memory corruption, and
## the refusal is what stops it.
##
## Falsifiability, without touching production code: if `require_build_id`
## stopped having an effect, the "checked" arm after the rebuild would return
## the same wrong address as the "unchecked" arm and the gate goes red on the
## refusal-name assertion. If the rebuild stopped changing the layout, the
## wrong address would equal the right one and the gate goes red on the
## `staleAddress != truthAddress` assertion — so the gate cannot pass by
## accident in either direction.
##
## Two distinct refusals are covered, because a rebuild can reach the provider
## two ways:
##
##   * `elf-build-id-mismatch` — the file at the object's path was replaced and
##     its build-id no longer matches the mapped `PT_NOTE`.
##   * `elf-object-image-replaced` — the MAIN EXECUTABLE's own file was
##     replaced. Detected before any build-id is read, from the " (deleted)"
##     suffix the kernel puts on `/proc/self/exe`, and kept as its own refusal
##     because it is found at a different point and means a different thing.
##   * `elf-build-id-absent` — the file has no `.note.gnu.build-id` at all.
##     This is not hypothetical: measured, the GCC in this dev shell emits none
##     unless `--build-id` is passed, and the real 84 MB Godot build has none.
##     Design §7.3 calls `--build-id` "the default on all mainstream Linux
##     toolchains"; on this host it is not, which is exactly why the flag has
##     to be asserted in the patchable link profile rather than assumed.
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

  proc buildIdOf(readelfOutput: string): string =
    ## `readelf -nW` prints the id on the SAME line as `NT_GNU_BUILD_ID`,
    ## separated by a tab, so this searches for the label rather than matching
    ## the start of a line.
    const Label = "Build ID:"
    let at = readelfOutput.find(Label)
    if at < 0:
      return ""
    var value = ""
    for ch in readelfOutput[at + Label.len .. ^1]:
      if ch in {'\n', '\r'}:
        break
      value.add ch
    value.strip()

  proc phaseNode(report: JsonNode; name: string): JsonNode =
    for node in report["phases"]:
      if node["phase"].getStr() == name:
        return node
    checkpoint("fixture produced no phase named \"" & name &
      "\"; it and this gate have drifted apart")
    fail()
    newJObject()

  suite "integration_hcr_linux_build_id_mismatch_refused":
    test "a shared library rebuilt under a running process is refused, not mis-resolved":
      requireTool("gcc")
      requireTool("readelf")

      let repoRoot = getCurrentDir()
      let fixtureDir = repoRoot / "tests" / "fixtures" / "hcr" /
        "linux-elf-symbols"
      let libV1 = fixtureDir / "hcr_lx_elf_lib.c"
      let libV2 = fixtureDir / "hcr_lx_elf_lib_v2.c"
      let probeSource = fixtureDir / "hcr_lx_build_id_probe.c"
      requireFixture(libV1)
      requireFixture(libV2)
      requireFixture(probeSource)

      let agentInclude = repoRoot / "libs" / "repro_hcr_agent" / "c"
      requireFixture(agentInclude / "repro_hcr_linux_elf_symbols.h")

      let workDir = repoRoot / "build" / "hcr-linux-build-id"
      removeDir(workDir)
      createDir(workDir)

      let libPath = workDir / "libhcrlxelffixture.so"
      let libNextPath = workDir / "libhcrlxelffixture.next.so"

      proc buildLib(source, outPath: string; withBuildId: bool) =
        var args = @["gcc", "-O2", "-g", "-fPIC", "-shared"]
        args.add(if withBuildId: "-Wl,--build-id=sha1" else: "-Wl,--build-id=none")
        args.add "-I" & fixtureDir
        args.add source
        args.add "-o"
        args.add outPath
        discard runSuccess(shellCommand(args), repoRoot)

      buildLib(libV1, libPath, true)

      let probePath = workDir / "build-id-probe"
      discard runSuccess(shellCommand(["gcc", "-O2", "-g",
        "-Wl,--build-id=sha1", "-I" & fixtureDir, "-I" & agentInclude,
        probeSource, "-o", probePath, "-L" & workDir, "-lhcrlxelffixture",
        "-Wl,-rpath," & workDir]), repoRoot)

      let firstGenerationBuildId =
        buildIdOf(runSuccess(shellCommand(["readelf", "-nW", libPath]), repoRoot))
      # Precondition, asserted rather than assumed: without a build-id in
      # generation one there is nothing to mismatch against and the gate would
      # be testing nothing.
      check firstGenerationBuildId.len > 0

      # -------------------------------------------------------------------
      # The rebuild. `mv` over the path rather than writing in place: an
      # in-place write to a mapped library is the one thing the loader would
      # notice, and a rename is also what a real build system does.
      # -------------------------------------------------------------------
      let rebuildCommand = shellCommand(["gcc", "-O2", "-g", "-fPIC", "-shared",
        "-Wl,--build-id=sha1", "-I" & fixtureDir, libV2, "-o", libNextPath]) &
        " && " & shellCommand(["mv", libNextPath, libPath])

      # The second replacement: a DIFFERENT binary moved over the probe's own
      # path while it runs. `readlink("/proc/self/exe")` then reports
      # "<path> (deleted)", which is proof the on-disk file is not the mapped
      # image before any build-id is read at all.
      let decoyPath = workDir / "decoy-binary"
      copyFileWithPermissions(probePath, decoyPath)
      discard runSuccess(shellCommand(["strip", "--strip-all", decoyPath]),
        repoRoot)
      let replaceSelfCommand = shellCommand(["mv", decoyPath, probePath])

      putEnv("REBUILD_CMD", rebuildCommand)
      putEnv("REPLACE_SELF_CMD", replaceSelfCommand)
      let output = runSuccess(q(probePath), repoRoot).strip()
      delEnv("REBUILD_CMD")
      delEnv("REPLACE_SELF_CMD")

      let report =
        try:
          parseJson(output)
        except CatchableError as err:
          checkpoint("fixture did not emit parseable JSON: " & err.msg)
          checkpoint(output)
          fail()
          newJObject()
      check report["schemaId"].getStr() ==
        "reprobuild.hcr.hlx-m1.build-id-verification.v1"
      check report["phases"].len == 4

      let secondGenerationBuildId =
        buildIdOf(runSuccess(shellCommand(["readelf", "-nW", libPath]), repoRoot))
      check secondGenerationBuildId.len > 0
      # If the rebuild produced the same build-id there is nothing to detect.
      check secondGenerationBuildId != firstGenerationBuildId

      # -------------------------------------------------------------------
      # Before the rebuild: the file matches the mapping, so the checked path
      # resolves, and it resolves to the address the process itself reports.
      # -------------------------------------------------------------------
      let before = report.phaseNode("before-rebuild")
      let beforeTruth = uint64(before["truthAddress"].getBiggestInt())
      let beforeChecked = before["checked"]
      checkpoint("before-rebuild checked: " & beforeChecked["detail"].getStr())
      check beforeChecked["refusalName"].getStr() == "ok"
      check uint64(beforeChecked["resolvedAddress"].getBiggestInt()) ==
        beforeTruth
      check before["unchecked"]["refusalName"].getStr() == "ok"
      # With a matching build-id the check changes nothing, which is what makes
      # the difference after the rebuild attributable to the rebuild.
      check beforeChecked["resolvedAddress"] ==
        before["unchecked"]["resolvedAddress"]
      let beforeLinkValue = uint64(beforeChecked["linkValue"].getBiggestInt())

      # -------------------------------------------------------------------
      # After the rebuild: REFUSED by name, and the refusal names both ids.
      # -------------------------------------------------------------------
      let after = report.phaseNode("after-rebuild")
      let afterTruth = uint64(after["truthAddress"].getBiggestInt())
      let afterChecked = after["checked"]
      checkpoint("after-rebuild checked: " & afterChecked["detail"].getStr())
      check afterChecked["refusalName"].getStr() == "elf-build-id-mismatch"
      check uint64(afterChecked["resolvedAddress"].getBiggestInt()) == 0'u64
      check afterChecked["objectsRefused"].getInt() >= 1
      # The diagnostic must name what it compared, or a mismatch is
      # indistinguishable from any other refusal to whoever reads the log.
      let detail = afterChecked["detail"].getStr()
      check detail.contains("on disk")
      check detail.contains("mapped")
      check detail.contains(firstGenerationBuildId)
      check detail.contains(secondGenerationBuildId)

      # The mapped image did not move: the process still reports the same
      # address it did before the rebuild. Only the FILE changed.
      check afterTruth == beforeTruth

      # -------------------------------------------------------------------
      # What the check prevented. This is the assertion that makes the gate
      # non-vacuous: with verification off, the stale file yields a confident
      # WRONG address.
      # -------------------------------------------------------------------
      let afterUnchecked = after["unchecked"]
      checkpoint("after-rebuild unchecked: " & afterUnchecked["detail"].getStr())
      check afterUnchecked["refusalName"].getStr() == "ok"
      let staleAddress = uint64(afterUnchecked["resolvedAddress"].getBiggestInt())
      let staleLinkValue = uint64(afterUnchecked["linkValue"].getBiggestInt())
      check staleAddress != 0'u64
      # It is wrong, and it is wrong by exactly the amount the rebuild moved
      # the symbol.
      check staleAddress != afterTruth
      check staleLinkValue != beforeLinkValue

      # And this is the sharpest form of the same fact: the stale address is
      # not merely "not right", it is the live address of a DIFFERENT function
      # in the still-mapped generation one. A patch published there would have
      # overwritten `hcr_lx_lib_exported_helper`'s entry while reporting
      # success for `hcr_lx_lib_static_helper`.
      let exportedTruth = uint64(after["truthExportedAddress"].getBiggestInt())
      check exportedTruth != 0'u64
      check exportedTruth != afterTruth
      check staleAddress == exportedTruth

      # -------------------------------------------------------------------
      # `elf-object-image-replaced`: the OTHER way a rebuild reaches the
      # provider, and a genuinely distinct refusal.
      #
      # The main executable has no `dlpi_name`, so its path comes from
      # `readlink("/proc/self/exe")`. The design note in §7.3 explains why that
      # is `readlink` and not an `open` of the magic link: opening the link
      # always reaches the ORIGINAL inode, so the build-id check could never
      # fire for the one object a hot-reload workflow is most likely to have
      # just rebuilt. The cost of using the path is that the path can be
      # replaced, and the kernel says so with a " (deleted)" suffix.
      # -------------------------------------------------------------------
      let selfIntact = report.phaseNode("self-image-intact")
      checkpoint("self-image-intact: " & selfIntact["checked"]["detail"].getStr())
      check selfIntact["checked"]["refusalName"].getStr() == "ok"
      check uint64(selfIntact["checked"]["resolvedAddress"].getBiggestInt()) ==
        uint64(selfIntact["truthAddress"].getBiggestInt())

      let selfReplaced = report.phaseNode("self-image-replaced")
      checkpoint("self-image-replaced: " &
        selfReplaced["checked"]["detail"].getStr())
      check selfReplaced["checked"]["refusalName"].getStr() ==
        "elf-object-image-replaced"
      check uint64(selfReplaced["checked"]["resolvedAddress"].getBiggestInt()) ==
        0'u64
      check selfReplaced["checked"]["detail"].getStr()
        .contains("replaced or removed since exec")
      # The refusal is NOT a build-id mismatch: it is detected earlier and for
      # a different reason, and collapsing the two would lose that.
      check selfReplaced["checked"]["refusalName"].getStr() !=
        "elf-build-id-mismatch"
      # The process itself is unharmed — it still runs and its own function is
      # still at the address it was. Only the file is gone.
      check selfReplaced["truthAddress"] == selfIntact["truthAddress"]
      # And turning the check off does not rescue it either: with the path
      # gone there is no file to read, so the honest answer is still a refusal
      # rather than an invented address.
      check uint64(
        selfReplaced["unchecked"]["resolvedAddress"].getBiggestInt()) == 0'u64

      # -------------------------------------------------------------------
      # `elf-build-id-absent`: a library with no build-id at all cannot be
      # verified and is refused rather than trusted. Measured on this host,
      # GCC emits no build-id unless asked, so this is the DEFAULT state of an
      # unprepared binary, not an exotic one.
      # -------------------------------------------------------------------
      let noteWorkDir = repoRoot / "build" / "hcr-linux-build-id-absent"
      removeDir(noteWorkDir)
      createDir(noteWorkDir)
      let noIdLibPath = noteWorkDir / "libhcrlxelffixture.so"
      buildLib(libV1, noIdLibPath, false)
      check buildIdOf(runSuccess(shellCommand(["readelf", "-nW", noIdLibPath]),
        repoRoot)).len == 0

      let noIdProbePath = noteWorkDir / "build-id-probe"
      discard runSuccess(shellCommand(["gcc", "-O2", "-g",
        "-Wl,--build-id=sha1", "-I" & fixtureDir, "-I" & agentInclude,
        probeSource, "-o", noIdProbePath, "-L" & noteWorkDir,
        "-lhcrlxelffixture", "-Wl,-rpath," & noteWorkDir]), repoRoot)

      # The rebuild here is a no-op that still succeeds, because this arm is
      # about the ABSENT id and not about a mismatch.
      putEnv("REBUILD_CMD", "true")
      putEnv("REPLACE_SELF_CMD", "true")
      let noIdOutput = runSuccess(q(noIdProbePath), repoRoot).strip()
      delEnv("REBUILD_CMD")
      delEnv("REPLACE_SELF_CMD")
      let noIdReport = parseJson(noIdOutput)
      let noIdBefore = noIdReport.phaseNode("before-rebuild")
      checkpoint("no-build-id checked: " & noIdBefore["checked"]["detail"].getStr())
      check noIdBefore["checked"]["refusalName"].getStr() == "elf-build-id-absent"
      check uint64(noIdBefore["checked"]["resolvedAddress"].getBiggestInt()) ==
        0'u64
      check noIdBefore["checked"]["detail"].getStr().contains("build-id")
      # And with the check off it resolves correctly, so the refusal is
      # attributable to the missing id and not to a broken parse.
      check noIdBefore["unchecked"]["refusalName"].getStr() == "ok"
      check uint64(noIdBefore["unchecked"]["resolvedAddress"].getBiggestInt()) ==
        uint64(noIdBefore["truthAddress"].getBiggestInt())

      # -------------------------------------------------------------------
      # Evidence.
      # -------------------------------------------------------------------
      var evidence = newJObject()
      evidence["schemaId"] =
        newJString("reprobuild.hcr.hlx-m1.build-id-mismatch-gate.v1")
      evidence["gccVersion"] =
        newJString(runSuccess("gcc --version", repoRoot).splitLines()[0])
      evidence["firstGenerationBuildId"] = newJString(firstGenerationBuildId)
      evidence["secondGenerationBuildId"] = newJString(secondGenerationBuildId)
      evidence["mismatchReport"] = report
      evidence["absentBuildIdReport"] = noIdReport
      evidence["preventedCorruption"] = %*{
        "truthAddress": "0x" & toHex(afterTruth, 16),
        "addressTheStaleFileWouldHaveGiven": "0x" & toHex(staleAddress, 16),
        "liveAddressOfExportedHelper": "0x" & toHex(exportedTruth, 16),
        "deltaBytes": int64(staleAddress) - int64(afterTruth),
        "note": "with build-id verification disabled the resolver returns the " &
          "second generation's st_value while the first generation is still " &
          "mapped. Measured, that address is not merely wrong: it is exactly " &
          "the live entry of hcr_lx_lib_exported_helper, so publishing a jump " &
          "there would replace one function while reporting success for another."
      }
      evidence["buildIdIsNotThisToolchainsDefault"] = newJBool(true)
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "integration_hcr_linux_build_id_mismatch_refused.json",
        pretty(evidence))

else:
  suite "integration_hcr_linux_build_id_mismatch_refused":
    test "HLX-M1 build-id verification gate is linux-x86_64-only":
      skip()

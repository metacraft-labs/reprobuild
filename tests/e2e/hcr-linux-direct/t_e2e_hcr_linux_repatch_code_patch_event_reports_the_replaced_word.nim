## Gate `e2e_hcr_linux_repatch_code_patch_event_reports_the_replaced_word`.
##
## Property: for a RE-PATCH of an already-patched function, the code-patch
## event the Linux agent emits describes the word its publishing store actually
## replaced — generation N's jump — not the function's original, unpatched
## window. So at one site each event's before-word and before-hash equal the
## previous event's after-word and after-hash.
##
## Spec: reprobuild-pm `spec/HCR/Linux-ELF-Provider.md` §10.3, paragraph
## '"Before" is the word the publishing store replaced'.
## Issue: reprobuild-pm
## `issues/2026-11-15-hcr-code-patch-event-reports-generation-0-as-the-word-a-re-patch-replaced.md`.
##
## Shape. One real target process (`hcr_lx_repatch_target.c`, built with the
## real patchable profile and linking the production C agent) is patched TWICE
## over ONE open agent session: generation 1 returns 77, generation 2 returns
## 99. The target captures both code-patch notes by defining the recorder entry
## point `ct_repro_hcr_agent_did_patch_v2`, which the agent calls exactly as it
## would call `libct_interpose`'s under `ct-mcr record`. It also observes, on
## its own, the pristine window (dumped before the first poll) and the window's
## live bytes inside each hook call (the word the store just wrote). The gate
## checks the agent's claims against those observations and recomputes every
## digest with an independent SHA-256, so it cannot pass on a pair of digests
## that are consistently wrong.
##
## `allowed_mocks: none`. Real GCC, real patchable profile, real relocatable
## object for the patch bodies, real `mmap`/page replacement inside the
## production agent, real Unix socket and Content-Length wire protocol driven
## by the production `HcrCoordinatorClient`. The recorder hook is the target's
## own definition of the real bridge symbol — it is the observation point, not
## a stand-in for anything the agent does.
##
## No silent skips on Linux x86_64. The `skip()` arm exists only for platforms
## that are not Linux x86_64.

from repro_core/process_streams import drainStream
import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]
import repro_test_support/reasoned_skip
when defined(posix):
  from repro_test_support/process_fixtures import shortSocketDirAtProcessExit

when defined(linux) and defined(amd64):
  import nimcrypto/sha2

  import repro_hcr_agent
  import repro_project_dsl

  import elf_rel_reader

  let PatchableCompileFlags = patchableCompileFlags(ReproHcr())
  let PatchableLinkFlags = patchableLinkFlags(ReproHcr())

  const
    SupportProfile = HcrLinuxX86_64DirectSupportProfile
    TargetSymbol = "hcr_lx_repatch_entry"
    Gen1Symbol = "hcr_lx_repatch_body_gen1"
    Gen2Symbol = "hcr_lx_repatch_body_gen2"
    WindowBytes = 8

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

  proc requireCompiler(name: string) =
    let found = findExe(name)
    if found.len == 0:
      checkpoint("required compiler not on PATH: " & name)
    require found.len > 0

  proc parseHexWord(value: string): uint64 =
    ## "0x…" as printed by the target. `parseHexInt` would overflow an int for
    ## a word with the top bit set, so this goes through `fromHex[uint64]`.
    fromHex[uint64](value.replace("0x", ""))

  proc wordBytes(word: uint64): seq[byte] =
    ## The word in its in-memory (little-endian) byte order: the bytes a reader
    ## finds at `windowAddress`.
    for i in 0 ..< WindowBytes:
      result.add byte((word shr (8 * i)) and 0xff'u64)

  proc sha256Hex(bytes: openArray[byte]): string =
    toLowerAscii($sha256.digest(bytes))

  proc wordFromHexBytes(hex: string; offset: int): uint64 =
    ## Little-endian word starting at byte `offset` of a hex dump.
    for i in 0 ..< WindowBytes:
      let b = parseHexInt(hex[(offset + i) * 2 ..< (offset + i) * 2 + 2])
      result = result or (uint64(b) shl (8 * i))

  proc request(patchId: string; bytes: seq[byte]): HcrPatchRequest =
    directPatchRequest(
      patchId = patchId,
      supportProfile = SupportProfile,
      changedFunctions = [TargetSymbol],
      targetSymbols = [TargetSymbol],
      directPatchBytes = bytes,
      debugObjectBytes = [],
      unwindMetadataBytes = [],
      sourceGenerationMap = [])

  suite "e2e_hcr_linux_repatch_code_patch_event_reports_the_replaced_word":
    test "a re-patch's codeWordBefore and codeHashBefore are the previous " &
        "generation's after-word and after-hash":
      requireCompiler("gcc")
      let repoRoot = getCurrentDir()
      let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-direct"
      let workDir = repoRoot / "build" / "hcr-linux-repatch-note"
      let binDir = repoRoot / "build" / "test-bin"
      createDir(workDir)
      createDir(binDir)

      # 1. Two real patch bodies out of one real relocatable object.
      let patchObj = workDir / "hcr_lx_repatch_patch.o"
      discard runSuccess(shellCommand([
        "gcc", "-c", "-O2", "-fcf-protection=full", "-ffunction-sections",
        caseDir / "hcr_lx_repatch_patch.c", "-o", patchObj]), repoRoot)
      let obj = parseElfRelObject(patchObj)
      var bodies: seq[seq[byte]]
      for (symbol, movImm) in [(Gen1Symbol, "b84d000000"),
                               (Gen2Symbol, "b863000000")]:
        let section = obj.definingSectionName(symbol)
        check section == ".text." & symbol
        check obj.relocationCount(section) == 0
        let bytes = obj.functionBytes(symbol)
        require bytes.len > 0
        # `mov $77,%eax` / `mov $99,%eax`: the values the target will observe.
        check hexBytes(bytes).contains(movImm)
        bodies.add bytes

      # 2. The real target, real patchable profile, production C agent.
      let targetBin = binDir / "hcr_lx_repatch_target"
      check PatchableCompileFlags.contains("-fpatchable-function-entry=16,0")
      check PatchableLinkFlags.contains("-Wl,--build-id=sha1")
      discard runSuccess(shellCommand(
        @["gcc", "-O2", "-g"] & PatchableCompileFlags &
        @["-fcf-protection=full",
        "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
        "-o", targetBin,
        caseDir / "hcr_lx_repatch_target.c",
        repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
        PatchableLinkFlags & @["-lpthread"]), repoRoot)
      check fileExists(targetBin)

      # 3. One session, two patches.
      let socketPath =
        shortSocketDirAtProcessExit("hcr-") / "hcr-lx-repatch.sock"
      removeFile(socketPath)
      var listener = listenHcrAgentUnixSocket(socketPath)
      defer: listener.close()

      var env = newStringTable()
      for key, value in envPairs():
        env[key] = value
      env[ReproHcrAgentSocketEnv] = socketPath
      let process = startProcess(targetBin, workingDir = repoRoot,
        env = env, options = {poStdErrToStdOut})

      var connection = acceptHcrAgentConnection(listener)
      var client = initHcrCoordinatorClient(SupportProfile)
      client.completeHandshake(connection)
      let delivery1 = client.requestPatchOnOpenSession(
        connection, request("hlx-repatch-note-gen1", bodies[0]))
      let delivery2 = client.requestPatchOnOpenSession(
        connection, request("hlx-repatch-note-gen2", bodies[1]))
      connection.close()

      let output = drainStream(process.outputStream)
      let exitCode = process.waitForExit()
      process.close()
      checkpoint("target output: " & output)
      require exitCode == 0

      # 4. Both patches applied over the wire, each with a code-patch report.
      for (delivery, patchId) in [(delivery1, "hlx-repatch-note-gen1"),
                                  (delivery2, "hlx-repatch-note-gen2")]:
        if delivery.patchFailed.isSome:
          checkpoint("agent refused " & patchId & ": " &
            delivery.patchFailed.get().message)
        require delivery.patchFailed.isNone
        require delivery.patchApplied.isSome
        check delivery.patchApplied.get().patchId == patchId
        require delivery.patchApplied.get().codePatchEvent.present
        check delivery.patchApplied.get().codePatchEvent.hashSelfTest
        check delivery.patchApplied.get().codePatchEvent.bridgePresent
        check delivery.patchApplied.get().codePatchEvent.recorded

      # 5. The target's own observations.
      let result = parseJson(output.strip())
      check result["schemaId"].getStr() ==
        "reprobuild.hcr.linux-repatch-note-result.v1"
      check result["startRc"].getInt() == 0
      check result["pollRc"].getInt() == 0
      check result["before"].getInt() == 11
      check result["after"].getInt() == 99
      # The hook bound and fired once per publication — no more, no fewer.
      require result["hookCalls"].getInt() == 2
      let notes = result["notes"]
      require notes.len == 2
      let note1 = notes[0]
      let note2 = notes[1]
      for note in [note1, note2]:
        check note["structSize"].getInt() ==
          result["expectedStructSize"].getInt()
        check note["noteVersion"].getInt() == 1
        check note["siteCount"].getInt() == 1
        check note["windowLength"].getInt() == WindowBytes
        check note["hasHashes"].getBool()
        check note["entryAddress"].getStr() == result["entryAddress"].getStr()
      check note1["observedReturn"].getInt() == 77
      check note2["observedReturn"].getInt() == 99
      check note1["generation"].getInt() == 1
      check note2["generation"].getInt() == 2

      # One site, both times.
      let windowAddress = parseHexWord(note1["windowAddress"].getStr())
      check parseHexWord(note2["windowAddress"].getStr()) == windowAddress
      check (windowAddress and 7'u64) == 0'u64
      let entryAddress = parseHexWord(result["entryAddress"].getStr())
      require windowAddress >= entryAddress
      let windowOffset = int(windowAddress - entryAddress)
      require windowOffset + WindowBytes <= 32

      # The independently observed words.
      let pristineWord =
        wordFromHexBytes(result["entryBytesBeforeHex"].getStr(), windowOffset)
      let observedAfter1 = parseHexWord(note1["observedWindowWord"].getStr())
      let observedAfter2 = parseHexWord(note2["observedWindowWord"].getStr())
      # Sanity on the observations themselves: the sled was all NOPs, and each
      # store changed the window.
      check pristineWord == 0x9090909090909090'u64
      check observedAfter1 != pristineWord
      check observedAfter2 != observedAfter1

      let before1 = parseHexWord(note1["codeWordBefore"].getStr())
      let after1 = parseHexWord(note1["codeWordAfter"].getStr())
      let before2 = parseHexWord(note2["codeWordBefore"].getStr())
      let after2 = parseHexWord(note2["codeWordAfter"].getStr())
      checkpoint("pristine=0x" & toHex(pristineWord) &
        " observedAfter1=0x" & toHex(observedAfter1) &
        " observedAfter2=0x" & toHex(observedAfter2))
      checkpoint("note1 before=0x" & toHex(before1) & " after=0x" & toHex(after1))
      checkpoint("note2 before=0x" & toHex(before2) & " after=0x" & toHex(after2))

      # First publication: before is the pristine window, after is store 1.
      check before1 == pristineWord
      check after1 == observedAfter1
      # THE PROPERTY. The re-patch replaced generation 1's jump, not the NOPs.
      check before2 == after1
      check before2 == observedAfter1
      check before2 != pristineWord
      check after2 == observedAfter2

      # Digests: SHA-256 of the observed little-endian window bytes, computed
      # here with an independent implementation.
      let h1Before = note1["codeHashBefore"].getStr()
      let h1After = note1["codeHashAfter"].getStr()
      let h2Before = note2["codeHashBefore"].getStr()
      let h2After = note2["codeHashAfter"].getStr()
      check h1Before == sha256Hex(wordBytes(pristineWord))
      check h1After == sha256Hex(wordBytes(observedAfter1))
      check h2Before == sha256Hex(wordBytes(observedAfter1))
      check h2After == sha256Hex(wordBytes(observedAfter2))
      check h2Before == h1After
      check h2Before != h1Before

      # 6. The same property on the wire: the `codePatchEvent` reported in
      #    each `patchApplied` carries the same digests as the note.
      let wire1 = delivery1.patchApplied.get().codePatchEvent
      let wire2 = delivery2.patchApplied.get().codePatchEvent
      check wire1.codeHashBefore == "sha256:" & h1Before
      check wire1.codeHashAfter == "sha256:" & h1After
      check wire2.codeHashBefore == "sha256:" & h2Before
      check wire2.codeHashAfter == "sha256:" & h2After
      check wire2.codeHashBefore == wire1.codeHashAfter
      check wire2.codeHashBefore != wire1.codeHashBefore

else:
  suite "e2e_hcr_linux_repatch_code_patch_event_reports_the_replaced_word":
    test "linux/amd64 only":
      skip("the Linux ELF provider (repro_hcr_linux_x86_64.h) exists only " &
        "on linux/amd64; this gate has no other-platform arm")

import std/[json, os, osproc, streams, strutils, unittest]

import repro_hcr_agent
import repro_hcr_linkgraph

import m28_packet

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  for index, arg in args:
    if index > 0:
      result.add(" ")
    result.add(q(arg))

proc runSuccess(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint(res.output)
  check res.exitCode == 0
  res.output

proc readBytes(path: string): seq[byte] =
  let raw = readFile(path)
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc writeBytes(stream: Stream; bytes: openArray[byte]) =
  if bytes.len > 0:
    stream.writeData(unsafeAddr bytes[0], bytes.len)
  stream.flush()

proc runTargetWithPacket(targetBin: string; packetBytes: openArray[byte];
                         cwd: string): JsonNode =
  let process = startProcess(targetBin, workingDir = cwd,
    options = {poStdErrToStdOut})
  process.inputStream.writeBytes(packetBytes)
  process.inputStream.close()
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    checkpoint(output)
  check exitCode == 0
  check not output.contains("dlopen")
  check not output.contains("dlsym")
  check not output.contains("LoadLibrary")
  check not output.contains("GetProcAddress")
  parseJson(output)

proc eventNames(node: JsonNode): seq[string] =
  for event in node["lifecycleEvents"]:
    result.add event["event"].getStr()

proc buildDebugObject(repoRoot: string): seq[byte] =
  let workDir = repoRoot / "build" / "hcr-m28-debug-object"
  createDir(workDir)
  let asmPath = workDir / "hcr_m28_debug_object.s"
  let objPath = workDir / "hcr_m28_debug_object.o"
  writeFile(asmPath, """
.text
.globl _hcr_m28_debug_object
_hcr_m28_debug_object:
  ret
""")
  discard runSuccess(shellCommand([
    "clang", "-c", "-arch", "arm64", "-g", asmPath, "-o", objPath
  ]), repoRoot)
  readBytes(objPath)

proc expectM28Result(result: JsonNode; packetBytes: openArray[byte];
                     debugObjectBytes: openArray[byte];
                     patchTemplateBytes: openArray[byte];
                     runLabel: string) =
  checkpoint(runLabel)
  check result["schemaId"].getStr() ==
    "reprobuild.hcr.m28.debug-unwind-replay-result.v1"
  check result["supportProfile"].getStr() ==
    "m28-macos-arm64-direct-debug-unwind-replay"
  check result["before"].getInt() == 11
  check result["after"].getInt() == 77
  check result["sharedLibraryPositivePath"].getBool() == false
  check result["debuggerUnwindRegistered"].getBool() == true
  check result["patchAddress"].getInt() ==
    result["targetEntryAddress"].getInt() + result["pageSize"].getInt()
  check result["patchProtection"].getStr() == "tpReadExec"
  check result["retainedOldEntryBytesHex"].getStr() == "1f2003d5"
  check result["symbolGeneration"].getInt() == 1

  check result["ipc"]["transport"].getStr() == "stdin-pipe"
  check result["ipc"]["byteCount"].getInt() == packetBytes.len
  check result["ipc"]["digest"].getStr() == byteDigest(packetBytes)
  check result["ipc"]["bytesHex"].getStr() == bytesHex(packetBytes)
  check result["ipc"]["patchTemplateBytesHex"].getStr() ==
    bytesHex(patchTemplateBytes)

  check result.eventNames == @[
    "target-started",
    "before-call",
    "ipc-bytes-read",
    "packet-decoded",
    "patch-transaction-applied",
    "jit-debug-registered",
    "dynamic-unwind-registered",
    "after-call-enter",
    "patch-backtrace-callback",
    "after-call-return"
  ]

  let debug = result["debugRegistration"]
  check debug["success"].getBool() == true
  check debug["descriptorVersion"].getInt() == 1
  check debug["actionFlag"].getInt() == 1
  check debug["relevantEntryAddress"].getInt() == debug["entryAddress"].getInt()
  check debug["firstEntryAddress"].getInt() == debug["entryAddress"].getInt()
  check debug["symfileAddress"].getInt() ==
    debug["retainedDebugObjectAddress"].getInt()
  check debug["symfileSize"].getInt() == debugObjectBytes.len
  check debug["retainedDebugObjectSize"].getInt() == debugObjectBytes.len
  check debug["retainedDebugObjectDigest"].getStr() ==
    byteDigest(debugObjectBytes)
  check debug["registerHookCallCount"].getInt() >= 1

  let unwind = result["unwindRegistration"]
  check unwind["called"].getBool() == true
  check unwind["api"].getStr() in [
    "__unw_add_dynamic_eh_frame_section",
    "__register_frame"
  ]
  check unwind["codeAddress"].getInt() == result["patchAddress"].getInt()
  check unwind["codeSize"].getInt() == result["patchSize"].getInt()
  check unwind["patchedRange"].getInt() == result["patchSize"].getInt()

  check result["backtrace"]["sawPatchFrame"].getBool() == true
  check result["backtrace"]["frameCount"].getInt() > 0
  check result["evidence"]["sharedLibraryPositivePath"].getBool() == false
  check result["evidence"]["trampoline"]["kind"].getStr() ==
    "tkAarch64BranchImm26"
  check result["patchPlan"]["sharedLibraryPositivePath"].getBool() == false

when defined(macosx) and defined(arm64):
  suite "e2e_hcr_direct_patch_debug_unwind_replay":
    test "direct patch registers debugger and unwind metadata and replays IPC bytes":
      let repoRoot = getCurrentDir()
      let targetSource = repoRoot / "tests" / "e2e" / "hcr-debug-unwind" /
        "hcr_m28_target.nim"
      let targetBin = repoRoot / "build" / "test-bin" / "hcr_m28_target"
      createDir(repoRoot / "build" / "test-bin")
      createDir(repoRoot / "build" / "nimcache")
      discard runSuccess(shellCommand([
        "nim", "c", "--threads:on",
        "--nimcache:" & repoRoot / "build" / "nimcache" / "hcr_m28_target",
        "--out:" & targetBin,
        targetSource
      ]), repoRoot)

      let nmOutput = runSuccess(shellCommand(["nm", "-g", targetBin]), repoRoot)
      check nmOutput.contains("__jit_debug_register_code")
      check nmOutput.contains("__jit_debug_descriptor")
      check not fileExists(targetBin & ".dylib")
      check not fileExists(targetBin & ".so")

      let patchTemplateBytes = aarch64CallbackPatchTemplate(77)
      let debugObjectBytes = buildDebugObject(repoRoot)
      let unwindTemplateBytes = minimalAarch64EhFrameTemplate()
      let packet = M28PatchPacket(
        patchTemplateBytes: patchTemplateBytes,
        debugObjectBytes: debugObjectBytes,
        unwindTemplateBytes: unwindTemplateBytes
      )
      let packetBytes = encodeM28PatchPacket(packet)

      let first = runTargetWithPacket(targetBin, packetBytes, repoRoot)
      let replay = runTargetWithPacket(targetBin, packetBytes, repoRoot)
      expectM28Result(first, packetBytes, debugObjectBytes, patchTemplateBytes,
        "recorded run")
      expectM28Result(replay, packetBytes, debugObjectBytes, patchTemplateBytes,
        "replay run")

      check replay["ipc"]["digest"].getStr() == first["ipc"]["digest"].getStr()
      check replay["ipc"]["bytesHex"].getStr() ==
        first["ipc"]["bytesHex"].getStr()
      check replay["before"].getInt() == first["before"].getInt()
      check replay["after"].getInt() == first["after"].getInt()
      check replay.eventNames == first.eventNames
      check replay["debugRegistration"]["retainedDebugObjectDigest"].getStr() ==
        first["debugRegistration"]["retainedDebugObjectDigest"].getStr()
      check replay["unwindRegistration"]["api"].getStr() ==
        first["unwindRegistration"]["api"].getStr()
      check replay["backtrace"]["sawPatchFrame"].getBool() ==
        first["backtrace"]["sawPatchFrame"].getBool()

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.m28.combined-inspection.v1")
      inspection["supportProfile"] =
        newJString("m28-macos-arm64-direct-debug-unwind-replay")
      inspection["packetDigest"] = newJString(byteDigest(packetBytes))
      inspection["recordedRun"] = first
      inspection["replayRun"] = replay
      inspection["sharedLibraryPositivePath"] = newJBool(false)
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_direct_patch_debug_unwind_replay.json",
        pretty(inspection))

when not (defined(macosx) and defined(arm64)):
  suite "e2e_hcr_direct_patch_debug_unwind_replay":
    test "M28 debug/unwind/replay gate is macOS arm64-only":
      skip()

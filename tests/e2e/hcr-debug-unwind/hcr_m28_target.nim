import std/[json]

import repro_hcr_agent
import repro_hcr_linker
import repro_hcr_linkgraph

import m28_packet

when defined(macosx) and defined(arm64):
  proc backtrace(buffer: ptr pointer; size: cint): cint {.
    importc: "backtrace", header: "<execinfo.h>".}

  var activePatchAddress: uint64
  var activePatchSize: uint64
  var capturedBacktrace: seq[uint64]
  var capturedBacktraceSawPatchFrame: bool

  proc addressFromPtr(p: pointer): uint64 =
    uint64(cast[uint](p))

  proc capturePatchBacktrace() {.cdecl, exportc: "repro_hcr_m28_capture_backtrace".} =
    var frames: array[64, pointer]
    let count = int(backtrace(addr frames[0], cint(frames.len)))
    capturedBacktrace = @[]
    capturedBacktraceSawPatchFrame = false
    for i in 0 ..< count:
      let address = addressFromPtr(frames[i])
      capturedBacktrace.add address
      if address >= activePatchAddress and
          address < activePatchAddress + activePatchSize:
        capturedBacktraceSawPatchFrame = true

  proc stdinBytes(): seq[byte] =
    let raw = stdin.readAll()
    result = newSeq[byte](raw.len)
    for i, ch in raw:
      result[i] = byte(ord(ch))

  proc lifecycleJson(events: openArray[string]): JsonNode =
    result = newJArray()
    for index, event in events:
      result.add %*{
        "index": index,
        "event": event
      }

  proc backtraceJson(): JsonNode =
    result = newJObject()
    result["sawPatchFrame"] = newJBool(capturedBacktraceSawPatchFrame)
    result["frameCount"] = newJInt(capturedBacktrace.len)
    result["frames"] = %capturedBacktrace

  proc main() =
    var lifecycle: seq[string] = @["target-started"]
    let functionName = "_hcr_m28_entry"
    let oldBytes = aarch64PatchableReturnBytes(11, sledNops = 4)
    var target = initMinimalAarch64Target(functionName, oldBytes)
    defer: target.close()

    let before = target.callOriginalPointer()
    lifecycle.add "before-call"

    let ipcBytes = stdinBytes()
    lifecycle.add "ipc-bytes-read"
    let packet = parseM28PatchPacket(ipcBytes)
    lifecycle.add "packet-decoded"

    let callbackAddress = addressFromPtr(cast[pointer](capturePatchBacktrace))
    let patchBytes = relocateAarch64CallbackPatch(packet.patchTemplateBytes,
      callbackAddress)
    let plan = directPatchPlanFromBytes(functionName, patchBytes,
      supportProfile = "m28-macos-arm64-direct-debug-unwind-replay",
      snapshotId = "m28-minimal-target")
    let tx = patchTransactionFromPlan(plan, functionName,
      target.targetEntryAddress, nopSledBytes = 16)
    let evidence = applyPatchTransaction(target.targetOps(), tx)
    lifecycle.add "patch-transaction-applied"

    let jitEvidence = registerJitDebugObject(packet.debugObjectBytes,
      target.patchAddress)
    lifecycle.add "jit-debug-registered"

    let unwindEvidence = registerDynamicEhFrame(packet.unwindTemplateBytes,
      target.patchAddress, uint64(patchBytes.len))
    lifecycle.add "dynamic-unwind-registered"

    activePatchAddress = target.patchAddress
    activePatchSize = uint64(patchBytes.len)
    lifecycle.add "after-call-enter"
    let after = target.callOriginalPointer()
    lifecycle.add "patch-backtrace-callback"
    lifecycle.add "after-call-return"

    var root = newJObject()
    root["schemaId"] =
      newJString("reprobuild.hcr.m28.debug-unwind-replay-result.v1")
    root["supportProfile"] =
      newJString("m28-macos-arm64-direct-debug-unwind-replay")
    root["before"] = newJInt(before)
    root["after"] = newJInt(after)
    root["pageSize"] = newJInt(target.pageSize)
    root["targetEntryAddress"] = newJInt(BiggestInt(target.targetEntryAddress))
    root["patchAddress"] = newJInt(BiggestInt(target.patchAddress))
    root["patchSize"] = newJInt(patchBytes.len)
    root["patchAddressShape"] =
      newJString("adjacent-page-after-generated-entry")
    root["targetProtection"] = newJString($target.targetProtection)
    root["patchProtection"] = newJString($target.patchProtection)
    root["retainedOldEntryBytesHex"] =
      newJString(bytesHex(target.retainedOldEntryBytes))
    root["symbolGeneration"] = newJInt(BiggestInt(target.symbolGeneration))
    root["sharedLibraryPositivePath"] = newJBool(false)
    root["debuggerUnwindRegistered"] =
      newJBool(jitEvidence.success and unwindEvidence.called)
    root["lifecycleEvents"] = lifecycleJson(lifecycle)
    root["ipc"] = %*{
      "transport": "stdin-pipe",
      "byteCount": ipcBytes.len,
      "digest": byteDigest(ipcBytes),
      "bytesHex": bytesHex(ipcBytes),
      "patchTemplateBytesHex": bytesHex(packet.patchTemplateBytes),
      "appliedPatchBytesHex": bytesHex(patchBytes),
      "debugObjectDigest": byteDigest(packet.debugObjectBytes),
      "unwindTemplateDigest": byteDigest(packet.unwindTemplateBytes)
    }
    root["debugRegistration"] = jitRegistrationJson(jitEvidence)
    root["unwindRegistration"] = unwindRegistrationJson(unwindEvidence)
    root["backtrace"] = backtraceJson()
    root["patchPlan"] = patchPlanJson(plan)
    root["evidence"] = transactionEvidenceJson(evidence)
    root["remainingOutOfScope"] = %[
      "full DWARF source-line debugger usability",
      "production relocation of compiler-generated .eh_frame FDEs",
      "CodeTracer CTFS or native replayer integration",
      "shared-library patch loading"
    ]
    echo $root

  main()
else:
  echo """{"schemaId":"reprobuild.hcr.m28.debug-unwind-replay-result.v1","unsupported":"macos-arm64-only"}"""

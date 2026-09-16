## Windows x86_64 PE/COFF HCR coordinator.
##
## This is the Windows peer of `hcr_patch_driver.nim`. It derives the complete
## profile-specific bundle from a real target PE/full PDB and a real MSVC COFF
## object, then delivers it through the production named-pipe coordinator. A
## caller may instead provide that identity-bound bundle after preparing it
## off the live-publication path.

import std/[json, options, os, strutils, times]

when defined(windows) and defined(amd64):
  import repro_hcr_agent
  import repro_hcr_linkgraph

  proc die(message: string) {.noreturn.} =
    stderr.writeLine("hcr_patch_driver_windows: " & message)
    quit(1)

  proc usage() {.noreturn.} =
    stderr.writeLine("""usage: hcr_patch_driver_windows --pid PID
    --target-image FILE --target-pdb FILE --target-symbol NAME
    --patch-object FILE --patch-symbol NAME --first-instruction-length N
  or: hcr_patch_driver_windows --pid PID --target-symbol NAME
    --patch-bundle FILE [--patch-symbol NAME]
    [--ready-file FILE --trigger-file FILE]
    [--patch-id ID] [--json-out FILE]""")
    quit(1)

  proc main() =
    var
      pid = 0
      targetImage = ""
      targetPdb = ""
      targetSymbol = ""
      patchObject = ""
      patchSymbol = ""
      patchBundle = ""
      readyFile = ""
      triggerFile = ""
      firstInstructionLength = 0
      patchId = "windows-hcr-patch-1"
      jsonOut = ""
    var index = 1
    while index <= paramCount():
      let argument = paramStr(index)
      proc nextValue(): string =
        inc index
        if index > paramCount():
          die("missing value for " & argument)
        paramStr(index)
      case argument
      of "--pid": pid = parseInt(nextValue())
      of "--target-image": targetImage = nextValue()
      of "--target-pdb": targetPdb = nextValue()
      of "--target-symbol": targetSymbol = nextValue()
      of "--patch-object": patchObject = nextValue()
      of "--patch-symbol": patchSymbol = nextValue()
      of "--patch-bundle": patchBundle = nextValue()
      of "--ready-file": readyFile = nextValue()
      of "--trigger-file": triggerFile = nextValue()
      of "--first-instruction-length":
        firstInstructionLength = parseInt(nextValue())
      of "--patch-id": patchId = nextValue()
      of "--json-out": jsonOut = nextValue()
      of "-h", "--help": usage()
      else: die("unknown argument: " & argument)
      inc index
    if pid <= 0 or targetSymbol.len == 0:
      usage()
    if (readyFile.len == 0) != (triggerFile.len == 0):
      die("--ready-file and --trigger-file must be supplied together")
    let usesPrebuilt = patchBundle.len > 0
    if usesPrebuilt:
      if targetImage.len > 0 or targetPdb.len > 0 or patchObject.len > 0 or
          firstInstructionLength > 0:
        die("--patch-bundle cannot be combined with bundle-construction inputs")
      if not fileExists(patchBundle):
        die("input does not exist: " & patchBundle)
      if patchSymbol.len == 0:
        patchSymbol = "<prebuilt>"
    else:
      if targetImage.len == 0 or targetPdb.len == 0 or patchObject.len == 0 or
          patchSymbol.len == 0 or firstInstructionLength <= 0:
        usage()
      for path in [targetImage, targetPdb, patchObject]:
        if not fileExists(path):
          die("input does not exist: " & path)

    var bundleBytes: seq[byte]
    if usesPrebuilt:
      let encoded = readFile(patchBundle)
      bundleBytes = newSeq[byte](encoded.len)
      if encoded.len > 0:
        copyMem(addr bundleBytes[0], unsafeAddr encoded[0], encoded.len)
      try:
        discard decodeWindowsDirectPatchBundle(bundleBytes)
      except CatchableError as failure:
        die("prebuilt bundle refused: " & failure.msg)
    else:
      let bundle =
        try:
          buildWindowsDirectPatchBundle(
            targetImage, targetPdb, targetSymbol, patchObject, patchSymbol,
            uint32(firstInstructionLength))
        except CatchableError as failure:
          die("bundle construction refused: " & failure.msg)
      bundleBytes = encodeWindowsDirectPatchBundle(bundle)

    var connection = connectHcrAgentWindowsPipe(pid, timeoutMs = 10_000)
    defer: connection.close()
    var client = initHcrCoordinatorClient(
      HcrWindowsX86_64DirectSupportProfile)
    if readyFile.len > 0:
      let parent = parentDir(readyFile)
      if parent.len > 0:
        createDir(parent)
      writeFile(readyFile, "ready\n")
      let deadline = epochTime() + 30.0
      while not fileExists(triggerFile):
        if epochTime() >= deadline:
          die("timed out waiting for trigger file: " & triggerFile)
        sleep(1)
    let request = directPatchRequest(
      patchId,
      HcrWindowsX86_64DirectSupportProfile,
      [targetSymbol],
      [targetSymbol],
      bundleBytes,
      [],
      [],
      [])
    let delivery = client.deliverPatchRequest(connection, request)

    var report = %*{
      "schemaId": "reprobuild.hcr.windows.patch-driver-result.v1",
      "supportProfile": HcrWindowsX86_64DirectSupportProfile,
      "targetSymbol": targetSymbol,
      "patchSymbol": patchSymbol,
      "bundleSource": (if usesPrebuilt: "prebuilt" else: "constructed"),
      "bundleBytesLength": bundleBytes.len,
      "agentCapabilities": delivery.session.agentCapabilities,
      "lifecycleEvents": delivery.session.lifecycleEvents,
      "transcriptFrames": delivery.transcript.len
    }
    var exitCode = 1
    if delivery.patchApplied.isSome:
      let applied = delivery.patchApplied.get()
      report["outcome"] = %"applied"
      # Keep the driver result aligned with the wire protocol. In particular,
      # the CodePatch recorder acknowledgement must survive the coordinator;
      # rebuilding this object field-by-field previously discarded it.
      let appliedJson = agentMessageJson(HcrAgentMessage(
        schemaId: HcrAgentProtocolSchemaId,
        transportScope: HcrAgentTransportScope,
        protocolVersion: HcrAgentProtocolVersion,
        messageId: "windows-patch-driver-applied",
        kind: hmkPatchApplied,
        patchApplied: applied))["patchApplied"]
      report["patchApplied"] = appliedJson
      # Preserve the generic driver's top-level compatibility view as well as
      # the canonical nested protocol shape.
      if applied.codePatchEvent.present:
        report["codePatchEvent"] = appliedJson["codePatchEvent"]
        stderr.writeLine(
          "hcr_patch_driver_windows: codePatchEvent recorded=" &
          $applied.codePatchEvent.recorded & " bridgePresent=" &
          $applied.codePatchEvent.bridgePresent & " bridgeResult=" &
          $applied.codePatchEvent.bridgeResult & " tier=" &
          $applied.codePatchEvent.publicationTier)
      if applied.windowsEvidence.present:
        report["windowsEvidence"] = %*{
          "publicationTier": applied.windowsEvidence.publicationTier,
          "suspendedThreads": applied.windowsEvidence.suspendedThreads,
          "capturedContexts": applied.windowsEvidence.capturedContexts,
          "quiescenceHeldAtStore":
            applied.windowsEvidence.quiescenceHeldAtStore,
          "cacheFlushSucceeded":
            applied.windowsEvidence.cacheFlushSucceeded,
          "firstInstructionLength":
            applied.windowsEvidence.firstInstructionLength
        }
      stderr.writeLine("hcr_patch_driver_windows: APPLIED " & patchId &
        " entry=" & applied.entryAddress &
        " dispatch=" & applied.dispatchAddress)
      exitCode = 0
    elif delivery.patchFailed.isSome:
      let failed = delivery.patchFailed.get()
      report["outcome"] = %"refused"
      report["patchFailed"] = %*{
        "patchId": failed.patchId,
        "stage": failed.stage,
        "message": failed.message
      }
      stderr.writeLine("hcr_patch_driver_windows: REFUSED at stage '" &
        failed.stage & "': " & failed.message)
      exitCode = 2
    else:
      report["outcome"] = %"no-verdict"
      stderr.writeLine("hcr_patch_driver_windows: NO VERDICT")

    let rendered = pretty(report)
    if jsonOut.len > 0:
      let parent = parentDir(jsonOut)
      if parent.len > 0:
        createDir(parent)
      writeFile(jsonOut, rendered)
    echo rendered
    quit(exitCode)

  when isMainModule:
    main()
else:
  when isMainModule:
    stderr.writeLine(
      "hcr_patch_driver_windows: requires Windows x86_64; this host is " &
      hostOS & "/" & hostCPU)
    quit(1)

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
    [--patch-id ID] [--json-out FILE]
  or, to serve MANY patches on one named-pipe connection:
      hcr_patch_driver_windows --pid PID
    --target-image FILE --target-pdb FILE --target-symbol NAME
    --first-instruction-length N --session --session-dir DIR
    [--session-idle-timeout-ms N] [--json-out FILE]""")
    quit(1)

  proc writeJsonAtomically(path: string; node: JsonNode) =
    let parent = parentDir(path)
    if parent.len > 0:
      createDir(parent)
    let temporary = path & ".tmp"
    writeFile(temporary, pretty(node))
    moveFile(temporary, path)

  proc bytesFromFile(path: string): seq[byte] =
    let encoded = readFile(path)
    result = newSeq[byte](encoded.len)
    if encoded.len > 0:
      copyMem(addr result[0], unsafeAddr encoded[0], encoded.len)

  proc buildBundleBytes(targetImage, targetPdb, targetSymbol, patchObject,
                        patchSymbol: string;
                        firstInstructionLength: int): seq[byte] =
    let bundle =
      try:
        buildWindowsDirectPatchBundle(
          targetImage, targetPdb, targetSymbol, patchObject, patchSymbol,
          uint32(firstInstructionLength))
      except CatchableError as failure:
        raise newException(ValueError, failure.msg)
    encodeWindowsDirectPatchBundle(bundle)

  proc appliedJson(applied: HcrPatchApplied): JsonNode =
    agentMessageJson(HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersion,
      messageId: "windows-patch-driver-applied",
      kind: hmkPatchApplied,
      patchApplied: applied))["patchApplied"]

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
      sessionMode = false
      sessionDir = ""
      sessionIdleTimeoutMs = 120_000
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
      of "--session": sessionMode = true
      of "--session-dir": sessionDir = nextValue()
      of "--session-idle-timeout-ms":
        sessionIdleTimeoutMs = parseInt(nextValue())
      of "-h", "--help": usage()
      else: die("unknown argument: " & argument)
      inc index
    if pid <= 0 or targetSymbol.len == 0:
      usage()
    if (readyFile.len == 0) != (triggerFile.len == 0):
      die("--ready-file and --trigger-file must be supplied together")
    if sessionMode:
      if sessionDir.len == 0 or targetImage.len == 0 or targetPdb.len == 0 or
          firstInstructionLength <= 0:
        usage()
      if patchObject.len > 0 or patchBundle.len > 0 or patchSymbol.len > 0:
        die("--session takes patch objects and symbols from --session-dir")
      if readyFile.len > 0:
        die("--ready-file/--trigger-file cannot be combined with --session")
      for path in [targetImage, targetPdb]:
        if not fileExists(path):
          die("input does not exist: " & path)
    let usesPrebuilt = patchBundle.len > 0
    if sessionMode:
      discard
    elif usesPrebuilt:
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
    if sessionMode:
      discard
    elif usesPrebuilt:
      bundleBytes = bytesFromFile(patchBundle)
      try:
        discard decodeWindowsDirectPatchBundle(bundleBytes)
      except CatchableError as failure:
        die("prebuilt bundle refused: " & failure.msg)
    else:
      try:
        bundleBytes = buildBundleBytes(
          targetImage, targetPdb, targetSymbol, patchObject, patchSymbol,
          firstInstructionLength)
      except ValueError as failure:
        die("bundle construction refused: " & failure.msg)

    var connection = connectHcrAgentWindowsPipe(pid, timeoutMs = 10_000)
    defer: connection.close()
    var client = initHcrCoordinatorClient(
      HcrWindowsX86_64DirectSupportProfile)
    if sessionMode:
      createDir(sessionDir)
      client.completeHandshake(connection)
      stderr.writeLine(
        "hcr_patch_driver_windows: session negotiated, capabilities = " &
        client.session.agentCapabilities.join(", "))
      writeJsonAtomically(sessionDir / "ready", %*{
        "schemaId":
          "reprobuild.hcr.windows.patch-driver-session-ready.v1",
        "pid": pid,
        "targetSymbol": targetSymbol,
        "supportProfile": HcrWindowsX86_64DirectSupportProfile,
        "agentCapabilities": client.session.agentCapabilities})

      var
        served = 0
        applied = 0
        refused = 0
        rejected = 0
        results = newJArray()
        stopped = false
        idleSince = epochTime()

      while not stopped:
        if fileExists(sessionDir / "stop"):
          stopped = true
          break
        let requestPath = sessionDir / ("req-" & $(served + 1) & ".json")
        if not fileExists(requestPath):
          if epochTime() - idleSince > float(sessionIdleTimeoutMs) / 1000.0:
            die("no request appeared in " & sessionDir & " within " &
              $sessionIdleTimeoutMs & " ms of the last one (served " &
              $served & ")")
          sleep(20)
          continue

        inc served
        idleSince = epochTime()
        let resultPath = sessionDir / ("res-" & $served & ".json")
        var request: JsonNode
        try:
          request = parseFile(requestPath)
        except CatchableError as failure:
          inc rejected
          writeJsonAtomically(resultPath, %*{
            "index": served,
            "outcome": "rejected",
            "message": "request is not JSON: " & failure.msg})
          continue

        let
          requestObject = request{"patchObject"}.getStr("")
          requestSymbol = request{"patchSymbol"}.getStr("")
          requestPatchId = request{"patchId"}.getStr(
            "windows-hcr-session-" & $served)
        var requestBundle: seq[byte]
        try:
          if requestObject.len == 0 or requestSymbol.len == 0:
            raise newException(ValueError,
              "request must name both patchObject and patchSymbol")
          if not fileExists(requestObject):
            raise newException(ValueError,
              "patch object does not exist: " & requestObject)
          requestBundle = buildBundleBytes(
            targetImage, targetPdb, targetSymbol, requestObject,
            requestSymbol, firstInstructionLength)
        except ValueError as failure:
          inc rejected
          writeJsonAtomically(resultPath, %*{
            "index": served,
            "outcome": "rejected",
            "patchId": requestPatchId,
            "patchObject": requestObject,
            "patchSymbol": requestSymbol,
            "message": failure.msg})
          results.add(%*{
            "index": served, "outcome": "rejected",
            "patchId": requestPatchId})
          continue

        let sentAt = epochTime()
        var delivery: HcrCoordinatorDelivery
        try:
          delivery = client.requestPatchOnOpenSession(
            connection,
            directPatchRequest(
              requestPatchId,
              HcrWindowsX86_64DirectSupportProfile,
              [targetSymbol],
              [targetSymbol],
              requestBundle,
              [],
              [],
              []))
        except CatchableError as failure:
          writeJsonAtomically(resultPath, %*{
            "index": served,
            "outcome": "session-lost",
            "patchId": requestPatchId,
            "message": failure.msg})
          writeJsonAtomically(sessionDir / "session.json", %*{
            "schemaId":
              "reprobuild.hcr.windows.patch-driver-session.v1",
            "outcome": "session-lost",
            "served": served,
            "applied": applied,
            "refused": refused,
            "rejected": rejected,
            "patchesRequested": client.session.patchesRequested,
            "results": results,
            "message": failure.msg})
          die("the named-pipe session was lost while serving request " &
            $served & ": " & failure.msg)

        var res = %*{
          "schemaId":
            "reprobuild.hcr.windows.patch-driver-result.v1",
          "index": served,
          "patchId": requestPatchId,
          "patchObject": requestObject,
          "patchSymbol": requestSymbol,
          "bundleSource": "constructed",
          "bundleBytesLength": requestBundle.len,
          "targetSymbol": targetSymbol,
          "supportProfile": HcrWindowsX86_64DirectSupportProfile,
          "lifecycleEvents": delivery.session.lifecycleEvents,
          "patchesRequestedInSession": client.session.patchesRequested,
          "requestToSettleSeconds": epochTime() - sentAt}
        if delivery.patchApplied.isSome:
          let verdict = delivery.patchApplied.get()
          inc applied
          res["outcome"] = %"applied"
          let verdictJson = appliedJson(verdict)
          res["patchApplied"] = verdictJson
          if verdict.codePatchEvent.present:
            res["codePatchEvent"] = verdictJson["codePatchEvent"]
          stderr.writeLine(
            "hcr_patch_driver_windows: APPLIED " & requestPatchId &
            " entry=" & verdict.entryAddress & " generation=" &
            $verdict.symbolGeneration & " (request " & $served & ")")
        elif delivery.patchFailed.isSome:
          let verdict = delivery.patchFailed.get()
          inc refused
          res["outcome"] = %"refused"
          res["patchFailed"] = %*{
            "patchId": verdict.patchId,
            "stage": verdict.stage,
            "message": verdict.message}
        else:
          res["outcome"] = %"no-verdict"
        writeJsonAtomically(resultPath, res)
        results.add(%*{
          "index": served,
          "outcome": res["outcome"].getStr(),
          "patchId": requestPatchId})

      let summary = %*{
        "schemaId": "reprobuild.hcr.windows.patch-driver-session.v1",
        "outcome": "completed",
        "pid": pid,
        "targetSymbol": targetSymbol,
        "served": served,
        "applied": applied,
        "refused": refused,
        "rejected": rejected,
        "patchesRequested": client.session.patchesRequested,
        "patchIds": client.session.seenPatchIds,
        "results": results}
      writeJsonAtomically(sessionDir / "session.json", summary)
      if jsonOut.len > 0:
        writeJsonAtomically(jsonOut, summary)
      echo pretty(summary)
      quit(0)

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
      let verdictJson = appliedJson(applied)
      report["patchApplied"] = verdictJson
      # Preserve the generic driver's top-level compatibility view as well as
      # the canonical nested protocol shape.
      if applied.codePatchEvent.present:
        report["codePatchEvent"] = verdictJson["codePatchEvent"]
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

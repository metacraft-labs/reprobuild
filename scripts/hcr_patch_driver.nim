## A Linux HCR coordinator you can point at any process that links the agent.
##
## HLX-M0 proved the Linux patch path with an e2e gate; HLX-M1 made real ELF
## symbol resolution work. Neither produced a way to patch a program that is not
## the gate's own fixture. `repro hcr coordinate` exists but hardcodes
## `CodetracerHcrSupportProfile` — the macOS arm64 profile
## (`repro_cli_support.nim:27145`, `:27182`) — so on Linux it negotiates a
## profile no agent will accept. This program is the missing piece: the same
## production `HcrCoordinatorClient` over the same production Unix-socket IPC,
## driven from the command line against an arbitrary target.
##
## It is a MEASUREMENT INSTRUMENT first. Applying a patch and refusing to apply
## one are both real answers, and the refusal is usually the more interesting
## one, so a refusal is reported in full — stage, message, and the named
## diagnostic the agent produced — and is never flattened into "failed".
##
## Usage:
##
##   hcr_patch_driver --socket PATH --target-symbol NAME \
##       --patch-object FILE --patch-symbol NAME \
##       [--patch-id ID] [--delay-ms N] [--json-out FILE] [--allow-relocations]
##
## The driver LISTENS on `--socket`; the target connects out to it because
## `REPRO_HCR_AGENT_SOCKET` names it. So the driver must be started first. It
## exits 0 when the agent reports `patchApplied`, 2 when the agent refuses, and
## 1 on any failure of the driver itself — three outcomes that must not be
## confused, because only the middle one is a measurement.
##
## Two ways to choose WHEN the patch is published, after the target connects.
## The agent's hello is already in the socket buffer either way, so the target
## runs normally throughout: this is what makes a BEFORE and an AFTER observable
## in the same process.
##
##   --delay-ms N            wait N ms. Simple, but it is a GUESS about how far
##                           the target has got, and a wrong guess is not
##                           harmless: measured on this host, `ct-mcr record`
##                           pushes the patched Godot engine's time-to-first-
##                           output from 0.09 s to 16.2 s, so a delay tuned
##                           without the recorder patches before the target has
##                           printed anything and there is no BEFORE at all.
##
##   --wait-for <file>       wait until <file> CONTAINS <marker>, then patch.
##   --marker <string>       This is an OBSERVATION rather than a guess: the
##   --marker-timeout-ms N   before-half is known to exist because it was read.
##                           If the marker never appears within the timeout the
##                           driver DIES WITHOUT PATCHING and exits 1. It must
##                           never fall through to patching anyway, because a
##                           patch published against an unknown target state
##                           produces a result nobody can interpret.

import std/[json, options, os, sequtils, strutils, times]
from std/strformat import nil

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_hcr_linkgraph

  proc die(message: string) {.noreturn.} =
    stderr.writeLine("hcr_patch_driver: " & message)
    quit(1)

  proc usage() {.noreturn.} =
    stderr.writeLine("""usage: hcr_patch_driver --socket PATH --target-symbol NAME
                        --patch-object FILE --patch-symbol NAME
                        [--patch-id ID] [--json-out FILE] [--allow-relocations]
  when to publish (pick one):
                        [--delay-ms N]
                        [--wait-for FILE --marker STRING [--marker-timeout-ms N]]""")
    quit(1)

  proc hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add toHex(b.int, 2).toLowerAscii()

  proc main() =
    var
      socketPath = ""
      targetSymbol = ""
      patchObject = ""
      patchSymbol = ""
      patchId = "hcr-patch-driver-1"
      delayMs = 0
      jsonOut = ""
      allowRelocations = false
      waitForFile = ""
      marker = ""
      markerTimeoutMs = 120_000

    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      proc nextValue(): string =
        inc i
        if i > paramCount():
          die("missing value for " & arg)
        paramStr(i)
      case arg
      of "--socket": socketPath = nextValue()
      of "--target-symbol": targetSymbol = nextValue()
      of "--patch-object": patchObject = nextValue()
      of "--patch-symbol": patchSymbol = nextValue()
      of "--patch-id": patchId = nextValue()
      of "--delay-ms": delayMs = parseInt(nextValue())
      of "--wait-for": waitForFile = nextValue()
      of "--marker": marker = nextValue()
      of "--marker-timeout-ms": markerTimeoutMs = parseInt(nextValue())
      of "--json-out": jsonOut = nextValue()
      of "--allow-relocations": allowRelocations = true
      of "-h", "--help": usage()
      else: die("unknown argument: " & arg)
      inc i

    if socketPath.len == 0 or targetSymbol.len == 0 or
       patchObject.len == 0 or patchSymbol.len == 0:
      usage()
    if (waitForFile.len == 0) != (marker.len == 0):
      die("--wait-for and --marker must be given together")

    # --- 1. extract the patch body from a real relocatable object ------------
    # Read with the HLX-M1 production reader, not a private one, so what the
    # driver sends is what the provider's own pipeline would have produced.
    if not fileExists(patchObject):
      die("patch object does not exist: " & patchObject)
    let graph =
      try:
        parseElfX86_64Object(patchObject)
      except CatchableError as exc:
        die("could not parse " & patchObject & " as an ELF64 relocatable " &
          "object: " & exc.msg)
    # `findSymbol` RAISES on a miss. Caught here so a mistyped symbol reports a
    # sentence instead of an unhandled-exception traceback, which reads like a
    # crash in the driver rather than a mistake in its arguments.
    let symbol =
      try:
        graph.findSymbol(patchSymbol)
      except CatchableError:
        die(patchObject & " defines no symbol named " & patchSymbol &
          " (defined functions: " &
          graph.functionSymbols().mapIt(it.name).join(", ") & ")")
    if symbol.name.len == 0 or not symbol.isDefined:
      die("patch object " & patchObject & " defines no symbol named " &
        patchSymbol)
    let patchBytes = graph.functionBytes(symbol)
    if patchBytes.len == 0:
      # A zero-length body would be sent, accepted, and jumped into. That is a
      # crash, not a patch. Refuse here where the cause is still legible.
      die("symbol " & patchSymbol & " has a zero-length body in " & patchObject)
    let relocations = graph.relocationsForSymbol(symbol)
    if relocations.len > 0 and not allowRelocations:
      var names: seq[string] = @[]
      for r in relocations:
        names.add r.kindName & "->" & r.targetName
      die("patch body " & patchSymbol & " carries " & $relocations.len &
        " relocation(s) and is therefore not position-independent: " &
        names.join(", ") & " (pass --allow-relocations to send it anyway)")

    # --- 2. listen, and let the target connect out ---------------------------
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    stderr.writeLine("hcr_patch_driver: listening on " & socketPath &
      " for target symbol " & targetSymbol & " (" & $patchBytes.len &
      " patch bytes)")
    stderr.writeLine("hcr_patch_driver: patch body hex = " & hexOf(patchBytes))

    var connection = acceptHcrAgentConnection(listener)
    let connectedAt = epochTime()
    stderr.writeLine("hcr_patch_driver: target connected")

    var markerObservedAt = 0.0
    if marker.len > 0:
      # Wait for something the target HAS ALREADY PRINTED. The point is that the
      # before-half of the observation is then known to exist rather than
      # assumed: the marker is read out of the target's own output before a
      # single byte of its text is touched.
      stderr.writeLine("hcr_patch_driver: waiting for marker " &
        marker.escape() & " in " & waitForFile &
        " (timeout " & $markerTimeoutMs & " ms) before patching")
      let deadline = epochTime() + float(markerTimeoutMs) / 1000.0
      var seen = false
      while epochTime() < deadline:
        if fileExists(waitForFile):
          # Read the whole file each poll. These logs are small and this runs a
          # few times a second; a tail-follow would add a second failure mode
          # (a partial line) for no benefit here.
          let content =
            try: readFile(waitForFile)
            except CatchableError: ""
          if content.contains(marker):
            seen = true
            break
        sleep(100)
      if not seen:
        # THE CRITICAL REFUSAL. Falling through to patch anyway would publish
        # against an unknown target state and produce a run whose "before" half
        # was never read -- exactly the vacuous result this flag exists to
        # prevent. A missing marker is a hard failure of the DRIVER (exit 1),
        # and deliberately not a refusal (exit 2), because nothing was ever
        # asked of the agent.
        die("marker " & marker.escape() & " never appeared in " & waitForFile &
          " within " & $markerTimeoutMs & " ms. NOT patching: the target's " &
          "pre-patch state was never observed, so a patch published now " &
          "would produce a result with no before-half to compare against.")
      markerObservedAt = epochTime()
      stderr.writeLine("hcr_patch_driver: marker observed after " &
        formatFloat(markerObservedAt - connectedAt, ffDecimal, 3) &
        " s; the target's pre-patch behaviour is now on the record")

    if delayMs > 0:
      # The agent's hello is already buffered in the socket; the target is free
      # to keep running. This window is the "before" half of the observation.
      stderr.writeLine("hcr_patch_driver: letting the target run for " &
        $delayMs & " ms before patching")
      sleep(delayMs)

    # --- 3. deliver, over the production wire --------------------------------
    var client = initHcrCoordinatorClient(HcrLinuxX86_64DirectSupportProfile)
    let request = directPatchRequest(
      patchId = patchId,
      supportProfile = HcrLinuxX86_64DirectSupportProfile,
      changedFunctions = [targetSymbol],
      targetSymbols = [targetSymbol],
      directPatchBytes = patchBytes,
      debugObjectBytes = [],
      unwindMetadataBytes = [],
      sourceGenerationMap = [])
    let sentAt = epochTime()
    let delivery = client.deliverPatchRequest(connection, request)
    let settledAt = epochTime()
    connection.close()

    # --- 4. report -----------------------------------------------------------
    var report = newJObject()
    report["schemaId"] =
      newJString("reprobuild.hcr.linux.patch-driver-result.v1")
    report["supportProfile"] = newJString(HcrLinuxX86_64DirectSupportProfile)
    report["targetSymbol"] = newJString(targetSymbol)
    report["patchObject"] = newJString(patchObject)
    report["patchSymbol"] = newJString(patchSymbol)
    report["patchBytesHex"] = newJString(hexOf(patchBytes))
    report["patchBytesLength"] = newJInt(patchBytes.len)
    report["agentCapabilities"] = %delivery.session.agentCapabilities
    report["lifecycleEvents"] = %delivery.session.lifecycleEvents
    report["connectToRequestSeconds"] = newJFloat(sentAt - connectedAt)
    report["requestToSettleSeconds"] = newJFloat(settledAt - sentAt)
    if marker.len > 0:
      report["marker"] = newJString(marker)
      report["markerObservedAfterSeconds"] =
        newJFloat(markerObservedAt - connectedAt)

    var exitCode = 1
    if delivery.patchApplied.isSome:
      let applied = delivery.patchApplied.get()
      report["outcome"] = newJString("applied")
      report["patchApplied"] = %*{
        "patchId": applied.patchId,
        "changedFunctions": applied.changedFunctions,
        "entryAddress": applied.entryAddress,
        "dispatchAddress": applied.dispatchAddress,
        "oldCodeRetained": applied.oldCodeRetained,
        "sharedLibraryPositivePath": applied.sharedLibraryPositivePath,
        "symbolGeneration": applied.symbolGeneration
      }
      # HLX-M7 — carry the agent's CodePatchEvent report through verbatim. It is
      # the client's only way to learn whether the recording it is sitting
      # inside got the code-version boundary, and it gives a gate a second,
      # independently transported copy of the digests to check the trace's
      # against.
      if applied.codePatchEvent.present:
        let cpe = applied.codePatchEvent
        report["codePatchEvent"] = %*{
          "recorded": cpe.recorded,
          "bridgePresent": cpe.bridgePresent,
          "bridgeResult": cpe.bridgeResult,
          "hashSelfTest": cpe.hashSelfTest,
          "publicationTier": cpe.publicationTier,
          "codeHashBefore": cpe.codeHashBefore,
          "codeHashAfter": cpe.codeHashAfter,
          "patchBundle": cpe.patchBundle,
          "claimHeld": cpe.claimHeld
        }
        stderr.writeLine("hcr_patch_driver: codePatchEvent recorded=" &
          $cpe.recorded & " bridgePresent=" & $cpe.bridgePresent &
          " bridgeResult=" & $cpe.bridgeResult &
          " tier=" & $cpe.publicationTier &
          " before=" & cpe.codeHashBefore & " after=" & cpe.codeHashAfter)
      if applied.skippedFunctions.len > 0:
        var skipped = newJArray()
        for sf in applied.skippedFunctions:
          skipped.add(%*{"function": sf.function, "reason": sf.reason,
                         "holder": sf.holder,
                         "windowAddress": sf.windowAddress})
        report["skippedFunctions"] = skipped
      stderr.writeLine("hcr_patch_driver: APPLIED " & applied.patchId &
        " entry=" & applied.entryAddress &
        " dispatch=" & applied.dispatchAddress)
      exitCode = 0
    elif delivery.patchFailed.isSome:
      # A refusal is an ANSWER. Carry the agent's own words through verbatim —
      # the named diagnostic in `message` is the whole diagnosis, and
      # summarising it loses which milestone owns the gap.
      let failed = delivery.patchFailed.get()
      report["outcome"] = newJString("refused")
      report["patchFailed"] = %*{
        "patchId": failed.patchId,
        "stage": failed.stage,
        "message": failed.message
      }
      if failed.skippedFunctions.len > 0:
        # §10.1 — a claim conflict is reported, not swallowed. Which function,
        # which reason, which holder.
        var skipped = newJArray()
        for sf in failed.skippedFunctions:
          skipped.add(%*{"function": sf.function, "reason": sf.reason,
                         "holder": sf.holder,
                         "windowAddress": sf.windowAddress})
        report["skippedFunctions"] = skipped
        for sf in failed.skippedFunctions:
          stderr.writeLine("hcr_patch_driver: SKIPPED " & sf.function &
            " reason=" & sf.reason & " holder=" & $sf.holder)
      stderr.writeLine("hcr_patch_driver: REFUSED at stage '" & failed.stage &
        "': " & failed.message)
      exitCode = 2
    else:
      # Neither applied nor failed: the session ended without a verdict. This is
      # a driver/transport failure and must not be reported as either outcome.
      report["outcome"] = newJString("no-verdict")
      stderr.writeLine("hcr_patch_driver: NO VERDICT — the session ended in " &
        "state " & $delivery.session.state & " with neither patchApplied nor " &
        "patchFailed. This is a transport failure, not a refusal.")
      exitCode = 1

    let rendered = pretty(report)
    if jsonOut.len > 0:
      createDir(parentDir(jsonOut))
      writeFile(jsonOut, rendered)
    echo rendered
    quit(exitCode)

  when isMainModule:
    main()

else:
  when isMainModule:
    stderr.writeLine(
      "hcr_patch_driver: the Linux ELF direct-patch provider is " &
      "linux-x86_64-only; this host is " & hostOS & "/" & hostCPU)
    quit(1)

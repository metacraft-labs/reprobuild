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
##
## SESSION MODE — `--session --session-dir DIR`
##
## The one-shot form above publishes one patch and closes the connection, and
## because the in-target agent dials OUT exactly once at process start
## (`repro_hcr_agent.c`, a bounded 500 x 10 ms retry and no later attempt),
## closing it is final: nothing can be patched into that process again, ever.
## A live-edit loop — type a value, watch the flame reshape, type another —
## is therefore not N runs of the one-shot form. It is one session serving N
## patches, which is what the agent's own frame loop (GDH-M4) and the Linux
## provider's per-site re-patch bookkeeping (design §4.5) were built for.
##
## The session is driven through a DIRECTORY rather than this process's stdin,
## so the thing asking for edits does not have to be this process's parent and
## every request and every verdict is an artifact on disk afterwards:
##
##   DIR/ready            written by the driver once the target has connected
##                        and the handshake is done. Its presence is the only
##                        correct signal that an edit can be published; a
##                        client that starts writing requests before it is
##                        racing the target's dial-out.
##   DIR/req-<n>.json     request n, n counting from 1, written by the client
##                        as `req-<n>.json.tmp` and RENAMED into place so the
##                        driver can never read a half-written request.
##                        Fields: patchObject, patchSymbol, patchId.
##   DIR/res-<n>.json     the verdict for request n, written the same way.
##   DIR/stop             ends the session cleanly.
##   DIR/session.json     the whole session's summary, written at the end.
##
## EXIT CODE, and how it differs from the one-shot form on purpose: session
## mode exits 0 when the SESSION ran and ended cleanly, and 1 when the driver
## itself failed. A patch the agent REFUSED is not a failed session — it is a
## verdict, recorded in `res-<n>.json` as `outcome: "refused"` with the agent's
## stage and message — and the caller reads it there. Collapsing a refusal in
## the middle of a ten-edit session into the exit status of the whole session
## would throw away which edit was refused.

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
                        [--wait-for FILE --marker STRING [--marker-timeout-ms N]]
  or, to serve MANY patches on one connection (the live-edit loop):
       hcr_patch_driver --socket PATH --target-symbol NAME
                        --session --session-dir DIR
                        [--session-idle-timeout-ms N] [--json-out FILE]
                        [--wait-for FILE --marker STRING]""")
    quit(1)

  proc hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add toHex(b.int, 2).toLowerAscii()

  type PatchLoadError = object of CatchableError

  proc loadPatchBytes(patchObject, patchSymbol: string;
                      allowRelocations: bool): seq[byte] =
    ## Read a patch body out of a real relocatable object with the HLX-M1
    ## production reader, refusing everything the one-shot path refuses and by
    ## the same sentences.
    ##
    ## It RAISES rather than `quit`s, because in session mode a bad request is
    ## one bad request: the session has a live connection to a process nobody
    ## else can reach any more, and killing it because edit 4 of 10 named a
    ## missing file would destroy the other six. The one-shot caller turns the
    ## same exception straight back into `die`, so its behaviour is unchanged.
    if not fileExists(patchObject):
      raise newException(PatchLoadError,
        "patch object does not exist: " & patchObject)
    let graph =
      try:
        parseElfX86_64Object(patchObject)
      except CatchableError as exc:
        raise newException(PatchLoadError,
          "could not parse " & patchObject & " as an ELF64 relocatable " &
            "object: " & exc.msg)
    let symbol =
      try:
        graph.findSymbol(patchSymbol)
      except CatchableError:
        raise newException(PatchLoadError,
          patchObject & " defines no symbol named " & patchSymbol &
            " (defined functions: " &
            graph.functionSymbols().mapIt(it.name).join(", ") & ")")
    if symbol.name.len == 0 or not symbol.isDefined:
      raise newException(PatchLoadError,
        "patch object " & patchObject & " defines no symbol named " &
          patchSymbol)
    let patchBytes = graph.functionBytes(symbol)
    if patchBytes.len == 0:
      # A zero-length body would be sent, accepted, and jumped into. That is a
      # crash, not a patch. Refuse here where the cause is still legible.
      raise newException(PatchLoadError,
        "symbol " & patchSymbol & " has a zero-length body in " & patchObject)
    let relocations = graph.relocationsForSymbol(symbol)
    if relocations.len > 0 and not allowRelocations:
      var names: seq[string] = @[]
      for r in relocations:
        names.add r.kindName & "->" & r.targetName
      raise newException(PatchLoadError,
        "patch body " & patchSymbol & " carries " & $relocations.len &
          " relocation(s) and is therefore not position-independent: " &
          names.join(", ") & " (pass --allow-relocations to send it anyway)")
    patchBytes

  proc writeJsonAtomically(path: string; node: JsonNode) =
    ## Write, then RENAME. A reader polling for this file must never be able to
    ## observe it half-written; `rename(2)` within one directory is atomic and
    ## a plain write is not. The same discipline is required of the client
    ## writing requests, and for the same reason.
    createDir(parentDir(path))
    let tmp = path & ".tmp"
    writeFile(tmp, pretty(node))
    moveFile(tmp, path)

  proc appliedJson(applied: HcrPatchApplied): JsonNode =
    result = %*{
      "patchId": applied.patchId,
      "changedFunctions": applied.changedFunctions,
      "entryAddress": applied.entryAddress,
      "dispatchAddress": applied.dispatchAddress,
      "oldCodeRetained": applied.oldCodeRetained,
      "sharedLibraryPositivePath": applied.sharedLibraryPositivePath,
      "symbolGeneration": applied.symbolGeneration
    }

  proc codePatchEventJson(applied: HcrPatchApplied): JsonNode =
    if not applied.codePatchEvent.present:
      return nil
    let cpe = applied.codePatchEvent
    %*{
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

  proc skippedJson(skipped: seq[HcrSkippedFunction]): JsonNode =
    result = newJArray()
    for sf in skipped:
      result.add(%*{"function": sf.function, "reason": sf.reason,
                    "holder": sf.holder, "windowAddress": sf.windowAddress})

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
      sessionMode = false
      sessionDir = ""
      sessionIdleTimeoutMs = 120_000

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
      of "--session": sessionMode = true
      of "--session-dir": sessionDir = nextValue()
      of "--session-idle-timeout-ms": sessionIdleTimeoutMs = parseInt(nextValue())
      of "-h", "--help": usage()
      else: die("unknown argument: " & arg)
      inc i

    if sessionMode:
      if socketPath.len == 0 or targetSymbol.len == 0 or sessionDir.len == 0:
        usage()
      if patchObject.len > 0 or patchSymbol.len > 0:
        # Taking one here would make it ambiguous whether the first edit of the
        # session was the one the client asked for or the one on the command
        # line, and the flame cannot tell you which it ran.
        die("--session takes its patches from --session-dir; " &
          "--patch-object/--patch-symbol are per-request fields there")
    else:
      if socketPath.len == 0 or targetSymbol.len == 0 or
         patchObject.len == 0 or patchSymbol.len == 0:
        usage()
    if (waitForFile.len == 0) != (marker.len == 0):
      die("--wait-for and --marker must be given together")

    # --- 1. extract the patch body from a real relocatable object ------------
    # Read with the HLX-M1 production reader, not a private one, so what the
    # driver sends is what the provider's own pipeline would have produced.
    # In session mode each request names its own object, so this is deferred.
    var patchBytes: seq[byte] = @[]
    if not sessionMode:
      patchBytes =
        try:
          loadPatchBytes(patchObject, patchSymbol, allowRelocations)
        except PatchLoadError as exc:
          die(exc.msg)

    # --- 2. listen, and let the target connect out ---------------------------
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    if sessionMode:
      stderr.writeLine("hcr_patch_driver: listening on " & socketPath &
        " for target symbol " & targetSymbol &
        " (SESSION mode, requests from " & sessionDir & ")")
    else:
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

    # --- 3a. SESSION mode: serve edits until told to stop ---------------------
    if sessionMode:
      createDir(sessionDir)
      var client = initHcrCoordinatorClient(HcrLinuxX86_64DirectSupportProfile)
      client.completeHandshake(connection)
      stderr.writeLine("hcr_patch_driver: session negotiated, capabilities = " &
        client.session.agentCapabilities.join(", "))

      # `ready` is written AFTER the handshake, not after the accept. A client
      # that published on the strength of a connected socket would be sending
      # a patch request into a session that had not negotiated, which the
      # session state machine refuses — a self-inflicted failure that reads
      # like the agent declining the edit.
      writeJsonAtomically(sessionDir / "ready", %*{
        "schemaId": "reprobuild.hcr.linux.patch-driver-session-ready.v1",
        "socket": socketPath,
        "targetSymbol": targetSymbol,
        "supportProfile": HcrLinuxX86_64DirectSupportProfile,
        "agentCapabilities": client.session.agentCapabilities,
        "connectedAfterSeconds": epochTime() - connectedAt})

      var
        served = 0
        applied = 0
        refused = 0
        rejected = 0
        results = newJArray()
        stopped = false
        idleSince = epochTime()

      while not stopped:
        let stopPath = sessionDir / "stop"
        if fileExists(stopPath):
          stderr.writeLine("hcr_patch_driver: stop requested after " &
            $served & " request(s)")
          stopped = true
          break
        let reqPath = sessionDir / ("req-" & $(served + 1) & ".json")
        if not fileExists(reqPath):
          if epochTime() - idleSince > float(sessionIdleTimeoutMs) / 1000.0:
            # A named death, not a hang. Per trap 1 a driver that sat here
            # until an outer `timeout` killed it would report rc 124, which
            # means "hung" and would be indistinguishable from the agent
            # having stopped answering — a different and much more interesting
            # failure. Say which one this is.
            die("no request appeared in " & sessionDir & " within " &
              $sessionIdleTimeoutMs & " ms of the last one (served " &
              $served & "). The session held an open connection to the " &
              "target the whole time; this is the CLIENT not asking for " &
              "anything, not the agent failing to answer.")
          sleep(20)
          continue

        inc served
        idleSince = epochTime()
        let resPath = sessionDir / ("res-" & $served & ".json")
        var request: JsonNode
        try:
          request = parseFile(reqPath)
        except CatchableError as exc:
          rejected.inc
          writeJsonAtomically(resPath, %*{
            "index": served, "outcome": "rejected",
            "message": "request " & reqPath & " is not JSON: " & exc.msg})
          continue

        let
          reqObject = request{"patchObject"}.getStr("")
          reqSymbol = request{"patchSymbol"}.getStr("")
          reqPatchId = request{"patchId"}.getStr(
            "hcr-patch-driver-session-" & $served)

        # A request this driver cannot even read is REJECTED, a third outcome
        # beside applied and refused. Folding it into "refused" would credit
        # the agent with declining an edit it was never shown.
        var bytes: seq[byte]
        try:
          if reqObject.len == 0 or reqSymbol.len == 0:
            raise newException(PatchLoadError,
              "request must name both patchObject and patchSymbol")
          bytes = loadPatchBytes(reqObject, reqSymbol, allowRelocations)
        except PatchLoadError as exc:
          rejected.inc
          stderr.writeLine("hcr_patch_driver: REJECTED request " & $served &
            ": " & exc.msg)
          writeJsonAtomically(resPath, %*{
            "index": served, "outcome": "rejected", "patchId": reqPatchId,
            "patchObject": reqObject, "patchSymbol": reqSymbol,
            "message": exc.msg})
          results.add(%*{"index": served, "outcome": "rejected",
                         "patchId": reqPatchId})
          continue

        let sentAt = epochTime()
        var delivery: HcrCoordinatorDelivery
        try:
          delivery = client.requestPatchOnOpenSession(connection,
            directPatchRequest(
              patchId = reqPatchId,
              supportProfile = HcrLinuxX86_64DirectSupportProfile,
              changedFunctions = [targetSymbol],
              targetSymbols = [targetSymbol],
              directPatchBytes = bytes,
              debugObjectBytes = [],
              unwindMetadataBytes = [],
              sourceGenerationMap = []))
        except CatchableError as exc:
          # The connection died mid-session. This is fatal for the session and
          # must be said in those words: there is no second dial-out, so no
          # later request can be served either.
          writeJsonAtomically(resPath, %*{
            "index": served, "outcome": "session-lost", "patchId": reqPatchId,
            "message": exc.msg})
          writeJsonAtomically(sessionDir / "session.json", %*{
            "schemaId": "reprobuild.hcr.linux.patch-driver-session.v1",
            "outcome": "session-lost", "served": served, "applied": applied,
            "refused": refused, "rejected": rejected,
            "patchesRequested": client.session.patchesRequested,
            "results": results,
            "message": exc.msg})
          die("the session was lost while serving request " & $served & ": " &
            exc.msg & ". The target dials out once at start, so this " &
            "connection cannot be re-established.")
        let settledAt = epochTime()

        var res = %*{
          "schemaId": "reprobuild.hcr.linux.patch-driver-result.v1",
          "index": served,
          "patchId": reqPatchId,
          "patchObject": reqObject,
          "patchSymbol": reqSymbol,
          "patchBytesHex": hexOf(bytes),
          "patchBytesLength": bytes.len,
          "targetSymbol": targetSymbol,
          "supportProfile": HcrLinuxX86_64DirectSupportProfile,
          "lifecycleEvents": delivery.session.lifecycleEvents,
          "patchesRequestedInSession": client.session.patchesRequested,
          "requestToSettleSeconds": settledAt - sentAt}
        if delivery.patchApplied.isSome:
          let a = delivery.patchApplied.get()
          applied.inc
          res["outcome"] = newJString("applied")
          res["patchApplied"] = appliedJson(a)
          let cpe = codePatchEventJson(a)
          if cpe != nil:
            res["codePatchEvent"] = cpe
          if a.skippedFunctions.len > 0:
            res["skippedFunctions"] = skippedJson(a.skippedFunctions)
          stderr.writeLine("hcr_patch_driver: APPLIED " & a.patchId &
            " entry=" & a.entryAddress & " generation=" &
            $a.symbolGeneration & " (request " & $served & " of this session)")
        elif delivery.patchFailed.isSome:
          let f = delivery.patchFailed.get()
          refused.inc
          res["outcome"] = newJString("refused")
          res["patchFailed"] = %*{"patchId": f.patchId, "stage": f.stage,
                                  "message": f.message}
          if f.skippedFunctions.len > 0:
            res["skippedFunctions"] = skippedJson(f.skippedFunctions)
          stderr.writeLine("hcr_patch_driver: REFUSED request " & $served &
            " at stage '" & f.stage & "': " & f.message)
        else:
          res["outcome"] = newJString("no-verdict")
          stderr.writeLine("hcr_patch_driver: NO VERDICT for request " &
            $served & " — session state " & $delivery.session.state)
        writeJsonAtomically(resPath, res)
        results.add(%*{"index": served,
                       "outcome": res["outcome"].getStr(),
                       "patchId": reqPatchId})

      connection.close()
      let summary = %*{
        "schemaId": "reprobuild.hcr.linux.patch-driver-session.v1",
        "outcome": "completed",
        "socket": socketPath,
        "targetSymbol": targetSymbol,
        "served": served,
        "applied": applied,
        "refused": refused,
        "rejected": rejected,
        # The SESSION's own count, read off the protocol state machine rather
        # than off this loop's counter. Two independent witnesses to "more than
        # one patch was published on one connection": a loop variable is the
        # harness counting itself.
        "patchesRequested": client.session.patchesRequested,
        "patchIds": client.session.seenPatchIds,
        "results": results}
      writeJsonAtomically(sessionDir / "session.json", summary)
      if jsonOut.len > 0:
        writeJsonAtomically(jsonOut, summary)
      echo pretty(summary)
      quit(0)

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

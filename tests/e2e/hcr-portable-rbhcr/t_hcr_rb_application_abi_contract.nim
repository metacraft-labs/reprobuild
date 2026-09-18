## HLX-M8 verification gate `hcr_rb_application_abi_contract` — the
## PLATFORM-NEUTRAL half of the `rb_hcr_*` application ABI and of the reload
## lifecycle behind it.
##
## Design: `reprobuild-specs/HCR/HCR-Overview.md` §7.4, §13.1-§13.4, §13.6;
## `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1, §3.2, §3.3 step 38,
## §3.4 step 43.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
## Cross-repo contract: `isonim/tests/helpers/hcr_stub.nim`.
##
## `allowed_mocks: none`. The production agent translation unit
## `libs/repro_hcr_agent/c/repro_hcr_agent.c` is compiled into this binary by
## `repro_hcr_agent/application_abi`; the wire arms spawn THIS binary as a real
## target process and drive it over the real agent socket with the production
## `HcrCoordinatorClient`. There is no stub agent and no second implementation.
##
## ---------------------------------------------------------------------------
## WHY A SECOND GATE, WHEN FOUR HLX-M8 GATES ALREADY EXIST
##
## The four are `tests/e2e/hcr-linux-rbhcr/t_*`, and each opens with
## `when defined(linux) and defined(amd64)`. Their vehicle is Linux by
## necessity — a target built with `-fpatchable-function-entry=16,0`, patch
## bytes cut out of an ELF relocatable object, assertions on `endbr64` and on an
## `E9 rel32` landing in one naturally aligned 8-byte window. What they ASSERT,
## though, is largely not Linux at all:
##
##   * §3.1's phase order (E before-reload -> F load -> G trampolines ->
##     H after-reload);
##   * §7.4's acceptance rule — accept iff every layout-changed type is managed,
##     otherwise `IncompatibleChange` naming the unmanaged ones;
##   * §3.3 step 38 — a load failure AFTER before-reload has fired still owes
##     the application an after-reload with zero `changed_types`;
##   * `rb_hcr_file_changed` answering over the most recent APPLIED reload;
##   * §13.2/§13.3's registration semantics.
##
## The implementation already agrees that these are platform-neutral:
## `rb_hcr_run_lifecycle` (`repro_hcr_agent.c:3996`) and all ten `rb_hcr_*`
## functions carry no platform guard. This gate re-expresses those assertions in
## a vehicle that has no platform in it either, so the macOS arm inherits them.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE. Per case, "what world would this fail in".
##
## 1. REGISTRY (`the §13.2/§13.3 registries`). Every assertion is a comparison
##    against a value that CHANGES within the case: counts go 0 -> 1 -> 2 -> 1,
##    stored pointers are compared by identity against the exact pointers passed
##    in, and the managed-type registry's answer is read before and after the
##    caller MUTATES the buffer it registered. An implementation that copied the
##    string, that de-duplicated on the callback alone, that removed on the
##    callback alone, or that grew past its capacity is red on a named line.
##
## 2. WIRE ARMS. Every one of them has a sibling arm with the OPPOSITE outcome
##    driven through the same binary and the same socket, differing by one
##    input: `--managed=` present or absent, synchronized mode on or off, a
##    zero-length body or a symbol that does not exist. "No callback fired" is
##    never asserted by an instrument that has not just been seen to say
##    "three callbacks fired".
##
## 3. PHASE ORDER. The target does not count callbacks; it LOGS them in
##    dispatch order into one array that spans both phases, and reads
##    `rb_hcr_file_changed` inside each one. On the step-38 arm that predicate
##    answers TRUE inside the before-callback and FALSE after the load failed —
##    a single predicate observed flipping inside one run, which no "always
##    false" implementation can produce.
##
## ---------------------------------------------------------------------------
## WHAT IS NOT HERE, AND WHY — stated so nobody reads this gate as covering it.
##
##   * NO ARM APPLIES A PATCH. Every wire arm stops in prepare or at Phase F.
##    That is deliberate and it is a safety property, not an omission: applying
##    a patch needs machine code for the host's architecture, and there is no
##    portable way to write x86_64 and arm64 bodies here. A gate that sent
##    plausible-looking bytes to the Apple arm's `repro_hcr_apply_direct_patch`
##    would install a branch to a page of garbage and crash the target. So the
##    "before-callback sees the OLD body, after-callback sees the NEW one"
##    observation — the sharpest thing the Linux gates measure — stays there.
##
##   * THE PHASE F / PHASE G BOUNDARY IS NOT ASSERTED. It is real only on Linux
##    (`repro_hcr_linux_x86_64.h:2438`/`:2456`); off it,
##    `repro_hcr_commit_direct_patch` (`repro_hcr_agent.c:2093`) checks
##    `txn->prepared` and calls the old monolithic
##    `repro_hcr_apply_direct_patch`, so there is no point at which the link has
##    completed and target text is untouched. The step-38 arm below therefore
##    asserts the OBLIGATION (before fired, so after must fire, with zero
##    `changed_types`, with nothing swapped and the window rolled back) and NOT
##    that a genuine in-memory-link refusal is distinguishable from a commit
##    refusal. `tests/e2e/hcr-linux-rbhcr/t_integration_hcr_linux_late_load_
##    failure_still_reaches_after_reload.nim` keeps that, with a real oversized
##    compiler-emitted body.
##
##   * macOS IS UNVERIFIED. This gate is portable BY CONSTRUCTION — no platform
##    conditional in the body or the helper except one `not defined(windows)`,
##    no ELF or Mach-O call, no architecture-specific byte — but as of
##    2026-09-18 it has been RUN on exactly one host, Linux x86_64. "Can run
##    there" is not "ran there", and nothing here should be read as a macOS
##    result. Two risks are open and neither is resolvable without a macOS host:
##    on macOS x86_64 both `defaultDirectSupportProfile()` and
##    `repro_hcr_agent_default_support_profile()` return `""` (neither
##    `REPRO_HCR_TARGET_APPLE_ARM64` nor `_LINUX_X86_64` is defined there), and
##    while the LIVE negotiation is a plain string equality that `""` satisfies
##    (`session.nim:110`, `:152`), that has not been exercised; and on macOS
##    arm64 `repro_hcr_find_symbol` falls back to `dlsym` (`repro_hcr_agent.c:
##    511`), so the `AbsentSymbol` arms additionally depend on `dlsym` failing —
##    which it should, the symbol being defined nowhere in the process, but that
##    is argued rather than measured.
##
##   * WINDOWS RUNS NOTHING, AND SAYS SO LOUDLY. `repro_hcr_agent.c` cannot
##    compile for Windows and `repro_hcr_agent_windows.c` defines no `rb_hcr_*`
##    symbol at all, so the ABI does not exist on that host. This gate FAILS
##    there with the remedy in the message. It does not `skip()`: a skip that
##    exits 0 is the defect `codetracer-specs/Testing/
##    Silent-Self-Pass-Audit-2026-08-23.md` exists to inventory.

import std/[json, options, os, strutils, unittest]

import repro_hcr_agent/application_abi

when ReproHcrApplicationAbiAvailable:
  import std/[osproc, streams, strtabs, times]

  # Deliberately the four submodules and NOT the `repro_hcr_agent` umbrella:
  # the umbrella re-exports `dispatch_table`, which `{.compile:}`s
  # `repro_hcr_dispatch_table.c` — and `repro_hcr_agent.c:89` already
  # `#include`s that same file, so importing both puts every dispatch-table
  # symbol in the link twice.
  import repro_hcr_agent/[coordinator, ipc, protocol, session]

  const
    TargetFlag = "--rb-abi-target"
    TargetSchemaId = "reprobuild.hcr.hlx-m8.portable-rb-hcr-target-result.v1"
    VictimSymbol = "hcr_rb_portable_victim"
    AbsentSymbol = "hcr_rb_portable_symbol_that_does_not_exist"
    ProbeChangedFile = "hcr_rb_portable_views.nim"
    ProbeAbsentFile = "hcr_rb_portable_never_in_any_patch.nim"
    ProbeManagedType = "HcrRbPortableState"
    PollBudget = 20_000
    PollSeconds = 30.0

  let EmptyBody: seq[byte] = @[]
    ## Zero-length on purpose; see the step-38 case for why that is a real
    ## Phase F refusal on every host rather than a lever.

  # =====================================================================
  # TARGET MODE. Everything from here to `runTarget` runs in the CHILD.
  #
  # This binary is its own target process. That is what makes the wire arms
  # portable: there is no per-platform C target to build and no compiler flags
  # to get right, and the application-side surface is exactly the ten `rb_hcr_*`
  # functions an embedding program has.
  # =====================================================================

  proc hcrRbPortableVictim(): cint {.cdecl.} = 11

  var
    dispatchLog: JsonNode = newJArray()
    targetScenario = ""
    managedTypeStorage: seq[string] = @[]

  proc recordDispatch(phase, tag: string; info: ptr RbHcrReloadInfo;
                      userData: pointer) =
    ## Called from inside a real dispatch. Records WHAT the application saw,
    ## never what the agent claims, and reads the §13.4 introspection
    ## predicates here because §13.6's own usage example calls them from inside
    ## a before-reload callback.
    var entry = newJObject()
    entry["phase"] = %phase
    entry["tag"] = %tag
    entry["userData"] = %("0x" & toHex(cast[uint](userData), 4).toLowerAscii())
    entry["infoIsNil"] = %(info == nil)
    if info != nil:
      entry["changedFilesCount"] = %int(info.changed_files_count)
      entry["changedTypesCount"] = %int(info.changed_types_count)
      if info.changed_files_count > 0'u32 and info.changed_files != nil:
        entry["firstFile"] = %($info.changed_files[0])
      else:
        entry["firstFile"] = %""
      if info.changed_types_count > 0'u32 and info.changed_types != nil:
        entry["firstType"] = %($info.changed_types[0].type_name)
        entry["firstTypeOldSize"] = %int(info.changed_types[0].old_size)
        entry["firstTypeNewSize"] = %int(info.changed_types[0].new_size)
      else:
        entry["firstType"] = %""
        entry["firstTypeOldSize"] = %0
        entry["firstTypeNewSize"] = %0
    entry["fileChangedProbe"] = %rbHcrFileChanged(ProbeChangedFile)
    entry["fileChangedAbsent"] = %rbHcrFileChanged(ProbeAbsentFile)
    entry["typeChangedProbe"] = %rbHcrTypeChanged(ProbeManagedType)
    entry["victim"] = %int(hcrRbPortableVictim())
    dispatchLog.add entry

  proc cbBefore1(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    recordDispatch("before", "B1", info, ud)

  proc cbBefore2(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    recordDispatch("before", "B2", info, ud)

  proc cbAfter1(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    recordDispatch("after", "A1", info, ud)

  proc cbAfter2(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    recordDispatch("after", "A2", info, ud)

  proc cbSnapshotLate(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    recordDispatch("before", "LATE", info, ud)

  proc cbSnapshotDoomed(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    recordDispatch("before", "DOOMED", info, ud)

  proc cbSnapshotMutator(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    ## §13.3's dispatch-over-a-snapshot rule, exercised from the only place it
    ## is observable: a callback that edits the registry MID-DISPATCH. `LATE`
    ## is registered now and must NOT fire in this dispatch; `DOOMED` is removed
    ## now and MUST still fire, because it was in the snapshot when the
    ## dispatch began.
    recordDispatch("before", "MUTATOR", info, ud)
    rbHcrBeforeReload(cbSnapshotLate, cast[pointer](0x7A00))
    rbHcrRemoveBeforeReload(cbSnapshotDoomed, cast[pointer](0x7B00))

  proc registerStandardCallbacks() =
    ## The registration shape every wire arm uses. Five `rb_hcr_before_reload`
    ## calls and four removals produce exactly three dispatches, and which
    ## three is the whole of §13.3's contract:
    ##
    ##   B1@0x8100 registered TWICE       -> one entry   (idempotent on the pair)
    ##   B2@0x8200                        -> one entry   (a different callback)
    ##   B1@0x8300 registered then removed-> no entry    (removal works)
    ##   B1@0x8400 "removed" with 0x9999  -> ONE ENTRY   (removal must match
    ##                                                    BOTH fields)
    ##
    ## The last line is the one no shipped gate asserted. An implementation
    ## that matched removal on the callback alone would silently drop a live
    ## registration belonging to someone else's `user_data`.
    rbHcrBeforeReload(cbBefore1, cast[pointer](0x8100))
    rbHcrBeforeReload(cbBefore1, cast[pointer](0x8100))
    rbHcrBeforeReload(cbBefore2, cast[pointer](0x8200))
    rbHcrBeforeReload(cbBefore1, cast[pointer](0x8300))
    rbHcrRemoveBeforeReload(cbBefore1, cast[pointer](0x8300))
    rbHcrBeforeReload(cbBefore1, cast[pointer](0x8400))
    rbHcrRemoveBeforeReload(cbBefore1, cast[pointer](0x9999))

    rbHcrAfterReload(cbAfter1, cast[pointer](0x8500))
    rbHcrAfterReload(cbAfter1, cast[pointer](0x8500))
    rbHcrAfterReload(cbAfter2, cast[pointer](0x8600))
    rbHcrAfterReload(cbAfter2, cast[pointer](0x8700))
    rbHcrRemoveAfterReload(cbAfter2, cast[pointer](0x8700))

  proc registerSnapshotCallbacks() =
    rbHcrBeforeReload(cbSnapshotMutator, cast[pointer](0x7900))
    rbHcrBeforeReload(cbSnapshotDoomed, cast[pointer](0x7B00))
    rbHcrAfterReload(cbAfter1, cast[pointer](0x8500))

  proc runTarget(params: seq[string]) =
    ## One reload attempt, driven the way an application's frame loop drives
    ## one, then a JSON report of what the APPLICATION observed.
    ##
    ## No skips and no silent early returns: a target that never sees a request
    ## exits 3 with a named reason on stderr rather than printing a report with
    ## zero dispatches, which would read as "the gate ran and nothing fired".
    var
      symbols: array[1, ReproHcrAgentSymbol]
      synchronized = true
    for param in params:
      if param.startsWith("--managed="):
        managedTypeStorage.add param[10 .. ^1]
      elif param == "--automatic":
        synchronized = false
      elif param.startsWith("--scenario="):
        targetScenario = param[11 .. ^1]

    # §13.2 stores the caller's POINTER and does not copy, so registration
    # happens only once `managedTypeStorage` has stopped growing — a `seq` that
    # is still being appended to may move its elements, and the registry would
    # then hold a dangling pointer. An embedding application has exactly this
    # obligation; doing it correctly here is part of what the ABI means.
    for name in managedTypeStorage.mitems:
      rbHcrRegisterManagedType(cast[cstring](addr name[0]))

    reproHcrAgentSetSynchronizedMode(if synchronized: 1 else: 0)

    case targetScenario
    of "snapshot": registerSnapshotCallbacks()
    else: registerStandardCallbacks()

    let beforeCountAtStart = int(reproHcrRbBeforeCallbackCount())
    let afterCountAtStart = int(reproHcrRbAfterCallbackCount())

    symbols[0].name = VictimSymbol
    symbols[0].address = cast[pointer](hcrRbPortableVictim)
    let startRc = reproHcrAgentStartPollingFromEnv(
      reproHcrAgentDefaultSupportProfile(), addr symbols[0], csize_t(1))

    var
      polls = 0
      wantsBefore = false
      wantsAfter = true
      timedOut = true
    let deadline = epochTime() + PollSeconds
    while polls < PollBudget and epochTime() < deadline:
      discard reproHcrAgentPollNonblocking()
      if rbHcrWantsReload():
        wantsBefore = true
        rbHcrApplyReload()
        wantsAfter = rbHcrWantsReload()
        timedOut = false
        break
      if ($reproHcrRbLifecycleTrace()).len > 0:
        # Automatic mode: the agent ran the whole lifecycle inside the poll.
        timedOut = false
        break
      polls.inc
      sleep(1)

    if timedOut:
      stderr.writeLine "hcr_rb_portable_target: no patch became pending " &
        "within " & $polls & " polls / " & $PollSeconds & "s; the agent never " &
        "parked or ran a request"
      quit(3)

    var report = newJObject()
    report["schemaId"] = %TargetSchemaId
    report["scenario"] = %targetScenario
    report["startRc"] = %int(startRc)
    report["supportProfile"] = %($reproHcrAgentDefaultSupportProfile())
    report["synchronizedMode"] = %(reproHcrAgentSynchronizedMode() != 0)
    report["wantsReloadBeforeApply"] = %wantsBefore
    report["wantsReloadAfterApply"] = %wantsAfter
    report["applyReloadCalls"] = %int(reproHcrRbApplyReloadCalls())
    report["lifecycleTrace"] = %($reproHcrRbLifecycleTrace())
    report["agentBeforeFired"] = %int(reproHcrRbLastBeforeCallbacksFired())
    report["agentAfterFired"] = %int(reproHcrRbLastAfterCallbacksFired())
    report["codeSwapped"] = %(reproHcrRbLastCodeSwapped() != 0)
    report["rejection"] = %($reproHcrRbLastRejection())
    report["unmanagedTypes"] = %($reproHcrRbLastUnmanagedTypes())
    report["beforeRegistryCountAtStart"] = %beforeCountAtStart
    report["afterRegistryCountAtStart"] = %afterCountAtStart
    report["beforeRegistryCountAtEnd"] = %int(reproHcrRbBeforeCallbackCount())
    report["afterRegistryCountAtEnd"] = %int(reproHcrRbAfterCallbackCount())
    report["managedTypeCount"] = %int(reproHcrRbManagedTypeCount())
    report["fileChangedProbeAtEnd"] = %rbHcrFileChanged(ProbeChangedFile)
    report["fileChangedAbsentAtEnd"] = %rbHcrFileChanged(ProbeAbsentFile)
    report["typeChangedProbeAtEnd"] = %rbHcrTypeChanged(ProbeManagedType)
    report["dispatches"] = dispatchLog
    echo $report
    stdout.flushFile()
    quit(0)

  # `runTarget` must pre-empt `unittest`, which is why this sits at module
  # scope above the suites rather than inside an `isMainModule` block at the
  # bottom: `suite`/`test` are templates that run in declaration order.
  block targetModeDispatch:
    let params = commandLineParams()
    if params.len > 0 and params[0] == TargetFlag:
      runTarget(params[1 .. ^1])

  # =====================================================================
  # DRIVER SIDE.
  # =====================================================================

  type
    PortableRun = object
      targetJson: JsonNode
      targetOutput: string
      delivery: HcrCoordinatorDelivery

  proc workDir(): string =
    result = getCurrentDir() / "build" / "hcr-portable-rbhcr"
    createDir(result)

  proc portableRequest(patchId: string; body: openArray[byte];
                       targetSymbol = VictimSymbol;
                       changedFiles: openArray[string] = [ProbeChangedFile];
                       changedTypes: openArray[HcrTypeLayoutChange] = []):
                       HcrPatchRequest =
    directPatchRequest(
      patchId = patchId,
      supportProfile = defaultDirectSupportProfile(),
      changedFunctions = [targetSymbol],
      targetSymbols = [targetSymbol],
      directPatchBytes = body,
      debugObjectBytes = [],
      unwindMetadataBytes = [],
      sourceGenerationMap = [],
      changedFiles = changedFiles,
      changedTypes = changedTypes)

  proc layoutChange(): HcrTypeLayoutChange =
    HcrTypeLayoutChange(typeName: ProbeManagedType, oldSize: 24, newSize: 40)

  proc runTargetReload(socketName: string; request: HcrPatchRequest;
                       scenario = "standard";
                       managedTypes: openArray[string] = [];
                       automatic = false): PortableRun =
    ## Spawn THIS binary as a target, hand it exactly one patch request over
    ## the real agent socket, and collect both halves of the evidence: the
    ## coordinator's view of the wire and the target's own observations.
    ##
    ## A non-zero exit is raised rather than returned, so no caller can read
    ## "the target refused to run" as "the target ran and observed nothing".
    let socketPath = workDir() / socketName
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()

    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env[ReproHcrAgentSocketEnv] = socketPath

    var argv = @[TargetFlag, "--scenario=" & scenario]
    if automatic:
      argv.add "--automatic"
    for managed in managedTypes:
      argv.add "--managed=" & managed

    let process = startProcess(getAppFilename(), workingDir = getCurrentDir(),
      args = argv, env = env, options = {poStdErrToStdOut})
    var connection = acceptHcrAgentConnection(listener)
    var client = initHcrCoordinatorClient(defaultDirectSupportProfile())
    result.delivery = client.deliverPatchRequest(connection, request)
    connection.close()

    result.targetOutput = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      raise newException(IOError,
        "portable rb_hcr target exited " & $exitCode & ":\n" &
        result.targetOutput)
    try:
      result.targetJson = parseJson(result.targetOutput.strip())
    except JsonParsingError as err:
      raise newException(IOError,
        "portable rb_hcr target printed unparsable JSON (" & err.msg & "):\n" &
        result.targetOutput)
    doAssert result.targetJson["schemaId"].getStr() == TargetSchemaId,
      "target printed schemaId " & result.targetJson["schemaId"].getStr()

  proc dispatches(run: PortableRun): seq[JsonNode] =
    for entry in run.targetJson["dispatches"]:
      result.add entry

  proc tags(run: PortableRun): seq[string] =
    for entry in run.dispatches():
      result.add entry["phase"].getStr() & ":" & entry["tag"].getStr() & "@" &
        entry["userData"].getStr()

  proc lastAfterDispatch(log: seq[JsonNode]): JsonNode =
    for entry in log:
      if entry["phase"].getStr() == "after":
        result = entry

  proc writeInspection(name: string; node: JsonNode) =
    let logDir = getCurrentDir() / "test-logs"
    createDir(logDir)
    writeFile(logDir / (name & ".json"), pretty(node))

  proc mutableCopy(text: string): string =
    ## A string with its OWN heap payload, mutable in place and not shared with
    ## any literal. `var s = "..."` in Nim can bind a literal buffer whose
    ## first write reallocates, which would silently move the pointer the
    ## managed-type registry is holding and turn the "stores the pointer, does
    ## not copy" assertions below into assertions about nothing.
    result = newStringOfCap(text.len + 1)
    for ch in text:
      result.add ch

  # A pair of callbacks used only by the in-process registry case. They are
  # distinct function pointers, which is what the case is about.
  proc registryProbeA(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    discard
  proc registryProbeB(info: ptr RbHcrReloadInfo; ud: pointer) {.cdecl.} =
    discard

  suite "hcr_rb_application_abi_contract":

    test "the §13.2/§13.3 registries keep their contract on every host":
      # No wire, no patch, no symbol, no architecture: this case touches only
      # the six registration functions, which carry no platform conditional in
      # repro_hcr_agent.c. It is the part of HLX-M8 that is identical on Linux,
      # macOS and Windows, and until now the only thing any gate asserted about
      # it was one `fired == 1`.
      require int(reproHcrRbBeforeCallbackCount()) == 0
      require int(reproHcrRbAfterCallbackCount()) == 0
      require int(reproHcrRbManagedTypeCount()) == 0

      # ---- §13.3 registration is idempotent on the PAIR, not the callback --
      rbHcrBeforeReload(registryProbeA, cast[pointer](0x11))
      check int(reproHcrRbBeforeCallbackCount()) == 1
      rbHcrBeforeReload(registryProbeA, cast[pointer](0x11))
      check int(reproHcrRbBeforeCallbackCount()) == 1
      rbHcrBeforeReload(registryProbeA, cast[pointer](0x22))
      check int(reproHcrRbBeforeCallbackCount()) == 2
      rbHcrBeforeReload(registryProbeB, cast[pointer](0x11))
      check int(reproHcrRbBeforeCallbackCount()) == 3

      # ---- registration order is the stored order (§13.3: it is also the
      # dispatch order, which the wire cases below measure directly) ---------
      check reproHcrRbBeforeCallbackAt(0) == registryProbeA
      check reproHcrRbBeforeUserDataAt(0) == cast[pointer](0x11)
      check reproHcrRbBeforeCallbackAt(1) == registryProbeA
      check reproHcrRbBeforeUserDataAt(1) == cast[pointer](0x22)
      check reproHcrRbBeforeCallbackAt(2) == registryProbeB
      check reproHcrRbBeforeUserDataAt(2) == cast[pointer](0x11)
      # Past the end answers rather than reads off the end.
      check reproHcrRbBeforeCallbackAt(3) == nil
      check reproHcrRbBeforeUserDataAt(3) == nil

      # ---- a NULL callback is ignored, not stored --------------------------
      rbHcrBeforeReload(nil, cast[pointer](0x33))
      check int(reproHcrRbBeforeCallbackCount()) == 3

      # ---- removal matches BOTH fields -------------------------------------
      # The sharp one. A removal keyed on the callback alone would take out
      # (A, 0x11) here and the count would fall to 2.
      rbHcrRemoveBeforeReload(registryProbeA, cast[pointer](0x99))
      check int(reproHcrRbBeforeCallbackCount()) == 3
      rbHcrRemoveBeforeReload(registryProbeA, cast[pointer](0x11))
      check int(reproHcrRbBeforeCallbackCount()) == 2
      # and the survivors keep their relative order after the compaction.
      check reproHcrRbBeforeCallbackAt(0) == registryProbeA
      check reproHcrRbBeforeUserDataAt(0) == cast[pointer](0x22)
      check reproHcrRbBeforeCallbackAt(1) == registryProbeB
      check reproHcrRbBeforeUserDataAt(1) == cast[pointer](0x11)
      # Removing something never registered is a no-op, not an error.
      rbHcrRemoveBeforeReload(registryProbeB, cast[pointer](0x44))
      check int(reproHcrRbBeforeCallbackCount()) == 2
      rbHcrRemoveBeforeReload(registryProbeA, cast[pointer](0x22))
      rbHcrRemoveBeforeReload(registryProbeB, cast[pointer](0x11))
      check int(reproHcrRbBeforeCallbackCount()) == 0

      # ---- the after-reload registry is a SEPARATE registry ----------------
      rbHcrAfterReload(registryProbeA, cast[pointer](0x11))
      check int(reproHcrRbAfterCallbackCount()) == 1
      check int(reproHcrRbBeforeCallbackCount()) == 0
      rbHcrRemoveAfterReload(registryProbeA, cast[pointer](0x11))
      check int(reproHcrRbAfterCallbackCount()) == 0

      # ---- the capacity, and that the drop past it is SILENT ---------------
      # `RB_HCR_MAX_CALLBACKS` is 64. Registering 70 distinct pairs must leave
      # exactly 64, must not crash, must not report anything, and must keep the
      # FIRST 64 rather than the last — the drop is of the arriving entry.
      for i in 0 ..< RbHcrMaxCallbacks + 6:
        rbHcrBeforeReload(registryProbeA, cast[pointer](0x1000 + i))
      check int(reproHcrRbBeforeCallbackCount()) == RbHcrMaxCallbacks
      check reproHcrRbBeforeUserDataAt(0) == cast[pointer](0x1000)
      check reproHcrRbBeforeUserDataAt(csize_t(RbHcrMaxCallbacks - 1)) ==
        cast[pointer](0x1000 + RbHcrMaxCallbacks - 1)
      for i in 0 ..< RbHcrMaxCallbacks + 6:
        rbHcrRemoveBeforeReload(registryProbeA, cast[pointer](0x1000 + i))
      check int(reproHcrRbBeforeCallbackCount()) == 0

      # ---- §13.2 managed types: de-duplicated BY NAME ----------------------
      var alpha = mutableCopy("HcrPortableAlpha")
      var beta = mutableCopy("HcrPortableBeta")
      let alphaPtr = cast[cstring](addr alpha[0])
      rbHcrRegisterManagedType(alphaPtr)
      check int(reproHcrRbManagedTypeCount()) == 1
      # A DIFFERENT pointer with the SAME text must not add a second entry:
      # matching is `strcmp`, not pointer identity. `alphaCopy` is built at
      # runtime rather than written as a second literal, because two identical
      # literals can share one buffer — which would make this line assert
      # pointer identity while reading as if it asserted the opposite.
      var alphaCopy = mutableCopy("HcrPortableAlpha")
      let alphaCopyPtr = cast[cstring](addr alphaCopy[0])
      # `==` on `cstring` compares CONTENT in Nim, which is the opposite of
      # what this line is for — hence the casts, here and at every other
      # pointer-identity comparison in this case.
      require cast[pointer](alphaCopyPtr) != cast[pointer](alphaPtr)
      rbHcrRegisterManagedType(alphaCopyPtr)
      check int(reproHcrRbManagedTypeCount()) == 1
      rbHcrRegisterManagedType(cast[cstring](addr beta[0]))
      check int(reproHcrRbManagedTypeCount()) == 2

      # ---- the registry stores the POINTER, and does not copy --------------
      # Asserted twice and in two different ways, because "stored, not copied"
      # is the property an application can be bitten by and the one the IsoNim
      # stub records as pinned. First by identity — the entry is the caller's
      # own buffer, not `alphaCopy`, which arrived second and was de-duplicated
      # away …
      check cast[pointer](reproHcrRbManagedTypeAt(0)) == cast[pointer](alphaPtr)
      check cast[pointer](reproHcrRbManagedTypeAt(0)) !=
        cast[pointer](alphaCopyPtr)
      # … and then by consequence: writing into the caller's buffer changes
      # what the registry answers, with no registry call in between. A registry
      # that had copied would still say "HcrPortableAlpha" here, and
      # `rb_hcr_type_changed` would follow it.
      alpha[12] = 'O'
      alpha[13] = 'M'
      alpha[14] = 'E'
      alpha[15] = 'G'
      require cast[pointer](addr alpha[0]) == cast[pointer](alphaPtr)
      check $reproHcrRbManagedTypeAt(0) == "HcrPortableAOMEG"
      check rbHcrTypeChanged(nil) == false
      rbHcrUnregisterManagedType(cast[cstring](addr alpha[0]))
      check int(reproHcrRbManagedTypeCount()) == 1
      check $reproHcrRbManagedTypeAt(0) == "HcrPortableBeta"
      rbHcrUnregisterManagedType(cast[cstring](addr beta[0]))
      check int(reproHcrRbManagedTypeCount()) == 0

      # ---- the managed-type capacity ---------------------------------------
      var names: seq[string] = @[]
      for i in 0 ..< RbHcrMaxManagedTypes + 4:
        names.add mutableCopy("HcrPortableCapacity" & $i)
      for name in names.mitems:
        rbHcrRegisterManagedType(cast[cstring](addr name[0]))
      check int(reproHcrRbManagedTypeCount()) == RbHcrMaxManagedTypes
      check $reproHcrRbManagedTypeAt(0) == "HcrPortableCapacity0"
      for name in names.mitems:
        rbHcrUnregisterManagedType(cast[cstring](addr name[0]))
      check int(reproHcrRbManagedTypeCount()) == 0

      # ---- §13.4 answers false before any reload has been applied ----------
      check not rbHcrFileChanged(ProbeChangedFile)
      check not rbHcrTypeChanged(ProbeManagedType)
      check not rbHcrFileChanged(nil)
      check not rbHcrTypeChanged(nil)

      # ---- §13.1 with nothing pending --------------------------------------
      # `rb_hcr_apply_reload` is documented as blocking until the lifecycle
      # completes; with nothing parked there is no lifecycle, and the agent
      # must say so rather than run an empty one. The call still counts, which
      # is how a frame loop that polls wrongly is diagnosable.
      let callsBefore = int(reproHcrRbApplyReloadCalls())
      check not rbHcrWantsReload()
      rbHcrApplyReload()
      check int(reproHcrRbApplyReloadCalls()) == callsBefore + 1
      check $reproHcrRbLifecycleTrace() == "reject:no-patch-pending"
      check int(reproHcrRbLastBeforeCallbacksFired()) == 0
      check int(reproHcrRbLastAfterCallbacksFired()) == 0

      # Left exactly as found, so the next case in this process starts clean.
      check int(reproHcrRbBeforeCallbackCount()) == 0
      check int(reproHcrRbAfterCallbackCount()) == 0
      check int(reproHcrRbManagedTypeCount()) == 0

    test "§7.4 accepts a managed layout change and refuses an unmanaged one":
      # ONE binary, ONE socket, ONE request shape. The only variable between
      # the two arms is whether `--managed=HcrRbPortableState` was passed, and
      # the outcomes are opposite. Neither arm applies a patch: the accepted
      # one is carried past §7.4 and then stopped at the symbol that does not
      # exist, which is what makes "§7.4 accepted it" observable without any
      # architecture-specific bytes.
      let refused = runTargetReload("p-unmanaged.sock",
        portableRequest("portable-unmanaged", EmptyBody,
                        targetSymbol = AbsentSymbol,
                        changedTypes = [layoutChange()]))
      check refused.delivery.patchApplied.isNone
      require refused.delivery.patchFailed.isSome
      let refusedMessage = refused.delivery.patchFailed.get().message
      check refusedMessage.contains("IncompatibleChange")
      check refusedMessage.contains(ProbeManagedType)
      # Refused in prepare: `hcr/patchApplying` never went out, so the agent
      # never committed to applying anything.
      check refused.delivery.session.lifecycleEvents == @["hcr/patchFailed"]

      let r = refused.targetJson
      check r["lifecycleTrace"].getStr() == "prepare,reject"
      check r["rejection"].getStr().contains("IncompatibleChange")
      check r["unmanagedTypes"].getStr() == ProbeManagedType
      check r["managedTypeCount"].getInt() == 0
      # HLX-M8's never-blank-the-surface deliverable, from the application's
      # own side: not one callback ran.
      check r["agentBeforeFired"].getInt() == 0
      check r["agentAfterFired"].getInt() == 0
      check refused.dispatches().len == 0
      # Requested is not applied: the introspection window did not move.
      check not r["fileChangedProbeAtEnd"].getBool()
      check not r["typeChangedProbeAtEnd"].getBool()

      # ---- the SAME request, with the type registered -----------------------
      let accepted = runTargetReload("p-managed.sock",
        portableRequest("portable-managed", EmptyBody,
                        targetSymbol = AbsentSymbol,
                        changedTypes = [layoutChange()]),
        managedTypes = [ProbeManagedType])
      require accepted.delivery.patchFailed.isSome
      let acceptedMessage = accepted.delivery.patchFailed.get().message
      # §7.4 let it through — the refusal is now about the SYMBOL, and names no
      # incompatible change at all.
      check not acceptedMessage.contains("IncompatibleChange")
      check acceptedMessage.contains("symbol")
      let a = accepted.targetJson
      check a["managedTypeCount"].getInt() == 1
      check a["unmanagedTypes"].getStr() == ""
      check a["lifecycleTrace"].getStr() == "prepare,reject"
      check a["rejection"].getStr().contains("symbol")
      # Still a prepare refusal, so still nothing fired and nothing moved.
      check accepted.dispatches().len == 0
      check not a["fileChangedProbeAtEnd"].getBool()

      writeInspection("hcr_rb_application_abi_contract_layout_acceptance", %*{
        "schemaId": "reprobuild.hcr.hlx-m8.portable-layout-acceptance.v1",
        "refusedUnmanaged": r,
        "acceptedManaged": a,
        "wireRefusedUnmanaged": refusedMessage,
        "wireAcceptedManaged": acceptedMessage})

    test "§3.4 step 43 refuses a layout-changing patch in automatic mode":
      # Asserted nowhere before this gate: every HLX-M8 target enables
      # synchronized mode unconditionally, so the refusal arm was unreachable.
      # It is pure prepare-stage policy — no platform in it.
      let automatic = runTargetReload("p-automatic.sock",
        portableRequest("portable-automatic", EmptyBody,
                        targetSymbol = AbsentSymbol,
                        changedTypes = [layoutChange()]),
        managedTypes = [ProbeManagedType], automatic = true)
      require automatic.delivery.patchFailed.isSome
      let m = automatic.delivery.patchFailed.get().message
      check m.contains("IncompatibleChange")
      check m.contains("synchronized mode")
      check m.contains("rb_hcr_apply_reload")
      let auto = automatic.targetJson
      check not auto["synchronizedMode"].getBool()
      # It ran on the AGENT's path, not the application's: nothing was parked,
      # so `rb_hcr_apply_reload` was never called.
      check auto["applyReloadCalls"].getInt() == 0
      check not auto["wantsReloadBeforeApply"].getBool()
      check auto["lifecycleTrace"].getStr() == "prepare,reject"
      check automatic.dispatches().len == 0

      # The CONTROL that makes the arm above mean something: the identical
      # request, in synchronized mode, gets past step 43 and is refused for a
      # different reason entirely.
      let synchronized = runTargetReload("p-automatic-control.sock",
        portableRequest("portable-automatic-control", EmptyBody,
                        targetSymbol = AbsentSymbol,
                        changedTypes = [layoutChange()]),
        managedTypes = [ProbeManagedType])
      require synchronized.delivery.patchFailed.isSome
      let controlMessage = synchronized.delivery.patchFailed.get().message
      check not controlMessage.contains("synchronized mode")
      check controlMessage.contains("symbol")
      check synchronized.targetJson["synchronizedMode"].getBool()
      check synchronized.targetJson["applyReloadCalls"].getInt() == 1

    test "a Phase F failure after before-reload still reaches after-reload":
      # §3.3 step 38, in the only shape that is portable today.
      #
      # THE REFUSAL IS REAL AND IS THE PRODUCTION CODE'S OWN. A zero-length
      # direct-patch body passes every prepare check — `patchId`,
      # `changedFunctions`, a non-NULL `bytesHex`, §7.4, §3.4, symbol
      # resolution and the hex decode all succeed — and is then refused inside
      # Phase F by `repro_hcr_lx_txn_prepare_site` on Linux
      # (`repro_hcr_linux_x86_64.h:1685`, `patch_len == 0`) and by
      # `repro_hcr_prepare_direct_patch` on every other host
      # (`repro_hcr_agent.c:2086`). Same predicate, same phase, same observable
      # — which is exactly why this arm is expressible off Linux and the
      # oversized-body arm in the Linux gate is not. No lever, no forced return
      # code, no simulated boundary.
      #
      # WHAT IT DOES NOT SHOW, off Linux: that the refusal happened in F rather
      # than in G. It cannot, because off Linux there is no such distinction —
      # see the header of this file.
      let control = runTargetReload("p-step38-control.sock",
        portableRequest("portable-step38-control", EmptyBody,
                        targetSymbol = AbsentSymbol,
                        changedTypes = [layoutChange()]),
        managedTypes = [ProbeManagedType])
      require control.delivery.patchFailed.isSome
      # The control is the SAME request with an unresolvable symbol, so it dies
      # one step earlier — in prepare. It exists so that "before-reload fired"
      # below is not something this instrument says about every run.
      check control.targetJson["lifecycleTrace"].getStr() == "prepare,reject"
      check control.dispatches().len == 0

      let late = runTargetReload("p-step38.sock",
        portableRequest("portable-step38", EmptyBody,
                        changedTypes = [layoutChange()]),
        managedTypes = [ProbeManagedType])
      require late.delivery.patchFailed.isSome
      # The failure came AFTER the agent committed to applying: `patchApplying`
      # went out. That is what separates a Phase F failure from a prepare
      # refusal on the wire, and the control above has only `patchFailed`.
      check late.delivery.session.lifecycleEvents ==
        @["hcr/patchApplying", "hcr/patchFailed"]
      check late.delivery.patchApplied.isNone

      let s = late.targetJson
      check s["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,load-failed,after"
      check not s["codeSwapped"].getBool()

      # ---- §3.1's phase order, from inside the process ---------------------
      # Three before-callbacks, then one after-callback, in registration order.
      # This single comparison carries §13.3's dispatch order, its idempotency
      # rule, its removal rule and §3.1's E-then-H order at once.
      check late.tags() == @[
        "before:B1@0x8100", "before:B2@0x8200", "before:B1@0x8400",
        "after:A1@0x8500", "after:A2@0x8600"]
      check s["agentBeforeFired"].getInt() == 3
      check s["agentAfterFired"].getInt() == 2

      let log = late.dispatches()
      # ---- step 38's parenthesis: ZERO changed_types to the after-callbacks,
      # while the before-callbacks, which ran before the failure, saw the real
      # layout delta. The zero is specific to the after side on this path.
      for entry in log:
        check entry["changedFilesCount"].getInt() == 1
        check entry["firstFile"].getStr() == ProbeChangedFile
        if entry["phase"].getStr() == "before":
          check entry["changedTypesCount"].getInt() == 1
          check entry["firstType"].getStr() == ProbeManagedType
          check entry["firstTypeOldSize"].getInt() == 24
          check entry["firstTypeNewSize"].getInt() == 40
          # §13.6 calls the introspection predicates from inside a
          # before-reload callback, so the window is open by Phase E.
          check entry["fileChangedProbe"].getBool()
          check not entry["fileChangedAbsent"].getBool()
          check entry["typeChangedProbe"].getBool()
        else:
          check entry["changedTypesCount"].getInt() == 0
          check entry["firstType"].getStr() == ""
          # … and by Phase H the latch has been rolled back, because the reload
          # did not happen. ONE predicate, observed flipping inside ONE run:
          # an implementation that always answered false, or always true, is
          # red on one of these two lines.
          check not entry["fileChangedProbe"].getBool()
          check not entry["typeChangedProbe"].getBool()

      # …and it is still false when the application asks after the reload.
      check not s["fileChangedProbeAtEnd"].getBool()
      check not s["typeChangedProbeAtEnd"].getBool()

      # OPEN-5, asserted rather than described. A PLAIN patch with no layout
      # change delivers a payload the application cannot tell apart from this
      # failure: same `changed_types_count`, same `changed_files_count`, and
      # `rb_hcr_file_changed` false in both. `RbHcrReloadInfo` has no status
      # field. Step 38 gives the AGENT an obligation; it hands the application
      # no discriminator, and that is measured here rather than papered over.
      let plain = runTargetReload("p-step38-plain.sock",
        portableRequest("portable-step38-plain", EmptyBody))
      require plain.delivery.patchFailed.isSome
      let plainAfter = lastAfterDispatch(plain.dispatches())
      let lateAfter = lastAfterDispatch(log)
      # Spelled as two `bool`s rather than `require x != nil`, because
      # `unittest` stringifies the operands of a failed comparison and `$` on a
      # nil `JsonNode` segfaults — which would turn a legitimate red under a
      # falsifier build into a crash that hides the rest of the case. Measured:
      # it did exactly that under `-DREPRO_HCR_FALSIFY_SKIP_STEP38`.
      let plainHasAfterDispatch = not plainAfter.isNil
      let lateHasAfterDispatch = not lateAfter.isNil
      require plainHasAfterDispatch
      require lateHasAfterDispatch
      check plainAfter["changedTypesCount"].getInt() ==
        lateAfter["changedTypesCount"].getInt()
      check plainAfter["changedFilesCount"].getInt() ==
        lateAfter["changedFilesCount"].getInt()
      check plainAfter["fileChangedProbe"].getBool() ==
        lateAfter["fileChangedProbe"].getBool()

      writeInspection("hcr_rb_application_abi_contract_step38", %*{
        "schemaId": "reprobuild.hcr.hlx-m8.portable-step38.v1",
        "prepareRefusalControl": control.targetJson,
        "phaseFFailure": s,
        "plainNoLayoutChange": plain.targetJson})

    test "callback dispatch runs over a snapshot taken when it began":
      # §13.3, and the reason `rb_hcr_fire` copies the array before iterating:
      # a callback may register or remove callbacks, and the live array must
      # not be re-read mid-dispatch. Neither half of that is observable without
      # a real dispatch, and neither was asserted anywhere before this gate.
      let run = runTargetReload("p-snapshot.sock",
        portableRequest("portable-snapshot", EmptyBody,
                        changedTypes = [layoutChange()]),
        scenario = "snapshot", managedTypes = [ProbeManagedType])
      require run.delivery.patchFailed.isSome
      let s = run.targetJson
      check s["lifecycleTrace"].getStr() ==
        "prepare,latch,before,load,load-failed,after"

      # MUTATOR registers LATE and removes DOOMED while the dispatch is
      # running. DOOMED still fires — it was in the snapshot. LATE does not —
      # it was not.
      check run.tags() == @[
        "before:MUTATOR@0x7900", "before:DOOMED@0x7b00", "after:A1@0x8500"]
      check s["agentBeforeFired"].getInt() == 2

      # The registry itself DID change: the edits landed, they just did not
      # take effect in the dispatch that made them. Without this the case
      # could not tell "the snapshot held" from "the edits did nothing".
      check s["beforeRegistryCountAtStart"].getInt() == 2
      check s["beforeRegistryCountAtEnd"].getInt() == 2
      check s["afterRegistryCountAtStart"].getInt() == 1
      check s["afterRegistryCountAtEnd"].getInt() == 1

      writeInspection("hcr_rb_application_abi_contract_snapshot", %*{
        "schemaId": "reprobuild.hcr.hlx-m8.portable-snapshot.v1",
        "run": s})

else:
  suite "hcr_rb_application_abi_contract":
    test "the rb_hcr_* application ABI must exist on this host":
      # NOT a skip. `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`
      # is an inventory of tests that detected a missing prerequisite, returned
      # early, and were counted as PASSED. The prerequisite missing here is the
      # PRODUCT, not the toolchain: HCR-Overview.md §13 declares ten functions
      # that this host does not implement, and `repro_hcr_agent.h` declares all
      # ten unconditionally, so an application that links against this host gets
      # a link error rather than a diagnostic. Reporting that as green would
      # tell the next reader that Windows has a working application ABI.
      checkpoint ReproHcrApplicationAbiUnavailable
      check ReproHcrApplicationAbiAvailable

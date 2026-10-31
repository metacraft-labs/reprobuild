## Ephemeral-State-Leases.md §4.2 — the daemon's SESSION reap transport is
## reachable from the PRODUCT, with nothing registered by hand.
##
## §4.2 states that the daemon destroys over the RP provider-session protocol
## "so an out-of-tree provider (gosti's Incus drivers) is reached without
## linking it into the daemon", with in-process linking as the *fallback*. That
## was inverted: the transport was selected only when a provider artifact had
## been registered with the daemon, `registerLeaseReapProvider` had NO caller
## anywhere in the shipped tree, and so every reap tick of every shipped daemon
## ran in-process, always — the `rtSession` arm was unreachable from the product
## (reprobuild-pm/issues/2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md).
##
## The mechanism was real: the only thing that had ever registered an artifact
## was a deleted `infra` topology gate which built a THROWAWAY in-process daemon
## on a thread and did the registration inside the test process. This case is
## the opposite of that gate, and that is the whole point of it:
##
##   * NOTHING here calls `registerLeaseReapProvider` — asserted, not assumed;
##   * the record on disk was written by the PRODUCTION session reconcile
##     (`reconcileResourcesViaSession`, the proc `repro run`'s leased-consumes
##     bridge calls), which is what records the provider artifact in it;
##   * the sweep is the PRODUCTION daemon tick, `runAndRecordLeaseReapTick`,
##     called exactly as `runtime.nim`'s event loop calls it — no transport
##     argument, no resolver, no injected handle;
##   * the session pool the materialize used is CLOSED first, so the provider
##     child that performs the destroy is one the tick launched itself.
##
## THE SETUP IS A REAL DAEMON CONFIGURATION, not a mock of one. A real provider
## binary is compiled from a recipe (the RP1 interface extraction + provider
## compile), owning `reapprod.fileworld`, whose driver's fake world is an
## on-disk FILE. The engine registers the attrs codec only long enough to WRITE
## the record, then drops it: from there the test process is the daemon — record
## on disk, provider binary reachable only by launching it, no driver for the
## type, no attrs codec for it.
##
## NON-VACUITY, five ways — this case must be incapable of passing by accident:
##
##   (a) `hasLeaseReapProviders()` is false at reap time, so the reap cannot
##       have come from the registry the deleted gate used;
##   (b) the engine has NO resource provider registered for the type, so an
##       in-process reap could not have done this;
##   (c) the engine has NO attrs codec for the type at reap time, so a strict
##       reconstruction would raise — and the second record below proves that
##       condition is live rather than a formality;
##   (d) the destroy left a WITNESS stamped with the writer's process id, and
##       that pid is a provider CHILD's, not this process's; the materialize
##       pool is closed before the tick, so the child is the tick's own;
##   (e) a SECOND record, of a type nothing can reach — no driver, no codec, no
##       artifact in its record and none registered — is still refused in the
##       SAME tick, with the §4.5 finding. So the sweep did not become
##       indiscriminate: it reaped the record that carries a route and reported
##       the one that does not.
##
## The fake world really exists before the reap, so the destroy is a real
## destroy and not an already-absent no-op that removes the record anyway.
##
## Skip rule: none. The provider build is the test.

import std/[options, os, strutils, tables, times, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources
import repro_daemon_core                 # runAndRecordLeaseReapTick +
                                         # hasLeaseReapProviders /
                                         # clearLeaseReapProviders /
                                         # readLeaseReapTickHealth

const
  ReapTypeId = "reapprod.fileworld"
  UnreachableTypeId = "reapprod.unreachable"
    ## A type with no driver, no attrs codec and no provider artifact anywhere.
    ## Case (e)'s record uses it: the §4.2 routing rule must send it in-process
    ## (the only arm left) and the §4.5 finding must report it, even on a tick
    ## that successfully session-reaped its neighbour.

# The engine side needs the attrs codec only to WRITE the record — exactly as
# the process that materialized the live `gosti.nic` record did. It is
# dropped again before the reap, which is the state under test.
type
  FileWorldAttrs = object
    path*: string
    value*: string

# ---------------------------------------------------------------------------
# The provider source. `reapprod.fileworld`'s fake world is a FILE:
#
#   * `apply(create/update)` writes "<pid>\n<value>";
#   * `apply(rakDestroy)`    writes "<pid>" to "<path>.destroyed-by" and then
#     REMOVES the world file. The witness file is what proves the destroy ran
#     in a provider child rather than here — a mere absence could also be
#     produced by never having created it.
#   * `observe` reports present iff the world file exists.
# ---------------------------------------------------------------------------

const providerBody = """
import std/[options, os, strutils, tables]
import repro_project_dsl
import repro_resources

type
  FileWorldAttrs = object
    path*: string
    value*: string

proc fwIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  "fileworld:" & a.path

proc fwDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & a.value)

proc fwObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  if fileExists(a.path):
    let contents = readFile(a.path)
    let lines = contents.split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString(inst.address & "\x00" & realized)
  else:
    result.present = false

proc fwApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  case action
  of rakDestroy:
    # The witness: who actually performed the destroy. Written BEFORE the
    # removal so a crash between the two cannot make the destroy look local.
    writeFile(a.path & ".destroyed-by", $getCurrentProcessId())
    if fileExists(a.path):
      removeFile(a.path)
    result = ResourceBinding(
      address: inst.address,
      typeId: inst.typeId,
      resourceId: fwIdentity(inst),
      present: false)
  else:
    writeFile(a.path, $getCurrentProcessId() & "\n" & a.value)
    result = ResourceBinding(
      address: inst.address,
      typeId: inst.typeId,
      resourceId: fwIdentity(inst),
      postWriteDigest: fwDigest(inst),
      present: true)

let fileWorldDriver = ResourceProviderDriver(
  identity: fwIdentity,
  digest: fwDigest,
  observe: fwObserve,
  apply: fwApply)

resourceType "reapprod.fileworld":
  attrs: FileWorldAttrs
  wrapper: fileWorld
  determinism: rdVolatile
  driver: fileWorldDriver
  attr path: string
  attr value: string

package reapprodprov:
  build:
    discard
"""

proc writeProject(root: string): string =
  createDir(extendedPath(root))
  let modulePath = root / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)
  modulePath

proc buildProvider(tempRoot: string): tuple[binary, artifactId: string] =
  ## Compile the provider the way the engine does: extract its lifted interface
  ## (RP1), then compile the provider binary against that fingerprint.
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  createDir(extendedPath(outDir))
  let modulePath = writeProject(projectRoot)
  let interfacePath = outDir / "reapprod-interface.rbsz"
  let stubPath = outDir / "reapprod-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "reapprod-provider"
  let compilePath = outDir / "reapprod-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

proc desiredInstance(worldPath, value: string): ResourceInstance =
  ResourceInstance(
    typeId: ReapTypeId,
    address: "world",
    attrs: TypedExtensionBox[FileWorldAttrs](
      typeId: ReapTypeId,
      val: FileWorldAttrs(path: worldPath, value: value)),
    dependsOn: @[],
    determinism: rdVolatile)

suite "the daemon's session reap transport is reachable from production":

  test "the production tick session-reaps a record that names its provider":
    let tempRoot = getTempDir() / "reapprod-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))

    # Case (a) precondition. The registry is a module global; clear it so a
    # sibling case in this binary cannot have seeded it, and so the assertion
    # below is about the production path rather than about test ordering.
    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()

    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))

    let worldPath = extendedPath(tempRoot / "fake-world.txt")
    let witnessPath = worldPath & ".destroyed-by"
    let storeRoot = tempRoot / "state"
    let store = openStateStore(storeRoot)

    # The artifact ref as the RESOURCE LANE carries it — the same shape the
    # resource-graph metadata hands `repro run`, which is where production gets
    # it. Not a `ProviderArtifactRef` hand-built for a pinned resolver.
    let artifactRef = ResourceProviderArtifactRef(
      binaryPath: provider.binary,
      providerArtifactId: provider.artifactId,
      workingDir: getCurrentDir())

    # ── Materialize over a session, THROUGH THE PRODUCTION RECONCILE. ──────
    # `reconcileResourcesViaSession(..., providerArtifacts = …)` is what the
    # leased-consumes bridge calls; passing the refs is what makes the record
    # carry its own route back to the provider.
    registerExtension[FileWorldAttrs](ReapTypeId)
    check extensionRegistry.contains(ReapTypeId)
    block materialize:
      let pool = newProviderSessionPool()
      # CLOSED before the tick, deliberately: if this session survived, the
      # destroy below could be served by a child this test launched, and the
      # case would prove nothing about what production can open on its own.
      defer: pool.closeAll()
      let resolve = proc (typeId: string): ProviderHandle =
        pool.openProviderSession(ProviderArtifactRef(
            binaryPath: artifactRef.binaryPath,
            providerArtifactId: artifactRef.providerArtifactId,
            workingDir: artifactRef.workingDir),
          defaultSessionPolicy(),
          EngineHello(
            protocolVersion: ProviderProtocolVersion,
            engineCapabilities: @["named-run-edge-consumes"],
            lockSliceId: "run-edge-consumes",
            canonicalExecutionRoot: getCurrentDir()))
      let materialized = reconcileResourcesViaSession(
        @[desiredInstance(worldPath, "up")], resolve,
        store = some(store),
        providerArtifacts = @[(typeId: ReapTypeId, artifact: artifactRef)])
      check materialized.actions.len == 1
      check materialized.actions[0].kind == rakCreate

    # The fake world really exists, so the reap below has something to destroy
    # and cannot pass as an already-absent no-op.
    check fileExists(worldPath)
    check not fileExists(witnessPath)
    check hasStateRecord(store, "world")

    # THE DURABLE HALF: the record names its provider. This is the single fact
    # that makes the session transport reachable without any registration, and
    # it is what the unfixed tree could not produce.
    var rec = readStateRecord(store, "world")
    check rec.providerArtifact.isSome
    check rec.providerArtifact.get.binaryPath == provider.binary
    check rec.providerArtifact.get.providerArtifactId == provider.artifactId
    check rec.providerArtifact.get.workingDir == getCurrentDir()
    check rec.attrsTypeId == ReapTypeId
    check rec.attrsJson.len > 0

    # Backdate the lease so the record is reapable. Read-modify-write through
    # the record itself: no codec is needed to move a deadline, which is also
    # why a daemon can select a record it cannot reconstruct.
    let past = getTime() - initDuration(hours = 1)
    rec.effectiveDeadline = some(past)
    rec.lastRenewed = past
    rec.holders = initTable[string, Time]()
    writeStateRecord(store, rec)

    # Case (e): a record of a type NOTHING can reach. Same store, same tick,
    # also expired, no `dependsOn` either way so neither can hold the other
    # back. Its attrs payload is deliberately an unregistered type's bytes.
    writeStateRecord(store, ResourceStateRecord(
      address: "unreachable",
      typeId: UnreachableTypeId,
      determinism: rdVolatile,
      attrsTypeId: UnreachableTypeId,
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:unreachable",
      present: true,
      holders: initTable[string, Time](),
      keepHolders: @[],
      keepHoldersKnown: true,
      effectiveDeadline: some(past),
      lastRenewed: past,
      providerArtifact: none(ResourceProviderArtifactRef)))

    # ── Become the daemon: drop the codec. ────────────────────────────────
    extensionRegistry.del(ReapTypeId)
    # (b) + (c): no driver, and now no codec either, for the reapable type.
    check not isResourceProviderRegistered(ReapTypeId)
    check not extensionRegistry.contains(ReapTypeId)
    # (b) for the unreachable type too.
    check not isResourceProviderRegistered(UnreachableTypeId)
    check not extensionRegistry.contains(UnreachableTypeId)
    # (a): THE REGISTRY IS EMPTY. Nothing in this file, and nothing in the
    # product, has registered an artifact — the reap that follows has only the
    # store to go on.
    check not hasLeaseReapProviders()

    # ── The production daemon tick. ───────────────────────────────────────
    # Exactly the call `runtime.nim`'s `runScopedLeaseReapTick` makes: scope,
    # store root, now. No transport, no resolver, no handle.
    let outcome = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 1))
    check not outcome.raised
    check outcome.failure == ""
    check outcome.reapedCount == 1

    # The world is torn down and its record removed.
    check not fileExists(worldPath)
    check not hasStateRecord(store, "world")

    # (d): the destroy ran in a PROVIDER CHILD the tick launched, not here.
    check fileExists(witnessPath)
    let destroyer = parseInt(readFile(witnessPath).strip())
    check destroyer != int(getCurrentProcessId())

    # (e): the unreachable record was refused, in the same tick, with the §4.5
    # finding — and it is still in the store for a sweep that can resume it.
    check outcome.failedCount == 1
    check hasStateRecord(store, "unreachable")
    var namedUnreachable = false
    for finding in outcome.findings:
      if finding.line.contains("unreachable") and
         finding.line.contains("cannot reap"):
        namedUnreachable = true
    check namedUnreachable

    # The tick's standing verdict was persisted, and it is UNSUCCESSFUL because
    # one selected record was left unreaped (§4.5) — which is the honest reading
    # of this store, not a complaint about the session reap.
    let health = readLeaseReapTickHealth(dlsUser, overrideRoot = storeRoot)
    check health.isSome
    check health.get.totalTicks == 1
    check health.get.consecutiveUnsuccessful == 1

    # With the stuck record gone, the next tick is a clean idle sweep: the
    # session reap above left nothing behind for it.
    removeStateRecord(store, "unreachable")
    let second = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 2))
    check not second.raised
    check second.reapedCount == 0
    check second.failedCount == 0
    let health2 = readLeaseReapTickHealth(dlsUser, overrideRoot = storeRoot)
    check health2.isSome
    check health2.get.consecutiveUnsuccessful == 0

  test "the reap session pool is bounded across ticks":
    ## `pruneLeaseReapSessionPool`'s rule, against LIVE sessions.
    ##
    ## The daemon's pool holds one live provider CHILD per
    ## `providerArtifactId` it has been asked for, and nothing evicted them.
    ## That was unreachable while no shipped code path could register an
    ## artifact — the pool was never created. Now the RECORDS drive it, and a
    ## rebuilt provider gets a new content-addressed id every time, so a
    ## developer iterating on an out-of-tree provider would leave one orphaned
    ## child per build alive for as long as the daemon ran. The leak is this
    ## change's to prevent.
    ##
    ## The rule is PER-ARTIFACT IDLENESS: a session no tick has used for
    ## `LeaseReapSessionIdleTickLimit` consecutive ticks is closed and nothing
    ## else is touched. Driven here in order:
    ##
    ##   1. a tick using TWO ids leaves two live sessions, and an identical
    ##      second tick REUSES both — the §4.2 pooling contract, and what a
    ##      naive close-after-every-tick would destroy;
    ##   2. an id the store stops referencing SURVIVES the ticks below the
    ##      limit and is evicted AT it, while the id still in use is kept —
    ##      which is the per-artifact half: the eviction does not take the
    ##      sessions the tick still wants with it;
    ##   3. an IDLE tick (nothing due, nothing attempted) ages nothing, so a
    ##      quiet period does not evict a session the next reap wants.
    ##
    ## (The alternating-due-times case below covers the other half of (2): a
    ## session surviving the ticks that did not use it when the two ids take
    ## turns. This case holds one id used throughout.)
    ##
    ## HOW LIVE SESSIONS ARE OBTAINED WITHOUT THE RECORDS BEING REAPED. The
    ## records name types the provider does not serve (`reapprod.poolA` /
    ## `.poolB`), both backed by the one REAL binary this file compiles under
    ## two different claimed artifact ids — which is a distinct pool key, since
    ## a v1 provider self-attests no id and the engine binds the session to the
    ## id it was given. The tick therefore LAUNCHES and POOLS a session per id
    ## and only then fails the record's `observe` inside the provider, so the
    ## record stays in the store for the next tick to meet again. That is what
    ## lets one store drive several ticks over the same live sessions.
    let tempRoot = getTempDir() / "reapprod-pool-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))

    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()

    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))
    let storeRoot = tempRoot / "state"
    let store = openStateStore(storeRoot)
    let past = getTime() - initDuration(hours = 1)

    proc poolRecord(address, typeId, artifactId: string): ResourceStateRecord =
      ResourceStateRecord(
        address: address,
        typeId: typeId,
        determinism: rdVolatile,
        attrsTypeId: typeId,
        attrsJson: "\x01\x00\x00\x00\x00\x00",
        dependsOn: @[],
        identity: "stub:" & address,
        present: true,
        holders: initTable[string, Time](),
        keepHolders: @[],
        keepHoldersKnown: true,
        effectiveDeadline: some(past),
        lastRenewed: past,
        providerArtifact: some(ResourceProviderArtifactRef(
          binaryPath: provider.binary,
          providerArtifactId: artifactId,
          workingDir: getCurrentDir())))

    writeStateRecord(store, poolRecord("pool-a", "reapprod.poolA", "art-aaaa"))
    writeStateRecord(store, poolRecord("pool-b", "reapprod.poolB", "art-bbbb"))

    # Two types, two artifact ids, both launchable.
    let derived = providerArtifactsOfRecords(listStateRecords(store))
    check derived.len == 2
    check leaseReapSessionCount() == 0
    check not hasLeaseReapProviders()

    # ── (1) a tick using TWO ids keeps TWO live sessions, and reuses them ──
    let first = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 1))
    check not first.raised
    # Both records were attempted over a session and both failed INSIDE the
    # provider (it serves neither type), so each left its session behind.
    check first.reapedCount == 0
    check first.failedCount == 2
    check leaseReapSessionCount() == 2
    check hasStateRecord(store, "pool-a")
    check hasStateRecord(store, "pool-b")

    let second = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 2))
    check second.failedCount == 2
    check leaseReapSessionCount() == 2        # reused, not relaunched

    # ── (2) an id the store stops referencing ages out, and only it ───────
    # `pool-b` leaves the store, as it would when its provider is rebuilt
    # under a new id (or the record is reaped elsewhere).
    removeStateRecord(store, "pool-b")
    check providerArtifactsOfRecords(listStateRecords(store)).len == 1

    # THE EVICTION TICK IS PINNED AS A LITERAL, deliberately. Every other loop
    # bound in this file is written in terms of
    # `LeaseReapSessionIdleTickLimit`, so changing the constant would redden
    # nothing and the reasoning in its docstring would stop being accountable
    # to any test. Four reaping ticks after `art-bbbb` was last used is the
    # BEHAVIOUR being promised — a literal 4 here is what makes a change to
    # that promise show up as a failure rather than as a silently different
    # policy. (`check LeaseReapSessionIdleTickLimit == 4` would pin the number
    # without pinning the behaviour, and is not what this is.)
    #
    # Ticks 1, 2 and 3 after last use: it SURVIVES. The rule is idleness, not
    # "the pool is bigger than this tick's used-set".
    for i in 0 ..< 3:
      let tick = runAndRecordLeaseReapTick(dlsUser, overrideRoot = storeRoot,
        now = past + initDuration(minutes = i + 3))
      check tick.failedCount == 1
      check leaseReapSessionCount() == 2
    # Tick 4: `art-bbbb` is closed — and `art-aaaa`, used by every one of these
    # ticks, is NOT.
    let evicting = runAndRecordLeaseReapTick(dlsUser, overrideRoot = storeRoot,
      now = past + initDuration(minutes = 6))
    check evicting.failedCount == 1
    check leaseReapSessionCount() == 1
    # The constant and the pinned behaviour must agree; if someone changes the
    # policy they have to change this case, and then the docstring's
    # four-way-rotation reasoning with it.
    check LeaseReapSessionIdleTickLimit == 4

    # It stays at one however many further ticks run: the eviction happened
    # once and the surviving session keeps being reused.
    let after = runAndRecordLeaseReapTick(dlsUser, overrideRoot = storeRoot,
      now = past + initDuration(minutes = LeaseReapSessionIdleTickLimit + 4))
    check after.failedCount == 1
    check leaseReapSessionCount() == 1

    # ── (3) an IDLE tick ages nothing ─────────────────────────────────────
    # With the last record gone nothing is due, so nothing is attempted, and
    # "used zero" must not be read as "needs zero". The surviving session is
    # left alone however many idle ticks run.
    removeStateRecord(store, "pool-a")
    for i in 0 ..< LeaseReapSessionIdleTickLimit + 2:
      let idle = runAndRecordLeaseReapTick(dlsUser, overrideRoot = storeRoot,
        now = past + initDuration(minutes = i + 30))
      check not idle.raised
      check idle.reapedCount == 0
      check idle.failedCount == 0
      check leaseReapSessionCount() == 1      # untouched, deliberately

    # Shutdown (what the daemon's own defer calls) closes it.
    clearLeaseReapProviders()
    check leaseReapSessionCount() == 0

  test "alternating due-times do not thrash the reap session pool":
    ## The §4.2 pooling contract under a REAL store's timing.
    ##
    ## The ids a tick uses are whichever records are DUE, and records of
    ## different types rarely fall due together. Two out-of-tree providers
    ## therefore alternate `used = {A}`, `used = {B}` — and the size-comparison
    ## prune this replaced saw a pool of two against a used-set of one on every
    ## other tick and dropped BOTH, relaunching both next tick. "Steady state
    ## keeps full reuse" was true only for identical consecutive sets, which a
    ## real store does not produce. The idleness rule keeps a session across the
    ## ticks that did not use it, up to `LeaseReapSessionIdleTickLimit`.
    ##
    ## Due-ness is toggled by REWRITING each record's deadline between ticks —
    ## a deadline in the past is due, one in the future is not — which is how
    ## the suite already backdates a lease. Advancing `now` alone cannot do it:
    ## once past, a deadline stays past.
    let tempRoot = getTempDir() / "reapprod-thrash-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))
    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()

    let provider = buildProvider(tempRoot)
    let storeRoot = tempRoot / "state"
    let store = openStateStore(storeRoot)
    let past = getTime() - initDuration(hours = 1)
    let future = getTime() + initDuration(hours = 1)

    proc thrashRecord(address, typeId, artifactId: string;
                      deadline: Time): ResourceStateRecord =
      ResourceStateRecord(
        address: address, typeId: typeId, determinism: rdVolatile,
        attrsTypeId: typeId, attrsJson: "\x01\x00\x00\x00\x00\x00",
        dependsOn: @[], identity: "stub:" & address, present: true,
        holders: initTable[string, Time](), keepHolders: @[],
        keepHoldersKnown: true,
        effectiveDeadline: some(deadline), lastRenewed: past,
        providerArtifact: some(ResourceProviderArtifactRef(
          binaryPath: provider.binary,
          providerArtifactId: artifactId,
          workingDir: getCurrentDir())))

    proc setDue(address, typeId, artifactId: string; due: bool) =
      writeStateRecord(store, thrashRecord(address, typeId, artifactId,
        if due: past else: future))

    # Both due: the tick opens a session per artifact id.
    setDue("rec-a", "reapprod.thrashA", "art-aaaa", true)
    setDue("rec-b", "reapprod.thrashB", "art-bbbb", true)
    let both = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 1))
    check both.failedCount == 2
    check leaseReapSessionCount() == 2

    # Now ALTERNATE for four ticks. Each tick uses exactly one id; the other
    # session must survive, because one tick of idleness is far below the
    # limit. Under the old rule every one of these ticks dropped both.
    for i in 0 .. 3:
      let aDue = (i mod 2) == 0
      setDue("rec-a", "reapprod.thrashA", "art-aaaa", aDue)
      setDue("rec-b", "reapprod.thrashB", "art-bbbb", not aDue)
      let tick = runAndRecordLeaseReapTick(dlsUser,
        overrideRoot = storeRoot, now = past + initDuration(minutes = i + 2))
      check not tick.raised
      check tick.failedCount == 1              # exactly one record was due
      # BOTH sessions still live: the one this tick used, and the one it did
      # not. This is the assertion the old rule failed.
      check leaseReapSessionCount() == 2

    # The idle one is evicted only once it has gone unused for the limit. Keep
    # `rec-a` due for that many consecutive ticks and `art-bbbb` ages out,
    # while `art-aaaa` — used every tick — stays.
    setDue("rec-b", "reapprod.thrashB", "art-bbbb", false)
    for i in 0 ..< LeaseReapSessionIdleTickLimit:
      setDue("rec-a", "reapprod.thrashA", "art-aaaa", true)
      discard runAndRecordLeaseReapTick(dlsUser, overrideRoot = storeRoot,
        now = past + initDuration(minutes = i + 10))
    check leaseReapSessionCount() == 1         # `art-bbbb` aged out, `art-aaaa` kept

  test "an orphaned session is dropped even behind a permanently failing one":
    ## The permanent leak the size-comparison rule had, and the reason the id
    ## is now recorded only on a SUCCESSFUL open.
    ##
    ## The old rule compared ids ASKED FOR against sessions HELD. A record whose
    ## artifact is stale — its launch always fails, so it holds no session —
    ## counted 1 used against 1 held, so `1 <= 1` and an unrelated ORPHANED
    ## session was never closed, on every tick, for the daemon's life. Such a
    ## record is not exotic: §4.5 says a record the sweep cannot reap is left in
    ## the store for whichever later sweep can, so it sits there by design and
    ## sustains the leak indefinitely.
    ##
    ## Here: one record whose artifact LAUNCHES (leaving a session), one whose
    ## artifact does not exist (launch fails, no session). Remove the first
    ## record — its session is now an orphan — and keep ticking. The failing
    ## record keeps the tick non-idle, and the orphan must age out.
    let tempRoot = getTempDir() / "reapprod-orphan-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))
    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()

    let provider = buildProvider(tempRoot)
    let storeRoot = tempRoot / "state"
    let store = openStateStore(storeRoot)
    let past = getTime() - initDuration(hours = 1)
    let missing = tempRoot / "never-built-provider"
    check not fileExists(extendedPath(missing))

    proc orphanRecord(address, typeId, artifactId, binaryPath: string):
        ResourceStateRecord =
      ResourceStateRecord(
        address: address, typeId: typeId, determinism: rdVolatile,
        attrsTypeId: typeId, attrsJson: "\x01\x00\x00\x00\x00\x00",
        dependsOn: @[], identity: "stub:" & address, present: true,
        holders: initTable[string, Time](), keepHolders: @[],
        keepHoldersKnown: true,
        effectiveDeadline: some(past), lastRenewed: past,
        providerArtifact: some(ResourceProviderArtifactRef(
          binaryPath: binaryPath, providerArtifactId: artifactId,
          workingDir: getCurrentDir())))

    writeStateRecord(store, orphanRecord("rec-live", "reapprod.liveT",
      "art-live", provider.binary))
    writeStateRecord(store, orphanRecord("rec-stale", "reapprod.staleT",
      "art-stale", missing))

    # Tick one: the live artifact opens a session; the stale one cannot.
    let first = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 1))
    check first.failedCount == 2
    check leaseReapSessionCount() == 1
    # THE BOOKKEEPING TRACKS ONLY WHAT IT HOLDS. `art-stale` never opened a
    # session, so it must not have an idleness entry: a store can hold a
    # never-launchable record indefinitely (§4.5 leaves it for a later sweep),
    # and a daemon iterating on a provider meets a new id per rebuild, so an
    # entry per ATTEMPTED id would grow a string per failed launch for the
    # daemon's life.
    check leaseReapPooledArtifactIds() == @["art-live"]

    # `rec-live` leaves the store — reaped by another sweep, or its provider
    # rebuilt under a new id. Its session is now an ORPHAN: nothing references
    # `art-live` any more.
    removeStateRecord(store, "rec-live")
    check providerArtifactsOfRecords(listStateRecords(store)).len == 1

    # Keep ticking. Every tick ATTEMPTS the stale artifact and opens nothing,
    # so `used` is empty — and that must still age the orphan. Under the old
    # rule the stale id counted as used and the orphan was pinned forever.
    for i in 0 ..< LeaseReapSessionIdleTickLimit:
      let tick = runAndRecordLeaseReapTick(dlsUser, overrideRoot = storeRoot,
        now = past + initDuration(minutes = i + 2))
      check not tick.raised
      check tick.failedCount == 1              # the stale record, still stuck
      # ...and it never accumulates bookkeeping, however many ticks retry it.
      check "art-stale" notin leaseReapPooledArtifactIds()
    check leaseReapSessionCount() == 0         # the orphan was dropped
    # Evicting the orphan drops its entry too, so the table does not outlive
    # the session it described.
    check leaseReapPooledArtifactIds().len == 0

    # The stuck record is still in the store, as §4.5 requires.
    check hasStateRecord(store, "rec-stale")

    # A genuinely IDLE tick must not age anything: with the store emptied,
    # nothing is attempted, so a pool (re)built by a later tick survives quiet
    # periods. Asserted on the tick's own outcome, since the pool is empty here.
    removeStateRecord(store, "rec-stale")
    let idle = runAndRecordLeaseReapTick(dlsUser,
      overrideRoot = storeRoot, now = past + initDuration(minutes = 30))
    check not idle.raised
    check idle.reapedCount == 0
    check idle.failedCount == 0

## Shared-Development-Services **D-SS10** (§7.1) — THE READINESS EDGE: a
## registration resource ordered on a service node whose COMPLETION IS ITS
## DECLARED READINESS, not its materialisation.
##
## The clause this file exists for, quoted from §7.1:
##
##   > So `dependsOn` onto a service already means *after readiness*, not
##   > after materialisation, wherever a readiness probe is declared. [...]
##   > what was missing was saying that a service node's **completion is
##   > its declared readiness**, and that is now said here.
##
## and the two shapes the decision makes illegal rather than discouraged:
## a registration ordered on a `readiness none` service, and an early read
## of the computed attribute.
##
## § WHAT MAKES THE ORDERING CASE A REAL TEST RATHER THAN A RESTATEMENT
##
## The weak version of this test would materialise, then probe, then
## assert the probe was satisfied — which passes for any implementation
## that does the two in that order, including one whose "probe" is a
## no-op. The case below is built so the two are SEPARABLE IN TIME and the
## separation is produced by a real process:
##
##   1. a REAL detached child process is started (`/bin/sh`), which sleeps
##      and only THEN touches the readiness marker;
##   2. the moment the child exists is recorded in the event log as
##      `service.materialised` — the fact the daemon's `Materialise ok`
##      corresponds to;
##   3. `reconcileResources` is then run over the real two-node plan.
##
## If completion meant materialisation, `registration.reconciled` would
## appear in the log while the marker still did not exist. The assertions
## are therefore: the marker did NOT exist at step 2, `registration
## .reconciled` appears AFTER `service.readiness.satisfied`, and the
## reconcile really did wait (the recorded `waitedMs` is non-zero).
##
## ORDER IS READ FROM THE EVENT LOG'S LINE ORDER, not from a clock this
## test keeps. `events.jsonl` is append-only and is written by the
## production sink the CLI installs; comparing two timestamps the test
## itself took would be comparing the test's own bookkeeping, which can
## agree with the test while the product disagrees.
##
## § MOCK POLICY — THREE INJECTED COLLABORATORS, EACH JUSTIFIED, NO MOCKS
##
## 1. `ServiceRegistrar`. There is no OIDC client and no identity provider
##    in this repository, so the real registrar does not exist to be
##    called — L9 owns the shared identity provider and D-SS10 explicitly
##    does not require one. The injection is also the PRODUCTION shape:
##    `repro_cli_support` installs its own registrar at the converge site,
##    exactly as the daemon installs the real liveness probe into
##    `ServiceInstanceRegistry.probe`. The registrar here records WHEN it
##    ran, which is the question the ordering clause asks and which a real
##    registrar could not be asked.
## 2. `ReadinessEdgeEventSink`. Not a double at all: it is the real
##    append-only writer, pointed at a real file in a real temp directory.
##    The CLI's sink appends to the dev session's `events.jsonl`; this one
##    appends to a file of the same shape, because `repro_resources` must
##    not import the CLI.
## 3. `ServiceReadinessProber`. Used by ONE case only (the "no prober
##    installed is a refusal" control). Every ordering case uses a
##    `fileExists` probe, which this library evaluates against the REAL
##    filesystem with no injection at all.
##
## Everything else is real: a real detached child process, a real
## filesystem, the real `reconcileResources` / `topoOrder`, the real
## providers registered by `readiness_edge.nim`'s module init.

import std/[algorithm, json, os, osproc, strutils, tables, unittest]

import repro_resources
import repro_resources/readiness_edge

const
  Svc = "sso"
  Instance = "service:workspace:dss10:development:stable:com.example.dss10"
  Members = ["codetracer-cli", "isonim-site"]
  Contributors = ["codetracer", "isonim"]
  ## How long the fixture child sleeps before touching the marker. Long
  ## enough that a reconcile which did not wait cannot pass by luck, short
  ## enough not to dominate the suite.
  MarkerDelaySeconds = 2

type
  Scratch = object
    root: string
    marker: string
    eventLog: string

proc newScratch(tag: string): Scratch =
  let root = getTempDir() / ("dss10-" & tag & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  Scratch(root: root, marker: root / "idp.ready",
    eventLog: root / "events.jsonl")

proc drop(s: Scratch) =
  try: removeDir(s.root)
  except CatchableError: discard

proc installSink(s: Scratch) =
  ## The real append-only writer, in the shape
  ## `appendSessionEvent` writes: one JSON object per line, in append
  ## order. `repro_resources` cannot import `repro_cli_support` (the
  ## dependency runs the other way), so the writer is spelled here rather
  ## than imported — the SHAPE is what the assertions read, and it is the
  ## same shape.
  let path = s.eventLog
  setReadinessEdgeEventSink(
    proc (kind, service, detail: string) {.closure.} =
      let line = $(%*{"kind": kind, "service": service, "detail": detail})
      if fileExists(path): writeFile(path, readFile(path) & line & "\n")
      else: writeFile(path, line & "\n"))

proc appendEvent(s: Scratch; kind, service, detail: string) =
  ## The test's own writer for the ONE fact the providers do not publish:
  ## that the instance has been materialised. In production that line is
  ## written by the CLI from the daemon's converge answer; here the
  ## detached child standing in for the instance is started by this file,
  ## so this file records it. It goes through the same append-only file so
  ## the ORDER is read from one log.
  let line = $(%*{"kind": kind, "service": service, "detail": detail})
  if fileExists(s.eventLog):
    writeFile(s.eventLog, readFile(s.eventLog) & line & "\n")
  else:
    writeFile(s.eventLog, line & "\n")

proc eventKinds(s: Scratch): seq[string] =
  result = @[]
  if not fileExists(s.eventLog):
    return
  for line in readFile(s.eventLog).splitLines():
    if line.strip().len == 0:
      continue
    result.add(parseJson(line){"kind"}.getStr(""))

proc eventDetail(s: Scratch; kind: string): string =
  if not fileExists(s.eventLog):
    return ""
  for line in readFile(s.eventLog).splitLines():
    if line.strip().len == 0:
      continue
    let node = parseJson(line)
    if node{"kind"}.getStr("") == kind:
      return node{"detail"}.getStr("")
  ""

proc indexOfKind(kinds: seq[string]; kind: string): int =
  for i, k in kinds:
    if k == kind:
      return i
  -1

proc fileProbe(s: Scratch; timeoutMs = 20_000): ServiceReadinessProbe =
  ServiceReadinessProbe(kind: "fileExists", path: s.marker,
    timeoutMs: timeoutMs)

proc startDelayedMarkerChild(s: Scratch): Process =
  ## A REAL detached child that sleeps and then writes the marker — the
  ## fixture's stand-in for "the server writes its readiness marker LAST,
  ## after it has finished seeding". A `sleep` inside this test process
  ## would not do: the point is that the marker's appearance is outside
  ## this process's control, exactly as a real instance's is.
  startProcess("/bin/sh",
    args = @["-c", "sleep " & $MarkerDelaySeconds & "; : > " &
      quoteShell(s.marker)],
    options = {poUsePath})

proc registrarRecording(ran: ref seq[string]): ServiceRegistrar =
  ## Records the member set it was asked for and mints a deterministic
  ## identifier per member. Deterministic because the property under test
  ## is ORDER, not identity — L8's suite owns mint-once.
  result = proc (attrs: ServiceRegistrationAttrs):
      seq[tuple[member, mintedId: string]] {.closure.} =
    result = @[]
    for m in attrs.members:
      ran[].add(m)
      result.add((member: m, mintedId: "client-" & m))

suite "D-SS10 — the plan is two nodes and an ordinary dependsOn":

  test "the registration's only ordering edge is dependsOn the service node":
    # The STRUCTURAL claim, asserted on the graph rather than on timing:
    # §7.1 resolved the edge as "an ordinary `dependsOn` onto the service
    # node", and the thing that would falsify it is a plan that carries
    # the ordering some other way (a `consumes` lease, or no edge at all
    # with the sequencing left to a loop).
    let s = newScratch("plan")
    defer: s.drop()
    let plan = planRegistrationEdge(Svc, Instance, fileProbe(s),
      Members, Contributors)
    check plan.len == 2
    let node = plan[0]
    let reg = plan[1]
    check node.address == serviceNodeAddress(Instance)
    check reg.address == registrationResourceAddress(Instance)
    check node.dependsOn.len == 0
    check reg.dependsOn == @[serviceNodeAddress(Instance)]
    # Not a lease. A leased `stateGroup` is the alternative §7.1 rejected
    # for conflating lifetime with ordering, so a plan that quietly used
    # one would be implementing the losing option.
    check reg.consumes.len == 0
    check node.consumes.len == 0

  test "topoOrder puts the service node before the registration":
    # `topoOrder` is the thing that enforces the order, so it is the thing
    # asserted on. A plan whose edge were dropped would still reconcile in
    # authored order and pass a looser test.
    let s = newScratch("topo")
    defer: s.drop()
    let ordered = topoOrder(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    check ordered.len == 2
    check ordered[0].address == serviceNodeAddress(Instance)
    check ordered[1].address == registrationResourceAddress(Instance)

  test "the order survives the plan being handed over REVERSED":
    # WRITTEN BECAUSE A MUTATION SURVIVED. Removing `dependsOn` from the
    # plan altogether left the two cases above green: `topoOrder` visits
    # `desired` in AUTHORED order, `planRegistrationEdge` authors the
    # service node first, and `reconcileResources` iterates what
    # `topoOrder` returns -- so authored order and topological order
    # coincided and neither case could tell the edge from the layout.
    #
    # Reversing the plan separates them. With the edge, `topoOrder` must
    # still visit the node first; without it, the registration would be
    # reconciled BEFORE the service's readiness was ever awaited, which
    # is the whole defect D-SS10 closes. This is the case that makes the
    # ordering a structural guarantee rather than a property of the
    # order the plan happens to be written in.
    let s = newScratch("reversed")
    defer: s.drop()
    var plan = planRegistrationEdge(Svc, Instance, fileProbe(s),
      Members, Contributors)
    reverse(plan)
    check plan[0].address == registrationResourceAddress(Instance)
    let ordered = topoOrder(plan)
    check ordered[0].address == serviceNodeAddress(Instance)
    check ordered[1].address == registrationResourceAddress(Instance)

  test "a reversed plan still waits for readiness before registering":
    # The same separation, driven through the real reconcile rather than
    # through `topoOrder` alone: the registrar must not have run while
    # the marker was absent.
    let s = newScratch("reversedrun")
    defer: s.drop()
    s.installSink()
    var ran = new(seq[string])
    ran[] = @[]
    setServiceRegistrar(registrarRecording(ran))
    defer: clearReadinessEdgeCollaborators()
    var plan = planRegistrationEdge(Svc, Instance, fileProbe(s),
      Members, Contributors)
    reverse(plan)
    let child = s.startDelayedMarkerChild()
    s.appendEvent("service.materialised", Svc, "pid=" & $child.processID())
    check not fileExists(s.marker)
    discard reconcileResources(plan)
    discard child.waitForExit()
    child.close()
    check ran[].len == 2
    let kinds = s.eventKinds()
    check kinds.indexOfKind("service.readiness.satisfied") >= 0
    check kinds.indexOfKind("registration.reconciled") >
      kinds.indexOfKind("service.readiness.satisfied")

  test "the registration address is the one the store record already names":
    # §7.1's title: "the readiness edge is the one that already exists".
    # `writeServiceRegistrations` has always written its record with
    # `dependsOn: @[serviceInstanceAddress(key)]`; if this module invented
    # a second spelling of the registration's address, the edge made
    # operative here would not be that one.
    check registrationResourceAddress(Instance) ==
      Instance & "/registrations"

suite "D-SS10 — completion is the DECLARED READINESS, not materialisation":

  test "the registration reconciles after the probe succeeds, not after the child exists":
    let s = newScratch("order")
    defer: s.drop()
    s.installSink()
    var ran = new(seq[string])
    ran[] = @[]
    setServiceRegistrar(registrarRecording(ran))
    defer: clearReadinessEdgeCollaborators()

    let child = s.startDelayedMarkerChild()
    # The instance EXISTS. This is the moment the daemon answers
    # `Materialise ok`, and the whole point of the case is that the marker
    # is not there yet.
    s.appendEvent("service.materialised", Svc, "pid=" & $child.processID())
    check not fileExists(s.marker)
    check ran[].len == 0

    let res = reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    discard child.waitForExit()
    child.close()

    # The registration really ran, and ran once.
    check ran[] == @[Members[0], Members[1]]
    check res.actions.len == 2

    # THE ORDER, read from the log's own line order.
    let kinds = s.eventKinds()
    let iMat = kinds.indexOfKind("service.materialised")
    let iWait = kinds.indexOfKind("service.readiness.waiting")
    let iReady = kinds.indexOfKind("service.readiness.satisfied")
    let iReg = kinds.indexOfKind("registration.reconciled")
    checkpoint("event kinds in log order: " & kinds.join(", "))
    check iMat >= 0
    check iWait > iMat
    check iReady > iWait
    check iReg > iReady

    # AND IT REALLY WAITED. Without this, an implementation that probed
    # once, found the marker and carried on would satisfy the order above
    # on a run where the child happened to win the race. `waitedMs` is
    # the service node's own report of how long it blocked.
    let readyDetail = s.eventDetail("service.readiness.satisfied")
    checkpoint("readiness detail: " & readyDetail)
    check readyDetail.contains("waitedMs=")
    var waitedMs = -1
    for part in readyDetail.split(' '):
      if part.startsWith("waitedMs="):
        waitedMs = parseInt(part[len("waitedMs=") .. ^1])
    check waitedMs >= MarkerDelaySeconds * 1000 - ReadinessPollIntervalMs

  test "an already-satisfied probe is the fast path and waits for nothing":
    # The positive control for the case above: the wait is a consequence
    # of the probe, not an unconditional sleep. A service whose marker is
    # already there must reconcile its registration with no wait at all --
    # which is what makes an ATTACH to a running instance cheap.
    let s = newScratch("fast")
    defer: s.drop()
    s.installSink()
    var ran = new(seq[string])
    ran[] = @[]
    setServiceRegistrar(registrarRecording(ran))
    defer: clearReadinessEdgeCollaborators()
    writeFile(s.marker, "")
    let res = reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    check ran[].len == 2
    # `rakNoOp` on the node is the observable difference: `observe` found
    # the probe satisfied, so `apply` -- the thing that waits -- was never
    # reached, and no readiness event was published.
    check res.actions[0].kind == rakNoOp
    let kinds = s.eventKinds()
    check kinds.indexOfKind("service.readiness.waiting") < 0
    check kinds.indexOfKind("registration.reconciled") >= 0

  test "a probe that never succeeds refuses, and the registration never runs":
    let s = newScratch("timeout")
    defer: s.drop()
    s.installSink()
    var ran = new(seq[string])
    ran[] = @[]
    setServiceRegistrar(registrarRecording(ran))
    defer: clearReadinessEdgeCollaborators()
    var message = ""
    try:
      discard reconcileResources(planRegistrationEdge(Svc, Instance,
        fileProbe(s, timeoutMs = 200), Members, Contributors))
      check false  # unreachable: the probe cannot succeed, nothing writes it
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("did not COMPLETE")
    check message.contains(Svc)
    # The downstream node was never reached. This is the property the
    # whole edge exists for: a half-configured issuer gets no
    # registrations rather than wrong ones.
    check ran[].len == 0
    check s.eventKinds().indexOfKind("registration.reconciled") < 0

suite "D-SS10 — `readiness none` cannot order a registration":

  test "a readiness none service is refused BY NAME":
    let s = newScratch("none")
    defer: s.drop()
    var message = ""
    try:
      discard planRegistrationEdge(Svc, Instance,
        ServiceReadinessProbe(kind: "none", timeoutMs: 1000),
        Members, Contributors)
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("service `" & Svc & "`")
    check message.contains("DECLARES NO READINESS")
    check message.contains("`readiness none`")
    # It names the EDGE that would have ordered it, not just the service.
    check message.contains(registrationOrderingEdge(Instance))
    # And it is distinguishable from the EXPANSION-time refusal, the
    # discipline L5 established for its own pair. If the two shared their
    # distinctive sentence a reader could not tell which gate spoke.
    check not message.contains("NOTHING CAN ORDER A REGISTRATION ON IT")

  test "a service that declared no readiness at all is refused too, and says so":
    # Refusing only the spelling an author WROTE DOWN would leave the
    # silent shape legal, which is this campaign's own defect class.
    var message = ""
    try:
      discard planRegistrationEdge(Svc, Instance,
        ServiceReadinessProbe(kind: "", timeoutMs: 1000),
        Members, Contributors)
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("DECLARES NO READINESS")
    check message.contains("no `readiness` setter at all")

  test "an unevaluable readiness kind is refused rather than read as ready":
    var message = ""
    try:
      discard planRegistrationEdge(Svc, Instance,
        ServiceReadinessProbe(kind: "whenTheStarsAlign", timeoutMs: 1000),
        Members, Contributors)
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("whenTheStarsAlign")
    check message.contains("cannot evaluate")

  test "the completion rule is derived from the probe, for every word":
    # The rule as a total function, so a fourth probe kind cannot be added
    # to the DSL and silently default to one side.
    check serviceCompletionRule(ServiceReadinessProbe(kind: "")) ==
      scrUndeclared
    check serviceCompletionRule(ServiceReadinessProbe(kind: "none")) ==
      scrExplicitlyNone
    check serviceCompletionRule(
      ServiceReadinessProbe(kind: "fileExists")) == scrDeclaredReadiness
    check serviceCompletionRule(
      ServiceReadinessProbe(kind: "httpGet")) == scrDeclaredReadiness
    check ordersRegistrations(ServiceReadinessProbe(kind: "httpGet"))
    check not ordersRegistrations(ServiceReadinessProbe(kind: "none"))

suite "D-SS10 — an early read refuses, and never answers nil or empty":

  test "reading an uncomputed attribute names attribute, resource AND edge":
    let s = newScratch("early")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    let address = computedClientIdAddress(Instance, Members[0])
    check not computedResourceAttributeIsAvailable(address,
      ClientIdAttributeName)
    var message = ""
    var answered = "SENTINEL"
    try:
      answered = readComputedResourceAttribute(address,
        ClientIdAttributeName, Instance)
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    # §7.1's three names.
    check message.contains("`" & ClientIdAttributeName & "`")   # attribute
    check message.contains("`" & address & "`")                 # resource
    check message.contains(registrationOrderingEdge(Instance))  # edge
    check message.contains("DECLARED READINESS")
    # AND SPECIFICALLY NOT nil OR "". The sentinel is what distinguishes
    # "it refused" from "it returned the empty string and the except arm
    # never ran" -- a distinction a bare `expect` cannot make, and the one
    # D-SS10 names as the answer that must not be chosen.
    check answered == "SENTINEL"
    check answered.len > 0

  test "a computed attribute read AFTER the reconcile yields the value":
    let s = newScratch("late")
    defer: s.drop()
    s.installSink()
    var ran = new(seq[string])
    ran[] = @[]
    setServiceRegistrar(registrarRecording(ran))
    defer: clearReadinessEdgeCollaborators()
    writeFile(s.marker, "")
    discard reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    for m in Members:
      let address = computedClientIdAddress(Instance, m)
      check computedResourceAttributeIsAvailable(address,
        ClientIdAttributeName)
      check readComputedResourceAttribute(address, ClientIdAttributeName,
        Instance) == "client-" & m

  test "a computed EMPTY value is refused at the write, not stored":
    # D-SS10's prohibition enforced where it can still be attributed: at
    # the read there is nothing left to tell an empty value from one that
    # was never computed, which is the confusion the prohibition exists to
    # prevent.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    var message = ""
    try:
      recordComputedResourceAttribute("r", ClientIdAttributeName, "")
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("EMPTY STRING")
    check not computedResourceAttributeIsAvailable("r",
      ClientIdAttributeName)

  test "a registrar that mints an empty identifier is refused, not recorded":
    let s = newScratch("emptymint")
    defer: s.drop()
    s.installSink()
    setServiceRegistrar(
      proc (attrs: ServiceRegistrationAttrs):
          seq[tuple[member, mintedId: string]] {.closure.} =
        @[(member: attrs.members[0], mintedId: "")])
    defer: clearReadinessEdgeCollaborators()
    writeFile(s.marker, "")
    var message = ""
    try:
      discard reconcileResources(planRegistrationEdge(Svc, Instance,
        fileProbe(s), Members, Contributors))
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("EMPTY STRING")

suite "D-SS10 — the installed collaborators fail closed":

  test "an httpGet probe with no prober installed refuses, never reads ready":
    # The near-miss this guard exists for: a hook whose absence counted as
    # success would put the listening-but-unseeded race back inside
    # D-SS10's own fix.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    var message = ""
    try:
      discard readinessSatisfied(ServiceReadinessProbe(kind: "httpGet",
        url: "http://127.0.0.1:1/", timeoutMs: 100))
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("no prober is installed")

  test "an installed prober decides the httpGet probe, both ways":
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    setServiceReadinessProber(proc (url: string): bool {.closure.} = false)
    check not readinessSatisfied(ServiceReadinessProbe(kind: "httpGet",
      url: "http://127.0.0.1:1/"))
    setServiceReadinessProber(proc (url: string): bool {.closure.} = true)
    check readinessSatisfied(ServiceReadinessProbe(kind: "httpGet",
      url: "http://127.0.0.1:1/"))

  test "a registration with no registrar installed refuses, never silently registers nothing":
    let s = newScratch("noreg")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    writeFile(s.marker, "")
    var message = ""
    try:
      discard reconcileResources(planRegistrationEdge(Svc, Instance,
        fileProbe(s), Members, Contributors))
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("no registrar is installed")

  test "a probeless service is never reported satisfied by the probe itself":
    # Two guards, not one. `planRegistrationEdge` refuses a probeless
    # service, and `readinessSatisfied` also declines to call one ready --
    # so a future caller that reaches the predicate without going through
    # the plan does not get a free pass.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    check not readinessSatisfied(ServiceReadinessProbe(kind: "none"))
    check not readinessSatisfied(ServiceReadinessProbe(kind: ""))

  test "a SECOND reconcile still runs the registrar, so a withdrawal happens":
    # The registration resource's `observe` reports ABSENT always, which
    # looks like a missing optimisation and is not. `reconcileService
    # Registrations` is the thing that decides mint-vs-reuse-vs-withdraw,
    # from its own store record. Reporting present-at-digest here would
    # make `decide` answer `rakNoOp` and SKIP it -- and the member set a
    # digest matches is the set THIS RUN asked for, not the set the
    # instance holds, so a member no longer contributed would never be
    # withdrawn. A no-op decided in the wrong place is the silent drop
    # this campaign keeps finding, so the skip is refused by construction
    # and this case is what says so.
    let s = newScratch("second")
    defer: s.drop()
    s.installSink()
    var ran = new(seq[string])
    ran[] = @[]
    setServiceRegistrar(registrarRecording(ran))
    defer: clearReadinessEdgeCollaborators()
    writeFile(s.marker, "")
    let plan = planRegistrationEdge(Svc, Instance, fileProbe(s),
      Members, Contributors)
    discard reconcileResources(plan)
    check ran[].len == 2
    # Same plan, same digest, same bindings carried forward.
    let second = reconcileResources(plan, recorded = @[])
    check second.actions[1].kind != rakNoOp
    check ran[].len == 4

  test "a probe kind reaches the rule case-insensitively":
    # `l9ParseReadinessSetter` records the AUTHOR'S spelling, not a
    # normalised one, and the artifact carries it verbatim. So the rule
    # has to fold case itself; if it did not, a recipe written
    # `readiness FileExists(...)` would reach `scrUndeclared` and be
    # refused as probeless.
    for word in ["fileExists", "fileexists", "FILEEXISTS", "FileExists"]:
      check serviceCompletionRule(ServiceReadinessProbe(kind: word)) ==
        scrDeclaredReadiness
    for word in ["none", "None", "NONE"]:
      check serviceCompletionRule(ServiceReadinessProbe(kind: word)) ==
        scrExplicitlyNone

  test "a plan with no members still reconciles, so a withdrawal can happen":
    # The empty member set is not an error and must not short-circuit:
    # `reconcileServiceRegistrations` removes a member no longer
    # contributed, so the run that withdraws the LAST one carries no
    # members at all. A plan that skipped the registration when
    # `members.len == 0` would leave last week's registration in place
    # with nothing asking for it.
    let s = newScratch("nomembers")
    defer: s.drop()
    s.installSink()
    var calls = new(seq[string])
    calls[] = @[]
    setServiceRegistrar(
      proc (attrs: ServiceRegistrationAttrs):
          seq[tuple[member, mintedId: string]] {.closure.} =
        calls[].add("called with " & $attrs.members.len)
        @[])
    defer: clearReadinessEdgeCollaborators()
    writeFile(s.marker, "")
    discard reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), [], []))
    check calls[] == @["called with 0"]

  test "members and contributors must be parallel":
    let s = newScratch("arity")
    defer: s.drop()
    var message = ""
    try:
      discard planRegistrationEdge(Svc, Instance, fileProbe(s),
        Members, ["only-one"])
      check false  # unreachable
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("parallel by construction")

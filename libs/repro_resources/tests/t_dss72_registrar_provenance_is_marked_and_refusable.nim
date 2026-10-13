## Shared-Development-Services **§7.2** — A DEVELOPMENT REGISTRAR MARKS WHAT
## IT PRODUCED, A CONSUMER THAT NEEDS THE ISSUER'S CAN REFUSE IT BY ASKING,
## AND WHICH REGISTRAR IS INSTALLED REACHES THE SESSION EVENT LOG.
##
## The clause, quoted:
##
##   > The CLI currently installs a registrar that derives an id from a local
##   > digest (`blake3DomainDigest(…)[0 ..< 24]`). That is a reasonable
##   > *development* registrar [...] and it is also **indistinguishable, at
##   > the point of use, from an id a real issuer minted.** A consumer
##   > receives a well-formed identifier that no issuer has ever heard of,
##   > and the failure arrives later, somewhere else, as an authentication
##   > error.
##
##   > - A development registrar must **mark what it produced**, and a
##   >   consumer that requires an issuer-minted id must be able to **refuse**
##   >   a development one by asking. Not a naming convention — a fact carried
##   >   with the value, like the provenance stamp §4.3's precondition reads.
##   > - Which registrar is installed must appear in the session's event log
##   > - The development registrar stays the default [...] It is the
##   >   *silence* that is wrong, not the fallback.
##
## § WHAT MAKES THESE REAL TESTS RATHER THAN RESTATEMENTS
##
## The weak version of "the value is marked" asserts that a field exists and
## holds the word the test just put there. Every case below instead drives the
## **real providers** through the **real `reconcileResources`** over a real
## two-node plan with a real readiness marker on a real filesystem, and reads
## the stamp back through the production accessor. What a value carries is
## therefore decided by the code path `repro up` takes, not by the test's own
## bookkeeping.
##
## THE DISTINGUISHABILITY CASE DELIBERATELY USES THE SAME IDENTIFIER TEXT for
## the development and the issuer registrar. If the two registrars minted
## different-looking ids, a test could "tell them apart" by reading the string
## — which is the naming convention §7.2 rules out, and which would pass for
## an implementation that carried no stamp at all. Identical text means the
## only thing that can answer the question is the stamp.
##
## THE EVENT-LOG CASE IS RUN IN BOTH INSTALL ORDERS, and that is the near-miss
## this file was written around rather than a thoroughness flourish. The sink
## and the registrar are two independent installs; an announcement published
## only from `setServiceRegistrar` is silently dropped on every call site that
## installs the sink second, which is a fact that is computed, correct, and
## reaches no reader — this campaign's dominant defect class. Both orders are
## asserted, and `announceInstalledRegistrar` is called from both setters for
## that reason.
##
## § MOCK POLICY — TWO INJECTED COLLABORATORS, NO MOCKS
##
## 1. `ServiceRegistrar`. Injected because that is the PRODUCTION shape:
##    §7.2 settles that "reprobuild ships no product registrar" and that the
##    owning project supplies the implementation through
##    `setServiceRegistrar`. There is no OIDC client in this repository to
##    call, by design. The registrars here are not doubles of a real one —
##    they are two real registrars of the two kinds the clause distinguishes,
##    and what is under test is what the LIBRARY attaches to their output.
## 2. `ReadinessEdgeEventSink`. Not a double at all: a real append-only
##    writer pointed at a real file in a real temp directory, in the same
##    one-JSON-object-per-line shape `appendSessionEvent` writes.
##    `repro_resources` cannot import `repro_cli_support` — the dependency
##    runs the other way — so the writer is spelled here; the SHAPE is what
##    the assertions read.
##
## Nothing else is substituted. `fileExists` probes a real marker, the
## resource lane is the real one, and every refusal asserted is raised by
## product code.

import std/[json, os, strutils, unittest]

import repro_resources
import repro_resources/readiness_edge

const
  Svc = "idp"
  Instance = "service-instance:com.example.dss72.idp#workspace#dev"
  Members = ["dss72-alpha", "dss72-beta"]
  Contributors = ["pkg-alpha", "pkg-beta"]
  Sentinel = "\u0001SENTINEL-NOT-OVERWRITTEN"
    ## Used instead of a bare `expect`: `expect` cannot tell "it refused"
    ## from "it returned `\"\"` and the except arm never ran", and the
    ## second is precisely the defect D-SS10 and §7.2 both name.
  IssuerRegistrarName = "external:/opt/example/register-rp"
  SharedIdText = "394610871109772528"
    ## ONE id text for both registrars. See the header: different-looking
    ## ids would let a test distinguish them by inspecting the string.

type
  Scratch = object
    root: string
    marker: string
    eventLog: string

proc newScratch(tag: string): Scratch =
  let root = getTempDir() / ("dss72-" & tag & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  Scratch(root: root, marker: root / "idp.ready",
    eventLog: root / "events.jsonl")

proc drop(s: Scratch) =
  try: removeDir(s.root)
  except CatchableError: discard

proc appendLine(path, kind, service, detail: string) =
  let line = $(%*{"kind": kind, "service": service, "detail": detail})
  if fileExists(path): writeFile(path, readFile(path) & line & "\n")
  else: writeFile(path, line & "\n")

proc installSink(s: Scratch) =
  let path = s.eventLog
  setReadinessEdgeEventSink(
    proc (kind, service, detail: string) {.closure.} =
      appendLine(path, kind, service, detail))

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

proc countOfKind(s: Scratch; kind: string): int =
  for k in s.eventKinds():
    if k == kind:
      inc result

proc fileProbe(s: Scratch; timeoutMs = 20_000): ServiceReadinessProbe =
  ServiceReadinessProbe(kind: "fileExists", path: s.marker,
    timeoutMs: timeoutMs)

proc flatRegistrar(): ServiceRegistrar =
  ## Answers the SAME identifier text for every member, whichever kind of
  ## registrar it is installed as. See `SharedIdText`.
  result = proc (attrs: ServiceRegistrationAttrs):
      seq[tuple[member, mintedId: string]] {.closure.} =
    result = @[]
    for m in attrs.members:
      result.add((member: m, mintedId: SharedIdText))

proc convergeWith(s: Scratch; identity: ServiceRegistrarIdentity) =
  ## Drive the REAL resource lane once, with `identity` installed.
  writeFile(s.marker, "")
  setServiceRegistrar(flatRegistrar(), identity)
  discard reconcileResources(planRegistrationEdge(Svc, Instance,
    fileProbe(s), Members, Contributors))

suite "§7.2 — the mark is carried with the value, not inferred from it":

  test "a development registrar's value is stamped `development`":
    let s = newScratch("devstamp")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    s.convergeWith(developmentRegistrarIdentity)
    for m in Members:
      let stamp = computedResourceAttributeStamp(
        computedClientIdAddress(Instance, m), ClientIdAttributeName,
        Instance)
      check stamp.value == SharedIdText
      check stamp.provenance == rprDevelopment
      check stamp.registrar == DevelopmentRegistrarName

  test "an issuer registrar's value is stamped `issuer`, same id text":
    # THE DISTINGUISHABILITY CLAUSE. The identifier text is byte-identical
    # to the development case above, so nothing about the STRING can tell
    # the two apart; only the stamp can. An implementation that carried no
    # provenance would make these two cases agree, which is exactly §7.2's
    # "indistinguishable, at the point of use".
    let s = newScratch("issuerstamp")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    s.convergeWith(ServiceRegistrarIdentity(name: IssuerRegistrarName,
      provenance: rprIssuer))
    for m in Members:
      let stamp = computedResourceAttributeStamp(
        computedClientIdAddress(Instance, m), ClientIdAttributeName,
        Instance)
      check stamp.value == SharedIdText
      check stamp.provenance == rprIssuer
      check stamp.registrar == IssuerRegistrarName

  test "with no registrar identity declared the value is `unstamped`":
    # The one-argument `setServiceRegistrar` is the shape a forgetful
    # install site has. It must not read as either of the other two.
    let s = newScratch("nostamp")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    writeFile(s.marker, "")
    setServiceRegistrar(flatRegistrar())
    discard reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    let stamp = computedResourceAttributeStamp(
      computedClientIdAddress(Instance, Members[0]), ClientIdAttributeName,
      Instance)
    check stamp.provenance == rprUnstamped
    check stamp.registrar == unstampedRegistrarIdentity.name

  test "the stamp comes from the installed registrar, not from the caller":
    # `recordComputedResourceAttribute` takes no provenance argument, so a
    # provider cannot record a value under a provenance its install site
    # never declared. Asserted by recording through the plain API under
    # each identity and reading the stamp back.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    setServiceRegistrar(flatRegistrar(), developmentRegistrarIdentity)
    recordComputedResourceAttribute("r-dev", ClientIdAttributeName, "x")
    check computedResourceAttributeStamp("r-dev", ClientIdAttributeName,
      Instance).provenance == rprDevelopment
    setServiceRegistrar(flatRegistrar(),
      ServiceRegistrarIdentity(name: IssuerRegistrarName,
        provenance: rprIssuer))
    recordComputedResourceAttribute("r-iss", ClientIdAttributeName, "x")
    check computedResourceAttributeStamp("r-iss", ClientIdAttributeName,
      Instance).provenance == rprIssuer
    # And the earlier value did NOT move when the registrar changed: a
    # stamp is attached at the write, not looked up at the read.
    check computedResourceAttributeStamp("r-dev", ClientIdAttributeName,
      Instance).provenance == rprDevelopment

  test "clearing the collaborators resets the identity to unstamped":
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    setServiceRegistrar(flatRegistrar(), developmentRegistrarIdentity)
    check installedServiceRegistrarIdentity() == developmentRegistrarIdentity
    clearReadinessEdgeCollaborators()
    check installedServiceRegistrarIdentity() == unstampedRegistrarIdentity

suite "§7.2 — a consumer that requires the issuer's refuses by ASKING":

  test "an issuer-minted value is returned by the issuer-requiring read":
    let s = newScratch("issuerread")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    s.convergeWith(ServiceRegistrarIdentity(name: IssuerRegistrarName,
      provenance: rprIssuer))
    check readIssuerMintedResourceAttribute(
      computedClientIdAddress(Instance, Members[0]), ClientIdAttributeName,
      Instance) == SharedIdText

  test "a development value is REFUSED, naming what it got and what it needed":
    let s = newScratch("devrefuse")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    s.convergeWith(developmentRegistrarIdentity)
    let address = computedClientIdAddress(Instance, Members[0])
    # The permissive read still answers -- the offline path is not
    # removed, which is §7.2's fourth bullet.
    check readComputedResourceAttribute(address, ClientIdAttributeName,
      Instance) == SharedIdText
    var message = ""
    var answered = Sentinel
    try:
      answered = readIssuerMintedResourceAttribute(address,
        ClientIdAttributeName, Instance)
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    # IT REFUSED -- it did not return the value, and it did not return "".
    check answered == Sentinel
    # WHAT IT GOT, WHAT PRODUCED IT, AND WHAT IT NEEDED.
    check message.contains("`" & $rprDevelopment & "`")
    check message.contains("`" & DevelopmentRegistrarName & "`")
    check message.contains("`" & $rprIssuer & "`")
    check message.contains("WAS NOT MINTED BY AN ISSUER")
    # And the remedy §7.2 names: the owning project supplies the registrar.
    check message.contains("setServiceRegistrar")

  test "an unstamped value is refused too, and not assumed either way":
    let s = newScratch("unstampedrefuse")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    writeFile(s.marker, "")
    setServiceRegistrar(flatRegistrar())
    discard reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    var message = ""
    var answered = Sentinel
    try:
      answered = readIssuerMintedResourceAttribute(
        computedClientIdAddress(Instance, Members[0]),
        ClientIdAttributeName, Instance)
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check answered == Sentinel
    check message.contains("NOTHING CLAIMED")
    check message.contains("`" & $rprUnstamped & "`")

  test "asking about an UNCOMPUTED attribute refuses with D-SS10's three names":
    # The stamp reader must not become a second, more permissive route to
    # an uncomputed attribute. It is routed through
    # `readComputedResourceAttribute`, so the refusal is the same one.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    let address = computedClientIdAddress(Instance, "never-registered")
    var message = ""
    var answered = Sentinel
    try:
      answered = computedResourceAttributeStamp(address,
        ClientIdAttributeName, Instance).value
    except ReadinessEdgeError as err:
      message = err.msg
    checkpoint(message)
    check answered == Sentinel
    check message.contains("IS NOT COMPUTED YET")
    check message.contains(registrationOrderingEdge(Instance))

suite "§7.2 — a development registrar cannot claim another provenance":

  test "installing the development registrar as the issuer's is REFUSED":
    # The direct form of the clause: "a development one must not pass for
    # the issuer's". Enforced at the install site rather than trusted,
    # because the install site is the only place the claim is made.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    for claimed in [rprIssuer, rprUnstamped]:
      var message = ""
      var refused = false
      try:
        setServiceRegistrar(flatRegistrar(),
          ServiceRegistrarIdentity(name: DevelopmentRegistrarName,
            provenance: claimed))
      except ReadinessEdgeError as err:
        refused = true
        message = err.msg
      checkpoint($claimed & ": " & message)
      check refused
      check message.contains(DevelopmentRegistrarName)
      check message.contains("`" & $claimed & "`")
      # And it did NOT take effect.
      check installedServiceRegistrarIdentity() != ServiceRegistrarIdentity(
        name: DevelopmentRegistrarName, provenance: claimed)

  test "a registrar installed with an EMPTY name is refused":
    # §7.2 asks the event log to say which registrar is installed. A
    # nameless one makes that line say nothing, which is the silence the
    # clause removes.
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    var message = ""
    var refused = false
    try:
      setServiceRegistrar(flatRegistrar(),
        ServiceRegistrarIdentity(name: "", provenance: rprIssuer))
    except ReadinessEdgeError as err:
      refused = true
      message = err.msg
    checkpoint(message)
    check refused
    check message.contains("EMPTY name")

suite "§7.2 — which registrar is installed reaches the session event log":

  test "the registrar is announced when the sink is installed FIRST":
    let s = newScratch("logsinkfirst")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    setServiceRegistrar(flatRegistrar(), developmentRegistrarIdentity)
    check s.countOfKind(RegistrarInstalledEventKind) == 1
    let detail = s.eventDetail(RegistrarInstalledEventKind)
    checkpoint(detail)
    check detail.contains("registrar=" & DevelopmentRegistrarName)
    check detail.contains("provenance=" & $rprDevelopment)

  test "the registrar is announced when the sink is installed SECOND":
    # THE NEAR-MISS. Two independent installs in the opposite order: an
    # announcement published only from `setServiceRegistrar` is dropped
    # here, and the clause's whole purpose -- answering "did this
    # workspace ever talk to an issuer" from the log -- fails silently
    # for every call site that wires the sink last.
    let s = newScratch("logsinksecond")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    setServiceRegistrar(flatRegistrar(),
      ServiceRegistrarIdentity(name: IssuerRegistrarName,
        provenance: rprIssuer))
    check not fileExists(s.eventLog)   # nowhere to publish yet
    s.installSink()
    check s.countOfKind(RegistrarInstalledEventKind) == 1
    let detail = s.eventDetail(RegistrarInstalledEventKind)
    checkpoint(detail)
    check detail.contains("registrar=" & IssuerRegistrarName)
    check detail.contains("provenance=" & $rprIssuer)

  test "a SECOND sink is told too, so a two-service session logs both":
    # THE GAP THE GUARD LEFT, and the reason it survived: deleting the
    # `registrarAnnounced` check reddened NOTHING, because every case
    # here installed one sink.
    #
    # A session that converges two shared services installs a sink per
    # service -- a different session directory each time. With the guard
    # left standing from the first install, the second sink is never
    # announced to, so that service's event log cannot answer "did this
    # workspace talk to an issuer". That is this proc's own documented
    # defect one level down: a fact computed, correct, reaching no
    # reader.
    let first = newScratch("logtwosinksA")
    defer: first.drop()
    let second = newScratch("logtwosinksB")
    defer: second.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    setServiceRegistrar(flatRegistrar(),
      ServiceRegistrarIdentity(name: IssuerRegistrarName,
        provenance: rprIssuer))
    first.installSink()
    check first.countOfKind(RegistrarInstalledEventKind) == 1
    # The second service's sink, same registrar, no re-install of it.
    second.installSink()
    check second.countOfKind(RegistrarInstalledEventKind) == 1
    # And the second log names the registrar that is ACTUALLY installed,
    # not a stale one -- the hazard if the guard were keyed on the
    # announcement rather than on the sink.
    let detail = second.eventDetail(RegistrarInstalledEventKind)
    checkpoint(detail)
    check detail.contains("registrar=" & IssuerRegistrarName)
    check detail.contains("provenance=" & $rprIssuer)
    # The first log did not grow a second line.
    check first.countOfKind(RegistrarInstalledEventKind) == 1

  test "the announcement is made once per install, not once per reconcile":
    # A line repeated per reconcile would make a reader counting
    # registrars wrong, and would say nothing new.
    let s = newScratch("logonce")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    setServiceRegistrar(flatRegistrar(), developmentRegistrarIdentity)
    writeFile(s.marker, "")
    discard reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    discard reconcileResources(planRegistrationEdge(Svc, Instance,
      fileProbe(s), Members, Contributors))
    check s.countOfKind(RegistrarInstalledEventKind) == 1
    # ...and re-installing a DIFFERENT registrar announces again, because
    # that is new information.
    setServiceRegistrar(flatRegistrar(),
      ServiceRegistrarIdentity(name: IssuerRegistrarName,
        provenance: rprIssuer))
    check s.countOfKind(RegistrarInstalledEventKind) == 2

  test "the reconcile's own event names the registrar and the provenance":
    # Beside the counts, per service: a session converging two shared
    # services can have a different answer for each, which the
    # session-wide `registrar.installed` line cannot express.
    let s = newScratch("logreconcile")
    defer: s.drop()
    clearReadinessEdgeCollaborators()
    defer: clearReadinessEdgeCollaborators()
    s.installSink()
    s.convergeWith(developmentRegistrarIdentity)
    let detail = s.eventDetail("registration.reconciled")
    checkpoint(detail)
    check detail.contains("registrar=" & DevelopmentRegistrarName)
    check detail.contains("provenance=" & $rprDevelopment)
    check detail.contains("computed=" & $Members.len)

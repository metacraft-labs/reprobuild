## Shared-Development-Services **D-SS10** (§7.1) — AN EARLY READ OF THE
## COMPUTED ATTRIBUTE REFUSES BY NAME, on the surface that actually
## performs it.
##
## §7.1, "What an early read sees: a refusal, never a value":
##
##   > A staged read of an uncomputed resource attribute reports which
##   > attribute, which resource, and which edge would have ordered it,
##   > in the same shape as §6's refusal for a required configurable that
##   > nothing satisfies. An empty string is indistinguishable from a
##   > legitimately empty value, which is how a silent misconfiguration
##   > becomes a confusing runtime failure somewhere else [...]
##
## The read in question, in the lane that exists, is argv concretization:
## `substituteMintedAttributes` resolves `@minted:<member>@` to what the
## instance minted for that member. Before §7.1 its refusal named the
## member and the registered set — which tells an author WHAT is missing
## but not WHAT WAS SUPPOSED TO PRODUCE IT, and "what orders this" is the
## question an author reading it is actually asking. The cases below
## assert the three names §7.1 requires.
##
## § THE SENTINEL, AND WHY A BARE `expect` WOULD NOT DO
##
## D-SS10 names nil and `""` as the two answers that must not be chosen.
## A test written as `expect ValueError: discard read(...)` cannot tell
## "it refused" from "it returned the empty string and the except arm
## never ran" — and the second is precisely the defect. So each case
## seeds its result with a SENTINEL and asserts the sentinel survived:
## that distinguishes a refusal from any return value, empty or not.
##
## § MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Every case calls the real `substituteMintedAttributes` and the real
## `writeSharedInstanceMinted` / `readSharedInstanceMinted` over a real
## directory on the real filesystem. The edge the refusal names is
## formatted by the real `registrationOrderingEdgeOfService` from
## `repro_resources/readiness_edge.nim` — the same proc the resource
## lane's own refusal uses, so the two cannot describe two edges.

import std/[os, strutils, tables, unittest]

import cbor                             # cborText, for the empty `metadata`
import repro_dev_env_artifacts          # DevEnvServiceSummary
import repro_cli_support/dev_session
import repro_resources/readiness_edge

const
  Svc = "sso"
  Member = "isonim-site"
  Token = "@minted:" & Member & "@"

proc scratchOut(tag: string): string =
  let root = getTempDir() / ("dss10-argv-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  root

suite "D-SS10 — the early read names attribute, resource and edge":

  test "an uncomputed attribute refuses, and names all three":
    var answered = @["SENTINEL"]
    var message = ""
    try:
      answered = substituteMintedAttributes(Svc, @[Token],
        initTable[string, string]())
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    # IT REFUSED -- not nil, not "", not the token verbatim.
    check answered == @["SENTINEL"]
    # 1. WHICH ATTRIBUTE.
    check message.contains("`" & ClientIdAttributeName & "`")
    # 2. WHICH RESOURCE.
    check message.contains(registrationResourceLabel(Svc, Member))
    # 3. WHICH EDGE WOULD HAVE ORDERED IT.
    check message.contains(registrationOrderingEdgeOfService(Svc))
    # And the rule, so an author meets the reason rather than only the
    # rule: completion is readiness, not materialisation.
    check message.contains("DECLARED READINESS")
    check message.contains("IS NOT COMPUTED")

  test "the refusal still reports what IS registered":
    # The pre-§7.1 content is kept, not replaced. An author whose member
    # name is a typo needs the registered set, and losing it to make room
    # for the edge would be trading one half of the diagnostic for the
    # other.
    var minted = initTable[string, string]()
    minted["codetracer-cli"] = "client-aaa"
    var answered = @["SENTINEL"]
    var message = ""
    try:
      answered = substituteMintedAttributes(Svc, @[Token], minted)
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check answered == @["SENTINEL"]
    check message.contains("Registered members: codetracer-cli")

  test "the refusal names the empty string as the answer it will not give":
    var message = ""
    try:
      discard substituteMintedAttributes(Svc, @[Token],
        initTable[string, string]())
    except ValueError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("indistinguishable from a legitimately empty")
    check message.contains("D-SS10")

  test "a computed attribute read AFTER the reconcile yields the value":
    # The positive control. Without it, a refusal that fired
    # unconditionally would pass every case above.
    let outDir = scratchOut("resolved")
    writeSharedInstanceMinted(outDir, @[
      (serviceName: Svc, member: Member, mintedId: "client-abc123")])
    let table = readSharedInstanceMinted(outDir)
    check substituteMintedAttributes(Svc, @["--client-id", Token], table) ==
      @["--client-id", "client-abc123"]

  test "the edge text is the resource lane's, not a second spelling of it":
    # The silent-drop shape this guards: two refusals describing two
    # different edges for one fact. Both are derived from
    # `registrationOrderingEdgeOfService`, so this asserts the derivation
    # rather than two hand-kept strings agreeing by luck.
    let edge = registrationOrderingEdgeOfService(Svc)
    check edge.contains("dependsOn")
    check edge.contains(ServiceNodeAddressPrefix)
    check edge.contains("DECLARED READINESS")
    check edge.contains("`" & Svc & "`")
    var message = ""
    try:
      discard substituteMintedAttributes(Svc, @[Token],
        initTable[string, string]())
    except ValueError as err:
      message = err.msg
    check message.contains(edge)

suite "D-SS10 — the declared readiness of a SHARED service is no longer dropped":

  test "`sharedServiceInstanceLaunch` reports the declared probe":
    # The silent drop this closes, measured as a property rather than
    # asserted in prose. `serviceSpecsFromArtifact` SKIPS every service
    # with an `instance:` block, so until D-SS10 the only reader of a
    # shared service's readiness was nothing at all: the probe was
    # parsed, validated, carried at envelope 4 and printed by
    # `repro dev-env --json`, and no code probed it. The launch tuple is
    # where the CLI now reads it, through the SAME
    # `serviceSpecFromSummary` the supervisor uses for a session-owned
    # service -- one reading of one declaration.
    let service = DevEnvServiceSummary(
      name: Svc,
      activityRequirements: @[Svc],
      metadata: cborText(""),
      identityKind: "stable",
      identityStableId: "com.example.dss10.sso",
      scope: "workspace",
      typedCommand: @["/bin/sh", "-c", "sleep 1"],
      workingDirectory: ".",
      readinessKind: "fileExists",
      readinessPath: "state/idp.ready",
      readinessTimeoutMs: 60000,
      instanceDeclared: true,
      instanceLeaseTtlSeconds: -1,
      instanceEnvironment: "development")
    let launch = sharedServiceInstanceLaunch(getCurrentDir(), service)
    check launch.readinessKind == "fileExists"
    # Resolved against the project root by the ONE reader, exactly as it
    # is for a session-owned service -- a relative path read raw here and
    # resolved there is how two readers of one declaration disagree.
    check launch.readinessPath == getCurrentDir() / "state/idp.ready"
    check launch.readinessTimeoutMs == 60000
    # And the probe it yields really does order a registration, which is
    # the whole point of carrying it.
    check ordersRegistrations(ServiceReadinessProbe(
      kind: launch.readinessKind, path: launch.readinessPath,
      url: launch.readinessUrl, timeoutMs: launch.readinessTimeoutMs))

  test "a shared service that declares NO probe yields one that cannot order":
    # The control for the case above: the launch tuple reports the ground
    # state as the ground state. An implementation that defaulted the
    # kind to `fileExists` would pass the positive case and make the
    # expansion refusal unreachable.
    let service = DevEnvServiceSummary(
      name: Svc,
      activityRequirements: @[Svc],
      metadata: cborText(""),
      identityKind: "stable",
      identityStableId: "com.example.dss10.sso-probeless",
      scope: "workspace",
      typedCommand: @["/bin/sh", "-c", "sleep 1"],
      workingDirectory: ".",
      instanceDeclared: true,
      instanceLeaseTtlSeconds: -1,
      instanceEnvironment: "development")
    let launch = sharedServiceInstanceLaunch(getCurrentDir(), service)
    check launch.readinessKind == "none"
    check not ordersRegistrations(ServiceReadinessProbe(
      kind: launch.readinessKind, path: launch.readinessPath,
      url: launch.readinessUrl, timeoutMs: launch.readinessTimeoutMs))

suite "D-SS10 — the session event log carries the ordering facts":

  test "appendSessionEvent writes the supervisor's own schema, in append order":
    # The ordering D-SS10 establishes happens BEFORE the supervisor
    # exists, and the test that asserts it reads the log's line order. So
    # the pre-supervisor rows must land in the SAME file, under the SAME
    # schema id -- a second log or a second id would make every reader
    # that knows `reprobuild.dev-session.event.v1` wrong by omission.
    let outDir = scratchOut("events")
    appendSessionEvent(outDir, "service.readiness.waiting", Svc,
      "probe=fileExists")
    appendSessionEvent(outDir, "service.readiness.satisfied", Svc,
      "waitedMs=1250")
    appendSessionEvent(outDir, "registration.reconciled", Svc,
      "members=2 computed=2")
    let lines = readFile(sessionEventLogPath(outDir)).strip().splitLines()
    check lines.len == 3
    check lines[0].contains("service.readiness.waiting")
    check lines[1].contains("service.readiness.satisfied")
    check lines[2].contains("registration.reconciled")
    for line in lines:
      check line.contains("reprobuild.dev-session.event.v1")
    # Same file as the supervisor's.
    check sessionEventLogPath(outDir) ==
      outDir.sessionDir / "events.jsonl"

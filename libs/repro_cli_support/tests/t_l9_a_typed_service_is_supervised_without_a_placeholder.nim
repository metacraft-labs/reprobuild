## Shared-Development-Services L9 — A SERVICE DECLARED ONLY AS A TYPED
## `service` BLOCK IS SUPERVISED, and every supervision fact it declared
## is the one the supervisor acts on.
##
## This is the half of "declared once" that decides whether the gate's
## clause is met rather than merely describable. L8 gave
## `DevEnvServiceSummary` the fields; until L9 the reader REFUSED a
## record with no placeholder metadata outright —
##
##     if text.len == 0:
##       raise newException(ValueError,
##         "service " & service.name & " has empty supervisor metadata")
##
## — so a recipe that declared its service once could not be started at
## all, whatever the typed block carried. That line is the measured
## before-state of every case in this file.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Every case builds a real `DevEnvServiceSummary` — the same record the
## real SSZ codec produces, with the same field names — and calls the
## real `serviceSpecFromSummary`, the real `sharedServiceInstanceOf` and
## the real `declaredReadinessTimeoutMs`. Nothing stubs the reader.
##
## A `DevEnvServiceSummary` literal is NOT a mock: it is the datum under
## test. `t_l9_supervision_facts_reach_the_dev_env_artifact` is the other
## half — it measures that a real recipe, lowered by the real macro,
## produces exactly these fields — so the two files together cover
## producer and consumer without either one simulating the other.
##
## THE PROBE SETS ARE CONSTANTS, asserted by cases of their own, for the
## reason L7's review recorded: three prose numbers for one set is how a
## probe set silently shrinks.

import std/[json, os, strutils, tables, unittest]

import cbor
import repro_dev_env_artifacts
import repro_project_dsl
import repro_resources/service_identity
import repro_cli_support/dev_session

const
  ProjectRoot = "/tmp/l9-supervision-project-root"
  ReadyMarker = ".repro/l9-sso/ready"
  StateDir = ".repro/l9-sso"
  JournalDir = ".repro/l9-sso-journal"
  DeclaredTimeoutMs = 600_000

  UnknownReadinessKinds* = [
    ## Words that must be REFUSED by name rather than read as a default.
    ## `readinessOk` reports an unrecognised kind as NEVER READY, so each
    ## of these would otherwise hang a session until its timeout with
    ## nothing said. The last two are the near-misses that make the
    ## refusal worth having: one is the right word in the wrong case for
    ## the artifact's own spelling rule, the other is a plausible
    ## invention.
    "fileexist",
    "http",
    "FileExists ",
    "processAlive"]

  KnownReadinessKinds* = [
    ## The three kinds the supervisor IMPLEMENTS, as a counted constant
    ## for the same reason the refusal set is one: an inline literal in
    ## the positive control can silently shrink to two, and a positive
    ## control that has quietly stopped covering a kind is worse than
    ## none, because it still reports OK.
    "none",
    "fileExists",
    "httpGet"]

proc typedOnly(): DevEnvServiceSummary =
  ## The record a recipe that declares its service ONCE produces:
  ## `metadata` empty, every supervision fact typed. The field values
  ## are the ones `t_l9_supervision_facts_reach_the_dev_env_artifact`
  ## measures a real lowering to produce.
  DevEnvServiceSummary(
    name: "sso",
    activityRequirements: @["sso"],
    metadata: cborText(""),
    identityKind: "stable",
    identityStableId: "com.metacraft-labs.l9-sso",
    scope: "workspace",
    typedCommand: @["bin/l9-sso", "--external-domain",
                    "login.metacraft-labs.test"],
    readinessKind: "fileExists",
    readinessPath: ReadyMarker,
    readinessTimeoutMs: DeclaredTimeoutMs,
    workingDirectory: ".",
    stateDirectories: @[StateDir, JournalDir],
    instanceDeclared: true,
    instanceLeaseTtlSeconds: -1,
    instanceEnvironment: "development")

proc placeholderOnly(): DevEnvServiceSummary =
  ## The pre-L9 record: everything in the opaque JSON, nothing typed.
  ## It is the control that says the new reader did not displace the old
  ## one.
  DevEnvServiceSummary(
    name: "sso",
    activityRequirements: @["sso"],
    metadata: cborText("""{
      "schemaId": "reprobuild.dev-session.service.v1",
      "command": ["scripts/sso-dev-server.sh"],
      "cwd": ".",
      "readiness": {"kind": "fileExists", "path": ".repro/sso/ready",
                    "timeoutMs": 600000},
      "resources": [{"kind": "directory", "path": ".repro/sso"}],
      "instance": {"lease": "keep"}
    }"""))

suite "L9: a typed-only service yields a complete supervisor spec":

  test "the command comes from the typed block":
    let spec = serviceSpecFromSummary(ProjectRoot, typedOnly())
    check spec.command == @["bin/l9-sso", "--external-domain",
                            "login.metacraft-labs.test"]

  test "the working directory is the typed one, resolved ONCE":
    # Relative, so it must be resolved against the project root — and
    # resolved by this proc, which is the same proc
    # `sharedServiceInstanceLaunch` reuses so the daemon and the
    # supervisor cannot resolve it differently.
    let spec = serviceSpecFromSummary(ProjectRoot, typedOnly())
    check spec.cwd == ProjectRoot
    check sharedServiceInstanceLaunch(ProjectRoot, typedOnly()).workingDir ==
      spec.cwd
    check sharedServiceInstanceLaunch(ProjectRoot, typedOnly()).command ==
      spec.command

  test "the readiness probe is the typed one, with its own timeout":
    let spec = serviceSpecFromSummary(ProjectRoot, typedOnly())
    check spec.readinessKind == "fileExists"
    check spec.readinessPath == ProjectRoot / ReadyMarker
    check spec.readinessTimeoutMs == DeclaredTimeoutMs

  test "the state directories become supervisor resources":
    let spec = serviceSpecFromSummary(ProjectRoot, typedOnly())
    check spec.resources.len == 2
    check spec.resources[0] == (kind: "directory", path: ProjectRoot / StateDir)
    check spec.resources[1] ==
      (kind: "directory", path: ProjectRoot / JournalDir)

  test "the instance declaration is read from the typed block":
    let declaration = sharedServiceInstanceOf(typedOnly())
    check declaration.declared
    check declaration.leaseTtlSeconds == SharedServiceInstanceKeepTtlSeconds
    check declaration.environment == "development"

  test "the instance key is resolvable from the typed declaration":
    # The whole point of `identity stable` + `scope workspace` + an
    # environment: a key the daemon can hold an instance under. Resolved
    # through the REAL `sharedServiceInstanceKey`, which refuses a
    # `derived` identity, so this also asserts the identity reached it.
    let summary = typedOnly()
    let identityAndScope = summaryDeclaredIdentityAndScope(summary)
    check identityAndScope.declared
    check identityAndScope.identity.kind == sikStable
    check identityAndScope.scope == sscWorkspace
    let key = sharedServiceInstanceKey(sharedServiceInstanceOf(summary),
      ProjectRoot, identityAndScope.identity, identityAndScope.scope)
    check key.environment == "development"

suite "L9: the PARENT's wait and the SUPERVISOR's wait read one number":

  test "`declaredReadinessTimeoutMs` sees the typed timeout":
    # Found by going looking, not by a failure: this proc sizes the
    # parent's wait and read only the JSON lane, so a typed service
    # declaring ten minutes was supervised for ten minutes and waited on
    # for ninety seconds plus the margin -- `repro up` would have
    # abandoned a healthy first boot.
    check typedOnly().declaredReadinessTimeoutMs == DeclaredTimeoutMs
    check serviceSpecFromSummary(ProjectRoot, typedOnly()).readinessTimeoutMs ==
      typedOnly().declaredReadinessTimeoutMs

  test "a typed service with no timeout falls back to the ONE default":
    var summary = typedOnly()
    summary.readinessTimeoutMs = 0
    check summary.declaredReadinessTimeoutMs == DefaultServiceReadinessTimeoutMs
    check serviceSpecFromSummary(ProjectRoot, summary).readinessTimeoutMs ==
      DefaultServiceReadinessTimeoutMs

suite "L9: the placeholder lane is untouched":

  test "a placeholder-only service is read exactly as before":
    let spec = serviceSpecFromSummary(ProjectRoot, placeholderOnly())
    check spec.command == @["scripts/sso-dev-server.sh"]
    check spec.cwd == ProjectRoot
    check spec.readinessKind == "fileExists"
    check spec.readinessPath == ProjectRoot / ".repro/sso/ready"
    check spec.resources == @[(kind: "directory",
                               path: ProjectRoot / ".repro/sso")]
    check sharedServiceInstanceOf(placeholderOnly()).declared

  test "a service that declares NEITHER is refused, naming both lanes":
    var summary = typedOnly()
    summary.metadata = cborText("")
    summary.typedCommand = @[]
    var raised = false
    try:
      discard serviceSpecFromSummary(ProjectRoot, summary)
    except ValueError as err:
      raised = true
      check "declares no command" in err.msg
      check "no `servicePlaceholder` at all" in err.msg
    check raised

suite "L9: two declarations of one fact are REFUSED, not ranked":

  test "a readiness probe in both lanes is refused, naming both":
    # Not a precedence decision: whichever lost would be the probe a
    # dependent does NOT wait on, and a dependent that starts against a
    # listening-but-unseeded instance fails intermittently rather than
    # loudly.
    var summary = placeholderOnly()
    summary.readinessKind = "httpGet"
    summary.readinessUrl = "http://127.0.0.1:8080"
    var raised = false
    try:
      discard serviceSpecFromSummary(ProjectRoot, summary)
    except ValueError as err:
      raised = true
      check "declared TWICE" in err.msg
      check "fileExists" in err.msg
      check "httpGet" in err.msg
    check raised

  test "an `instance` block in both lanes is refused, naming both":
    var summary = placeholderOnly()
    summary.instanceDeclared = true
    summary.instanceLeaseTtlSeconds = 0
    var raised = false
    try:
      discard sharedServiceInstanceOf(summary)
    except ValueError as err:
      raised = true
      check "declared TWICE" in err.msg
      check "reaped" in err.msg
    check raised

  test "a placeholder COMMAND still wins over the typed one":
    # L8's one-way fallback, unchanged on purpose: a recipe carrying
    # both is mid-migration, and silently preferring the typed command
    # would change what an existing recipe runs.
    var summary = placeholderOnly()
    summary.typedCommand = @["bin/l9-sso"]
    check serviceSpecFromSummary(ProjectRoot, summary).command ==
      @["scripts/sso-dev-server.sh"]

suite "L9: an unknown readiness kind is refused rather than defaulted":

  test "the probe set's size is read from the set":
    check UnknownReadinessKinds.len == 4

  test "each unknown kind is refused, naming it and the three that exist":
    for kind in UnknownReadinessKinds:
      var summary = typedOnly()
      summary.readinessKind = kind
      var raised = false
      try:
        discard serviceSpecFromSummary(ProjectRoot, summary)
      except ValueError as err:
        raised = true
        checkpoint("refusal for `" & kind & "` does not name it: " & err.msg)
        check kind in err.msg
        check "not a kind this build knows" in err.msg
      # Emitted only when it is TRUE. `checkpoint` accumulates and
      # prints on the next failure, so an unconditional one here labels
      # every correctly-refused kind "was NOT refused" in the output of
      # a failure caused by a later kind.
      if not raised:
        checkpoint("readiness kind `" & kind & "` was NOT refused")
      check raised

  test "the three kinds the supervisor implements are accepted":
    # The positive control: a probe set made only of refusals cannot
    # tell "refuses everything" from "refuses the wrong things".
    check KnownReadinessKinds.len == 3
    for kind in KnownReadinessKinds:
      var summary = typedOnly()
      summary.readinessKind = kind
      summary.readinessUrl = "http://127.0.0.1:8080"
      checkpoint("readiness kind `" & kind & "` was refused")
      check serviceSpecFromSummary(ProjectRoot, summary).readinessKind == kind

suite "L9: the state directories reach the supervisor as resources":

  test "a typed state directory becomes a directory resource under the project root":
    # WHAT THIS MEASURES, EXACTLY: that each typed `stateDirectory`
    # reaches `ServiceSpec.resources` as a path resolved under the
    # project root, and that none of those paths exists beforehand -- so
    # the supervisor is being handed directories to create rather than
    # directories that happened to be there.
    #
    # WHAT IT DOES NOT MEASURE, stated rather than implied by the name:
    # the creation itself. `reconcileResources` in
    # `repro_cli_support/dev_session.nim` is the proc that calls
    # `createDir` over this list, it is unexported, and it is NOT driven
    # here -- the `createDir` below is THIS TEST's, standing in for it.
    # An earlier name claimed "a directory the supervisor creates",
    # which read as a filesystem assertion about the supervisor and was
    # not one. Closing that gap means exporting `reconcileResources` or
    # driving a real session, and neither is done here.
    let root = getTempDir() / ("l9-statedir-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer:
      try: removeDir(root)
      except CatchableError: discard
    let spec = serviceSpecFromSummary(root, typedOnly())
    for resource in spec.resources:
      check not dirExists(resource.path)
      createDir(resource.path)
    check dirExists(root / StateDir)
    check dirExists(root / JournalDir)

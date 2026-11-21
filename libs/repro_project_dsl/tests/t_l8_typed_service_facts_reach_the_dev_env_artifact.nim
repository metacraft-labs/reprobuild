## Shared-Development-Services L8 — THE PLUMBING GAP L7's REVIEW
## ASSIGNED HERE IS CLOSED: the typed `service` block's identity, scope,
## compatibility and command reach `DevEnvArtifact.services`.
##
## What L7's review measured, and what this file measures instead:
##
##   "`DevEnvServiceSummary` carries only `name`,
##    `activityRequirements`, `supervisorPlanRef`,
##    `hasSupervisorPlanRef` and `metadata`. There is no field an
##    identity or a scope could travel in, so no amount of routing on
##    the PRODUCING side closes it -- the typed interface has to reach
##    the CONSUMING path first."
##
## Consequence recorded there: "a recipe that wants a shared instance
## declares the service TWICE". And: "if it is not closed first, L9's
## proof contradicts L9's own clause".
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## The package is a real `package` block with a real typed `service`
## block; the dev-env body is run by the real `buildPackageDevEnv`; the
## artifact is produced by the real `toDevEnvArtifact` and round-tripped
## through the real SSZ codec.
##
## THE DRIFT ASSERTION IS HERE AND NOT IN A COMMENT. `runtime_provider`
## derives the scope word with `($scope)[3 .. ^1].normalize` because
## `repro_resources/service_identity.nim`'s `scopeWord` cannot be
## imported there (`repro_resources` depends on `repro_project_dsl`). A
## TEST may import both, so the agreement is asserted for every value of
## both enums rather than asserted in prose.

import std/[algorithm, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/types
import repro_dev_env_artifacts
import repro_resources/service_identity

import l8_contribution_fixtures

proc pkgDef(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "l8MatrixOwner":
      return pkg
  raise newException(ValueError, "fixture drift: l8MatrixOwner missing")

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".dev-env",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/l8-facts-fixture-root",
    namespace: "project-" & pkg.packageName,
    activity: activity)

proc devEnvResultFor(activity: string): DevEnvResult =
  clearRegisteredServices("l8MatrixOwner")
  let pkg = pkgDef()
  buildPackageDevEnv(pkg, devEnvRequest(pkg, activity),
    devEnvL8MatrixOwnerPackage)

proc serviceNamed(res: DevEnvResult; name: string): DevEnvServiceMetadata =
  for svc in res.services:
    if svc.name == name:
      return svc
  raise newException(ValueError, "no service named " & name)

suite "L8: the typed `service` block's facts reach DevEnvResult.services":

  test "the fixture declares typed services and NO servicePlaceholder":
    # The control for the whole file: if the fixture also carried a
    # placeholder, every assertion below could be reading the
    # placeholder's channel and the gap would be untouched. The EMPTY
    # metadata is what says so -- a placeholder's metadata is the JSON
    # blob, and these records carry none.
    let res = devEnvResultFor("sso")
    var names: seq[string] = @[]
    for svc in res.services:
      names.add(svc.name)
      check svc.metadata.len == 0
    names.sort()
    check names == @["zitadel", "zitadelEmpty"]

  test "identity, scope and compatibility travel on the record":
    let svc = serviceNamed(devEnvResultFor("sso"), "zitadel")
    check svc.identityKind == "stable"
    check svc.identityStableId == "com.metacraft-labs.l8-matrix"
    check svc.scope == "workspace"

  test "the typed command travels on the record, one token per argument":
    let svc = serviceNamed(devEnvResultFor("sso"), "zitadel")
    # executable, then every `args` token including the folded
    # contribution members -- the L8 collection reaching the supervisor's
    # channel rather than only the graph fragment's.
    check svc.typedCommand.len > 0
    check svc.typedCommand[^3 .. ^1] ==
      @["owner-default", "consumer-a", "cell"]
    check "start-from-init" in svc.typedCommand
    check "--relying-parties" in svc.typedCommand

suite "L8: the words are derived once, so the two libraries cannot drift":

  test "every ServiceScope value renders as repro_resources renders it":
    let svc = serviceNamed(devEnvResultFor("sso"), "zitadel")
    check svc.scope == scopeWord(sscWorkspace)
    # and the formula, for the whole enum, so a new scope cannot be
    # added on one side only.
    for scope in ServiceScope:
      check ($scope)[3 .. ^1].normalize == scopeWord(scope)

  test "every ServiceIdentityKind value renders as repro_resources renders it":
    let svc = serviceNamed(devEnvResultFor("sso"), "zitadel")
    check svc.identityKind == identityKindWord(sikStable)
    for kind in ServiceIdentityKind:
      check ($kind)[3 .. ^1].normalize == identityKindWord(kind)

suite "L8: the facts survive the artifact codec":

  test "the fields round-trip through the real SSZ envelope":
    let res = devEnvResultFor("sso")
    let artifact = artifactFromDevEnvResult(res)
    proc summaryNamed(a: DevEnvArtifact; name: string): DevEnvServiceSummary =
      for svc in a.services:
        if svc.name == name:
          return svc
      raise newException(ValueError, "no summary named " & name)
    let summary = summaryNamed(artifact, "zitadel")
    check summary.identityKind == "stable"
    check summary.identityStableId == "com.metacraft-labs.l8-matrix"
    check summary.scope == "workspace"
    check summary.typedCommand == serviceNamed(res, "zitadel").typedCommand
    # The SECOND service's `scope project` is carried too, which is what
    # says the field is read per record rather than once.
    check summaryNamed(artifact, "zitadelEmpty").scope == "project"
    let bytes = encodeDevEnvArtifact(artifact)
    let decoded = decodeDevEnvArtifact(bytes)
    check decoded.services.len == artifact.services.len
    let roundTripped = summaryNamed(decoded, "zitadel")
    check roundTripped.identityKind == "stable"
    check roundTripped.identityStableId == "com.metacraft-labs.l8-matrix"
    check roundTripped.scope == "workspace"
    check roundTripped.typedCommand == summary.typedCommand
    check summaryNamed(decoded, "zitadelEmpty").scope == "project"

  test "the JSON view shows them, so an operator can see what was declared":
    let artifact = artifactFromDevEnvResult(devEnvResultFor("sso"))
    let text = toJsonInspection(artifact)
    check "\"identityKind\":\"stable\"" in text
    check "\"scope\":\"workspace\"" in text
    check "\"identityStableId\":\"com.metacraft-labs.l8-matrix\"" in text
    check "\"typedCommand\":" in text

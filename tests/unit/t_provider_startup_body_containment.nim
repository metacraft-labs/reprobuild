## The DSL's STARTUP PASS over a package's ``build:`` body must not be
## able to abort the provider binary.
##
## The ``package`` macro runs every body once while the provider binary is
## still initialising, so the shell-action registry is populated before a
## convention decides whether it can claim the recipe. That pass has no
## request behind it: no project root, no dependency bindings.
##
## Every recipe in a project is linked into ONE provider binary. So a body
## that raises during the pass -- and resolving a single input path
## against the (absent) project root is enough -- takes the whole binary
## down at startup, and every target in that project becomes unbuildable,
## including targets that never reference the offending recipe. What the
## operator sees is ``provider exited with code 1`` plus a stack trace
## naming neither the request nor the package.
##
## Coverage, and each case's negative counterpart:
##
##   1. The pass ran both fixture bodies. Without this the rest of the
##      suite holds vacuously -- a rule with no reachable input.
##   2. A raising body does not abort initialisation. Reaching ANY case
##      here is itself the measurement.
##   3. The failure is recorded, naming the package and carrying the
##      message. Containment must not be silence.
##   4. The pass continues past the failing package, and still does its
##      one job (the shell row is registered).
##   5. A body can ask POSITIVELY whether it is in the pass. Inferring it
##      from an empty project root conflates the pass with a planning
##      fault that has to stay fatal.
##   6. The containment is scoped to the pass. The same body still raises
##      when invoked for real, directly and through
##      ``buildPackageFragment``. Were it otherwise, a recipe that cannot
##      plan would yield an EMPTY fragment rather than a failure.
##   7. A real PROVIDER PROCESS tells the operator which package failed.
##      The record is not the report: a suite that reads only
##      ``providerStartupBodyFailures()`` stays green when the line that
##      prints it is deleted, and a contained failure nobody is told
##      about is a silently broken recipe.
##   8. The ENGINE carries that line rather than dropping it. A
##      successful provider's captured output is otherwise read only to
##      be discarded -- and after containment the provider IS
##      successful, so without this the report reaches no log at all.
##   9. An invocation with no project root is refused where it is
##      produced, by a message that names the entry point.
##  10. A ``Defect`` is contained, recorded AS a defect and reported --
##      and still aborts a body invoked for real. Containment covered
##      ``CatchableError`` only, which left the likeliest failure of a
##      rootless body (an index or range operation) uncovered.
##
## What is NOT covered, and cannot be: a ``quit`` in a startup body.
## ``quit`` raises nothing, so no handler intercepts it and the provider
## still dies. That is a property of ``quit`` rather than a gap here; the
## contract a recipe has to meet is to raise, and cases 2 and 10 are what
## show that raising is enough.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import lints/ambient_execution

import "../fixtures/provider-startup-body/packages" as fixture

const
  ProviderRoleFlag = "--startup-body-fixture-provider-role"
  EngineRoleFlag = "--startup-body-fixture-engine-role"

# Re-entry points. The last two cases are about what a real PROVIDER
# PROCESS writes and what the engine does with it, and neither can be
# observed from inside this process: ``runPackageProvider`` is what emits
# the report, and only a provider binary calls it. Rather than assert on
# the source text -- which stays green when the line is deleted -- this
# binary re-executes ITSELF in the two roles and reads the child's output.
#
# ``extraArgs`` puts the flag at argv[1], ahead of the protocol arguments
# the engine appends, so the same check serves both roles.
when defined(reproProviderMode):
  if paramCount() >= 1 and paramStr(1) == ProviderRoleFlag:
    quit runPackageProvider(
      PackageDef(packageName: "startupBodyRefuses"),
      buildStartupBodyRefusesPackage)
  if paramCount() >= 1 and paramStr(1) == EngineRoleFlag:
    discard readProviderManifest(ProviderExecutionConfig(
      binaryPath: getAppFilename(),
      extraArgs: @[ProviderRoleFlag],
      workingDir: getCurrentDir(),
      tempRoot: getTempDir() / "startup-body-fixture-engine"),
      "startup-body-fixture-provider")
    quit 0

proc runSelf(role: string): string =
  ## Merged stdout+stderr of this binary re-executed in ``role`` -- the
  ## same merge (``poStdErrToStdOut``) the engine captures a provider
  ## with, so what this reads is what the engine would have had.
  uncontrolledExecCmdEx(
    "'" & getAppFilename().replace("'", "'\\''") & "' " & role).output

# Snapshot everything the startup pass produced BEFORE any case runs.
# Case 6 invokes the raising body again on purpose, which moves the
# counters; asserting against the snapshots keeps each case independent of
# the order the runner happens to use.
let
  snapshotRefusesRuns = fixture.startupBodyRefusesRuns
  snapshotDefectsRuns = fixture.startupBodyDefectsRuns
  snapshotRegistersRuns = fixture.startupBodyRegistersRuns
  snapshotActiveSeen = fixture.startupBodyActiveSeenByRefuses
  snapshotRootSeen = fixture.startupBodyRootSeenByRefuses
  snapshotRanPackages = providerStartupBodyPackages()
  snapshotFailures = providerStartupBodyFailures()
  snapshotRegisteredShell = registeredShellActions("startupBodyRegisters")

proc fixtureRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "startup-body-fixture-provider",
    entryPointId: "startupBodyRefuses.root",
    entryPointBodyHash: "startup-body-fixture-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

suite "provider startup pass containment":

  test "this gate is compiled in provider mode":
    # Without the define the macro emits no startup pass at all and every
    # case below would hold for the wrong reason. A red case says so more
    # usefully than a compile error, which the verification bar counts as
    # inconclusive rather than as a failure.
    check defined(reproProviderMode)

  test "the startup pass ran every fixture body":
    check snapshotRefusesRuns == 1
    check snapshotDefectsRuns == 1
    check snapshotRegistersRuns == 1
    check "startupBodyRefuses" in snapshotRanPackages
    check "startupBodyRaisesDefect" in snapshotRanPackages
    check "startupBodyRegisters" in snapshotRanPackages

  test "a raising body does not abort module initialisation":
    # The fixture's first package raises unconditionally. That this case
    # executes at all means initialisation survived it; the counter says
    # the body really did run and really did reach the raise.
    check snapshotRefusesRuns == 1
    check snapshotActiveSeen.len == 1

  test "the contained failure is recorded, named and quoted":
    check snapshotFailures.len == 2
    check snapshotFailures[0].startsWith("startupBodyRefuses: ")
    check fixture.StartupBodyRaiseSentinel in snapshotFailures[0]

  test "a DEFECT in a startup body is contained too, and reported as one":
    ## Containment used to cover ``CatchableError`` only. A body running
    ## with no project root fails at index, slice and range operations at
    ## least as often as it raises -- `path[0]` on a string that is empty
    ## because the root it came from is empty -- and in Nim those are
    ## ``Defect``s. So the likeliest failure of the very pass this exists
    ## to survive was the one it did not cover, and the operator got
    ## "provider exited with code 1" for every target in the project.
    ##
    ## That this case RUNS is the first half of the measurement: the
    ## defect-raising fixture package is declared before the registering
    ## one, so an uncontained defect stops module initialisation and
    ## nothing in this file reports anything.
    check snapshotDefectsRuns == 1
    check "startupBodyRaisesDefect" in snapshotRanPackages
    check snapshotFailures[1].startsWith("startupBodyRaisesDefect: ")
    check fixture.StartupBodyDefectSentinel in snapshotFailures[1]
    # Reported AS a defect. The two kinds of failure mean different
    # things to whoever reads the log, and a record that flattens them
    # tells the reader one fewer thing than it knows.
    check "defect: " in snapshotFailures[1]
    check "defect: " notin snapshotFailures[0]

  test "a DEFECT still aborts a body invoked for REAL":
    ## The containment is scoped to the startup pass, and this is what
    ## keeps that from being a claim. Outside the pass a defect is not
    ## caught by anything here: a recipe that cannot plan must fail the
    ## plan, not yield an empty fragment.
    let before = fixture.startupBodyDefectsRuns
    expect IndexDefect:
      buildStartupBodyRaisesDefectPackage()
    check fixture.startupBodyDefectsRuns == before + 1

  test "a real provider process reports a contained DEFECT as well":
    ## Same reasoning as the raise: the record is not the report, and a
    ## contained failure nobody is told about is a silently broken recipe.
    let output = runSelf(ProviderRoleFlag)
    check ProviderStartupBodyFailurePrefix & "startupBodyRaisesDefect: " &
      "defect: " & fixture.StartupBodyDefectSentinel in output

  test "the pass continues past the failing package and still registers":
    check snapshotRegistersRuns == 1
    check snapshotRegisteredShell.len == 1
    check snapshotRegisteredShell[0].command == fixture.StartupBodyShellCommand

  test "a body can tell the startup pass from a real invocation":
    check snapshotActiveSeen == @[true]
    check snapshotRootSeen == @[""]
    # Outside the pass the answer flips, so the predicate distinguishes
    # the two states rather than being constantly true.
    check not providerStartupBodyActive()

  test "the same body still raises when invoked directly":
    let before = fixture.startupBodyRefusesRuns
    expect ValueError:
      buildStartupBodyRefusesPackage()
    check fixture.startupBodyRefusesRuns == before + 1
    # And it saw itself OUTSIDE the pass while doing so.
    check fixture.startupBodyActiveSeenByRefuses[^1] == false

  test "buildPackageFragment propagates the failure to the caller":
    let before = fixture.startupBodyRefusesRuns
    expect ValueError:
      discard buildPackageFragment(
        PackageDef(packageName: "startupBodyRefuses"),
        fixtureRequest(getCurrentDir()),
        buildStartupBodyRefusesPackage)
    check fixture.startupBodyRefusesRuns == before + 1

  test "a real provider process tells the operator which package failed":
    # The record is not the report. A gate that only reads
    # ``providerStartupBodyFailures()`` stays green when the line that
    # prints it is deleted, and a contained failure nobody is told about
    # is a silently broken recipe.
    let output = runSelf(ProviderRoleFlag)
    check ProviderStartupBodyFailurePrefix & "startupBodyRefuses: " &
      fixture.StartupBodyRaiseSentinel in output

  test "the engine forwards that line instead of discarding it":
    # The provider exits 0 here (it answers a manifest request), and on
    # that path the engine's capture pipe is read only to be thrown away.
    # The child below IS the engine: it runs a real provider protocol
    # round trip against a real provider, and the line has to come out.
    let output = runSelf(EngineRoleFlag)
    check ProviderStartupBodyFailurePrefix & "startupBodyRefuses: " &
      fixture.StartupBodyRaiseSentinel in output

  test "a graph invocation with no project root is refused by name":
    # The refusal lives where the invocation is BUILT, so the message can
    # name the entry point. Resolving a path against an empty root deeper
    # in a recipe names neither the request nor the package.
    var raised = false
    try:
      discard refreshProviderGraph(RefreshConfig(
        storeRoot: getTempDir() / "startup-body-fixture-store",
        providerBinaryPath: getAppFilename(),
        providerArtifactId: "startup-body-fixture-provider",
        rootEntryPointId: "startupBodyRefuses.root",
        rootArguments: "",
        namespace: "project",
        lockSliceId: "startup-body-fixture-slice",
        activity: "build"))
    except CatchableError as err:
      raised = true
      check "no project root" in err.msg
      check "startupBodyRefuses.root" in err.msg
    check raised

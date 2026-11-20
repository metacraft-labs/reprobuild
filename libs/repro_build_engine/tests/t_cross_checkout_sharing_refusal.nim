## `crossCheckoutSharingRefusal`: which planned actions can be served to
## another checkout on this host, and the first reason why one cannot
## (what `repro cache sharing` reports per action).
##
## Each case starts from an action that meets every condition (a cacheable,
## hybrid, monitored compile whose program lies under the store root and
## that declares its object) and breaks exactly one, so each condition is
## shown to be both checked and sufficient to refuse. The actions are plain
## `BuildAction` values: the procedure reads only their planned fields, which
## is the point of it (it answers before anything runs), so nothing is
## executed and nothing is mocked.
##
## The procedure calls the engine's own predicates (`crossHostRefusal`,
## `evidenceSourceOf` under `publicationRuleRefusal`,
## `portableIdentityRefusal`) instead of restating them, so the cases that
## a restatement would get wrong are pinned here: a depfile VALIDATED by the
## monitor is monitored evidence and stays a candidate, a builtin kind the
## publication rule refuses is refused, and so are a host-bound edge, an
## unsafe preserve-outputs step and a configuration with no portable roots.

import std/[options, strutils, unittest]

import repro_build_engine
import repro_core/dependency_gathering
import repro_core/edge_determinism
import repro_local_store

const
  ProjectRoot = "/work/checkout-one/proj"
  StoreRoot = "/work/store"

let roots = @[
  LogicalRoot(label: "project", path: ProjectRoot, kind: lrkTracked),
  LogicalRoot(label: "store", path: StoreRoot, kind: lrkTracked)]

proc candidate(): BuildAction =
  ## A compile that meets every condition.
  result = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakProcess,
    id: "compile",
    argv: @[StoreRoot & "/tool-store/prefixes/gcc/15.3.0-x/bin/gcc", "-c",
      "-O2", "-o", ProjectRoot & "/obj/add.o", ProjectRoot & "/src/add.c"],
    cwd: ProjectRoot,
    inputs: @[ProjectRoot & "/src/add.c"],
    outputs: @[ProjectRoot & "/obj/add.o"],
    cacheable: true,
    actionCachePolicy: ffpHybrid,
    weakFingerprint: weakFingerprintFromText("compile"))
  result.dependencyPolicy.kind = dgAutomaticMonitor

suite "which planned actions another checkout can be served":
  test "an action meeting every condition is a candidate":
    check crossCheckoutSharingRefusal(candidate(), roots) == ""
    var checksum = candidate()
    checksum.actionCachePolicy = ffpChecksum
    check crossCheckoutSharingRefusal(checksum, roots) == ""

  test "an action that is not cacheable is refused":
    var action = candidate()
    action.cacheable = false
    check "not cacheable" in crossCheckoutSharingRefusal(action, roots)

  test "a timestamp action is refused, naming its policy":
    var action = candidate()
    action.actionCachePolicy = ffpTimestamp
    let refusal = crossCheckoutSharingRefusal(action, roots)
    check "ffpTimestamp input-check policy" in refusal

  test "a depfile-evidenced action is refused unless the monitor validates it":
    proc report(name: string): RecognizedDependencyReportSpec =
      RecognizedDependencyReportSpec(formatName: DependencyFormatName(name),
        outputs: @[ExpectedDependencyFile(logicalName: "deps",
          path: ProjectRoot & "/obj/add.d", required: false)],
        completeness: decComplete)
    var recognized = candidate()
    recognized.dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormat, completeness: decComplete,
      recognizedReports: @[report("make-depfile")])
    check "dependency format 'make-depfile' (unmonitored)" in
      crossCheckoutSharingRefusal(recognized, roots)
    var converted = candidate()
    converted.dependencyPolicy = DependencyGatheringPolicy(
      kind: dgPostBuildConverter, completeness: decComplete,
      postBuildConverters: @[PostBuildDependencyConverterSpec(
        outputKind: dcoRecognizedFormat,
        outputFormatName: DependencyFormatName("msvc-includes"))])
    check "converted dependency report" in
      crossCheckoutSharingRefusal(converted, roots)
    # The engine grades a report validated by the monitor as monitored
    # evidence (`evidenceSourceOf`), and the publication rule admits it.
    var validated = candidate()
    validated.dependencyPolicy = monitorValidatedPolicy([report("make-depfile")])
    check crossCheckoutSharingRefusal(validated, roots) == ""
    # A format the rule assigns to an edge kind as complete evidence.
    var pure = candidate()
    pure.dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormat, completeness: decComplete,
      recognizedReports: @[report("nix-pure-flake")])
    check crossCheckoutSharingRefusal(pure, roots) == ""

  test "a host-bound edge is refused, naming its class":
    var action = candidate()
    action.determinism = some(edHostBound)
    check "forbids cross-machine substitution" in
      crossCheckoutSharingRefusal(action, roots)

  test "an unsafe preserve-outputs step is refused":
    var action = candidate()
    action.unsafePreserveOutputs = true
    check crossCheckoutSharingRefusal(action, roots) ==
      UnsafePreserveOutputsCrossHostRefusal

  test "no portable roots (the identity is off) refuses every action":
    check "portable identity is off" in
      crossCheckoutSharingRefusal(candidate(), newSeq[LogicalRoot]())
    let untrackedOnly = @[
      LogicalRoot(label: "system-proc", path: "/proc", kind: lrkUntracked)]
    check "portable identity is off" in
      crossCheckoutSharingRefusal(candidate(), untrackedOnly)

  test "a program outside every logical root is refused, naming it":
    var action = candidate()
    action.argv[0] = "/nix/store/abc-gcc-wrapper-15.2.0/bin/gcc"
    let refusal = crossCheckoutSharingRefusal(action, roots)
    check "/nix/store/abc-gcc-wrapper-15.2.0/bin/gcc" in refusal
    check "outside every logical root" in refusal
    # A program named by a bare word is resolved later; the plan cannot say
    # where it lies, so it does not refuse on it.
    action.argv[0] = "gcc"
    check crossCheckoutSharingRefusal(action, roots) == ""

  test "an untracked root does not make its programs portable":
    var action = candidate()
    let untracked = @[
      LogicalRoot(label: "project", path: ProjectRoot, kind: lrkTracked),
      LogicalRoot(label: "store", path: StoreRoot, kind: lrkUntracked)]
    check "outside every logical root" in
      crossCheckoutSharingRefusal(action, untracked)

  test "an action that declares no output is refused":
    var action = candidate()
    action.outputs = @[]
    check "declares no output" in crossCheckoutSharingRefusal(action, roots)
    action.declaredOutputs = @[ProjectRoot & "/obj/add.o"]
    check crossCheckoutSharingRefusal(action, roots) == ""

  test "a builtin action is judged by its kind, without a program":
    var action = candidate()
    action.kind = bakWriteText
    action.argv = @[]
    action.dependencyPolicy.kind = dgRecognizedFormat
    check crossCheckoutSharingRefusal(action, roots) == ""
    # A kind that reads more than its declared inputs is refused, naming it.
    action.kind = bakCopyFile
    check "'copy-file' builtin" in crossCheckoutSharingRefusal(action, roots)
    # ...unless its caller prewired a monitor capture, which the engine
    # folds as monitored evidence.
    action.monitorDepfile = ProjectRoot & "/obj/copy.iomon"
    action.dependencyPolicy.kind = dgAutomaticMonitor
    check crossCheckoutSharingRefusal(action, roots) == ""

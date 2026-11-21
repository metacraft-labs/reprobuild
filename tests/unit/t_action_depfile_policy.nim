## Exercise the real action constructor: rejection happens before execution,
## so no monitor, compiler fixture, or lease daemon is needed.
import std/[options, strutils, unittest]
import repro_build_engine
import repro_core

suite "action depfile policy":
  test "explicit automatic monitor cannot become depfile-only evidence":
    for policy in [automaticMonitorGatheringPolicy(),
        automaticMonitorGatheringPolicy(["/ignored"])]:
      var refused = false
      try:
        discard action("explicit-monitor", ["tool"], depfile = "deps.d",
          dependencyPolicy = policy,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
      except ValueError as error:
        refused = true
        check error.msg.contains("depfile")
        check error.msg.contains("dependencyPolicy")
        check error.msg.contains("monitorValidatedPolicy")
      check refused

  test "omitted policy preserves legacy Make depfile evidence":
    let edge = action("legacy", ["tool"], depfile = "deps.d",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check edge.dependencyPolicy.kind == dgRecognizedFormat
    check edge.dependencyPolicy.completeness == decComplete
    check edge.dependencyPolicy.recognizedReports.len == 1
    let report = edge.dependencyPolicy.recognizedReports[0]
    check $report.formatName == "make-depfile"
    check report.outputs.len == 1
    check report.outputs[0].path == "deps.d"
    check not report.outputs[0].required

  test "omitted policy without a depfile still monitors":
    let edge = action("default", ["tool"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check edge.dependencyPolicy == automaticMonitorGatheringPolicy()

  test "explicit automatic policy without a depfile preserves all fields":
    var policy = automaticMonitorGatheringPolicy(["/ignored"])
    policy.captureBreadth = mcbOmitAmbientReads
    let edge = action("automatic", ["tool"], dependencyPolicy = policy,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check edge.dependencyPolicy == policy

  test "monitor depfile prevents legacy lowering for default and explicit policies":
    let policy = automaticMonitorGatheringPolicy(["/ignored"])
    let explicitEdge = action("monitor-report", ["tool"],
      depfile = "deps.d", monitorDepfile = "deps.iomon",
      dependencyPolicy = policy,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check explicitEdge.dependencyPolicy == policy
    check explicitEdge.depfile == "deps.d"
    check explicitEdge.monitorDepfile == "deps.iomon"
    let defaultEdge = action("default-monitor-report", ["tool"],
      depfile = "deps.d", monitorDepfile = "deps.iomon",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check defaultEdge.dependencyPolicy == automaticMonitorGatheringPolicy()

  test "explicit report and converter policies retain their evidence":
    for kind in [dgRecognizedFormat, dgRecognizedFormatValidatedByMonitor,
        dgPostBuildConverter, dgPostBuildConverterValidatedByMonitor]:
      let policy = DependencyGatheringPolicy(kind: kind,
        completeness: decComplete, ignoredInputPrefixes: @["/ignored"],
        recognizedReports: @[RecognizedDependencyReportSpec(
          formatName: DependencyFormatName("make-depfile"),
          outputs: @[ExpectedDependencyFile(path: "policy.d", required: true)],
          completeness: decComplete)])
      let edge = action("explicit-report", ["tool"], depfile = "legacy.d",
        dependencyPolicy = policy,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      check edge.dependencyPolicy == policy

  test "forwarded optional policies distinguish absence and explicit monitoring":
    let absent = none(DependencyGatheringPolicy)
    let legacy = action("optional-legacy", ["tool"], depfile = "deps.d",
      dependencyPolicy = absent,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check legacy.dependencyPolicy.kind == dgRecognizedFormat
    let automatic = action("optional-default", ["tool"],
      dependencyPolicy = absent,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check automatic.dependencyPolicy == automaticMonitorGatheringPolicy()
    let present = some(automaticMonitorGatheringPolicy(["/ignored"]))
    expect ValueError:
      discard action("optional-monitor", ["tool"], depfile = "deps.d",
        dependencyPolicy = present,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let monitored = action("optional-monitor-report", ["tool"],
      depfile = "deps.d", monitorDepfile = "deps.iomon",
      dependencyPolicy = present,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check monitored.dependencyPolicy == present.get

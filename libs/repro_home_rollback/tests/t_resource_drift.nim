## Drift is observed through the real resource driver and filesystem. These
## tests cover both rollback preflight entry points, including the diagnostic
## used when accepting edits; there are no fake resource drivers or observers.
import std/[os, tempfiles, unittest]

import blake3
import repro_home_generations
import repro_home_rollback

proc digestOf(s: string): Digest256 =
  var bytes = newSeq[byte](s.len)
  for i, c in s: bytes[i] = byte(c)
  let raw = blake3.digest(bytes)
  for i in 0 ..< 32: result[i] = raw[i]

proc binding(path, content: string): ResourceBinding =
  ResourceBinding(resourceAddress: "profile.fs.userFile.marker",
    resourceKind: "fs.userFile", realWorldIdentity: path,
    postWriteDigest: digestOf(content))

proc resourcePlan(current, target: ResourceBinding;
                  kind: RollbackOpKind): RollbackPlan =
  RollbackPlan(resourceOps: @[ResourceOp(kind: kind,
    address: current.resourceAddress, hasCurrentRecord: true,
    currentRecord: current, hasTargetRecord: kind == rokUpdateResource,
    targetRecord: target)])

suite "rollback resource drift preflight":
  test "remove and update compare current identity and digest in both walkers":
    let root = createTempDir("rollback-resource-preflight-", "")
    defer: removeDir(root)
    let path = root / "current"
    let targetPath = root / "target"
    writeFile(path, "user edit")
    writeFile(targetPath, "target")
    let current = binding(path, "current")
    let target = binding(targetPath, "target")
    for kind in [rokRemoveResource, rokUpdateResource]:
      let plan = resourcePlan(current, target, kind)
      check checkPlanForDrift(plan, "", "") ==
        @["resource:" & current.resourceAddress]
      var raised = false
      try:
        raiseFirstDrift(plan, "", "")
      except EUserEditDetected as e:
        raised = true
        check e.path == current.resourceAddress
        check e.recordKind == "resource"
        check e.expectedDigestHex == digestHex(current.postWriteDigest)
        check e.observedDigestHex == digestHex(digestOf("user edit"))
      check raised
      check readFile(path) == "user edit"

  test "live target bytes still drift from the current generation":
    let root = createTempDir("rollback-resource-target-drift-", "")
    defer: removeDir(root)
    let path = root / "current"
    writeFile(path, "target")
    let current = binding(path, "current")
    let target = binding(path, "target")
    let plan = resourcePlan(current, target, rokUpdateResource)
    check checkPlanForDrift(plan, "", "") ==
      @["resource:" & current.resourceAddress]
    expect EUserEditDetected:
      raiseFirstDrift(plan, "", "")

  test "matching current and absent objects do not drift":
    let root = createTempDir("rollback-resource-preflight-", "")
    defer: removeDir(root)
    let path = root / "current"
    let current = binding(path, "current")
    for present in [true, false]:
      if present: writeFile(path, "current")
      elif fileExists(path): removeFile(path)
      for kind in [rokRemoveResource, rokUpdateResource]:
        let plan = resourcePlan(current, binding(path, "target"), kind)
        check checkPlanForDrift(plan, "", "").len == 0
        raiseFirstDrift(plan, "", "")

  test "current destroyed update still checks target and zero digest remove skips":
    let root = createTempDir("rollback-resource-preflight-", "")
    defer: removeDir(root)
    let path = root / "current"
    writeFile(path, "user edit")
    var current = binding(path, "current")
    current.postWriteDigest = default(Digest256)
    let target = binding(path, "target")
    let remove = resourcePlan(current, target, rokRemoveResource)
    check checkPlanForDrift(remove, "", "").len == 0
    raiseFirstDrift(remove, "", "")
    let update = resourcePlan(current, target, rokUpdateResource)
    check checkPlanForDrift(update, "", "") ==
      @["resource:" & current.resourceAddress]
    expect EUserEditDetected:
      raiseFirstDrift(update, "", "")

  test "unobservable recorded kinds keep their own rollback policy":
    for kind in ["vscode.extension", "macos.appBundle"]:
      var current = binding("unused", "current")
      current.resourceKind = kind
      for op in [rokRemoveResource, rokUpdateResource]:
        let plan = resourcePlan(current, binding("unused", "target"), op)
        check checkPlanForDrift(plan, "", "").len == 0
        raiseFirstDrift(plan, "", "")

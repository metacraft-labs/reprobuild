## M82 Phase B Verification Gate: integration_explicit_depends_on
##
## Per the M82 milestone entry's verification block:
##
##   * `depends_on` in the profile syntax is parsed;
##   * a cyclic dependency graph is refused at plan time with a clear
##     error naming the cycle;
##   * a multi-hop dependency chain (A -> B -> C -> D) is applied in
##     topological order;
##   * an implicit-edge case — a profile with both
##     `windows.capability OpenSSH.Server` and `windows.service sshd`
##     orders the capability before the service WITHOUT the user
##     writing `depends_on` (the producer / consumer map seeded from
##     M69's CBS-finalization wait inserts the edge implicitly).
##
## The gate is PURE LOGIC — it exercises the public `producePlan` API
## with fixture profile text and asserts the emitted plan's operation
## order. No VM, no broker, no real Windows API, no host mutation. It
## therefore runs on every host (Windows, Linux, macOS) and is the
## right home-gate complement to the heavier M69 destructive gates
## that need Hyper-V.
##
## The companion `integration_intra_batch_capability_to_service` gate
## that drives the REAL Hyper-V `Add-WindowsCapability OpenSSH.Server`
## + `Set-Service sshd` scenario lives in
## `tools/hyperv-m69-system/` and is exercised by the reviewer.
##
## No `skip`, no `xfail`.

import std/[strutils, unittest]

import repro_infra

const HostIdentity = "m82-phase-b-gate-host"
const FixedTimestamp = 1_700_000_000'i64

proc planOps(profileText: string): seq[PlannedOperationRecord] =
  ## Convenience: produce a plan and return its operation sequence in
  ## the planner's emitted order. The host identity + timestamp are
  ## pinned so the plan id is deterministic across runs.
  let result0 = producePlan(profileText, HostIdentity, now = FixedTimestamp)
  return result0.envelope.operations

suite "integration_explicit_depends_on (M82 Phase B)":

  # -------------------------------------------------------------------------
  # Scenario 1 — cyclic `depends_on` is refused at plan time.
  # -------------------------------------------------------------------------
  test "a cyclic depends_on graph is refused with the cycle named":
    # A 3-node cycle: A -> B -> C -> A. All three resources are
    # `fs.systemFile` so the test is platform-pure. The CYCLE itself
    # is detected by the topological-sort layer; the diagnostic carries
    # the full traversal path with the entry node repeated at the end.
    let profileText = """
fs.systemFile {
  path = "/etc/site-A"
  content = "A"
  depends_on = ["fs.systemFile:/etc/site-C"]
}
fs.systemFile {
  path = "/etc/site-B"
  content = "B"
  depends_on = ["fs.systemFile:/etc/site-A"]
}
fs.systemFile {
  path = "/etc/site-C"
  content = "C"
  depends_on = ["fs.systemFile:/etc/site-B"]
}
"""
    var raised = false
    var detail = ""
    try:
      discard producePlan(profileText, HostIdentity, now = FixedTimestamp)
    except EPlanCyclicDependency as e:
      raised = true
      detail = e.msg
      check e.cyclePath.len == 4         # 3 nodes + 1 closing repetition
      check e.cyclePath[0] == e.cyclePath[^1]
      # All three resources appear in the cycle (the path's first 3
      # entries are the cycle's nodes in traversal order).
      let nodes = e.cyclePath[0 ..< 3]
      check "systemFile:/etc/site-A" in nodes
      check "systemFile:/etc/site-B" in nodes
      check "systemFile:/etc/site-C" in nodes
    check raised
    # The exception message names "cycle" so the CLI surface can
    # render a one-line diagnostic without further introspection.
    check "cycle" in detail.toLowerAscii()

  # -------------------------------------------------------------------------
  # Scenario 2 — an explicit multi-hop chain is applied in topological
  #              order even when the declaration order REVERSES it.
  # -------------------------------------------------------------------------
  test "a multi-hop explicit chain emits A, B, C, D regardless of declaration order":
    # The four resources are declared D, C, B, A — the OPPOSITE of the
    # topological order. The dependency chain (A -> B -> C -> D, where
    # the arrow means "must run BEFORE") is encoded via `depends_on`
    # entries on B, C, D. The emitted plan must list A, B, C, D in
    # that order.
    let profileText = """
fs.systemFile {
  path = "/etc/repro-D"
  content = "D"
  depends_on = ["fs.systemFile:/etc/repro-C"]
}
fs.systemFile {
  path = "/etc/repro-C"
  content = "C"
  depends_on = ["fs.systemFile:/etc/repro-B"]
}
fs.systemFile {
  path = "/etc/repro-B"
  content = "B"
  depends_on = ["fs.systemFile:/etc/repro-A"]
}
fs.systemFile {
  path = "/etc/repro-A"
  content = "A"
}
"""
    let ops = planOps(profileText)
    check ops.len == 4
    # The emitted addresses must appear in topological order.
    check ops[0].address == "systemFile:/etc/repro-A"
    check ops[1].address == "systemFile:/etc/repro-B"
    check ops[2].address == "systemFile:/etc/repro-C"
    check ops[3].address == "systemFile:/etc/repro-D"
    # Every op preserves its kind tag so a downstream consumer can
    # still dispatch to the correct driver.
    for o in ops:
      check o.kindTag == "fs.systemFile"

  # -------------------------------------------------------------------------
  # Scenario 3 — implicit producer / consumer edge (the M69 motivating
  #              case): `windows.capability OpenSSH.Server` produces
  #              `windows.service sshd`. The user does NOT write
  #              `depends_on`; the planner infers the edge from the
  #              shared `ProducerConsumerMap` and orders the capability
  #              before the service.
  # -------------------------------------------------------------------------
  test "implicit-edge inference orders OpenSSH.Server capability before sshd service":
    # Declaration order: service FIRST, capability SECOND. The implicit
    # edge from the producer / consumer map MUST reverse this so the
    # emitted plan applies the capability before the service.
    let profileText = """
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
}
windows.capability {
  name = "OpenSSH.Server~~~~0.0.1.0"
}
"""
    let ops = planOps(profileText)
    check ops.len == 2
    # CAPABILITY first, SERVICE second — even though declaration order
    # was the OPPOSITE. This is the load-bearing assertion that closes
    # the original M69 sshd scenario at the planner layer.
    check ops[0].kindTag == "windows.capability"
    check ops[0].address == "capability:OpenSSH.Server~~~~0.0.1.0"
    check ops[1].kindTag == "windows.service"
    check ops[1].address == "service:sshd"

  # -------------------------------------------------------------------------
  # Scenario 3b — the implicit-edge inference is a NO-OP when only one
  # side of the producer / consumer pair is present. A profile with
  # just the capability (no consumer service) keeps the capability as
  # a single isolated op — and ditto for a profile with only the
  # service.
  # -------------------------------------------------------------------------
  test "implicit-edge inference does not invent missing consumers":
    let capOnly = """
windows.capability { name = "OpenSSH.Server~~~~0.0.1.0" }
"""
    let opsCap = planOps(capOnly)
    check opsCap.len == 1
    check opsCap[0].kindTag == "windows.capability"

    let svcOnly = """
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
}
"""
    let opsSvc = planOps(svcOnly)
    check opsSvc.len == 1
    check opsSvc[0].kindTag == "windows.service"

  # -------------------------------------------------------------------------
  # Scenario 4 — stable secondary order: two ops with NO dependency
  # between them keep their declaration order in the emitted plan, so
  # the plan output is byte-comparable across runs of the same profile
  # text.
  # -------------------------------------------------------------------------
  test "independent ops keep their declaration order (stable secondary key)":
    let profileText = """
fs.systemFile { path = "/etc/alpha" content = "1" }
fs.systemFile { path = "/etc/bravo" content = "2" }
fs.systemFile { path = "/etc/charlie" content = "3" }
"""
    let ops = planOps(profileText)
    check ops.len == 3
    check ops[0].address == "systemFile:/etc/alpha"
    check ops[1].address == "systemFile:/etc/bravo"
    check ops[2].address == "systemFile:/etc/charlie"

  # -------------------------------------------------------------------------
  # Scenario 5 — explicit + implicit edges combine: the same producer /
  # consumer pair declared with BOTH a `depends_on` entry AND an
  # implicit-map match still orders correctly (and does not double-
  # apply / introduce a duplicate edge).
  # -------------------------------------------------------------------------
  test "redundant explicit + implicit edges still produce a valid order":
    let profileText = """
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
  depends_on = ["windows.capability:OpenSSH.Server~~~~0.0.1.0"]
}
windows.capability {
  name = "OpenSSH.Server~~~~0.0.1.0"
}
"""
    let ops = planOps(profileText)
    check ops.len == 2
    check ops[0].kindTag == "windows.capability"
    check ops[1].kindTag == "windows.service"

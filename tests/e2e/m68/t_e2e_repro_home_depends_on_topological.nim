## M82 home-scope follow-up gate: integration_explicit_depends_on_home.
##
## The home-scope analog of
## `tests/e2e/m69/t_e2e_repro_infra_depends_on_topological.nim`. Per
## the M82 home-scope follow-up's verification block:
##
##   * `depends_on` in a `home.nim` `resources:` stanza is parsed;
##   * a cyclic dependency graph is refused at plan time with a clear
##     error naming the cycle;
##   * a multi-hop dependency chain (A -> B -> C -> D) is materialized
##     in topological order regardless of declaration order;
##   * independent ops keep their declaration order (stable secondary
##     key — the emitted action stream is byte-comparable across runs);
##   * the empty home `ProducerConsumerMap` is harmless (today no
##     home-scope producer/consumer pairs exist — a profile with no
##     `depends_on` produces actions in pure declaration order).
##
## The gate is PURE LOGIC — it loads a `home.nim` fixture via the home
## intent parser, composes the desired resource set (which the M82
## follow-up topologically sorts), and asserts the resulting iteration
## order. No `$HOME` mutation, no broker, no driver writes. Runs on
## every host.
##
## No `skip`, no `xfail`.

import std/[os, sequtils, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_home_intent
import repro_home_resources

const HostIdentity = "m82-home-gate-host"

proc writeProfileFixture(body: string): tuple[profileDir, profilePath: string] =
  ## Materialize a `home.nim` fixture under a per-test temp directory.
  ## Returns the profile dir + the absolute path to `home.nim`. The
  ## caller is responsible for cleanup; the temp dir is unique per
  ## invocation so concurrent test invocations do not collide.
  let dir = createTempDir("repro-m82-home-gate-", "")
  let path = dir / "home.nim"
  writeFile(extendedPath(path), body)
  result = (profileDir: dir, profilePath: path)

proc orderedAddresses(profileText: string): seq[string] =
  ## Convenience: write a `home.nim` containing `profileText` as its
  ## body (after the standard import + `profile "..."` header), load
  ## it, compose the desired resource set (which topologically sorts
  ## the resources via the M82 follow-up's `dep_graph` integration),
  ## and return the action ADDRESSES in emission order. The
  ## OrderedTable iteration order IS the topological order after the
  ## sort, so the resulting `seq[string]` is what the apply executor
  ## would walk.
  let (dir, path) = writeProfileFixture(profileText)
  defer:
    try: removeDir(extendedPath(dir)) except CatchableError: discard
  let profile = loadProfile(path)
  let desired = composeDesiredResources(profile, dir, HostIdentity)
  for addr0 in desired.resources.keys:
    result.add(addr0)

suite "integration_explicit_depends_on_home (M82 home-scope follow-up)":

  # -------------------------------------------------------------------------
  # Scenario 1 — cyclic `depends_on` is refused at plan time. The
  # cycle is named in the diagnostic so the operator can find it.
  # -------------------------------------------------------------------------
  test "a cyclic depends_on graph is refused with the cycle named":
    # A 3-node cycle A -> B -> C -> A. All three are `fs.managedBlock`
    # so the test is platform-pure.
    let profileText = """
import repro/profile

profile "m82-home-cycle":

  activity default:
    m82-home-fixture

  resources:
    fs.managedBlock A:
      hostFile = "~/.m82-A"
      blockId = "m82-A"
      content = "A"
      depends_on = ["fs.managedBlock:C"]
    fs.managedBlock B:
      hostFile = "~/.m82-B"
      blockId = "m82-B"
      content = "B"
      depends_on = ["fs.managedBlock:A"]
    fs.managedBlock C:
      hostFile = "~/.m82-C"
      blockId = "m82-C"
      content = "C"
      depends_on = ["fs.managedBlock:B"]

  hosts:
    "m82-home-gate-host": [default]
"""
    var raised = false
    var detail = ""
    try:
      discard orderedAddresses(profileText)
    except EHomePlanCyclicDependency as e:
      raised = true
      detail = e.msg
      # 3 nodes + 1 closing repetition; first == last.
      check e.cyclePath.len == 4
      check e.cyclePath[0] == e.cyclePath[^1]
      let nodes = e.cyclePath[0 ..< 3]
      check "A" in nodes
      check "B" in nodes
      check "C" in nodes
    check raised
    check "cycle" in detail.toLowerAscii()

  # -------------------------------------------------------------------------
  # Scenario 2 — a multi-hop explicit chain is materialized in
  # topological order even when the declaration order REVERSES it.
  # -------------------------------------------------------------------------
  test "a multi-hop explicit chain emits A, B, C, D regardless of declaration order":
    # Declaration order: D, C, B, A — the OPPOSITE of topological.
    # Chain: A -> B -> C -> D (arrow == "must run BEFORE") encoded via
    # `depends_on` entries on B, C, D.
    let profileText = """
import repro/profile

profile "m82-home-chain":

  activity default:
    m82-home-fixture

  resources:
    fs.managedBlock D:
      hostFile = "~/.m82-D"
      blockId = "m82-D"
      content = "D"
      depends_on = ["fs.managedBlock:C"]
    fs.managedBlock C:
      hostFile = "~/.m82-C"
      blockId = "m82-C"
      content = "C"
      depends_on = ["fs.managedBlock:B"]
    fs.managedBlock B:
      hostFile = "~/.m82-B"
      blockId = "m82-B"
      content = "B"
      depends_on = ["fs.managedBlock:A"]
    fs.managedBlock A:
      hostFile = "~/.m82-A"
      blockId = "m82-A"
      content = "A"

  hosts:
    "m82-home-gate-host": [default]
"""
    let addrs = orderedAddresses(profileText)
    check addrs.len == 4
    check addrs[0] == "A"
    check addrs[1] == "B"
    check addrs[2] == "C"
    check addrs[3] == "D"

  # -------------------------------------------------------------------------
  # Scenario 3 — independent ops keep their declaration order: the
  # stable secondary key. Two resources with no dependency between
  # them MUST emit in the order they were declared so the plan output
  # is byte-comparable across runs of the same profile text.
  # -------------------------------------------------------------------------
  test "independent ops keep declaration order (stable secondary key)":
    let profileText = """
import repro/profile

profile "m82-home-independent":

  activity default:
    m82-home-fixture

  resources:
    fs.managedBlock alpha:
      hostFile = "~/.m82-alpha"
      blockId = "m82-alpha"
      content = "1"
    fs.managedBlock bravo:
      hostFile = "~/.m82-bravo"
      blockId = "m82-bravo"
      content = "2"
    fs.managedBlock charlie:
      hostFile = "~/.m82-charlie"
      blockId = "m82-charlie"
      content = "3"

  hosts:
    "m82-home-gate-host": [default]
"""
    let addrs = orderedAddresses(profileText)
    check addrs.len == 3
    check addrs[0] == "alpha"
    check addrs[1] == "bravo"
    check addrs[2] == "charlie"

  # -------------------------------------------------------------------------
  # Scenario 4 — the empty home `ProducerConsumerMap` is harmless. The
  # CURRENT STATE: no home-scope producer/consumer pairs exist. A
  # profile with no `depends_on` declarations therefore produces an
  # action stream in pure declaration order — the implicit-edge layer
  # adds zero edges. This pins the "empty table is a no-op" invariant
  # so the planner code path that calls `lookupProducedResources`
  # remains correct when the first home entry is added later.
  # -------------------------------------------------------------------------
  test "empty home producer-consumer table is harmless":
    let profileText = """
import repro/profile

profile "m82-home-implicit-empty":

  activity default:
    m82-home-fixture

  resources:
    fs.managedBlock first:
      hostFile = "~/.m82-first"
      blockId = "m82-first"
      content = "1"
    env.userPath launcherDir:
      entries = "~/.m82/bin"
    shell.integration secondBlock:
      hostFile = "~/.m82-second"
      blockId = "m82-second"
      content = "echo hello"

  hosts:
    "m82-home-gate-host": [default]
"""
    let addrs = orderedAddresses(profileText)
    check addrs.len == 3
    # No `depends_on`, no implicit edges (table is empty) -> pure
    # declaration order. The action stream is byte-comparable across
    # runs because Kahn's secondary key is the declaration index.
    check addrs[0] == "first"
    check addrs[1] == "launcherDir"
    check addrs[2] == "secondBlock"

  # -------------------------------------------------------------------------
  # Scenario 5 — mixed implicit + explicit handling. The home
  # producer-consumer table is INTENTIONALLY EMPTY today (no known
  # home-scope producer/consumer pairs), so this scenario is gated on
  # a `when false:` block with a documentation comment explaining what
  # it WILL cover once the first home implicit edge is added. The
  # planner already invokes `lookupProducedResources` for every
  # resource on every plan — the data-table change alone activates the
  # scenario without a planner change.
  # -------------------------------------------------------------------------
  when false:
    # Activate this block when the first home-scope entry lands in
    # `home_producer_consumer_map.ProducerConsumerMap`. The scenario
    # should mirror the system-scope "redundant explicit + implicit
    # edges still produce a valid order" test:
    #
    #   * declare a producer-consumer pair the table knows about;
    #   * additionally declare an explicit `depends_on` from the
    #     consumer to the producer;
    #   * assert (a) the action stream orders producer before consumer;
    #     (b) the dedupe logic in `record()` (in `dep_graph.nim`)
    #     promotes the duplicate edge to `edkExplicit` so a future
    #     cycle diagnostic names the user's `depends_on` source.
    test "mixed implicit + explicit edges still produce a valid order":
      check false                          # placeholder

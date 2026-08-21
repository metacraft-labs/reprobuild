## Every metadata object kind is fetched, and each is distinguishable in the
## recorded path set.
##
## Named-Lock-Files NLF-M6, **first folded criterion from NLF-M5**:
##
## > **The remaining metadata object kinds.** M5 ships exactly one (a package's
## > version list). The root manifest, index shards, acquisition records and
## > curator snapshot indexes that `Repository-And-Index-Format.md` enumerates
## > are the same edge shape and are not implemented. A test must fetch at
## > least one of each kind and assert the kind is distinguishable in the
## > recorded path set — otherwise materiality cannot discriminate between
## > them.
##
## ## Why "distinguishable" is the requirement and not "present"
##
## If the recorded path set carried only a subject and a digest, then a change
## to `libfoo`'s version list and a change to the index shard `l` would be the
## same observation whenever their subjects collided, and materiality could not
## say which one moved. Worse, the two kinds have DIFFERENT filter semantics —
## a version list is an enumeration a strategy narrows to an interval, and an
## index shard is a document read whole — so conflating them would apply an
## interval filter to a document and silently ignore most of its content.
##
## So this file asserts three separate things:
##
##   1. all five kinds are FETCHED, over the real socket, in ONE wave;
##   2. all five appear in the recorded path set, tagged with their kind;
##   3. the kinds are treated DIFFERENTLY — the version list carries an
##      interval filter and the other four are raw whole-document reads — and
##      a change to each kind invalidates independently of the others.
##
## (3) is the one that makes (2) mean something. A path set that recorded the
## tag and then ignored it would pass (1) and (2).
##
## ## Which five, and why not eight
##
## `Repository-And-Index-Format.md` §"Data Model Overview" enumerates eight
## object types. `MetadataObjectKind`'s own documentation records why three are
## absent: the package metadata envelope duplicates facts the version list
## already carries, and the artifact manifest and mirror closure index are
## consumed when REALIZING a solved graph rather than when solving one, so a
## fetch edge for them belongs to the second wave.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full. The four
## non-version-list objects are published as fixture bytes at their real
## repository paths and retrieved over the same real socket as everything else.

import std/[strutils, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  AllKinds = {mokRootManifest, mokIndexShard, mokVersionList,
              mokAcquisitionRecord, mokCuratorSnapshotIndex}

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

proc publishEverything(reg: Registry; manifest = "format = 1\n") =
  ## One object of every kind, at the paths `metadataObjectUrl` names.
  reg.server.publish(App, ["1.0.0"])
  reg.server.publish(LibFoo, ["1.2.0", "1.4.0", "1.9.0"])
  reg.server.publishAt("repository.manifest", manifest)
  reg.server.publishAt("snapshots.index", "snapshot = \"2026-08\"\n")
  # Acquisition records are planned from the STATICALLY declared candidate
  # versions, so `app@1.0.0` and `libfoo@1.2.0` are the two the plan asks for.
  reg.server.publishAt("index/a.shard", "app\n")
  reg.server.publishAt("index/l.shard", "libfoo\n")
  reg.server.publishAt("acquisition/app@1.0.0.acquisition", "method = \"tar\"\n")
  reg.server.publishAt("acquisition/libfoo@1.2.0.acquisition",
    "method = \"tar\"\n")

suite "the plan reaches every object kind, in one wave":

  test "all five kinds are planned and fetched":
    let reg = startRegistry("kinds-fetch")
    try:
      reg.publishEverything()
      let req = reg.request(workspace(), lsLowest, kinds = AllKinds)
      var planned: seq[string] = @[]
      for entry in req.fetchPlan():
        if $entry.kind notin planned: planned.add($entry.kind)
      for k in AllKinds:
        check $k in planned

      let served = reg.server.requestsServed()
      let r = runLockSolve(req, "")
      check r.solveExecuted
      check r.fetchAttempts >= 5
      check reg.server.requestsServed() > served
      # §5.6's over-approximation property: ONE wave. Adding four object kinds
      # must not have turned the generation into a fixpoint.
      check r.fetchWaves.len == 1
    finally:
      reg.shutdown()

  test "the default kind set is still version lists alone":
    # NLF-M5's fetch plan must be byte-unchanged for a caller that asks for
    # nothing, or every pre-existing generation acquires four extra network
    # round-trips.
    let reg = startRegistry("kinds-default")
    try:
      reg.publishEverything()
      let req = reg.request(workspace(), lsLowest)
      for entry in req.fetchPlan():
        check entry.kind == mokVersionList
    finally:
      reg.shutdown()

suite "every kind is distinguishable in the recorded path set":

  test "each kind appears, tagged":
    let reg = startRegistry("kinds-recorded")
    try:
      reg.publishEverything()
      let r = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      let kinds = r.kindsObserved()
      for k in AllKinds:
        check $k in kinds
    finally:
      reg.shutdown()

  test "the version list is an ENUMERATION and the rest are documents":
    let reg = startRegistry("kinds-semantics")
    try:
      reg.publishEverything()
      let r = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      for obs in r.pathSet.observations:
        if obs.kind == mokVersionList:
          check isEnumerationKind(obs.kind)
          check obs.filter == mfInterval
          check obs.low.len > 0 or obs.high.len > 0
        else:
          check not isEnumerationKind(obs.kind)
          check obs.filter == mfRaw
          # And the reason says WHY it is raw, so this is not confused with
          # §5.7's interval-uncomputable fallback.
          check obs.reason.contains("document")
    finally:
      reg.shutdown()

  test "two kinds sharing a subject do not collide":
    # `libfoo` the package and `l` the shard are different objects; a path set
    # keyed on the subject alone would already be ambiguous here, and one
    # keyed on the retrieved bytes alone would be ambiguous whenever two
    # objects happened to hold the same text.
    let reg = startRegistry("kinds-collision")
    try:
      reg.publishEverything()
      # Deliberately identical bodies across two kinds.
      reg.server.publishAt("repository.manifest", "same\n")
      reg.server.publishAt("snapshots.index", "same\n")
      let r = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      var locators: seq[string] = @[]
      for obs in r.pathSet.observations:
        let loc = observationLocator(obs)
        check loc notin locators
        locators.add(loc)
      check locators.len == r.pathSet.observations.len
    finally:
      reg.shutdown()

suite "a change to each kind invalidates independently":

  test "the root manifest moving invalidates; an untouched kind does not":
    let reg = startRegistry("kinds-invalidate")
    try:
      reg.publishEverything()
      let first = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      check first.solveExecuted

      # Control: nothing moved.
      let same = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      check not same.solveExecuted

      # The root manifest moves — a kind the version-list observation says
      # nothing about.
      reg.server.publishAt("repository.manifest", "format = 2\n")
      let after = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      check after.solveExecuted
      check after.pathSetHitIndex == -1
    finally:
      reg.shutdown()

  test "a version-list publication outside the interval still does not":
    # The pair. If EVERY kind were recorded raw, this would invalidate too, and
    # the test above would be reporting a working filter for a path set that
    # simply always changes.
    let reg = startRegistry("kinds-pair")
    try:
      reg.publishEverything()
      let first = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      check first.solveExecuted
      check first.intervalOf(LibFoo) == "[1.2.0, 1.2.0]"

      reg.server.publish(LibFoo, ["1.2.0", "1.4.0", "1.9.0", "1.10.0"])
      let after = reg.generate(workspace(), lsLowest, kinds = AllKinds)
      check not after.solveExecuted
      check after.lockDocument == first.lockDocument
    finally:
      reg.shutdown()

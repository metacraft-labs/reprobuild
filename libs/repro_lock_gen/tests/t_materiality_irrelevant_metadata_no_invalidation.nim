## Publishing something the solve never consulted does not invalidate its lock.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-GEN-1**: "Publishing a package
## the solve never consulted produces a cache hit."
##
## Design §5.7:
##
## > **run the solve, record which metadata facts it consulted, key the edge on
## > that observed set.** A registry adding a package the solve never looked at
## > does not invalidate; a change inside something it did consult does.
## > Materiality derived, not declared.
##
## ## Every claim here is PAIRED, because a one-sided one proves nothing
##
## NLF-M6's exit criteria make this a hard requirement rather than a
## preference:
##
## > **Every materiality claim is measured, not asserted.** A test that shows
## > "no invalidation occurred" must also show the mutation that DOES
## > invalidate, in the same run. A one-sided materiality test cannot
## > distinguish a working filter from a fingerprint that never changes.
##
## So the fixture below carries THREE registry mutations against one recorded
## path set, and the third is what gives the first two their meaning:
##
##   1. a new version of `libssl`, whose metadata WAS fetched (§5.6's
##      over-approximation across variant arms) and which the solve did not
##      consult because the `tls` variant resolved to `false` — **no
##      invalidation**;
##   2. an entirely new package the fetch plan never asked for — **no
##      invalidation**;
##   3. a new version of `libfoo` INSIDE the interval the solve's answer
##      depended on — **invalidation, and the answer moves**.
##
## Without (3), an implementation whose strong fingerprint was a constant
## would pass (1) and (2) perfectly.
##
## ## Why case (1) is the one that needed NLF-M9
##
## `libssl`'s version list is fetched. It is on disk next to `libfoo`'s when
## the solve runs. The only thing that distinguishes it is that nothing
## SELECTED it — which is the fact NLF-M9 made the solve record
## (`UnifiedSolution.selected`, derived in the ASP from the same
## `variant_assigned` atom that gates the range constraint). An implementation
## that keyed the solve edge on the files it was handed, rather than on the
## packages it consulted, would invalidate here; and it would do so while
## producing an identical lock, so only the solve-execution assertion catches
## it.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full for every
## test that imports it: a real loopback HTTP server, the real in-process
## fetch client, real engine edges, a real clingo solve, a real lock writer,
## and a real on-disk path-set store.

import std/[os, strutils, tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  LibSsl = "libssl"
  Unrelated = "libunrelated"
  Tls = "tls"

proc workspace(): seq[PackageDecl] =
  ## `app` depends on `libfoo` unconditionally and on `libssl` only when the
  ## `tls` variant is on. `tls` is pinned OFF, so the `libssl` arm is dormant —
  ## and §5.6's over-approximation fetches its metadata anyway.
  @[
    newPackage(App, @["1.0.0"], @[
      newDependency(LibFoo, ">=1.2"),
      newConditionalDependency(LibSsl, ">=3.0", Tls, "true")]),
    newPackage(LibFoo, @["1.4.0"]),
    newPackage(LibSsl, @["3.0.0"])]

proc tlsOff(): seq[VariantDecl] =
  ## Pinned rather than merely defaulted, so the arm's dormancy is a fact of
  ## the program and not an artifact of which model clingo happened to return.
  @[newBoolVariant(Tls, pinnedValue = "false")]

suite "NLF-GEN-1 the premise: the dormant arm's metadata IS fetched":
  ## Stated first, because "publishing `libssl` did not invalidate" is only
  ## interesting if `libssl` was fetched. If it were never retrieved, the test
  ## below would be measuring the fetch plan rather than materiality.

  test "libssl is fetched even though the tls arm is dormant":
    let reg = startRegistry("gen1-premise")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      reg.server.publish(LibSsl, ["3.0.0", "3.1.0"])
      let req = reg.request(workspace(), lsLowest, tlsOff())
      var planned: seq[string] = @[]
      for entry in req.fetchPlan():
        planned.add(entry.subject)
      check LibSsl in planned
      check LibFoo in planned

      let r = runLockSolve(req, "")
      check r.solveExecuted
      # Fetched, and then NOT consulted: the observation set names `libfoo`
      # and not `libssl`. That asymmetry is the whole mechanism.
      check r.observedPackages() == @[App, LibFoo]
      check r.intervalOf(LibSsl) == "absent"
    finally:
      reg.shutdown()

suite "NLF-GEN-1 immaterial publications do not invalidate":

  test "three mutations, two immaterial and one material, in one run":
    let reg = startRegistry("gen1")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      reg.server.publish(LibSsl, ["3.0.0", "3.1.0"])

      # --- the recorded solve -------------------------------------------
      let first = runLockSolve(reg.request(workspace(), lsLowest, tlsOff()), "")
      check first.solveExecuted
      check first.resolved()[LibFoo] == "1.4.0"
      # `>=1.2` selecting 1.4 under `lowest`: the interval covers the gap
      # between the declared bound and the lowest published version.
      check first.intervalOf(LibFoo) == "[1.2.0, 1.4.0]"

      # --- mutation 1: a new version of the UNSELECTED package ----------
      reg.server.publish(LibSsl, ["3.0.0", "3.1.0", "3.9.0"])
      let afterSsl = runLockSolve(reg.request(workspace(), lsLowest, tlsOff()), "")
      check not afterSsl.solveExecuted
      check afterSsl.pathSetHitIndex == 0
      check afterSsl.lockDocument == first.lockDocument

      # --- mutation 2: an entirely new package nothing asked for --------
      reg.server.publish(Unrelated, ["7.0.0"])
      let afterNew = runLockSolve(reg.request(workspace(), lsLowest, tlsOff()), "")
      check not afterNew.solveExecuted
      check afterNew.pathSetHitIndex == 0
      check afterNew.lockDocument == first.lockDocument

      # --- mutation 3: THE PAIR. A publication inside the interval ------
      #
      # Without this, everything above is satisfied by a strong fingerprint
      # that never changes.
      reg.server.publish(LibFoo, ["1.3.0", "1.4.0", "1.9.0"])
      let afterFoo = runLockSolve(reg.request(workspace(), lsLowest, tlsOff()), "")
      check afterFoo.solveExecuted
      check afterFoo.pathSetHitIndex == -1
      check afterFoo.resolved()[LibFoo] == "1.3.0"
      check afterFoo.lockDocument != first.lockDocument

      # And the store now carries TWO path sets under one weak fingerprint —
      # the two-phase structure, not a single-entry cache under a longer name.
      check afterFoo.solveWeakFingerprint == first.solveWeakFingerprint
      check afterFoo.pathSetsRecorded == 2
    finally:
      reg.shutdown()

  test "the immaterial mutations really did reach the registry":
    # A publication that silently failed to land would produce "no
    # invalidation" for the wrong reason, and the test above cannot tell the
    # difference. This reads the served bytes back over the same real socket.
    let reg = startRegistry("gen1-landed")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0"])
      reg.server.publish(LibSsl, ["3.0.0"])
      discard runLockSolve(reg.request(workspace(), lsLowest, tlsOff()), "")
      reg.server.publish(LibSsl, ["3.0.0", "3.9.0"])
      let req = reg.request(workspace(), lsLowest, tlsOff())
      discard runLockSolve(req, "")
      var sslPath = ""
      for entry in req.fetchPlan():
        if entry.kind == mokVersionList and entry.subject == LibSsl:
          sslPath = entry.objectPath
      check sslPath.len > 0
      check fileExists(sslPath)
      check readFile(sslPath).contains("3.9.0")
    finally:
      reg.shutdown()

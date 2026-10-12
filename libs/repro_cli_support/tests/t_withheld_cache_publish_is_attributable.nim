## A cacheable edge that is DENIED a cache-record publish must say so, in
## one run, naming the cause.
##
## THE DEFECT THIS PINS, as measured on the shipped `examples/hello-world-c`
## (reprobuild-specs/issues/2026-10-06-…-link-edge-never-caches-…):
##
##   action: ccpp-direct-link-hello-world-c status=asSucceeded launched=true
##           cache=cdMiss reason=exit=0 … evidence=depfile:0
##
## — on build 1, build 2, build 5 and every build after. The edge's root
## image resolved to `/usr/bin/gcc`, Apple's SIP-protected xcrun shim; macOS
## strips `DYLD_INSERT_LIBRARIES` when it execs a platform binary, so the
## monitor shim never loads, io-mon reports an unknown-scope loss, and
## `applyMonitorEvidenceStatus` withholds the record. Every step of that is
## the FAIL-CLOSED arm `Failure-Semantics.md` §"Monitoring Failures" and
## `Monitor-Loss-Path-Invalidation.md` §Vocabulary require, and it is not
## what this suite asks to change.
##
## What was wrong is that it was unsayable. `reason` is overwritten by
## `completeSuccess` with the settle detail (`exit=0`) for exactly the
## actions that LAUNCH, `cacheMissReason` reads "no cache record for weak
## fingerprint" — true, and identical to a first build — and the only record
## of the withheld publish was a scheduler TRACE no build log prints. A
## permanent cache miss was therefore indistinguishable from a cold one, and
## that is how it survived in the canonical example.
## `Action-Cache-Per-Edge-Store.md` §8.3: "a cost that cannot be attributed
## cannot be defended."
##
## NO MOCKS, and the mock that would have been easy here is the one that
## would have made the suite worthless. The condition is not simulated with
## a hand-built RMDF: the SIP arm EXECS A REAL SIP-PROTECTED PLATFORM BINARY
## (`/usr/bin/true`) through the real monitor driver, the real shim, the real
## evidence fold and the real per-edge store, and the loss is the one the
## kernel really produces. A synthetic capture would have graded the fold's
## bookkeeping; this grades the host behaviour the defect is made of.
##
## THE NON-SIP ARM IS WHAT MAKES THE SIP ARM A STATEMENT ABOUT SIP. Same
## graph shape, same config, same cache root discipline, root image swapped
## for the Nix clang wrapper on PATH: it publishes one record, the second
## build is a `cdHit`, and `cachePublishSkipReason` is EMPTY. Without that
## arm, "the SIP edge never publishes" could be a fact about the fixture.
##
## PLATFORM. The SIP arms are macOS-only, because a SIP-protected image is.
## They `skip()` elsewhere rather than passing: the renderer cases below are
## platform-independent and still run, so a Linux CI run grades the half it
## can and says it skipped the half it cannot.

import std/[os, strutils, unittest]

import repro_build_engine
from repro_test_support import prepareMonitorTools
import repro_test_support/reasoned_skip
import repro_cli_support

const SipImage = "/usr/bin/true"
  ## A SIP-protected platform binary present on every macOS. `/usr/bin` is
  ## in the shared `sipProtectedPrefixes` population io-mon and the engine
  ## both read (`stackable_hooks/propagation`), so this is the same
  ## predicate the production path applies — not a second opinion about
  ## which paths are protected.

proc hostedConfig(cacheRoot: string): BuildEngineConfig =
  let tools = prepareMonitorTools(getCurrentDir(),
    getCurrentDir() / "build" / "test-withheld-publish", "withheld-publish")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: tools.monitorCliPath,
    monitorCliPath: tools.monitorCliPath,
    monitorCliArgs: tools.monitorCliArgs,
    maxParallelism: 1,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    bypassRunQuota: true,
    monitorHosting: mhmNever)

proc scratchRoot(name: string): string =
  result = absolutePath("build" / "test-tmp" /
    "t_withheld_cache_publish" / name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc perEdgeRecordDirCount(cacheRoot: string): int =
  ## How many edges have a per-edge record directory under this cache root.
  ##
  ## The DIRECT statement of "did anything get published", and the one the
  ## issue's own evidence was taken from. It counts directories rather than
  ## asking the cache, so a withheld publish cannot be mistaken for a
  ## published record the reader then failed to match.
  let root = cacheRoot / "action-cache" / "hot-records"
  if not dirExists(root):
    return 0
  for kind, _ in walkDir(root):
    if kind == pcDir:
      inc result

proc oneAction(id: string; argv: openArray[string]; work: string): BuildGraph =
  ## `cacheable = true` is load-bearing: with the default every build
  ## reports `cdNotCacheable`, nothing is ever withheld, and both arms below
  ## would agree for a reason that has nothing to do with the monitor.
  graph([action(id, argv, cwd = work, cacheable = true,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())])

suite "a withheld cache publish is attributable from one run":

  test "SIP root image: the withheld publish is reported, with its cause":
    when not defined(macosx):
      skip("not macOS; a SIP-protected root image is a macOS-only condition")
    else:
      let root = scratchRoot("sip")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"

      let first = runBuild(oneAction("withheld-sip", [SipImage], work),
        hostedConfig(cacheRoot))
      check first.results.len == 1
      let a = first.results[0]

      # The state being graded, stated rather than assumed: the action ran
      # and succeeded, and NOTHING was published for it.
      check a.status == asSucceeded
      check a.launched
      check perEdgeRecordDirCount(cacheRoot) == 0

      # THE PROPERTY. Before this change the field did not exist and the
      # only record of the withheld publish was a scheduler trace.
      check a.cachePublishSkipReason.len > 0
      check "monitor-loss" in a.cachePublishSkipReason
      check "re-run on every build" in a.cachePublishSkipReason
      # And it names the CAUSE, not just the reason code. `cirMonitorLoss`
      # is also what a kill-before-flush and a breakaway daemon produce, and
      # those are transient; this one is permanent, and only the image says
      # which of the three happened.
      check SipImage in a.cachePublishSkipReason
      check "SIP-protected" in a.cachePublishSkipReason

      # The second build is the one the issue is about: nothing changed,
      # and the edge re-runs anyway, because there is still no record.
      let second = runBuild(oneAction("withheld-sip", [SipImage], work),
        hostedConfig(cacheRoot))
      check second.results.len == 1
      let b = second.results[0]
      check b.launched
      check b.cacheDecision == cdMiss
      check perEdgeRecordDirCount(cacheRoot) == 0
      # `reason` still carries the SETTLE detail and still says nothing
      # about the cache. That is deliberate and unchanged — the attribution
      # is a separate field precisely so the action line's shape does not
      # move for every build in the world.
      check b.reason == "exit=0"
      check b.cachePublishSkipReason.len > 0

  test "non-SIP root image: publishes, hits, and reports no skip (control)":
    ## Non-vacuity for the case above. If this arm did not hit, "the SIP
    ## edge never publishes" would be a fact about this fixture.
    when not defined(macosx):
      skip("not macOS; a SIP-protected root image is a macOS-only condition")
    else:
      let nonSip = findExe("cc")
      if nonSip.len == 0 or nonSip.startsWith("/usr/bin/") or
          nonSip.startsWith("/bin/"):
        # Refuse to report a pass this host cannot earn: without an
        # injectable compiler on PATH the control proves nothing.
        raise newException(ValueError,
          "this host has no non-SIP `cc` on PATH (found: " &
          (if nonSip.len == 0: "none" else: nonSip) &
          "), so the control arm cannot distinguish a SIP root image from " &
          "a fixture that never publishes. It refuses to pass instead.")
      let root = scratchRoot("nonsip")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"

      let first = runBuild(
        oneAction("withheld-nonsip", [nonSip, "--version"], work),
        hostedConfig(cacheRoot))
      check first.results.len == 1
      check first.results[0].status == asSucceeded
      check first.results[0].launched
      check first.results[0].cachePublishSkipReason.len == 0
      check perEdgeRecordDirCount(cacheRoot) == 1

      let second = runBuild(
        oneAction("withheld-nonsip", [nonSip, "--version"], work),
        hostedConfig(cacheRoot))
      check second.results.len == 1
      check not second.results[0].launched
      check second.results[0].cacheDecision == cdHit
      # WHICH ARM ANSWERED, pinned rather than assumed. A whole-graph hit can
      # also come from the no-op PREFIX (`tryFastNoopCacheHits`), and a case
      # that only checked `cdHit` would be satisfied either way — so "this
      # edge's own lookup hit" would not be what it had shown.
      # `asCacheHit` is reachable only from the scheduler's per-edge `aclHit`
      # arm; the prefix settles every action it serves as `asUpToDate`
      # (`fastNoopReuseReason`). This config also leaves
      # `rebuildMissingOutputsOnCacheHit` false, which the prefix refuses on
      # before it stats anything — belt and braces, and the status is the
      # part that stays true if that default ever changes.
      check second.results[0].status == asCacheHit
      check second.results[0].cachePublishSkipReason.len == 0
      check perEdgeRecordDirCount(cacheRoot) == 1

  test "the action log renders the withheld publish and the miss reason":
    ## The rendering half. `cacheAttributionLines` is the ONLY path by which
    ## either field reaches a build log: `--log=actions` prints `reason`,
    ## which `completeSuccess` has already overwritten with the settle
    ## detail, so a launched action's cache verdict was unreachable from the
    ## console however many `-v`s were passed.
    ##
    ## WHAT THIS CASE DOES NOT REACH. The two `--log=actions` loops that
    ## CALL this are inside a proc whose `logAction` is a local template, so
    ## there is no seam a unit case can observe; deleting the call sites
    ## leaves this suite green. That wiring was verified by a measured
    ## `reprobuild build` of `examples/hello-world-c` and is NOT covered
    ## here — an e2e case over the CLI's rendered output is the gap.
    let launchedAndWithheld = ActionResult(
      id: "e", status: asSucceeded, launched: true, cacheDecision: cdMiss,
      reason: "exit=0",
      cacheMissReason: "no cache record for weak fingerprint",
      cachePublishSkipReason: "reasons=monitor-loss; this edge will re-run")
    let lines = cacheAttributionLines(launchedAndWithheld)
    # `require`, not `check`: the two index reads below are only meaningful
    # once the length is known, and a `check` would let the case die on an
    # IndexDefect that reads like a harness fault rather than a failure.
    require lines.len == 2
    check lines[0].strip() ==
      "cache-miss: no cache record for weak fingerprint"
    check lines[1].strip().startsWith("cache-publish-skipped: ")
    check "monitor-loss" in lines[1]

  test "a clean action adds no lines at all":
    ## The cost side of the rule above. A build in which every edge behaves
    ## must print exactly what it printed before — otherwise the attribution
    ## is bought with noise on every action in every build, which is how a
    ## diagnostic gets turned off.
    check cacheAttributionLines(ActionResult(
      id: "e", status: asUpToDate, launched: false, cacheDecision: cdHit,
      reason: "outputs-present")).len == 0
    # A HIT that is not launched carries no miss reason by construction; a
    # launched action with no reason recorded carries none either.
    check cacheAttributionLines(ActionResult(
      id: "e", status: asSucceeded, launched: true, cacheDecision: cdMiss,
      reason: "exit=0")).len == 0

  test "a warm edge that missed says how many candidates it considered":
    ## The other half of §8.3 applied to a miss: "it had records and matched
    ## none" is a different event from "there are no records", and the two
    ## were reported with messages a reader could not separate. Graded here
    ## through the engine rather than against the string, so the count comes
    ## from a real candidate walk.
    when not defined(macosx):
      skip("not macOS; a SIP-protected root image is a macOS-only condition")
    else:
      let nonSip = findExe("cc")
      if nonSip.len == 0 or nonSip.startsWith("/usr/bin/"):
        skip("no non-SIP `cc` on PATH; the candidate walk needs an " &
          "injectable compiler to publish a record to be a candidate")
      else:
        let root = scratchRoot("candidates")
        let work = root / "work"
        createDir(work)
        let cacheRoot = root / "cache"
        let probe = work / "probe.txt"
        writeFile(probe, "one")

        proc g(): BuildGraph =
          graph([action("candidate-count",
            @[nonSip, "-E", "-x", "c", probe, "-o", work / "out.i"],
            cwd = work, inputs = [probe], outputs = [work / "out.i"],
            cacheable = true,
            governingLockIdentity = lockIdentityOutsideSolvedGraph())])

        check runBuild(g(), hostedConfig(cacheRoot)).results[0].launched
        # Move the input so the stored record cannot match, then look again.
        writeFile(probe, "two")
        let warm = runBuild(g(), hostedConfig(cacheRoot))
        let item = warm.results[0]
        check item.launched
        check item.cacheMissReason.len > 0
        check "candidate record" in item.cacheMissReason

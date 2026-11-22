## The `flake.lock` stage of the pre-push gate does not refuse a push because
## the workspace's ONE checkout of a sibling sits at another participating
## repo's committed pin, and its verdict does not depend on which of the two
## repos pushes first.
##
## Spec: Unified-Locking-And-Hooks.md §13.6 (amended 2026-11-22, "A shared
## checkout another participating repo pins"). Observed 2026-11-22: this
## repository pins its shared modules repo at `109058e`, another repository of
## the same workspace pins it 9 commits later at `13b6de6`, and whichever pushed second was refused
## (`flake_lock_stale`), once as "unfetched" and once as "9 commit(s) AHEAD".
##
## ## The shape
##
## The NF-2 fixture's `app` pins `alpha` at its seed revision. `delta`, another
## participating repo, is made a flake consumer of `alpha` too and pins it one
## published commit later. Both locks are committed and published.
##
##   1. checkout at delta's pin: `app`'s push is NOT refused; the gate prints a
##      notice naming `delta` and both pins (`deferred=shared-checkout`);
##   2. checkout at app's pin: `delta`'s push is NOT refused, symmetrically —
##      the order of the two pushes no longer decides anything;
##   3. checkout at a THIRD revision nobody pins: both pushes are refused,
##      exactly as before;
##   4. a pin that exists only as an UNCOMMITTED edit of delta's lock does not
##      hold the checkout: `app` is refused.
##
## Arms 1 and 2 fail on the unfixed gate (it refuses `flake_lock_stale`);
## arms 3 and 4 are the controls that keep the exception narrow.
##
## Test-double policy: NO mocks, doubles or fakes — real bare origins, real
## clones, real committed locks and the real `./build/bin/repro` gate. See the
## headers of `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture
import repro_test_support/reasoned_skip

proc noticesOf(report: JsonNode): seq[string] =
  if report.kind == JObject and report.hasKey("notices"):
    for n in report["notices"]: result.add(n.getStr())

proc sharedCheckoutNotice(report: JsonNode; pinnedBy: string): string =
  ## The gate's notice for a row held by ``pinnedBy``'s committed pin, or "".
  for n in noticesOf(report):
    if n.contains("deferred=shared-checkout") and
        n.contains("pinnedBy=" & pinnedBy):
      return n

proc writeDeltaLock(fx: Nf2Fixture; alphaRev: string) =
  writeFile(siblingDir(fx, "delta") / "flake.lock",
    "{\n" &
    "  \"nodes\": {\n" &
    lockedNode("alpha-src", originUrl(fx, "alpha"), alphaRev,
      "sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=", "    ") & ",\n" &
    "    \"root\": {\n" &
    "      \"inputs\": {\n" &
    "        \"alpha-src\": \"alpha-src\"\n" &
    "      }\n" &
    "    }\n" &
    "  },\n" &
    "  \"root\": \"root\",\n" &
    "  \"version\": 7\n" &
    "}\n")

proc makeDeltaAnAlphaConsumer(fx: Nf2Fixture; alphaRev: string) =
  ## `delta` becomes a flake that consumes `alpha` by the same origin URL
  ## `app` uses, so the gate's identity binding ties both inputs to the one
  ## `alpha` checkout. Its lock pins ``alphaRev``.
  let delta = siblingDir(fx, "delta")
  writeFile(delta / "flake.nix",
    "{\n" &
    "  inputs = {\n" &
    "    alpha-src.url = \"git+" & originUrl(fx, "alpha") & "?ref=main\";\n" &
    "  };\n" &
    "  outputs = _: { };\n" &
    "}\n")
  writeDeltaLock(fx, alphaRev)

proc commitAndPublishDelta(fx: Nf2Fixture; message: string) =
  let delta = siblingDir(fx, "delta")
  discard gitIn(fx, delta, "add -A")
  discard gitIn(fx, delta, "commit -q -m " & q(message))
  publishRepo(fx, delta)

proc checkoutAlpha(fx: Nf2Fixture; rev: string) =
  ## Put the shared `alpha` checkout at ``rev`` (detached), leaving every
  ## published revision in place.
  discard gitIn(fx, siblingDir(fx, "alpha"), "checkout -q --detach " & rev)

suite "a shared checkout at another participating repo's pin":

  test "neither of two repos pinning one checkout differently is refused":
    const caseName = "shared checkout held by another repo's pin"
    if not nf3Prerequisites(caseName):
      skip("needs `git` on PATH and a built ./build/bin/repro (printed above)")
    else:
      let fx = setupNf2Fixture("shared-checkout")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)
      publishAll(fx)

      let appPin = fx.seedSha[0]
      # alpha moves one PUBLISHED commit on; delta pins that commit.
      let deltaPin = advancePublishedSibling(fx, "alpha", 1)
      require deltaPin != appPin
      makeDeltaAnAlphaConsumer(fx, deltaPin)
      commitAndPublishDelta(fx, "consume alpha at its newer revision")
      check readFile(lockPath(fx)).contains(appPin)

      # ---- (1) checkout at delta's pin: app's push is not refused ----------
      checkoutAlpha(fx, deltaPin)
      let appGate = gatePrePush(fx)
      checkpoint("app gate (alpha at delta's pin):\n" & appGate.output)
      check not hasGateFailure(appGate.report, "flake_lock_stale")
      let appNotice = sharedCheckoutNotice(appGate.report, "delta")
      checkpoint("notices: " & $noticesOf(appGate.report))
      check appNotice.len > 0
      check appNotice.contains("pinned=" & appPin)
      check appNotice.contains("sibling=" & deltaPin)
      check appNotice.contains("repo=alpha")

      # ---- (2) checkout at app's pin: delta's push is not refused ----------
      checkoutAlpha(fx, appPin)
      let deltaGate = gatePrePushIn(fx, siblingDir(fx, "delta"))
      checkpoint("delta gate (alpha at app's pin):\n" & deltaGate.output)
      check not hasGateFailure(deltaGate.report, "flake_lock_stale")
      let deltaNotice = sharedCheckoutNotice(deltaGate.report, "app")
      checkpoint("notices: " & $noticesOf(deltaGate.report))
      check deltaNotice.len > 0
      check deltaNotice.contains("pinned=" & deltaPin)
      check deltaNotice.contains("sibling=" & appPin)

      # ---- (3) a third revision nobody pins: both are refused --------------
      checkoutAlpha(fx, deltaPin)
      # A distinct marker: `advancePublishedSibling` would rewrite the content
      # the first advance already committed, leaving nothing to commit.
      let thirdRev = moveAndPublishSibling(fx, "alpha", "third revision")
      require thirdRev != deltaPin and thirdRev != appPin
      let appThird = gatePrePush(fx)
      checkpoint("app gate (alpha at a third revision):\n" & appThird.output)
      check hasGateFailure(appThird.report, "flake_lock_stale")
      check sharedCheckoutNotice(appThird.report, "delta").len == 0
      let deltaThird = gatePrePushIn(fx, siblingDir(fx, "delta"))
      checkpoint("delta gate (alpha at a third revision):\n" &
        deltaThird.output)
      check hasGateFailure(deltaThird.report, "flake_lock_stale")
      check sharedCheckoutNotice(deltaThird.report, "app").len == 0

      # ---- (4) an uncommitted pin holds nothing ----------------------------
      writeDeltaLock(fx, thirdRev)
      let appUncommitted = gatePrePush(fx)
      checkpoint("app gate (delta's pin only in its working tree):\n" &
        appUncommitted.output)
      check hasGateFailure(appUncommitted.report, "flake_lock_stale")
      check sharedCheckoutNotice(appUncommitted.report, "delta").len == 0

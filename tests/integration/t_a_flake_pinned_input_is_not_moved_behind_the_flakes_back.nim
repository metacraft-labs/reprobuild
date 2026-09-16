## NF-2 — **an input `flake.nix` pins BY REVISION is not re-pinned by the
## refresh**, because doing so makes the flake's own pin inert.
##
## ## The failure this pins
##
## A `flake.lock` node states a revision TWICE. `locked.rev` is what the
## evaluation will build; `original.rev` mirrors the flake-ref as it is written
## in `flake.nix`, and it is only present when the author pinned that input
## explicitly (`…?rev=<sha>` / `github:o/r/<sha>`) rather than floating on a
## branch. The NF-2 refresh rewrites `locked.rev` from the observed sibling
## HEAD. Before this case it rewrote it for rev-pinned inputs too, leaving the
## two halves of the node naming DIFFERENT revisions.
##
## Nix does not reconcile them. `src/libflake/flake.cc` reuses a lock entry on
## `oldLock->originalRef.canonicalize() == input.ref->canonicalize()` alone —
## the comparison is between the lock's `original` and `flake.nix`, and
## `locked` is never checked against either. Measured on this host with nix
## 2.32.8, against two local git revisions differing in one file:
##
##   * `flake.nix` declaring `?rev=<R1>`, lock carrying `original.rev = R1` and
##     `locked.rev = R2`: `nix eval` returned **R2's** content. No warning, no
##     error, and the lock was left byte-identical. The explicit pin in
##     `flake.nix` was INERT — it reads as a pin on R1 and builds R2;
##   * rewriting `original.rev` to R2 as well — the obvious "make the node
##     agree with itself" repair — is worse: nix then finds the lock disagrees
##     with `flake.nix`, REVERTS the node to R1, and rewrites `flake.lock`. The
##     refresh is undone and the no-churn property (§13.3, and
##     `t_a_refreshed_lock_does_not_churn_under_nix`) is lost with it.
##
## So neither half of a rev-pinned node is this refresh's to move: the author's
## revision is stated in `flake.nix`, and only an edit there can move it. The
## refresh therefore DECLINES, through the same `withheld` channel as every
## other §3.2 decision — loudly, with the reason and the remedy — and the pin,
## its `narHash` and the rest of the node are left exactly as they were.
##
## This is the same defect class the refresh exists to remove. The module's own
## rationale rejects treatment (i) — move `rev`, leave `narHash` — because it
## produces "a pin that reads correct and builds something else". A moved
## `locked.rev` under a stale `original.rev` is that sentence again, one level
## up: it is `flake.nix` that reads correct and builds something else.
##
## Live instances at the time of writing, in this repo's own `flake.lock`:
## `io-mon-src` (`flake.nix` pins `ac3e5b97…`, the lock builds `3ec0223c…`) and
## `nim-stackable-hooks-src` (`41ab1b98…` vs `49006c31…`).
##
## ## What is asserted
##
##   1. a rev-pinned input whose sibling has moved is LEFT ALONE — `locked.rev`
##      still names the seed revision;
##   2. its node keeps `narHash` / `lastModified` / `revCount`. A refresh that
##      declined to move the pin but stripped its integrity fields anyway would
##      pass (1) and still have damaged the lock;
##   3. a FLOATING input in the same commit is refreshed as always. Without
##      this the fix is indistinguishable from disabling the refresh, which is
##      the mutation the whole milestone is about;
##   4. the whole-document invariant: no node states one revision in
##      `original.rev` and another in `locked.rev`. Asserted over every node,
##      and guarded against vacuity — the case fails if the lock contains no
##      `original.rev` at all, since the invariant would then hold trivially;
##   5. the decision is ANNOUNCED — the pre-commit log names the input, both
##      revisions, and `flake.nix` as the place to change it. A skip nobody can
##      see is indistinguishable from a refresh that silently did nothing.
##
## The second case pins the BOUNDARY of the rule rather than the rule: once
## `flake.nix` (and therefore `original.rev`) names the observed revision, the
## refresh completes the node instead of declining. A fix that declined
## whenever `original.rev` merely EXISTS passes every assertion of the first
## case and fails this one.
##
## ## The two cases below them: the decline has to be ACTIONABLE
##
## Declining correctly is only half of it. Measured end to end on this fixture,
## the decline left the operator in a loop: the commit succeeded printing the
## warning, the pre-push gate refused with `flake_lock_stale`, its remedy said
## to run `repro flake refresh-lock …` and commit the result, that command
## exited **0** having printed the decline twice, and the next gate refused
## identically. Two distinct defects, one case each:
##
##   * `t_a_declined_refresh_exits_non_zero` — the verb reported SUCCESS while
##     declining to do what it was asked. A human reads the printed decline; a
##     hook, a CI step or a `&&` chain reads only the status.
##   * `t_a_push_over_a_rev_pinned_input_names_the_flake_edit` — the gate named
##     a command that cannot move an author-owned pin. The remedy for one is an
##     edit to `flake.nix`, and this is also the first case in the suite to
##     drive the PUSH path for a rev-pinned input at all.
##
## `t_a_rev_pinned_sibling_that_is_behind_is_not_sent_to_the_flake` pins the
## BOUNDARY of the second, the way the second case of this file pins the
## boundary of the first: a rev-pinned input can disagree with its sibling
## because the CHECKOUT is stale, and there the author's flake is already right.
##
## Test-double policy: NO mocks, doubles or fakes. Real git repositories, a
## real `git commit`, the real installed `pre-commit` hook and the real `repro`
## binary — see the header of `nf2_flake_lock_fixture.nim` for the inventory.

import std/[json, os, strutils, unittest]

# The NF-2 fixture, plus the published workspace and `gatePrePush` that the two
# cases at the bottom of this file need. `nf3_override_state_fixture` re-exports
# `nf2_flake_lock_fixture` wholesale, so the first two cases are reading exactly
# the fixture they always were.
import nf3_override_state_fixture

proc originalRevOf(doc: JsonNode; node: string): string =
  let original = doc["nodes"][node]{"original"}
  if original == nil or original.kind != JObject: return ""
  let rev = original{"rev"}
  if rev == nil or rev.kind != JString: return ""
  rev.getStr()

proc lockedRevOf(doc: JsonNode; node: string): string =
  let locked = doc["nodes"][node]{"locked"}
  if locked == nil or locked.kind != JObject: return ""
  let rev = locked{"rev"}
  if rev == nil or rev.kind != JString: return ""
  rev.getStr()

proc incoherentNodes(doc: JsonNode): seq[string] =
  ## Every node whose two statements of "which revision" disagree.
  for name, node in doc["nodes"].pairs:
    if node.kind != JObject: continue
    let declared = originalRevOf(doc, name)
    let built = lockedRevOf(doc, name)
    if declared.len > 0 and built.len > 0 and declared != built:
      result.add(name & ": flake.nix pins " & declared & ", the lock builds " &
        built)

proc nodesStatingAnOriginalRev(doc: JsonNode): seq[string] =
  ## The vacuity guard for `incoherentNodes`: "no node disagrees" is worth
  ## nothing if no node states an `original.rev` in the first place.
  for name, node in doc["nodes"].pairs:
    if node.kind != JObject: continue
    if originalRevOf(doc, name).len > 0: result.add(name)

suite "NF-2: a rev-pinned flake input is not re-pinned behind flake.nix's back":

  test "t_a_flake_pinned_input_is_not_moved_behind_the_flakes_back":
    if not nf2Prerequisites(
        "t_a_flake_pinned_input_is_not_moved_behind_the_flakes_back"):
      skip()
    else:
      # `beta-src` is declared with an explicit `rev=`; `alpha-src` floats on
      # `ref=main`. Both are bound to workspace checkouts, so both are
      # candidates for the refresh and the only difference between them is the
      # statement `flake.nix` makes.
      let fx = setupNf2Fixture("revpin", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let seedAlpha = fx.seedSha[0]
      let seedBeta = fx.seedSha[1]
      let before = readFile(lockPath(fx))

      # ---- the arrangement is real, before anything is asserted about it. --
      # Each of these would silently hollow out a later assertion if it were
      # not true: an empty revision compares equal to another empty revision.
      check seedAlpha.len == 40
      check seedBeta.len == 40
      check seedAlpha != seedBeta
      let beforeDoc = parseJson(before)
      check lockedRevOf(beforeDoc, "beta-src") == seedBeta
      check originalRevOf(beforeDoc, "beta-src") == seedBeta
      check originalRevOf(beforeDoc, "alpha-src") == ""
      let flakeNix = readFile(fx.app / "flake.nix")
      if not flakeNix.contains("rev=" & seedBeta):
        checkpoint("flake.nix does not pin beta-src by revision:\n" & flakeNix)
      check flakeNix.contains("rev=" & seedBeta)
      check not flakeNix.contains("rev=" & seedAlpha)

      # ---- both siblings move, in the same commit. ------------------------
      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      check newAlpha.len == 40 and newAlpha != seedAlpha
      check newBeta.len == 40 and newBeta != seedBeta

      let commit = tryCommitInApp(fx, "work against both siblings")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output & "\nlog:\n" &
          preCommitLog(fx))
      check commit.code == 0

      let after = readFile(lockPath(fx))
      let doc = parseJson(after)

      # ---- (1) the rev-pinned input was LEFT ALONE. -----------------------
      if lockedRevOf(doc, "beta-src") != seedBeta:
        checkpoint("beta-src was re-pinned behind flake.nix's back.\n" &
          "flake.nix pins: " & seedBeta & "\n" &
          "lock now builds: " & lockedRevOf(doc, "beta-src") & "\n" &
          "node:\n" & nodeText(after, "beta-src") & "\nlog:\n" &
          preCommitLog(fx))
      check lockedRevOf(doc, "beta-src") == seedBeta

      # ---- (2) …untouched, not merely un-moved. ---------------------------
      # BYTE-identical: the node the refresh declined to move is the node the
      # lock already had, down to member order and indentation.
      check nodeText(after, "beta-src") == nodeText(before, "beta-src")
      let betaLocked = doc["nodes"]["beta-src"]["locked"]
      for field in ["narHash", "lastModified", "revCount"]:
        if not betaLocked.hasKey(field):
          checkpoint("beta-src lost " & field & " despite not being moved:\n" &
            nodeText(after, "beta-src"))
        check betaLocked.hasKey(field)
      # Non-empty as well as present: an integrity field that survived as `""`
      # would satisfy `hasKey` and protect nothing.
      check betaLocked{"narHash"} != nil
      if betaLocked{"narHash"} != nil:
        check betaLocked["narHash"].getStr().len > 0

      # ---- (3) the floating input in the SAME commit still refreshed. -----
      # The witness that the decline is targeted. Disabling the refresh
      # outright satisfies (1), (2) and (4); it cannot satisfy this.
      if lockedRevOf(doc, "alpha-src") != newAlpha:
        checkpoint("alpha-src was not refreshed — the decline is not " &
          "targeted, it is a disabled refresh.\nexpected: " & newAlpha &
          "\nfound: " & lockedRevOf(doc, "alpha-src") & "\nlog:\n" &
          preCommitLog(fx))
      check lockedRevOf(doc, "alpha-src") == newAlpha
      check not doc["nodes"]["alpha-src"]["locked"].hasKey("narHash")

      # ---- (4) the whole-document invariant, with its vacuity guard. ------
      let stating = nodesStatingAnOriginalRev(doc)
      if stating.len == 0:
        checkpoint("no node in the refreshed lock states an `original.rev`, " &
          "so the coherence assertion below proves nothing:\n" & after)
      check stating.len > 0
      let incoherent = incoherentNodes(doc)
      if incoherent.len > 0:
        checkpoint("nodes stating two different revisions:\n" &
          incoherent.join("\n") & "\nlock:\n" & after)
      check incoherent.len == 0

      # ---- (5) the decision is announced, with the remedy. ----------------
      let log = preCommitLog(fx)
      if not log.contains("beta-src"):
        checkpoint("the withheld pin is not named in the pre-commit log:\n" &
          log)
      check log.contains("beta-src")
      check log.contains(newBeta)
      check log.contains(seedBeta)
      check log.contains("flake.nix")

  test "t_a_flake_pin_the_author_moved_is_recorded_not_declined":
    if not nf2Prerequisites(
        "t_a_flake_pin_the_author_moved_is_recorded_not_declined"):
      skip()
    else:
      let fx = setupNf2Fixture("revpin-followed", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let seedBeta = fx.seedSha[1]
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      check newBeta.len == 40 and newBeta != seedBeta

      # The developer follows the remedy: `flake.nix` is edited to name the new
      # revision, and `original` — which is nix's mirror of that ref — follows
      # it. `locked` still names the old one, which is the state nix itself
      # leaves behind between the edit and the next evaluation.
      let flakeNixPath = fx.app / "flake.nix"
      writeFile(flakeNixPath,
        readFile(flakeNixPath).replace("rev=" & seedBeta, "rev=" & newBeta))
      let lock = readFile(lockPath(fx))
      let betaNodeBefore = nodeText(lock, "beta-src")
      check betaNodeBefore.len > 0
      # Only the `original` half is moved here; the `locked` half is what the
      # refresh is being asked to complete. The split is on `"original"` rather
      # than on indentation, so the edit cannot silently miss and leave the
      # case asserting the FIRST case's arrangement over again.
      let originalAt = betaNodeBefore.find("\"original\"")
      check originalAt > 0
      let movedOriginal = betaNodeBefore[0 ..< originalAt] &
        betaNodeBefore[originalAt .. ^1].replace(seedBeta, newBeta)
      if movedOriginal == betaNodeBefore:
        checkpoint("the fixture's beta-src node did not have the shape this " &
          "case edits:\n" & betaNodeBefore)
      check movedOriginal != betaNodeBefore
      writeFile(lockPath(fx), lock.replace(betaNodeBefore, movedOriginal))

      let staged = parseJson(readFile(lockPath(fx)))
      check originalRevOf(staged, "beta-src") == newBeta
      check lockedRevOf(staged, "beta-src") == seedBeta

      let commit = tryCommitInApp(fx, "adopt the new beta revision")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output & "\nlog:\n" &
          preCommitLog(fx))
      check commit.code == 0

      let doc = parseJson(readFile(lockPath(fx)))
      # The refresh now agrees with the flake instead of contradicting it, so
      # it records — and the node ends up coherent rather than merely unmoved.
      if lockedRevOf(doc, "beta-src") != newBeta:
        checkpoint("the refresh declined a pin flake.nix had already moved.\n" &
          "flake.nix pins: " & newBeta & "\nlock builds: " &
          lockedRevOf(doc, "beta-src") & "\nlog:\n" & preCommitLog(fx))
      check lockedRevOf(doc, "beta-src") == newBeta
      check originalRevOf(doc, "beta-src") == newBeta
      check incoherentNodes(doc).len == 0
      check nodesStatingAnOriginalRev(doc).len > 0

  test "t_a_declined_refresh_exits_non_zero":
    ## **(a)** `repro flake refresh-lock` must not report SUCCESS when it
    ## declined to do what it was asked.
    ##
    ## The verb's own contract is "exit 0 when the lock is correct afterwards".
    ## After a decline the lock is NOT correct afterwards — the substituted
    ## sibling still disagrees with its pin, and the pre-push gate refuses on
    ## exactly that — so the status has to say so. A human reads the printed
    ## decline; a hook, a CI step or a `refresh-lock && git commit && git push`
    ## chain reads only the status, and exit 0 sent every one of them onwards
    ## into a refusal.
    ##
    ## Four arms, and each exists to kill a different way of "fixing" this:
    ##
    ##   1. TOTAL decline — nothing was moved, so the status must be non-zero;
    ##   2. PARTIAL — a floating input moved in the same run and the rev-pinned
    ##      one was still declined. Also non-zero: the exit code answers "is the
    ##      lock correct afterwards", not "did any byte change". A consumer must
    ##      not have to know how many inputs were in play to read the status,
    ##      and the withheld input is still what the gate will refuse over;
    ##   3. a refresh that withholds NOTHING still exits 0. Without this arm the
    ##      whole case is satisfied by making the verb always fail, which is the
    ##      obvious mutation;
    ##   4. THE COMMIT PATH IS UNAFFECTED. A commit must not start failing
    ##      merely because a pin is author-owned: `runPreCommitLockCommand` is
    ##      documented "ALWAYS returns 0" and reaches this refresh through
    ##      `refreshFlakeLockAtCommit`, whose return tuple carries no exit code
    ##      at all. Asserted rather than assumed, because a fix that routed the
    ##      status through the hook would break every commit in a workspace with
    ##      an author-pinned input.
    if not nf2Prerequisites("t_a_declined_refresh_exits_non_zero"):
      skip()
    else:
      let fx = setupNf2Fixture("revpin-exit", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let seedAlpha = fx.seedSha[0]
      let seedBeta = fx.seedSha[1]
      check seedAlpha.len == 40 and seedBeta.len == 40
      check seedAlpha != seedBeta

      proc refreshLock(): tuple[code: int; output: string] =
        run(q(fx.repro) & " flake refresh-lock --flake=" & q(fx.app) &
          " --workspace-root=" & q(fx.ws) & " --tool-provisioning=path",
          cwd = fx.app)

      # ---- (1) every input it was asked to move was declined. -------------
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      check newBeta.len == 40 and newBeta != seedBeta
      let beforeTotal = readFile(lockPath(fx))
      let total = refreshLock()
      checkpoint("total-decline refresh -> " & $total.code & "\n" & total.output)
      # Stated as BOTH: `!= 0` is the contract a consumer relies on, and the
      # exact value is the contract this verb publishes. A fix that returned 2
      # would satisfy the first and conflate "I ran and declined" with "I could
      # not run at all", which is the distinction `refused-*` already owns.
      check total.code != 0
      check total.code == 3
      check total.output.contains("skipped-unrecordable-sibling")
      # …and it really did decline, rather than failing for some other reason:
      # the lock is byte-identical and still names the seed revision.
      check readFile(lockPath(fx)) == beforeTotal
      check beforeTotal.contains(seedBeta)

      # ---- (2) partial: one input moved, one declined. --------------------
      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
      check newAlpha.len == 40 and newAlpha != seedAlpha
      let partial = refreshLock()
      checkpoint("partial refresh -> " & $partial.code & "\n" & partial.output)
      check partial.code == 3
      let afterPartial = readFile(lockPath(fx))
      # Non-vacuous in BOTH directions: the run really moved something, and it
      # really still withheld something. Either assertion alone would pass over
      # a refresh that did nothing at all.
      check afterPartial != beforeTotal
      check lockedRevOf(parseJson(afterPartial), "alpha-src") == newAlpha
      check lockedRevOf(parseJson(afterPartial), "beta-src") == seedBeta

      # ---- (3) a refresh that withholds nothing still exits 0. ------------
      # `beta`'s checkout goes back to the revision `flake.nix` pins, which is
      # the state in which there is nothing to decline. The objects are not
      # discarded, so this is the ordinary stale-checkout shape.
      discard gitIn(fx, siblingDir(fx, "beta"), "reset --hard " & seedBeta)
      check headOf(fx, siblingDir(fx, "beta")) == seedBeta
      let laterAlpha = moveAndPublishSibling(fx, "alpha", "revision 3")
      check laterAlpha.len == 40 and laterAlpha != newAlpha
      let clean = refreshLock()
      checkpoint("clean refresh -> " & $clean.code & "\n" & clean.output)
      check clean.code == 0
      check clean.output.contains("refreshed")
      let afterClean = readFile(lockPath(fx))
      check lockedRevOf(parseJson(afterClean), "alpha-src") == laterAlpha
      check lockedRevOf(parseJson(afterClean), "beta-src") == seedBeta

      # ---- (4) the COMMIT path still succeeds over a live decline. --------
      # `beta` goes back to the published revision arm (1) declined, which puts
      # the decline back in play without needing a push: the revision is
      # already on the origin, so it stays lockable-for-other-people and the
      # only reason it is withheld is the author's pin.
      discard gitIn(fx, siblingDir(fx, "beta"), "reset --hard " & newBeta)
      let againBeta = headOf(fx, siblingDir(fx, "beta"))
      check againBeta == newBeta
      check againBeta != seedBeta
      check siblingRevIsPublished(fx, "beta", againBeta)
      let commit = tryCommitInApp(fx, "commit over an author-owned pin")
      if commit.code != 0:
        checkpoint("git commit FAILED over a declined pin — the exit status " &
          "reached the hook:\n" & commit.output & "\nlog:\n" & preCommitLog(fx))
      check commit.code == 0
      # …and the commit path still ANNOUNCED the decline. A commit that
      # succeeded because the refresh stopped running would satisfy the line
      # above and lose the whole NF-2 guarantee.
      let log = lastFlakeLogLine(fx)
      checkpoint("pre-commit log line: " & log)
      check log.contains("skipped-unrecordable-sibling")
      check log.contains("beta-src")
      check log.contains(againBeta)

  test "t_a_push_over_a_rev_pinned_input_names_the_flake_edit":
    ## **(b)** the pre-push gate's remedy for a rev-pinned input must be the
    ## FILE EDIT, not the refresh that cannot perform it.
    ##
    ## The loop this pins, measured end to end before the fix:
    ##
    ##   1. the commit succeeds, printing the decline;
    ##   2. the gate refuses — exit 2, `flake_lock_stale`;
    ##   3. its remedy says to run `repro flake refresh-lock …` "then commit the
    ##      refreshed flake.lock and re-push";
    ##   4. that command exits 0 and changes nothing — it prints the decline
    ##      twice;
    ##   5. the next gate refuses identically. The operator loops.
    ##
    ## Step (3) is the defect: for an input `flake.nix` pins by revision there
    ## is no command that moves the pin, because the revision is the author's
    ## statement and lives in `flake.nix`. The remedy is an edit there.
    ##
    ## What is asserted:
    ##
    ##   1. the gate still REFUSES (the fix is to the advice, not to the gate);
    ##   2. its remedy does NOT name `refresh-lock` for this offender — the
    ##      command that cannot work is the whole defect;
    ##   3. it names the `flake.nix` to edit, the `rev=` that is there now, and
    ##      the `rev=` to put in its place. Asserted as CONTAINS-the-revision
    ##      rather than as non-empty: a remedy that named the file and neither
    ##      revision would pass a length check and teach nothing;
    ##   4. every backticked chunk is still a single runnable command line —
    ##      the edit itself carries no backticks, because `backtickedCommands`
    ##      lifts them out and callers run what they find;
    ##   5. and THE LOOP IS BROKEN: after following the remedy the push passes
    ##      the flake stage.
    ##
    ## ### The one step of (5) that is performed rather than driven
    ##
    ## Following the remedy is two halves. The first — editing `rev=` in
    ## `flake.nix` — is done here exactly as the message says. The second is
    ## nix's: on the next evaluation it notices the lock's `original` no longer
    ## matches the flake and re-locks the node, moving `original.rev` AND
    ## `locked.rev` and recomputing `narHash`. This case performs the
    ## `original.rev` half by writing the lock, and lets the real `pre-commit`
    ## refresh complete `locked.rev` — which is the code under test and is NOT
    ## simulated. That is not a mock of anything: `original` is nix's mirror of
    ## the flake-ref, the whole fixture already writes `flake.lock` in nix's
    ## own on-disk format, and `t_a_flake_pin_the_author_moved_is_recorded_not_
    ## declined` above pins that exact hand-off. What is NOT covered here is
    ## `nix` performing the re-lock itself; that is announced rather than
    ## implied, and the nix-level half of NF-2 has its own cases.
    if not nf3Prerequisites("t_a_push_over_a_rev_pinned_input_names_the_flake_edit"):
      skip()
    else:
      let fx = setupNf2Fixture("revpin-gate", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let seedBeta = fx.seedSha[1]
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      check seedBeta.len == 40
      check newBeta.len == 40 and newBeta != seedBeta
      publishAll(fx)

      # ---- the loop's step 1: the commit succeeds, printing the decline. ---
      let commit = tryCommitInApp(fx, "work against the author-pinned beta")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output & "\nlog:\n" &
          preCommitLog(fx))
      check commit.code == 0
      check lastFlakeLogLine(fx).contains("skipped-unrecordable-sibling")
      publishRepo(fx, fx.app)

      let lockBefore = readFile(lockPath(fx))
      check lockedRevOf(parseJson(lockBefore), "beta-src") == seedBeta

      # ---- (1) the gate refuses. ------------------------------------------
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, "flake_lock_stale")
      if not hasGateFailure(gate.report, "flake_lock_stale"):
        checkpoint("report:\n" & pretty(gate.report, indent = 2))
      else:
        let failure = gateFailureOf(gate.report, "flake_lock_stale")
        let remediation = failure["remediation"].getStr()
        checkpoint("remediation: " & remediation)
        # The offender is still named — the fix changes the ADVICE, not the
        # diagnosis.
        check remediation.contains("'beta'")
        check remediation.contains("beta-src")

        # ---- (2) it does not name the command that cannot work. -----------
        if remediation.contains("refresh-lock"):
          checkpoint("the gate still tells the operator to run refresh-lock " &
            "for an input flake.nix pins BY REVISION. That command exits " &
            "non-zero and changes nothing, so this is the loop:\n" &
            remediation)
        check not remediation.contains("refresh-lock")

        # ---- (3) it names the file, the current rev and the new one. ------
        let flakeNixPath = fx.app / "flake.nix"
        check remediation.contains(flakeNixPath)
        check remediation.contains("rev=" & seedBeta)
        check remediation.contains("rev=" & newBeta)

        # ---- (4) nothing unrunnable was put in backticks. -----------------
        # The edit is prose; anything quoted has to be one command line. The
        # list is asserted NON-EMPTY first, because a `for` over an empty seq
        # proves nothing and this refusal does still owe the operator one
        # pasteable command: the re-lock that makes flake.lock follow the edit.
        let commands = backtickedCommands(remediation)
        checkpoint("backticked: " & $commands)
        check commands.len > 0
        var namesTheRelock = false
        for cmd in commands:
          check cmd.splitLines().len == 1
          check not cmd.contains("rev=")
          if cmd.startsWith("nix flake lock"):
            namesTheRelock = true
            # It has to run against THIS flake, not whichever directory the
            # operator happens to be in — the same rule the refresh command is
            # spelled with both location flags for.
            check cmd.contains(fx.app)
        check namesTheRelock

        # ---- (5) following the remedy clears the gate. --------------------
        writeFile(flakeNixPath,
          readFile(flakeNixPath).replace("rev=" & seedBeta, "rev=" & newBeta))
        check readFile(flakeNixPath).contains("rev=" & newBeta)
        # nix's half of the re-lock: `original` mirrors the flake-ref, so it
        # follows the edit. `locked` is left for the refresh to complete.
        let betaNode = nodeText(lockBefore, "beta-src")
        check betaNode.len > 0
        let originalAt = betaNode.find("\"original\"")
        check originalAt > 0
        let movedOriginal = betaNode[0 ..< originalAt] &
          betaNode[originalAt .. ^1].replace(seedBeta, newBeta)
        check movedOriginal != betaNode
        writeFile(lockPath(fx), lockBefore.replace(betaNode, movedOriginal))

        let followUp = tryCommitInApp(fx, "adopt the new beta revision")
        if followUp.code != 0:
          checkpoint("git commit failed:\n" & followUp.output & "\nlog:\n" &
            preCommitLog(fx))
        check followUp.code == 0
        let lockAfter = readFile(lockPath(fx))
        if lockedRevOf(parseJson(lockAfter), "beta-src") != newBeta:
          checkpoint("the remedy was followed and the lock still does not " &
            "name the observed revision:\n" & preCommitLog(fx))
        check lockedRevOf(parseJson(lockAfter), "beta-src") == newBeta

        publishRepo(fx, fx.app)
        let again = gatePrePush(fx)
        checkpoint("second gate output:\n" & again.output)
        if hasGateFailure(again.report, "flake_lock_stale"):
          checkpoint("the gate refuses AGAIN after its own remedy was " &
            "followed — the loop is not broken:\n" &
            gateFailureOf(again.report, "flake_lock_stale")["remediation"].getStr())
        check not hasGateFailure(again.report, "flake_lock_stale")

  test "t_a_rev_pinned_sibling_that_is_behind_is_not_sent_to_the_flake":
    ## The BOUNDARY of (b), and the reason the gate's new branch is guarded by
    ## the row's relation rather than by "`original.rev` exists".
    ##
    ## An input can be pinned BY REVISION and still disagree with its sibling
    ## for a reason that has nothing to do with the pin: the CHECKOUT is stale.
    ## There the author's `flake.nix` is already correct and the remedy is to
    ## move the checkout to it (`git merge --ff-only <pin>`) — the remedy the
    ## gate has always printed for a behind row. Telling the operator to edit
    ## `flake.nix` would send them to change a file that is right, and would
    ## record a downgrade nobody chose.
    ##
    ## A fix that emitted the edit whenever `original.rev` merely EXISTS passes
    ## every assertion of the case above and fails this one.
    if not nf3Prerequisites(
        "t_a_rev_pinned_sibling_that_is_behind_is_not_sent_to_the_flake"):
      skip()
    else:
      let fx = setupNf2Fixture("revpin-behind", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # The pin is moved FORWARD (flake.nix and both halves of the lock node),
      # then the checkout is wound back to where it started. The objects stay in
      # beta's store, which is what lets the gate state the distance.
      let seedBeta = fx.seedSha[1]
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      check newBeta.len == 40 and newBeta != seedBeta
      let flakeNixPath = fx.app / "flake.nix"
      writeFile(flakeNixPath,
        readFile(flakeNixPath).replace("rev=" & seedBeta, "rev=" & newBeta))
      let lock = readFile(lockPath(fx))
      let betaNode = nodeText(lock, "beta-src")
      check betaNode.len > 0
      writeFile(lockPath(fx),
        lock.replace(betaNode, betaNode.replace(seedBeta, newBeta)))
      check rewindSibling(fx, "beta", 1) == seedBeta

      # The arrangement really is the one this case is about, asserted before
      # anything is concluded from it: the flake pins BY REVISION, at a
      # revision the checkout is NOT at, and in the BEHIND direction.
      let staged = parseJson(readFile(lockPath(fx)))
      check originalRevOf(staged, "beta-src") == newBeta
      check lockedRevOf(staged, "beta-src") == newBeta
      check headOf(fx, siblingDir(fx, "beta")) == seedBeta
      check pinIsFetched(fx, "beta", newBeta)

      # Every repo but `beta` is published from its HEAD. `beta` is NOT, and
      # that is the arrangement rather than an omission: its checkout has been
      # wound back, so `push HEAD:main` would be a non-fast-forward and git
      # would refuse it. Its origin already carries `newBeta` (the publishing
      # push that `moveAndPublishSibling` made), so `seedBeta` is an ancestor of
      # a remote-tracking ref and the gate's publication stage is satisfied —
      # asserted below rather than assumed, because an unpublished sibling would
      # change which offender the gate reports and make this case about
      # something else.
      for name in Nf2Repos:
        if name != "beta": publishRepo(fx, fx.ws / name)
      check siblingRevIsPublished(fx, "beta", seedBeta)
      commitLockAndPublish(fx, "pin beta at the newer revision")

      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, "flake_lock_stale")
      if hasGateFailure(gate.report, "flake_lock_stale"):
        let failure = gateFailureOf(gate.report, "flake_lock_stale")
        let evidence = failure["evidence"].getStr()
        let remediation = failure["remediation"].getStr()
        checkpoint("evidence: " & evidence)
        checkpoint("remediation: " & remediation)
        # The vacuity guard for everything below: the offender really is the
        # rev-pinned input, really is BEHIND, and really is the row the naive
        # guard would have sent to flake.nix.
        check evidence.contains("input=beta-src")
        check evidence.contains("relation=behind")

        # The remedy moves the CHECKOUT, and says nothing about editing the
        # flake.
        check remediation.contains("merge --ff-only")
        check remediation.contains(newBeta)
        check not remediation.contains("change rev=")
        check not remediation.contains("pinned BY REVISION")

        # …and it is still a command that RUNS where the message says, which is
        # the property the whole remedy contract rests on.
        let namedDir = directoryNamedForRunning(remediation)
        check namedDir.len > 0
        check dirExists(namedDir)
        let commands = backtickedCommands(remediation)
        check commands.len > 0
        let res = runNamedCommand(fx, commands[0], namedDir)
        checkpoint("ran `" & commands[0] & "` in " & namedDir & " -> " &
          $res.code & "\n" & res.output)
        check res.code == 0
        check headOf(fx, siblingDir(fx, "beta")) == newBeta
        let cleared = gatePrePush(fx)
        checkpoint("second gate output:\n" & cleared.output)
        check not hasGateFailure(cleared.report, "flake_lock_stale")

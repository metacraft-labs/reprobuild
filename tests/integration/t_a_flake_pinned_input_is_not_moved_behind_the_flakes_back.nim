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
## Test-double policy: NO mocks, doubles or fakes. Real git repositories, a
## real `git commit`, the real installed `pre-commit` hook and the real `repro`
## binary — see the header of `nf2_flake_lock_fixture.nim` for the inventory.

import std/[json, os, strutils, unittest]

import nf2_flake_lock_fixture

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

## NF-2 — **a workspace membership the commit hook cannot resolve must not be
## read as "no sibling moved"**.
##
## Nix-Flake-Coexistence.md §5 names the defect this whole campaign exists to
## remove: a mechanism that "looked like it was working while doing nothing".
## NF-1 drew the rule from it — *an empty result and a failure must not look
## alike* — and refuses rather than reporting an empty override set.
##
## The commit-path pre-filter had the same hole, one layer down, and it is the
## subject of this case.
##
## ## The hole, precisely
##
## `refreshFlakeLockAtCommit` asks a cheap question before it resolves the
## develop set: does any flake input's sibling directory hold a `HEAD` that
## differs from the pin `flake.lock` already carries? To ask it, it needs to
## know WHERE each sibling is checked out, and a repo's path is not always its
## name — `reprobuild/references/nix` is one repo of this very workspace. So it
## consults the membership manifest.
##
## When that consultation FAILED, the failure was discarded (`except
## CatchableError: discard`) and the scan continued with an empty path table.
## Every repo then fell back to `<workspaceRoot>/<name>`, a directory that does
## not exist for any repo whose path differs from its name, so every such input
## was silently skipped — and with nothing left to look at, the pre-filter
## concluded "nothing can have moved" and reported `up-to-date`. A refresh that
## never happened, reported as a refresh that was not needed. Exactly §5's
## shape, in the one place a whole milestone's correctness passes through.
##
## ## …and the second half, which writing this case turned up
##
## Removing the `discard` was not enough, because **a raise is not the only way
## the lookup fails to answer**. The shared resolution ladder is deliberately
## forgiving: `committedLockDerivedProject` documents that an unparseable
## committed lock falls back to deriving the set from HEAD plus nested-dep
## discovery. So a broken membership comes back as a SMALL SET rather than as
## an error, and the pre-filter — now catching raises faithfully — still
## reported `up-to-date` about a sibling that had moved. Measured on this
## fixture: `repro workspace list` refused outright ("no project or variant
## named 'nf2' found") while the flake path was handed a set it accepted.
##
## There is no way to ask "is this set complete?". There is a cheap NECESSARY
## condition that a degraded set fails and a healthy one cannot: the commit is
## being made in a repo of this workspace, so a membership that does not name
## that repo is not describing this workspace. That is the guard this case
## pins, and it costs one comparison per repo on a healthy commit.
##
## ## What is asserted
##
##   1. **path ≠ name is followed.** With the membership resolvable, a sibling
##      checked out at `refs/gamma` rather than `gamma` has its pin recorded.
##      This is the capability the manifest lookup exists to provide, and
##      asserting it first means assertion (2) is about the FAILURE rather than
##      about the lookup never having worked;
##   2. **a membership that cannot be resolved is loud, and never
##      `up-to-date`.** With the committed lock made unparseable and a sibling
##      genuinely moved, the commit still succeeds (a pre-commit hook must not
##      reject work over a tooling fault), the log names the membership failure,
##      and the outcome is a refusal — not a report that the lock is already
##      correct. Note this is the DEGRADED-set shape rather than the raising
##      one, because it is the shape this workspace's resolution ladder
##      actually produces;
##   3. **it never degrades into "no overrides".** The lock is not rewritten
##      with a partial answer either: a pre-filter that cannot locate the
##      siblings hands over to the authoritative path, which refuses for the
##      same reason rather than filing a guess;
##   4. **a refusal SAYS WHY.** The other shape — the ladder RAISING rather
##      than degrading — is reached by a workspace whose `.repro/workspace.toml`
##      names a project no manifest layer on disk defines (`repro sync` never
##      run, or the project renamed out from under the checkout). The guard in
##      (2) fires on that too, so a refusal happens either way; what must not be
##      lost is WHICH of the two happened. The raised message names the project
##      and where the ladder looked — the operator's entire remedy — so the
##      diagnostic is asserted to carry THAT text rather than the generic
##      "it resolved to an EMPTY repo set" the second guard synthesises. A
##      refusal that cannot say why is the same defect one level up: it looks
##      like a mechanism that is working, and tells nobody what to fix.
##
## ## Mutations: either half of the guard removed ⇒ RED
##
##   * restoring `except CatchableError: discard` around the membership lookup
##     (`membershipFailure = err.msg` → `discard err.msg`) ⇒ assertion (4) RED:
##     the second guard still refuses, but the refusal now reports an empty
##     repo set instead of the project the ladder could not find;
##   * dropping the "the membership must name the repo this commit is in"
##     check ⇒ assertion (2) RED: the degraded set reads `up-to-date`, the
##     silent skip that motivated this case.
##
## Test-double policy: NO mocks, doubles or fakes. A real workspace, a real
## relocated checkout, a real `repro.lock` made unparseable on disk, and real
## `git commit`s. See the header of `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import nf2_flake_lock_fixture

proc relocateGamma(fx: Nf2Fixture) =
  ## Move `gamma`'s checkout to `refs/gamma` and say so in the committed lock,
  ## so its manifest PATH no longer equals its NAME. This is the shape
  ## `reprobuild/references/nix` has in the real workspace.
  createDir(fx.ws / "refs")
  moveDir(fx.ws / "gamma", fx.ws / "refs" / "gamma")
  let lock = fx.ws / "repro.lock"
  let text = readFile(lock)
  let old = "{ name = \"gamma\", path = \"gamma\","
  let replacement = "{ name = \"gamma\", path = \"refs/gamma\","
  if old notin text:
    checkpoint("the fixture's repro.lock no longer carries the `gamma` entry " &
      "this relocation rewrites; the shape it depends on has changed:\n" & text)
    quit 1
  writeFile(lock, text.replace(old, replacement))

proc membershipClause(line: string): string =
  ## The part of a `flake-lock` log line that carries the REASON the membership
  ## could not be resolved — the text between `could not be resolved — ` and
  ## ` — so the fast pre-filter`.
  ##
  ## Scoped rather than a bare `contains` over the whole line, and that is the
  ## point of the assertion it serves: the authoritative path that the refusal
  ## hands over to resolves the same membership and appends its own diagnostic
  ## to the SAME line, so a whole-line match could be satisfied by that second,
  ## independent report while the clause under test said nothing. Only this
  ## substring is the value `membershipFailure` carried.
  const
    opener = " could not be resolved — "
    closer = " — so the fast pre-filter"
  let at = line.find(opener)
  if at < 0: return ""
  let rest = line[at + opener.len .. ^1]
  let stop = rest.find(closer)
  if stop < 0: return rest
  rest[0 ..< stop]

suite "NF-2: an unresolvable membership is not read as no overrides":

  test "t_an_unresolvable_membership_is_not_read_as_no_overrides":
    if not nf2Prerequisites(
        "t_an_unresolvable_membership_is_not_read_as_no_overrides"):
      skip()
    else:
      let fx = setupNf2Fixture("membership")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      relocateGamma(fx)
      check dirExists(fx.ws / "refs" / "gamma")
      check not dirExists(fx.ws / "gamma")

      # ---- (1) path ≠ name is followed while the membership resolves. -----
      let gammaDir = fx.ws / "refs" / "gamma"
      writeFile(gammaDir / "marker.txt", "gamma revision 2\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(gammaDir) &
        " commit -q -a -m " & q("gamma revision 2"))
      let newGamma = gitIn(fx, gammaDir, "rev-parse HEAD").strip()
      check newGamma != fx.seedSha[2]

      let first = tryCommitInApp(fx, "build against the relocated gamma")
      if first.code != 0:
        checkpoint("git commit failed:\n" & first.output)
      check first.code == 0
      let afterFirst = readFile(lockPath(fx))
      if not afterFirst.contains(newGamma):
        checkpoint("a sibling whose manifest path differs from its name was " &
          "INVISIBLE to the refresh. log:\n" & preCommitLog(fx) &
          "\nlock:\n" & afterFirst)
      check afterFirst.contains(newGamma)
      check fx.seedSha[2] notin nodeText(afterFirst, "gamma-src")
      check lockInCommit(fx) == afterFirst
      check lastFlakeLogLine(fx).contains("flake-lock refreshed")

      # ---- (2) an unresolvable membership is loud. ------------------------
      # The committed lock is the workspace's membership here, so making it
      # unparseable is exactly "the membership cannot be resolved". Truncated
      # rather than deleted: a missing file is a different question (there is
      # no workspace), and this case is about a workspace whose membership
      # cannot be READ.
      writeFile(fx.ws / "repro.lock",
        "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock\n" &
        "this file is not parseable TOML\n")

      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      let lockBefore = readFile(lockPath(fx))
      let second = tryCommitInApp(fx, "commit with an unreadable membership")
      # A tooling fault is not a reason to reject a developer's commit.
      if second.code != 0:
        checkpoint("the commit was REJECTED over an unresolvable " &
          "membership:\n" & second.output)
      check second.code == 0

      let line = lastFlakeLogLine(fx)
      if line.len == 0:
        checkpoint("nothing was recorded at all for a commit whose " &
          "membership could not be resolved. Silence here is the defect: " &
          "log:\n" & preCommitLog(fx))
      check line.len > 0
      # THE assertion. `up-to-date` is the answer the swallowed failure gave,
      # and it is a claim about the lock being correct that nothing checked.
      if line.contains("up-to-date"):
        checkpoint("an unresolvable membership was reported as 'up-to-date' " &
          "— the mechanism looked like it was working while doing nothing. " &
          "line: " & line)
      check not line.contains("up-to-date")
      check line.contains("could not be resolved")
      # It names a refusal, so an operator reading the log learns that the
      # refresh did not happen rather than that it was not needed.
      check line.contains("refused-unresolvable-workspace")

      # ---- (3) and it filed no guess. -------------------------------------
      check readFile(lockPath(fx)) == lockBefore
      check newAlpha notin readFile(lockPath(fx))
      check lockInCommit(fx) == lockBefore

      # ---- (4) the OTHER shape — the ladder raises — and the refusal SAYS
      #          WHY. ------------------------------------------------------
      # Arm (2) is the degraded-set shape, and the "membership must name this
      # repo" guard is what catches it. This arm is the shape that actually
      # RAISES: with no committed lock at the workspace root, the ladder falls
      # through to the named-project rung, and `.repro/workspace.toml` names a
      # project (`nf2`) that no manifest layer on disk defines. That is a
      # workspace whose `repro sync` has not run — an everyday state, not a
      # contrived one.
      #
      # Both shapes refuse, so "a refusal happened" cannot tell them apart.
      # The raised message can: it names the project and every path the ladder
      # looked in, which IS the operator's remedy. Discarding it leaves the
      # second guard to synthesise "it resolved to an EMPTY repo set, which no
      # workspace has" — true, unhelpful, and indistinguishable from a
      # workspace that has no repos.
      removeFile(fx.ws / "repro.lock")
      check not fileExists(fx.ws / "repro.lock")

      let newBeta = moveSibling(fx, "beta", "revision 2")
      let lockBeforeRaise = readFile(lockPath(fx))
      let third = tryCommitInApp(fx, "commit with an unresolvable project")
      if third.code != 0:
        checkpoint("the commit was REJECTED over a membership the ladder " &
          "could not resolve:\n" & third.output)
      check third.code == 0

      let raiseLine = lastFlakeLogLine(fx)
      if raiseLine.contains("up-to-date"):
        checkpoint("a membership the ladder REFUSED to resolve was reported " &
          "as 'up-to-date'. line: " & raiseLine)
      check not raiseLine.contains("up-to-date")
      check raiseLine.contains("refused-unresolvable-workspace")

      let clause = membershipClause(raiseLine)
      if clause.len == 0:
        checkpoint("the refusal named no membership failure at all:\n" &
          raiseLine)
      check clause.len > 0
      # THE assertion of this arm. The ladder's own words, not a substitute
      # invented after they were dropped.
      if not clause.contains("named 'nf2'"):
        checkpoint("the refusal does not name WHY the membership could not " &
          "be resolved — the ladder's message (which names the project and " &
          "where it looked, the operator's whole remedy) was replaced by a " &
          "generic one. clause: " & clause & "\nfull line: " & raiseLine)
      check clause.contains("named 'nf2'")
      # And specifically NOT the text the second guard synthesises when the
      # raise was swallowed and it had to invent a reason from an empty table.
      check "resolved to an EMPTY repo set" notin clause

      # Still no guess filed.
      check readFile(lockPath(fx)) == lockBeforeRaise
      check newBeta notin readFile(lockPath(fx))
      check lockInCommit(fx) == lockBeforeRaise

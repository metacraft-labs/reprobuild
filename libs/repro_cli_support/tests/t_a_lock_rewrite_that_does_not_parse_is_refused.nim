## A partial rewrite of `repro.lock` is checked before it is written, and one
## that does not parse, or does not read back to the pins it was meant to
## record, is REFUSED (Unified-Locking-And-Hooks.md §13.3, "A refresh never
## writes a document that does not parse").
##
## THE DEFECT THIS GUARDS AGAINST (reprobuild-pm issue
## 2026-11-12-the-pre-commit-lock-rewrite-misreads-a-multi-line-deps-entry-
## and-writes-invalid-toml). The commit-time re-pin spliced its one-line
## `deps` over the FIRST physical line of a `deps` array laid out as TOML
## continuation lines and left the rest behind, writing a lock that no longer
## parsed. The reader fix makes the splice cover the whole statement, so in a
## working build no writer produces such a document; this guard is the
## second line, and this file is the test that it holds when a splice is
## wrong. It drives the guard with exactly the document the defect wrote.
##
## Cases:
##   1. ``splicedCommittedLockDeps`` given the WHOLE statement
##      (``lockStatementSource``) yields the canonical one-line document, and
##      ``committedLockRewriteProblem`` passes it;
##   2. the defect's splice (first physical line only) is refused as "does
##      not parse as TOML";
##   3. a rewrite that parses but records other pins than planned is refused
##      as "does not read back to the dependencies";
##   4. a rewrite that is valid TOML but not a lock the reader accepts is
##      refused as "does not read back";
##   5. wired into the plan: ``summarizeCommittedLockRepin`` over a plan
##      whose ``originalDeps`` is the first physical line alone reports
##      `repro-lock refused-invalid-rewrite`, marks nothing changed, and
##      ``committedLockRepinFailure`` turns it into a refused commit;
##   6. the CONTROL: the same plan over the whole statement re-pins.
##
## Falsifiability: before the guard (reprobuild `3a64ddc14`) none of
## ``committedLockRewriteProblem``, ``lockStatementSource`` or
## ``CommittedLockRepinPlan.originalDeps`` exists, so this does not compile;
## and with the guard's body replaced by `""`, cases 2-5 fail (case 5's plan
## then reports `repro-lock re-pinned lib-b …` and would write the defect's
## document).
##
## Test-double policy: NO mocks. Every document is the real lock writer's
## output (``serializeLockedDependencies``), re-laid-out by text edits as a
## hand edit laid out codetracer `a0efd6494`'s lock, and every check is the
## production proc, reached through ``{.all.}`` because it is module-private.

import std/[importutils, strutils, unittest]

import repro_lock
import repro_cli_support {.all.}

import ../../repro_lock/tests/nlf_lock_fixtures

const Platform = "amd64-linux"

proc vcsDep(name, rev: string; self = false): LockedDep =
  LockedDep(name: name,
    path: (if self: SelfLockedDepPath else: defaultLockedDepCheckoutPath(name)),
    coordinates: Coordinates(kind: ckVcs,
      url: "https://example.invalid/" & name & ".git", revision: rev),
    integrity: "git-sha1:" & rev)

proc threeDepLock(libB = repeat('2', 40)): LockedDependencies =
  result = lockedDepsFromSolved(solutionToLock(
    solutionOf(@[("libfoo", "1.4.2"), ("nim", "2.2.0")], []), Platform,
    "packages: demo"))
  result.deps = @[
    vcsDep("app", repeat('1', 40), self = true),
    vcsDep("lib-b", libB),
    vcsDep("lib-c", repeat('3', 40))]
  result.deps[0].depends = @["lib-b", "lib-c"]

proc spreadLayout(doc: string): string =
  ## codetracer `a0efd6494`'s layout: each record after the first on its own
  ## line, opened by the separating comma.
  let line = committedLockDepsLine(parseLockedDependencies(doc))
  doc.replace(line, line.replace("}, { name", "}\n, { name"))

proc firstPhysicalLine(statement: string): string =
  statement.splitLines()[0]

let moved = repeat('4', 40)

suite "a lock rewrite that does not parse is refused":

  test "the whole-statement splice is the canonical document, and passes":
    let canonicalMoved = serializeLockedDependencies(threeDepLock(moved))
    let spread = spreadLayout(serializeLockedDependencies(threeDepLock()))
    let statement = lockStatementSource(spread, "deps")
    check statement.count('\n') == 2
    let depsLine = committedLockDepsLine(threeDepLock(moved))
    let rewritten = splicedCommittedLockDeps(spread, statement, depsLine)
    check rewritten == canonicalMoved
    check committedLockRewriteProblem(spread, rewritten, depsLine) == ""

  test "the defect's splice, over the first physical line, is refused":
    let spread = spreadLayout(serializeLockedDependencies(threeDepLock()))
    let depsLine = committedLockDepsLine(threeDepLock(moved))
    let broken = splicedCommittedLockDeps(spread,
      firstPhysicalLine(lockStatementSource(spread, "deps")), depsLine)
    # It really is what the defect wrote: the new line, then the old
    # continuation lines.
    check broken.count("\n, { name = ") == 2
    let problem = committedLockRewriteProblem(spread, broken, depsLine)
    checkpoint(problem)
    check problem.startsWith("the rewritten lock does not parse as TOML")

  test "a rewrite recording other pins than planned is refused":
    let doc = serializeLockedDependencies(threeDepLock())
    let planned = committedLockDepsLine(threeDepLock(moved))
    # A well-formed lock, but not the one planned: lib-b keeps its old pin.
    let problem = committedLockRewriteProblem(doc, doc, planned)
    checkpoint(problem)
    check problem.startsWith(
      "the rewritten lock does not read back to the dependencies")

  test "a rewrite that is TOML but not a readable lock is refused":
    let doc = serializeLockedDependencies(threeDepLock())
    let line = committedLockDepsLine(threeDepLock())
    # Valid TOML, but a schema the lock reader does not know, so only the
    # read-back can refuse it.
    check SolvedGraphLockSchemaV3 in doc
    let rewritten = doc.replace(SolvedGraphLockSchemaV3,
      "reprobuild.solved-graph-lock.v99")
    let problem = committedLockRewriteProblem(doc, rewritten, line)
    checkpoint(problem)
    check problem.startsWith("the rewritten lock does not read back (")

  proc planOver(spread, originalDeps: string): CommittedLockRepinPlan =
    # The plan's fields are module-private; ``privateAccess`` is the
    # standard way for a test to build one (std/importutils).
    privateAccess(CommittedLockRepinPlan)
    privateAccess(ReproLockMove)
    result.lockPath = "app/repro.lock"
    result.text = spread
    result.originalDeps = originalDeps
    result.originalLd = parseLockedDependencies(spread)
    result.plannedLd = threeDepLock(moved)
    result.depsLine = committedLockDepsLine(result.plannedLd)
    result.moves = @[ReproLockMove(name: "lib-b", oldRev: repeat('2', 40),
      newRev: moved)]
    summarizeCommittedLockRepin(result)

  test "the plan refuses the defect's splice as a failed commit":
    privateAccess(CommittedLockRepinPlan)
    let spread = spreadLayout(serializeLockedDependencies(threeDepLock()))
    let plan = planOver(spread,
      firstPhysicalLine(lockStatementSource(spread, "deps")))
    checkpoint(plan.line)
    check plan.line.startsWith(
      "repro-lock refused-invalid-rewrite: app/repro.lock: " &
      "the rewritten lock does not parse as TOML")
    check plan.line.endsWith("; nothing was written")
    check not plan.changed
    check committedLockRepinFailure(plan) == plan.line

  test "the CONTROL: the same plan over the whole statement re-pins":
    privateAccess(CommittedLockRepinPlan)
    let spread = spreadLayout(serializeLockedDependencies(threeDepLock()))
    let plan = planOver(spread, lockStatementSource(spread, "deps"))
    checkpoint(plan.line)
    check plan.changed
    check plan.line.startsWith("repro-lock re-pinned lib-b ")
    check committedLockRepinFailure(plan) == ""

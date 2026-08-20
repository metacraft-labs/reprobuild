## NLF-ID-7 — two solver runs, same constraints, different answers, no collision.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-ID-7**
## (`Named-Lock-Files-Test-Corpus.md` §3), verifying design §6.2 and Q-6.
##
## - **Input.** One constraint set; two solved graphs differing only in a
##   choice among tied optima (simulate by forcing a different model
##   selection).
## - **Expect.** **Distinct lock identities**, distinct action fingerprints,
##   no artifact served across them.
## - **Catches.** "Identity keyed on the **constraint set** rather than the
##   solved graph — the defect found in review and corrected in §6.2. Under
##   it, the two graphs collide on one key."
##
## ## Why this case exists, and what it is really guarding
##
## §6.2 originally hashed "the canonical constraint set, canonical
## feature/variant selections" — the QUESTION. The owner corrected it to the
## solved graph — the ANSWER — on 2026-08-18, and the reason is a
## cache-poisoning argument rather than an aesthetic one:
##
## > **Constraint-set keying is unsound.** Two solver versions, or one solver
## > under a different configuration, can produce **different solved graphs
## > from identical constraints** — the Q-6 evidence in §15: clingo is
## > constructed with no arguments (`solver_api.nim:447`), no `--seed`, no
## > `--opt-strategy`, and the driver enumerates to exhaustion keeping the
## > *last* model, so determinism among tied optima rests on defaults. Under
## > constraint-set keying those two graphs **collide on one key** and serve
## > each other's artifacts.
##
## So this is not a hypothetical. The repository already HAS a constraint-set
## digest — `inputs_digest`, computed by `inputsDigestOf` over the rendered
## solver-inputs text and recorded in every committed lock — and it is the
## obvious thing to reach for when implementing "hash the lock". An
## implementation that did so would pass NLF-ID-1, NLF-ID-2 and NLF-ID-3, and
## would poison the cache here.
##
## ## Making it genuinely discriminating
##
## Three properties, and all three are asserted rather than assumed:
##
##  1. **The tie is real.** Both candidate versions genuinely satisfy the
##     constraint set — established by solving for each in turn with the REAL
##     clingo driver and checking both solves succeed. A "tie" one of whose
##     arms is infeasible is not a tie.
##  2. **The constraint set is genuinely identical.** Both locks carry the
##     same `inputs_digest`, because `inputs_digest` is a function of the
##     solver-inputs text and both runs saw the same text. This is the
##     premise the whole case rests on, so it is checked and not narrated.
##  3. **The rejected formula really would collide.** The case computes what
##     constraint-set keying would have produced for both graphs and asserts
##     it is the SAME value — then asserts the implemented formula differs.
##     Without (3) a reader has to take on faith that the case can fail;
##     with it, the defect is exhibited next to its absence.
##
## The "forcing a different model selection" the corpus sanctions is done
## with the product's own `newPinnedPackage`, the pinning primitive NLF-M2
## added — not by hand-editing a solution object. The answer that comes back
## is a real clingo answer to a real program.
##
## Test-double policy: NO mocks, doubles, or fakes. Real clingo solves via
## `repro_solver.solve`, real committed `…lock.v2` files, the product's own
## reader and key function, and the engine's real action constructors.
##
## Requires `libclingo` on the loader path.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_lock
import repro_solver

import ./nlf_lock_fixtures

const
  LibFoo = "libfoo"
  TiedLow = "1.0.0"
  TiedHigh = "1.0.1"
  # ONE constraint set, rendered once. Both solver runs below see exactly
  # this, so both locks record the same `inputs_digest` — which is what makes
  # the constraint-set formula collide and the solved-graph formula not.
  SharedConstraintSetText =
    "package libfoo versions 1.0.0 1.0.1\n" &
    "package app versions 0.9.0\n" &
    "package nim versions 2.2.0\n"

proc constraintSetPackages(): seq[PackageDecl] =
  ## The tied constraint set: `libfoo` has two candidate versions and nothing
  ## in the program distinguishes them. `app` and `nim` are single-candidate
  ## so the only degree of freedom is the tie.
  @[
    newPackage(LibFoo, [TiedLow, TiedHigh]),
    newPackage("app", ["0.9.0"]),
    newPackage("nim", ["2.2.0"])
  ]

proc solveForcing(chosen: string): UnifiedSolution =
  ## Solve the SAME constraint set with the tie resolved to `chosen`.
  ##
  ## This is the corpus's "simulate by forcing a different model selection".
  ## `newPinnedPackage` is the product's own pinning primitive (NLF-M2): it
  ## asserts `package_chosen` as a FACT, so clingo returns the model in which
  ## the tie went that way. Every other package is declared exactly as in
  ## `constraintSetPackages`, so the two runs differ only in which arm of the
  ## tie the search landed on — which is precisely "two solved graphs
  ## differing only in a choice among tied optima".
  var packages: seq[PackageDecl] = @[]
  for p in constraintSetPackages():
    if p.name == LibFoo:
      packages.add(newPinnedPackage(LibFoo, chosen))
    else:
      packages.add(p)
  solve([], packages)

proc constraintSetKeyOf(lock: SolvedGraphLock): string =
  ## What the REJECTED formula — identity over the constraint set — would
  ## have produced. The repository's constraint-set digest is the lock's own
  ## `inputs_digest`, so this is not a straw man: it is the value an
  ## implementer reaching for "hash the lock's provenance" would have used.
  lock.inputsDigest

suite "NLF-ID-7 tied optima do not collide":

  test "the tie is real: both arms are feasible answers to one constraint set":
    let low = solveForcing(TiedLow)
    let high = solveForcing(TiedHigh)

    # Both solves produced an answer, and each produced the arm it was
    # forced to. An arm that came back with the other version — or with
    # nothing — would mean the "tie" was not one.
    check low.packages.getOrDefault(LibFoo, "") == TiedLow
    check high.packages.getOrDefault(LibFoo, "") == TiedHigh

    # And they agree on everything else, so the two graphs differ ONLY in the
    # tie-break. A difference elsewhere would make the case pass for the
    # wrong reason.
    check low.packages.len == high.packages.len
    for name, version in low.packages:
      if name != LibFoo:
        check high.packages.getOrDefault(name, "") == version
    check low.variants == high.variants

  test "two tied answers get DISTINCT lock identities":
    let tempRoot = createTempDir("repro-nlf-id7-identity", "")
    defer: removeDir(tempRoot)

    let lowPath = tempRoot / "run-a.lock"
    let highPath = tempRoot / "run-b.lock"
    writeCommittedLock(lowPath, solveForcing(TiedLow),
      inputsText = SharedConstraintSetText)
    writeCommittedLock(highPath, solveForcing(TiedHigh),
      inputsText = SharedConstraintSetText)

    let lowLock = readCommittedLock(lowPath)
    let highLock = readCommittedLock(highPath)

    # PREMISE: the constraint set really is identical across the two runs.
    check lowLock.inputsDigest == highLock.inputsDigest
    check lowLock.inputsDigest.len > 0
    check lowLock.platform == highLock.platform

    # THE DEFECT, exhibited: constraint-set keying gives ONE key for two
    # different solved graphs. This check is expected to be EQUAL — it is
    # the collision, shown so the next assertion has something to be
    # contrasted with.
    check constraintSetKeyOf(lowLock) == constraintSetKeyOf(highLock)

    # THE REQUIREMENT: solved-graph keying gives two.
    let lowIdentity = lockIdentityOf(lowLock)
    let highIdentity = lockIdentityOf(highLock)
    check lowIdentity.isValid()
    check highIdentity.isValid()
    check lowIdentity != highIdentity

    # And the identity does not merely echo the constraint-set digest under
    # another name — an implementation that mixed `inputs_digest` IN would
    # still be keying partly on the question.
    check not ($lowIdentity).contains(lowLock.inputsDigest)

  test "an identical re-solve does NOT invalidate":
    # The other side of the same property, and the reason the case cannot be
    # satisfied by making every solve produce a fresh identity. §6.2:
    # "Re-solving to the same answer does not invalidate. Identical content
    # yields an identical key."
    let tempRoot = createTempDir("repro-nlf-id7-resolve", "")
    defer: removeDir(tempRoot)

    let firstPath = tempRoot / "first.lock"
    let secondPath = tempRoot / "second.lock"
    writeCommittedLock(firstPath, solveForcing(TiedLow),
      inputsText = SharedConstraintSetText)
    writeCommittedLock(secondPath, solveForcing(TiedLow),
      inputsText = SharedConstraintSetText)

    check lockIdentityOf(readCommittedLock(firstPath)) ==
      lockIdentityOf(readCommittedLock(secondPath))

  test "no artifact is served across the two answers":
    let tempRoot = createTempDir("repro-nlf-id7-artifacts", "")
    defer: removeDir(tempRoot)
    let cacheRoot = tempRoot / "cache"
    createDir(cacheRoot)

    let lowPath = tempRoot / "run-a.lock"
    let highPath = tempRoot / "run-b.lock"
    writeCommittedLock(lowPath, solveForcing(TiedLow),
      inputsText = SharedConstraintSetText)
    writeCommittedLock(highPath, solveForcing(TiedHigh),
      inputsText = SharedConstraintSetText)

    proc buildUnder(lockPath, outDir, payload: string):
        tuple[fingerprint, artifact: string] =
      createDir(outDir)
      let identity = lockIdentityOf(readCommittedLock(lockPath))
      let outPath = absolutePath(outDir / "libfoo.a")
      let edge = builtinAction(bakWriteText, "build/libfoo@" & $identity,
        outputs = [outPath], text = payload,
        governingLockIdentity = identity)
      var cfg = defaultBuildEngineConfig(cacheRoot)
      cfg.maxParallelism = 1
      cfg.bypassRunQuota = true
      cfg.deferLocalOutputBlobs = false
      discard runBuild(graph(@[edge]), cfg)
      (fingerprint: toHex(edge.weakFingerprint.bytes.toOpenArray(
         0, edge.weakFingerprint.bytes.high)),
       artifact: readFile(outPath))

    let a = buildUnder(lowPath, tempRoot / "a", "libfoo-1.0.0\n")
    let b = buildUnder(highPath, tempRoot / "b", "libfoo-1.0.1\n")

    check a.fingerprint != b.fingerprint
    check a.artifact == "libfoo-1.0.0\n"
    check b.artifact == "libfoo-1.0.1\n"

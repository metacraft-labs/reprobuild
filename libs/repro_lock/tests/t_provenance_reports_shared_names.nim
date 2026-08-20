## NLF-ID-5 — provenance is reported without entering the key.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-ID-5**
## (`Named-Lock-Files-Test-Corpus.md` §3), verifying design §6.3.
##
## - **Input.** Two names bound to identical content (as NLF-ID-1). Query
##   `repro why` for the shared artifact.
## - **Expect.** Both names reported — "`hostTools` and `targetRuntime`
##   resolved identically; artifacts shared" — presented as sharing, not as a
##   warning or a conflict.
## - **Catches.** "Two distinct defects: (a) a provenance side table that is
##   lossy, BuildXL-style `TryAdd` dropping the second name (§6.3 explicitly
##   improves on the precedent here); (b) an implementation that reports the
##   collapse as a problem, which would train users to avoid a correct and
##   desirable outcome."
##
## ## What is under test
##
## `lockProvenanceReportLines` is the renderer `repro why` prints from. The
## CLI's text path (`renderWhyActionText` in
## `libs/repro_cli_support/src/repro_cli_support.nim`) calls exactly this
## proc for exactly this action field, and its JSON path emits the same names
## as an array from the same `namesFor`. Testing it here rather than through
## the CLI keeps the case fast and dependency-light; the labels it asserts on
## (`LockFileIdentityLabel`, `LockFileNamesLabel`) are the constants the CLI
## interpolates, so a change to the printed wording moves this test.
##
## Defect (b) — reporting sharing as a problem — needs an assertion with
## teeth, because the natural reading of "two things mapped to one" is that
## something went wrong. §6.3 is explicit that it did not: "Two lock files
## mapping to one identity is the system reporting that those lock files
## resolved to the same lock file and their work was correctly done once. It
## is a success condition. … and never as a warning." So the case asserts on
## the ABSENCE of alarm vocabulary as well as on the presence of both names.
##
## Test-double policy: NO mocks, doubles, or fakes. Real committed
## `…lock.v2` files, the product's `parseSolvedGraphLock` / `lockIdentityOf`,
## and the product's own `LockProvenance` and renderer.

import std/[os, strutils, tempfiles, unittest]

import repro_lock

import ./nlf_lock_fixtures

const
  HostTools = "hostTools"
  TargetRuntime = "targetRuntime"
  ThirdName = "ciMinimal"

  AlarmVocabulary = [
    "warning", "Warning", "WARNING",
    "conflict", "Conflict",
    "collision", "Collision",
    "error", "Error",
    "duplicate", "Duplicate",
    "ambiguous", "clash", "overwritten", "discarded", "ignored"
  ]

proc sharedSolution(): UnifiedSolution =
  solutionOf(@[("libfoo", "1.4.2"), ("nim", "2.2.0")],
             @[("enableTLS", "true")])

suite "NLF-ID-5 provenance reports shared names":

  test "the side table keeps the SET of names, not the first one":
    # Defect (a). BuildXL's `m_qualifierToFriendlyQualifierName.TryAdd`
    # (`QualifierTable.cs:148-153`) keeps whichever name arrived first and
    # silently drops the rest. §6.3 requires the set.
    let tempRoot = createTempDir("repro-nlf-id5-set", "")
    defer: removeDir(tempRoot)

    let hostPath = tempRoot / "host-tools.lock"
    let targetPath = tempRoot / "aarch64.lock"
    let ciPath = tempRoot / "ci-min.lock"
    for p in [hostPath, targetPath, ciPath]:
      writeCommittedLock(p, sharedSolution())

    var provenance = initLockProvenance()
    var identity: LockIdentity
    for (name, path) in [(HostTools, hostPath), (TargetRuntime, targetPath),
                         (ThirdName, ciPath)]:
      identity = lockIdentityOf(readCommittedLock(path))
      provenance.recordBinding(identity, name)

    let names = provenance.namesFor(identity)
    check names.len == 3
    check HostTools in names
    check TargetRuntime in names
    check ThirdName in names
    # Sorted, so diagnostics built on it are deterministic regardless of the
    # order the bindings were resolved in.
    check names == @[ThirdName, HostTools, TargetRuntime]

    # Recording the same binding twice is idempotent — a re-resolve must not
    # make one name appear as two.
    provenance.recordBinding(identity, HostTools)
    check provenance.namesFor(identity).len == 3

    # And the table really is keyed on the identity: a DIFFERENT lock gets
    # its own entry rather than joining this one.
    let otherPath = tempRoot / "other.lock"
    writeCommittedLock(otherPath,
      solutionOf(@[("libfoo", "2.0.0"), ("nim", "2.2.0")]))
    let otherIdentity = lockIdentityOf(readCommittedLock(otherPath))
    provenance.recordBinding(otherIdentity, "other")
    check provenance.namesFor(otherIdentity) == @["other"]
    check provenance.namesFor(identity).len == 3
    check provenance.identities().len == 2

  test "`repro why` reports both names as SHARING":
    let tempRoot = createTempDir("repro-nlf-id5-why", "")
    defer: removeDir(tempRoot)

    let hostPath = tempRoot / "host-tools.lock"
    let targetPath = tempRoot / "aarch64.lock"
    writeCommittedLock(hostPath, sharedSolution())
    writeCommittedLock(targetPath, sharedSolution())

    let identity = lockIdentityOf(readCommittedLock(hostPath))
    check identity == lockIdentityOf(readCommittedLock(targetPath))

    var provenance = initLockProvenance()
    provenance.recordBinding(identity, HostTools)
    provenance.recordBinding(identity, TargetRuntime)

    check provenance.isShared(identity)

    let lines = lockProvenanceReportLines(provenance, identity)
    let rendered = lines.join("\n")
    checkpoint("repro why would print:\n" & rendered)

    # The identity is reported — it is the key, and an operator correlates it
    # against a cache entry.
    check lines.len == 2
    check lines[0] == LockFileIdentityLabel & $identity

    # BOTH names are reported. This is the assertion defect (a) fails.
    check lines[1].startsWith(LockFileNamesLabel)
    check lines[1].contains(HostTools)
    check lines[1].contains(TargetRuntime)

    # Phrased as sharing, in §6.3's own words.
    check lines[1].contains("resolved identically")
    check lines[1].contains("artifacts shared")

    # Defect (b): NOT as a warning, a conflict or a collision.
    for word in AlarmVocabulary:
      if rendered.contains(word):
        checkpoint("sharing was reported using alarm vocabulary `" & word &
          "`: " & rendered)
      check not rendered.contains(word)

  test "a single binding reports the one name, still without alarm":
    # The control for the phrasing. Without it, an implementation that
    # printed the sharing sentence unconditionally would pass the case above.
    let tempRoot = createTempDir("repro-nlf-id5-single", "")
    defer: removeDir(tempRoot)

    let onlyPath = tempRoot / "repro.lock"
    writeCommittedLock(onlyPath, sharedSolution())
    let identity = lockIdentityOf(readCommittedLock(onlyPath))

    var provenance = initLockProvenance()
    provenance.recordBinding(identity, "default")

    check not provenance.isShared(identity)
    let lines = lockProvenanceReportLines(provenance, identity)
    let rendered = lines.join("\n")
    check lines.len == 2
    check lines[1].contains("default")
    # One name is not "shared", so the sharing sentence must NOT appear.
    check not rendered.contains("resolved identically")
    check not rendered.contains("artifacts shared")
    for word in AlarmVocabulary:
      check not rendered.contains(word)

  test "an unbound identity still reports its key and claims no names":
    # An action can carry a governing identity that no name resolved to in
    # this process — every edge outside a solved graph does. `repro why` must
    # still print the key, and must not invent a name.
    var provenance = initLockProvenance()
    let identity = lockIdentityOutsideSolvedGraph()
    let lines = lockProvenanceReportLines(provenance, identity)
    check lines.len == 1
    check lines[0] == LockFileIdentityLabel & $identity

  test "the provenance table never contributes to a key":
    # §6.3: "maintained alongside the cache and never mixed into any key.
    # Diagnostics read from it; identity does not."
    #
    # Structural, not incidental: `lockIdentityOf` takes a
    # `CanonicalSolvedGraph`, which has no name field, so there is no
    # argument through which a name could reach it. The behavioural check is
    # that recording bindings — any number, under any names — leaves the
    # identity of the same content untouched.
    let tempRoot = createTempDir("repro-nlf-id5-keys", "")
    defer: removeDir(tempRoot)
    let lockPath = tempRoot / "repro.lock"
    writeCommittedLock(lockPath, sharedSolution())

    let before = lockIdentityOf(readCommittedLock(lockPath))
    var provenance = initLockProvenance()
    for name in [HostTools, TargetRuntime, ThirdName, "default", "production"]:
      provenance.recordBinding(before, name)
    let after = lockIdentityOf(readCommittedLock(lockPath))

    check before == after
    check provenance.namesFor(before).len == 5
    for name in provenance.namesFor(before):
      check not ($after).contains(name)

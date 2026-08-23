## PMC-4 — the lock entry pins the resolved microarchitecture target.
##
## Platform-And-Microarchitecture-Constraints PMC-4, deliverable 1:
## "`lockIdentity` includes the resolved target; a lock produced on a v3 host
## is legible (and correct) on a v2 host."
##
## ## What this test is actually defending
##
## Once selection depends on the host's microarchitecture, a lock entry that
## omits the target means ONE recipe resolved on TWO hosts yields two
## different artifacts under one entry — the lockfile silently stops meaning
## one thing. That is a "works until it doesn't" failure: nothing reports an
## error, the second host just gets different bytes.
##
## ## The half that is easy to get wrong in the other direction
##
## The obvious implementation — always hash a `target` entry, empty string and
## all — is CORRECT for distinguishing targets and CATASTROPHIC in deployment:
## it moves every lock identity that exists today, because every graph that
## exists today declares no floor. That is a silent fleet-wide cache-miss
## event dressed up as a safety fix.
##
## So the golden below is not decoration. `LevelLessGolden` was measured on
## the PRE-PMC-4 tree, by compiling a probe that never names `resolvedTarget`
## (so it builds against both trees) against `identity.nim` + `repro_lock.nim`
## as of the commit before PMC-4 landed, and reading the identity back:
##
##   pre-PMC-4 : blake3:37b8d297b03a9f200bb70943b2a577555d308c61c41a868f425605e9aeede6e0
##   post-PMC-4: blake3:37b8d297b03a9f200bb70943b2a577555d308c61c41a868f425605e9aeede6e0
##
## It is an INDEPENDENTLY MEASURED value, not this code's own output recorded
## back as an expectation, which is the only version of this assertion worth
## having. If a future change moves it, that change invalidates every lock in
## the fleet and the person making it needs to know before they push, not
## after.

import std/unittest

import repro_lock

const
  LevelLessGolden =
    "blake3:37b8d297b03a9f200bb70943b2a577555d308c61c41a868f425605e9aeede6e0"
    ## Measured on the pre-PMC-4 tree — see the module docstring.

proc graphWith(targets: openArray[string]): CanonicalSolvedGraph =
  ## The same two-package graph every case below uses, differing ONLY in the
  ## resolved target, so nothing else can explain an identity change.
  doAssert targets.len == 2
  CanonicalSolvedGraph(
    platform: "amd64-linux",
    packages: @[
      SolvedPackageInstance(
        name: "libfoo",
        version: "1.4.2",
        sourceIdentity: "sha256:demo-source-libfoo",
        variants: @[],
        resolvedTarget: targets[0]),
      SolvedPackageInstance(
        name: "app",
        version: "0.9.0",
        sourceIdentity: "sha256:demo-source-app",
        variants: @[],
        resolvedTarget: targets[1])],
    graphVariants: @[])

suite "PMC-4 — the lock entry pins the resolved target":

  test "a floor-less graph keeps the identity it had before PMC-4":
    # The compatibility guarantee for every lock that already exists.
    check $lockIdentityOf(graphWith(["", ""])) == LevelLessGolden

  test "a resolved target changes the identity":
    let levelless = lockIdentityOf(graphWith(["", ""]))
    let v3 = lockIdentityOf(graphWith(["x86-64-v3", ""]))
    let v2 = lockIdentityOf(graphWith(["x86-64-v2", ""]))
    check $v3 != $levelless
    check $v2 != $levelless
    # Two different targets are two different answers, not one.
    check $v3 != $v2

  test "the target is attributed to the instance that resolved for it":
    # Two instances in one graph may legitimately resolve differently — a v3
    # build of one tool beside a level-less build of another. If the target
    # were hashed graph-wide instead of per instance, these two would
    # collide.
    check $lockIdentityOf(graphWith(["x86-64-v3", ""])) !=
          $lockIdentityOf(graphWith(["", "x86-64-v3"]))

  test "features participate, not just the level":
    # PMC-3 made the level sugar over a feature set; a lock that recorded only
    # the level would lose the distinction the cache key preserves.
    check $lockIdentityOf(graphWith(["x86-64-v3", ""])) !=
          $lockIdentityOf(graphWith(["x86-64-v3+avx512vl", ""]))

  test "identical inputs give identical identities":
    # The target must not leak nondeterminism into the key: same graph twice,
    # same answer. Without this the two assertions above could pass for the
    # wrong reason.
    check $lockIdentityOf(graphWith(["x86-64-v3", "x86-64-v2"])) ==
          $lockIdentityOf(graphWith(["x86-64-v3", "x86-64-v2"]))
    check $lockIdentityOf(graphWith(["", ""])) ==
          $lockIdentityOf(graphWith(["", ""]))

## PMC-4 — a lock produced on a v3 host, read on a v2 host.
##
## Platform-And-Microarchitecture-Constraints PMC-4 acceptance:
## "a lock produced on a high-level host is legible on a lower one and either
## resolves a satisfiable artifact or fails LOUDLY. It must not silently
## re-resolve to something the lock never named."
##
## ## Two failure modes, and only one of them is loud
##
## `lock.platform` is the cpu-os coordinate. A lock refreshed on an
## x86-64-v3 machine can name a v3 floor and still carry
## `platform: amd64-linux`, so every pre-PMC-4 validity check passes on a v2
## host while the artifacts it names cannot execute there. The failure is a
## SIGILL inside a later build with nothing pointing back at the lock.
##
## The tempting "fix" is worse than the bug: have the reading host quietly
## re-resolve to something it CAN run. The build then succeeds while the lock
## no longer describes what was built, which is the one outcome worse than
## refusing — a lockfile that does not mean one thing is not a lockfile.
##
## So this test pins BOTH halves:
##   * LEGIBLE — the recorded target survives a serializer round-trip
##     unchanged on the reading host. Nothing rewrites it to the reader's own
##     target, and nothing drops it.
##   * LOUD — the unsatisfiable case is refused through the SAME primitive
##     selection uses, naming the shortfall.
##
## Hermetic by construction: the host target is a value passed in, never a
## probe, so this runs on hardware that has none of the features named.

import std/[strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_lock

proc lockNaming(target: string): SolvedGraphLock =
  ## A one-package lock as `repro lock refresh` would write it on a host that
  ## resolved `target`.
  SolvedGraphLock(
    platform: "amd64-linux",
    packages: @[
      LockedPackage(
        name: "libfoo",
        version: "1.4.2",
        source: "sha256:demo-source-libfoo",
        selection: ssSelected,
        target: target)],
    variants: @[])

let
  v2Host = initPlatformTarget(pcX86_64, mlX86_64_v2)
  v3Host = initPlatformTarget(pcX86_64, mlX86_64_v3)

suite "PMC-4 — a v3 lock read on a v2 host":

  test "the recorded target is LEGIBLE after a round-trip":
    # The reading host must not rewrite the lock to its own target. If this
    # ever fails, the lock has stopped naming what it named.
    let written = serializeSolvedGraphLock(lockNaming("x86-64-v3"))
    let reread = parseSolvedGraphLock(written)
    check reread.packages.len == 1
    check reread.packages[0].target == "x86-64-v3"

  test "an absent target reads as no floor, not as the reader's target":
    # Every lock written before PMC-4 has no `target` key. It must read as
    # "no floor" -- the answer the writing host actually recorded -- and not
    # be back-filled from whatever machine happens to be reading.
    let reread = parseSolvedGraphLock(serializeSolvedGraphLock(lockNaming("")))
    check reread.packages[0].target == ""

  test "the v3 floor is REFUSED on a v2 host, and the shortfall is named":
    let verdict = resolvedTargetSatisfiedBy("x86-64-v3", v2Host)
    check not verdict.ok
    # Named, not merely refused: a bare "no matching arm" here puts us back
    # where PMC-1 started.
    check verdict.missing.len > 0
    check verdict.badToken.len == 0   # a capability gap, not a vocabulary one
    let named = describeCpuFeatures(verdict.missing)
    check named.len > 0
    check "avx2" in named

  test "the satisfiable direction resolves rather than refusing":
    # "Refuses what it cannot run" and "accepts what it can" are different
    # properties; the first passes trivially if the check refuses everything.
    check resolvedTargetSatisfiedBy("x86-64-v2", v3Host).ok
    check resolvedTargetSatisfiedBy("x86-64-v3", v3Host).ok
    check resolvedTargetSatisfiedBy("", v2Host).ok

  test "an unreadable target is refused as a VOCABULARY problem":
    # Distinct from a capability gap: `missing` is empty, so a diagnostic that
    # blindly rendered it would print "missing cpu features: " with nothing
    # after it. The two want different messages.
    let verdict = resolvedTargetSatisfiedBy("x86-64-v9", v3Host)
    check not verdict.ok
    check verdict.badToken.len > 0
    check verdict.missing.len == 0

  test "a lock's target participates in its identity across the round-trip":
    # Ties the legibility above to the thing that actually protects the
    # cache: two locks differing only in target are two different answers,
    # and remain so after serialization.
    let v3 = parseSolvedGraphLock(serializeSolvedGraphLock(lockNaming("x86-64-v3")))
    let none = parseSolvedGraphLock(serializeSolvedGraphLock(lockNaming("")))
    check $lockIdentityOf(v3) != $lockIdentityOf(none)

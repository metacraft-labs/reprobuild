## NPC-M6 verification `test_npc_m6_refresh_shows_index_age` (threat model
## G34, residual risk R2, NPC-AREQ15): `repro lock refresh` and `repro lock
## diff` print the pinned index revision's generation time -- the root's
## `generated_at`, written by the generator -- and its age. Against an index
## remote frozen at an old revision the refresh SUCCEEDS (a freeze is not
## refused) and the printed time and age are the old ones, so the freeze is
## visible; and nothing printed calls a refresh a protection against a stale
## mirror.
##
## Falsifying mutation (recorded in the plan): printing the refresh's own
## time instead of the root's generation time hides the freeze, and the
## age assertions fail.
##
## No mock: a real index repository and shared clone, the production verbs.

import std/[os, strutils, unittest]

import ./nimble_m6_fixtures

proc noProtectionClaim(output: string) =
  ## No line may present the refresh as a protection against a stale or
  ## frozen mirror, nor as current (NPC-AREQ15).
  let t = output.toLowerAscii()
  check "stale" notin t
  check "protect" notin t
  check "up to date" notin t
  check "up-to-date" notin t

suite "NPC-M6: refresh and diff show the index's generation time and age":
  test "a frozen index refreshes, and its old generation time is printed":
    var w = newWorld("age")
    let generated = daysAgo(40)
    let gen = w.publish(@[package("alpha", @[record("alpha", "1.0.0")])],
      generated, "generation 1")
    let dir = w.newProject(@[("alpha", "")])

    let first = refreshProvisioning(dir)
    checkpoint first.output
    check first.rc == 0
    let line = "nimble index \"" & IndexRepo & "\" at " & gen.commit &
      ": generated " & isoUtc(generated) & " (40 days old)"
    check line in first.output
    noProtectionClaim(first.output)
    let before = dir / "before.lock"
    copyFile(dir / "repro.lock", before)

    # The remote publishes nothing new (frozen). The refresh still succeeds
    # -- freeze is not refused -- and still prints the 40-day-old time.
    let again = refreshProvisioning(dir)
    checkpoint again.output
    check again.rc == 0
    check line in again.output
    check indexPin(dir).revision == gen.commit
    noProtectionClaim(again.output)

    # A plain refresh (the pin is not moved) prints it too.
    let plain = lockVerb(dir, "refresh")
    checkpoint plain.output
    check plain.rc == 0
    check line in plain.output

    # The diff of the two locks prints the generation time of each side.
    let diff = lockDiff(before, dir / "repro.lock")
    checkpoint diff.output
    check diff.rc == 0
    check "nimble index (old lock): " & line in diff.output
    check "nimble index (new lock): " & line in diff.output
    noProtectionClaim(diff.output)

  test "a new generation shows its own time, and the diff both":
    var w = newWorld("age-moved")
    let oldAt = daysAgo(30)
    let newAt = daysAgo(2)
    let g1 = w.publish(@[package("alpha", @[record("alpha", "1.0.0")])],
      oldAt, "generation 1")
    let dir = w.newProject(@[("alpha", "")])
    check refreshProvisioning(dir).rc == 0
    let before = dir / "before.lock"
    copyFile(dir / "repro.lock", before)
    let g2 = w.publish(@[package("alpha", @[record("alpha", "1.0.0"),
      record("alpha", "1.2.0")])], newAt, "generation 2")
    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    check ("at " & g2.commit & ": generated " & isoUtc(newAt) &
      " (2 days old)") in moved.output
    let diff = lockDiff(before, dir / "repro.lock")
    checkpoint diff.output
    check diff.rc == 1
    check ("revision " & g1.commit & " -> " & g2.commit) in diff.output
    check ("nimble index (old lock): nimble index \"" & IndexRepo & "\" at " &
      g1.commit & ": generated " & isoUtc(oldAt) & " (30 days old)") in
      diff.output
    check ("nimble index (new lock): nimble index \"" & IndexRepo & "\" at " &
      g2.commit & ": generated " & isoUtc(newAt) & " (2 days old)") in
      diff.output
    check "~ nimble:alpha: version 1.0.0 -> 1.2.0" in diff.output

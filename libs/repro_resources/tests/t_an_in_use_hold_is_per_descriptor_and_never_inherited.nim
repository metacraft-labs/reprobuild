## A consumer's in-use hold on a leased state belongs to that one hold: a
## second hold in the same process is independent of it, and no program a
## child `exec`s inherits it (Ephemeral-State-Leases.md §4.6, "The primitive").
## A `fork` without `exec` still shares the hold, as the spec says; every
## child `repro` starts execs, which is what the two child cases model.
##
## Daemonless correctness rests on this lock (§4.3): a reaper may destroy a
## state only after claiming its in-use lock exclusively, without waiting.
## Two weaker primitives would each break that while every other test of the
## store still passed:
##
##   * a per-process `fcntl` lock: two consumes of one state inside one
##     `repro` would share a single lock, and ending either one would drop
##     both, so a reaper could destroy the state under the consume that is
##     still running;
##   * a lock descriptor that is not close-on-exec: a run-edge's command, or a
##     daemon it detaches, would inherit the hold and keep the state pinned
##     after `repro` released it, so the lease could never be reaped. The
##     reaper's exclusive claim has the same hazard in reverse: a provider
##     session started while it is held would block every later consume.
##
## Recorded as issue
## `reprobuild-pm/issues/2026-11-16-the-in-use-lock-primitive-and-its-inheritance-are-unspecified.md`.
##
## No mocks: the production `holdStateInUse` / `tryClaimStateForReap` /
## `releaseStateLock` on a real store under a private temporary directory, and
## a real child process. The inheritance cases are POSIX-only: it spawns
## `/bin/sh` and relies on `osproc` inheriting every descriptor that is not
## close-on-exec, which is the hazard it guards against.

import std/[os, osproc, tempfiles, unittest]

import repro_core/ambient_execution
import repro_resources/state_store

const Address = "state.cluster"

suite "the in-use hold is per descriptor and never inherited":
  test "two holds in one process are independent of each other":
    let root = createTempDir("inuse-hold-", "")
    defer: removeDir(root)
    let store = openStateStore(root)

    var first = holdStateInUse(store, Address)
    var second = holdStateInUse(store, Address)

    var claim: ReproFileLock
    check not tryClaimStateForReap(store, Address, claim)

    # Ending one consume must leave the other's hold in force. A per-process
    # lock would be gone now, and the claim below would succeed.
    releaseStateLock(first)
    check not tryClaimStateForReap(store, Address, claim)

    releaseStateLock(second)
    check tryClaimStateForReap(store, Address, claim)
    releaseStateLock(claim)

  when not defined(windows):
    test "a child spawned during a consume does not keep the state in use":
      let root = createTempDir("inuse-hold-", "")
      defer: removeDir(root)
      let store = openStateStore(root)

      var hold = holdStateInUse(store, Address)
      # A command that outlives the consume, as a detached daemon would.
      let child = uncontrolledStartProcess("/bin/sh",
        args = ["-c", "sleep 60"], options = {})
      defer:
        if child.running:
          child.terminate()
          discard child.waitForExit()
        child.close()
      check child.running

      releaseStateLock(hold)
      check child.running   # the child still lives, holding whatever it inherited

      var claim: ReproFileLock
      let claimed = tryClaimStateForReap(store, Address, claim)
      if not claimed:
        checkpoint("the reaper's claim was refused while only the child " &
          "lived: the child inherited the consumer's in-use hold")
      check claimed
      if claimed:
        releaseStateLock(claim)

    test "a child spawned while a reaper holds its claim does not keep it":
      # The reaper keeps its exclusive claim across the provider's observe
      # and destroy, which may start a long-lived provider session. If that
      # session inherited the claim, every later consume of the address
      # would wait for it forever.
      let root = createTempDir("inuse-hold-", "")
      defer: removeDir(root)
      let store = openStateStore(root)

      var claim: ReproFileLock
      check tryClaimStateForReap(store, Address, claim)
      let child = uncontrolledStartProcess("/bin/sh",
        args = ["-c", "sleep 60"], options = {})
      defer:
        if child.running:
          child.terminate()
          discard child.waitForExit()
        child.close()
      check child.running

      releaseStateLock(claim)
      check child.running

      var again: ReproFileLock
      let claimed = tryClaimStateForReap(store, Address, again)
      if not claimed:
        checkpoint("the in-use lock stayed held while only the child " &
          "lived: the child inherited the reaper's exclusive claim")
      check claimed
      if claimed:
        releaseStateLock(again)

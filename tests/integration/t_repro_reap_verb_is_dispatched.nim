## `repro reap` reaches `runReapCli` instead of falling through to usage.
##
## Ephemeral-State-Leases.md §4.3 names `repro reap --once` as fallback (b) —
## the reason the lease model does not require a daemon for correctness — and
## CLI/reap.md specifies the verb. `runReapCli` has existed and been tested
## since L3 (`libs/repro_resources/tests/t_l3_reaper.nim` cases 9/10/15/18), but
## nothing DISPATCHED it: there was no `reap` arm in `runThinAppDispatch`, so
## the command the spec promised fell through to the generic usage text and
## exited 2. `runReapCli`'s own docstring used to record that — *"Nothing
## dispatches `repro reap` yet"* — and has been corrected along with this
## wiring, which is why that sentence is quoted here in the past tense rather
## than cited as a live reference.
##
## That is not a cosmetic gap. The `lease-reaper` row of CLI/health.md names
## this command as its remedy, and Interactive-UX-And-Progress.md Principle 2
## makes a remedy an obligation: a failing row that printed a command the binary
## answers with usage text would be the same lie as the log line nobody read
## (reprobuild-pm/issues/2026-09-29-lease-reap-tick-has-never-once-succeeded.md).
##
## Asserted, each against a POSITIVE CONTROL on the same surface so a passing
## case cannot be a command that is broken for everyone:
##
##   1. `repro reap --once --state-root=<empty>` reaches the verb: it prints the
##      verb's own report (`state-root=`, `reaped:`, `kept:`) and exits 0.
##      Control: a neighbouring *undispatched* spelling (`repro reapx`) prints
##      the usage banner and does NOT print a reap report — so arm 1 is evidence
##      about the `reap` arm and not about the binary in general.
##   2. The sweep targets the `--state-root` it was given and ONLY that one:
##      two stores are seeded identically, one is named, and the other must come
##      out unmentioned and untouched. A canned report, or a sweep that reached
##      for the ambient per-user store instead, fails here.
##   3. A record it cannot destroy makes the verb exit NONZERO and name the
##      record — the diagnosis the health remedy promises ("then act on what it
##      names"), not a silent success.
##
## Hermetic: a throwaway state store under the test's own scratch directory. No
## daemon, no provider, no network. The records are written with the library's
## own `writeStateRecord`, so the on-disk shape is the production one.

import std/[options, os, strutils, tables, times, unittest]

import repro_resources
import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc scratch(sub: string): string =
  result = getTempDir() / ("reap-dispatch-" & $getCurrentProcessId() & "-" & sub)
  removeDir(result)
  createDir(result)

proc expiredRecord(address, typeId, attrsTypeId: string;
                   now: Time): ResourceStateRecord =
  ## A record whose lease lapsed an hour ago, so any sweep must select it.
  ResourceStateRecord(
    address: address,
    typeId: typeId,
    determinism: rdVolatile,
    attrsTypeId: attrsTypeId,
    attrsJson: "\x01\x00\x00\x00\x00\x00",
    dependsOn: @[],
    identity: "fixture:" & address,
    present: true,
    holders: initTable[string, Time](),
    effectiveDeadline: some(now - initDuration(hours = 1)),
    lastRenewed: now - initDuration(hours = 1))

suite "repro reap is a dispatched verb":

  test "the reap verb reaches runReapCli, and an undispatched one does not":
    let bin = reproBinary()
    let root = scratch("empty")
    defer: removeDir(root)
    let storeRoot = root / "state"
    discard openStateStore(storeRoot)

    let res = runShell(shellCommand(
      [bin, "reap", "--once", "--state-root=" & storeRoot]))
    # The verb's own report, not the usage banner.
    check res.output.contains("repro reap: state-root=" & storeRoot)
    check res.output.contains("reaped: 0")
    check res.output.contains("kept: 0")
    # An empty store is nothing to do, which is success.
    check res.code == 0

    # POSITIVE CONTROL for the control: a spelling with no dispatch arm falls
    # through to usage and prints no reap report. Without this, arm 1 could pass
    # on a binary that printed a reap report for every argv.
    let undispatched = runShell(shellCommand([bin, "reapx", "--once"]))
    check undispatched.output.contains("usage: repro")
    check not undispatched.output.contains("repro reap: state-root=")
    # The exit code is the sharper half of the control, and the pair is what
    # makes arm 1 meaningful: a dispatched verb with nothing to do exits 0, an
    # undispatched spelling exits 2. Before the `reap` arm existed, `repro
    # reap` was indistinguishable from this line.
    check undispatched.code == 2

  test "the sweep targets the --state-root it was given, and only that one":
    ## Arm 2: the report is produced by sweeping the store the operator named,
    ## not by printing a constant and not by reaching for the ambient per-user
    ## store. Two stores are seeded identically and only one is named; the
    ## other must come out untouched.
    ##
    ## (The "it really destroys things" half is proven where a provider exists
    ## to destroy over: `t_l3_reaper` cases 1-8 over the in-process transport,
    ## and `t_lease_reap_destroys_an_unlinked_type_over_a_session` against a
    ## real launched provider. A record of a type `repro` does not link cannot
    ## be destroyed by this binary by construction, which is arm 3's subject.)
    let bin = reproBinary()
    let root = scratch("targets")
    defer: removeDir(root)
    let namedRoot = root / "named"
    let otherRoot = root / "other"
    let named = openStateStore(namedRoot)
    let other = openStateStore(otherRoot)

    let now = getTime()
    writeStateRecord(named,
      expiredRecord("in-named", "reapdispatch.unlinked",
                    "reapdispatch.unlinked", now))
    writeStateRecord(other,
      expiredRecord("in-other", "reapdispatch.unlinked",
                    "reapdispatch.unlinked", now))

    let res = runShell(shellCommand(
      [bin, "reap", "--once", "--state-root=" & namedRoot]))
    check res.output.contains("repro reap: state-root=" & namedRoot)
    # The named store's record was inspected and reported...
    check res.output.contains("in-named")
    # ...and the other store's was never looked at. This is the falsifiable
    # half: a sweep over the wrong root, or over both, fails here.
    check not res.output.contains("in-other")
    check not res.output.contains(otherRoot)
    check hasStateRecord(other, "in-other")

  test "a record it cannot destroy exits nonzero and names the record":
    ## Arm 3: the health row's remedy says "then act on what it names". A verb
    ## that exited 0 and said nothing would make that remedy useless, which is
    ## the failure mode the whole issue is about.
    let bin = reproBinary()
    let root = scratch("stuck")
    defer: removeDir(root)
    let storeRoot = root / "state"
    let store = openStateStore(storeRoot)

    # A typeId no provider in `repro` serves and whose attrs codec it does not
    # link: the live daemon's `gosti.nic` shape. `present: true`, so the
    # sweep must attempt a destroy and fail rather than no-op.
    writeStateRecord(store,
      expiredRecord("nic0", "reapdispatch.unlinked", "reapdispatch.unlinked",
                    getTime()))

    let res = runShell(shellCommand(
      [bin, "reap", "--once", "--state-root=" & storeRoot]))
    check res.code != 0                       # the diagnosis, not a success
    check res.output.contains("nic0")         # WHICH record
    check res.output.contains("reapdispatch.unlinked")
    # The record is left for a sweep that can do better — never silently
    # dropped, which would strand real state with nothing naming it.
    check hasStateRecord(store, "nic0")

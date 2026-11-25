## The add-on's egress table brought back when it is found gone (ReproOS
## Add-On Mode spec §10.4 *The egress observer*; §13 decisions 43 and 187;
## threat model T65, C86).
##
## The observer, ``repro-addon-egress.service``, loads the table at start
## and is tied to the host's ``nftables.service`` by ``PartOf=`` and
## ``ReloadPropagatedFrom=``, so a restart, reload or stop of that service
## reloads or stops it too. One case escapes the tie: a START of
## ``nftables.service`` (``systemctl enable --now nftables``, the usual way
## an operator adopts it), or any other flush, while the observer is active.
## The flush deletes the table, the observer stays active
## (``RemainAfterExit=yes``), and nothing loads the table again.
##
## Decision 187 (the operator, 2026-11-25): an apply (``repro system addon
## apply``, every agent and operator apply) and the boot re-assertion
## converge that drift -- an ``lcNftTable`` entry of the ledger whose table
## is missing -- by RELOADING the observer unit, whose ``ExecReload=`` loads
## the table again. They ask PID 1 to do it; neither holds ``CAP_NET_ADMIN``
## for it, and no new unit does (T65). ``plan``, ``verify`` and the egress
## check stay strictly read-only: they report the table missing (the check
## as ``egress-observer-missing``) and never reload it. Until the next apply
## or re-assertion the table stays gone: that window is stated in §10.4.

import std/strutils

from repro_infra/host_exec import runSystemctl

import ./generation0
import ./ledger
import ./mutations

type
  UnitState* = proc (unit: string): string {.closure.}
    ## The unit's ``ActiveState`` ("" when systemctl cannot say).
  UnitReload* = proc (unit: string): tuple[ok: bool; output: string] {.closure.}
    ## ``systemctl reload <unit>``.
  TableMissing* = proc (e: LedgerEntry): bool {.closure.}
    ## Whether the table ``e`` names is gone from the host.

proc hostUnitState(unit: string): string =
  try:
    let r = runSystemctl(["show", "-p", "ActiveState", "--value", unit])
    if r.exitCode == 0: r.output.strip() else: ""
  except CatchableError:
    ""

proc hostReload(unit: string): tuple[ok: bool; output: string] =
  try:
    let r = runSystemctl(["reload", unit])
    (r.exitCode == 0, r.output.strip())
  except CatchableError as e:
    (false, e.msg)

proc hostTableMissing(e: LedgerEntry): bool =
  observeDrift(e) == "missing"

proc convergeEgressTable*(l: Ledger; unitState: UnitState = hostUnitState;
                          reload: UnitReload = hostReload;
                          missing: TableMissing = hostTableMissing):
    seq[string] =
  ## For each ``lcNftTable`` entry whose table is gone: reload the observer
  ## when it is active, and say what was done. An observer that is not
  ## active (stopped with ``nftables.service`` through ``PartOf=``) is left
  ## for its next start, which loads the table: the fetch unit's
  ## ``Requires=`` starts it at the next fetch. Never raises.
  for e in l.entries:
    if e.class != lcNftTable: continue
    var gone = false
    try: gone = missing(e)
    except CatchableError: gone = false
    if not gone: continue
    let state = unitState(EgressUnit)
    if state != "active":
      result.add("egress table " & e.path & " is missing; " & EgressUnit &
        " is " & (if state.len > 0: state else: "in an unknown state") &
        ", and its next start loads it")
      continue
    let r = reload(EgressUnit)
    if r.ok:
      result.add("egress table " & e.path & " was missing; reloaded " &
        EgressUnit & " (§13 decision 187)")
    else:
      result.add("egress table " & e.path & " is missing; reloading " &
        EgressUnit & " failed: " & r.output)

proc readOnlyMustNotReload*(l: Ledger; unitState: UnitState = hostUnitState;
                            reload: UnitReload = hostReload;
                            missing: TableMissing = hostTableMissing):
    seq[string] =
  ## What ``plan``, ``verify`` and the egress check do about a missing table:
  ## nothing (decision 187). The falsifying build
  ## ``read-only-commands-reload-egress`` makes them converge too, so the
  ## VM step that holds them read-only goes red.
  when mutated("read-only-commands-reload-egress"):
    convergeEgressTable(l, unitState, reload, missing)
  else:
    discard l
    @[]

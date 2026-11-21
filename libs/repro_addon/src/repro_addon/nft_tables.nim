## The add-on's one nftables table, as an object on the host (owner
## decision 2026-11-04, threat model G40, DET-AO-3).
##
## The add-on owns exactly one table, ``inet repro_addon_egress``, and never
## reads, changes or flushes any other: every command here names that table
## (or lists the table NAMES only, for the fingerprint). It is created by the
## egress observer unit of generation 0, tracked by the ledger
## (``lcNftTable``), fingerprinted (the ``nftables`` component) and removed
## by uninstall.
##
## The ``nft`` binary is the base's (the ``nftables`` package); the add-on
## carries none. A base without it, or whose kernel lacks the ``socket
## cgroupv2`` match, cannot host the observer and bootstrap refuses it
## (``preflight``: ``EAddOnEgressObserverUnavailable``).

import std/strutils

import ./host_exec

const
  EgressTableFamily* = "inet"
  EgressTableName* = "repro_addon_egress"
  EgressTableKey* = EgressTableFamily & " " & EgressTableName
    ## The ledger path and the fingerprint key of the table.
  NftCandidates* = ["/usr/sbin/nft", "/sbin/nft"]
  EgressObserverUnavailable* = "EAddOnEgressObserverUnavailable"
    ## Bootstrap's refusal of a base that cannot carry the observer.

proc nftBinary*(): string =
  ## The base's ``nft``, "" when it has none.
  resolveHostTool(NftCandidates)

proc listTableNames*(nft = nftBinary(); hostNamespaces = false):
    tuple[ok: bool; tables: seq[string]; why: string] =
  ## ``<family> <name>`` of every table in the host's ruleset (names only:
  ## no rule of another table is read). ``ok`` false, with the reason, when
  ## ``nft`` is missing or cannot list.
  ##
  ## nftables tables belong to a network namespace. ``hostNamespaces`` runs
  ## ``nft`` as a transient unit of PID 1 (``runInHostNamespaces``), so a
  ## caller confined with ``PrivateNetwork=yes`` -- the re-assert and apply
  ## units -- reads the host's ruleset and not its own empty one (A11 audit
  ## session 2, G4: in its own namespace the listing fails on every boot,
  ## a healthy table and a removed one alike).
  if nft.len == 0: return (false, @[], "no nft on this host")
  let r = if hostNamespaces:
            try: runInHostNamespaces([nft, "list", "tables"], timeoutSec = 30)
            except HostToolMissing as e:
              return (false, @[], e.msg)
          else: runHostTool([nft, "list", "tables"], timeoutSec = 30)
  if r.exitCode != 0:
    return (false, @[], "nft list tables exited " & $r.exitCode & ": " &
      r.output.strip())
  result.ok = true
  for line in r.output.splitLines():
    let p = line.splitWhitespace()
    if p.len == 3 and p[0] == "table": result.tables.add(p[1] & " " & p[2])

proc egressTablePresent*(nft = nftBinary()): bool =
  let l = listTableNames(nft)
  l.ok and EgressTableKey in l.tables

proc deleteEgressTable*(nft = nftBinary()): string =
  ## Delete the add-on's table (only it). "" on success or when it is
  ## already gone, otherwise why not.
  if nft.len == 0: return "no nft on this host"
  if not egressTablePresent(nft): return ""
  let r = runHostTool([nft, "delete", "table", EgressTableFamily,
                       EgressTableName], timeoutSec = 30)
  if r.exitCode != 0: r.output.strip() else: ""

proc egressObserverProblem*(nft: string; timeoutSec = 30): string =
  ## Why this host cannot carry the egress observer, or "": ``nft`` must
  ## exist and the kernel must accept a ``socket cgroupv2`` match. Checked
  ## with ``nft -c`` (check only: nothing is committed), on a scratch table
  ## named for the check, matching ``system.slice``, which every systemd
  ## host has.
  if nft.len == 0:
    return EgressObserverUnavailable & ": the base has no nft (the " &
      "nftables package): the deploy agent's egress observer cannot be " &
      "installed, and bootstrap does not fall back to running without it"
  var r: HostToolResult
  try:
    r = runHostTool([nft, "-c", "add table inet repro_addon_probe ; " &
      "add chain inet repro_addon_probe c { type filter hook output priority 0 ; } ; " &
      "add rule inet repro_addon_probe c socket cgroupv2 level 1 " &
      "\"system.slice\" counter"], timeoutSec = timeoutSec)
  except CatchableError as e:
    return EgressObserverUnavailable & ": " & nft & " cannot run: " & e.msg
  if r.exitCode != 0:
    return EgressObserverUnavailable & ": the kernel or nft refuses a " &
      "socket cgroupv2 match (" & r.output.strip() & ")"
  ""


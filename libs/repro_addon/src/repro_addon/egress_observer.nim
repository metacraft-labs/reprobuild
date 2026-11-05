## The deploy agent's egress observer at run time (owner decision
## 2026-11-04; threat model DET-AO-3, G40; spec §10.4).
##
##   repro system addon egress-check
##       (``repro-addon-egress-check.service``, after every fetch and on its
##       timer.) Reads the add-on's nftables table (``nft_tables``): every
##       destination the fetch unit's slice sent to outside its allow-list,
##       with its packet count. A destination that is new, or whose count
##       grew, since the last check is a DET-AO-3 detection; a table that is
##       gone is one too (``egress-observer-missing``: the observer was
##       removed, which is itself what an attacker with root would do). Every
##       run heartbeats, so a check that stopped running is silence, not
##       "nothing refused" (DET-5).
##
## Why a table at all: the fetch unit's ``IPAddressDeny=`` drops a refused
## packet in a cgroup BPF program that counts nothing it denies, and the only
## process that sees the ``EPERM`` is the attacker's. Netfilter's output hook
## runs before that program, so the table sees every packet the unit sends;
## it drops none (the unit's filter does).

import std/[json, os, strutils, tables, times]

import ./evidence
import ./evidence_ship
import ./generation0
import ./host_exec
import ./mutations
import ./nft_tables

const
  EgressStateName* = "egress-refused.state"
    ## Under the evidence directory: ``<address> <packets>`` per line, the
    ## counts the previous check saw.

type
  RefusedDestination* = tuple[address: string; packets: int64]

  EgressCheck* = object
    present*: bool
    refused*: seq[RefusedDestination]   ## everything the table holds
    fresh*: seq[RefusedDestination]     ## new or grown since the last check
    error*: string

proc parseRefusedSet*(json: string): seq[RefusedDestination] =
  ## The elements of one ``nft -j list set`` answer: ``{"elem": {"val":
  ## <address>, "counter": {"packets": N, ...}}}`` (counted sets), or a bare
  ## address (a set without counters: counted as 1).
  let doc = parseJson(json)
  for item in doc{"nftables"}.getElems():
    let st = item{"set"}
    if st.isNil: continue
    for e in st{"elem"}.getElems():
      if e.kind == JString:
        result.add((e.getStr(), 1'i64))
      elif e{"elem"} != nil:
        let v = e["elem"]
        result.add((v{"val"}.getStr(), v{"counter"}{"packets"}.getBiggestInt(1)))

proc readState(path: string; table: string): Table[string, int64] =
  ## The counts the previous check saw -- of THIS table instance: a table
  ## loaded since (every boot, every restart of the observer unit) starts
  ## its counters at zero, so counts of another instance are none (A11
  ## audit F3).
  result = initTable[string, int64]()
  try:
    var instance = ""
    for l in readFile(path).splitLines():
      let p = l.splitWhitespace()
      if p.len == 2 and p[0] == "table": instance = p[1]
      elif p.len == 2: result[p[0]] = parseBiggestInt(p[1])
    when not mutated("egress-state-survives-reload"):
      if instance != table: result.clear()
  except CatchableError:
    discard

proc tableInstance*(nft: string): string =
  ## The table's kernel handle: new on every load (the table is deleted and
  ## defined again), so it names the instance its counters belong to.
  let r = runHostTool([nft, "-j", "list", "table", EgressTableFamily,
                       EgressTableName], mergeStderr = false, timeoutSec = 30)
  if r.exitCode != 0: return ""
  try:
    for item in parseJson(r.output){"nftables"}.getElems():
      if item{"table"} != nil: return $item["table"]{"handle"}.getBiggestInt()
  except CatchableError:
    discard
  ""

proc freshSince*(refused: seq[RefusedDestination]; statePath: string;
                 table = "-"): seq[RefusedDestination] =
  ## The destinations new or grown since the counts in ``statePath`` (of the
  ## same table instance ``table``), which then holds these counts.
  let before = readState(statePath, table)
  var text = "table " & table & "\n"
  for d in refused:
    if before.getOrDefault(d.address, 0) < d.packets: result.add(d)
    text.add(d.address & " " & $d.packets & "\n")
  createDir(parentDir(statePath))
  writeFile(statePath & ".tmp", text)
  moveFile(statePath & ".tmp", statePath)

proc checkEgress*(nft, statePath: string): EgressCheck =
  ## Read the table and compare with the last check (see the header). The
  ## state is rewritten only after the read succeeded.
  if nft.len == 0:
    return EgressCheck(error: "no nft on this host")
  let l = listTableNames(nft)
  if not l.ok: return EgressCheck(error: l.why)
  if EgressTableKey notin l.tables: return EgressCheck(present: false)
  result.present = true
  for setName in ["refused4", "refused6"]:
    let r = runHostTool([nft, "-j", "list", "set", EgressTableFamily,
                         EgressTableName, setName], mergeStderr = false,
                        timeoutSec = 30)
    if r.exitCode != 0:
      result.error = "nft list set " & setName & " exited " & $r.exitCode
      return
    try: result.refused.add(parseRefusedSet(r.output))
    except CatchableError as e:
      result.error = "nft list set " & setName & ": " & e.msg
      return
  let instance = tableInstance(nft)
  result.fresh = freshSince(result.refused, statePath,
                            if instance.len > 0: instance else: "-")

proc recordEgressCheck*(c: EgressCheck; site: EvidenceSite;
                        heartbeatMs: int64) =
  ## The check's records: one detection per fresh destination, one when the
  ## table is gone, and the heartbeat. Raises when a detection cannot be
  ## written (the unit then fails, which the journal shows).
  if c.error.len == 0 and not c.present:
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-observer-missing",
      fields: @[("message", "the add-on's nftables table " & EgressTableKey &
                 " is not loaded")]), site)
  for d in c.fresh:
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-refused",
      fields: @[("destination", d.address), ("count", $d.packets),
                ("message", "the deploy agent's fetch unit sent to " &
                 d.address & ", outside its allow-list")]), site)
  discard recordEvidence(EvidenceEvent(detector: edEgress,
    category: ecHeartbeat, kind: "egress-check", offHostOnly: true,
    fields: @[("intervalMs", $heartbeatMs),
              ("status", if c.error.len > 0: "error: " & c.error
                         elif c.present: "present" else: "missing"),
              ("count", $c.refused.len)]), site)

proc runEgressCheckCli*(args: seq[string]): int =
  if args.len != 0:
    stderr.write("usage: repro system addon egress-check\n")
    return 2
  let site = defaultSite()
  let heartbeat = try: int64(loadEvidenceConf().heartbeatSec) * 1000
                  except CatchableError: 0'i64
  let c = checkEgress(nftBinary(), EvidenceDirPath / EgressStateName)
  try:
    recordEgressCheck(c, site, heartbeat)
  except CatchableError as e:
    stderr.write("repro system addon egress-check: " & e.msg & "\n")
    return 1
  stdout.write("egress observer: " &
    (if c.error.len > 0: "error: " & c.error
     elif not c.present: "TABLE MISSING"
     else: $c.refused.len & " refused destination(s), " & $c.fresh.len &
           " new") & "\n")
  if c.error.len > 0 or not c.present: 1 else: 0

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

import std/[json, os, sets, strutils, tables, times]

import ./evidence
import ./evidence_ship
import ./generation0
import ./host_exec
import ./ledger
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
    counted*: int64                     ## the named counter now
    unattributed*: int64
      ## refused packets since the last check that no set element accounts
      ## for: the sets were full (A11 review finding 13)
    setFull*: bool                      ## a set holds ``EgressSetSize``
    stateError*: string
      ## The check's own state could not be used (read, parsed, written).
    error*: string

const
  EgressSummaryNamesMax* = 64
    ## Addresses a truncated check's summary names.
  EgressDetectionsMax* = 64
    ## Destinations one check records one by one; the rest in one summary,
    ## so a flood of throwaway addresses cannot fill the host's records.

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

proc parseCounterPackets*(json: string): int64 =
  ## The packets of a ``nft -j list counter`` answer.
  for item in parseJson(json){"nftables"}.getElems():
    let c = item{"counter"}
    if c != nil: return c{"packets"}.getBiggestInt(0)
  0'i64

const EgressStateHeader* = "repro-egress-state 2"
  ## The first line of the observer check's state file. A file without it
  ## (empty, truncated, foreign) is unreadable, never a first run; a file in
  ## the format before it (its first line ``table ...``) is read once and
  ## rewritten.

type
  EgressStateError* = object of CatchableError
  OwedDestination* = tuple[address: string; since: int64; packets: int64]
  EgressState = object
    counts: Table[string, int64]     ## of THIS table instance
    owed: seq[OwedDestination]       ## oldest first
    check: int64                     ## checks made so far

proc readState(path: string; table: string): EgressState =
  ## The counts the previous check saw -- of THIS table instance: a table
  ## loaded since (every boot, every restart of the observer unit) starts
  ## its counters at zero, so counts of another instance are none (A11
  ## audit F3) -- and the destinations it saw but has not recorded by
  ## address yet (``owed``), kept whatever the instance: a reload empties
  ## the sets, not what the host owes (A11 review round 3). A missing file
  ## is the first check. A file that cannot be read, or is not this
  ## format, raises ``EgressStateError``: it is never read as empty.
  result.counts = initTable[string, int64]()
  if not fileExists(path) and not symlinkExists(path): return
  var text = ""
  try: text = readFile(path)
  except IOError, OSError:
    raise newException(EgressStateError, "the egress check's state " & path &
      " cannot be read: " & getCurrentExceptionMsg())
  let lines = text.splitLines()
  let legacy = lines.len > 0 and lines[0].startsWith("table ")
  if not legacy and (lines.len == 0 or lines[0] != EgressStateHeader):
    when mutated("egress-state-empty-is-valid"):
      return
    raise newException(EgressStateError, "the egress check's state " &
      path & " does not begin with " & EgressStateHeader &
      " (empty or not the check's)")
  var instance = ""
  try:
    for i, l in lines:
      if i == 0 and not legacy: continue
      let p = l.splitWhitespace()
      if p.len == 0: continue
      if p.len == 2 and p[0] == "table": instance = p[1]
      elif p.len == 2 and p[0] == "check": result.check = parseBiggestInt(p[1])
      elif p.len == 3 and p[0] == "counter":
        result.counts[" counter"] = parseBiggestInt(p[2])
      elif p.len == 4 and p[0] == "owed":
        result.owed.add((p[1], parseBiggestInt(p[2]), parseBiggestInt(p[3])))
      elif p.len == 3 and p[0] == "deferred":       # round 2's format
        result.owed.add((p[1], 0'i64, 0'i64))
      elif p.len == 2: result.counts[p[0]] = parseBiggestInt(p[1])
      else: raise newException(ValueError, "line " & $(i + 1) & ": " & l)
  except ValueError as e:
    raise newException(EgressStateError, "the egress check's state " & path &
      " is malformed: " & e.msg)
  when not mutated("egress-state-survives-reload"):
    if instance != table:
      result.counts.clear()
      when mutated("egress-owed-dropped-at-reload"):
        result.owed.setLen(0)

proc instanceKey*(listTable, bootId: string): string =
  ## The instance a ``nft -j list table`` answer names: this boot's id and
  ## the table's kernel handle. The handle is new on every load (the table is
  ## deleted and defined again), but the kernel's handle counter starts again
  ## at every boot, so a table loaded in the same order at the next boot gets
  ## the same handle; the boot id tells the two apart. The bare handle when
  ## the boot id is unknown; "" when the answer names no table.
  try:
    for item in parseJson(listTable){"nftables"}.getElems():
      if item{"table"} != nil:
        let handle = $item["table"]{"handle"}.getBiggestInt()
        when mutated("egress-instance-ignores-boot"):
          return handle
        else:
          return if bootId.len > 0: bootId & "/" & handle else: handle
  except CatchableError:
    discard
  ""

proc tableInstance*(nft: string): string =
  ## The instance the table's counters belong to (``instanceKey``).
  let r = runHostTool([nft, "-j", "list", "table", EgressTableFamily,
                       EgressTableName], mergeStderr = false, timeoutSec = 30)
  if r.exitCode != 0: return ""
  instanceKey(r.output, bootIdNow())

proc freshSince*(refused: seq[RefusedDestination]; statePath: string;
                 table = "-"; counted = -1'i64;
                 unattributed: ptr int64 = nil;
                 recordMax = EgressDetectionsMax): seq[RefusedDestination] =
  ## The destinations to record since the check before, in the order the
  ## check records them, which ``statePath`` then reflects. Raises
  ## ``EgressStateError`` (nothing written) when the state is unusable.
  ##
  ## Destinations OWED by earlier checks come first, oldest first, whether
  ## or not the current table still lists them (a reload empties the sets:
  ## an owed destination is recorded with the count it had); then the
  ## destinations new since the counts of this table instance, then the
  ## grown ones. Only the first ``recordMax`` are recorded and leave the
  ## owed list; every other fresh one joins it, behind those already owed.
  ## So each owed destination is recorded within ``ceil(owed ahead of it /
  ## recordMax) + 1`` checks, however many decoys stay fresh (A11 review
  ## round 3; round 2 ordered them by the set's listing, and dropped them at
  ## a reload).
  ##
  ## With ``counted`` (the named counter), ``unattributed`` is set to the
  ## refused packets since the last check that no set element's growth
  ## accounts for.
  let before = readState(statePath, table)
  let checkNo = before.check + 1
  var now = initTable[string, int64]()
  for d in refused: now[d.address] = d.packets
  var owedSet = initHashSet[string]()
  var owed: seq[OwedDestination]
  for o in before.owed:
    if o.address in owedSet: continue
    owedSet.incl(o.address)
    owed.add((o.address, o.since, max(o.packets, now.getOrDefault(o.address, 0))))
  when mutated("egress-owed-by-listing"):
    # FALSIFYING BUILD: owed destinations in the set's listing order.
    var listed: seq[OwedDestination]
    for d in refused:
      for o in owed:
        if o.address == d.address: listed.add(o)
    owed = listed
  var fresh0, grown0: seq[RefusedDestination]
  var grown = 0'i64
  for d in refused:
    let was = before.counts.getOrDefault(d.address, 0)
    if was < d.packets:
      grown += d.packets - was
      if d.address in owedSet: continue
      if was == 0: fresh0.add(d) else: grown0.add(d)
  for o in owed: result.add((o.address, o.packets))
  result.add(fresh0)
  result.add(grown0)
  var stillOwed: seq[OwedDestination]
  for i, d in result:
    if i < recordMax: continue
    if i < owed.len: stillOwed.add(owed[i])
    else: stillOwed.add((d.address, checkNo, d.packets))
  var text = EgressStateHeader & "\n" & "table " & table & "\n" &
             "check " & $checkNo & "\n"
  for d in refused:
    text.add(d.address & " " & $d.packets & "\n")
  if counted >= 0 and not mutated("egress-ignores-counter"):
    let wasCounted = before.counts.getOrDefault(" counter", 0)
    if unattributed != nil:
      unattributed[] = max(0'i64, (counted - wasCounted) - grown)
    text.add("counter refused " & $counted & "\n")
  for o in stillOwed:
    text.add("owed " & o.address & " " & $o.since & " " & $o.packets & "\n")
  try:
    createDir(parentDir(statePath))
    writeFileAtomic(statePath, text, 0o600)
  except CatchableError as e:
    raise newException(EgressStateError, "the egress check's state " &
      statePath & " cannot be written: " & e.msg)

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
  let c = runHostTool([nft, "-j", "list", "counter", EgressTableFamily,
                       EgressTableName, "refused"], mergeStderr = false,
                      timeoutSec = 30)
  result.counted = -1
  if c.exitCode == 0:
    try: result.counted = parseCounterPackets(c.output)
    except CatchableError: discard
  var v4, v6 = 0
  for d in result.refused:
    if ':' in d.address: inc v6 else: inc v4
  result.setFull = v4 >= EgressSetSize or v6 >= EgressSetSize
  let instance = tableInstance(nft)
  var un = 0'i64
  try:
    result.fresh = freshSince(result.refused, statePath,
                              if instance.len > 0: instance else: "-",
                              result.counted, addr un)
  except EgressStateError as e:
    # Fail closed: nothing is judged from a state the check cannot trust,
    # and the state is left as it is for the operator (A11 review round 3).
    result.stateError = e.msg
    result.error = e.msg
    return
  result.unattributed = un

proc recordEgressCheck*(c: EgressCheck; site: EvidenceSite;
                        heartbeatMs: int64) =
  ## The check's records: one detection per fresh destination, one when the
  ## table is gone, and the heartbeat. Raises when a detection cannot be
  ## written (the unit then fails, which the journal shows).
  if c.stateError.len > 0:
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-state-unreadable",
      fields: @[("message", c.stateError)]), site)
  if c.error.len == 0 and not c.present:
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-observer-missing",
      fields: @[("message", "the add-on's nftables table " & EgressTableKey &
                 " is not loaded")]), site)
  let cap = min(c.fresh.len, EgressDetectionsMax)
  for d in c.fresh[0 ..< cap]:
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-refused",
      fields: @[("destination", d.address), ("count", $d.packets),
                ("message", "the deploy agent's fetch unit sent to " &
                 d.address & ", outside its allow-list")]), site)
  if c.fresh.len > cap:
    # Truncated: the rest are owed (their state did not advance) and a
    # later check records them by address. The summary names the first of
    # them too, bounded.
    var named: seq[string]
    for d in c.fresh[cap ..< min(c.fresh.len, cap + EgressSummaryNamesMax)]:
      named.add(d.address)
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-refused-summary",
      fields: @[("count", $(c.fresh.len - cap)), ("truncated", "true"),
                ("destinations", named.join(" ")),
                ("message", $(c.fresh.len - cap) & " more refused " &
                 "destinations than one check records one by one: the " &
                 "list was truncated, and they are recorded by later " &
                 "checks")]), site)
  if c.setFull or c.unattributed > 0:
    # The sets no longer tell every destination apart: the counter still
    # counts, and this says so (A11 review finding 13).
    discard recordEvidence(EvidenceEvent(detector: edEgress,
      category: ecDetection, trigger: "egress-set-full",
      fields: @[("count", $c.unattributed),
                ("message", "the refused-destination sets are full; " &
                 $c.unattributed & " refused packet(s) since the last " &
                 "check are counted but not attributed to a destination")]),
      site)
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

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
## Its positive control runs on the host, every fetch (DET-4; spec §10.4
## "Scheduled positive controls"): the fetch unit sends one datagram to the
## control address (``sendEgressControl``), and the check reports whether
## the table counted it (the heartbeat's ``control``). A table that is loaded
## and no longer matches the slice -- rules flushed, or a slice created
## again, since a ``socket cgroupv2`` match keeps the cgroup it resolved at
## load -- heartbeats ``present`` exactly as a working one does; only the
## control tells them apart, and the off-host check alerts when no control
## tripped for a while (``evidence_check``).
##
## Why a table at all: the fetch unit's ``IPAddressDeny=`` drops a refused
## packet in a cgroup BPF program that counts nothing it denies, and the only
## process that sees the ``EPERM`` is the attacker's. Netfilter's output hook
## runs before that program, so the table sees every packet the unit sends;
## it drops none (the unit's filter does).

import std/[json, nativesockets, net, os, sets, strutils, tables, times]
from std/posix import EPERM

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
  EgressControlAddress* = "127.68.69.84"
    ## Where the fetch unit sends its control datagram. In the loopback
    ## range, so it never leaves the host whatever the routing; outside
    ## every allow-list (the allow-list names the two origins), so the
    ## table's rules count it and the unit's ``IPAddressDeny=`` then drops
    ## it.
  EgressControlPort* = 9
    ## The discard port (RFC 863): nothing is expected to answer.

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
    counterReset*: string
      ## What went down, when a count of this table instance is lower than
      ## the last check saw it, or a destination left its set
      ## (``freshSince``); "" otherwise. Printed by the check, not recorded
      ## as a detection.
    stateError*: string
      ## The check's own state could not be used (read, parsed, written).
    control*: string
      ## The positive control (spec §10.4): ``tripped`` when the control
      ## address's count grew since the previous check of this table
      ## instance, ``idle`` when it did not (no fetch ran since),
      ## ``not-run`` when the table is missing or could not be read.
    controlPackets*: int64
      ## The control address's count in the table now (never a refused
      ## destination: kept apart from ``refused``).
    error*: string

const
  EgressSummaryNamesMax* = 64
    ## Addresses a truncated check's summary names.
  EgressDetectionsMax* = 64
    ## Destinations one check records one by one; the rest in one summary,
    ## so a flood of throwaway addresses cannot fill the host's records.

  EgressListMaxBytes* = 8 * 1024 * 1024
    ## What the check keeps of one ``nft -j list set`` answer, and of the
    ## ``nft -j list table`` it reads the instance from (which lists both
    ## sets with their elements). A full set is
    ## ``EgressSetSize`` elements of about a hundred bytes each (an address
    ## and its counter), so several hundred kilobytes; ``runHostTool``'s
    ## default bound of 64 KiB cut the answer off at some 800 destinations,
    ## and every check of a fuller set failed to parse it, and lost the
    ## table's instance with it (reprobuild-pm issue
    ## ``2026-11-19-addon-egress-check-cannot-read-a-set-of-more-than-64-kib.md``).
    ## An answer that reaches this bound is reported as cut short, never
    ## parsed.

proc sendEgressControl*(): string =
  ## The fetch unit's positive control: one UDP datagram from this process
  ## to ``EgressControlAddress``. Returns "" when it was handed to the
  ## kernel -- refused by the unit's ``IPAddressDeny=`` (``EPERM``) included,
  ## since the table's output hook counted it before that drop -- and why
  ## not otherwise (a socket the unit's ``RestrictAddressFamilies=`` does
  ## not allow, say), which the fetch reports and the off-host check then
  ## sees as a control that never trips.
  when mutated("egress-control-not-sent"):
    # FALSIFYING BUILD: the fetch sends no control.
    return ""
  var sock: Socket
  try:
    sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)
  except CatchableError as e:
    return "cannot open the control socket: " & e.msg
  defer: sock.close()
  try:
    sock.sendTo(EgressControlAddress, Port(EgressControlPort), "c")
  except OSError as e:
    # EPERM is the unit's own filter dropping it after it was counted.
    if e.errorCode != EPERM.int32:
      return "cannot send the control datagram: " & e.msg
  ""

proc parseRefusedSet*(json: string): seq[RefusedDestination] =
  ## The elements of one ``nft -j list set`` answer: ``{"elem": {"val":
  ## <address>, "counter": {"packets": N, ...}}}`` (counted sets), or a bare
  ## address (a set without counters: counted as 1). An address listed
  ## more than once is one destination, with the largest count listed: the
  ## kernel's dump of a set that grows while it is read repeats elements
  ## (measured on Linux 6.18 with nftables 1.0.9: up to 59 repeats in one
  ## listing of a set being filled), and counted twice they filled the
  ## check's records and the set's size, and lowered the shortfall.
  let doc = parseJson(json)
  var at = initTable[string, int]()
  proc add(res: var seq[RefusedDestination]; address: string;
           packets: int64) =
    if address in at:
      res[at[address]].packets = max(res[at[address]].packets, packets)
    else:
      at[address] = res.len
      res.add((address, packets))
  for item in doc{"nftables"}.getElems():
    let st = item{"set"}
    if st.isNil: continue
    for e in st{"elem"}.getElems():
      if e.kind == JString:
        add(result, e.getStr(), 1'i64)
      elif e{"elem"} != nil:
        let v = e["elem"]
        add(result, v{"val"}.getStr(),
            v{"counter"}{"packets"}.getBiggestInt(1))

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
  ## rewritten. The line ``unattributed <n>`` was added under the same
  ## header (2026-11-18): a file without it is read as having reported the
  ## shortfall its counter and sets show, and an older reader takes the
  ## line for a destination that is never listed, which its next write
  ## drops. So were ``kernel-counter <n>`` (2026-11-19), the named counter
  ## as the kernel gave it, and ``starting-over 1``: for a file without
  ## the first, the counter is compared with ``counter refused <n>``, which
  ## was never above it. Since then ``unattributed`` may be below
  ## zero (after a reset of the counter). A reader from before takes a
  ## value below zero for a missing line and derives the amount from the
  ## counter and the counts, the two new lines among them: zero, in
  ## effect, which is where it stood before these lines existed.

type
  EgressStateError* = object of CatchableError
  OwedDestination* = tuple[address: string; since: int64; packets: int64]
  EgressState = object
    counts: Table[string, int64]     ## of THIS table instance
    owed: seq[OwedDestination]       ## oldest first
    check: int64                     ## checks made so far
    control: int64                   ## the control address's count (of
                                     ## THIS table instance)
    reported: int64                  ## the shortfall already reported
                                     ## (of THIS table instance); below
                                     ## zero after a reset of the counter
    hasReported: bool                ## false: the state predates the line
    kernel: int64                    ## the named counter as the kernel
                                     ## gave it, the control's packets
                                     ## included (of THIS table instance);
                                     ## -1: not known
    startingOver: bool               ## a count went down while the counter
                                     ## could not be read: the next check
                                     ## that reads it starts over

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
  result.kernel = -1
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
      elif p.len == 2 and p[0] == "control":
        result.control = parseBiggestInt(p[1])
      elif p.len == 2 and p[0] == "unattributed":
        result.reported = parseBiggestInt(p[1])
        result.hasReported = true
      elif p.len == 2 and p[0] == "kernel-counter":
        result.kernel = parseBiggestInt(p[1])
      elif p.len == 2 and p[0] == "starting-over":
        result.startingOver = true
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
    # ``-`` is an instance that could not be read: it matches none, the
    # next ``-`` included, since a reload may fall between two checks that
    # both read ``-`` (reprobuild-pm issue
    # ``2026-11-21-addon-egress-check-reports-packets-a-set-held-after-a-set-reset-and-compares-two-unread-instances.md``).
    # FALSIFYING BUILD: two unread instances match, as before.
    let unread = (instance == "-" or table == "-") and
                 not mutated("egress-unread-instance-compared")
    if instance != table or unread:
      result.counts.clear()
      result.control = 0
      result.reported = 0
      result.hasReported = true
      result.kernel = -1
      result.startingOver = false
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
                       EgressTableName], mergeStderr = false, timeoutSec = 30,
                      maxOutputBytes = EgressListMaxBytes)
  if r.exitCode != 0: return ""
  instanceKey(r.output, bootIdNow())

proc freshSince*(refused: seq[RefusedDestination]; statePath: string;
                 table = "-"; counted = -1'i64;
                 unattributed: ptr int64 = nil;
                 recordMax = EgressDetectionsMax;
                 controlPackets = -1'i64;
                 controlBefore: ptr int64 = nil;
                 kernelCounted = -1'i64;
                 counterReset: ptr string = nil;
                 setFull = true): seq[RefusedDestination] =
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
  ## refused packets since the last check that no set element accounts
  ## for. It is judged on this table instance's totals, never on the
  ## growth of each since the last check, and ``counted`` must be read
  ## BEFORE the sets, both of one table instance (``checkEgress``): the
  ## counter's rule runs before the set update, so the sets then hold every
  ## packet the counter counted, and perhaps some after it. The packets
  ## they lack -- ``counted`` less the sum of the elements' counts -- are
  ## never more than those a full set did not add, and a check reports only
  ## what that shortfall exceeds the most already reported. So a packet
  ## that arrived between the two reads is attributed whichever read saw it
  ## first, and none a full set did not add is reported twice. The
  ## shortfall errs low only by packets sent between a check's two reads,
  ## so a check of a quiet table reports every one not yet reported
  ## (reprobuild-pm issue
  ## ``2026-11-17-addon-egress-check-reports-set-full-for-one-unattributed-packet.md``:
  ## the difference of the two growths read such a packet as unattributed).
  ##
  ## A count that went DOWN within one table instance -- the named counter
  ## (``kernelCounted``: as the kernel gave it, the control's packets
  ## included; ``counted`` when not given), the control's element, or a
  ## destination's -- or a destination that left its set, was changed in
  ## place: the kernel only adds to the counts, the sets have no timeout, a
  ## reload gives the table a new instance, and each count is compared with
  ## its own earlier reading, so no read race lowers one. (``counted``
  ## itself, the counter less the control's element read after it, can fall
  ## by a control datagram sent between the reads, which is why the counter
  ## is kept as the kernel gave it.) ``nft reset counter`` does it, a
  ## host-wide ``nft reset counters`` too, and both keep the table's
  ## handle. ``counterReset`` then says what went down, and the check
  ## starts over from what it reads now: the shortfall it reads becomes the
  ## amount already reported -- below zero when the counter fell under what
  ## the sets hold, so it is taken from the counter as the kernel gave it
  ## less the control's element, never from ``counted``, which stops at
  ## zero -- and packets a full set does not add from here on are reported
  ## one for one (kept at the old amount, they were hidden until the
  ## counter made up what it lost: reprobuild-pm issue
  ## ``2026-11-18-addon-egress-counter-reset-hides-unattributed-packets-until-the-shortfall-regrows.md``);
  ## a destination whose count went down is new or grown again by its new
  ## count once that is above zero, and the control's earlier count is
  ## zero. The check that sees the counter itself fall reports the least
  ## it can prove (``setFull`` below): the counter's new value, all
  ## counted after the reset, less what the elements can have gained
  ## since it. Limits. Packets no set added before the reset and after the
  ## last check cannot be told any more; nor can any, when what fell was
  ## not the counter. The shortfall that check reads errs low by packets
  ## sent between its two reads, as every check's does, and here nothing
  ## above it absorbs the error: while a set is full, the check after may
  ## report those few as unattributed. A reset the counts have outgrown by
  ## the next check is not seen: while no set is full that costs nothing;
  ## while one is, a reset of a set every element of which has outgrown
  ## it may be reported as unattributed packets, up to what those elements
  ## held before it.
  ## And nothing is judged while the table's instance cannot be
  ## read (``table`` is ``-``), since a reload lowers the counts too, and
  ## a state keyed to ``-`` is compared with nothing (``readState``). When
  ## the counter cannot be read at the check that sees a count go down,
  ## the next check that reads it starts over (``starting-over`` in the
  ## state) and reports none either.
  ##
  ## ``setFull`` says whether a set (the control's element counted) holds
  ## ``EgressSetSize`` elements now. A set adds every packet until it is
  ## full and only grows, so while none is full and no destination has
  ## left one, no refused packet since the last check went unadded, and
  ## ``unattributed`` is zero whatever the counts say; a shortfall read
  ## then (a reset of the sets' counts that they have since outgrown) only
  ## raises the amount already reported. The caller that cannot tell
  ## passes nothing: a full set is assumed, and nothing is hidden.
  ## Limits: a set also fails to add a packet when the kernel cannot
  ## allocate the new element (``nft_dynset_new`` allocates with
  ## ``GFP_ATOMIC``), and a deletion (``CAP_NET_ADMIN``, threat T65) of
  ## elements added since the last check is not seen; such packets are
  ## not reported while no set is full.
  ##
  ## The check that sees the counter fall reports what it can prove from
  ## the counts it reads. When the counter alone fell, that is what the
  ## counter holds less what the sets and the control's element gained;
  ## when an element's count fell with it (``nft reset set``, which zeroes
  ## every element), any element may have been reset and outgrown its old
  ## count, so each element's gain is at most its whole count, and the
  ## least is what the counter holds less what the sets and the control's
  ## element hold; when a destination left its set, the packets it was
  ## sent since are not known, and the least is none.
  ##
  ## ``controlPackets`` (the control address's count now, when known) is
  ## kept in the state as its own line, and ``controlBefore`` is set to the
  ## count the previous check of this table instance saw (0 for a new
  ## instance). ``refused`` and ``counted`` must already leave the control
  ## out (``checkEgress``).
  let before = readState(statePath, table)
  let checkNo = before.check + 1
  # What went down since the last check of this instance: the first one
  # named, the others counted.
  var wentDown: string
  var wentDownMore = 0
  # Besides the counter: an element's count fell (``elementFell``), or a
  # destination left its set (``left``). Each bounds what the check that
  # sees the counter fall can prove (above).
  var elementFell, left = false
  # Not judged when the instance could not be read (``-``): a reload is
  # then not told from a reset. FALSIFYING BUILD: never judged, so a count
  # that went down is compared as any other.
  let noticed = table != "-" and not mutated("egress-ignores-counter-reset")
  proc fell(what: string; was, now: int64) =
    if wentDown.len == 0:
      wentDown = what & " fell from " & $was & " to " & $now
    else: inc wentDownMore
  let kernelNow = if kernelCounted >= 0: kernelCounted else: counted
  # A state from before ``kernel-counter`` kept the counter less the
  # control's element, which was never above the counter: a counter below
  # even that has fallen.
  let kernelWas = if before.kernel >= 0: before.kernel
                  else: before.counts.getOrDefault(" counter", -1)
  var counterFell = false
  if noticed and kernelNow >= 0 and kernelWas >= 0 and kernelNow < kernelWas:
    fell("the counter of refused packets", kernelWas, kernelNow)
    counterFell = true
  var controlWas = before.control
  if noticed and controlPackets >= 0 and controlPackets < before.control:
    fell("the control address's count", before.control, controlPackets)
    controlWas = 0
    elementFell = true
  if controlBefore != nil: controlBefore[] = controlWas
  var now = initTable[string, int64]()
  for d in refused: now[d.address] = d.packets
  if noticed:
    for a, was in before.counts:
      if a != " counter" and a notin now:
        left = true
        if wentDown.len == 0:
          wentDown = "the destination " & a & " (" & $was &
            " packet(s)) left its set"
        else: inc wentDownMore
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
  var held = 0'i64
  var gained = max(0'i64, controlPackets) - controlWas
    ## what the sets and the control's element gained since the last check
  for d in refused:
    held += d.packets
    var was = before.counts.getOrDefault(d.address, 0)
    if noticed and was > d.packets:
      fell("the count of " & d.address, was, d.packets)
      was = 0
      elementFell = true
    gained += d.packets - was
    if was < d.packets:
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
  if controlPackets >= 0:
    text.add("control " & $controlPackets & "\n")
  for d in refused:
    text.add(d.address & " " & $d.packets & "\n")
  if not mutated("egress-ignores-counter"):
    var reported = before.reported
    if not before.hasReported:
      # A state written before this line (reprobuild before the issue
      # above): it had reported the shortfall its own check saw, so that is
      # not reported again. That check read the sets first, so this can
      # credit a packet or two of its read race too: an approximation made
      # once, at the upgrade.
      var wasHeld = 0'i64
      for a, n in before.counts:
        if a != " counter": wasHeld += n
      reported = max(0'i64,
                     before.counts.getOrDefault(" counter", 0) - wasHeld)
    var startOver = wentDown.len > 0 or (noticed and before.startingOver)
    if counted >= 0:
      # ``counted`` stops at zero; after a reset the counter can be below
      # the control's element, and the shortfall must follow it there.
      let lacking = (if kernelCounted >= 0:
                       kernelCounted - max(0'i64, controlPackets)
                     else: counted) - held
      # A set that is not full added every packet (see ``setFull``).
      # FALSIFYING BUILD: a shortfall is reported whether or not a set is
      # full.
      let canLack = setFull or mutated("egress-shortfall-while-set-not-full")
      if startOver:
        # Changed in place: start over from the shortfall read now. When
        # it is the counter that fell, what it holds was counted after the
        # reset, and each of those packets is in what an element or the
        # control's element gained since the reset or in no set. That
        # gain is at most what each gained since the last check while no
        # element was reset, at most what each holds when one was, and
        # unknown when a destination left. FALSIFYING BUILD: the gain since
        # the last check, whatever else fell.
        let proven =
          if not counterFell or not canLack: 0'i64
          elif mutated("egress-reset-bound-ignores-set-reset"):
            kernelNow - gained
          elif left: 0'i64
          elif elementFell: lacking
          else: kernelNow - gained
        if unattributed != nil: unattributed[] = max(0'i64, proven)
        reported = lacking
        startOver = false
      else:
        if unattributed != nil:
          unattributed[] = if canLack: max(0'i64, lacking - reported)
                           else: 0'i64
        reported = max(reported, lacking)
      text.add("counter refused " & $counted & "\n")
    # Kept when the counter could not be read this time, so a later check
    # does not report again what was reported already.
    text.add("unattributed " & $reported & "\n")
    # Likewise kept, so a reset is still seen by the next check that reads
    # the counter.
    let kernelKept = if kernelNow >= 0: kernelNow else: before.kernel
    if kernelKept >= 0:
      text.add("kernel-counter " & $kernelKept & "\n")
    if startOver: text.add("starting-over 1\n")
  if counterReset != nil:
    counterReset[] = wentDown
    if wentDownMore > 0:
      counterReset[].add(" (and " & $wentDownMore & " more count(s) fell)")
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
  if EgressTableKey notin l.tables:
    return EgressCheck(present: false, control: "not-run")
  result.present = true
  result.control = "not-run"
  # The named counter first, the sets after it (``freshSince``): a packet
  # sent between the reads is then in the sets, never only in the counter.
  # The table's instance is read before and after both: a reload between
  # them pairs one instance's counter with another's sets, so the reads are
  # taken again, and a check that keeps meeting reloads judges no
  # unattributed packets (the next check does).
  var instance = ""
  var attempt = 0
  while true:
    inc attempt
    instance = tableInstance(nft)
    let c = runHostTool([nft, "-j", "list", "counter", EgressTableFamily,
                         EgressTableName, "refused"], mergeStderr = false,
                        timeoutSec = 30)
    result.counted = -1
    if c.exitCode == 0:
      try: result.counted = parseCounterPackets(c.output)
      except CatchableError: discard
    result.refused.setLen(0)
    for setName in ["refused4", "refused6"]:
      let r = runHostTool([nft, "-j", "list", "set", EgressTableFamily,
                           EgressTableName, setName], mergeStderr = false,
                          timeoutSec = 30,
                          maxOutputBytes = EgressListMaxBytes)
      if r.exitCode != 0:
        result.error = "nft list set " & setName & " exited " & $r.exitCode
        return
      if r.output.len >= EgressListMaxBytes:
        result.error = "nft list set " & setName & " printed more than " &
          $EgressListMaxBytes & " bytes: cut short, not judged"
        return
      try: result.refused.add(parseRefusedSet(r.output))
      except CatchableError as e:
        result.error = "nft list set " & setName & ": " & e.msg
        return
    let after = tableInstance(nft)
    if after == instance: break
    instance = after
    if attempt >= 3:
      # The sets read may be an earlier instance's. Keyed to no instance,
      # they are never compared with the next check's: keyed to the newest
      # one, lower counts there read as a change in place.
      result.counted = -1
      instance = ""
      break
  let kernelCounted = result.counted   # as read, the control included
  # The control address is the fetch unit's positive control, never a
  # refused destination: kept apart, and its packets taken off the named
  # counter so the counter and the sets still agree.
  # Whether a set is full is judged on what the set holds, the control's
  # element included.
  var v4, v6 = 0
  var others: seq[RefusedDestination]
  for d in result.refused:
    if ':' in d.address: inc v6 else: inc v4
    if d.address == EgressControlAddress:
      result.controlPackets = d.packets
    else:
      others.add(d)
  result.setFull = v4 >= EgressSetSize or v6 >= EgressSetSize
  result.refused = others
  if result.counted >= 0:
    result.counted = max(0'i64, result.counted - result.controlPackets)
  var un = 0'i64
  var controlBefore = 0'i64
  try:
    result.fresh = freshSince(result.refused, statePath,
                              if instance.len > 0: instance else: "-",
                              result.counted, addr un,
                              controlPackets = result.controlPackets,
                              controlBefore = addr controlBefore,
                              kernelCounted = kernelCounted,
                              counterReset = addr result.counterReset,
                              setFull = result.setFull)
  except EgressStateError as e:
    # Fail closed: nothing is judged from a state the check cannot trust,
    # and the state is left as it is for the operator (A11 review round 3).
    result.stateError = e.msg
    result.error = e.msg
    return
  result.unattributed = un
  result.control = if result.controlPackets > controlBefore: "tripped"
                   else: "idle"

proc recordEgressCheck*(c: EgressCheck; site: EvidenceSite;
                        heartbeatMs: int64) =
  ## The check's records: one detection per fresh destination, one when the
  ## table is gone, and the heartbeat. A count that went down in place
  ## (``counterReset``) is no record: the check prints it
  ## (``runEgressCheckCommand``), and whether it should be a detection is an
  ## open owner decision (reprobuild-pm issue
  ## ``2026-11-19-addon-egress-counter-reset-is-not-a-detection.md``).
  ## Raises when a detection cannot be written (the unit then fails, which
  ## the journal shows).
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
              ("control", if c.control.len > 0: c.control else: "not-run"),
              ("count", $c.refused.len)]), site)

proc runEgressCheckCommand*(): int =
  ## ``repro system addon egress-check`` (repro-addon-egress-check.service).
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
           " new" & (if c.counterReset.len > 0: "; COUNTERS RESET: " &
                     c.counterReset else: "")) & "\n")
  if c.error.len > 0 or not c.present: 1 else: 0

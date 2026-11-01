## The two observations ``e2e_addon_validator_never_double_signs`` is
## decided on, as pure functions over text pulled out of the guest.
##
## 1. **Conflicting signatures** in slashing-protection records, read as
##    EIP-3076 interchange files (https://eips.ethereum.org/EIPS/eip-3076,
##    the format `validator slashing-protection-history export` writes).
##    The conditions are the consensus specs' slashing conditions
##    (https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md,
##    `is_slashable_attestation_data` and proposer slashing): for one key,
##    two blocks at one slot with different signing roots; two
##    attestations with one target epoch and different signing roots (a
##    double vote); or one attestation whose source and target surround
##    another's (a surround vote). A record without a signing root (the
##    format allows it) is conflicting with any other record at its slot
##    or target, since nothing shows it signed the same message. Every
##    interchange of a run is read together, so two databases that each
##    look clean but signed different messages for one slot are a
##    conflict.
## 2. **Lifetimes** of the validator client's processes, from a monitor in
##    the guest (no unit, no hook in the client), decided on the kernel's
##    own ordering rather than on clocks (A12 review finding 3). A clock
##    cannot decide it: `/proc/<pid>/stat` gives a start time in 10 ms
##    ticks and a polled exit is only bounded by the poll, so a successor a
##    plain `systemctl restart` starts a few milliseconds after its
##    predecessor exits fell inside that window and was counted as an
##    overlap (3 of 12 runs at ab69afad80). Instead, for each validator
##    unit the monitor follows its control group (cgroup v2) through one
##    inotify descriptor, which delivers events in the kernel's order:
##
##    - `cg create <unit> <inode>`: a new incarnation of the unit's cgroup
##      (systemd creates it when the unit starts and removes it when the
##      unit goes inactive);
##    - `cg delete <unit>`: it was removed. The kernel refuses to remove a
##      cgroup that has a process in it, so every process of that
##      incarnation had exited by then;
##    - `seen <pid> <start> <unit> <inode>`: a validator process and the
##      incarnation it runs in (the cgroup directory's inode, read and then
##      confirmed by finding the process still alive: a process that
##      outlives the read cannot belong to an incarnation removed before
##      it), or `- -` outside every validator unit.
##
##    Two instances overlap when they ran in one incarnation, or in
##    incarnations of two units whose create-to-delete spans intersect in
##    that order (`cgroupOverlaps`); a span that never ended counts as open.
##    An instance outside the units is still held to the clock check
##    (`overlaps`), which only errs towards an overlap. The monitor also
##    records, once per instance, the slashing-protection database it holds
##    open (`db <pid> <device>:<inode> <path>`).
##
##    *What the order cannot see, and how it is bounded* (A12 round-2
##    review). The kernel drops inotify events when the descriptor's queue
##    is full and says so once with `IN_Q_OVERFLOW`; the monitor logs that
##    as `cg overflow`, and an overflow is itself reported as an overlap
##    (`cgroupOverlaps`): with events missing the order decides nothing, so
##    the check fails closed. An incarnation in which no validator process
##    was seen is left out of the pairing: either the unit failed before
##    its `ExecStart=` ran (a credential that did not load, a start limit),
##    or the process lived less than one scan of `/proc`. The second is
##    harmless only if a validator cannot sign within one scan, so the
##    monitor logs the longest gap between the starts of two scans
##    (`scan <seconds>`, each time it grows) and the gate requires it below
##    ``MaxScanGapSec``: before its first signature a validator client
##    decrypts its EIP-2335 keystores (scrypt, about a second for the
##    test's keys), connects to its beacon node and waits for a duty in a
##    slot. ``monitorStats`` gives the gate both numbers and the count of
##    incarnations left out, and the record carries them.

import std/[json, sets, strutils, tables]

type
  Conflict* = object
    pubkey*: string
    kind*: string     ## "double-proposal", "double-vote", "surround-vote"
    detail*: string

  Instance* = object
    pid*: string
    start*: float          ## seconds since boot
    lastSeen*: float       ## -1 while alive at the end of the log
    goneAt*: float
    unit*: string          ## the validator unit it ran in, "" outside them
    cgroup*: string        ## that incarnation's cgroup inode

const MaxScanGapSec* = 0.5
  ## The longest the monitor may go between two scans of `/proc` for an
  ## unseen validator instance to be harmless (module header).

proc rootOf(n: JsonNode): string =
  if n.hasKey("signing_root"): n["signing_root"].getStr().toLowerAscii() else: ""

proc conflicts*(interchanges: openArray[JsonNode]): seq[Conflict] =
  ## Every conflicting pair across ``interchanges``. A file of another
  ## interchange version or of no `data` raises: it is never read as clean.
  var blocks: Table[string, seq[(int, string)]]
  var atts: Table[string, seq[(int, int, string)]]
  var roots: Table[string, string]
  for ic in interchanges:
    if ic.kind != JObject or not ic.hasKey("metadata") or
        not ic.hasKey("data"):
      raise newException(ValueError, "not an EIP-3076 interchange")
    let v = ic["metadata"]["interchange_format_version"].getStr()
    if v != "5":
      raise newException(ValueError, "interchange version " & v &
        " (only 5 is read)")
    let gvr = ic["metadata"]["genesis_validators_root"].getStr().toLowerAscii()
    if roots.len > 0 and gvr notin roots:
      raise newException(ValueError, "interchanges of two different chains")
    roots[gvr] = gvr
    for d in ic["data"]:
      let pk = d["pubkey"].getStr().toLowerAscii()
      for b in d{"signed_blocks"}.getElems():
        blocks.mgetOrPut(pk, @[]).add((parseInt(b["slot"].getStr()), rootOf(b)))
      for a in d{"signed_attestations"}.getElems():
        atts.mgetOrPut(pk, @[]).add((parseInt(a["source_epoch"].getStr()),
          parseInt(a["target_epoch"].getStr()), rootOf(a)))
  for pk, bs in blocks:
    for i in 0 ..< bs.len:
      for j in i + 1 ..< bs.len:
        if bs[i][0] == bs[j][0] and
            (bs[i][1] != bs[j][1] or bs[i][1].len == 0):
          result.add(Conflict(pubkey: pk, kind: "double-proposal",
            detail: "slot " & $bs[i][0] & ": " & bs[i][1] & " / " & bs[j][1]))
  for pk, as0 in atts:
    for i in 0 ..< as0.len:
      for j in i + 1 ..< as0.len:
        let (s1, t1, r1) = as0[i]
        let (s2, t2, r2) = as0[j]
        if t1 == t2 and (r1 != r2 or r1.len == 0):
          result.add(Conflict(pubkey: pk, kind: "double-vote",
            detail: "target " & $t1 & ": " & r1 & " / " & r2))
        elif (s1 < s2 and t2 < t1) or (s2 < s1 and t1 < t2):
          result.add(Conflict(pubkey: pk, kind: "surround-vote",
            detail: $s1 & "->" & $t1 & " and " & $s2 & "->" & $t2))

proc earliestTarget*(interchanges: openArray[JsonNode]): Table[string, int] =
  ## Per key, the earliest attestation target any interchange records:
  ## where its history begins.
  for ic in interchanges:
    for d in ic["data"]:
      let pk = d["pubkey"].getStr().toLowerAscii()
      for a in d{"signed_attestations"}.getElems():
        let t = parseInt(a["target_epoch"].getStr())
        if pk notin result or t < result[pk]: result[pk] = t

proc attestationCount*(interchanges: openArray[JsonNode]): int =
  for ic in interchanges:
    for d in ic["data"]:
      result += d{"signed_attestations"}.getElems().len

proc parseLifetimes*(log: string): seq[Instance] =
  ## The monitor's log, in order: `seen <pid> <start>` and
  ## `gone <pid> <lastSeen> <goneAt>`. A malformed line raises: a skipped
  ## `gone` would hide an overlap.
  var open: Table[string, int]
  for line in log.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let f = t.splitWhitespace()
    if f[0] in ["db", "cg", "scan"]:
      continue          # the database (`databasesHeld`), the cgroups
                        # (`cgroupOverlaps`), the scan gap (`monitorStats`)
    if f[0] == "seen" and f.len in [3, 5]:
      open[f[1]] = result.len
      var inst = Instance(pid: f[1], start: parseFloat(f[2]), lastSeen: -1,
                          goneAt: -1)
      if f.len == 5 and f[3] != "-":
        inst.unit = f[3]
        inst.cgroup = f[4]
      result.add(inst)
    elif f[0] == "gone" and f.len == 4 and f[1] in open:
      let i = open[f[1]]
      result[i].lastSeen = parseFloat(f[2])
      result[i].goneAt = parseFloat(f[3])
      open.del(f[1])
    else:
      raise newException(ValueError, "malformed lifetime line: " & t)

proc databasesHeld*(log: string): seq[string] =
  ## The distinct `<device>:<inode> <path>` of the slashing-protection
  ## databases the instances held open, in first-seen order.
  for line in log.splitLines():
    let f = line.strip().splitWhitespace()
    if f.len >= 4 and f[0] == "db":
      let d = f[2 .. ^1].join(" ")
      if d notin result: result.add(d)

proc overlaps*(ls: seq[Instance]): seq[string] =
  ## Every pair of instances whose lifetimes may have overlapped: the later
  ## one started before the earlier one was seen gone (or while it was
  ## still alive at the end).
  for i in 0 ..< ls.len:
    for j in 0 ..< ls.len:
      if i == j: continue
      let a = ls[i]
      let b = ls[j]
      if b.start < a.start or (b.start == a.start and j < i): continue
      let aEnd = if a.goneAt < 0: Inf else: a.goneAt
      if b.start < aEnd:
        result.add("pid " & b.pid & " started at " & $b.start &
          " while pid " & a.pid & " (started " & $a.start & ") was " &
          (if a.goneAt < 0: "still alive"
           else: "last seen at " & $a.lastSeen & ", gone by " & $a.goneAt))

proc cgroupOverlaps*(log: string): seq[string] =
  ## The overlaps the kernel's ordering shows (module header, 2.): two
  ## instances in one incarnation of a unit's cgroup, or instances in
  ## incarnations of two units that existed at once. Instances outside the
  ## validator units are held to ``overlaps`` against every instance. A
  ## malformed ``cg`` line raises.
  type Incarnation = object
    unit: string
    created, deleted: int          ## log positions; deleted = high(int) open
    pids: seq[string]
  var incs: seq[Incarnation]
  var byKey: Table[string, int]    ## "<unit> <inode>" -> incs index
  var current: Table[string, int]  ## unit -> its open incarnation
  var pos = 0
  for line in log.splitLines():
    let f = line.strip().splitWhitespace()
    if f.len == 0: continue
    inc pos
    if f[0] != "cg": continue
    if f.len == 4 and f[2] == "create":
      byKey[f[1] & " " & f[3]] = incs.len
      current[f[1]] = incs.len
      incs.add(Incarnation(unit: f[1], created: pos, deleted: high(int)))
    elif f.len == 3 and f[2] == "delete":
      if f[1] in current:
        incs[current[f[1]]].deleted = pos
        current.del(f[1])
    elif f.len == 2 and f[1] == "overflow":
      # IN_Q_OVERFLOW: events were dropped, so the order is incomplete and
      # cannot show that two incarnations did not coexist.
      result.add("the monitor's inotify queue overflowed (IN_Q_OVERFLOW) " &
        "at log line " & $pos & ": cgroup events were lost, so the kernel's " &
        "order cannot decide an overlap")
    else:
      raise newException(ValueError, "malformed cgroup line: " & line.strip())
  let ls = parseLifetimes(log)
  var outside: seq[Instance]
  for inst in ls:
    if inst.unit.len == 0:
      outside.add(inst)
      continue
    let k = inst.unit & " " & inst.cgroup
    if k notin byKey:
      result.add("pid " & inst.pid & " ran in an incarnation of " &
        inst.unit & " (cgroup " & inst.cgroup & ") the monitor never saw " &
        "created")
      continue
    if inst.pid notin incs[byKey[k]].pids:
      incs[byKey[k]].pids.add(inst.pid)
  for i, a in incs:
    if a.pids.len > 1:
      result.add("pids " & a.pids.join(", ") & " ran in one incarnation of " &
        a.unit)
    for j in i + 1 ..< incs.len:
      let b = incs[j]
      if a.unit == b.unit or a.pids.len == 0 or b.pids.len == 0: continue
      if a.created < b.deleted and b.created < a.deleted:
        result.add(a.unit & " (pid " & a.pids.join(", ") & ") and " & b.unit &
          " (pid " & b.pids.join(", ") & ") existed at once" &
          (if a.deleted == high(int) or b.deleted == high(int):
             " (one never ended)" else: ""))
  # An instance outside the units: the conservative clock check against
  # every instance.
  if outside.len > 0:
    for o in overlaps(ls):
      for x in outside:
        if ("pid " & x.pid & " ") in o:
          result.add(o)
          break

type MonitorStats* = object
  ## What the monitor's log says about its own coverage (module header).
  overflows*: int            ## `cg overflow` lines (IN_Q_OVERFLOW)
  longestScanGapSec*: float  ## the largest `scan` value, 0 when none
  incarnations*: int         ## validator-unit cgroup incarnations created
  withoutValidator*: int     ## of those, the ones no validator was seen in

proc monitorStats*(log: string): MonitorStats =
  ## The coverage numbers the gate requires and records. A malformed
  ## `scan` line raises.
  var seenIn: HashSet[string]
  var created: seq[string]
  for line in log.splitLines():
    let f = line.strip().splitWhitespace()
    if f.len == 0: continue
    case f[0]
    of "cg":
      if f.len == 2 and f[1] == "overflow": inc result.overflows
      elif f.len == 4 and f[2] == "create": created.add(f[1] & " " & f[3])
    of "scan":
      if f.len != 2:
        raise newException(ValueError, "malformed scan line: " & line.strip())
      result.longestScanGapSec = max(result.longestScanGapSec, parseFloat(f[1]))
    of "seen":
      if f.len == 5 and f[3] != "-": seenIn.incl(f[3] & " " & f[4])
    else: discard
  result.incarnations = created.len
  for c in created:
    if c notin seenIn: inc result.withoutValidator

const MonitorScript* = """
import ctypes, os, struct, sys, time
# The validator client's processes (an executable named `validator` under
# the store) and the cgroups of the validator units named in argv[2:], in
# the kernel's order (one inotify descriptor); see validator_safety.nim.
tck = os.sysconf('SC_CLK_TCK')
log = open(sys.argv[1], 'a', buffering=1)
units = set(sys.argv[2:])
SLICE = '/sys/fs/cgroup/system.slice'
IN_CREATE, IN_DELETE, IN_Q_OVERFLOW = 0x100, 0x200, 0x4000
libc = ctypes.CDLL(None, use_errno=True)
ifd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
if ifd < 0 or libc.inotify_add_watch(ifd, SLICE.encode(), IN_CREATE | IN_DELETE) < 0:
    raise OSError(ctypes.get_errno(), 'inotify on ' + SLICE)
alive = {}
dbs = set()
def now():
    return time.clock_gettime(time.CLOCK_BOOTTIME)
def created(u):
    try:
        log.write('cg %s create %d\n' % (u, os.stat(SLICE + '/' + u).st_ino))
    except OSError:
        pass   # already removed again: its delete follows in the queue
def drain():
    while True:
        try:
            buf = os.read(ifd, 65536)
        except BlockingIOError:
            return
        i = 0
        while i < len(buf):
            wd, mask, cookie, ln = struct.unpack_from('iIII', buf, i)
            name = buf[i + 16:i + 16 + ln].split(b'\0', 1)[0].decode()
            i += 16 + ln
            if wd == -1 and mask & IN_Q_OVERFLOW:
                # The kernel dropped events: say so, the check fails closed.
                log.write('cg overflow\n')
                continue
            if name in units:
                if mask & IN_CREATE:
                    created(name)
                elif mask & IN_DELETE:
                    log.write('cg %s delete\n' % name)
for u in sorted(units):
    if os.path.isdir(SLICE + '/' + u):
        created(u)
def start_of(p):
    st = open('/proc/%s/stat' % p).read()
    return int(st[st.rindex(')') + 2:].split()[19]) / tck
last_scan = None
max_gap = 0.0
while True:
    drain()
    t0 = now()
    if last_scan is not None and t0 - last_scan > max_gap:
        # The longest gap between two scans: an instance that lived less
        # than it may go unseen (validator_safety.nim, MaxScanGapSec).
        max_gap = t0 - last_scan
        log.write('scan %.6f\n' % max_gap)
    last_scan = t0
    seen = set()
    pending = []
    for p in os.listdir('/proc'):
        if not p.isdigit():
            continue
        try:
            exe = os.readlink('/proc/%s/exe' % p)
        except OSError:
            continue
        if not (exe.startswith('/repro/store/') and exe.endswith('/bin/validator')):
            continue
        try:
            start = start_of(p)
        except OSError:
            continue
        key = (p, start)
        seen.add(key)
        if key not in alive:
            unit, ino = '-', '-'
            try:
                for line in open('/proc/%s/cgroup' % p):
                    path = line.strip().split(':', 2)[2]
                    if path.startswith('/system.slice/') and path[14:] in units:
                        unit = path[14:]
                ino = '-'
                if unit != '-':
                    ino = str(os.stat(SLICE + '/' + unit).st_ino)
                    # Alive after the stat: it is in that incarnation (one
                    # removed before the stat held no process).
                    if start_of(p) != start:
                        raise OSError('gone')
            except (OSError, IndexError):
                seen.discard(key)
                continue
            pending.append('seen %s %.3f %s %s\n' % (p, start, unit, ino))
        alive[key] = t0
        if key not in dbs:
            # The slashing-protection database it holds open, once it has.
            try:
                for fd in os.listdir('/proc/%s/fd' % p):
                    t = os.readlink('/proc/%s/fd/%s' % (p, fd))
                    if t.endswith('/validator.db'):
                        st2 = os.stat(t)
                        pending.append('db %s %d:%d %s\n' % (p, st2.st_dev, st2.st_ino, t))
                        dbs.add(key)
                        break
            except OSError:
                pass
    # The creations a seen process's cgroup may come from are logged first.
    drain()
    for line in pending:
        log.write(line)
    t1 = now()
    for key in list(alive):
        if key not in seen:
            log.write('gone %s %.3f %.3f\n' % (key[0], alive[key], t1))
            del alive[key]
    time.sleep(0.005)
"""

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
##    the guest that polls `/proc` (no unit, no hook in the client): it
##    records each process's start time from `/proc/<pid>/stat` (field 22,
##    clock ticks since boot) and, when it disappears, the last time it was
##    seen alive and the first time it was seen gone (both
##    `CLOCK_BOOTTIME`). A successor overlaps its predecessor when it
##    started before the predecessor was seen gone: an instance that
##    started inside the polling window is counted as overlapping, never
##    as clean, so the coarse clock can only make the check stricter. It
##    also records, once per instance, the slashing-protection database it
##    holds open (`db <pid> <device>:<inode> <path>`).

import std/[json, strutils, tables]

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
    if f[0] == "db":
      continue          # the database an instance holds (`databasesHeld`)
    if f[0] == "seen" and f.len == 3:
      open[f[1]] = result.len
      result.add(Instance(pid: f[1], start: parseFloat(f[2]), lastSeen: -1,
                          goneAt: -1))
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

const MonitorScript* = """
import os, sys, time
# The validator client's processes: an executable named `validator` under
# the store. Polls /proc every 5 ms; see validator_safety.nim.
tck = os.sysconf('SC_CLK_TCK')
log = open(sys.argv[1], 'a', buffering=1)
alive = {}
dbs = set()
def now():
    return time.clock_gettime(time.CLOCK_BOOTTIME)
while True:
    t0 = now()
    seen = set()
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
            st = open('/proc/%s/stat' % p).read()
        except OSError:
            continue
        start = int(st[st.rindex(')') + 2:].split()[19]) / tck
        key = (p, start)
        seen.add(key)
        if key not in alive:
            log.write('seen %s %.3f\n' % (p, start))
        alive[key] = t0
        if key not in dbs:
            # The slashing-protection database it holds open, once it has.
            try:
                for fd in os.listdir('/proc/%s/fd' % p):
                    t = os.readlink('/proc/%s/fd/%s' % (p, fd))
                    if t.endswith('/validator.db'):
                        st2 = os.stat(t)
                        log.write('db %s %d:%d %s\n' % (p, st2.st_dev, st2.st_ino, t))
                        dbs.add(key)
                        break
            except OSError:
                pass
    t1 = now()
    for key in list(alive):
        if key not in seen:
            log.write('gone %s %.3f %.3f\n' % (key[0], alive[key], t1))
            del alive[key]
    time.sleep(0.005)
"""

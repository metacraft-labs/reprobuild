## Shipping the add-on's evidence off the host (spec §10.4; DET-5, DET-6,
## EVID-2; threat model G22, G34).
##
##   repro system addon evidence-ship
##       (``repro-addon-evidence.service``, started by its path unit the
##       moment a record lands in the outbox and by its timer.) Appends every
##       outbox entry to the Evidence sink, oldest first, then this unit's
##       own heartbeat; deletes each entry the sink acknowledged. Turns the
##       apt hook WRAPPER's own events (``verify-missing``, ``verify-failed``,
##       ``verify-timeout``: the shell around the verification, which cannot
##       write a record itself) into DET-AO-6 records first.
##   repro system addon evidence-credential-check
##       The host's own test of its sink credential (G34): an append must be
##       acknowledged, and a list, a read, an overwrite and a delete must each
##       go unanswered. Exit 0 only then.
##
## THE SINK is reprobuild's ``repro-evidence-sink`` (``repro_peer_cache/
## evidence``): append-only by vocabulary, tamper-evident by hash chain and
## signed checkpoints, and it stamps the sender's host id from the verified
## TLS credential, so a host cannot file records under another's name. The
## host's WRITE CREDENTIAL is a host CA of its own (``EvidenceStateDir``),
## generated at bootstrap; the sink accepts appends from the hosts whose CA
## is in its anchor directory -- per host, revocable one by one.
##
## WHAT THE HEARTBEAT SAYS (DET-5). Every run whose last heartbeat is older
## than half the interval sends one: the interval, the boot id (so the
## off-host check can require a re-assert record per boot), the number of
## entries still queued, and when dpkg last ran (so it can require an apt
## hook record after each dpkg run). Silence of this heartbeat is "the host
## stopped shipping", distinct from a heartbeat with nothing detected.
##
## A sink that is unreachable or does not know this host yet is not a unit
## failure: the entries stay queued, the run says so on stderr (the journal)
## and exits 0; the sink side sees the heartbeat stop. A configuration that
## cannot be read exits 2.

import std/[asyncdispatch, os, strutils, times]

import repro_core/file_lock
import repro_peer_cache/evidence as sinkEvidence
import repro_peer_cache/identity
import repro_peer_cache/pki
import repro_peer_cache/types

import ./apt_hook
import ./evidence
import ./generation0
import ./mutations

type
  EvidenceConf* = object
    sinkEndpoint*: string     ## ``address:port``
    sinkHost*: string         ## the sink's host id, 64 hex
    heartbeatSec*: int
    tickSec*: int             ## 0: no deploy agent on this host

  ShipSite* = object
    ## Every path the shipping unit reads or writes; ``defaultShipSite`` is
    ## the host's, tests point it into a scratch directory.
    confPath*: string
    sinkCaPath*: string
    credentialCert*: string
    credentialKey*: string
    stateDir*: string         ## cursor, receipt, last heartbeat
    outbox*: string
    aptHookLog*: string
    dpkgLog*: string
    bootIdPath*: string

  ShipResult* = object
    shipped*: int             ## outbox entries the sink acknowledged
    pending*: int             ## entries still queued
    heartbeat*: bool          ## a heartbeat was sent and acknowledged
    hookEvents*: int          ## wrapper events turned into records
    error*: string            ## why something stayed queued ("" if nothing)

  CredentialCheck* = object
    appended*: bool
    answered*: seq[(ForbiddenOperation, bool)]
      ## true: the sink ANSWERED the operation (the credential can do more
      ## than append)
    error*: string

  EvidenceConfError* = object of CatchableError

const
  ShipDrainTimeoutMs = ShipDrainTimeoutSec * 1000
  ShipDelayAlertMs* = 60_000'i64
    ## A record that waited longer than this to leave is a stall the
    ## off-host check alerts on (DET-AO-8 ``shipping-stalled``).
  HookWrapperKinds* = ["verify-missing", "verify-failed", "verify-timeout"]

proc defaultShipSite*(): ShipSite =
  ShipSite(confPath: EvidenceConfPath, sinkCaPath: EvidenceSinkCaPath,
    credentialCert: EvidenceCredentialCertPath,
    credentialKey: EvidenceCredentialKeyPath, stateDir: EvidenceStateDir,
    outbox: EvidenceOutboxPath, aptHookLog: AptHookLogPath,
    dpkgLog: "/var/log/dpkg.log",
    bootIdPath: "/proc/sys/kernel/random/boot_id")

proc parseEvidenceConf*(text: string): EvidenceConf =
  ## ``key = value`` lines (``generation0.renderEvidenceConf``).
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(EvidenceConfError, "not key = value: " & line)
    let (k, v) = (line[0 ..< eq].strip(), line[eq + 1 .. ^1].strip())
    try:
      case k
      of "sink": result.sinkEndpoint = v
      of "sink-host": result.sinkHost = v.toLowerAscii()
      of "heartbeat-interval": result.heartbeatSec = parseInt(v)
      of "tick-interval": result.tickSec = parseInt(v)
      else: discard
    except ValueError:
      raise newException(EvidenceConfError, "malformed " & k & ": " & v)
  if result.sinkEndpoint.len == 0:
    raise newException(EvidenceConfError, "no sink")
  if result.sinkHost.len != 64 or not result.sinkHost.allCharsInSet(HexDigits):
    raise newException(EvidenceConfError, "sink-host is not a 64-hex host id")
  if result.heartbeatSec <= 0:
    result.heartbeatSec = DefaultEvidenceHeartbeatSec

proc loadEvidenceConf*(path = EvidenceConfPath): EvidenceConf =
  try: parseEvidenceConf(readFile(path))
  except IOError, OSError:
    raise newException(EvidenceConfError, "cannot read " & path)

proc peerIdOfHex*(hex: string): PeerId =
  var raw: array[32, byte]
  if hex.len != 64 or not hex.allCharsInSet(HexDigits):
    raise newException(ValueError, "not a 64-hex host id: " & hex)
  for i in 0 ..< 32: raw[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
  peerIdFromBytes(raw)

proc openAppender*(site: ShipSite; conf: EvidenceConf): EvidenceAppender =
  ## The appender, with this host's credential and the sink's CA alone. The
  ## credential is never created here: bootstrap made it, and a missing one
  ## is an error, not a reason to mint a new identity the sink does not
  ## know.
  if not (fileExists(site.credentialCert) and fileExists(site.credentialKey)):
    raise newException(EvidenceConfError, "no sink write credential at " &
      site.credentialCert)
  let identity = loadOrCreateHostIdentity(site.credentialCert,
                                          site.credentialKey)
  var leaf = mintLeaf(identity, lrDaemon)
  let provider = proc(): LeafCredential {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      if leaf.needsRenewal: leaf = mintLeaf(identity, lrDaemon)
      leaf
  result = newEvidenceAppender(parseSinkEndpoint(conf.sinkEndpoint), provider,
    loadTrustAnchorFile(site.sinkCaPath),
    expectedSink = peerIdOfHex(conf.sinkHost))
  result.receiptPath = site.stateDir / "receipt"

proc bootId*(site: ShipSite): string =
  try: readFile(site.bootIdPath).strip() except IOError, OSError: ""

proc lastShipMs(site: ShipSite): int64 =
  try: parseBiggestInt(readFile(site.stateDir / "last-ship").strip())
  except CatchableError: 0'i64

proc lastHeartbeatMs(site: ShipSite): int64 =
  try: parseBiggestInt(readFile(site.stateDir / "last-heartbeat").strip())
  except CatchableError: 0'i64

proc writeOutboxRecord*(outbox: string; r: EvidenceRecord; kind: string) =
  ## An entry the shipping unit itself writes (it holds no attestation key,
  ## so these are unattested): the hook wrapper's events.
  createDir(outbox)
  let t = getTime()
  let ns = t.toUnix() * 1_000_000_000 + int64(t.nanosecond)
  let name = align($ns, 20, '0') & "-" & $getCurrentProcessId() & "-" &
             kind & ".evr"
  writeOutboxEntry(outbox, name, cast[string](encodeEvidenceRecord(redact(r))))

proc harvestHookWrapperEvents*(site: ShipSite; host: string): int =
  ## The apt hook wrapper's ``verify-*`` lines since the last run, each as a
  ## DET-AO-6 record in the outbox (persisted before the cursor moves on,
  ## so a run that cannot reach the sink loses none of them).
  for line in hookEventsSince(site.stateDir / "apt-hook.cursor",
                              site.aptHookLog):
    let parts = line.splitWhitespace()
    if parts.len < 2 or parts[1] notin HookWrapperKinds: continue
    var r = newEvidenceRecord(ecDetection, $edAptHook, parts[1],
      [("kind", parts[1]), ("message", line), ("host", host)],
      nowMs = int64(epochTime() * 1000))
    r.senderPid = int32(getCurrentProcessId())
    writeOutboxRecord(site.outbox, r, parts[1])
    inc result

const
  StaleOutboxMs* = 60_000'i64
    ## A file in the outbox that is not an entry (a torn ``.tmp`` of a
    ## writer that died, anything else) is removed after this long and
    ## reported: the path unit's ``DirectoryNotEmpty=`` would otherwise start
    ## the shipping unit for it again and again.
  ShipPassesMax* = ShipPassesMaxN
    ## Re-listings of the outbox one run makes, so records that land while
    ## it ships leave with it (A11 drill D1); bounded against a writer that
    ## never stops.

proc clearStaleOutbox(site: ShipSite; host: string): int =
  ## Remove stale non-entries, writing a record for each.
  if not dirExists(site.outbox): return
  let now = getTime()
  for kind, p in walkDir(site.outbox):
    if kind == pcFile and p.endsWith(".evr"): continue
    try:
      if (now - getLastModificationTime(p)).inMilliseconds < StaleOutboxMs:
        continue
      if kind == pcDir: removeDir(p) else: removeFile(p)
      var r = newEvidenceRecord(ecDetection, $edShip, "outbox-entry-unreadable",
        [("path", p), ("reason", "not an outbox entry; removed"),
         ("host", host)], nowMs = int64(epochTime() * 1000))
      r.senderPid = int32(getCurrentProcessId())
      writeOutboxRecord(site.outbox, r, "outbox-stale")
      inc result
    except CatchableError:
      discard

proc runEvidenceShipOnce(site: ShipSite; conf: EvidenceConf; host: string;
                         forceHeartbeat: bool): ShipResult

proc shipLockPath*(site: ShipSite): string =
  ## Held for a whole shipping run: one run ships at a time.
  site.stateDir / "ship.lock"

proc runEvidenceShip*(site: ShipSite; conf: EvidenceConf; host: string;
                      forceHeartbeat = false;
                      onPass: proc () = nil;
                      lockWaitMs = ShipLockWaitSec * 1000): ShipResult =
  ## One shipping run (see the module documentation): the outbox is listed
  ## again after each pass, so a record that lands while the run ships goes
  ## with it. Never raises for an unreachable sink; raises
  ## ``EvidenceConfError`` for a broken credential or configuration.
  ##
  ## Runs are serialised by ``shipLockPath``: the shipping unit (started by
  ## the path unit as records land) and ``contain``/``release`` (which ship
  ## their record at once) would otherwise both read an entry before either
  ## deleted it, and the sink would hold the record twice. A run that cannot
  ## take the lock within ``lockWaitMs`` ships nothing and says so; the
  ## holder lists the outbox again after each pass.
  createDir(site.stateDir)
  var lock: ReproFileLock
  when not mutated("ship-runs-concurrently"):
    try:
      lock = acquireExclusiveLockWithin(shipLockPath(site), lockWaitMs)
    except IOError as e:
      result.pending = outboxEntries(site.outbox).len
      result.error = "another shipping run holds " & shipLockPath(site) &
        ": " & e.msg
      return
  defer: releaseExclusiveFileLock(lock)
  discard clearStaleOutbox(site, host)
  result = runEvidenceShipOnce(site, conf, host, forceHeartbeat)
  when mutated("evidence-path-changed-only"):
    # FALSIFYING BUILD: one listing per run, as before D1.
    if onPass != nil: onPass()
    return
  var passes = 1
  if onPass != nil: onPass()      # a test's writer, between two passes
  while result.error.len == 0 and passes < ShipPassesMax and
      outboxEntries(site.outbox).len > 0:
    let more = runEvidenceShipOnce(site, conf, host, false)
    result.shipped += more.shipped
    result.pending = more.pending
    result.heartbeat = result.heartbeat or more.heartbeat
    result.error = more.error
    inc passes

proc runEvidenceShipOnce(site: ShipSite; conf: EvidenceConf; host: string;
                         forceHeartbeat: bool): ShipResult =
  createDir(site.stateDir)
  result.hookEvents = harvestHookWrapperEvents(site, host)
  let entries = outboxEntries(site.outbox)
  var records: seq[EvidenceRecord]
  var shippable: seq[string]
  for p in entries:
    try:
      records.add(decodeEvidenceRecord(cast[seq[byte]](readFile(p))))
      shippable.add(p)
    except CatchableError as e:
      # A torn or foreign entry: report it in place of its bytes, then drop
      # it so it cannot block the queue.
      var r = newEvidenceRecord(ecDetection, $edShip, "outbox-entry-unreadable",
        [("path", p), ("reason", e.msg), ("host", host)],
        nowMs = int64(epochTime() * 1000))
      records.add(r)
      shippable.add(p)
  let now = int64(epochTime() * 1000)
  # How long the oldest record waited to leave (its writer's clock against
  # this run's): a path unit that stopped starting this unit shows up here,
  # since records then wait for the timer (A11 audit F2). A delay past
  # ``ShipDelayAlertMs`` always heartbeats, so the sink hears of it.
  # Counted from the later of the record's writing and this host's last
  # successful shipment: records queued while the sink was unreachable, or
  # before it knew the host at all, are not a stall of the path unit; the
  # first shipment ever has none.
  var delayMs = 0'i64
  let lastOk = lastShipMs(site)
  if lastOk > 0:
    for r in records:
      if r.senderTimeMs > 0:
        delayMs = max(delayMs, now - max(r.senderTimeMs, lastOk))
  let beat = forceHeartbeat or delayMs > ShipDelayAlertMs or
             now - lastHeartbeatMs(site) >= int64(conf.heartbeatSec) * 500
  if records.len == 0 and not beat:
    return
  let a = openAppender(site, conf)
  defer: a.close()
  for r in records: a.append(r)
  when mutated("ship-deletes-before-ack"):
    # FALSIFYING BUILD: the queue is emptied as soon as the records are
    # handed to the appender, acknowledged or not.
    for p in shippable:
      try: removeFile(p) except OSError: discard
  if beat:
    a.append(newEvidenceRecord(ecHeartbeat, $edShip, "",
      [("intervalMs", $(conf.heartbeatSec * 1000)), ("bootId", bootId(site)),
       ("pending", $records.len), ("dpkgLastRun", dpkgLastRun(site.dpkgLog)),
       ("shipDelayMs", $delayMs),
       ("host", host)], nowMs = now))
  discard a.drain(ShipDrainTimeoutMs)
  # The sink acknowledges in queue order: the first ``appended`` records are
  # on the sink. Only those entries are deleted.
  let acked = min(a.appended, shippable.len)
  for i in 0 ..< acked:
    try: removeFile(shippable[i]) except OSError: discard
  result.shipped = acked
  result.pending = shippable.len - acked
  result.heartbeat = beat and a.appended == records.len + 1
  if result.heartbeat:
    writeFile(site.stateDir / "last-heartbeat", $now & "\n")
  if a.appended > 0 and a.appended == records.len + (if beat: 1 else: 0):
    writeFile(site.stateDir / "last-ship", $now & "\n")
  if a.appended < records.len + (if beat: 1 else: 0):
    result.error = (if a.lastError.len > 0: a.lastError
                    else: "the sink did not acknowledge every record")

proc runCredentialCheck*(site: ShipSite; conf: EvidenceConf;
                         host: string): CredentialCheck =
  ## G34's test from the host: append one probe record, then attempt each
  ## forbidden operation with the same credential.
  let a = openAppender(site, conf)
  defer: a.close()
  a.append(newEvidenceRecord(ecAudit, $edShip, "credential-probe",
    [("host", host)], nowMs = int64(epochTime() * 1000)))
  discard a.drain(ShipDrainTimeoutMs)
  result.appended = a.appended == 1
  if not result.appended: result.error = a.lastError
  # Stop the appender before the probes: a drain that timed out leaves a
  # flush in flight, which must neither reconnect nor share anything with
  # them (each probe opens a connection of its own).
  a.close()
  for op in ForbiddenOperation:
    let answered = try: waitFor a.probeForbiddenOperation(op)
                   except CatchableError: false
    result.answered.add((op, answered))

proc credentialCheckOk*(c: CredentialCheck): bool =
  if not c.appended: return false
  for (_, answered) in c.answered:
    if answered: return false
  true

proc readHost(): string =
  try: readFile("/proc/sys/kernel/hostname").strip()
  except IOError, OSError: "localhost"

proc outboxBusy(outbox: string): bool =
  ## Anything in the outbox (the path unit's ``DirectoryNotEmpty=`` sees it).
  if not dirExists(outbox): return false
  for kind, p in walkDir(outbox): return true
  false

proc shipBackoffSec*(failures, heartbeatSec: int): int =
  ## The wait before a run that left the outbox non-empty exits: doubling
  ## with each consecutive such run from 5 s, at most the heartbeat
  ## interval (and ``ShipBackoffMaxSec``, below the unit's start timeout). Bounds how often the path unit restarts the unit
  ## whatever kept the outbox non-empty (A11 review finding 11).
  let cap = when mutated("ship-backoff-reaches-timeout"):
              min(300, max(5, heartbeatSec))
            else: min(ShipBackoffMaxSec, max(5, heartbeatSec))
  var w = 5
  for i in 0 ..< min(failures, 10): w = min(cap, w * 2)
  min(cap, w)

proc shipRunWait*(site: ShipSite; heartbeatSec: int): int =
  ## The seconds a run waits before it exits: ``shipBackoffSec`` of the runs
  ## in a row that left the outbox non-empty (counted in the unit's state,
  ## ``ship-failures``), 0 once it is empty (the count is cleared). Every
  ## run ends with it, whatever kept the outbox non-empty -- a sink that is
  ## down, a credential that is broken, an entry that will not go -- so the
  ## path unit's ``DirectoryNotEmpty=`` restarts it at a bounded pace (A11
  ## review finding 11).
  let failuresPath = site.stateDir / "ship-failures"
  var failures = 0
  try: failures = parseInt(readFile(failuresPath).strip())
  except CatchableError: discard
  when mutated("ship-no-backoff"):
    return 0
  if outboxBusy(site.outbox):
    inc failures
    try:
      createDir(site.stateDir)
      writeFile(failuresPath, $failures & "\n")
    except CatchableError: discard
    shipBackoffSec(failures - 1, heartbeatSec)
  else:
    if failures > 0:
      try: removeFile(failuresPath) except CatchableError: discard
    0

proc runEvidenceShipCli*(args: seq[string]): int =
  var force = false
  for a in args:
    if a == "--heartbeat": force = true
    else:
      stderr.write("usage: repro system addon evidence-ship [--heartbeat]\n")
      return 2
  let site = defaultShipSite()
  var heartbeat = DefaultEvidenceHeartbeatSec
  var broken = ""
  result = 0
  try:
    let conf = loadEvidenceConf(site.confPath)
    heartbeat = conf.heartbeatSec
    let r = runEvidenceShip(site, conf, readHost(), force)
    stdout.write("evidence: shipped " & $r.shipped & ", queued " & $r.pending &
      (if r.heartbeat: ", heartbeat sent" else: "") &
      (if r.hookEvents > 0: ", " & $r.hookEvents & " apt hook event(s)" else: "") &
      "\n")
    if r.error.len > 0:
      stderr.write("repro-addon evidence: the sink at " & conf.sinkEndpoint &
        " did not take every record (they stay queued): " & r.error & "\n")
  except CatchableError as e:
    broken = e.msg
    stderr.write("repro system addon evidence-ship: " & e.msg & "\n")
    result = 2
  if broken.len > 0:
    # A credential or configuration that cannot be used: a local detection
    # record (the sink will see the heartbeat stop), once per distinct
    # error, not once per restart.
    let lastPath = site.stateDir / "ship-broken"
    let last = try: readFile(lastPath).strip() except CatchableError: ""
    if last != broken:
      try:
        createDir(site.stateDir)
        writeFile(lastPath, broken & "\n")
        discard recordEvidence(EvidenceEvent(detector: edShip,
          category: ecDetection, trigger: "evidence-ship-broken",
          kind: "evidence-ship-broken", fields: @[("message", broken)]),
          defaultSite())
      except CatchableError: discard
  sleep(1000 * shipRunWait(site, heartbeat))

proc runCredentialCheckCli*(args: seq[string]): int =
  if args.len != 0:
    stderr.write("usage: repro system addon evidence-credential-check\n")
    return 2
  let site = defaultShipSite()
  try:
    let conf = loadEvidenceConf(site.confPath)
    let c = runCredentialCheck(site, conf, readHost())
    stdout.write("append: " & (if c.appended: "acknowledged" else:
      "NOT acknowledged (" & c.error & ")") & "\n")
    for (op, answered) in c.answered:
      stdout.write($op & ": " & (if answered: "ANSWERED (the credential " &
        "can " & $op & " the sink)" else: "refused") & "\n")
    if credentialCheckOk(c): 0 else: 1
  except CatchableError as e:
    stderr.write("repro system addon evidence-credential-check: " & e.msg & "\n")
    2

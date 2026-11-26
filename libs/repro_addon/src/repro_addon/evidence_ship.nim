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

import std/[asyncdispatch, json, os, posix, strutils, sysrand, times]

import repro_core/file_lock
import repro_peer_cache/evidence as sinkEvidence
import repro_peer_cache/identity
import repro_peer_cache/pki
import repro_peer_cache/types

import ./apt_hook
import ./evidence
import ./generation0
import ./host_exec
import ./record_dir
import ./ledger
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
    harvestStateDir*: string  ## the apt hook cursor's directory ("": stateDir)
    legacyOutbox*: string
      ## Where the outbox was before §13 decision 181 (``LegacyOutboxPath``),
      ## emptied into ``outbox`` by the privileged harvest; "" where nothing
      ## may read it.
    legacyStateDir*: string
      ## Where ``LegacyShipStateNames`` were before decision 181
      ## (``EvidenceStateDir``); "" as for ``legacyOutbox``.
    dropDir*: string
      ## The egress check's root drop directory (§13 decision 188), emptied
      ## into the outbox by the privileged harvest; "" where nothing may
      ## read it (the dynamic user's own view).
    confined*: bool
      ## The host's site as root sees it: a shipping run or credential
      ## check for it runs in the shipping unit's confinement, as its
      ## dynamic user (``runConfined``; §13 decision 181), never in the
      ## calling root process. Test sites are run in process.

  ShipResult* = object
    shipped*: int             ## outbox entries the sink acknowledged
    pending*: int             ## entries still queued
    heartbeat*: bool          ## a heartbeat was sent and acknowledged
    hookEvents*: int          ## wrapper events turned into records
    error*: string            ## why something stayed queued ("" if nothing)

  CredentialCheck* = object
    appended*: bool
    answered*: seq[(ForbiddenOperation, ProbeOutcome)]
      ## Per forbidden operation: answered (the credential can do more than
      ## append), refused (the sink recorded the refusal and said so), or
      ## undelivered (the attempt tells nothing; A11 review round 3)
    probeErrors*: seq[string]
      ## Why an undelivered attempt was not delivered.
    error*: string

  EvidenceConfError* = object of CatchableError

const
  ShipDrainTimeoutMs = ShipDrainTimeoutSec * 1000
  ShipDelayAlertMs* = 60_000'i64
    ## A record that waited longer than this to leave is a stall the
    ## off-host check alerts on (DET-AO-8 ``shipping-stalled``).
  HookWrapperKinds* = ["verify-missing", "verify-failed", "verify-timeout"]

proc defaultShipSite*(): ShipSite =
  ## The host's site as a root caller sees it (``confined``).
  ShipSite(confPath: EvidenceConfPath, sinkCaPath: EvidenceSinkCaPath,
    credentialCert: EvidenceCredentialCertPath,
    credentialKey: EvidenceCredentialKeyPath, stateDir: EvidenceShipStateDir,
    harvestStateDir: EvidenceStateDir, confined: true,
    outbox: EvidenceOutboxPath, aptHookLog: AptHookLogPath,
    dpkgLog: "/var/log/dpkg.log", dropDir: EgressDropDir,
    legacyOutbox: LegacyOutboxPath, legacyStateDir: EvidenceStateDir,
    bootIdPath: "/proc/sys/kernel/random/boot_id")

proc unitShipSite*(): ShipSite =
  ## The host's site as the shipping unit and its transient runs see it:
  ## the credential from ``$CREDENTIALS_DIRECTORY`` (``LoadCredential=``),
  ## the dynamic user's state directory, and no apt hook log (its
  ## privileged ``ExecStartPre=+`` step, or the root caller, harvests it).
  let creds = getEnv("CREDENTIALS_DIRECTORY")
  result = defaultShipSite()
  result.confined = false
  result.credentialCert = creds / EvidenceCredentialNames[0]
  result.credentialKey = creds / EvidenceCredentialNames[1]
  result.stateDir = EvidenceShipUnitStateDir
  result.outbox = EvidenceShipUnitStateDir / "outbox"
  result.aptHookLog = ""
  result.harvestStateDir = ""
  result.dropDir = ""
  result.legacyOutbox = ""
  result.legacyStateDir = ""

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
  let t = getTime()
  let ns = t.toUnix() * 1_000_000_000 + int64(t.nanosecond)
  let name = align($ns, 20, '0') & "-" & $getCurrentProcessId() & "-" &
             kind & ".evr"
  writeOutboxEntry(outbox, name, cast[string](encodeEvidenceRecord(redact(r))))

proc harvestHookWrapperEvents*(site: ShipSite; host: string): int =
  ## The apt hook wrapper's ``verify-*`` lines since the last run, each as a
  ## DET-AO-6 record in the outbox (persisted before the cursor moves on,
  ## so a run that cannot reach the sink loses none of them).
  if site.aptHookLog.len == 0: return
  let cursorDir = if site.harvestStateDir.len > 0: site.harvestStateDir
                  else: site.stateDir
  createDir(cursorDir)
  for line in hookEventsSince(cursorDir / "apt-hook.cursor",
                              site.aptHookLog):
    let parts = line.splitWhitespace()
    if parts.len < 2 or parts[1] notin HookWrapperKinds: continue
    var r = newEvidenceRecord(ecDetection, $edAptHook, parts[1],
      [("kind", parts[1]), ("message", line), ("host", host)],
      nowMs = int64(epochTime() * 1000))
    r.senderPid = int32(getCurrentProcessId())
    writeOutboxRecord(site.outbox, r, parts[1])
    inc result

proc escapeControl*(s: string): string

const DropLeftName* = "drop-left"
  ## Under ``<shipping state>/harvest``: how many of the egress check's drop
  ## entries the last harvest could not move into the outbox. The shipping
  ## run counts them as queued for its backoff (``shipRunWait``), since it
  ## cannot see the root drop directory itself.

proc dropLeftPath*(stateDir: string): string = stateDir / "harvest" / DropLeftName

proc harvestDropEntries*(dropDir, outbox: string; stateDir = ""): DropHarvest =
  ## The egress check's entries in its root drop directory, each moved into
  ## the outbox (§13 decision 188): run as root, by the shipping unit's
  ## privileged first step and by a root caller before its confined run.
  ## ``takeDropEntries`` follows no link, takes regular files only, each
  ## under ``DropEntryMaxBytes``, and moves anything else aside unread. What
  ## was moved aside and what could not be moved is printed, every name
  ## escaped (it is a name the writer chose). With ``stateDir`` (the shipping
  ## unit's state as root sees it), the count left behind is written there
  ## for the shipping run's backoff (``dropLeftPath``).
  if dropDir.len == 0: return
  result = takeDropEntries(dropDir, DropEntryMaxBytes,
    take = proc (e: DropEntry) = writeOutboxEntry(outbox, e.name, e.bytes))
  for r in result.asideNames & result.left:
    stderr.write("repro-addon evidence: drop entry " & escapeControl(r) & "\n")
  if stateDir.len > 0:
    try:
      writeDelegatedEntry(stateDir / "harvest", DropLeftName,
                          $result.left.len & "\n", mode = 0o644)
    except CatchableError as e:
      stderr.write("repro-addon evidence: cannot record the drop entries " &
        "left: " & escapeControl(e.msg) & "\n")

proc dropLeft(stateDir: string): int =
  try: parseInt(readFile(dropLeftPath(stateDir)).strip())
  except CatchableError: 0

const LegacyLeftName* = "legacy-left"
  ## Under ``<shipping state>/harvest``: how much of the shipping state from
  ## before §13 decision 181 the privileged harvest has still to move
  ## (``moveLegacyShipState``). Written "1" before a move starts and the
  ## count left once it ends, so a move that stopped half way, by a failure
  ## or a crash, leaves it non-zero. While it is, a shipping run ships
  ## nothing: an entry the move handed over but could not yet remove would
  ## otherwise leave twice.

proc legacyLeftPath*(stateDir: string): string =
  stateDir / "harvest" / LegacyLeftName

proc legacyLeft*(stateDir: string): int =
  try: parseInt(readFile(legacyLeftPath(stateDir)).strip())
  except CatchableError: 0

type
  LegacyMove* = object
    ## What one ``moveLegacyShipState`` did.
    found*: bool             ## there was legacy state to move
    entries*: DropHarvest    ## the legacy outbox's entries
    stateMoved*: seq[string] ## state files carried over
    stateKept*: seq[string]  ## legacy state files dropped because the
                             ## dynamic user's state already has a newer one
    stateLeft*: seq[string]  ## state files that could not be moved, with why

proc hasLegacyShipState*(site: ShipSite): bool =
  ## Whether ``site`` names legacy state and any of it is there: the legacy
  ## outbox directory, or a ``LegacyShipStateNames`` file. Judged without
  ## following a link.
  if site.legacyOutbox.len > 0:
    var st: Stat
    if lstat(site.legacyOutbox.cstring, st) == 0: return true
  if site.legacyStateDir.len > 0:
    for n in LegacyShipStateNames:
      var st: Stat
      if lstat((site.legacyStateDir / n).cstring, st) == 0: return true
  false

proc moveLegacyShipState*(site: ShipSite): LegacyMove =
  ## The shipping state of a host an engine before §13 decision 181
  ## bootstrapped, moved into the dynamic user's state directory (the
  ## owner's decision of 2026-11-26, "migrate existing hosts"). Run as root
  ## by the privileged harvest, before any shipping run that follows it.
  ##
  ## - Every regular ``*.evr`` entry of the legacy outbox is handed into the
  ##   outbox under its own name and then removed (``takeDropEntries``: no
  ##   link followed, anything else moved aside unread into
  ##   ``outbox-rejected``). A move killed between the two leaves the entry
  ##   in both places, and the next run hands it over again under the same
  ##   name, replacing the copy: no entry is lost and none is queued twice.
  ## - Each ``LegacyShipStateNames`` file is carried over unless the dynamic
  ##   user's state already has that file -- the newer one, written by a
  ##   shipping run after a move that stopped between the copy and the
  ##   removal -- and then removed. The sink's receipt is the signed head of
  ##   what it holds, so the newer one is the one to keep.
  ## - ``legacyLeftPath`` is "1" while the move runs and the count left
  ##   afterwards; a shipping run ships nothing while it is non-zero.
  ##
  ## Serialised by a root lock in the legacy state directory, so two root
  ## callers never hand the same entry over twice. Nothing to do (no legacy
  ## state): returns at once and writes nothing.
  if not hasLegacyShipState(site): return
  result.found = true
  createDir(site.legacyStateDir)
  var lock = acquireExclusiveLockWithin(site.legacyStateDir / "legacy-move.lock",
                                        ShipLockWaitSec * 1000)
  defer: releaseExclusiveFileLock(lock)
  writeDelegatedEntry(site.stateDir / "harvest", LegacyLeftName, "1\n",
                      mode = 0o644)
  # The state files first: a receipt carried over before any entry moves
  # is the head the entries' shipping continues from.
  for n in LegacyShipStateNames:
    let src = site.legacyStateDir / n
    var st: Stat
    if lstat(src.cstring, st) != 0: continue
    if not S_ISREG(st.st_mode) or st.st_size > MaxRecordBytes:
      # Root's own directory: only root wrote there. Anything else is not
      # shipping state, and is left for the operator, reported.
      result.stateLeft.add(n & ": not a regular file of at most " &
        $MaxRecordBytes & " bytes; left in " & site.legacyStateDir)
      continue
    try:
      if delegatedStateFileExists(site.stateDir, n):
        result.stateKept.add(n)
      else:
        let bytes = readRecordFileNoFollow(src)
        writeDelegatedStateFile(site.stateDir, n, bytes)
        result.stateMoved.add(n)
      if crashPointHook != nil: crashPointHook("state-copied:" & n)
      if posix.unlink(src.cstring) != 0 and errno != ENOENT:
        raiseOSError(osLastError(), "remove " & src)
    except OSError, IOError, ValueError:
      result.stateLeft.add(n & ": " & getCurrentExceptionMsg())
  when mutated("legacy-move-skips-outbox"):
    discard
  else:
    result.entries = takeDropEntries(site.legacyOutbox, MaxRecordBytes,
      take = proc (e: DropEntry) = writeOutboxEntry(site.outbox, e.name, e.bytes))
  # The emptied legacy outbox goes; an engine unit not yet re-pointed that
  # writes a record makes it again, and the next harvest moves that too.
  if result.entries.left.len == 0:
    discard posix.rmdir(site.legacyOutbox.cstring)
  let left = result.entries.left.len + result.stateLeft.len
  writeDelegatedEntry(site.stateDir / "harvest", LegacyLeftName, $left & "\n",
                      mode = 0o644)

proc reportLegacyMove(m: LegacyMove) =
  ## The move on stdout (what moved) and stderr (what did not), every name
  ## escaped.
  if not m.found: return
  if m.entries.moved > 0 or m.stateMoved.len > 0:
    stdout.write("evidence: moved " & $m.entries.moved & " queued record(s)" &
      (if m.stateMoved.len > 0: " and " & m.stateMoved.join(", ") else: "") &
      " from before the shipping unit's own user (§13 decision 181)\n")
  for k in m.stateKept:
    stdout.write("evidence: kept the shipping state's newer " & k &
      "; removed the one from before decision 181\n")
  for r in m.entries.asideNames & m.entries.left & m.stateLeft:
    stderr.write("repro-addon evidence: legacy shipping state: " &
      escapeControl(r) & "\n")

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
  # The move of the shipping state from before §13 decision 181 has not
  # finished (``moveLegacyShipState``): an entry it handed over may still be
  # in the legacy outbox too, so nothing ships until the next harvest has
  # finished it (the owner's decision of 2026-11-26).
  when not mutated("legacy-ship-ungated"):
    if legacyLeft(site.stateDir) > 0:
      result.pending = outboxEntries(site.outbox).len
      result.error = "the shipping state from before the shipping unit's " &
        "own user has not been moved yet (" & legacyLeftPath(site.stateDir) &
        "); nothing ships until the privileged harvest has moved it"
      return
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
    let outcome = try: waitFor a.probeForbiddenOperation(op)
                  except CatchableError: poUndelivered
    if outcome == poUndelivered: result.probeErrors.add($op & ": " & a.lastError)
    result.answered.add((op, outcome))

proc credentialCheckOk*(c: CredentialCheck): bool =
  if not c.appended: return false
  ## Only when the sink took the probe record and confirmed the refusal of
  ## every forbidden operation: an operation it never received tells
  ## nothing about the credential, and fails the self-test.
  if c.answered.len != ForbiddenOperation.high.ord + 1: return false
  for (_, outcome) in c.answered:
    if outcome != poRefused: return false
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
  # Drop entries the privileged harvest could not move count as queued
  # too (A11 round 26): the path unit's DirectoryNotEmpty= on the drop
  # directory would otherwise restart the unit at once, for ever.
  let dropBusy = when mutated("ship-backoff-ignores-drop"): false
                 else: dropLeft(site.stateDir) > 0
  let legacyBusy = legacyLeft(site.stateDir) > 0
  if outboxBusy(site.outbox) or dropBusy or legacyBusy:
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

# ---------------------------------------------------------------------------
# The confined runs (§13 decision 181). Every decoder of the sink's bytes --
# the shipping run, the credential self-test -- runs as the shipping unit's
# dynamic user, in its sandbox. A root caller (``contain``, ``release``,
# uninstall, an operator's ``evidence-credential-check``) starts a
# transient unit with exactly the shipping unit's confinement
# (``evidenceShipConfinement``), waits for it, and then takes from the
# outbox only what names it holds: never an entry's bytes.
# ---------------------------------------------------------------------------

const SystemdRunCandidates* = ["/usr/bin/systemd-run", "/bin/systemd-run"]
const ConfinedExeCopyDir* = "/var/lib/repro-addon-evidence-run"
  ## Where a confined run's copy of a binary outside the store lives:
  ## root's, 0755, each run in a directory of its own
  ## (``<dir>/run-<pid>-<random>/repro``), made just before the run and
  ## removed just after it, so two runs at once never share or remove each
  ## other's copy. Not in /run (mounted ``noexec``) and not in the dynamic
  ## user's state directory (systemd refuses to execute from it: measured
  ## on debian-13, "Permission denied" at EXEC). In practice only an
  ## uninstall re-run whose store is already gone needs it. Uninstall
  ## removes the directory with the shipping unit's state.

proc escapeControl*(s: string): string =
  ## ``s`` with every byte that is not printable ASCII, a newline or a tab
  ## written as ``\xNN`` (and ``\`` as ``\\``): text a confined run
  ## printed after decoding the sink's bytes, before root prints it, so a
  ## hostile sink cannot reach the operator's terminal with escape
  ## sequences.
  const hexd = "0123456789abcdef"
  when mutated("confined-output-unescaped"):
    return s
  for c in s:
    let b = ord(c)
    if c == '\\': result.add("\\\\")
    elif c in {'\n', '\t'} or (b >= 0x20 and b < 0x7f): result.add(c)
    else:
      result.add("\\x")
      result.add(hexd[b shr 4])
      result.add(hexd[b and 15])

proc sinkAddressOf*(endpoint: string): string =
  ## The address part of ``address:port`` (IPv6 without its brackets).
  let colon = endpoint.rfind(':')
  result = if colon > 0: endpoint[0 ..< colon] else: endpoint
  if result.startsWith("[") and result.endsWith("]"):
    result = result[1 .. ^2]

proc confinedReproExe*(unitFile = unitPath(EvidenceShipUnit);
                       bootstrapRecord = "/var/lib/repro/system/addon/" &
                         "bootstrap-evidence.json";
                       self = getAppFilename()): string =
  ## The add-on's own binary, which a confined run executes as the dynamic
  ## user: this process's when it is in the store; otherwise the one the
  ## installed shipping unit names, or, once uninstall removed the units,
  ## the one bootstrap recorded (an operator may run ``repro`` from a path
  ## the sandbox hides, ``/root`` say); otherwise this process's.
  if self.startsWith(StoreRoot & "/") and fileExists(self): return self
  try:
    for l in readFile(unitFile).splitLines():
      if l.startsWith("ExecStart="):
        let exe = l["ExecStart=".len .. ^1].splitWhitespace()[0]
        if exe.startsWith(StoreRoot & "/") and fileExists(exe): return exe
  except CatchableError: discard
  try:
    let exe = parseJson(readFile(bootstrapRecord)){"reproExe"}.getStr()
    if exe.startsWith(StoreRoot & "/") and fileExists(exe): return exe
  except CatchableError: discard
  self

proc confinedRunArgv*(conf: EvidenceConf; command: openArray[string];
                      reproExe = confinedReproExe(); systemdRun = "";
                      exeCopy = ConfinedExeCopyDir / "run" / "repro"): seq[string] =
  ## ``systemd-run`` for one confined run of ``repro system addon
  ## <command>``: waits for it, passes its output through, and gives it
  ## every line of the shipping unit's confinement.
  let tool = if systemdRun.len > 0: systemdRun
             else: resolveHostTool(SystemdRunCandidates)
  if tool.len == 0:
    raise newException(EvidenceConfError, "systemd-run not found at " &
      SystemdRunCandidates.join(" or ") & "; the sink is reached only from " &
      "the shipping unit's confinement")
  result = @[tool, "--wait", "--pipe", "--quiet", "--collect",
             "--service-type=oneshot",
             "--description=Reprobuild add-on: confined evidence run",
             "-p", "TimeoutStartSec=" & $EvidenceShipTimeoutStartSec]
  let inputs = EvidenceUnitsInputs(sinkAddress: sinkAddressOf(conf.sinkEndpoint))
  for line in evidenceShipConfinement(inputs):
    result.add("-p")
    result.add(line)
  # A binary outside the store may sit where the sandbox hides it (an
  # operator's /root, the test bed's /root/addon): the run executes root's
  # copy of that one file, ``exeCopy``, under ``ConfinedExeCopyDir``
  # (``runConfined`` makes it; systemd-run looks the command up on the
  # host, so it must exist there too).
  result.add("--")
  result.add(if reproExe.startsWith(StoreRoot & "/"): reproExe
             else: exeCopy)
  result.add("system")
  result.add("addon")
  for c in command: result.add(c)

var confinedRunner*: proc (argv: seq[string]): HostToolResult {.nimcall.} = nil
  ## A test seam, nil in production: what runs a confined run's
  ## ``systemd-run`` argv instead of the host (a unit test has no PID 1 to
  ## start a transient unit).

proc confinedCopyPath*(pid = getCurrentProcessId(); nonce = ""): string =
  ## This run's own copy (``ConfinedExeCopyDir``): a directory per run.
  var n = nonce
  if n.len == 0:
    for b in urandom(6): n.add(toHex(int(b), 2).toLowerAscii())
  when mutated("confined-copy-shared"):
    # FALSIFYING BUILD: every run shares one copy, and the first to finish
    # removes it from under the others.
    discard n
    return ConfinedExeCopyDir / "repro"
  ConfinedExeCopyDir / ("run-" & $pid & "-" & n) / "repro"

proc runConfined*(conf: EvidenceConf; command: openArray[string]):
    HostToolResult =
  ## One confined run (``confinedRunArgv``), its output captured with every
  ## control byte escaped (``escapeControl``): it was printed by the
  ## process that decoded the sink's bytes.
  if confinedRunner != nil:
    result = confinedRunner(confinedRunArgv(conf, command,
                                            systemdRun = "/usr/bin/systemd-run"))
    result.output = escapeControl(result.output)
    return
  let exe = confinedReproExe()
  let copied = not exe.startsWith(StoreRoot & "/")
  let copy = confinedCopyPath()
  if copied:
    createDir(ConfinedExeCopyDir)
    discard posix.chmod(ConfinedExeCopyDir.cstring, Mode(0o755))
    createDir(parentDir(copy))
    discard posix.chmod(parentDir(copy).cstring, Mode(0o755))
    writeFileAtomic(copy, readFile(exe), 0o755)
  try:
    result = runHostTool(confinedRunArgv(conf, command, reproExe = exe,
                                         exeCopy = copy),
                         timeoutSec = EvidenceShipTimeoutStartSec + 60)
    result.output = escapeControl(result.output)
  finally:
    if copied:
      # Only this run's own directory; the shared parent goes only when no
      # other run has one in it (an rmdir of a non-empty one fails).
      try: removeDir(parentDir(copy))
      except OSError: discard
      when not mutated("confined-copy-shared"):
        discard posix.rmdir(ConfinedExeCopyDir.cstring)

proc shipFor*(site: ShipSite; conf: EvidenceConf; host: string;
              forceHeartbeat = false): ShipResult =
  ## A shipping run for ``site``: in process for a test's site; for the
  ## host's (``site.confined``) the apt hook harvest here, as root, and
  ## the shipping itself in a confined run. ``pending`` is then the count
  ## of entry names left in the outbox, and ``error`` says why any are.
  if not site.confined or mutated("ship-decoded-as-root"):
    var s = site
    s.confined = false
    return runEvidenceShip(s, conf, host, forceHeartbeat)
  result.hookEvents = harvestHookWrapperEvents(site, host)
  try:
    reportLegacyMove(moveLegacyShipState(site))
  except CatchableError as e:
    # The move leaves ``legacyLeftPath`` non-zero, so the confined run
    # below ships nothing; the records stay where they are.
    stderr.write("repro-addon evidence: the shipping state from before " &
      "the shipping unit's own user: " & escapeControl(e.msg) & "\n")
  var dropLeftOver = 0
  try:
    dropLeftOver = harvestDropEntries(site.dropDir, site.outbox,
                                      site.stateDir).left.len
  except CatchableError as e:
    # A drop directory that cannot be opened (a link or a file in its
    # place) ships nothing from it, and says so; the outbox still ships.
    stderr.write("repro-addon evidence: the egress check's drop directory " &
      escapeControl(site.dropDir) & ": " & escapeControl(e.msg) & "\n")
  var cmd = @["evidence-ship", "--no-backoff"]
  if forceHeartbeat: cmd.add("--heartbeat")
  let r = runConfined(conf, cmd)
  result.pending = outboxEntries(site.outbox).len
  # Drop entries still not moved are queued records too (uninstall's gate).
  when not mutated("uninstall-ignores-drop"):
    result.pending += dropEntryNames(site.dropDir).len
  # So are the legacy outbox's entries not yet moved.
  if site.legacyOutbox.len > 0:
    result.pending += dropEntryNames(site.legacyOutbox).len
  if r.exitCode != 0:
    result.error = "the confined shipping run (" & confinedReproExe() &
      ") exited " & $r.exitCode & ": " & r.output.strip()
  elif result.pending > 0:
    result.error = $result.pending & " record(s) still queued: " &
      r.output.strip()

proc inConfinedRun(): bool =
  ## Whether this process is the shipping unit or one of its transient
  ## runs (``EvidenceShipConfinedEnv``).
  getEnv(EvidenceShipConfinedEnv) == "1"

proc runHarvest*(site: ShipSite; host: string): int

proc runEvidenceHarvestCommand*(): int =
  ## ``repro system addon evidence-harvest``: the shipping unit's
  ## privileged ``ExecStartPre=+`` step. Turns the apt hook wrapper's
  ## events in root's log into outbox entries, and moves the egress check's
  ## entries from its root drop directory into the outbox (§13 decision
  ## 188); reads nothing from the network.
  runHarvest(defaultShipSite(), readHost())

proc runHarvest*(site: ShipSite; host: string): int =
  ## ``evidence-harvest`` for ``site``. Each half's failure is reported and
  ## does not fail the step (A11 round 26): an ``ExecStartPre=+`` that
  ## failed would stop the shipping run, and with it every record already
  ## in the outbox.
  var failed = false
  try:
    # The shipping state from before §13 decision 181 (the owner's
    # decision of 2026-11-26), before anything else lands in the outbox.
    reportLegacyMove(moveLegacyShipState(site))
  except CatchableError as e:
    failed = true
    stderr.write("repro system addon evidence-harvest: the shipping state " &
      "from before the shipping unit's own user: " & escapeControl(e.msg) &
      "\n")
  try:
    let n = harvestHookWrapperEvents(site, host)
    if n > 0: stdout.write("evidence: " & $n & " apt hook event(s)\n")
  except CatchableError as e:
    failed = true
    stderr.write("repro system addon evidence-harvest: the apt hook's " &
      "events: " & escapeControl(e.msg) & "\n")
  try:
    # The egress check's entries (§13 decision 188).
    let h = harvestDropEntries(site.dropDir, site.outbox, site.stateDir)
    if h.moved > 0: stdout.write("evidence: " & $h.moved & " egress check entr" &
                                 (if h.moved == 1: "y" else: "ies") & "\n")
  except CatchableError as e:
    failed = true
    stderr.write("repro system addon evidence-harvest: the egress check's " &
      "drop directory " & escapeControl(site.dropDir) & ": " &
      escapeControl(e.msg) & "\n")
  when mutated("harvest-failure-fails-step"):
    return (if failed: 2 else: 0)     # FALSIFYING BUILD: the step fails
  else:
    discard failed
    0

proc runEvidenceShipCommand*(heartbeat, noBackoff: bool): int =
  ## ``repro system addon evidence-ship [--heartbeat]`` (the shipping unit);
  ## ``noBackoff`` (``--no-backoff``, which the confined run of a root
  ## caller's ship is given) skips the unit's wait.
  let force = heartbeat
  if not inConfinedRun() and not mutated("ship-decoded-as-root"):
    # An operator's (or any root) invocation: ship in a confined run.
    try:
      let site = defaultShipSite()
      let conf = loadEvidenceConf(site.confPath)
      let r = shipFor(site, conf, readHost(), force)
      stdout.write("evidence: queued " & $r.pending & "\n")
      if r.error.len > 0: stderr.write("repro-addon evidence: " & r.error & "\n")
      return 0
    except CatchableError as e:
      stderr.write("repro system addon evidence-ship: " & e.msg & "\n")
      return 2
  let site = unitShipSite()
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
  if not noBackoff:
    sleep(1000 * shipRunWait(site, heartbeat))

proc runCredentialCheckCommand*(): int =
  ## ``repro system addon evidence-credential-check``.
  if not inConfinedRun() and not mutated("ship-decoded-as-root"):
    # The sink's answers are decoded in the shipping unit's confinement,
    # never by the calling root process (§13 decision 181).
    try:
      let conf = loadEvidenceConf(defaultShipSite().confPath)
      let r = runConfined(conf, ["evidence-credential-check"])
      stdout.write(r.output)
      return (if r.exitCode in [0, 1, 2]: r.exitCode else: 2)
    except CatchableError as e:
      stderr.write("repro system addon evidence-credential-check: " & e.msg & "\n")
      return 2
  let site = unitShipSite()
  try:
    let conf = loadEvidenceConf(site.confPath)
    let c = runCredentialCheck(site, conf, readHost())
    stdout.write("append: " & (if c.appended: "acknowledged" else:
      "NOT acknowledged (" & c.error & ")") & "\n")
    for (op, outcome) in c.answered:
      stdout.write($op & ": " & (case outcome
        of poAnswered: "ANSWERED (the credential can " & $op & " the sink)"
        of poRefused: "refused, and the sink recorded the refusal"
        of poUndelivered: "NOT DELIVERED (the sink never said it refused " &
          "it; nothing is known of the credential's scope)") & "\n")
    for e in c.probeErrors: stdout.write("  " & e & "\n")
    if credentialCheckOk(c): 0 else: 1
  except CatchableError as e:
    stderr.write("repro system addon evidence-credential-check: " & e.msg & "\n")
    2

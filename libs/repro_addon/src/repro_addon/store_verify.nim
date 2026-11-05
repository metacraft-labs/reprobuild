## Store verification against the digest each path had when it was realised
## (spec §13 decision 46; threat model DET-AO-5, G41).
##
##   repro system addon store-verify [--background] [--adopt-unverified]
##       (``repro-addon-store-verify.service``, with ``--background``, from
##       its timer: two minutes after boot and every six hours.) Every store
##       path the current generation's ledger names is hashed again
##       (``repro_local_store.storeTreeDigest``, the canonical tree digest)
##       and compared with the digest its receipt recorded when it was
##       realised (receipt v4, ``contentDigest``).
##
## * A MISMATCH is a DET-AO-5 detection (``addon-store`` /
##   ``store-digest-mismatch``, with both digests) and the path is
##   QUARANTINED (``store_root.quarantineStorePath``): every later switch
##   that would use it refuses (``EAddOnStoreChanged``), and the re-assert
##   reports the host ``degraded`` while the current generation uses it.
## * A path with NO digest -- realised before receipts carried one, or
##   adopted by a realiser that did not hash it -- is never silently trusted:
##   it is reported (``store-unverifiable``, one record per run naming
##   them) until an operator records its digest as it is now
##   (``--adopt-unverified``: an operator action with its own evidence
##   record, after which the path is verified against that digest).
## * BOUNDED: one run stops after ``StoreVerifyBudgetSec``; the paths it did
##   not reach are the next run's first (a rotating cursor), and the unit
##   runs at idle CPU and IO priority. It is started by a timer, never by
##   the boot transaction.
## * Every run heartbeats (DET-5): verification that stopped running is
##   silence, not "nothing altered".

import std/[os, strutils, tables, times]

import repro_local_store/store

import ./addon_apply
import ./evidence
import ./generation0
import ./ledger
import ./mutations
import ./store_root

type
  StoreVerifySite* = object
    stateDir*: string
    quarantinePath*: string
    adoptedPath*: string
    cursorPath*: string
    evidence*: EvidenceSite

  StoreVerifyReport* = object
    verified*: seq[string]
    mismatched*: seq[tuple[path, expected, observed: string]]
    unverifiable*: seq[string]
    notReached*: seq[string]
    quarantined*: seq[string]

proc defaultStoreVerifySite*(stateDir = DefaultStateDir): StoreVerifySite =
  StoreVerifySite(stateDir: stateDir, quarantinePath: StoreQuarantinePath,
    adoptedPath: StoreAdoptedDigestsPath,
    cursorPath: addonDir(stateDir) / "store-verify.cursor",
    evidence: defaultSite(stateDir))

proc withEvidence*(site: StoreVerifySite; e: EvidenceSite): StoreVerifySite =
  ## ``site`` writing its records to ``e`` (a test's, or another state's).
  result = site
  result.evidence = e

proc readAdopted(path: string): Table[string, string] =
  result = initTable[string, string]()
  try:
    for l in readFile(path).splitLines():
      let p = l.splitWhitespace()
      if p.len == 2: result[p[0]] = p[1]
  except IOError, OSError:
    discard

proc currentStorePaths*(stateDir: string): seq[string] =
  ## The store paths the current generation's ledger names.
  let l = readLedger(ledgerCopyPath(stateDir))
  for e in l.entries:
    if e.class == lcStorePrefix and e.path notin result: result.add(e.path)

proc expectedDigest*(path: string; adopted: Table[string, string]): string =
  ## The digest ``path`` had when it was realised, from its receipt, or the
  ## one an operator adopted for it; "" when there is none.
  try:
    let r = readReceiptFile(path / ReceiptFileName)
    if r.contentDigest.len > 0: return r.contentDigest
  except CatchableError:
    discard
  adopted.getOrDefault(path, "")

proc verifyStore*(site: StoreVerifySite; paths: seq[string];
                  budgetSec = StoreVerifyBudgetSec): StoreVerifyReport =
  ## Verify ``paths``, starting at the cursor and wrapping, until the budget
  ## is spent. Quarantines each mismatch.
  let adopted = readAdopted(site.adoptedPath)
  var start = 0
  try: start = parseInt(readFile(site.cursorPath).strip()) mod max(1, paths.len)
  except CatchableError: discard
  let deadline = epochTime() + float(budgetSec)
  var i = 0
  while i < paths.len:
    let p = paths[(start + i) mod paths.len]
    if epochTime() > deadline:
      result.notReached.add(p)
      inc i
      continue
    let expected = expectedDigest(p, adopted)
    if expected.len == 0:
      result.unverifiable.add(p)
    elif not dirExists(p):
      discard   # a missing object is the re-assert's own finding
    else:
      let observed = storeTreeDigest(p)
      when mutated("reassert-skips-digest-check"):
        # FALSIFYING BUILD: the digests are computed and never compared.
        result.verified.add(p)
      else:
        if observed == expected: result.verified.add(p)
        else:
          result.mismatched.add((p, expected, observed))
          quarantineStorePath(p, site.quarantinePath)
          result.quarantined.add(p)
    inc i
  let next = if result.notReached.len > 0:
               (start + paths.len - result.notReached.len) mod max(1, paths.len)
             else: 0
  try:
    createDir(parentDir(site.cursorPath))
    writeFile(site.cursorPath, $next & "\n")
  except CatchableError:
    discard

proc recordStoreVerify*(r: StoreVerifyReport; site: StoreVerifySite) =
  ## The run's records: a detection per mismatch, one for the unverifiable
  ## paths, and the heartbeat. Raises when a detection cannot be written.
  for m in r.mismatched:
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecDetection, trigger: "store-digest-mismatch",
      fields: @[("path", m.path), ("digest", m.expected),
                ("observedDigest", m.observed),
                ("message", m.path & " no longer holds the bytes it was " &
                 "realised with; quarantined")], attest: true), site.evidence)
  if r.unverifiable.len > 0:
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecDetection, trigger: "store-unverifiable",
      fields: @[("count", $r.unverifiable.len),
                ("message", "no realisation digest for: " &
                 r.unverifiable.join(", "))], attest: true), site.evidence)
  discard recordEvidence(EvidenceEvent(detector: edStore,
    category: ecHeartbeat, kind: "store-verify", offHostOnly: true,
    fields: @[("intervalMs", $(int64(StoreVerifyIntervalSec) * 1000)),
              ("count", $r.verified.len), ("pending", $r.notReached.len),
              ("status", if r.mismatched.len > 0: "mismatch"
                         elif r.unverifiable.len > 0: "unverifiable"
                         else: "verified")], attest: true), site.evidence)

proc adoptUnverified*(site: StoreVerifySite; paths: seq[string]): seq[string] =
  ## Record the digest each path without one has now (an operator's act:
  ## from here on it is verified against that digest). Returns what it
  ## adopted.
  var adopted = readAdopted(site.adoptedPath)
  for p in paths:
    if expectedDigest(p, adopted).len == 0 and dirExists(p):
      adopted[p] = storeTreeDigest(p)
      result.add(p)
  var text = ""
  for k, v in adopted: text.add(k & " " & v & "\n")
  createDir(parentDir(site.adoptedPath))
  writeFile(site.adoptedPath & ".tmp", text)
  setFilePermissions(site.adoptedPath & ".tmp", {fpUserRead, fpUserWrite})
  moveFile(site.adoptedPath & ".tmp", site.adoptedPath)
  if result.len > 0:
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecAudit, trigger: "store-digest-adopted",
      fields: @[("outcome", "aoOperatorAction"), ("count", $result.len),
                ("message", result.join(", "))], attest: true), site.evidence)

proc runStoreVerifyCli*(args: seq[string]): int =
  var background, adopt = false
  for a in args:
    case a
    of "--background": background = true
    of "--adopt-unverified": adopt = true
    else:
      stderr.write("usage: repro system addon store-verify [--background] " &
        "[--adopt-unverified]\n")
      return 2
  let site = defaultStoreVerifySite()
  try:
    let paths = currentStorePaths(site.stateDir)
    if adopt:
      let a = adoptUnverified(site, paths)
      stdout.write("adopted the current digest of " & $a.len & " path(s)\n")
    let r = verifyStore(site, paths)
    recordStoreVerify(r, site)
    stdout.write("store: " & $r.verified.len & " verified, " &
      $r.mismatched.len & " ALTERED (quarantined), " & $r.unverifiable.len &
      " without a realisation digest, " & $r.notReached.len &
      " left for the next run\n")
    for m in r.mismatched: stdout.write("  altered: " & m.path & "\n")
    if background: 0
    elif r.mismatched.len > 0: 1
    else: 0
  except CatchableError as e:
    stderr.write("repro system addon store-verify: " & e.msg & "\n")
    if background: 0 else: 2

## Store verification against the digest each path had when it was realised
## (spec §13 decision 46; threat model DET-AO-5, G41).
##
##   repro system addon store-verify [--background] [--adopt-unverified]
##       (``repro-addon-store-verify.service``, with ``--background``, from
##       its timer: two minutes after boot and every six hours.) Every store
##       path the current generation's ledger names is hashed again
##       (``repro_local_store.storeTreeDigest``, the canonical tree digest)
##       and compared with the digest it had when it was realised. That
##       digest is taken from OUTSIDE the store: the ledger entry the
##       realising process wrote (``value`` of a ``storePrefix`` entry,
##       computed from the bytes it staged), the realisation index
##       (``store_custody``, spec §13 decision 48), or one an operator
##       adopted. Since decision 48 the ledger names every store object
##       the generation references, so every one of them is verified.
##       Never from the path's own receipt: whoever can alter the path can
##       alter or delete its receipt too (audit session 2, G2).
##
## * A MISMATCH is a DET-AO-5 detection (``addon-store`` /
##   ``store-digest-mismatch``, with both digests) and the path is
##   QUARANTINED (``store_root.quarantineStorePath``): every later switch
##   that would use it refuses (``EAddOnStoreChanged``), and the re-assert
##   reports the host ``degraded`` while the current generation uses it.
## * A path with NO recorded digest -- realised before the ledger carried
##   one -- is never silently trusted: it is reported
##   (``store-unverifiable``, one record per run naming each with the
##   digest it has now, and its receipt's when it has one) until an
##   operator records its digest as it is now (``--adopt-unverified``: an
##   operator action with its own evidence record, after which the path is
##   verified against that digest). A path whose receipt names a digest
##   other than the one it has now is never adopted: it was altered after
##   it was realised, or its receipt was.
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
import ./store_custody
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
    unverifiableDigests*: seq[tuple[observed, receipt: string]]
      ## per ``unverifiable`` entry: the digest it has now, and the one its
      ## receipt names ("" when none)
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

proc custodyOf*(site: StoreVerifySite): CustodySite =
  ## The custody state this verification reads: the realisation index and
  ## the evidence directory of its state directory, its own quarantine and
  ## adoption files.
  result = custodySite(site.stateDir)
  result.quarantinePath = site.quarantinePath
  result.adoptedPath = site.adoptedPath
  result.evidence = site.evidence

proc currentStorePaths*(stateDir: string): seq[string] =
  ## The store paths the current generation's ledger names.
  let l = readLedger(ledgerCopyPath(stateDir))
  for e in l.entries:
    if e.class == lcStorePrefix and e.path notin result: result.add(e.path)

proc receiptDigestOf(path: string): string =
  ## The ``contentDigest`` the path's own receipt claims, "" when it has
  ## none or no receipt. Context for a reader only, never an expectation.
  try: readReceiptFile(path / ReceiptFileName).contentDigest
  except CatchableError: ""

proc expectedDigest*(path: string; recorded, adopted: Table[string, string]):
    string =
  ## The digest ``path`` had when it was realised, as a ledger recorded it,
  ## or the one an operator adopted for it; "" when there is none.
  when mutated("store-verify-trusts-receipt"):
    # FALSIFYING BUILD: session 1's expectation, read from the receipt in
    # the very path being verified (audit session 2, G2).
    let r = receiptDigestOf(path)
    if r.len > 0: return r
    return adopted.getOrDefault(path, "")
  result = recorded.getOrDefault(path, "")
  if result.len == 0: result = adopted.getOrDefault(path, "")


proc verifyStore*(site: StoreVerifySite; paths: seq[string];
                  budgetSec = StoreVerifyBudgetSec): StoreVerifyReport =
  ## Verify ``paths``, starting at the cursor and wrapping, until the budget
  ## is spent. Quarantines each mismatch.
  let adopted = readAdopted(site.adoptedPath)
  # Every expectation from outside the store: the ledgers, the realisation
  # index (§13 decision 48), then the adoptions.
  let recorded = expectedDigests(custodyOf(site))
  pruneEvidence(custodyOf(site))
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
    let expected = expectedDigest(p, recorded, adopted)
    if expected.len == 0:
      result.unverifiable.add(p)
      let observed = if dirExists(p): storeTreeDigest(p) else: "(gone)"
      result.unverifiableDigests.add((observed, receiptDigestOf(p)))
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
    # Each path with the digest it has now (and its receipt's claim), so
    # off-host a path that changed between two runs is visible.
    var each: seq[string]
    for i, p in r.unverifiable:
      let d = r.unverifiableDigests[i]
      each.add(p & " " & d.observed &
               (if d.receipt.len > 0: " receipt=" & d.receipt else: ""))
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecDetection, trigger: "store-unverifiable",
      fields: @[("count", $r.unverifiable.len),
                ("paths", each.join("; ")),
                ("message", "no realisation digest recorded outside the " &
                 "store for: " & r.unverifiable.join(", "))], attest: true),
      site.evidence)
  discard recordEvidence(EvidenceEvent(detector: edStore,
    category: ecHeartbeat, kind: "store-verify", offHostOnly: true,
    fields: @[("intervalMs", $(int64(StoreVerifyIntervalSec) * 1000)),
              ("count", $r.verified.len), ("pending", $r.notReached.len),
              ("status", if r.mismatched.len > 0: "mismatch"
                         elif r.unverifiable.len > 0: "unverifiable"
                         else: "verified")], attest: true), site.evidence)

proc adoptUnverified*(site: StoreVerifySite; paths: seq[string]):
    tuple[adopted, refused: seq[string]] =
  ## Record the digest each path without a recorded one has now (an
  ## operator's act: from here on it is verified against that digest).
  ## A path a ledger records a digest for is not "without one" and is never
  ## re-blessed, whatever its receipt says now; a path whose receipt names
  ## another digest than it has now is refused (altered since it was
  ## realised, or its receipt was), and named. Returns both lists.
  var adopted = readAdopted(site.adoptedPath)
  let recorded = expectedDigests(custodyOf(site))
  for p in paths:
    if not dirExists(p) or expectedDigest(p, recorded, adopted).len > 0:
      continue
    let now = storeTreeDigest(p)
    let claimed = receiptDigestOf(p)
    when not mutated("store-verify-trusts-receipt"):
      if claimed.len > 0 and claimed != now:
        result.refused.add(p)
        continue
    adopted[p] = now
    result.adopted.add(p)
  var text = ""
  for k, v in adopted: text.add(k & " " & v & "\n")
  createDir(parentDir(site.adoptedPath))
  writeFile(site.adoptedPath & ".tmp", text)
  setFilePermissions(site.adoptedPath & ".tmp", {fpUserRead, fpUserWrite})
  moveFile(site.adoptedPath & ".tmp", site.adoptedPath)
  # Every object the generation references now has a digest: the host is
  # under custody from here on (§13 decision 48).
  var left = 0
  for p in paths:
    if dirExists(p) and expectedDigest(p, recorded, adopted).len == 0: inc left
  if left == 0 and result.refused.len == 0:
    markCustody(custodyOf(site))
  if result.adopted.len > 0:
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecAudit, trigger: "store-digest-adopted",
      fields: @[("outcome", "aoOperatorAction"),
                ("count", $result.adopted.len),
                ("message", result.adopted.join(", "))], attest: true),
      site.evidence)
  if result.refused.len > 0:
    discard recordEvidence(EvidenceEvent(detector: edStore,
      category: ecDetection, trigger: "store-digest-mismatch",
      fields: @[("count", $result.refused.len),
                ("message", "not adopted, the receipt names another " &
                 "digest than the path has now: " &
                 result.refused.join(", "))], attest: true), site.evidence)

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
      stdout.write("adopted the current digest of " & $a.adopted.len &
        " path(s)\n")
      for p in a.refused:
        stdout.write("  NOT adopted (its receipt names another digest): " &
          p & "\n")
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

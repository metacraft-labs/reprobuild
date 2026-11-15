## Uninstall leaves a pre-bootstrap input in place (ReproOS Add-On Mode
## spec §6.1, §6.4; §13 decisions 166 to 168), the deploy agent's live
## records above all: the sequence floor is rewritten at every tick, so it
## is ledgered with its content UNPINNED (``lcKept``), never removed, never
## rewritten, and every ``*.seq`` floor stays while the key does. A floor
## that did not survive would let a manifest this host already accepted
## replay on its kept key. Only the mode and owner bootstrap's takeover
## changed are put back, in place, before the ledger copy goes.
##
## The reviewed defect (R review, item 1): the records were ledgered with
## a content digest, so after the first tick the capture judged them
## drifted and skipped them, the state directory was removed, and nothing
## wrote them back. Since §13 decision 166 nothing is written back at all:
## the inputs are never removed, and only their mode and owner change,
## back to what they were (the suite "the pre-bootstrap inputs stay where
## they are" below).
##
## No mocks: real files under a temporary root, the uninstall's own
## removal and metadata procedures (the host-level verb around them needs
## root and a ledger of a real bootstrap; the VM gates cover that), the
## ledger's own drift check, and the apply planner's own refusal.

import std/[json, os, posix, sequtils, strutils, unittest]

import repro_infra
import repro_addon/fingerprint
import repro_addon/[addon_apply, evidence, evidence_ship, ledger, store_root, uninstall]
from repro_addon/preflight import AgentStateRecordsDir

let me = $getuid() & ":" & $getgid()
let myIds = (int(getuid()), int(getgid()))

suite "the agent's records survive uninstall byte for byte":
  let root = getTempDir() / ("repro-addon-uninstall-kept-" & $getCurrentProcessId())
  removeDir(root)
  let records = root / "agent/state/deploy-agent"
  createDir(records)
  let seqPath = records / "rpi2.seq"
  writeFile(seqPath, "7\n")
  let ledger = Ledger(generation: "g0", entries: @[
    LedgerEntry(class: lcRoot, path: root / "agent", mode: "0700", owner: me,
                kindHint: "dir", replaced: "dir 0700 " & me, collision: "adopt"),
    LedgerEntry(class: lcDir, path: root / "agent/state", mode: "0700",
                owner: me, replaced: "dir 0700 " & me, collision: "adopt"),
    LedgerEntry(class: lcDir, path: records, mode: "0700", owner: me,
                replaced: "dir 0700 " & me, collision: "adopt"),
    LedgerEntry(class: lcKept, path: seqPath, mode: "0600", owner: me,
                collision: "adopt"),
  ])

  test "a kept record is a pre-bootstrap input with no content pinned":
    check ledger.entries[3].isPreBootstrapInput
    check ledger.entries[3].sha256.len == 0

  test "a bumped sequence floor is not drift":
    writeFile(seqPath, "12\n")        # the agent ticked after bootstrap
    check observeDrift(ledger.entries[3]) == ""

  test "a bumped sequence floor is an input left where it is, with its recorded mode and owner":
    writeFile(seqPath, "12\n")
    let pb = preBootstrapInputs(ledger, expectedOwner = myIds)
    check pb.drift.len == 0 and pb.errors.len == 0
    check pb.inputs.len == 4
    check pb.inputs[3].path == seqPath and not pb.inputs[3].isDir and
          pb.inputs[3].mode == 0o600
    check pb.inputs[0].isDir and pb.inputs[0].mode == 0o700

  test "a content-pinned input that changed is drift":
    let signers = root / "signers"
    writeFile(signers, "key\n")
    let pinned = LedgerEntry(class: lcEtcFile, path: signers,
      sha256: sha256Hex("key\n"), mode: "0644", owner: me,
      replaced: "f 0644 " & me & " sha256:" & sha256Hex("key\n"),
      collision: "adopt")
    writeFile(signers, "other key\n")
    let pb = preBootstrapInputs(Ledger(entries: @[pinned]), expectedOwner = myIds)
    check pb.drift.len == 1 and "content changed" in pb.drift[0]

  test "the ledger text carries the kept class":
    check parseLedger(ledger.render()).entries[3].class == lcKept

  removeDir(root)

suite "a profile cannot declare a resource at a kept path":
  let previous = Ledger(generation: "g0", entries: @[
    LedgerEntry(class: lcEtcFile, path: "/etc/repro/deploy-manifest-allowed-signers",
                sha256: "aa", mode: "0644", owner: "0:0", collision: "adopt"),
    LedgerEntry(class: lcKept, path: "/var/lib/repro/agent/state/deploy-agent/rpi2.seq",
                mode: "0600", owner: "0:0", collision: "adopt"),
    LedgerEntry(class: lcEtcFile, path: "/etc/app/app.conf", sha256: "bb",
                mode: "0644", owner: "0:0", resource: "systemFile:/etc/app/app.conf"),
  ])

  test "a kept file's path is refused at plan time, naming the rule":
    let why = keptPathRefusal(previous, "/etc/repro/deploy-manifest-allowed-signers")
    check "pre-bootstrap input" in why and "cannot declare" in why
    check keptPathRefusal(previous,
      "/var/lib/repro/agent/state/deploy-agent/rpi2.seq").len > 0

  test "a tmpfiles rule named like the kept fragment lands on its path and is refused":
    # The refusal uses the planner's own targetPathOf, so every
    # file-shaped kind is covered, not only systemFile / unit / diversion.
    let kept = Ledger(entries: @[LedgerEntry(class: lcEtcFile,
      path: "/etc/tmpfiles.d/repro-addon-bootstrap.conf", sha256: "cc",
      mode: "0644", owner: "0:0", collision: "adopt")])
    let rule = SystemResource(kind: srkLinuxTmpfilesRule,
      address: "linux.tmpfilesRule:repro-addon-bootstrap.conf",
      tmpfilesName: "repro-addon-bootstrap.conf")
    check targetPathOf(rule) == "/etc/tmpfiles.d/repro-addon-bootstrap.conf"
    check keptPathRefusal(kept, targetPathOf(rule)).len > 0
    let other = SystemResource(kind: srkLinuxTmpfilesRule,
      address: "linux.tmpfilesRule:repro-agent.conf",
      tmpfilesName: "repro-agent.conf")
    check keptPathRefusal(kept, targetPathOf(other)) == ""

  test "an ordinary owned path and an unknown path are not":
    check keptPathRefusal(previous, "/etc/app/app.conf") == ""
    check keptPathRefusal(previous, "/etc/other") == ""
    check keptPathRefusal(previous, "") == ""

# ---------------------------------------------------------------------------
# reprobuild-pm issue 2026-11-14-addon-uninstall-removes-the-state-and-
# attestation-key-after-a-failed-store-removal-so-the-discard-can-never-
# complete (spec §10.2 Uninstall step 5, §13 decisions 62 and 113): a failed
# removal of /repro must keep the state (ledger copy, attestation key), so a
# second uninstall can finish the discard.
#
# No mocks of the unit under test: a real temporary state directory with a
# real ledger and key file, and the uninstall's own ``removeStore`` and
# ``keepStateWhenIncomplete``. The failing removal is a ``StoreRemover`` that
# raises ``OSError`` as ``removeReproRoot`` does part-way: the host-level verb
# needs root and a bootstrapped host (the VM gates cover that), and /repro
# cannot be made to fail portably here.
# ---------------------------------------------------------------------------

proc stateScene(name: string): tuple[state: string; l: Ledger] =
  let dir = getTempDir() / ("repro-uninstall-state-" & name & "-" &
                            $getCurrentProcessId())
  removeDir(dir)
  createDir(dir / "agent")
  writeFile(dir / "agent/attestation.key", "KEY")
  let l = Ledger(generation: "g0", entries: @[
    LedgerEntry(class: lcDir, path: dir / "gone-nowhere", mode: "0755",
                owner: "0:0", collision: "adopt")])
  writeLedger(ledgerCopyPath(dir), l)
  (dir, l)

suite "a failed store removal keeps the state":
  test "the removal error makes the uninstall incomplete and keeps state":
    let s = stateScene("failed")
    var r: UninstallResult
    let failed = removeStore(r, keepStore = false,
      remover = proc () = raise newException(OSError, "Operation not permitted"),
      mounted = false)
    check failed
    check ReproRoot notin r.removed
    check r.errors.len == 1 and "Operation not permitted" in r.errors[0]
    check keepStateWhenIncomplete(r, s.l, s.state)
    check fileExists(s.state / "agent/attestation.key")
    check fileExists(ledgerCopyPath(s.state))
    check "are kept" in r.errors[^1]

  test "a store still mounted is also a failed removal":
    var r: UninstallResult
    check removeStore(r, keepStore = false, remover = proc () = discard,
                      mounted = true)
    check "still mounted" in r.errors[0]

  test "a successful removal is complete: the state may go":
    let s = stateScene("ok")
    var r: UninstallResult
    check not removeStore(r, keepStore = false, remover = proc () = discard,
                          mounted = false)
    check ReproRoot in r.removed
    check not keepStateWhenIncomplete(r, s.l, s.state)

  test "--keep-store removes nothing and is not a failure":
    var r: UninstallResult
    var called = false
    check not removeStore(r, keepStore = true,
      remover = proc () = called = true, mounted = false)
    check not called and r.errors.len == 0

suite "the decision after the store's removal, and the second uninstall":
  test "a failed store removal stops the uninstall before the state goes":
    let s = stateScene("decision")
    var r: UninstallResult
    let failed = removeStore(r, false,
      proc () = raise newException(OSError, "EPERM"), mounted = false)
    check keepStateAfterStore(r, s.l, s.state, failed)
    check fileExists(s.state / "agent/attestation.key")

  test "a leftover aside without --keep-store also stops it":
    let s = stateScene("aside")
    var r: UninstallResult
    r.leftAside.add("/repro/store/tmp/custody-aside/x")
    r.errors.add("aside still there")
    check keepStateAfterStore(r, s.l, s.state, false)

  test "a clean store removal does not stop it":
    let s = stateScene("clean")
    var r: UninstallResult
    check not keepStateAfterStore(r, s.l, s.state, false)

  test "a second uninstall finds the key and the ledger and completes":
    let s = stateScene("second")
    var first: UninstallResult
    let failed = removeStore(first, false,
      proc () = raise newException(OSError, "EPERM"), mounted = false)
    check keepStateAfterStore(first, s.l, s.state, failed)
    # Second run: the ledger copy is readable and the key is still there.
    let again = readLedger(ledgerCopyPath(s.state))
    check again.generation == "g0"
    check fileExists(s.state / "agent/attestation.key")
    var second: UninstallResult
    check not removeStore(second, false, proc () = discard, mounted = false)
    check not keepStateAfterStore(second, again, s.state, false)

  test "evidence is listed as removed only after its root is gone":
    let dir = getTempDir() / ("repro-uninstall-root-" & $getCurrentProcessId())
    createDir(dir)
    var bad: UninstallResult
    removeHostRoot(bad, dir, @[dir / "ev"],
      proc (d: string) = raise newException(OSError, "busy"))
    check bad.removed.len == 0 and bad.errors.len == 1
    var good: UninstallResult
    removeHostRoot(good, dir, @[dir / "ev"])
    check dir in good.removed and (dir / "ev" & " (store evidence)") in good.removed

# ---------------------------------------------------------------------------
# A11 code review round 11: the store-evidence entries under the state are
# removed before the keys and the state, each reported removed only once it
# is gone, and an entry that cannot be removed keeps the state with the
# attestation key (spec §6.4 step 5, *Order*; §13 decision 81, amended
# 2026-11-14). Falsifier ``evidence-reported-removed-unchecked`` (an entry
# reported removed though its removal failed, and the uninstall going on to
# the keys) turns this suite red.
#
# The failing removal is a remover that raises ``OSError``, as ``removeDir``
# does on an immutable file; the VM gate ``e2e_addon_store_custody`` makes
# the same failure with ``chattr +i`` on a real host.
# ---------------------------------------------------------------------------

suite "a failed store-evidence removal keeps the state":
  test "an entry whose removal fails is not reported removed, and stops the uninstall":
    let s = stateScene("evidence")
    let e1 = s.state / "ev1"
    let e2 = s.state / "ev2"
    createDir(e1)
    createDir(e2)
    var r: UninstallResult
    let failed = removeStateEvidence(r, @[e1, e2],
      proc (d: string) =
        if d == e1: raise newException(OSError, "Operation not permitted")
        removeDir(d))
    check failed
    check (e1 & " (store evidence)") notin r.removed
    check (e2 & " (store evidence)") in r.removed
    check r.errors.len == 1 and "Operation not permitted" in r.errors[0]
    check keepStateWhenIncomplete(r, s.l, s.state)
    check fileExists(s.state / "agent/attestation.key")
    check fileExists(ledgerCopyPath(s.state))

  test "an entry still on disk after a removal that did not raise is a failure":
    let s = stateScene("evidence-left")
    let e = s.state / "ev"
    createDir(e)
    var r: UninstallResult
    check removeStateEvidence(r, @[e], proc (d: string) = discard)
    check (e & " (store evidence)") notin r.removed
    check "still on disk" in r.errors[0]

  test "entries that are removed are reported, and do not stop it":
    let s = stateScene("evidence-ok")
    let e = s.state / "ev"
    createDir(e)
    var r: UninstallResult
    check not removeStateEvidence(r, @[e])
    check not dirExists(e)
    check (e & " (store evidence)") in r.removed and r.errors.len == 0

# ---------------------------------------------------------------------------
# A11 code review round 11, found by the store-custody VM gate: a first
# uninstall that does not finish removes the `/etc` objects, the sink
# configuration among them, and keeps the state with its evidence outbox.
# A re-run then found no configuration, read it as "a host without a sink:
# nothing to wait for", and discarded the unshipped evidence with no signed
# record (§13 decisions 62 and 81). A host without a sink never writes an
# outbox entry, so queued entries without a configuration are records the
# sink never acknowledged. Falsifier ``ship-ok-without-sink-configuration``.
# No mocks: a real outbox directory and the uninstall's own ``shipAndConfirm``.
# ---------------------------------------------------------------------------

suite "a lost sink configuration does not acknowledge queued records":
  let root = getTempDir() / ("repro-uninstall-ship-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root / "outbox")
  let site = ShipSite(confPath: root / "evidence.conf", outbox: root / "outbox",
                      stateDir: root / "state")

  test "no configuration and an empty outbox: nothing to wait for":
    check shipAndConfirm(site, "h") == (true, "")

  test "no configuration and queued records: not acknowledged, and says why":
    writeOutboxEntry(site.outbox, "1-x.evr", "bytes")
    let r = shipAndConfirm(site, "h")
    check not r.ok
    check "1 record(s) still queued" in r.why and "is gone" in r.why

# ---------------------------------------------------------------------------
# A11 code review round 13 (§13 decision 150): the state, /var/lib/repro, goes
# with its ledger copy last, so a removal that fails part-way leaves the one
# file a re-run reads first. A directory without write permission stands for
# an immutable file (the test runs without root); the real removal and the
# real readLedger otherwise. Falsifier ``ledger-copy-removed-with-the-rest``.
# ---------------------------------------------------------------------------

suite "the ledger copy goes last":
  test "a state removal that fails part-way keeps the ledger copy, and a re-run finishes":
    let st = getTempDir() / ("repro-uninstall-varlib-" & $getCurrentProcessId())
    removeDir(st)
    createDir(st / "system" / "addon")
    writeFile(st / "system" / "addon" / "other", "y")
    let ledger = ledgerCopyPath(st / "system")
    writeLedger(ledger, Ledger(generation: "g0"))
    # The blocker is the first directory the removal reaches AFTER system/
    # (the directory order is the file system's), so a removal that does not
    # keep the ledger copy for last has already taken it when it fails.
    for i in 0 ..< 16:
      createDir(st / ("d" & $i))
      writeFile(st / ("d" & $i) / "keep.me", "x")
    var order: seq[string]
    var extra = 0
    while true:
      order = @[]
      for kind, p in walkDir(st, relative = true): order.add(p)
      if order.find("system") < order.high: break
      createDir(st / ("e" & $extra))      # system/ listed last: add more
      writeFile(st / ("e" & $extra) / "keep.me", "x")
      inc extra
    let blocker = st / order[order.find("system") + 1]
    checkpoint "order: " & $order & " blocker: " & blocker
    setFilePermissions(blocker, {fpUserRead, fpUserExec})
    var r: UninstallResult
    let token = st & "-log" / StateRemovalTokenName
    removeStateRoot(r, st, ledger, @[st / "ev"], tokenPath = token)
    checkpoint $r.errors
    check r.errors.len == 1 and "is kept" in r.errors[0]
    check st notin r.removed
    check fileExists(ledger)
    check readLedger(ledger).generation == "g0"
    setFilePermissions(blocker, {fpUserRead, fpUserWrite, fpUserExec})
    var again: UninstallResult
    removeStateRoot(again, st, ledger, @[st / "ev"], tokenPath = token)
    check not fileExists(token)       # the run finished: no token is left
    check again.errors.len == 0
    check not dirExists(st)
    check st in again.removed and (st / "ev" & " (store evidence)") in again.removed

# ---------------------------------------------------------------------------
# A11 code review rounds 14 and 15 (§13 decisions 161 and 165, amending
# 150): after the ledger copy only rmdir(2) of the add-on's own empty
# directories runs. Before the ledger copy goes, a durable token outside the
# state (beside the discard records) names them; a re-run with that token
# and no ledger removes exactly them and succeeds, a host with neither is
# refused as before with nothing touched, and a directory that was a
# pre-bootstrap root is never removed. The failing rmdir is reported
# precisely: its errno and cause, what remains, and never "everything is
# gone" when the directory still holds something.
#
# A parent directory without write permission stands for an immutable
# /var/lib or a mount point (the tests run without root). The real
# removal, the real token and the real re-run (through
# ``runAddonUninstall``, whose host lock a process without root does not
# take) otherwise. Falsifiers ``empty-state-root-reported-vaguely``,
# ``empty-state-root-left-unfinished``, ``state-removal-rerun-unwired``,
# ``state-removal-token-not-required`` and ``pre-bootstrap-root-rmdir``.
# ---------------------------------------------------------------------------

proc v2Scene(name: string): tuple[parent, st, lc, token: string] =
  let parent = getTempDir() / ("repro-uninstall-v2-" & name & "-" &
                               $getCurrentProcessId())
  if dirExists(parent):
    for d in [parent, parent / "var-lib-repro", parent / "var-lib-repro" / "system"]:
      if dirExists(d):
        setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec})
  removeDir(parent)
  let st = parent / "var-lib-repro"
  createDir(st / "agent")
  createDir(st / "system" / "addon" / "discard-markers")
  writeFile(st / "agent" / "attestation.key", "x")
  let lc = ledgerCopyPath(st / "system")
  writeLedger(lc, Ledger(generation: "g0"))
  createDir(parent / "log")
  (parent, st, lc, parent / "log" / StateRemovalTokenName)

proc leftUnder(d: string): seq[string] =
  for p in walkDirRec(d, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                        pcLinkToDir}):
    result.add(p)

proc rerun(s: tuple[parent, st, lc, token: string]): UninstallResult =
  ## The re-run through the uninstall verb itself, so its wiring is held.
  runAddonUninstall(UninstallOptions(stateDir: s.st / "system",
    stateRoot: s.st, logDir: parentDir(s.token)))

suite "only the add-on's own empty directories follow the ledger copy":
  test "V2: a failed rmdir of the root says what remains, keeps the token, and a re-run finishes":
    let s = v2Scene("finish")
    setFilePermissions(s.parent, {fpUserRead, fpUserExec})
    var r: UninstallResult
    removeStateRoot(r, s.st, s.lc, @[s.st / "ev"], tokenPath = s.token)
    setFilePermissions(s.parent, {fpUserRead, fpUserWrite, fpUserExec})
    checkpoint $r.errors
    check r.errors.len == 1
    check r.errors.len == 1 and r.errors[0].startsWith(s.st & ": rmdir failed")
    check r.errors.len == 1 and
      ("the directory " & s.st & " remains, empty of") in r.errors[0]
    check r.errors.len == 1 and " remains, " in r.errors[0] and
      " remain, " notin r.errors[0]
    check s.st notin r.removed
    check dirExists(s.st) and leftUnder(s.st).len == 0
    check not fileExists(s.lc)
    check fileExists(s.token)
    let again = rerun(s)
    checkpoint $again.errors
    check again.errors.len == 0
    check not dirExists(s.st)
    check not fileExists(s.token)
    check again.removed == @[s.st & " (left by an earlier uninstall)"]

  test "a failed rmdir of an intermediate directory names it and both that remain":
    let s = v2Scene("intermediate")
    # system/ itself cannot be removed: its parent (the root) is read-only
    # once everything else is gone. A read-only root also refuses agent/'s
    # removal, so agent/ is moved out first: only system/ is left in it.
    moveDir(s.st / "agent", s.parent / "agent-elsewhere")
    setFilePermissions(s.st, {fpUserRead, fpUserExec})
    var r: UninstallResult
    removeStateRoot(r, s.st, s.lc, tokenPath = s.token)
    setFilePermissions(s.st, {fpUserRead, fpUserWrite, fpUserExec})
    checkpoint $r.errors
    let sys = s.st / "system"
    check r.errors.len == 1 and r.errors[0].startsWith(sys & ": rmdir failed")
    check r.errors.len == 1 and
      ("the directories " & sys & ", " & s.st & " remain") in r.errors[0]
    check dirExists(sys) and not fileExists(s.lc) and fileExists(s.token)
    let again = rerun(s)
    check again.errors.len == 0
    check not dirExists(s.st) and not fileExists(s.token)

  test "a directory that is not empty is named, never called empty":
    let s = v2Scene("notempty")
    var r: UninstallResult
    removeStateRoot(r, s.st, s.lc, tokenPath = s.token)
    check r.errors.len == 0 and not dirExists(s.st)
    # A token from a run that stopped, and an entry that appeared since.
    createDir(s.st / "system")
    writeFile(s.st / "system" / "late", "x")
    writeFile(s.token, $(%*{"schema": StateRemovalTokenSchema, "root": s.st,
      "ledgerCopy": s.lc, "chain": [s.st / "system", s.st],
      "preBootstrapRoots": newSeq[string]()}))
    var again: UninstallResult
    check finishEmptyStateRoot(again, s.st, s.lc, s.token)
    checkpoint $again.errors
    check again.errors.len == 1 and
      (s.st / "system" & ": rmdir failed") in again.errors[0]
    check again.errors.len == 1 and "is not empty" in again.errors[0]
    check again.errors.len == 1 and "empty of" notin again.errors[0]
    check fileExists(s.st / "system" / "late") and fileExists(s.token)

  test "a re-run without the token touches nothing and refuses as before":
    let s = v2Scene("notoken")
    # The shape an earlier uninstall leaves when it put the pre-bootstrap
    # directories back, or a host that never had the add-on: empty
    # directories, no ledger, no token.
    removeFile(s.lc)
    removeFile(s.st / "agent" / "attestation.key")
    removeDir(s.st / "system" / "addon")
    var r: UninstallResult
    check not finishEmptyStateRoot(r, s.st, s.lc, s.token)
    check r.errors.len == 0 and r.removed.len == 0
    expect LedgerError:
      discard rerun(s)
    check dirExists(s.st / "system") and dirExists(s.st / "agent")

  test "a pre-bootstrap root is never removed, by the run or by a re-run":
    let s = v2Scene("prebootstrap")
    # /var/lib/repro and agent/ were the host's before the add-on;
    # system/ is the add-on's.
    var r: UninstallResult
    removeStateRoot(r, s.st, s.lc, tokenPath = s.token,
                    preBootstrap = @[s.st, s.st / "agent"])
    checkpoint $r.errors
    check r.errors.len == 0
    check dirExists(s.st)                       # kept
    check not dirExists(s.st / "system")        # the add-on's: removed
    check not fileExists(s.token)
    # A re-run after a failure at system/: the token's chain is system/ only.
    createDir(s.st / "system")
    let chain = stateDirChain(s.st, s.lc, @[s.st, s.st / "agent"])
    check chain == @[s.st / "system"]
    setFilePermissions(s.st, {fpUserRead, fpUserExec})
    var mid: UninstallResult
    writeLedger(s.lc, Ledger(generation: "g0"))
    removeStateRoot(mid, s.st, s.lc, tokenPath = s.token,
                    preBootstrap = @[s.st, s.st / "agent"])
    setFilePermissions(s.st, {fpUserRead, fpUserWrite, fpUserExec})
    check mid.errors.len == 1 and fileExists(s.token)
    let again = rerun(s)
    check again.errors.len == 0
    check dirExists(s.st) and not dirExists(s.st / "system")

# ---------------------------------------------------------------------------
# A11 code review round 15, F2 (§13 decision 166): uninstall never deletes
# or recreates a pre-bootstrap input. The removal of the state keeps every
# input; before the token and the ledger copy, each gets back the mode and
# owner it had before the add-on, in place (fchown, fchmod, fsync); a crash
# at any point leaves the ledger copy (a re-run finishes) or the inputs
# already right. The crash is a test seam (``InputStepHook``) raising a
# ``Defect``-free exception the removal does not catch, as a killed process
# would stop there. Ownership is the test user's own (chown to another id
# needs root); an owner that is no account is uid 4000000.
# Falsifiers ``inputs-removed-and-restored``, ``input-mode-owner-not-
# restored`` and ``input-metadata-after-ledger-copy``.
# ---------------------------------------------------------------------------

type Crash = object of CatchableError

proc inodeOf(p: string): uint64 =
  var st: Stat
  doAssert lstat(p.cstring, st) == 0, p
  uint64(st.st_ino)

proc modeOf(p: string): int =
  var st: Stat
  doAssert lstat(p.cstring, st) == 0, p
  int(st.st_mode) and 0o7777

type InputScene = object
  parent, st, lc, token, agent, key, floor, attest: string
  inputs: seq[PreBootstrapInput]

proc inputScene(name: string): InputScene =
  let s = v2Scene("inputs-" & name)
  result.parent = s.parent
  result.st = s.st
  result.lc = s.lc
  result.token = s.token
  result.agent = s.st / "agent"
  result.attest = s.st / "agent" / "attestation.key"    # the add-on's
  result.key = s.st / "agent" / "recipient.key"         # inputs
  result.floor = s.st / "agent" / "state" / "deploy-agent" / "rpi2.seq"
  createDir(parentDir(result.floor))
  writeFile(result.key, "KEY\n")
  writeFile(result.floor, "12\n")
  setFilePermissions(result.key, {fpUserRead})
  # bootstrap's takeover gave agent/ the add-on's 0700; it was 0750.
  setFilePermissions(result.agent, {fpUserRead, fpUserWrite, fpUserExec})
  let (u, g) = (int(getuid()), int(getgid()))
  result.inputs = @[
    PreBootstrapInput(path: s.st, isDir: true, mode: modeOf(s.st), uid: u, gid: g),
    PreBootstrapInput(path: result.agent, isDir: true, mode: 0o750, uid: u, gid: g),
    PreBootstrapInput(path: result.agent / "state", isDir: true,
                      mode: modeOf(result.agent / "state"), uid: u, gid: g),
    PreBootstrapInput(path: parentDir(result.floor), isDir: true,
                      mode: modeOf(parentDir(result.floor)), uid: u, gid: g),
    PreBootstrapInput(path: result.key, isDir: false, mode: 0o400, uid: u, gid: g),
    PreBootstrapInput(path: result.floor, isDir: false, mode: modeOf(result.floor),
                      uid: u, gid: g)]

proc removeWith(sc: InputScene; r: var UninstallResult;
                hook: InputStepHook = nil) =
  removeStateRoot(r, sc.st, sc.lc, tokenPath = sc.token,
                  preBootstrap = inputPaths(sc.inputs), inputs = sc.inputs,
                  hook = hook)

suite "the pre-bootstrap inputs stay where they are":
  test "inputs are never deleted or recreated, and get their prior mode and owner back":
    let sc = inputScene("stay")
    let before = @[inodeOf(sc.key), inodeOf(sc.floor), inodeOf(sc.agent)]
    var r: UninstallResult
    removeWith(sc, r)
    checkpoint $r.errors
    check r.errors.len == 0
    check fileExists(sc.key) and fileExists(sc.floor)
    check @[inodeOf(sc.key), inodeOf(sc.floor), inodeOf(sc.agent)] == before
    check readFile(sc.key) == "KEY\n" and readFile(sc.floor) == "12\n"
    check modeOf(sc.agent) == 0o750 and modeOf(sc.key) == 0o400
    check not fileExists(sc.attest)                 # the add-on's: gone
    check not dirExists(sc.st / "system")           # the add-on's: gone
    check dirExists(sc.st) and not fileExists(sc.token)

  test "a crash after the ledger copy goes leaves the key and the floor intact":
    let sc = inputScene("crash-after-ledger")
    let before = @[inodeOf(sc.key), inodeOf(sc.floor)]
    var r: UninstallResult
    expect Crash:
      removeWith(sc, r, proc (step, path: string) =
        if step == "ledger-copy-removed": raise newException(Crash, step))
    check not fileExists(sc.lc) and fileExists(sc.token)
    check fileExists(sc.key) and fileExists(sc.floor)
    check @[inodeOf(sc.key), inodeOf(sc.floor)] == before
    check readFile(sc.key) == "KEY\n" and readFile(sc.floor) == "12\n"
    check modeOf(sc.agent) == 0o750                 # already right
    let again = rerun((sc.parent, sc.st, sc.lc, sc.token))
    checkpoint $again.errors
    check again.errors.len == 0
    check readFile(sc.floor) == "12\n" and inodeOf(sc.floor) == before[1]
    check not dirExists(sc.st / "system") and not fileExists(sc.token)

  test "a crash between an input's chown and its chmod is finished by the re-run":
    let sc = inputScene("crash-chown")
    var r: UninstallResult
    expect Crash:
      removeWith(sc, r, proc (step, path: string) =
        if step == "chowned" and path == sc.agent:
          raise newException(Crash, step))
    check fileExists(sc.lc)                         # the re-run resumes
    check modeOf(sc.agent) == 0o700                 # the chmod never ran
    var again: UninstallResult
    removeWith(sc, again)
    checkpoint $again.errors
    check again.errors.len == 0
    check modeOf(sc.agent) == 0o750
    check not fileExists(sc.lc) and readFile(sc.floor) == "12\n"

  test "an input that is gone is a note, never recreated":
    let sc = inputScene("gone")
    removeFile(sc.floor)
    var r: UninstallResult
    removeWith(sc, r)
    check r.errors.len == 0
    check not fileExists(sc.floor)
    check r.notes.anyIt(it.startsWith(sc.floor & ": a pre-bootstrap input " &
      "that is not on the host now"))

  test "the other roots keep their inputs: /etc/repro's signers file, the store directories":
    let base = getTempDir() / ("repro-uninstall-roots-" & $getCurrentProcessId())
    removeDir(base)
    let etc = base / "etc-repro"
    createDir(etc / "anchors")
    writeFile(etc / "deploy-manifest-allowed-signers", "signer\n")
    writeFile(etc / "anchors" / "cache.pub", "x")       # the add-on's
    let signersIno = inodeOf(etc / "deploy-manifest-allowed-signers")
    var r: UninstallResult
    removeRootKeepingInputs(r, etc, @[etc, etc / "deploy-manifest-allowed-signers"])
    check r.errors.len == 0
    check dirExists(etc) and not dirExists(etc / "anchors")
    check inodeOf(etc / "deploy-manifest-allowed-signers") == signersIno
    let repro = base / "repro"
    createDir(repro / "store" / "prefixes" / "x")
    writeFile(repro / "store" / "prefixes" / "x" / "f", "y")
    writeFile(repro / "gc-roots", "z")
    removeAllBelowKeeping(repro, @[repro, repro / "store"])
    check dirExists(repro / "store") and not dirExists(repro / "store" / "prefixes")
    check not fileExists(repro / "gc-roots")
    var gone: UninstallResult
    removeRootKeepingInputs(gone, base / "run-repro-absent", @[])
    check gone.errors.len == 0
    removeDir(base)

# ---------------------------------------------------------------------------
# A11 code review round 16: the pre-bootstrap inputs left in place (§13
# decisions 166 amended, 167, 168; R16-1, R16-2,
# R16-3, R16-5, R16-6). Falsifiers ``unmarked-prior-trusted``,
# ``new-floors-removed``, ``etc-sweep-rewrites-inputs``,
# ``run-repro-rewrites-inputs``, ``store-remover-rewrites-inputs`` and
# ``token-dir-unchecked``; the bootstrap and step-4 halves
# (``prior-mode-captured-after-takeover``, ``etc-input-rewritten-in-step-4``)
# need root and a real host, and are held by the byte-identity VM gate.
# ---------------------------------------------------------------------------

suite "round 16":
  test "R16-6: a recorded prior owner that is not root's is a corrupt ledger":
    let e = LedgerEntry(class: lcRoot, path: "/var/lib/repro/agent",
      mode: "0700", owner: "0:0", replaced: "dir 0750 1000:1000",
      collision: "adopt", observation: PriorCapturedBeforeTakeover)
    let pb = preBootstrapInputs(Ledger(entries: @[e]))
    check pb.inputs.len == 0
    check pb.errors.len == 1 and "the ledger is corrupt" in pb.errors[0]

  test "R16-1: an unmarked takeover root of the four keeps the recorded mode, and says so":
    let unmarked = LedgerEntry(class: lcRoot, path: AgentStateRecordsDir,
      mode: "0700", owner: "0:0", replaced: "dir 0700 0:0", collision: "adopt")
    var marked = unmarked
    marked.observation = PriorCapturedBeforeTakeover
    let established = LedgerEntry(class: lcRoot, path: "/var/lib/repro/agent",
      mode: "0700", owner: "0:0", replaced: "dir 0750 0:0", collision: "adopt")
    let a = preBootstrapInputs(Ledger(entries: @[unmarked, established]))
    check a.errors.len == 0 and a.inputs.len == 2
    check a.inputs[0].mode == 0o700 and a.inputs[1].mode == 0o750
    check a.notes.len == 1 and a.notes[0].startsWith(AgentStateRecordsDir &
      ": its mode before the add-on was not captured")
    let b = preBootstrapInputs(Ledger(entries: @[marked]))
    check b.notes.len == 0

  test "R16-2: with the key kept, every floor stays, a later one too":
    let sc = inputScene("floors")
    let records = parentDir(sc.floor)
    writeFile(records / "rpi3.seq", "41\n")      # the add-on's agent wrote it
    writeFile(records / "rpi2.last-tick.json", "{}")
    let floors = keptFloors(sc.inputs, keyPath = sc.key, recordsDir = records)
    check (records / "rpi3.seq") in floors and sc.floor in floors
    var r: UninstallResult
    removeStateRoot(r, sc.st, sc.lc, tokenPath = sc.token,
                    preBootstrap = inputPaths(sc.inputs) & floors,
                    inputs = sc.inputs)
    checkpoint $r.errors
    check r.errors.len == 0
    check readFile(records / "rpi3.seq") == "41\n"
    check not fileExists(records / "rpi2.last-tick.json")   # not a floor
    let noKey = sc.inputs.filterIt(it.path != sc.key)
    check keptFloors(noKey, keyPath = sc.key, recordsDir = records).len == 0

  test "R16-3: each removal site keeps its inputs' inodes":
    let base = getTempDir() / ("repro-uninstall-sites-" & $getCurrentProcessId())
    removeDir(base)
    for site in ["etc", "run", "store"]:
      let d = base / site
      createDir(d / "input-dir")
      writeFile(d / "input-file", "kept\n")
      writeFile(d / "addon-file", "x")
      createDir(d / "addon-dir")
      let keep = @[d, d / "input-dir", d / "input-file"]
      let ino = @[inodeOf(d / "input-dir"), inodeOf(d / "input-file")]
      keepingRemoval(d, keep, site)
      checkpoint site
      check not fileExists(d / "addon-file") and not dirExists(d / "addon-dir")
      check fileExists(d / "input-file") and dirExists(d / "input-dir")
      check @[inodeOf(d / "input-dir"), inodeOf(d / "input-file")] == ino
    removeDir(base)

  test "R16-5: the token is never written to, or read from, a directory others can write":
    let sc = inputScene("tokendir")
    setFilePermissions(parentDir(sc.token), {fpUserRead, fpUserWrite,
      fpUserExec, fpGroupWrite, fpGroupRead, fpGroupExec})
    var r: UninstallResult
    removeWith(sc, r)
    checkpoint $r.errors
    check r.errors.len == 1 and "writable by its group" in r.errors[0]
    check fileExists(sc.lc) and not fileExists(sc.token)
    # A token planted there is not acted on.
    removeFile(sc.lc)
    writeFile(sc.token, $(%*{"schema": StateRemovalTokenSchema, "root": sc.st,
      "ledgerCopy": sc.lc, "chain": [sc.st / "system"],
      "preBootstrapRoots": newSeq[string]()}))
    var again: UninstallResult
    check finishEmptyStateRoot(again, sc.st, sc.lc, sc.token)
    check again.errors.len == 1 and "may not be trusted" in again.errors[0]
    check dirExists(sc.st / "system")
    setFilePermissions(parentDir(sc.token), {fpUserRead, fpUserWrite, fpUserExec})

  test "R16-5: a stale link at the token's temporary name is not followed":
    let sc = inputScene("tokentmp")
    let victim = sc.parent / "victim"
    writeFile(victim, "untouched\n")
    createSymlink(victim, sc.token & ".tmp")
    var r: UninstallResult
    removeWith(sc, r)
    check r.errors.len == 0
    check readFile(victim) == "untouched\n"
    check not fileExists(sc.token) and not symlinkExists(sc.token & ".tmp")

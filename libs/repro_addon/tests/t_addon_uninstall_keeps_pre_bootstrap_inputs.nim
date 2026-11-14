## Uninstall puts a pre-bootstrap input back exactly as found (ReproOS
## Add-On Mode spec §6.1, §6.4), the deploy agent's live records above
## all: the sequence floor is rewritten at every tick, so it is ledgered
## with its content UNPINNED (``lcKept``), captured before anything is
## removed, and written back byte for byte. A floor that did not survive
## would let a manifest this host already accepted replay on its kept key.
##
## The reviewed defect (R review, item 1): the records were ledgered with
## a content digest, so after the first tick the capture judged them
## drifted and skipped them, the state directory was removed, and nothing
## wrote them back. The falsifier is that classification: ledger the
## bumped record as a content-pinned ``lcEtcFile`` and "a bumped sequence
## floor survives" goes red (run and reverted before this file landed).
##
## No mocks: real files under a temporary root, the uninstall's own
## capture and restore procedures (the host-level verb around them needs
## root and a ledger of a real bootstrap; the VM gates cover that), the
## ledger's own drift check, and the apply planner's own refusal.

import std/[os, posix, strutils, unittest]

import repro_infra
import repro_addon/fingerprint
import repro_addon/[addon_apply, evidence, evidence_ship, ledger, store_root, uninstall]

let me = $getuid() & ":" & $getgid()

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

  test "a bumped sequence floor survives: captured live, put back byte for byte":
    writeFile(seqPath, "12\n")
    let captured = capturePreBootstrapInputs(ledger)
    check captured.drift.len == 0
    check captured.files.len == 1 and captured.files[0].bytes == "12\n"
    removeDir(root / "agent")         # what `removeDir("/var/lib/repro")` does
    check not fileExists(seqPath)
    var r: UninstallResult
    restorePreBootstrapInputs(captured, keepStore = false, r)
    check r.errors == newSeq[string]()
    check readFile(seqPath) == "12\n"
    var st: Stat
    check stat(seqPath.cstring, st) == 0 and (int(st.st_mode) and 0o7777) == 0o600
    check stat((root / "agent").cstring, st) == 0 and
          (int(st.st_mode) and 0o7777) == 0o700

  test "a content-pinned input that changed is drift, not silently put back":
    let signers = root / "signers"
    writeFile(signers, "key\n")
    let pinned = LedgerEntry(class: lcEtcFile, path: signers,
      sha256: sha256Hex("key\n"), mode: "0644", owner: me,
      replaced: "f 0644 " & me & " sha256:" & sha256Hex("key\n"),
      collision: "adopt")
    writeFile(signers, "other key\n")
    let captured = capturePreBootstrapInputs(Ledger(entries: @[pinned]))
    check captured.files.len == 0
    check captured.drift.len == 1 and "content changed" in captured.drift[0]

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

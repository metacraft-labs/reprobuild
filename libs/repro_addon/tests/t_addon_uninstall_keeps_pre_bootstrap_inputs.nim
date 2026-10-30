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
import repro_addon/[addon_apply, ledger, uninstall]

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

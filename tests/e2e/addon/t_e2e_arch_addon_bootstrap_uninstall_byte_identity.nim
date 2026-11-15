## Gate ``e2e_arch_addon_bootstrap_uninstall_byte_identity`` (spec
## ReproOS-Add-On-Mode §6.2, §6.4, §12.2, §12.5 condition 1).
##
## The Debian gate ``e2e_addon_bootstrap_uninstall_byte_identity``'s sequence on the Arch
## guests: fingerprint the base twice (the determinism guard), preflight,
## bootstrap with the acknowledged digest, apply a generation that adds a
## unit and an ``/etc`` file, apply one that removes the unit and changes
## the file, uninstall, fingerprint again. Every step's fingerprint diff must
## equal the delta the two ledgers account for, and the fingerprints before
## bootstrap and after uninstall must be identical (the add-on creates no
## account; the journal is not fingerprinted; no ``takeOver`` is declared, so
## §6.4's pacman exception does not arise). Each apply runs the pacman
## collision driver, generation 0's included. The fingerprint carries the
## Arch components: ``pacman-local`` and, on the btrfs guest,
## ``btrfs-subvolumes``, which sees ``/repro`` as its own subvolume.
##
## Generation 0 on Arch carries no package-manager hook (spec §6.2, §13
## decision 130): the gate also checks that nothing appeared under
## ``/etc/apt``.
##
## Baseline: before the first fingerprint the gate runs ``udevadm settle``
## and ``systemctl daemon-reload`` in the guest (``settleBaseline``, §12.2,
## §13 decision 134), so units the base's generators emit on a reload are
## in the baseline. Nothing is excluded from the comparison.
##
## Vacuity guards: ``findmnt -no FSTYPE /`` must be ``btrfs`` on the btrfs
## guest and ``ext4`` on the ext4 guest; and the run as a whole must have
## covered a plain Arch guest of each (whatever ``REPRO_ADDON_BASES``
## says), or the gate fails: a run on one placement does not measure the
## other.
##
## Negative control (``REPRO_ADDON_MUTATION=uninstall-keeps-repro-subvolume``):
## uninstall leaves the ``/repro`` subvolume in place, so the gate must go
## red on the btrfs guest with a diff naming it (``btrfs-subvolumes`` and
## ``addon-roots`` records of ``/repro``). The record says which.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64,omarchy-amd64``). On the Omarchy VM
## (the test bed's pinned Omarchy 4.5.0 install) the preflight and bootstrap
## take ``--profile`` with the ``omarchyAccount``, every generation names
## it, an operator apply of an empty profile (which names no account) is
## refused with ``EAddOnBaseLayerOwned`` and changes nothing, and the
## fingerprint also records the account's hook tree (``omarchy-hooks``),
## which must be present and unchanged at the end.
##
## A falsifier run (``REPRO_ADDON_MUTATION``) passes only when every base
## shows the mutation's own red steps and nothing else (``expectedFalsifier``,
## judged by ``arch_gate_support.falsifierVerdict``): only the listed steps
## may be red, the steps that run before and around the mutated code
## (bootstrap, the generation applies, uninstall, ...) must be present and
## green, and an exception or infrastructure failure always fails it. A base
## outside the mutation must stay green. The base's own verdict stays
## ``red`` in its record; the judgement is the record's ``falsifier``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_bootstrap_uninstall_byte_identity``).
##
## *Mocking.* None: the real Arch Linux image, real systemd and pacman, the
## real static add-on binary, real disks.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

proc diffIsExactlyTheReproSubvolume*(diffText: string): bool =
  ## The final diff the negative control must produce, and nothing else:
  ## exactly two records, ``/repro``'s ``addon-roots`` record changed from
  ## ``absent`` to a subvolume, and its ``btrfs-subvolumes`` record added
  ## under the top (``repro``) or Omarchy's ``@`` (``@/repro``).
  var lines: seq[string]
  for l in diffText.splitLines():
    if l.strip().len > 0: lines.add(l)
  if lines.len != 2: return false
  var root, subvolume = false
  for l in lines:
    let f = l.split('\t')
    if f.len != 3: return false
    if f[0] == "~ addon-roots" and f[1] == "/repro" and
        f[2].startsWith("absent => btrfs-subvolume "):
      root = true
    elif f[0] == "+ btrfs-subvolumes" and f[1] in ["repro", "@/repro"] and
        f[2].startsWith("id "):
      subvolume = true
  root and subvolume

static:
  doAssert diffIsExactlyTheReproSubvolume(
    "~ addon-roots\t/repro\tabsent => btrfs-subvolume 0755 0:0\n" &
    "+ btrfs-subvolumes\trepro\tid 259 parent 5\n")
  doAssert diffIsExactlyTheReproSubvolume(
    "~ addon-roots\t/repro\tabsent => btrfs-subvolume 0755 0:0\n" &
    "+ btrfs-subvolumes\t@/repro\tid 265 parent 256\n")
  doAssert not diffIsExactlyTheReproSubvolume(
    "~ addon-roots\t/repro\tabsent => btrfs-subvolume 0755 0:0\n" &
    "+ btrfs-subvolumes\trepro\tid 259 parent 5\n+ etc\t/etc/x\tf\n")
  doAssert not diffIsExactlyTheReproSubvolume(
    "+ btrfs-subvolumes\tnotrepro\tid 259 parent 5\n" &
    "~ addon-roots\t/repro\tabsent => btrfs-subvolume 0755 0:0\n")
  doAssert not diffIsExactlyTheReproSubvolume("fingerprints identical")

proc reproSubvolumeIsTheWholeDiff(record: JsonNode): bool =
  record{"diffNamesReproSubvolume"}.getBool()

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  ## Each negative control's expected red (``falsifierVerdict``): with
  ## bootstrap, both generations and uninstall succeeding, the final diff
  ## is exactly the ``/repro`` subvolume left behind, on a btrfs root; an
  ## ext4 root has no subvolume and stays green.
  case mut
  of "uninstall-keeps-repro-subvolume":
    var runs = @["root filesystem (vacuity guard)",
      "baseline: udevadm settle and systemctl daemon-reload",
      "fingerprint is deterministic", "preflight is compatible",
      "bootstrap", "bootstrap diff == generation 0 ledger",
      "apply generation 1", "generation 1 diff == ledger delta",
      "apply generation 2", "generation 2 diff == ledger delta",
      "uninstall"]
    if isOmarchyBase(b):
      runs.add("an empty operator profile on Omarchy is refused, " &
               "EAddOnBaseLayerOwned")
    if rootIsBtrfs(b):
      Falsifier(required: @["base fingerprint after uninstall == before bootstrap"],
        mustRunGreen: runs,
        recordChecks: @[(name: "the final diff is exactly /repro's addon-roots " &
                           "and btrfs-subvolumes records",
                         check: reproSubvolumeIsTheWholeDiff)])
    else: Falsifier(green: true, mustRunGreen: runs &
      @["base fingerprint after uninstall == before bootstrap"])
  else: raise unknownMutation("e2e_arch_addon_bootstrap_uninstall_byte_identity", mut)

proc runBase(b: BaseImage; record: JsonNode;
             covered: var seq[string]): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let guard = g.vacuityGuardRootFs(b)
    step("root filesystem (vacuity guard)", guard.ok, guard.detail)
    if not guard.ok: return fails
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha

    let account = accountFor(b)
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    sleep(20_000)
    let f0b = g.fingerprintArch(repro, account)
    let det = identityReport(f0, f0b)
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    step("the fingerprint has pacman-local records",
         "\npacman-local\t" in f0,
         (if "\npacman-local\t" in f0: "present" else: "no pacman-local component"))
    if account.len > 0:
      step("the fingerprint has omarchy-hooks records (the real hook tree)",
           hooksRecorded(f0),
           g.run("ls -la ~" & account & "/.config/omarchy/hooks 2>&1"))

    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
    let l0 = g.ledgerOf()
    let f1 = g.fingerprintArch(repro, account)
    let d0 = deltaReport(f0, f1, "", l0)
    step("bootstrap diff == generation 0 ledger", d0.ok, d0.text)
    step("generation 0 wrote nothing under /etc/apt",
         g.exec("test -e /etc/apt").exitCode != 0,
         g.exec("ls -la /etc/apt 2>&1").stdout)
    if rootIsBtrfs(b):
      step("/repro is a btrfs subvolume",
           g.exec("test \"$(stat -c %i /repro)\" = 256").exitCode == 0,
           g.run("stat -c '%i %F' /repro"))

    if account.len > 0:
      # An operator apply of an empty profile names no omarchyAccount, so
      # the account check refuses it (spec §4.3.2, §8.5; §13 decision 131:
      # only generation 0, a replay or a revert is exempt), and it changes
      # nothing.
      let empty = g.applyProfile(repro, "empty-operator", "")
      let said = empty.stdout & empty.stderr
      record["emptyOperatorProfile"] = %said
      step("an empty operator profile on Omarchy is refused, " &
           "EAddOnBaseLayerOwned", empty.exitCode != 0 and
             "EAddOnBaseLayerOwned" in said,
           "exit " & $empty.exitCode & "\n" & said)
      let same = identityReport(f1, g.fingerprintArch(repro, account))
      step("the refused empty profile changed nothing", same.ok, same.text)
      step("the refused empty profile left the ledger as it was",
           g.ledgerOf() == l0, "")

    let exe = g.gen0ReproExe()
    let a1 = g.applyProfile(repro, "gen1", gen1Profile(exe, account))
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    let l1 = g.ledgerOf()
    let f2 = g.fingerprintArch(repro, account)
    let d1 = deltaReport(f1, f2, l0, l1)
    step("generation 1 diff == ledger delta", d1.ok, d1.text)
    step("the fixture unit is active",
         g.exec("systemctl is-active " & FixtureUnitName).exitCode == 0,
         g.exec("systemctl status --no-pager " & FixtureUnitName).stdout)

    let a2 = g.applyProfile(repro, "gen2", gen2Profile(account))
    step("apply generation 2", a2.exitCode == 0, a2.stdout & a2.stderr)
    if a2.exitCode != 0: return fails
    let l2 = g.ledgerOf()
    let f3 = g.fingerprintArch(repro, account)
    let d2 = deltaReport(f2, f3, l1, l2)
    step("generation 2 diff == ledger delta", d2.ok, d2.text)

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let f4 = g.fingerprintArch(repro, account)
    let ident = identityReport(f0, f4)
    record["finalDiff"] = %ident.text
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)
    if not isOmarchyBase(b):
      covered.add(g.rootFsType())
    if not ident.ok and rootIsBtrfs(b):
      record["diffNamesReproSubvolume"] =
        %diffIsExactlyTheReproSubvolume(ident.text)
    for (n, t) in [("f0", f0), ("f1", f1), ("f2", f2), ("f3", f3), ("f4", f4),
                   ("l0", l0), ("l1", l1), ("l2", l2)]:
      writeFile(g.runDir / (n & ".txt"), t)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_arch_addon_bootstrap_uninstall_byte_identity":
  test "bootstrap, two generations and uninstall leave each Arch base byte-identical":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_addon_bootstrap_uninstall_byte_identity)")
    else:
      var failures: seq[string]
      var covered: seq[string]
      for b in selectedArchBases():
        let record = archGateRecord("e2e_arch_addon_bootstrap_uninstall_byte_identity")
        record["base"] = %b.name
        if isOmarchyBase(b): record["omarchy"] = omarchyRecordBase()
        let f = runBase(b, record, covered)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun("e2e_arch_addon_bootstrap_uninstall_byte_identity", record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(
          "e2e_arch_addon_bootstrap_uninstall_byte_identity", record)
        failures.add(judged)
      # The per-run vacuity guard: a plain Arch guest on each root
      # filesystem ran the sequence to its end.
      for fs in ["btrfs", "ext4"]:
        if fs notin covered:
          failures.add("vacuity guard: the run covered no plain Arch guest " &
            "with a " & fs & " root (covered: " & covered.join(",") & ")")
      for f in failures: echo "FAIL ", f
      check failures.len == 0

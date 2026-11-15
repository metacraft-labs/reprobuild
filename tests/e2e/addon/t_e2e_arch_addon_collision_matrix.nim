## Gate ``e2e_arch_addon_collision_matrix`` (spec ReproOS-Add-On-Mode §4.3,
## §4.3.1, §8.4, §12.5 condition 1; §13 decisions 99 and 108).
##
## One fixture per row of the decision table on each plain Arch guest, with
## the pacman collision driver deciding: each default refusal exits 2 with
## its diagnostic and writes nothing (the fingerprint is unchanged, the
## ledger and the preserved bytes too); each apply's fingerprint diff equals
## exactly the delta the two ledgers account for.
##
## The §4.3 rows:
##
## - **absent, unowned**: created; applied again, a no-op; changed in the
##   profile, an update.
## - **owned, changed out of band to the desired bytes**: a no-op reported
##   ``accepted-out-of-band``.
## - **owned, changed out of band to other bytes**: ``EDrift``.
## - **present, unowned, identical**: adopted without a write.
## - **present, unowned, different**: ``EDrift``.
## - **package unit** (``fixture-pkg.service``, shipped by the fixture
##   package under ``/usr/lib/systemd/system``): ``EAddOnUnitShadows``;
##   ``collision = "dropIn"`` writes a drop-in systemd lists in
##   ``DropInPaths``.
## - **unit in /etc/systemd/system the ledger does not list**
##   (``fixture-hand.service``, written before the baseline): ``EDrift``.
## - **existing diversion by someone else**: does not arise -- pacman has no
##   diversions (§4.3.1 item 2); the ``divert`` row below stands in for it.
## - **sysctl key assigned by a later base fragment**
##   (``/etc/sysctl.d/99-repro-fx-base.conf``): refused, naming the file.
##
## The §4.3.1 rows:
##
## - **a non-backup package file** (``/etc/repro-fx-matrix/plain.conf``):
##   ``EAddOnPackageOwned`` naming the package and the drop-in directory
##   beside it, with and without ``collision = "takeOver"``. The profile
##   declares the packaged bytes themselves, so an observer that missed the
##   package would adopt the file silently.
## - **a backup file** (``/etc/avahi/avahi-daemon.conf`` of ``avahi``):
##   without the opt-in ``EAddOnPackageOwned`` naming ``takeOver`` (never
##   ``divert``); with ``collision = "takeOver"`` exactly its ledger entry
##   (``collision takeOver``, observation ``backup:avahi``, the packaged
##   bytes preserved), materialised as a copy. Its removal at the end puts
##   the packaged bytes back (``pacman -Qkk avahi`` clean).
## - **a backup file pacman reports [missing]** and **one it reports
##   [modified]** (two backup files of the fixture package, deleted and
##   edited after its install): ``takeOver`` refused at plan time with
##   ``EAddOnPackageOwned`` naming the file.
## - **divert**: ``EAddOnOutOfScope`` naming "`divert` is unavailable on
##   Arch".
##
## At the end every resource leaves the profile, the add-on is uninstalled,
## and the fingerprint equals the baseline's.
##
## Fixtures, installed before the baseline: ``avahi`` from the guest's
## pinned archive, and the ``makepkg`` package ``repro-fx-matrix``
## (``arch_fixture_packages``) with its two backup files put in the
## ``[missing]`` and ``[modified]`` states.
##
## Falsifying mutations:
##
## - ``REPRO_ADDON_MUTATION=observer-ignores-backup``: no backup file is
##   seen, so the ``takeOver`` row is refused and turns the gate red.
## - ``REPRO_ADDON_MUTATION=observer-never-package-owned``: no path is
##   package-owned, so the non-backup row is let through (the packaged bytes
##   are adopted, exit 0) and turns the gate red.
##
## Each is judged by ``arch_gate_support.falsifierVerdict``: only the
## listed steps may be red, and bootstrap, the rows that do not depend on
## package ownership, and uninstall must be present and green.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_addon_collision_matrix``).
##
## *Mocking.* None: real Arch guests, real pacman, makepkg and systemd, the
## real static add-on binary.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger, md5_hex]

import ./arch_fixture_packages
import ./arch_gate_support

const
  Gate = "e2e_arch_addon_collision_matrix"
  Own = "/etc/repro-fx-own"
  Pkg = "/etc/repro-fx-matrix"
  Avahi = "/etc/avahi/avahi-daemon.conf"
  PlainBytes = "# a plain package file\nplain = yes\n"
  HandUnit = "fixture-hand.service"
  PkgUnit = "fixture-pkg.service"
  BaseSysctl = "/etc/sysctl.d/99-repro-fx-base.conf"
  AddOnAvahi = "[server]\nallow-interfaces=eth0\nuse-ipv4=yes\n"

proc q(s: string): string =
  ## A profile string literal. The profile text takes a value's newlines
  ## as they are (no escapes), so the fixtures hold no quote or backslash.
  doAssert '"' notin s and '\\' notin s, "a fixture value needs no escaping: " & s
  "\"" & s & "\""

proc stanza(): string =
  "addOn {\n  managedEtcPrefixes = [\"" & Own & "/\", \"" & Pkg & "/\", " &
    "\"/etc/avahi/\"]\n}\n"

proc fileRes(path, content: string; collision = ""): string =
  "\nfs.systemFile {\n  path = " & q(path) & "\n  content = " & q(content) &
    "\n" & (if collision.len > 0: "  collision = " & q(collision) & "\n" else: "") &
    "}\n"

proc unitRes(name, content: string; collision = ""): string =
  "\nsystemd.systemUnit {\n  floorExceptions = [\"serviceFloor: a test " &
    "fixture that runs the base's own binaries\"]\n  name = " & q(name) &
    "\n  content = " & q(content) &
    "\n" & (if collision.len > 0: "  collision = " & q(collision) & "\n" else: "") &
    "}\n"

proc matrixPackage(): ArchFixturePackage =
  ArchFixturePackage(name: "repro-fx-matrix", pkgver: "1", pkgrel: "1",
    files: @[fxFile(Pkg & "/plain.conf", PlainBytes),
             fxFile(Pkg & "/plain.conf.d/README", "drop-ins go here\n"),
             fxFile(Pkg & "/missing.conf", "missing = no\n", backup = true),
             fxFile(Pkg & "/modified.conf", "modified = no\n", backup = true),
             fxFile("/usr/lib/systemd/system/" & PkgUnit,
               "[Unit]\nDescription=fixture package unit\n\n[Service]\n" &
               "Type=oneshot\nExecStart=/usr/bin/true\n")])

proc entriesAt(ledgerText, path: string): seq[LedgerEntry] =
  for e in parseLedger(ledgerText).entries:
    if e.path == path: result.add(e)

const
  # The rows whose outcome depends on the observer seeing packages.
  PackageRows = ["plain-file", "plain-file-takeover", "backup-no-opt-in",
                 "takeover", "missing-backup", "modified-backup",
                 "package-unit", "package-unit-dropin"]

proc rowSteps(row: string): seq[string] =
  ## Every step name a row records (``refused`` and ``applied`` below).
  @[row & ": the refused apply kept no preserved bytes",
    row & ": refused", row & ": the refused apply wrote nothing",
    row & ": applied", row & ": fingerprint diff == ledger delta"]

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  let common = @["baseline: udevadm settle and systemctl daemon-reload",
    "fingerprint is deterministic", "preflight is compatible", "bootstrap",
    "create: applied", "create: fingerprint diff == ledger delta",
    "no-op: reported as a no-op", "update: applied",
    "update: fingerprint diff == ledger delta",
    "accepted-out-of-band: applied", "accepted-out-of-band: reported",
    "owned-drift: refused", "owned-drift: the refused apply wrote nothing",
    "owned-drift-reconciled: applied",
    "adopt-identical: applied", "adopt-identical: fingerprint diff == ledger delta",
    "unowned-differs: refused", "unowned-differs: the refused apply wrote nothing",
    "divert: refused", "divert: the refused apply wrote nothing",
    "hand-unit: refused", "hand-unit: the refused apply wrote nothing",
    "sysctl-later-fragment: refused",
    "sysctl-later-fragment: the refused apply wrote nothing",
    "uninstall"]
  case mut
  of "observer-ignores-backup":
    var may: seq[string]
    for r in ["backup-no-opt-in", "takeover", "missing-backup",
              "modified-backup"]:
      may.add(rowSteps(r))
    may.add(@["takeover: one ledger entry, takeOver of backup:avahi, its packaged bytes preserved",
              "takeover: a copy holding the add-on's bytes",
              "removal: every resource leaves the profile",
              "removal: fingerprint diff == ledger delta"])
    Falsifier(required: @["takeover: applied"], mayBeRed: may,
      mustRunGreen: common & @["plain-file: refused",
        "plain-file: the refused apply wrote nothing",
        "package-unit: refused", "package-unit-dropin: applied"])
  of "observer-never-package-owned":
    var may: seq[string]
    for r in PackageRows: may.add(rowSteps(r))
    may.add(@["takeover: one ledger entry, takeOver of backup:avahi, its packaged bytes preserved",
              "takeover: a copy holding the add-on's bytes",
              "package-unit-dropin: systemd lists the drop-in",
              "removal: every resource leaves the profile",
              "removal: fingerprint diff == ledger delta",
              "removal: avahi-daemon.conf holds the packaged bytes again, pacman -Qkk clean",
              "base fingerprint after uninstall == before bootstrap"])
    Falsifier(required: @["plain-file: refused",
                          "plain-file: the refused apply wrote nothing"],
      mayBeRed: may, mustRunGreen: common)
  else: raise unknownMutation(Gate, mut)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
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
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha

    # The fixtures, part of the base.
    let av = g.exec("pacman -Sy --noconfirm --needed avahi 2>&1", timeoutSec = 1800)
    if av.exitCode != 0:
      raise newException(TestBedError, "installing avahi from the pinned " &
        "archive failed: " & av.stdout & av.stderr)
    g.installMakepkgPrerequisites()
    let pkgFile = g.buildArchFixture(matrixPackage())
    let inst = g.pacmanInstall(pkgFile)
    if inst.exitCode != 0:
      raise newException(TestBedError, "installing repro-fx-matrix failed: " &
        inst.stdout & inst.stderr)
    discard g.run("set -e; rm " & Pkg & "/missing.conf; " &
      "printf 'modified = yes\\n' > " & Pkg & "/modified.conf; " &
      "mkdir -p " & Own & "; printf 'same\\n' > " & Own & "/same.conf; " &
      "printf 'hand\\n' > " & Own & "/diff.conf; " &
      "printf '[Service]\\nType=oneshot\\nExecStart=/usr/bin/true\\n' > " &
        "/etc/systemd/system/" & HandUnit & "; " &
      "printf 'vm.swappiness = 61\\n' > " & BaseSysctl & "; " &
      "systemctl daemon-reload")
    record["avahiVersion"] = %g.run("pacman -Q avahi").strip()
    record["avahiBackupMd5"] = %g.backupMd5InDb("avahi", Avahi)
    step("vacuity guard: avahi-daemon.conf is a backup file of avahi, unmodified",
         g.backupMd5InDb("avahi", Avahi).len == 32 and
           g.md5InGuest(Avahi) == g.backupMd5InDb("avahi", Avahi),
         g.run("pacman -Qii avahi | sed -n '/Backup Files/,$p'"))
    step("vacuity guard: the fixture's backup files are [missing] and [modified]",
         "[missing]" in g.run("pacman -Qii repro-fx-matrix") and
           "[modified]" in g.run("pacman -Qii repro-fx-matrix"),
         g.run("pacman -Qii repro-fx-matrix | sed -n '/Backup Files/,$p'"))

    g.settleBaseline(step)
    let fBase = g.fingerprintArch(repro)
    sleep(20_000)
    let det = identityReport(fBase, g.fingerprintArch(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if not g.bootstrapArch(repro, step).ok: return fails
    var f = g.fingerprintArch(repro)
    var l = g.ledgerOf()
    var kept = stanza()     # the resources applied so far, every profile's base

    proc preservedListing(): string =
      g.run("ls -A /var/lib/repro/system/addon/preserved 2>/dev/null; true")

    proc refused(row, extra: string; needles: openArray[string]) =
      ## A default refusal: exit 2, the needles in its output, nothing
      ## written -- not even preserved bytes.
      # Judged against the host as it is right before this apply, so a row
      # an earlier (falsified) row let through cannot spill into this one.
      let before = g.fingerprintArch(repro)
      let ledgerBefore = g.ledgerOf()
      let pres = preservedListing()
      let r = g.applyProfile(repro, row, kept & extra)
      let said = r.stdout & r.stderr
      step(row & ": the refused apply kept no preserved bytes",
           preservedListing() == pres, pres & " -> " & preservedListing())
      var named = r.exitCode == 2
      for n in needles: named = named and n in said
      step(row & ": refused", named,
           "exit " & $r.exitCode & ", expected " & needles.join(", ") & "\n" & said)
      let same = identityReport(before, g.fingerprintArch(repro))
      step(row & ": the refused apply wrote nothing",
           same.ok and g.ledgerOf() == ledgerBefore, same.text)

    proc applied(row, extra: string; flags = ""): string =
      ## An apply that must succeed, its diff equal to the ledger delta; the
      ## resources it added stay in every later profile.
      let r = g.applyProfile(repro, row, kept & extra, flags)
      result = r.stdout & r.stderr
      step(row & ": applied", r.exitCode == 0, result)
      let after = g.fingerprintArch(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step(row & ": fingerprint diff == ledger delta", d.ok, d.text)
      f = after
      l = l2
      if r.exitCode == 0: kept.add(extra)

    # --- The §4.3 rows on unowned and owned paths.
    discard applied("create", fileRes(Own & "/new.conf", "v1\n"))
    block:
      let r = g.applyProfile(repro, "no-op", kept)
      step("no-op: reported as a no-op", r.exitCode == 0 and
           "no-op\t" & Own & "/new.conf" in r.stdout, r.stdout & r.stderr)
    kept = kept.replace(fileRes(Own & "/new.conf", "v1\n"), "")
    discard applied("update", fileRes(Own & "/new.conf", "v2\n"))
    # Out of band to exactly the next desired bytes: accepted.
    discard g.run("rm " & Own & "/new.conf && printf 'v3\\n' > " & Own & "/new.conf")
    block:
      kept = kept.replace(fileRes(Own & "/new.conf", "v2\n"), "")
      let r = g.applyProfile(repro, "accepted-out-of-band",
                             kept & fileRes(Own & "/new.conf", "v3\n"))
      let said = r.stdout & r.stderr
      step("accepted-out-of-band: applied", r.exitCode == 0, said)
      step("accepted-out-of-band: reported",
           "accepted-out-of-band\t" & Own & "/new.conf" in said, said)
      kept.add(fileRes(Own & "/new.conf", "v3\n"))
      f = g.fingerprintArch(repro)
      l = g.ledgerOf()
    # Out of band to other bytes: drift, refused.
    discard g.run("printf 'v3-hand\\n' > " & Own & "/new.conf")
    f = g.fingerprintArch(repro)
    block:
      let r = g.applyProfile(repro, "owned-drift", kept)
      let said = r.stdout & r.stderr
      step("owned-drift: refused", r.exitCode == 2 and "EDrift" in said and
           Own & "/new.conf" in said, "exit " & $r.exitCode & "\n" & said)
      let same = identityReport(f, g.fingerprintArch(repro))
      step("owned-drift: the refused apply wrote nothing",
           same.ok and g.ledgerOf() == l, same.text)
      let rc = g.applyProfile(repro, "owned-drift-reconciled", kept,
                              " --reconcile-drift")
      step("owned-drift-reconciled: applied", rc.exitCode == 0,
           rc.stdout & rc.stderr)
      f = g.fingerprintArch(repro)
      l = g.ledgerOf()
    discard applied("adopt-identical", fileRes(Own & "/same.conf", "same\n"))
    refused("unowned-differs", fileRes(Own & "/diff.conf", "other\n"),
            ["EDrift", Own & "/diff.conf"])

    # --- The §4.3.1 rows.
    refused("plain-file", fileRes(Pkg & "/plain.conf", PlainBytes),
            ["EAddOnPackageOwned", "repro-fx-matrix", "not a backup file",
             Pkg & "/plain.conf.d/"])
    refused("plain-file-takeover", fileRes(Pkg & "/plain.conf", "x\n", "takeOver"),
            ["EAddOnPackageOwned", "repro-fx-matrix", "not a backup file"])
    refused("backup-no-opt-in", fileRes(Avahi, AddOnAvahi),
            ["EAddOnPackageOwned", "avahi", "backup file", "takeOver"])
    block:
      let said = applied("takeover", fileRes(Avahi, AddOnAvahi, "takeOver"))
      let es = entriesAt(l, Avahi)
      let detail = said & "\n" & $es.len & " entries" &
        (if es.len > 0: ": collision " & es[0].collision & ", observation " &
           es[0].observation & ", form " & es[0].form & ", preserved " &
           es[0].preserved else: "")
      var preservedMd5 = ""
      if es.len == 1 and es[0].preserved.len > 0:
        preservedMd5 = g.md5InGuest(es[0].preserved)
      step("takeover: one ledger entry, takeOver of backup:avahi, its packaged bytes preserved",
           es.len == 1 and es[0].collision == "takeOver" and
             es[0].observation == "backup:avahi" and
             preservedMd5 == g.backupMd5InDb("avahi", Avahi),
           detail & "\npreserved MD5 " & preservedMd5)
      step("takeover: a copy holding the add-on's bytes",
           es.len == 1 and not es[0].isLink and
             g.sha256InGuest(Avahi) == sha256Hex(AddOnAvahi),
           g.run("ls -la " & Avahi))
    refused("missing-backup", fileRes(Pkg & "/missing.conf", "y\n", "takeOver"),
            ["EAddOnPackageOwned", Pkg & "/missing.conf", "[missing]"])
    refused("modified-backup", fileRes(Pkg & "/modified.conf", "y\n", "takeOver"),
            ["EAddOnPackageOwned", Pkg & "/modified.conf", "[modified]"])
    refused("divert", fileRes(Pkg & "/plain.conf", "y\n", "divert"),
            ["EAddOnOutOfScope", "`divert` is unavailable on Arch"])

    # --- Units and sysctl.
    let unitBody = "[Service]\nType=oneshot\nExecStart=/usr/bin/true\n" &
      "RemainAfterExit=yes\n"
    refused("package-unit", unitRes(PkgUnit, unitBody),
            ["EAddOnUnitShadows", "/usr/lib/systemd/system/" & PkgUnit])
    block:
      discard applied("package-unit-dropin",
        unitRes(PkgUnit, "[Service]\nEnvironment=REPRO_FX=1\n", "dropIn"))
      step("package-unit-dropin: systemd lists the drop-in",
           "/etc/systemd/system/" & PkgUnit & ".d/50-repro-addon.conf" in
             g.run("systemctl show -p DropInPaths " & PkgUnit),
           g.run("systemctl show -p DropInPaths -p FragmentPath " & PkgUnit))
    refused("hand-unit", unitRes(HandUnit, unitBody), ["EDrift", HandUnit])
    refused("sysctl-later-fragment",
            "\nlinux.sysctl {\n  key = \"vm.swappiness\"\n  value = \"10\"\n}\n",
            [BaseSysctl, "61"])

    # --- Everything leaves the profile; the take-over goes back.
    block:
      let r = g.applyProfile(repro, "removal", stanza())
      step("removal: every resource leaves the profile", r.exitCode == 0,
           r.stdout & r.stderr)
      let after = g.fingerprintArch(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step("removal: fingerprint diff == ledger delta", d.ok, d.text)
      let qkk = g.pacmanQkkClean("avahi")
      step("removal: avahi-daemon.conf holds the packaged bytes again, pacman -Qkk clean",
           g.md5InGuest(Avahi) == g.backupMd5InDb("avahi", Avahi) and qkk.ok,
           qkk.output)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let ident = identityReport(fBase, g.fingerprintArch(repro))
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)
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

suite Gate:
  test "one fixture per row of the decision table, on Arch":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the plain Arch guests")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        record["notApplicable"] = %["existing diversion by someone else: " &
          "pacman has no diversions (spec §4.3.1 item 2); the divert row " &
          "covers it"]
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(Gate, record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

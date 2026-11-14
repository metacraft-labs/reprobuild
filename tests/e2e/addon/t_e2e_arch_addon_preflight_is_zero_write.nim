## Gate ``e2e_arch_addon_preflight_is_zero_write`` (spec ReproOS-Add-On-Mode
## §6.1, §12.5 condition 1).
##
## A2's ``e2e_addon_preflight_is_zero_write`` on the Arch guests:
##
## 1. **zero write**: the prepared guest is shut down and its qcow2 overlay
##    hashed; it boots again with the disk write-protected below it (QEMU
##    ``readonly=on``), the add-on binary is copied to a tmpfs and verified,
##    the preflight runs and must be compatible; after shutdown the qcow2
##    must be byte-identical.
## 2. **vacuity guard**: the read-write preflight must print the same plan
##    digest, and on the read-write disk no file on the root filesystem may
##    be newer than a marker taken just before it ran (the leg that catches
##    a write the read-only disk only made fail).
## 3. **the Arch base rule**: the plan accepts ``ID=arch`` (the guests) and,
##    with ``os-release`` rewritten to Omarchy's ``ID=omarchy`` /
##    ``ID_LIKE=arch``, still passes the ``distribution`` check (and asks
##    for ``--profile``, because the Omarchy account cannot be checked
##    without the profile). The Arch plan records ``base.pacman``,
##    ``base.networkManager`` and ``rootFilesystem.snapper``.
## 3b. **on the Omarchy VM** (the test bed's pinned Omarchy 4.5.0 install,
##    ``ID=omarchy`` / ``ID_LIKE=arch`` as installed): the read-only and the
##    read-write runs take ``--profile`` naming ``omarchyAccount``; the plan
##    records Omarchy's ``VERSION_ID``, ``BUILD_ID`` and the ``omarchy``
##    package's version, which must equal what ``omarchy-version`` prints;
##    without ``--profile``, with a profile naming no account, and with an
##    account the password database does not know, the ``omarchy-account``
##    check fails with ``EAddOnBaseLayerOwned``; with the account's hook
##    directory moved away it fails naming the directory. On a plain Arch
##    guest a profile naming an ``omarchyAccount`` fails with
##    ``EAddOnOutOfScope``.
## 4. **an archive date below the matrix**: on ``arch-old-systemd-amd64``
##    (pacman pinned to an Arch Linux Archive date whose systemd major is
##    257) the preflight refuses with the ``distribution`` check failed,
##    naming systemd below 258 -- the ``EAddOnUnsupportedBase`` condition
##    (spec §8.4), which bootstrap and every apply then raise -- and writes
##    nothing there either.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=preflight-writes``): a
## preflight that writes under ``/var/lib`` and swallows the error; step 2's
## marker leg must turn red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_addon_preflight_is_zero_write``).
## Bases: ``REPRO_ADDON_BASES`` (default ``arch-btrfs-amd64,arch-ext4-amd64``);
## step 4 always runs on ``arch-old-systemd-amd64`` as well.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

proc newerThanMarker(g: Guest; repro: string): ExecOut =
  ## Every file on the root filesystem modified after a marker while the
  ## preflight ran (A2's leg; ``/var/log`` holds the journal, which the base
  ## writes on its own; on Arch timesyncd keeps its clock file in the same
  ## place as on Debian).
  g.exec("touch /run/addon-marker && sleep 1 && " &
    repro & " system addon preflight >/dev/null 2>&1; " &
    "find / -xdev \\( -path /proc -o -path /sys -o -path /dev -o -path /run " &
    "-o -path /tmp -o -path /var/log -o -path /var/lib/systemd/timesync " &
    "\\) -prune -o -newer /run/addon-marker -print")

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  let belowMatrix = not isOmarchyBase(b) and archVariantOf(b) == avOldSystemd
  let omarchy = isOmarchyBase(b)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    # The first profile, on the disk before the hash is taken (Omarchy only).
    let profileFlag = g.firstProfileFlag(b)
    g.shutdown()
    let h0 = g.diskSha256()

    g.boot(readonly = true)
    let a = artefact(b.debArch)
    discard g.run("mount -t tmpfs -o mode=0700,size=64m repro-addon-preflight /mnt")
    g.copyTo(a.path, "/mnt/repro")
    discard g.run("cd /mnt && echo '" & a.sha256 &
                  "  repro' | sha256sum -c - && chmod 0755 repro")
    let ro = g.exec("/mnt/repro system addon preflight" & profileFlag)
    record["readOnlyPreflight"] = %(ro.stdout & ro.stderr)
    if belowMatrix:
      step("the preflight refuses a base whose systemd is below the matrix",
           ro.exitCode == 2 and "fail distribution" in ro.stdout and
             "below the Arch matrix's 258" in ro.stdout,
           ro.stdout & ro.stderr)
    else:
      step("preflight on a write-protected disk is compatible",
           ro.exitCode == 0, ro.stdout & ro.stderr)
    g.shutdown()
    let h1 = g.diskSha256()
    step("qcow2 byte-identical after the read-only preflight", h0 == h1,
         "before " & h0 & " after " & h1)

    g.boot()
    let newer = g.newerThanMarker(repro)
    step("the preflight modified no file on the root filesystem",
         newer.exitCode == 0 and newer.stdout.strip().len == 0,
         if newer.stdout.strip().len == 0: "(nothing newer than the marker)"
         else: newer.stdout & newer.stderr)
    if belowMatrix: return fails

    let rw = g.exec(repro & " system addon preflight" & profileFlag)
    step("read-write preflight is compatible", rw.exitCode == 0,
         rw.stdout & rw.stderr)
    if rw.exitCode == 0 and ro.exitCode == 0:
      let roDigest = planDigestOf(ro.stdout)
      let rwDigest = planDigestOf(rw.stdout)
      step("plan digest is the same read-only and read-write",
           rwDigest == roDigest, "ro " & roDigest & " rw " & rwDigest)
    let js = g.exec(repro & " system addon preflight --json" & profileFlag)
    var plan: JsonNode
    try:
      plan = parseJson(js.stdout)
    except CatchableError as e:
      step("the plan is JSON", false, e.msg & "\n" & js.stdout)
      return fails
    let p = plan
    step("the plan records pacman, the network manager and snapper",
         p{"base", "pacman"}.getStr().startsWith("7") and
           p{"base", "networkManager"}.getStr().len > 0 and
           p{"rootFilesystem", "snapper"} != nil,
         $p{"base"} & " " & $p{"rootFilesystem"})
    step("the plan records the root filesystem type",
         p{"rootFilesystem", "type"}.getStr() == g.rootFsType(),
         $p{"rootFilesystem"})

    if omarchy:
      let osr = g.run(". /etc/os-release && printf '%s|%s|%s|%s' \"$ID\" \"$ID_LIKE\" \"$VERSION_ID\" \"$BUILD_ID\"").strip().split('|')
      let ver = g.run("omarchy-version 2>/dev/null || true").strip()
      let pkg = g.run("pacman -Q omarchy | cut -d' ' -f2").strip()
      record["omarchyFacts"] = %*{"osRelease": osr, "omarchyVersion": ver,
                                  "package": pkg}
      step("the installed base is ID=omarchy ID_LIKE=arch, and passes",
           osr.len == 4 and osr[0] == "omarchy" and "arch" in osr[1] and
             "pass distribution" in rw.stdout and
             "pass omarchy-account" in rw.stdout, rw.stdout)
      let o = p{"omarchy"}
      step("the plan records Omarchy's version from os-release and the package",
           o != nil and o{"versionId"}.getStr() == osr[2] and
             o{"buildId"}.getStr() == osr[3] and o{"package"}.getStr() == pkg and
             o{"account"}.getStr() == accountFor(b) and
             (ver.len == 0 or ver == osr[2] or pkg.startsWith(ver)),
           $o & " omarchy-version=" & ver)
      let none = g.exec(repro & " system addon preflight")
      step("no --profile on Omarchy is refused, EAddOnBaseLayerOwned",
           none.exitCode == 2 and "fail omarchy-account" in none.stdout and
             "EAddOnBaseLayerOwned" in none.stdout, none.stdout)
      let noAcct = g.exec(repro & " system addon preflight --profile " &
        g.putProfile("no-account", addOnStanza("")))
      step("a profile naming no omarchyAccount is refused, EAddOnBaseLayerOwned",
           noAcct.exitCode == 2 and "fail omarchy-account" in noAcct.stdout and
             "EAddOnBaseLayerOwned" in noAcct.stdout, noAcct.stdout)
      let unknown = g.exec(repro & " system addon preflight --profile " &
        g.putProfile("unknown-account", addOnStanza("nosuchuser")))
      step("an account the password database does not know is refused",
           unknown.exitCode == 2 and "EAddOnBaseLayerOwned" in unknown.stdout and
             "not an account" in unknown.stdout, unknown.stdout)
      let hooks = g.run("getent passwd " & accountFor(b) & " | cut -d: -f6").strip() &
        "/.config/omarchy/hooks"
      discard g.run("mv " & hooks & " " & hooks & ".repro-gate")
      let noDir = g.exec(repro & " system addon preflight" & profileFlag)
      discard g.run("mv " & hooks & ".repro-gate " & hooks)
      step("an account with no hook directory is refused, naming it",
           noDir.exitCode == 2 and "EAddOnBaseLayerOwned" in noDir.stdout and
             hooks in noDir.stdout, noDir.stdout)
      let back = g.exec(repro & " system addon preflight" & profileFlag)
      step("compatible again with the hook directory back", back.exitCode == 0,
           back.stdout)
      return fails

    # On a plain Arch base an omarchyAccount has no meaning.
    let stray = g.exec(repro & " system addon preflight --profile " &
      g.putProfile("stray-account", addOnStanza("root")))
    step("an omarchyAccount on a base that is not Omarchy is EAddOnOutOfScope",
         stray.exitCode == 2 and "fail omarchy-account" in stray.stdout and
           "EAddOnOutOfScope" in stray.stdout, stray.stdout)

    # Omarchy's os-release: the base rule accepts ID=omarchy ID_LIKE=arch;
    # without --profile the Omarchy account cannot be checked.
    discard g.run("cp --remove-destination \"$(readlink -f /etc/os-release)\" " &
      "/root/addon/os-release.orig && cp --remove-destination " &
      "\"$(readlink -f /etc/os-release)\" /etc/os-release && " &
      "sed -i 's/^ID=.*/ID=omarchy\\nID_LIKE=arch/' /etc/os-release")
    let om = g.exec(repro & " system addon preflight")
    step("ID=omarchy ID_LIKE=arch passes the distribution check",
         "pass distribution" in om.stdout, om.stdout)
    step("an Omarchy base without --profile is refused naming the account",
         om.exitCode == 2 and "fail omarchy-account" in om.stdout and
           "EAddOnBaseLayerOwned" in om.stdout, om.stdout)
    discard g.run("ln -sf ../usr/lib/os-release /etc/os-release")
    let back = g.exec(repro & " system addon preflight")
    step("compatible again once os-release is restored", back.exitCode == 0,
         back.stdout)
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

suite "e2e_arch_addon_preflight_is_zero_write":
  test "the preflight writes nothing on Arch and applies the Arch base rule":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_addon_preflight_is_zero_write)")
    else:
      var failures: seq[string]
      var bases = selectedArchBases()
      var hasOld = false
      for b in bases:
        if not isOmarchyBase(b) and archVariantOf(b) == avOldSystemd:
          hasOld = true
      if not hasOld: bases.add(ArchOldSystemd)
      for b in bases:
        let record = archGateRecord("e2e_arch_addon_preflight_is_zero_write")
        record["base"] = %b.name
        if isOmarchyBase(b): record["omarchy"] = omarchyRecordBase()
        else: record["archiveDate"] = %archiveDateOf(b)
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord("e2e_arch_addon_preflight_is_zero_write",
                                     record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

## Gate ``e2e_omarchy_addon_base_layer_refusal`` (spec ReproOS-Add-On-Mode
## §4.3.2, §8.4, §12.5 condition 1; §13 decision 11).
##
## On the Omarchy VM (the test bed's pinned Omarchy 4.5.0-3 install):
##
## - **Preflight records the base layer.** ``preflight --json`` records the
##   Omarchy version and the Omarchy path set, and the set equals the one
##   committed with the test bed (``fixtures/omarchy/omarchy-4.5.0-3.etc-paths``,
##   derived from the package without the add-on). Each recorded path names
##   scripts that are files of the ``omarchy`` package and contain it, and its
##   package owners are exactly the packages whose ``%FILES%`` lists it (read
##   in the guest by ``awk``, not by the add-on's reader); at least one path
##   has a package owner too (``omarchy-settings`` owns many). The human
##   preflight lists the set with both owners.
## - **A plan refuses what intersects it.** A profile declaring ``/etc/ssh/``
##   as a managed prefix, a file under ``/etc/sudoers.d`` and the unit
##   ``omarchy-nvme-suspend-fix.service`` (Omarchy's
##   ``install/hardware/apple/fix-suspend-nvme.sh`` installs it) is refused
##   with ``EAddOnBaseLayerOwned`` for each, naming a script that names it,
##   and writes nothing (fingerprint and ledger unchanged); each alone is
##   refused the same way.
## - **``overrideBaseLayer`` applies it, and every plan lists it.** A file
##   under ``/etc/modprobe.d`` (another directory of the set) and the unit,
##   declared with ``collision = "overrideBaseLayer"`` (the prefix narrowed
##   to the file), apply, the fingerprint diff equals the ledger delta, and
##   the apply and a later ``repro infra plan`` both list each override with
##   its script. (Not the ``/etc/sudoers.d`` file: the add-on writes files
##   mode 0644, which sudo's tree rejects; ``arch_gate_support.ModprobeFile``.)
##   The ``/etc/ssh/`` prefix stays refused beside them: a prefix carries no
##   acknowledgement of its own.
##
## Everything leaves the profile, the add-on is uninstalled, and the
## fingerprint equals the baseline's.
##
## Falsifying mutation: ``REPRO_ADDON_MUTATION=omarchy-path-set-empty``
## reads the set as empty, so preflight records no path and all three
## declarations are let through; the set comparison and the refusals turn
## the gate red. Judged by ``arch_gate_support.falsifierVerdict``.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is ``omarchy-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_omarchy_addon_base_layer_refusal``).
##
## *Mocking.* None: the real Omarchy VM, its real ``omarchy`` package and
## pacman database, systemd and sudo, and the real static add-on binary.

import std/[algorithm, json, os, sequtils, sets, strutils, tables, unittest]

import repro_test_support/reasoned_skip

import repro_addon/fingerprint

import ./arch_gate_support

const
  Gate = "e2e_omarchy_addon_base_layer_refusal"
  CommittedSet = currentSourcePath().parentDir / "fixtures" / "omarchy" /
    ("omarchy-" & OmarchyVersion & ".etc-paths")

proc committedPaths(): seq[string] =
  ## The committed set: one path per line, ``#`` lines are comments.
  for l in readFile(CommittedSet).splitLines():
    if l.len > 0 and not l.startsWith("#"): result.add(l)

proc ownersListing(g: Guest; paths: seq[string]): Table[string, seq[string]] =
  ## Every package whose ``%FILES%`` lists each path (a directory without
  ## its trailing ``/``), read in the guest by awk over the local database:
  ## an independent reading of what the add-on's reader reports.
  discard g.run("cat > /root/addon/ar3-paths <<'EOF'\n" & paths.join("\n") &
                "\nEOF")
  let o = g.run("for d in /var/lib/pacman/local/*/; do " &
    "n=$(sed -n '/^%NAME%$/{n;p;q}' \"$d/desc\"); " &
    "sed -n '/^%FILES%$/,/^$/p' \"$d/files\" | sed -n '2,$p' | " &
    "sed -e 's|/$||' -e 's|^|/|' -e \"s|$|\t$n|\"; done | " &
    "awk -F'\t' 'NR==FNR{w[$1]=1;next} ($1 in w){print}' /root/addon/ar3-paths -",
    timeoutSec = 900)
  for l in o.splitLines():
    let f = l.split('\t')
    if f.len == 2 and f[1].len > 0:
      var owners = result.getOrDefault(f[0])
      if f[1] notin owners: owners.add(f[1])
      result[f[0]] = owners.sorted(system.cmp)

proc scriptsOf(recorded: JsonNode; path: string): seq[string] =
  for e in recorded.getElems():
    if e{"path"}.getStr() == path:
      for s in e{"scripts"}.getElems(): result.add(s.getStr())

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  case mut
  of "omarchy-path-set-empty":
    var may = @[
      "preflight: every recorded path is named by its scripts, files of the omarchy package",
      "preflight: each path's package owners are the packages whose %FILES% lists it",
      "preflight: some path of the set is also owned by a package",
      "preflight: the human preflight lists the set with both owners"]
    for row in ["prefix-alone", "file-alone", "unit-alone", "prefix-beside-overrides"]:
      may.add(@[row & ": refused", row & ": the refused apply wrote nothing"])
    may.add(@["all-three: the refused apply wrote nothing",
              "override: the apply lists each override with its script",
              "override: the plan lists each override with its script"])
    Falsifier(required: @[
        "preflight's recorded path set == the set committed for Omarchy " &
          OmarchyVersion,
        "all-three: refused"],
      mayBeRed: may,
      mustRunGreen: @["vacuity guard: the omarchy package is " & OmarchyVersion,
        "baseline: udevadm settle and systemctl daemon-reload",
        "fingerprint is deterministic", "preflight records the Omarchy version",
        "preflight is compatible", "bootstrap", "override: applied",
        "override: fingerprint diff == ledger delta",
        "override: the file holds the profile's bytes",
        "override: the unit is active",
        "removal: every resource leaves the profile", "uninstall",
        "base fingerprint after uninstall == before bootstrap"])
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
    let account = accountFor(b)
    let installed = g.run("pacman -Q omarchy").strip()
    step("vacuity guard: the omarchy package is " & OmarchyVersion,
         installed == "omarchy " & OmarchyVersion, installed)

    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    sleep(20_000)
    let det = identityReport(f0, g.fingerprintArch(repro, account))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails

    # --- Preflight records the base layer (zero-write, before bootstrap).
    let first = g.firstProfileFlag(b)
    let pj = g.exec(repro & " system addon preflight --json" & first)
    var plan = newJObject()
    try: plan = parseJson(pj.stdout)
    except JsonParsingError, ValueError:
      raise newException(TestBedError, "preflight --json printed no plan: " &
        pj.stdout & pj.stderr)
    let recorded = plan{"omarchy", "paths"}
    step("preflight records the Omarchy version",
         plan{"omarchy", "package"}.getStr() == OmarchyVersion,
         (if plan.hasKey("omarchy"): $plan["omarchy"] else: "no omarchy key"))
    var got: seq[string]
    if recorded != nil:
      for e in recorded.getElems(): got.add(e{"path"}.getStr())
    let want = committedPaths()
    record["recordedPaths"] = %got.len
    record["committedPaths"] = %want.len
    let missing = want.filterIt(it notin got)
    let extra = got.filterIt(it notin want)
    step("preflight's recorded path set == the set committed for Omarchy " &
           OmarchyVersion,
         got.len > 0 and missing.len == 0 and extra.len == 0 and
           got == got.sorted(system.cmp),
         $got.len & " recorded, " & $want.len & " committed; missing: " &
           missing.join(" ") & "; extra: " & extra.join(" "))
    block:
      # Each (path, script): the script is a file of the omarchy package and
      # its text contains the path.
      # The pairs go to the guest as a file (one ``<path>\t<script>`` line
      # each), so the command stays far below the kernel's single-argument
      # limit (MAX_ARG_STRLEN, 128 KiB) whatever the set's size.
      var tsv = ""
      var pairs = 0
      for e in (if recorded != nil: recorded.getElems() else: @[]):
        for s in e{"scripts"}.getElems():
          inc pairs
          tsv.add(e{"path"}.getStr() & "\t" & s.getStr() & "\n")
      let o =
        if pairs == 0: "no path recorded"
        else:
          discard g.run("cat > /root/addon/ar3-pairs <<'EOF'\n" & tsv & "EOF")
          g.run("pacman -Qlq omarchy > /root/addon/ar3-files; " &
            "tab=$(printf '\\t'); while IFS=\"$tab\" read -r p s; do " &
            "grep -qxF -- \"$s\" /root/addon/ar3-files && " &
            "grep -qF -- \"$p\" \"$s\" || echo \"NOT NAMED: $p in $s\"; " &
            "done < /root/addon/ar3-pairs")
      step("preflight: every recorded path is named by its scripts, files " &
           "of the omarchy package", pairs > 0 and o.strip().len == 0,
           $pairs & " (path, script) pairs\n" & o)
    block:
      let independent = g.ownersListing(got)
      var wrong: seq[string]
      var dual = 0
      for e in (if recorded != nil: recorded.getElems() else: @[]):
        let p = e{"path"}.getStr()
        var reported: seq[string]
        for o in e{"owners"}.getElems(): reported.add(o.getStr())
        if reported.len > 0: inc dual
        if reported != independent.getOrDefault(p):
          wrong.add(p & ": reported " & reported.join(",") & ", %FILES% " &
            independent.getOrDefault(p).join(","))
      record["pathsWithAPackageOwner"] = %dual
      step("preflight: each path's package owners are the packages whose " &
           "%FILES% lists it", got.len > 0 and wrong.len == 0,
           wrong.join("\n"))
      step("preflight: some path of the set is also owned by a package",
           dual > 0, $dual & " path(s) with a package owner")
    block:
      let h = g.exec(repro & " system addon preflight" & first)
      let said = h.stdout
      var dualLine = false
      for l in said.splitLines():
        let f = l.strip().split('\t')
        if f.len == 3 and f[0].startsWith("/etc/") and f[1] != "-" and
            f[2].startsWith("/usr/share/omarchy/"):
          dualLine = true
      step("preflight: the human preflight lists the set with both owners",
           "omarchy-path-set" in said and
             "Omarchy path set (path, package owners, scripts):" in said and
             dualLine, said)

    if not g.bootstrapArch(repro, step, first).ok: return fails
    let exe = g.gen0ReproExe()

    proc refused(row, profile: string; needles: openArray[string]) =
      ## Exit 2, every needle in the output, nothing written.
      let before = g.fingerprintArch(repro, account)
      let ledgerBefore = g.ledgerOf()
      let r = g.applyProfile(repro, row, profile)
      let said = r.stdout & r.stderr
      var named = r.exitCode == 2
      var absent: seq[string]
      for n in needles:
        if n notin said: absent.add(n)
      step(row & ": refused", named and absent.len == 0,
           "exit " & $r.exitCode & "; not in the output: " &
             absent.join(" | ") & "\n" & said)
      let same = identityReport(before, g.fingerprintArch(repro, account))
      step(row & ": the refused apply wrote nothing",
           same.ok and g.ledgerOf() == ledgerBefore, same.text)

    # A script naming each declaration, from the recorded set.
    let sshScripts = scriptsOf(recorded, "/etc/ssh/ssh_config.d") &
                     scriptsOf(recorded, "/etc/ssh/sshd_config.d/10-omarchy-hardening.conf")
    let sudoScripts = scriptsOf(recorded, SudoersDir)
    let unitScripts = scriptsOf(recorded, OmarchyUnitPath)
    let modprobeScripts = scriptsOf(recorded, ModprobeDir)
    record["namingScripts"] = %*{"ssh": sshScripts, "sudoers.d": sudoScripts,
                                 "unit": unitScripts}
    proc firstOf(s: seq[string]): string =
      if s.len > 0: s[0] else: "(no script recorded)"
    let prefixNeedles = @["EAddOnBaseLayerOwned", "managed prefix " & SshPrefix &
      " covers", firstOf(sshScripts)]
    let fileNeedles = @["EAddOnBaseLayerOwned", SudoersFile &
      " is written by the base layer", SudoersDir & " (named by",
      firstOf(sudoScripts), "overrideBaseLayer"]
    let unitNeedles = @["EAddOnBaseLayerOwned", OmarchyUnit & " is a unit",
      OmarchyUnitPath & " (named by", firstOf(unitScripts), "overrideBaseLayer"]

    # --- The three together, then each alone.
    refused("all-three",
      baseLayerStanza([SshPrefix, SudoersFile], account) & sudoersRes() &
        omarchyUnitRes(exe),
      prefixNeedles & fileNeedles & unitNeedles)
    refused("prefix-alone", baseLayerStanza([SshPrefix], account), prefixNeedles)
    refused("file-alone", baseLayerStanza([SudoersFile], account) & sudoersRes(),
            fileNeedles)
    refused("unit-alone", baseLayerStanza([], account) & omarchyUnitRes(exe),
            unitNeedles)

    # --- Acknowledged: the file and the unit apply, and are listed.
    let overrides = baseLayerStanza([ModprobeFile], account) &
      modprobeRes("overrideBaseLayer") & omarchyUnitRes(exe, "overrideBaseLayer")
    proc listsOverrides(said: string): bool =
      var inSection = false
      var file, unit = false
      for l in said.splitLines():
        if l.startsWith("base-layer overrides"): inSection = true
        elif inSection and l.startsWith("  "):
          if ("\t" & ModprobeFile & "\t") in l and firstOf(modprobeScripts) in l:
            file = true
          if ("\t" & OmarchyUnit & "\t") in l and firstOf(unitScripts) in l:
            unit = true
        elif inSection: inSection = false
      file and unit
    block:
      let before = g.fingerprintArch(repro, account)
      let lBefore = g.ledgerOf()
      let r = g.applyProfile(repro, "override", overrides)
      let said = r.stdout & r.stderr
      step("override: applied", r.exitCode == 0, said)
      let after = g.fingerprintArch(repro, account)
      let d = deltaReport(before, after, lBefore, g.ledgerOf())
      step("override: fingerprint diff == ledger delta", d.ok, d.text)
      step("override: the apply lists each override with its script",
           listsOverrides(said), said)
      step("override: the file holds the profile's bytes",
           g.run("sha256sum < " & ModprobeFile & " | cut -d' ' -f1").strip() ==
             sha256Hex(ModprobeBytes),
           g.run("ls -la " & ModprobeFile))
      step("override: the unit is active",
           g.exec("systemctl is-active " & OmarchyUnit).exitCode == 0,
           g.exec("systemctl status --no-pager " & OmarchyUnit).stdout)
      let p = g.planProfile(repro, "override-plan", overrides)
      step("override: the plan lists each override with its script",
           p.exitCode == 0 and listsOverrides(p.stdout & p.stderr),
           p.stdout & p.stderr)
    refused("prefix-beside-overrides",
      baseLayerStanza([SshPrefix, ModprobeFile], account) &
        modprobeRes("overrideBaseLayer") &
        omarchyUnitRes(exe, "overrideBaseLayer"),
      prefixNeedles)

    # --- Everything leaves the profile; uninstall; byte identity.
    block:
      let before = g.fingerprintArch(repro, account)
      let lBefore = g.ledgerOf()
      let r = g.applyProfile(repro, "removal", baseLayerStanza([], account))
      step("removal: every resource leaves the profile", r.exitCode == 0,
           r.stdout & r.stderr)
      let d = deltaReport(before, g.fingerprintArch(repro, account), lBefore,
                          g.ledgerOf())
      step("removal: fingerprint diff == ledger delta", d.ok, d.text)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let ident = identityReport(f0, g.fingerprintArch(repro, account))
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
  test "the Omarchy path set is recorded, and what intersects it is refused":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if not isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the Omarchy VM")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        record["omarchy"] = omarchyRecordBase()
        record["committedSet"] = %("tests/e2e/addon/fixtures/omarchy/" &
          extractFilename(CommittedSet))
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(Gate, record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

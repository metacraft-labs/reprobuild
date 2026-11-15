## Steps the Arch add-on gates share (spec ReproOS-Add-On-Mode §12.5
## condition 1): the Debian byte-identity sequence's profiles in their Arch form, the
## fingerprint with the Arch components, and the preflight and bootstrap of an
## Arch guest.
##
## The guests are the Arch test bed's (``arch_testbed.nim``); everything
## else is the Debian test bed's (``addon_testbed.nim``). Nothing here starts or
## stops a process on the host or in a guest except through those.
##
## *The fixture service.* On Arch a service is a Reprobuild store package,
## never a ``.deb`` closure (spec §8.3 *Services on Arch*, §13 decision 92).
## The store package every add-on host carries is the add-on's own: its
## ``repro`` in the store, which bootstrap realises. The fixture unit runs
## it (``fixtureUnit``), so it needs nothing from the base's ``/usr`` and no
## package the test bed would have to add.
##
## *Mocking.* None: real Arch guests, real systemd and pacman, the real static
## add-on binary.

import std/[json, strutils]

import ./addon_testbed
import ./arch_testbed

export addon_testbed, arch_testbed

const
  FixturePrefix* = "/etc/repro-addon-fixture/"
  FixtureFile* = "/etc/repro-addon-fixture/fixture.conf"
  FixtureUnitName* = "repro-addon-fixture.service"

proc gen0ReproExe*(g: Guest): string =
  ## The add-on's ``repro`` in the store, as bootstrap recorded it
  ## (``bootstrap-evidence.json``'s ``reproExe``).
  result = g.run("sed -n 's/.*\"reproExe\": *\"\\([^\"]*\\)\".*/\\1/p' " &
    "/var/lib/repro/system/addon/bootstrap-evidence.json | head -1").strip()
  if not result.startsWith("/repro/store/"):
    raise newException(TestBedError, "bootstrap recorded no add-on binary " &
      "in the store: '" & result & "'")

proc fixtureUnit*(reproExe: string): string =
  ## A unit whose program is a Reprobuild store package: the add-on's own
  ## ``repro`` (``--version``), as a ``oneshot`` that stays active
  ## (``RemainAfterExit=yes``), so the generation has an active unit of its
  ## own without anything from the base's ``/usr``.
  "systemd.systemUnit {\n" &
  "  floorExceptions = [\"serviceFloor: a test fixture whose only job is " &
    "to stay active\"]\n" &
  "  name = \"" & FixtureUnitName & "\"\n" &
  "  content = \"[Unit]\nDescription=Reprobuild add-on Arch test fixture\n\n" &
    "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=" & reproExe &
    " --version\n\n[Install]\nWantedBy=repro-addon.target\n\"\n" &
  "  enabled = true\n}\n"

proc fixtureFile*(content: string): string =
  "fs.systemFile {\n  path = \"" & FixtureFile & "\"\n  content = \"" &
    content & "\"\n}\n"

proc addOnStanza*(omarchyAccount = ""): string =
  "addOn {\n  managedEtcPrefixes = [\"" & FixturePrefix & "\"]\n" &
    (if omarchyAccount.len > 0:
       "  omarchyAccount = \"" & omarchyAccount & "\"\n"
     else: "") & "}\n\n"

proc gen1Profile*(reproExe: string; omarchyAccount = ""): string =
  ## The Debian sequence's generation 1 on Arch: a unit and an ``/etc`` file (no diversion:
  ## pacman has none, spec §4.3.1).
  addOnStanza(omarchyAccount) & fixtureUnit(reproExe) & "\n" &
    fixtureFile("fixture = 1\n")

proc gen2Profile*(omarchyAccount = ""): string =
  ## The Debian sequence's generation 2: the unit removed, the file changed.
  addOnStanza(omarchyAccount) & fixtureFile("fixture = 2\n")

const SettleBaselineCommand* = "udevadm settle && systemctl daemon-reload && " &
  "for a in $(systemctl list-units --type=automount --state=active --plain " &
  "--no-legend | awk '{print $1}'); do m=\"${a%.automount}.mount\"; " &
  "if systemctl -q is-active \"$m\"; then systemctl stop \"$m\"; fi; done"
  ## Run in the guest before a baseline fingerprint (spec §12.2, §13
  ## decision 134): the base's own generators and udev rules have finished
  ## and systemd's unit set reflects them, so units a generator emits only
  ## on a reload (Omarchy's zram swap aliases) are already in the baseline
  ## when bootstrap's own ``daemon-reload`` would otherwise make them
  ## appear. A mount behind an armed automount (the Arch guests' ``/efi``)
  ## is stopped, the state the base returns to by itself once the
  ## automount's idle timeout passes, so the baseline does not depend on
  ## whether something touched it in the last minutes; the automount stays
  ## armed, and a later access shows in the comparison. It is part of the
  ## gate, never of preflight, which writes nothing (spec §6.1).

proc settleBaseline*(g: Guest; step: StepFn) =
  ## ``SettleBaselineCommand`` as a recorded step of the gate.
  let r = g.exec(SettleBaselineCommand, timeoutSec = 300)
  step("baseline: udevadm settle and systemctl daemon-reload",
       r.exitCode == 0, r.stdout & r.stderr)
  if r.exitCode != 0:
    raise newException(TestBedError, "the baseline step failed: " &
      r.stdout & r.stderr)

proc fingerprintArch*(g: Guest; repro: string; omarchyAccount = ""): string =
  ## The fingerprint with the Arch components (``pacman-local``,
  ## ``btrfs-subvolumes`` on a btrfs root, ``omarchy-hooks`` for an account).
  g.run(repro & " system addon fingerprint" &
        (if omarchyAccount.len > 0: " --omarchy-account " & omarchyAccount
         else: ""))

proc rootIsBtrfs*(b: BaseImage): bool =
  ## The base's root filesystem as the test bed builds it: btrfs for the
  ## Arch cloud image and its archive-date variant, and for the Omarchy VM
  ## (Omarchy's installer: btrfs ``@`` with snapper); ext4 for the ext4 guest.
  isOmarchyBase(b) or archVariantOf(b) in {avBtrfs, avOldSystemd}

proc accountFor*(b: BaseImage): string =
  ## The ``omarchyAccount`` a profile names on ``b``: the account the
  ## Omarchy VM's installer created, "" on a plain Arch guest.
  if isOmarchyBase(b): OmarchyAccount else: ""

proc vacuityGuardRootFs*(g: Guest; b: BaseImage): tuple[ok: bool; detail: string] =
  ## The byte-identity gate's vacuity guard: a btrfs base must report a
  ## btrfs root and the ext4 base an ext4 one (``findmnt -no FSTYPE /``),
  ## or the two legs would test one placement twice.
  let fs = g.rootFsType()
  let want = if rootIsBtrfs(b): "btrfs" else: "ext4"
  (fs == want, b.name & ": findmnt -no FSTYPE / = " & fs & ", expected " & want)

proc firstProfileFlag*(g: Guest; b: BaseImage): string =
  ## ``--profile <file>`` for the preflight and bootstrap on an Omarchy base
  ## (spec §6.1: the account cannot be checked without the profile), with
  ## the ``addOn`` stanza naming the account; "" on a plain Arch guest.
  if not isOmarchyBase(b): return ""
  " --profile " & g.putProfile("first", addOnStanza(accountFor(b)))

proc hooksRecorded*(fingerprint: string): bool =
  ## The fingerprint records the account's hook tree (``omarchy-hooks``),
  ## and the hook directory itself is present, not ``absent``.
  for line in fingerprint.splitLines():
    if line.startsWith("omarchy-hooks	"):
      if line.endsWith("	absent"): return false
      result = true

proc preflightArch*(g: Guest; repro, flags: string): ExecOut =
  g.exec(repro & " system addon preflight" & flags)

proc bootstrapArch*(g: Guest; repro: string; step: StepFn;
                    flags = ""; withCache = true):
    tuple[ok: bool; anchors: Anchors] =
  ## Preflight and bootstrap with the acknowledged plan digest; ``flags``
  ## (``--profile <file>`` on Omarchy) go to both, since bootstrap
  ## recomputes the plan from the same inputs. ``withCache = false`` names
  ## the deploy signers only: a gate that configures the deploy agent must
  ## not name the test bed's cache, whose host does not resolve, because
  ## preflight pins every origin of the agent to addresses (spec §9.1), as
  ## ``agent_e2e_support.agentFlags`` does for the Debian agent gates.
  let anchors = g.installAnchors()
  result.anchors = anchors
  let anchorFlags =
    if withCache: anchors.flags
    else: " --deploy-signers /root/addon/deploy-signers.anchors"
  let pre = g.preflightArch(repro, anchorFlags & flags)
  step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
  if pre.exitCode != 0: return
  let boot = g.exec(repro & " system addon bootstrap --plan " &
    planDigestOf(pre.stdout) & anchorFlags & flags, timeoutSec = 1800)
  step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
  result.ok = boot.exitCode == 0

proc archGateRecord*(gate: string): JsonNode =
  ## The record every Arch gate writes: the Debian gates' fields plus the Arch pins.
  result = archRecordBase()
  result["gate"] = %gate
  result["reprobuild"] = %gitHead()
  result["mutation"] = %mutation()
  result["testSeams"] = %testSeams()

# ---------------------------------------------------------------------------
# Falsifier runs (REPRO_ADDON_MUTATION).
# ---------------------------------------------------------------------------

type
  RecordCheck* = tuple[name: string; check: proc(record: JsonNode): bool]
    ## A property of the falsifier run's record beyond its steps (the
    ## exact final diff of the byte-identity control, the uninstall over a
    ## marker having run to its end), named for the record.

  Falsifier* = object
    ## What a gate's falsifying build must do to one base. The judgement is an allow-list: a step may be red
    ## only when it is ``required`` (the mutation's own failure) or listed
    ## in ``mayBeRed`` (a stated consequence of it); every other step the
    ## run recorded must be green. ``mustRunGreen`` names steps that must
    ## be PRESENT and green -- bootstrap, the generation applies,
    ## uninstall, every step before the mutated code -- so a run that
    ## stopped early, or whose uninstall simply failed, is never taken for
    ## the mutation's red. ``green`` marks a base outside the mutation (an
    ## ext4 root under a btrfs-only mutation): nothing may be red there.
    ## ``recordChecks`` must all hold.
    required*: seq[string]
    mayBeRed*: seq[string]
    mustRunGreen*: seq[string]
    green*: bool
    recordChecks*: seq[RecordCheck]

proc falsifierVerdict*(f: Falsifier; record: JsonNode):
    tuple[confirmed: bool; why: string] =
  ## Whether ``record`` (one base of a mutated run) shows exactly the
  ## failure the mutation is for, and nothing else. An ``exception`` step
  ## -- a guest that did not answer, an SSH timeout, any infrastructure
  ## failure -- is never allowed red, so it always refutes.
  var failed, passed: seq[string]
  for s in record{"steps"}.getElems():
    if s{"ok"}.getBool(): passed.add(s{"step"}.getStr())
    else: failed.add(s{"step"}.getStr())
  if "exception" in failed:
    return (false, "an exception, not the mutation's failure: " &
      $record{"steps"})
  for m in f.mustRunGreen:
    if m notin passed:
      return (false, "a step that must run and stay green did not: " & m &
        (if m in failed: " (red)" else: " (absent)"))
  if f.green:
    if failed.len > 0:
      return (false, "outside the mutation, but red: " & failed.join("; "))
  else:
    for r in f.required:
      if r notin failed:
        return (false, "the required step is not red: " & r & " (red: " &
          failed.join("; ") & ")")
    for s in failed:
      if s notin f.required and s notin f.mayBeRed:
        return (false, "a step outside the mutation's reach is red: " & s)
  for c in f.recordChecks:
    if not c.check(record):
      return (false, "the record check failed: " & c.name)
  if f.green: (true, "outside the mutation, and green")
  else: (true, "red at: " & f.required.join("; "))

block falsifierVerdictSelfCheck:
  # The judge's own controls, run whenever a gate starts: the mutation's
  # red alone confirms; a red outside the list, an exception, a missing or
  # red must-run step, or a failed record check refutes.
  proc rec(steps: openArray[(string, bool)]): JsonNode =
    result = %*{"steps": []}
    for (n, ok) in steps: result["steps"].add(%*{"step": n, "ok": ok})
  let f = Falsifier(required: @["mutated"], mayBeRed: @["consequence"],
                    mustRunGreen: @["bootstrap", "uninstall"])
  doAssert falsifierVerdict(f, rec([("bootstrap", true), ("mutated", false),
    ("consequence", false), ("uninstall", true)])).confirmed
  doAssert not falsifierVerdict(f, rec([("bootstrap", true), ("mutated", false),
    ("elsewhere", false), ("uninstall", true)])).confirmed
  doAssert not falsifierVerdict(f, rec([("bootstrap", true), ("mutated", false),
    ("uninstall", false)])).confirmed
  doAssert not falsifierVerdict(f, rec([("bootstrap", true),
    ("mutated", false)])).confirmed
  doAssert not falsifierVerdict(f, rec([("bootstrap", true), ("mutated", false),
    ("uninstall", true), ("exception", false)])).confirmed
  doAssert not falsifierVerdict(f, rec([("bootstrap", true), ("mutated", true),
    ("uninstall", true)])).confirmed
  let g = Falsifier(green: true, mustRunGreen: @["uninstall"])
  doAssert falsifierVerdict(g, rec([("uninstall", true)])).confirmed
  doAssert not falsifierVerdict(g, rec([("uninstall", true),
    ("x", false)])).confirmed
  var c = f
  c.recordChecks = @[(name: "always false",
                      check: proc(r: JsonNode): bool = false)]
  doAssert not falsifierVerdict(c, rec([("bootstrap", true), ("mutated", false),
    ("uninstall", true)])).confirmed

proc judgeRun*(gate: string; record: JsonNode; baseFailures: seq[string];
               expected: proc(mutation: string; b: BaseImage): Falsifier;
               b: BaseImage): seq[string] =
  ## The gate's failures for one base: ``baseFailures`` on a product run;
  ## on a falsifier run, nothing when ``falsifierVerdict`` confirms the
  ## expected red, and why not otherwise. The base's own verdict stays in
  ## ``record["verdict"]``; the judgement goes to ``record["falsifier"]``.
  let mut = mutation()
  if mut.len == 0: return baseFailures
  let f = expected(mut, b)
  let v = falsifierVerdict(f, record)
  var checks: seq[string]
  for c in f.recordChecks: checks.add(c.name)
  record["falsifier"] = %*{"mutation": mut, "confirmed": v.confirmed,
    "why": v.why, "required": f.required, "mayBeRed": f.mayBeRed,
    "mustRunGreen": f.mustRunGreen, "outsideMutation": f.green,
    "recordChecks": checks}
  if not v.confirmed:
    result.add(b.name & ": falsifier " & mut & " not confirmed: " & v.why)

proc unknownMutation*(gate, mutation: string): ref TestBedError =
  newException(TestBedError, gate & " has no falsifier named " & mutation)

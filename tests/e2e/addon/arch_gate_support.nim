## Steps the Arch add-on gates share (spec ReproOS-Add-On-Mode §12.5
## condition 1): the A2 sequence's profiles in their Arch form, the
## fingerprint with the Arch components, and the preflight and bootstrap of an
## Arch guest.
##
## The guests are the Arch test bed's (``arch_testbed.nim``); everything
## else is the A2 test bed's (``addon_testbed.nim``). Nothing here starts or
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
  ## A2's generation 1 on Arch: a unit and an ``/etc`` file (no diversion:
  ## pacman has none, spec §4.3.1).
  addOnStanza(omarchyAccount) & fixtureUnit(reproExe) & "\n" &
    fixtureFile("fixture = 1\n")

proc gen2Profile*(omarchyAccount = ""): string =
  ## A2's generation 2: the unit removed, the file changed.
  addOnStanza(omarchyAccount) & fixtureFile("fixture = 2\n")

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
                    flags = ""): tuple[ok: bool; anchors: Anchors] =
  ## Preflight and bootstrap with the acknowledged plan digest; ``flags``
  ## (``--profile <file>`` on Omarchy) go to both, since bootstrap
  ## recomputes the plan from the same inputs.
  let anchors = g.installAnchors()
  result.anchors = anchors
  let pre = g.preflightArch(repro, anchors.flags & flags)
  step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
  if pre.exitCode != 0: return
  let boot = g.exec(repro & " system addon bootstrap --plan " &
    planDigestOf(pre.stdout) & anchors.flags & flags, timeoutSec = 1800)
  step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
  result.ok = boot.exitCode == 0

proc archGateRecord*(gate: string): JsonNode =
  ## The record every Arch gate writes: the A2 fields plus the Arch pins.
  result = archRecordBase()
  result["gate"] = %gate
  result["reprobuild"] = %gitHead()
  result["mutation"] = %mutation()
  result["testSeams"] = %testSeams()

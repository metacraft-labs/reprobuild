## What a gate written for the Debian bases needs to run, unchanged in its
## steps and checks, on the Arch guests and the Omarchy VM too (milestone
## AR4: A4's and A5's gates on Arch; spec ReproOS-Add-On-Mode §12.5
## condition 1).
##
## A gate names its bases with ``REPRO_ADDON_BASES`` as before; a name may
## now be a Debian base (``addon_testbed``) or an Arch-family one
## (``arch_testbed``: ``arch-btrfs-amd64``, ``arch-ext4-amd64``,
## ``omarchy-amd64``). Where the gates used a Debian-only fixture, the base
## family picks its counterpart here, and nowhere else:
##
## =======================  ==========================  ==========================
## what                     Debian                      Arch family
## =======================  ==========================  ==========================
## the guest                ``newGuest``,               ``newArchGuest``,
##                          ``prepareBase``             ``prepareArchGuest``
## a distribution service   ``cron.service`` (package   ``cronie.service``
## with a vendor unit       ``cron``)                   (package ``cronie``),
##                                                      enabled and started as
##                                                      Debian's package does
## a package's conffile     an ``equivs`` package and   a ``makepkg`` package
## the add-on takes         ``collision = "divert"``    whose file is in
##                                                      ``backup=``, and
##                                                      ``collision = "takeOver"``
##                                                      (``divert`` is
##                                                      ``EAddOnOutOfScope`` on
##                                                      Arch, spec §4.3.1)
## =======================  ==========================  ==========================
##
## On the Omarchy VM every operator profile names ``omarchyAccount`` and
## the preflight and bootstrap are given the host's first profile (spec
## §4.3.2, §6.1, §8.5): this module registers ``addon_testbed.baseAdapter``
## for that, so a gate's profiles are written as on Debian.
##
## Everything here runs before a gate's baseline: it is part of the base.
##
## *Mocking.* None: real guests, real packages.

import std/[os, strutils]

import ./addon_testbed
import ./arch_testbed
import ./arch_fixture_packages

export arch_testbed.isOmarchyBase

proc gateBaseNamed*(name: string): BaseImage =
  if isArchBase(name): archBaseNamed(name) else: baseNamed(name)

proc selectedGateBases*(): seq[BaseImage] =
  ## ``REPRO_ADDON_BASES``, Debian and Arch-family names alike; the Debian
  ## default when unset (as ``selectedBases``).
  let env = getEnv("REPRO_ADDON_BASES")
  if env.len == 0: return selectedBases()
  for n in env.split(','):
    if n.strip().len > 0: result.add(gateBaseNamed(n.strip()))

proc isArchFamily*(b: BaseImage): bool = isArchBase(b.name)

proc newGateGuest*(b: BaseImage; diskGiB = 0; cpus = 0; memoryMB = 0): Guest =
  ## A guest of ``b``, claimed and prepared, not booted. ``diskGiB`` 0 keeps
  ## the base's own default size.
  if b.isArchFamily:
    if diskGiB > 0: newArchGuest(b, diskGiB = diskGiB, cpus = cpus, memoryMB = memoryMB)
    else: newArchGuest(b, cpus = cpus, memoryMB = memoryMB)
  else:
    newGuest(b, diskGiB = (if diskGiB > 0: diskGiB else: 8), cpus = cpus,
             memoryMB = memoryMB)

proc prepareGateBase*(g: Guest) =
  ## After ``boot``: the base's own first-boot settling and pins. On the
  ## Omarchy VM also the first run of the base's ``snapper-cleanup.service``
  ## (its timer fires it ten minutes after boot, and it pulls in
  ## ``nss-user-lookup.target``), so that firing does not land between two
  ## fingerprints of a gate.
  if g.base.isArchFamily:
    g.prepareArchGuest()
    if isOmarchyBase(g.base):
      discard g.run("systemctl start snapper-cleanup.service", timeoutSec = 600)
  else: g.prepareBase()

proc bootVariance*(b: BaseImage; debian: openArray[string]): seq[string] =
  ## The fingerprint records two boots of ``b`` differ in that no switch
  ## makes: the gate's own list for its Debian bases, and on an Arch-family
  ## base ``arch_testbed.ArchBootVariance`` (a superset of it).
  result = @debian
  if b.isArchFamily:
    for v in ArchBootVariance:
      if v notin result: result.add(v)

proc resetVariance*(b: BaseImage): seq[string] =
  ## What a boot after a QEMU ``system_reset`` of an Arch-family guest may
  ## differ in beyond ``bootVariance``: the kernel's taint mask. On
  ## arch-ext4-amd64 a boot after a reset came up with ``kernel.tainted``
  ## 512 (TAINT_WARN, a kernel warning; measured 2026-11-17 under the
  ## build host's load). The add-on writes no state the kernel taints for,
  ## so the hard-reset gate does not count it; comparisons within one boot
  ## still do.
  if b.isArchFamily: @["sysctl:kernel.tainted"] else: @[]

proc settleAfterPacman(g: Guest) =
  ## A ``pacman`` transaction arms ``ConditionNeedsUpdate`` (its hook
  ## touches ``/usr``), so the next boot runs ``ldconfig``,
  ## ``systemd-sysusers``, ``systemd-journal-catalog-update`` and
  ## ``systemd-update-done`` once, and only that boot has them active. One
  ## reboot here takes that boot, so a gate's later boots all look alike.
  g.rebootGuest()
  discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                 timeoutSec = 600)

proc cronUnit*(b: BaseImage): string =
  ## The base's cron daemon's vendor unit.
  if b.isArchFamily: "cronie.service" else: "cron.service"

proc installCron*(g: Guest) =
  ## The base's cron daemon, installed, enabled and running, as Debian's
  ## ``cron`` package leaves it. On Arch from the guest's pinned archive
  ## (the Omarchy VM's capture has no cronie: the gates that use it run on
  ## the plain Arch guests).
  if g.base.isArchFamily:
    discard g.run("pacman -S --noconfirm --needed cronie >/dev/null && " &
                  "systemctl enable --now cronie.service", timeoutSec = 1800)
    g.settleAfterPacman()
  else:
    discard g.run("export DEBIAN_FRONTEND=noninteractive; " &
      "apt-get install -y -qq cron >/dev/null", timeoutSec = 1200)

proc conffileCollision*(b: BaseImage): string =
  ## The collision a profile declares to take over a package's conffile:
  ## ``divert`` on Debian, ``takeOver`` of a backup file on Arch.
  if b.isArchFamily: "takeOver" else: "divert"

proc installConffilePackage*(g: Guest; name, path, content: string) =
  ## A package that owns ``path`` (a conffile on Debian, a backup file on
  ## Arch) with ``content``, installed.
  if g.base.isArchFamily:
    g.installMakepkgPrerequisites()
    let pkg = g.buildArchFixture(ArchFixturePackage(name: name, pkgver: "1.0",
      pkgrel: "1", files: @[fxFile(path, content, backup = true)]))
    let r = g.pacmanInstall(pkg)
    if r.exitCode != 0:
      raise newException(TestBedError, "pacman -U " & pkg & " failed: " &
        r.stdout & r.stderr)
    g.settleAfterPacman()
  else:
    g.installEquivs()
    let deb = g.buildEquivsPackage(name, "1.0",
      @[(name: extractFilename(path), content: content,
         destDir: parentDir(path))])
    discard g.run("export DEBIAN_FRONTEND=noninteractive; dpkg -i " & deb &
                  " >/dev/null < /dev/null")

proc conffileTaken*(g: Guest; path: string): bool =
  ## Did the add-on take ``path`` over from its package? Debian: a dpkg
  ## diversion of it exists. Arch: the add-on's ledger copy records it with
  ## ``collision = takeOver`` and the package still owns it (pacman keeps
  ## the path; the add-on preserved the packaged bytes, spec §4.3.1).
  if g.base.isArchFamily:
    g.exec("grep -F '" & path & "' /var/lib/repro/system/addon-ledger | " &
           "grep -q takeOver && pacman -Qqo " & path).exitCode == 0
  else:
    g.exec("dpkg-divert --list " & path).stdout.contains(path)

# ---------------------------------------------------------------------------
# The Omarchy VM's profiles (``addon_testbed.baseAdapter``).
# ---------------------------------------------------------------------------

proc withOmarchyAccount*(text, account: string): string =
  ## ``text`` with ``omarchyAccount = "<account>"`` in its ``addOn``
  ## stanza (one is added, managing no prefix, when it has none): every
  ## operator profile on an Omarchy base names it (spec §8.5; §13 decision
  ## 94). A stanza that names an account already is left as it is.
  let head = "addOn {"
  let at = text.find(head)
  if at < 0:
    return "addOn {\n  managedEtcPrefixes = []\n  omarchyAccount = \"" &
      account & "\"\n}\n\n" & text
  let close = text.find('}', at)
  if close > at and "omarchyAccount" in text[at ..< close]: return text
  text[0 ..< at + head.len] & "\n  omarchyAccount = \"" & account & "\"" &
    text[at + head.len .. ^1]

baseAdapter = BaseAdapter(
  profileText: proc (g: Guest; text: string): string =
    if isOmarchyBase(g.base): withOmarchyAccount(text, OmarchyAccount)
    else: text,
  bootstrapFlags: proc (g: Guest): string =
    if not isOmarchyBase(g.base): return ""
    # The host's first profile: its addOn stanza names the account.
    " --profile " & g.putProfile("first", "addOn {\n  managedEtcPrefixes = []\n}\n"))


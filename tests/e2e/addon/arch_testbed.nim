## The add-on's Arch Linux test bed: QEMU guests built from the
## digest-pinned Arch Linux cloud image, with pacman pinned to one Arch
## Linux Archive date.
##
## It extends ``addon_testbed.nim`` (the A2 test bed) and reuses all of it:
## run directories claimed with an exclusive ``mkdir`` and an owner token,
## QEMU guests named with ``QemuNamePrefix``, each with its own user-mode
## network and a qcow2 overlay it owns, a cloud-init NoCloud seed with a key
## generated for the run, and the same ``exec`` / ``run`` / ``copyTo`` /
## ``shutdown`` / ``destroy``. QEMU processes are started and stopped by
## gosti, which kills only the PID it started.
##
## API for the gates
## =================
##
## .. code-block:: nim
##   import ./addon_testbed, ./arch_testbed
##
##   for b in selectedArchBases():       # REPRO_ADDON_BASES, default btrfs + ext4
##     var g = newArchGuest(b)           # an overlay over the cached built image
##     try:
##       g.boot()
##       g.prepareArchGuest()            # refuses an unpinned pacman (below)
##       let (repro, sha) = g.installArtefact()
##       ...                             # the gate
##     finally:
##       g.destroy()
##
## - ``ArchBtrfs`` (``arch-btrfs-amd64``): the cloud image as Arch publishes
##   it, whose root is btrfs (top-level subvolume, ``compress=zstd:1``).
## - ``ArchExt4`` (``arch-ext4-amd64``): the same installed system copied
##   onto an ext4 root (``archExt4Recipe`` below).
## - ``ArchOldSystemd`` (``arch-old-systemd-amd64``): the btrfs guest moved
##   back to ``ArchOldSystemdArchiveDate``, whose systemd major (257) is
##   below the add-on's matrix (systemd 258 or later, spec §6.1): the
##   preflight's refusal case. Not in the default selection.
## - ``archBaseNamed(name)``, ``archVariantOf(b)``, ``archiveDateOf(b)``.
## - ``newArchGuest(b; diskGiB = 8; cpus = 0; memoryMB = 0)``: claims a
##   run and prepares (does not boot) a guest over the built image of ``b``,
##   building it first when the cache has none for the current pin set.
## - ``prepareArchGuest(g)``: waits for cloud-init and for systemd to
##   settle, then enforces the pin: pacman's effective configuration
##   (``pacman-conf``, which resolves every ``Include``) must name, for
##   every repository, exactly the pinned archive date's URL and nothing
##   else. Anything else -- a live mirror, another date, a ``file://``
##   cache -- raises ``TestBedError`` before the gate does anything. This
##   is the refusal ``e2e_arch_testbed_is_pinned`` checks.
## - ``archGoldenImage(variant)``: the verified cached image (building it
##   when missing); ``buildArchImage(variant, outPath, ...)``: one fresh
##   build, for the pinning gate's two independent builds.
## - ``packageList(g)``, ``syuReport(g)``: what that gate compares.
##
## The Omarchy guest (spec §12.1, §13 decision 93) is not built here yet:
## see the AR1 report on which Omarchy version is pinned and what its
## installer is, now that Omarchy installs only from its ISO.
##
## Pins
## ====
##
## The pin set is ``ArchCloudImage`` (URL and SHA-256), the archive dates
## and ``ArchRecipeVersion``. Each is changed only by a commit. The built
## images are cached under ``<cache>/arch-images/<variant>-<pin-set digest>``
## and re-verified against the SHA-256 recorded when they were built before
## every use; a different pin set is a different directory, never an
## overwrite. Building takes the cache's lock (``flock``), so concurrent
## gates build an image once.
##
## *The archive date* (``ArchArchiveDate``). The Arch Linux Archive keeps a
## daily snapshot of every repository at ``archive.archlinux.org/repos/<date>``
## (https://wiki.archlinux.org/title/Arch_Linux_Archive). With the mirror
## list naming only that date, ``pacman -Syu`` resolves the same packages
## whenever it runs. ``2026/11/01`` is the cloud image's own date: on the
## image as published, ``pacman -Qu`` against it lists nothing (measured
## 2026-11-13), and the build's ``pacman -Syu`` changes nothing.
##
## *Base preparation* (the Arch counterpart of A2's apt adjustments; made
## when the image is built, so part of the base, not of anything a gate
## measures): the mirror list is replaced by the archive date's single
## ``Server`` line; ``archlinux-keyring-wkd-sync.timer`` is disabled (weekly,
## it refreshes ``/etc/pacman.d/gnupg`` from the network, which would change
## the ``etc`` fingerprint under a running gate); the package cache is
## emptied; cloud-init's instance state and the build key are removed, so
## every guest is a first boot of its own instance. The machine id and the
## pacman keyring made by the build's first boot are kept: resetting the
## machine id makes systemd treat the next boot as a first boot and apply
## the unit presets, which disable ``sshd`` and cloud-init on this image.
##
## *Mocking.* None: the real Arch Linux image, real pacman against the real
## Arch Linux Archive, real QEMU guests.

import std/[json, os, osproc, posix, strutils, tables, times]

import nimcrypto/[hash, sha2]

import ./addon_testbed

type
  ArchVariant* = enum
    avBtrfs = "btrfs"
    avExt4 = "ext4"
    avOldSystemd = "old-systemd"

const
  ArchCloudImage* = BaseImage(name: "arch-cloudimg-20261101.620452-amd64",
    debArch: "amd64",
    url: "https://geo.mirror.pkgbuild.com/images/v20261101.620452/Arch-Linux-x86_64-cloudimg-20261101.620452.qcow2",
    algo: "sha256",
    digest: "794eb4889b39e1f0ed7d5ae998b2a1ed2137db8cf8c3476cf2962c7437ecb003",
    file: "Arch-Linux-x86_64-cloudimg-20261101.620452.qcow2",
    osId: "arch", versionId: "",
    note: "arch-boxes cloud image; mirror.pkgbuild.com keeps about three " &
      "months of images, so a fresh cache needs a copy of this file " &
      "(verified against the digest) once the directory is gone")
    ## The published ``.SHA256`` beside the image names the same digest.

  ArchArchiveRoot* = "https://archive.archlinux.org/repos/"
  ArchArchiveDate* = "2026/11/01"
    ## The plain Arch guests' pin (see the module header).
  ArchOldSystemdArchiveDate* = "2025/09/15"
    ## The refusal fixture's date: ``core`` there holds systemd 257.9-1,
    ## pacman 7.0.0.r6.gc685ae6-6 and glibc 2.42+r17 (its ``core.db``, read
    ## 2026-11-13); systemd 258 reached ``core`` between 2025-09-15 and
    ## 2025-10-01.

  ArchRecipeVersion* = 1
    ## Bumped by any commit that changes how an image is built, so a cached
    ## image of an older recipe is never used.
  ArchExt4RootUuid = "5f3c7a52-9d0e-4b8a-a1a2-7c2d1e0b6a41"
    ## The ext4 root's filesystem UUID, fixed so that two builds make the
    ## same boot configuration.
  ArchImageGiB = 8
    ## The built images' virtual size; a guest's overlay may be larger.

  ArchBtrfs* = BaseImage(name: "arch-btrfs-amd64", debArch: "amd64",
    url: ArchCloudImage.url, algo: ArchCloudImage.algo,
    digest: ArchCloudImage.digest, file: ArchCloudImage.file,
    osId: "arch", versionId: "",
    note: "btrfs root, pacman pinned to the archive date " & ArchArchiveDate)
  ArchExt4* = BaseImage(name: "arch-ext4-amd64", debArch: "amd64",
    url: ArchCloudImage.url, algo: ArchCloudImage.algo,
    digest: ArchCloudImage.digest, file: ArchCloudImage.file,
    osId: "arch", versionId: "",
    note: "ext4 root, pacman pinned to the archive date " & ArchArchiveDate)
  ArchOldSystemd* = BaseImage(name: "arch-old-systemd-amd64", debArch: "amd64",
    url: ArchCloudImage.url, algo: ArchCloudImage.algo,
    digest: ArchCloudImage.digest, file: ArchCloudImage.file,
    osId: "arch", versionId: "",
    note: "btrfs root moved back to the archive date " &
      ArchOldSystemdArchiveDate & " (systemd 257)")
  ArchBases* = [ArchBtrfs, ArchExt4, ArchOldSystemd]
  DefaultArchBases* = ["arch-btrfs-amd64", "arch-ext4-amd64"]

proc archBaseNamed*(name: string): BaseImage =
  for b in ArchBases:
    if b.name == name: return b
  raise newException(TestBedError, "unknown Arch test-bed base: " & name)

proc isArchBase*(name: string): bool =
  for b in ArchBases:
    if b.name == name: return true
  false

proc archVariantOf*(b: BaseImage): ArchVariant =
  case b.name
  of ArchBtrfs.name: avBtrfs
  of ArchExt4.name: avExt4
  of ArchOldSystemd.name: avOldSystemd
  else: raise newException(TestBedError, b.name & " is not an Arch base")

proc archBaseOf*(v: ArchVariant): BaseImage =
  case v
  of avBtrfs: ArchBtrfs
  of avExt4: ArchExt4
  of avOldSystemd: ArchOldSystemd

proc archiveDateOf*(v: ArchVariant): string =
  if v == avOldSystemd: ArchOldSystemdArchiveDate else: ArchArchiveDate

proc archiveDateOf*(b: BaseImage): string = archiveDateOf(archVariantOf(b))

proc selectedArchBases*(): seq[BaseImage] =
  ## The Arch bases a gate runs on: ``REPRO_ADDON_BASES`` when it names
  ## any, otherwise ``DefaultArchBases``. A non-Arch name is refused rather
  ## than ignored, so a typo cannot shrink the matrix silently.
  let env = getEnv("REPRO_ADDON_BASES")
  if env.len == 0:
    for n in DefaultArchBases: result.add(archBaseNamed(n))
  else:
    for n in env.split(','):
      if n.strip().len > 0: result.add(archBaseNamed(n.strip()))

# ---------------------------------------------------------------------------
# The pacman pin and its refusal.
# ---------------------------------------------------------------------------

type
  PacmanServerRule* = object
    ## Which servers a guest's pacman may name. ``archiveDate``: exactly
    ## ``ArchArchiveRoot & date & "/<repo>/os/<arch>"`` per repository.
    ## ``captureRoot``: exactly ``captureRoot & "/<repo>"`` (the Omarchy
    ## guest's content-addressed capture cache, a ``file://`` URL).
    archiveDate*: string
    captureRoot*: string

  PacmanRepo* = object
    name*: string
    servers*: seq[string]

proc archiveRule*(date: string): PacmanServerRule =
  PacmanServerRule(archiveDate: date)

proc captureCacheRule*(root: string): PacmanServerRule =
  PacmanServerRule(captureRoot: root)

proc expectedServer*(rule: PacmanServerRule; repo, arch: string): string =
  if rule.captureRoot.len > 0:
    rule.captureRoot.strip(leading = false, chars = {'/'}) & "/" & repo
  else:
    ArchArchiveRoot & rule.archiveDate & "/" & repo & "/os/" & arch

proc pacmanServerViolations*(repos: seq[PacmanRepo]; rule: PacmanServerRule;
                             arch = "x86_64"): seq[string] =
  ## Every way ``repos`` (pacman's effective repositories and their
  ## servers) departs from ``rule``; empty when the configuration is
  ## pinned. A configuration with no repository at all is a violation too:
  ## a guest that cannot resolve anything pins nothing.
  if repos.len == 0:
    result.add("pacman names no repository")
  for r in repos:
    let want = rule.expectedServer(r.name, arch)
    if r.servers.len == 0:
      result.add("[" & r.name & "] names no server (expected " & want & ")")
    for s in r.servers:
      if s != want:
        result.add("[" & r.name & "] names " & s & " (only " & want &
                   " is pinned)")

proc parsePacmanConfDump*(dump: string): seq[PacmanRepo] =
  ## Parse ``PacmanConfDump``'s output: one ``<repo>\t`` line per
  ## repository, then one ``<repo>\t<server>`` line per server.
  var index = initTable[string, int]()
  for line in dump.splitLines():
    if line.len == 0: continue
    let tab = line.find('\t')
    if tab < 0:
      raise newException(TestBedError, "unexpected pacman-conf line: " & line)
    let repo = line[0 ..< tab]
    let server = line[tab + 1 .. ^1]
    if repo notin index:
      index[repo] = result.len
      result.add(PacmanRepo(name: repo))
    if server.len > 0:
      result[index[repo]].servers.add(server)

const PacmanConfDump* = "set -e; for r in $(pacman-conf --repo-list); do " &
  "printf '%s\\t\\n' \"$r\"; pacman-conf --repo=\"$r\" Server | " &
  "while IFS= read -r s; do printf '%s\\t%s\\n' \"$r\" \"$s\"; done; done"
  ## pacman's own view of its configuration: ``pacman-conf`` parses
  ## ``/etc/pacman.conf`` and every file it includes, and prints each
  ## repository's servers with ``$repo`` and ``$arch`` substituted
  ## (pacman-conf(8)).

proc pacmanRepos*(g: Guest): seq[PacmanRepo] =
  parsePacmanConfDump(g.run(PacmanConfDump))

proc requirePinnedPacman*(g: Guest; rule: PacmanServerRule) =
  ## Refuse (``TestBedError``) a guest whose pacman can resolve packages
  ## from anything but the pin.
  let v = pacmanServerViolations(g.pacmanRepos(), rule)
  if v.len > 0:
    raise newException(TestBedError, "refusing " & g.name & " (" &
      g.base.name & "): its pacman is not pinned: " & v.join("; "))
  g.note("pacman pinned: " & (if rule.captureRoot.len > 0: rule.captureRoot
                              else: "archive date " & rule.archiveDate))

static:
  # The rule's negative and positive controls, on pacman-conf output.
  let pinned = parsePacmanConfDump("core\t\ncore\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n" &
    "extra\t\nextra\thttps://archive.archlinux.org/repos/2026/11/01/extra/os/x86_64\n")
  doAssert pacmanServerViolations(pinned, archiveRule("2026/11/01")).len == 0
  doAssert pacmanServerViolations(pinned, archiveRule("2026/11/02")).len == 2
  let live = parsePacmanConfDump("core\t\ncore\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n" &
    "core\thttps://geo.mirror.pkgbuild.com/core/os/x86_64\nextra\t\n" &
    "extra\thttps://archive.archlinux.org/repos/2026/11/01/extra/os/x86_64\n")
  doAssert pacmanServerViolations(live, archiveRule("2026/11/01")).len == 1
  doAssert pacmanServerViolations(@[], archiveRule("2026/11/01")).len == 1
  let noServer = parsePacmanConfDump("core\t\n")
  doAssert pacmanServerViolations(noServer, archiveRule("2026/11/01")).len == 1
  let cache = parsePacmanConfDump("omarchy\t\nomarchy\tfile:///var/cache/tb/omarchy\n")
  doAssert pacmanServerViolations(cache, captureCacheRule("file:///var/cache/tb")).len == 0
  doAssert pacmanServerViolations(cache, archiveRule("2026/11/01")).len == 1
  doAssert pacmanServerViolations(pinned, captureCacheRule("file:///var/cache/tb")).len == 2

proc mirrorlistLine*(date: string): string =
  ## The one ``Server`` line of a guest pinned to ``date``.
  "Server = " & ArchArchiveRoot & date & "/$repo/os/$arch"

# ---------------------------------------------------------------------------
# Building the images.
# ---------------------------------------------------------------------------

proc sha256Hex(s: string): string =
  var ctx: sha256
  ctx.init()
  ctx.update(s)
  toLowerAscii($ctx.finish())

proc pinSet*(v: ArchVariant): string =
  ## The pins an image of ``v`` is a function of, one per line: what its
  ## cache directory is keyed by, and what a gate record names.
  result = "image " & ArchCloudImage.url & " sha256:" & ArchCloudImage.digest &
    "\narchive-date " & ArchArchiveDate & "\nrecipe " & $ArchRecipeVersion &
    "\nvariant " & $v & "\n"
  if v == avExt4: result.add("ext4-root-uuid " & ArchExt4RootUuid & "\n")
  if v == avOldSystemd:
    result.add("old-archive-date " & ArchOldSystemdArchiveDate & "\n")

proc pinSetDigest*(v: ArchVariant): string = sha256Hex(pinSet(v))

const CleanForImage = """
# What makes each guest a first boot of its own instance (module header).
cloud-init clean --logs --seed
rm -f /root/.ssh/authorized_keys /home/arch/.ssh/authorized_keys
rm -f /var/cache/pacman/pkg/*
"""
  ## Run last, in the same session as the power-off (``finishImage``): it
  ## removes the key the build reaches the guest with.

proc btrfsRecipe(): string =
  ## Run as root in a guest booted over the cloud image itself.
  "set -eu\n" &
  "cloud-init status --wait >/dev/null 2>&1 || true\n" &
  "printf '%s\\n' " & quoteShell(mirrorlistLine(ArchArchiveDate)) &
    " > /etc/pacman.d/mirrorlist\n" &
  "systemctl disable --now archlinux-keyring-wkd-sync.timer\n" &
  "pacman -Syu --noconfirm\n"

proc oldSystemdRecipe(): string =
  ## Run as root in a guest booted over a btrfs image. A system moved back
  ## to an earlier date takes that date's keyring as well: the current
  ## keyring has disabled keys that signed packages then (``base-3-2`` is
  ## signed by a key ``archlinux-keyring`` 20260909 disables; measured), so
  ## the older keyring is installed with the current one's verification,
  ## the keyring is re-made from it, and only then is everything moved
  ## back (``-Suu`` allows the downgrade). Packages the earlier date does
  ## not have are the later splits of packages it does (``gcc-libs`` into
  ## ``libgcc``, ``libstdc++``, ...; ``libmakepkg-dropins`` out of
  ## ``pacman``; measured): their database entries are dropped first
  ## (``--dbonly``: the running system keeps its libraries while pacman
  ## runs), and the earlier packages are installed over the files they
  ## leave untracked.
  "set -eu\n" &
  "cloud-init status --wait >/dev/null 2>&1 || true\n" &
  "printf '%s\\n' " & quoteShell(mirrorlistLine(ArchOldSystemdArchiveDate)) &
    " > /etc/pacman.d/mirrorlist\n" &
  "pacman -Syy\n" &
  "pacman -S --noconfirm archlinux-keyring\n" &
  # The keyring's gpg-agent still serves the directory about to go; stop it
  # through its own socket first, or the new keyring's master key cannot be
  # generated ("agent_genkey failed", measured).
  "gpgconf --homedir /etc/pacman.d/gnupg --kill gpg-agent\n" &
  "rm -rf /etc/pacman.d/gnupg\n" &
  "pacman-key --init\npacman-key --populate archlinux\n" &
  "foreign=$(pacman -Qmq || true)\n" &
  "[ -z \"$foreign\" ] || pacman -Rdd --dbonly --noconfirm $foreign\n" &
  "pacman -Suu --noconfirm --overwrite '*'\n" &
  "[ -z \"$(pacman -Qmq || true)\" ]\n" &
  "pacman -Q systemd pacman glibc\n"

proc ext4Recipe(): string =
  ## Run as root in a guest booted over a btrfs image with one empty data
  ## disk attached: copy the running system onto an ext4 root on that disk
  ## and make it bootable. The partition table is the boot disk's (BIOS
  ## boot, ESP, root), the ESP is copied byte for byte, the root is a fresh
  ## ext4 with ``ArchExt4RootUuid``. btrfs-only boot settings go:
  ## ``rootflags=compress=zstd:1`` on the kernel command line. The initramfs
  ## and GRUB (BIOS, as the guests boot) are re-made in the copy, so
  ## ``autodetect`` sees ext4. The subvolumes the image has (``swap``,
  ## ``var/lib/machines``, ``var/lib/portables``) become directories; the
  ## swap file is re-made at its size.
  "set -eu\n" &
  "cloud-init status --wait >/dev/null 2>&1 || true\n" &
  "t=''\nfor d in /sys/block/vd*; do n=${d##*/}; [ \"$n\" = vda ] && continue\n" &
  "  [ -n \"$(blkid -o value -s TYPE /dev/$n 2>/dev/null)\" ] && continue\n" &
  "  t=/dev/$n; done\n" &
  "[ -n \"$t\" ] || { echo 'no empty data disk' >&2; exit 1; }\n" &
  "sfdisk -d /dev/vda | sed \"s#/dev/vda#$t#g\" | sfdisk -q \"$t\"\n" &
  "udevadm settle\n" &
  "dd if=/dev/vda1 of=${t}1 bs=1M status=none\n" &
  "dd if=/dev/vda2 of=${t}2 bs=1M status=none\n" &
  "mkfs.ext4 -q -F -U " & ArchExt4RootUuid & " ${t}3\n" &
  "mount ${t}3 /mnt\n" &
  "cp -ax / /mnt/\n" &
  "mkdir -p /mnt/swap /mnt/var/lib/machines /mnt/var/lib/portables /mnt/efi " &
    "/mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp\n" &
  "chmod 0700 /mnt/var/lib/machines /mnt/var/lib/portables\n" &
  "if [ -f /swap/swapfile ]; then sz=$(stat -c %s /swap/swapfile); " &
    "rm -f /mnt/swap/swapfile; fallocate -l \"$sz\" /mnt/swap/swapfile; " &
    "chmod 0600 /mnt/swap/swapfile; mkswap -q /mnt/swap/swapfile; fi\n" &
  "sed -i 's/ *rootflags=compress=zstd:1//' /mnt/etc/default/grub\n" &
  "! grep -q rootflags /mnt/etc/default/grub\n" &
  "mount --rbind /dev /mnt/dev\nmount --make-rslave /mnt/dev\n" &
  "mount -t proc proc /mnt/proc\nmount -t sysfs sysfs /mnt/sys\n" &
  "chroot /mnt mkinitcpio -P >/dev/null\n" &
  "chroot /mnt grub-install --target=i386-pc \"$t\" >/dev/null 2>&1\n" &
  "chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1\n" &
  "grep -q 'root=UUID=" & ArchExt4RootUuid & "' /mnt/boot/grub/grub.cfg\n" &
  "chroot /mnt sh -c " & quoteShell(CleanForImage) & "\n" &
  "umount -R /mnt\nsync\n"

type
  ArchBuild* = object
    ## One built image and what its build saw.
    variant*: ArchVariant
    path*: string            ## the standalone qcow2
    sha256*: string
    pinSet*: string
    startedAt*, finishedAt*: string
    seconds*: float
    log*: seq[string]

proc convertTo*(src, dst: string) =
  ## A standalone qcow2 of ``src`` (its backing chain flattened), written to
  ## a temporary name first so ``dst`` is never a partial image.
  let part = dst & ".part-" & $getCurrentProcessId()
  if execCmd("qemu-img convert -q -O qcow2 " & quoteShell(src) & " " &
             quoteShell(part)) != 0:
    removeFile(part)
    raise newException(TestBedError, "qemu-img convert of " & src & " failed")
  moveFile(part, dst)

proc runRecipe(g: Guest; recipe, what: string) =
  writeFile(g.runDir / "recipe.sh", recipe)
  g.copyTo(g.runDir / "recipe.sh", "/root/arch-testbed-recipe.sh")
  let r = g.exec("bash /root/arch-testbed-recipe.sh > /root/arch-testbed-recipe.log " &
                 "2>&1; rc=$?; tail -n 60 /root/arch-testbed-recipe.log; " &
                 "rm -f /root/arch-testbed-recipe.sh /root/arch-testbed-recipe.log; " &
                 "exit $rc", timeoutSec = 3600)
  g.note(what & " exited " & $r.exitCode & "; its log's tail:\n" & r.stdout)
  if r.exitCode != 0:
    raise newException(TestBedError, what & " failed (" & $r.exitCode &
      "):\n" & r.stdout & r.stderr)

proc finishImage(g: Guest) =
  ## Clean the guest for use as an image and power it off, in one session:
  ## the cleaning removes the build's SSH key, so nothing can follow it.
  discard g.exec(CleanForImage & "fstrim -a >/dev/null 2>&1 || true\nsync\n" &
                 "systemctl poweroff", timeoutSec = 120)
  if not g.waitPoweredOff(300):
    raise newException(TestBedError, g.name & " did not power off after " &
      "its image was cleaned")

proc buildArchImage*(v: ArchVariant; outPath: string;
                     btrfsImage = ""): ArchBuild =
  ## Build one image of ``v`` into ``outPath`` (a fresh path; never an
  ## existing file), from the pins alone. ``avExt4`` and ``avOldSystemd``
  ## start from the btrfs image ``btrfsImage`` (the pinning gate's own
  ## build, or the cached one).
  if fileExists(outPath):
    raise newException(TestBedError, "refusing to build over " & outPath)
  let t0 = epochTime()
  result = ArchBuild(variant: v, path: outPath, pinSet: pinSet(v),
                     startedAt: $now().utc)
  var g: Guest
  var data: DataDisk
  try:
    case v
    of avBtrfs:
      g = newGuest(ArchCloudImage, diskGiB = ArchImageGiB)
      g.boot()
      g.runRecipe(btrfsRecipe(), "the btrfs image's build")
      g.finishImage()
      convertTo(g.diskPath, outPath)
    of avOldSystemd:
      if btrfsImage.len == 0:
        raise newException(TestBedError, "the old-systemd image is built " &
          "from a btrfs image; none was given")
      g = newGuest(ArchBtrfs, diskGiB = ArchImageGiB, image = btrfsImage)
      g.boot()
      g.runRecipe(oldSystemdRecipe(), "the old-systemd image's build")
      g.finishImage()
      convertTo(g.diskPath, outPath)
    of avExt4:
      if btrfsImage.len == 0:
        raise newException(TestBedError, "the ext4 image is built from a " &
          "btrfs image; none was given")
      data = newDataDisk(ArchImageGiB)
      g = newGuest(ArchBtrfs, diskGiB = ArchImageGiB, image = btrfsImage)
      g.dataDisks = @[data.path]
      g.boot()
      g.runRecipe(ext4Recipe(), "the ext4 image's build")
      g.shutdown()
      convertTo(data.path, outPath)
    result.log = g.log
  finally:
    if g != nil: g.destroy()
    data.release()
  result.sha256 = fileDigest(outPath, "sha256")
  result.finishedAt = $now().utc
  result.seconds = epochTime() - t0

# ---------------------------------------------------------------------------
# The cache of built images.
# ---------------------------------------------------------------------------

proc c_flock(fd: cint; op: cint): cint {.importc: "flock", header: "<sys/file.h>".}
const LockEx = cint(2)

proc archImageDir*(v: ArchVariant): string =
  cacheDir() / "arch-images" / ($v & "-" & pinSetDigest(v)[0 ..< 16])

proc verifiedCachedImage(v: ArchVariant): string =
  ## The cached image of ``v``'s pin set, re-verified; "" when none.
  let dir = archImageDir(v)
  let img = dir / "disk.qcow2"
  let sumFile = dir / "disk.qcow2.sha256"
  if not fileExists(img): return ""
  if not fileExists(sumFile) or not fileExists(dir / "pinset"):
    raise newException(TestBedError, "cached Arch image " & img &
      " has no recorded digest or pin set; delete " & dir & " by hand " &
      "after checking why")
  if readFile(dir / "pinset") != pinSet(v):
    raise newException(TestBedError, dir & " was built from another pin set")
  let want = readFile(sumFile).strip()
  let have = fileDigest(img, "sha256")
  if have != want:
    raise newException(TestBedError, "cached Arch image " & img &
      " hashes to " & have & ", not the " & want & " recorded when it was " &
      "built; delete " & dir & " by hand after checking why")
  img

proc archGoldenImage*(v: ArchVariant): string =
  ## The verified cached image of ``v`` for the current pin set, built
  ## first (under the cache's lock) when there is none.
  let cached = verifiedCachedImage(v)
  if cached.len > 0: return cached
  # The btrfs image the others are built from, resolved before this call
  # takes the lock: a flock is held per open file, so taking it again from
  # a nested call in the same process would wait for itself.
  let btrfs = if v == avBtrfs: "" else: archGoldenImage(avBtrfs)
  let base = cacheDir() / "arch-images"
  createDir(base)
  let lockPath = base / ".build.lock"
  let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT, Mode(0o600))
  if fd < 0:
    raise newException(TestBedError, "cannot open " & lockPath)
  defer: discard posix.close(fd)
  if c_flock(fd, LockEx) != 0:
    raise newException(TestBedError, "cannot lock " & lockPath)
  # Another process may have built it while this one waited.
  let again = verifiedCachedImage(v)
  if again.len > 0: return again
  let dir = archImageDir(v)
  createDir(dir)
  let img = dir / "disk.qcow2"
  # Built under another name and renamed last, after its digest and pin set
  # are written, so a build that died leaves no image without them. A
  # leftover from such a build is this cache's own, and the lock is held.
  let building = img & ".building"
  if fileExists(building): removeFile(building)
  stderr.writeLine($now() & " building the Arch " & $v & " image into " & dir)
  let b = buildArchImage(v, building, btrfsImage = btrfs)
  writeFile(dir / "disk.qcow2.sha256", b.sha256 & "\n")
  writeFile(dir / "pinset", b.pinSet)
  writeFile(dir / "build-log", b.log.join("\n") & "\n")
  moveFile(building, img)
  img

proc newArchGuest*(b: BaseImage; diskGiB = ArchImageGiB; cpus = 0;
                   memoryMB = 0): Guest =
  ## Claim a run and prepare (not boot) a guest of the Arch base ``b``
  ## over its cached built image. ``prepareArchGuest`` after the boot.
  if useIncus():
    raise newException(TestBedError, "the Arch test bed is QEMU only")
  if diskGiB < ArchImageGiB:
    raise newException(TestBedError, "an Arch guest's disk is at least " &
      $ArchImageGiB & " GiB")
  newGuest(b, diskGiB = diskGiB, cpus = cpus, memoryMB = memoryMB,
           image = archGoldenImage(archVariantOf(b)))

proc newArchGuestOver*(b: BaseImage; image: string;
                       diskGiB = ArchImageGiB): Guest =
  ## A guest of ``b`` over an image the caller built and owns (the pinning
  ## gate's independent builds and its negative control).
  newGuest(b, diskGiB = diskGiB, image = image)

proc prepareArchGuest*(g: Guest) =
  ## First-boot completion, then the pin check: refuses (raises) a guest
  ## whose pacman names anything but its archive date.
  discard g.exec("cloud-init status --wait >/dev/null 2>&1 || true",
                 timeoutSec = 600)
  discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                 timeoutSec = 600)
  g.requirePinnedPacman(archiveRule(archiveDateOf(g.base)))

# ---------------------------------------------------------------------------
# What the pinning gate compares.
# ---------------------------------------------------------------------------

proc packageList*(g: Guest): string =
  ## ``pacman -Q``: every installed package and its version, sorted.
  g.run("pacman -Q")

proc rootFsType*(g: Guest): string =
  g.run("findmnt -no FSTYPE /").strip()

type SyuReport* = object
  exitCode*: int
  output*: string
  noop*: bool
  detail*: string

proc syuReport*(g: Guest; env = ""): SyuReport =
  ## Run ``pacman -Syu --noconfirm`` (with ``env`` prefixed, e.g.
  ## ``OMARCHY_ALLOW_DIRECT_PACMAN=1``) and judge whether it was a no-op:
  ## exit 0, pacman's own "there is nothing to do", no package listed as
  ## newer than its repository (a guest ahead of the pin), and ``pacman -Q``
  ## unchanged.
  let before = g.packageList()
  let r = g.exec((if env.len > 0: env & " " else: "") &
                 "pacman -Syu --noconfirm 2>&1", timeoutSec = 1800)
  let after = g.packageList()
  result = SyuReport(exitCode: r.exitCode, output: r.stdout & r.stderr)
  var why: seq[string]
  if r.exitCode != 0: why.add("exit " & $r.exitCode)
  if "there is nothing to do" notin result.output:
    why.add("pacman did not report \"there is nothing to do\"")
  if "is newer than" in result.output:
    why.add("a package is newer than the pinned repositories")
  if before != after: why.add("pacman -Q changed")
  result.noop = why.len == 0
  result.detail = if why.len == 0: "no-op" else: why.join("; ")

proc archRecordBase*(): JsonNode =
  ## The pins every Arch gate record names.
  %*{"archCloudImage": ArchCloudImage.url,
     "archCloudImageSha256": ArchCloudImage.digest,
     "archArchiveDate": ArchArchiveDate,
     "archOldSystemdArchiveDate": ArchOldSystemdArchiveDate,
     "archRecipeVersion": ArchRecipeVersion}

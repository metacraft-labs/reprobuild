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
## - ``OmarchyBase`` (``omarchy-amd64``): Omarchy ``OmarchyVersion`` as its
##   own installer lays it out (btrfs ``@``/``@home``/``@log``/``@pkg``,
##   snapper configured for ``/``, Limine, UEFI), the account
##   ``OmarchyAccount``. ``newArchGuest`` / ``prepareArchGuest`` accept it,
##   or call ``newOmarchyGuest`` / ``prepareOmarchyGuest`` directly; the
##   guest is reached as root with the image's key and has no cloud-init.
##   ``prepareOmarchyGuest`` refuses a guest whose pacman names any server
##   but the capture cache. A gate that runs ``pacman -Syu`` on it sets
##   ``OMARCHY_ALLOW_DIRECT_PACMAN=1`` in the guest and says so in its
##   record (spec §7.9); nothing here sets it on a host.
##
## The Omarchy guest (spec §12.1, §13 decision 93 as the owner amended it on
## 2026-11-14) is not derived from the cloud image. ``buildOmarchyImage``
## boots the SHA-256-pinned Omarchy ISO (``OmarchyIso``) in QEMU with no
## network and drives Omarchy's own installer unattended through its
## autoinstall volume (``omarchyCidataFiles``); then it points every pacman
## repository at the capture cache (``OmarchyCaptureRoot``, a ``file://``
## repository) and runs ``pacman -Syu`` from it. The capture -- the ISO,
## the ``stable-mirror.omarchy.org`` and ``pkgs.omarchy.org`` databases and
## every package and signature the install resolves against them -- is kept
## by SHA-256 in ``<cache>/capture/sha256`` and listed in the committed
## ``fixtures/omarchy/omarchy-<version>.capture``; ``capture_omarchy.nim``
## writes it (``just addon-omarchy-capture``), and a build reads only the
## list and the cache, so it needs no network at all.
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

when defined(gostiAvailable):
  import gosti

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
  OmarchyIso* = BaseImage(name: "omarchy-iso-4.5.0-x86", debArch: "amd64",
    url: "https://iso.omarchy.org/omarchy-4.5.0-x86.iso",
    algo: "sha256",
    digest: "5d6288bc57f96f6231719830457582c846a2291985201c36a9a7d1216978b00f",
    file: "omarchy-4.5.0-x86.iso", osId: "omarchy", versionId: "4.5.0",
    note: "the x86_64 ISO of the 2026-11-05 release (arch/version " &
      "2026.11.05); Omarchy serves only its current ISO, so the content " &
      "cache holds the pinned bytes")
  OmarchyBase* = BaseImage(name: "omarchy-amd64", debArch: "amd64",
    url: OmarchyIso.url, algo: OmarchyIso.algo, digest: OmarchyIso.digest,
    file: OmarchyIso.file, osId: "omarchy", versionId: "4.5.0",
    note: "Omarchy 4.5.0-3 installed by its own ISO installer")

proc archBaseNamed*(name: string): BaseImage =
  ## An Arch base by name, the Omarchy guest (``omarchy-amd64``) included.
  if name == OmarchyBase.name: return OmarchyBase
  for b in ArchBases:
    if b.name == name: return b
  raise newException(TestBedError, "unknown Arch test-bed base: " & name)

proc isArchBase*(name: string): bool =
  if name == OmarchyBase.name: return true
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
    cacheServers*: seq[string]
      ## ``CacheServer`` entries (pacman.conf(5), pacman >= 7.0): pacman
      ## downloads from them before any ``Server``, so an unpinned one
      ## unpins the guest exactly as an unpinned ``Server`` does.

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
    for s in r.cacheServers:
      if s != want:
        result.add("[" & r.name & "] names CacheServer " & s & " (only " &
                   want & " is pinned)")

const PacmanServerKeys* = ["Server", "CacheServer"]
  ## Every per-repository key through which pacman.conf(5) names a URL
  ## pacman downloads packages from. ``pacman-conf`` exits non-zero for a
  ## key it does not know, so a pacman without ``CacheServer`` fails the
  ## dump (closed) rather than silently reporting none.

proc parsePacmanConfDump*(dump: string): seq[PacmanRepo] =
  ## Parse ``PacmanConfDump``'s output: one ``<repo>\t`` line per
  ## repository, then one ``<repo>\t<key>\t<url>`` line per server, where
  ## ``<key>`` is one of ``PacmanServerKeys``. Any other shape, or another
  ## key, is refused: the pin check must not skip a line it cannot read.
  var index = initTable[string, int]()
  for line in dump.splitLines():
    if line.len == 0: continue
    let fields = line.split('\t')
    if fields.len notin [2, 3] or fields[0].len == 0 or
       (fields.len == 2 and fields[1].len > 0) or
       (fields.len == 3 and (fields[1] notin PacmanServerKeys or
                             fields[2].len == 0)):
      raise newException(TestBedError, "unexpected pacman-conf line: " & line)
    let repo = fields[0]
    if repo notin index:
      index[repo] = result.len
      result.add(PacmanRepo(name: repo))
    if fields.len == 3:
      if fields[1] == "Server": result[index[repo]].servers.add(fields[2])
      else: result[index[repo]].cacheServers.add(fields[2])

const PacmanConfDump* = "set -e; for r in $(pacman-conf --repo-list); do " &
  "printf '%s\\t\\n' \"$r\"; for k in Server CacheServer; do " &
  "v=$(pacman-conf --repo=\"$r\" \"$k\"); " &
  "printf '%s\\n' \"$v\" | while IFS= read -r s; do [ -n \"$s\" ] || continue; " &
  "printf '%s\\t%s\\t%s\\n' \"$r\" \"$k\" \"$s\"; done; done; done"
  ## pacman's own view of its configuration: ``pacman-conf`` parses
  ## ``/etc/pacman.conf`` and every file it includes, and prints each
  ## repository's ``Server`` and ``CacheServer`` values with ``$repo`` and
  ## ``$arch`` substituted (pacman-conf(8)). Each ``pacman-conf`` call is
  ## a plain assignment rather than the head of a pipeline so that
  ## ``set -e`` sees its exit status, and nothing is written to the guest.

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
  let pinned = parsePacmanConfDump("core\t\ncore\tServer\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n" &
    "extra\t\nextra\tServer\thttps://archive.archlinux.org/repos/2026/11/01/extra/os/x86_64\n")
  doAssert pacmanServerViolations(pinned, archiveRule("2026/11/01")).len == 0
  doAssert pacmanServerViolations(pinned, archiveRule("2026/11/02")).len == 2
  let live = parsePacmanConfDump("core\t\ncore\tServer\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n" &
    "core\tServer\thttps://geo.mirror.pkgbuild.com/core/os/x86_64\nextra\t\n" &
    "extra\tServer\thttps://archive.archlinux.org/repos/2026/11/01/extra/os/x86_64\n")
  doAssert pacmanServerViolations(live, archiveRule("2026/11/01")).len == 1
  doAssert pacmanServerViolations(@[], archiveRule("2026/11/01")).len == 1
  let noServer = parsePacmanConfDump("core\t\n")
  doAssert pacmanServerViolations(noServer, archiveRule("2026/11/01")).len == 1
  let cache = parsePacmanConfDump("omarchy\t\nomarchy\tServer\tfile:///var/cache/tb/omarchy\n")
  doAssert pacmanServerViolations(cache, captureCacheRule("file:///var/cache/tb")).len == 0
  doAssert pacmanServerViolations(cache, archiveRule("2026/11/01")).len == 1
  doAssert pacmanServerViolations(pinned, captureCacheRule("file:///var/cache/tb")).len == 2
  # A live CacheServer beside a pinned Server is refused; one equal to
  # the pin is not.
  let liveCache = parsePacmanConfDump("core\t\ncore\tServer\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n" &
    "core\tCacheServer\thttps://geo.mirror.pkgbuild.com/core/os/x86_64\n")
  doAssert liveCache[0].cacheServers.len == 1
  doAssert pacmanServerViolations(liveCache, archiveRule("2026/11/01")).len == 1
  let pinnedCache = parsePacmanConfDump("core\t\ncore\tServer\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n" &
    "core\tCacheServer\thttps://archive.archlinux.org/repos/2026/11/01/core/os/x86_64\n")
  doAssert pacmanServerViolations(pinnedCache, archiveRule("2026/11/01")).len == 0
  # Lines the parser cannot read are refused, never skipped.
  for bad in ["core\tMirror\thttps://x\n", "core\thttps://x\n", "core\n",
              "core\tServer\t\n"]:
    var raised = false
    try: discard parsePacmanConfDump(bad)
    except TestBedError: raised = true
    doAssert raised, bad

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
    extraFiles*: seq[(string, string)]
      ## Files the image needs beside it (name in the cache, path now): the
      ## Omarchy image's SSH key.

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

proc verifiedCachedImageAt(dir, pins, what: string): string =
  ## The image cached in ``dir`` for the pin set ``pins``, re-verified
  ## against the SHA-256 recorded when it was built; "" when none.
  let img = dir / "disk.qcow2"
  let sumFile = dir / "disk.qcow2.sha256"
  if not fileExists(img): return ""
  if not fileExists(sumFile) or not fileExists(dir / "pinset"):
    raise newException(TestBedError, "cached " & what & " image " & img &
      " has no recorded digest or pin set; delete " & dir & " by hand " &
      "after checking why")
  if readFile(dir / "pinset") != pins:
    raise newException(TestBedError, dir & " was built from another pin set")
  let want = readFile(sumFile).strip()
  let have = fileDigest(img, "sha256")
  if have != want:
    raise newException(TestBedError, "cached " & what & " image " & img &
      " hashes to " & have & ", not the " & want & " recorded when it was " &
      "built; delete " & dir & " by hand after checking why")
  img

type ImageBuilder = proc(outPath: string): ArchBuild

proc cachedImage(dir, pins, what: string; build: ImageBuilder): string =
  ## The verified image in ``dir``, built first with ``build`` when the
  ## cache has none. The build runs under the cache's lock (``flock``), so
  ## concurrent gates build it once. The image is built under another name
  ## and renamed last, after its digest and pin set are written, so a build
  ## that died leaves no image without them; a leftover from such a build is
  ## this cache's own, and the lock is held. A builder whose image needs
  ## another cached image resolves it BEFORE this call: a flock is held per
  ## open file, so taking it again from a nested call in the same process
  ## would wait for itself.
  let cached = verifiedCachedImageAt(dir, pins, what)
  if cached.len > 0: return cached
  let base = parentDir(dir)
  createDir(base)
  let lockPath = base / ".build.lock"
  let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT, Mode(0o600))
  if fd < 0:
    raise newException(TestBedError, "cannot open " & lockPath)
  defer: discard posix.close(fd)
  if c_flock(fd, LockEx) != 0:
    raise newException(TestBedError, "cannot lock " & lockPath)
  # Another process may have built it while this one waited.
  let again = verifiedCachedImageAt(dir, pins, what)
  if again.len > 0: return again
  createDir(dir)
  let img = dir / "disk.qcow2"
  let building = img & ".building"
  if fileExists(building): removeFile(building)
  stderr.writeLine($now() & " building the " & what & " image into " & dir)
  let b = build(building)
  for (name, src) in b.extraFiles:
    moveFile(src, dir / name)
  writeFile(dir / "disk.qcow2.sha256", b.sha256 & "\n")
  writeFile(dir / "pinset", b.pinSet)
  writeFile(dir / "build-log", b.log.join("\n") & "\n")
  moveFile(building, img)
  img

proc archGoldenImage*(v: ArchVariant): string =
  ## The verified cached image of ``v`` for the current pin set, built
  ## first (under the cache's lock) when there is none.
  let ready = verifiedCachedImageAt(archImageDir(v), pinSet(v), "Arch " & $v)
  if ready.len > 0: return ready
  let btrfs = if v == avBtrfs: "" else: archGoldenImage(avBtrfs)
  cachedImage(archImageDir(v), pinSet(v), "Arch " & $v,
    proc(outPath: string): ArchBuild =
      buildArchImage(v, outPath, btrfsImage = btrfs))

# ---------------------------------------------------------------------------
# The Omarchy guest (spec §12.1, §13 decision 93 as amended by the owner on
# 2026-11-14).
# ---------------------------------------------------------------------------

const
  OmarchyVersion* = "4.5.0-3"
    ## The pinned ``omarchy`` package (``omarchy-version``).
  OmarchyBuildId* = "4.5.0"
    ## ``BUILD_ID`` in the installed system's ``os-release``.
  OmarchyAccount* = "omarchy"
    ## The account the install creates: the ``omarchyAccount`` of a profile
    ## (spec §4.3.2, §8.5).
  OmarchyAccountPassword = "omarchy"
    ## The test account's password: the guest's SSH is reachable on the
    ## build host's loopback only, and its key is the test bed's.
  OmarchyImageGiB* = 40
    ## The install disk's virtual size, as Omarchy's own install test sizes it.
  OmarchyRecipeVersion* = 1
  OmarchyRepoServers* = {
    "core": "https://stable-mirror.omarchy.org/core/os/x86_64",
    "extra": "https://stable-mirror.omarchy.org/extra/os/x86_64",
    "multilib": "https://stable-mirror.omarchy.org/multilib/os/x86_64",
    "omarchy": "https://pkgs.omarchy.org/stable/x86_64"}
    ## Where the capture fetched each repository from: Omarchy's snapshot of
    ## Arch, and Omarchy's own repository (spec §4.3.2).
  OmarchyCaptureRoot* = "/var/cache/repro-testbed/capture"
    ## The capture cache inside the guest; every repository's only server
    ## is ``file://<this>/<repo>``.
  OmarchyCaptureManifest* = currentSourcePath().parentDir / "fixtures" /
    "omarchy" / ("omarchy-" & OmarchyVersion & ".capture")
    ## The SHA-256 list of every captured file (the ISO, each repository
    ## database, each package), committed: changing it is a commit.

proc omarchyCaptureRule*(): PacmanServerRule =
  captureCacheRule("file://" & OmarchyCaptureRoot)

proc isOmarchyBase*(b: BaseImage): bool = b.name == OmarchyBase.name

# -- The content-addressed cache. --------------------------------------------

proc casDir*(): string =
  result = cacheDir() / "capture" / "sha256"
  createDir(result)

proc casPath*(hex: string): string = casDir() / hex

proc casPut(src: string): string =
  ## Move ``src`` into the cache under its SHA-256; returns the digest. An
  ## entry already there must hash the same (it is then left as it is).
  result = fileDigest(src, "sha256")
  let dst = casPath(result)
  if fileExists(dst):
    removeFile(src)
  else:
    moveFile(src, dst)
    setFilePermissions(dst, {fpUserRead, fpGroupRead, fpOthersRead})

proc casVerified*(hex: string): string =
  ## The cache entry ``hex``, re-hashed; raises when it is missing or its
  ## bytes changed. A missing entry cannot be fetched again by name:
  ## Omarchy keeps only its current release, so the capture is the only copy.
  result = casPath(hex)
  if not fileExists(result):
    raise newException(TestBedError, "the content cache has no " & hex &
      " (" & result & "); the capture of Omarchy " & OmarchyVersion &
      " is the only copy of these bytes. Restore the cache, or re-capture " &
      "with tests/e2e/addon/capture_omarchy.nim and commit the new list")
  let have = fileDigest(result, "sha256")
  if have != hex:
    raise newException(TestBedError, result & " hashes to " & have &
      "; delete it by hand after checking why")

proc download(url, dst: string) =
  let part = dst & ".part-" & $getCurrentProcessId()
  if execCmd("curl -sSfL --retry 5 --retry-all-errors -o " & quoteShell(part) & " " &
             quoteShell(url)) != 0:
    removeFile(part)
    raise newException(TestBedError, "download failed: " & url)
  moveFile(part, dst)

type
  CaptureEntry* = object
    sha256*: string
    size*: BiggestInt
    path*: string     ## ``iso/<file>`` or ``repo/<repo>/<file>``

proc parseCaptureManifest*(text: string): seq[CaptureEntry] =
  for line in text.splitLines():
    let t = line.strip()
    if t.len == 0 or t.startsWith("#"): continue
    let f = t.splitWhitespace()
    if f.len != 3 or f[0].len != 64:
      raise newException(TestBedError, "bad capture line: " & line)
    result.add(CaptureEntry(sha256: f[0], size: parseBiggestInt(f[1]),
                            path: f[2]))

proc renderCaptureManifest*(entries: seq[CaptureEntry]; header: string): string =
  result = header
  for e in entries:
    result.add(e.sha256 & " " & $e.size & " " & e.path & "\n")

proc omarchyCapture*(): seq[CaptureEntry] =
  ## The committed capture list; it must name the pinned ISO.
  if not fileExists(OmarchyCaptureManifest):
    raise newException(TestBedError, "no capture list at " &
      OmarchyCaptureManifest)
  result = parseCaptureManifest(readFile(OmarchyCaptureManifest))
  var iso = false
  for e in result:
    if e.path == "iso/" & OmarchyIso.file and e.sha256 == OmarchyIso.digest:
      iso = true
  if not iso:
    raise newException(TestBedError, OmarchyCaptureManifest &
      " does not name the pinned ISO " & OmarchyIso.digest)

proc omarchyIsoPath*(): string =
  ## The pinned ISO from the content cache, fetched into it (and checked
  ## against the pin) when it is not there yet.
  let p = casPath(OmarchyIso.digest)
  if not fileExists(p):
    let tmp = casDir() / (".iso-" & $getCurrentProcessId())
    download(OmarchyIso.url, tmp)
    let got = casPut(tmp)
    if got != OmarchyIso.digest:
      raise newException(TestBedError, OmarchyIso.url & " hashes to " & got &
        ", not the pinned " & OmarchyIso.digest)
  casVerified(OmarchyIso.digest)

# -- Installing from the ISO. ------------------------------------------------

proc omarchyCidataFiles(pub: string): seq[(string, string)] =
  ## Omarchy's autoinstall inputs (the configurator's own output files, read
  ## off a volume labelled CIDATA by the ISO's ``omarchy-cidata-load``), the
  ## way Omarchy's install test writes them (omacom/omarchy-iso
  ## ``test/integration.d/base-test.sh`` ``build_cidata``, identical at
  ## 69f9a702, the commit the 2026.11.05 ISO's installer matches): the full
  ## disk, a 2 GiB ESP and a btrfs root with ``@``, ``@home``, ``@log`` and
  ## ``@pkg``, Limine, no encryption. The same volume's NoCloud
  ## ``user-data`` authorises the run's key for the LIVE system's root, which
  ## is how the build watches the install; the installed system has no
  ## cloud-init, and the installer copies ``authorized_keys`` to the account.
  let mib = 1024'i64 * 1024
  let gib = 1024'i64 * mib
  let diskBytes = OmarchyImageGiB.int64 * gib
  let bootStart = mib
  let bootSize = 2 * gib
  let mainStart = bootStart + bootSize
  let mainSize = diskBytes - mainStart - mib
  let (hashOut, rc) = execCmdEx("openssl passwd -6 -salt reproaddontb " &
                                quoteShell(OmarchyAccountPassword))
  if rc != 0:
    raise newException(TestBedError, "openssl passwd failed: " & hashOut)
  let hash = hashOut.strip()
  let creds = %*{"root_enc_password": hash, "users": [{"enc_password": hash,
    "groups": [], "sudo": true, "username": OmarchyAccount}]}
  let config = %*{
    "app_config": nil, "archinstall-language": "English", "auth_config": {},
    "audio_config": {"audio": "pipewire"},
    "bootloader_config": {"bootloader": "Limine", "uki": false,
                          "removable": false},
    "custom_commands": [],
    "omarchy_install": {"mode": "full_disk", "defer_provisioning": false,
      "target_mount": "/mnt",
      "boot": {"esp_mount": "/boot", "esp_path": "/EFI/limine",
               "efi_binary": "limine_x64.efi", "enable_fallback": true},
      "storage": {"kernel": "linux-omarchy"}},
    "disk_config": {"config_type": "default_layout",
      "device_modifications": [{"device": "/dev/vda", "wipe": true,
        "partitions": [
          {"btrfs": [], "dev_path": nil, "flags": ["boot", "esp"],
           "fs_type": "fat32", "mount_options": [], "mountpoint": "/boot",
           "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
           "size": {"sector_size": {"unit": "B", "value": 512}, "unit": "B",
                    "value": bootSize},
           "start": {"sector_size": {"unit": "B", "value": 512}, "unit": "B",
                     "value": bootStart},
           "status": "create", "type": "primary"},
          {"btrfs": [{"mountpoint": "/", "name": "@"},
                     {"mountpoint": "/home", "name": "@home"},
                     {"mountpoint": "/var/log", "name": "@log"},
                     {"mountpoint": "/var/cache/pacman/pkg", "name": "@pkg"}],
           "dev_path": nil, "flags": [], "fs_type": "btrfs",
           "mount_options": ["compress=zstd"], "mountpoint": nil,
           "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
           "size": {"sector_size": {"unit": "B", "value": 512}, "unit": "B",
                    "value": mainSize},
           "start": {"sector_size": {"unit": "B", "value": 512}, "unit": "B",
                     "value": mainStart},
           "status": "create", "type": "primary"}]}]},
    "hostname": "addon-tb-omarchy", "kernels": ["linux-omarchy"],
    "network_config": {"type": "iso"}, "ntp": true, "parallel_downloads": 8,
    "script": nil, "services": [], "swap": true, "timezone": "UTC",
    "locale_config": {"kb_layout": "us", "sys_enc": "UTF-8",
                      "sys_lang": "en_US.UTF-8"},
    "mirror_config": {"custom_repositories": [], "custom_servers": [
        {"url": "https://mirror.omarchy.org/$repo/os/$arch"},
        {"url": "https://mirror.rackspace.com/archlinux/$repo/os/$arch"},
        {"url": "https://geo.mirror.pkgbuild.com/$repo/os/$arch"}],
      "mirror_regions": {}, "optional_repositories": []},
    "packages": ["base-devel", "git", "omarchy-keyring", "omarchy-settings",
                 "omarchy"],
    "profile_config": {"gfx_driver": nil, "greeter": nil, "profile": {}},
    "version": "3.0.9"}
  @[("meta-data", "instance-id: repro-addon-tb-omarchy\n"),
    ("user-data", "#cloud-config\nusers: []\ndisable_root: false\n" &
      "ssh_authorized_keys:\n  - " & pub.strip() & "\n"),
    ("user_configuration.json", pretty(config) & "\n"),
    ("user_credentials.json", pretty(creds) & "\n"),
    ("user_encrypt_installation.txt", "false\n"),
    ("authorized_keys", pub.strip() & "\n")]

proc writeCidata(dir, image, pub: string) =
  ## A 4 MiB FAT volume labelled CIDATA with the autoinstall files (mtools,
  ## so nothing is mounted on the build host).
  let src = dir / "cidata"
  createDir(src)
  for (name, content) in omarchyCidataFiles(pub):
    writeFile(src / name, content)
  var f = open(image, fmWrite)
  f.setFilePos(4 * 1024 * 1024 - 1)
  f.write('\0')
  f.close()
  if execCmd("mformat -i " & quoteShell(image) & " -v CIDATA ::") != 0:
    raise newException(TestBedError, "mformat of the cidata volume failed")
  for (name, _) in omarchyCidataFiles(pub):
    if execCmd("mcopy -i " & quoteShell(image) & " " & quoteShell(src / name) &
               " ::/" & name) != 0:
      raise newException(TestBedError, "mcopy of " & name & " failed")

proc sudo(g: Guest; script: string; timeoutSec = 1800): ExecOut =
  ## ``script`` as root on the installed system, through the account's
  ## ``sudo`` (the build reaches it as the account the install created).
  g.exec("printf '%s\\n' " & quoteShell(OmarchyAccountPassword) &
         " | sudo -S -p '' bash -c " & quoteShell(script), timeoutSec)

proc sudoRun(g: Guest; script, what: string; timeoutSec = 1800): string =
  let r = g.sudo(script, timeoutSec)
  g.note(what & " exited " & $r.exitCode)
  if r.exitCode != 0:
    raise newException(TestBedError, what & " failed (" & $r.exitCode & "):\n" &
      r.stdout & r.stderr)
  r.stdout

when defined(gostiAvailable):
  proc omarchyBackend(key, user: string): QemuBootBackend =
    newQemuBootBackend(stateDir = cacheDir() / "qemu-state",
      namePrefix = QemuNamePrefix, sshUser = user, sshKeyPath = key)

proc installOmarchy(g: Guest; disk: string) =
  ## Boot the pinned ISO with the autoinstall volume and a blank ``disk``,
  ## with no network (QEMU ``restrict=on``: the ISO installs from the image
  ## and the offline mirror it carries, so nothing the install uses comes
  ## from the network), wait for Omarchy's installer to report the install
  ## complete, and power the live system off.
  when defined(gostiAvailable):
    let iso = omarchyIsoPath()
    let cidata = g.runDir / "cidata.img"
    writeCidata(g.runDir, cidata, readFile(g.keyPath & ".pub"))
    let spec = BootMediaSpec(name: g.name, kind: bmkIso, mediaPath: iso,
      targetDiskPath: disk, diskGB: OmarchyImageGiB,
      secondaryIsoPath: cidata, cpus: 4, memoryMB: 8192, generation: 2,
      acceleration: baAuto, sshForwardPort: freePort(),
      serialLogPath: g.serialLog, guestArch: gaX86_64,
      networkRestricted: true)
    g.note("booting the Omarchy ISO " & OmarchyIso.digest[0 ..< 12] &
           " to install onto " & disk & " (no network)")
    g.vm = g.qemu.bootFromMedia(spec)
    g.booted = true
    g.qemu.startAndAwaitReady(g.vm, timeoutSec = 900)
    g.note("live system reachable")
    # In an autoinstall (``OMARCHY_UI_INTERACTIVE=no``) the installer's
    # dashboard reboots on its own a few seconds after the install completes
    # (``omarchy-install-dashboard``: ``reboot_prompt`` returns at once,
    # then ``reboot_now``), and under ``-no-reboot`` QEMU then exits. So the
    # install's verdict is read from its state file while the live system
    # runs: ``finished_at`` set means complete; a QEMU that exits without
    # it is a failed install.
    let deadline = epochTime() + 3600
    var finishedSeen = ""
    var gone = 0
    while true:
      if epochTime() > deadline:
        raise newException(TestBedError, "the Omarchy install did not " &
          "complete in an hour:\n" &
          g.exec("tail -n 60 /var/log/omarchy-install.log").stdout)
      if g.qemu.waitForShutdown(g.vm, 1):
        g.qemu.stopAndCleanup(g.vm, deleteVm = true)
        g.booted = false
        if finishedSeen.len == 0:
          let serial = if fileExists(g.serialLog): readFile(g.serialLog) else: ""
          raise newException(TestBedError, "the live system exited before " &
            "the installer reported the install complete:\n" &
            serial[max(0, serial.len - 3000) .. ^1])
        g.note("the installer rebooted the live system")
        return
      # The installer's own state file (``omarchy-install-dashboard`` reads
      # the same keys).
      let st = g.exec("f=/run/omarchy-install/state.json; " &
        "if [ -f $f ]; then printf 'finished=%s\\n' \"$(jq -r " &
        "'.finished_at // 0 | tostring' $f 2>/dev/null)\"; " &
        "printf 'phase=%s\\n' \"$(jq -r '.current_phase // empty' " &
        "$f 2>/dev/null)\"; fi; " &
        "pgrep -f orchestrator.main >/dev/null && echo running=yes; true",
        timeoutSec = 30)
      var finished, phase = ""
      var running = false
      for l in st.stdout.splitLines():
        if l.startsWith("finished="): finished = l["finished=".len .. ^1]
        elif l.startsWith("phase="): phase = l["phase=".len .. ^1]
        elif l == "running=yes": running = true
      if finished.len > 0 and finished notin ["0", "null"]:
        if finishedSeen.len == 0:
          g.note("install complete (finished_at " & finished & ", " & phase & ")")
        finishedSeen = finished
      elif st.exitCode == 0 and not running and finished.len > 0:
        inc gone
        if gone >= 10:
          raise newException(TestBedError, "the Omarchy installer stopped " &
            "without completing (" & phase & "):\n" &
            g.exec("tail -n 80 /var/log/omarchy-install.log").stdout)
      else:
        gone = 0
      sleep(2000)


const OmarchyPinScript = """
set -eu
root=__ROOT__
mkdir -p "$root"
tar -C "$root" -xf /home/__ACCOUNT__/capture.tar
rm -f /home/__ACCOUNT__/capture.tar
# Every repository section names the capture cache and nothing else: its
# Server and Include lines go and one file:// server takes their place.
awk -v root="file://$root" '
  /^\[/ { sec = substr($0, 2, length($0) - 2); print
          if (sec != "options") print "Server = " root "/" sec; next }
  sec != "" && sec != "options" && /^[[:space:]]*(Server|Include)[[:space:]]*=/ { next }
  { print }' /etc/pacman.conf > /etc/pacman.conf.repro-testbed
mv /etc/pacman.conf.repro-testbed /etc/pacman.conf
chmod 0644 /etc/pacman.conf
"""

proc stageCapture(g: Guest; entries: seq[CaptureEntry]) =
  ## Copy the captured repositories into the guest (``OmarchyCaptureRoot``)
  ## and point pacman at them only.
  let stage = g.runDir / "capture"
  for e in entries:
    if not e.path.startsWith("repo/"): continue
    let dst = stage / e.path["repo/".len .. ^1]
    createDir(parentDir(dst))
    let src = casVerified(e.sha256)
    try: createHardlink(src, dst)
    except OSError: copyFile(src, dst)
  let tarball = g.runDir / "capture.tar"
  if execCmd("tar -C " & quoteShell(stage) & " -cf " & quoteShell(tarball) &
             " .") != 0:
    raise newException(TestBedError, "tar of the capture failed")
  g.copyTo(tarball, "/home/" & OmarchyAccount & "/capture.tar")
  removeFile(tarball)
  removeDir(stage)
  discard g.sudoRun(OmarchyPinScript.replace("__ROOT__", OmarchyCaptureRoot).
    replace("__ACCOUNT__", OmarchyAccount), "pointing pacman at the capture")

proc bootInstalled(g: Guest; disk, user: string) =
  ## Boot the installed disk in place (UEFI, no network) as ``user``.
  when defined(gostiAvailable):
    g.diskPath = disk
    g.seedPath = ""
    g.uefi = true
    g.networkIsolated = true
    g.memoryMB = 4096
    g.cpus = 4
    g.qemu = omarchyBackend(g.keyPath, user)
    g.boot()
    discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                   timeoutSec = 600)

proc newOmarchyBuildGuest(): Guest =
  ## A run (directory, token, key) for an Omarchy install; nothing booted.
  when not defined(gostiAvailable):
    raise newException(TestBedError,
      "gosti is not available: set GOSTI_SRC to gosti's src directory")
  else:
    let name = QemuNamePrefix & "om-" & $getCurrentProcessId() & "-" &
      randomHex(6)
    let (dir, token) = claimRunDir(name)
    result = Guest(base: OmarchyBase, name: name, runDir: dir,
                   ownerToken: token, kind: gkQemu, uefi: true,
                   networkIsolated: true)
    result.keyPath = dir / "id_ed25519"
    if execCmd("ssh-keygen -q -t ed25519 -N '' -C repro-addon-testbed -f " &
               quoteShell(result.keyPath)) != 0:
      raise newException(TestBedError, "ssh-keygen failed")
    result.serialLog = dir / "serial.log"
    result.qemu = omarchyBackend(result.keyPath, "root")

proc omarchyPinSet*(): string =
  ## What an Omarchy image is a function of: the ISO, the version, the
  ## capture list's digest and the recipe.
  "omarchy-iso " & OmarchyIso.url & " sha256:" & OmarchyIso.digest &
    "\nomarchy-version " & OmarchyVersion &
    "\ncapture-list sha256:" & fileDigest(OmarchyCaptureManifest, "sha256") &
    "\nrecipe " & $OmarchyRecipeVersion & "\n"

proc omarchyKeyOf*(image: string): string =
  ## The SSH key a built Omarchy image authorises for root, kept beside it.
  image & ".id_ed25519"

proc buildOmarchyImage*(outPath: string): ArchBuild =
  ## One Omarchy image from the pins alone: the pinned ISO installs it, then
  ## pacman is pointed only at the capture cache, ``pacman -Syu`` runs from
  ## it (``OMARCHY_ALLOW_DIRECT_PACMAN=1``, in the guest only: Omarchy's
  ## ``00-omarchy-update-guard.hook`` aborts a direct upgrade otherwise,
  ## spec §7.9), and root is given the image's key. No step has a network.
  if fileExists(outPath):
    raise newException(TestBedError, "refusing to build over " & outPath)
  let t0 = epochTime()
  result = ArchBuild(path: outPath, pinSet: omarchyPinSet(),
                     startedAt: $now().utc)
  let capture = omarchyCapture()
  var g: Guest
  try:
    g = newOmarchyBuildGuest()
    let disk = g.runDir / "omarchy.qcow2"
    g.installOmarchy(disk)
    g.bootInstalled(disk, OmarchyAccount)
    g.stageCapture(capture)
    let syu = g.sudoRun("set -o pipefail; OMARCHY_ALLOW_DIRECT_PACMAN=1 " &
      "pacman -Syu --noconfirm 2>&1 && rm -f /var/cache/pacman/pkg/*",
      "pacman -Syu from the capture (OMARCHY_ALLOW_DIRECT_PACMAN=1)")
    g.note("the build's pacman -Syu:\n" & syu)
    discard g.sudoRun("install -d -m 0700 /root/.ssh && install -m 0600 " &
      "/home/" & OmarchyAccount & "/.ssh/authorized_keys " &
      "/root/.ssh/authorized_keys", "authorising the image key for root")
    g.requirePinnedPacman(omarchyCaptureRule())
    # Still the account's session (a booted VM keeps the SSH user it was
    # booted with), so the power-off goes through sudo too.
    let off = g.sudo("sync; " & PowerOffCommand, timeoutSec = 30)
    g.note("power-off: exit " & $off.exitCode & " " & off.stdout & off.stderr)
    if not g.waitPoweredOff(300):
      raise newException(TestBedError, "the installed system did not " &
        "power off")
    convertTo(disk, outPath)
    copyFile(g.keyPath, omarchyKeyOf(outPath))
    setFilePermissions(omarchyKeyOf(outPath), {fpUserRead, fpUserWrite})
    result.extraFiles = @[("disk.qcow2.id_ed25519", omarchyKeyOf(outPath))]
    result.log = g.log
  finally:
    if g != nil: g.destroy()
  result.sha256 = fileDigest(outPath, "sha256")
  result.finishedAt = $now().utc
  result.seconds = epochTime() - t0

proc omarchyImageDir*(): string =
  cacheDir() / "arch-images" / ("omarchy-" & sha256Hex(omarchyPinSet())[0 ..< 16])

proc omarchyGoldenImage*(): string =
  ## The verified cached Omarchy image of the current pin set, built first
  ## when there is none. Its key is ``omarchyKeyOf`` of the returned path.
  result = cachedImage(omarchyImageDir(), omarchyPinSet(), "Omarchy",
    proc(outPath: string): ArchBuild = buildOmarchyImage(outPath))
  if not fileExists(omarchyKeyOf(result)):
    raise newException(TestBedError, "the cached Omarchy image has no key " &
      "beside it: " & omarchyKeyOf(result))

proc newOmarchyGuestOver*(image: string; diskGiB = OmarchyImageGiB;
                          cpus = 4; memoryMB = 4096): Guest =
  ## A guest over an Omarchy image (the cached one, or one the caller
  ## built), reached as root with the image's key. UEFI (the image boots
  ## Limine); no cloud-init seed (the installed system has no cloud-init).
  when not defined(gostiAvailable):
    raise newException(TestBedError,
      "gosti is not available: set GOSTI_SRC to gosti's src directory")
  else:
    if diskGiB < OmarchyImageGiB:
      raise newException(TestBedError, "an Omarchy guest's disk is at " &
        "least " & $OmarchyImageGiB & " GiB")
    let key = omarchyKeyOf(image)
    if not fileExists(key):
      raise newException(TestBedError, "no key beside " & image)
    result = newGuest(OmarchyBase, diskGiB = diskGiB, cpus = cpus,
                      memoryMB = memoryMB, image = image)
    # The overlay and the run are newGuest's; the key and the boot are the
    # image's.
    removeFile(result.seedPath)
    result.seedPath = ""
    result.uefi = true
    result.keyPath = result.runDir / "image_ed25519"
    copyFile(key, result.keyPath)
    setFilePermissions(result.keyPath, {fpUserRead, fpUserWrite})
    result.qemu = omarchyBackend(result.keyPath, "root")

proc newOmarchyGuest*(diskGiB = OmarchyImageGiB; cpus = 4;
                      memoryMB = 4096): Guest =
  ## Claim a run and prepare (not boot) an Omarchy guest over the cached
  ## image. ``prepareArchGuest`` (or ``prepareOmarchyGuest``) after the boot.
  newOmarchyGuestOver(omarchyGoldenImage(), diskGiB, cpus, memoryMB)

proc prepareOmarchyGuest*(g: Guest) =
  ## Boot settled, then the pin check: refuses (raises) a guest whose
  ## pacman names any server other than the capture cache.
  discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                 timeoutSec = 600)
  g.requirePinnedPacman(omarchyCaptureRule())

proc omarchyBuildId*(g: Guest): string =
  g.run(". /etc/os-release && printf '%s' \"$BUILD_ID\"").strip()

proc omarchyRecordBase*(): JsonNode =
  %*{"omarchyIso": OmarchyIso.url, "omarchyIsoSha256": OmarchyIso.digest,
     "omarchyVersion": OmarchyVersion, "omarchyBuildId": OmarchyBuildId,
     "omarchyCaptureList": "tests/e2e/addon/fixtures/omarchy/" &
       extractFilename(OmarchyCaptureManifest),
     "omarchyCaptureListSha256": fileDigest(OmarchyCaptureManifest, "sha256"),
     "omarchyRecipeVersion": OmarchyRecipeVersion}

# -- Capturing (run by hand, by tests/e2e/addon/capture_omarchy.nim). ---------

proc dbChecksums(db: string): Table[string, string] =
  ## ``%FILENAME%`` -> ``%SHA256SUM%`` of every entry of a pacman database.
  let (o, c) = execCmdEx("bsdtar -xOf " & quoteShell(db) & " '*/desc'")
  if c != 0:
    raise newException(TestBedError, "cannot read " & db & ": " & o)
  var name, sum, key = ""
  for line in o.splitLines() & @["%END%"]:
    if line.startsWith("%") and line.endsWith("%"):
      key = line
      if key == "%FILENAME%" and name.len > 0 and sum.len > 0:
        result[name] = sum
        name = ""; sum = ""
      if key == "%END%" and name.len > 0 and sum.len > 0:
        result[name] = sum
    elif line.len > 0:
      if key == "%FILENAME%": name = line
      elif key == "%SHA256SUM%": sum = line

proc captureOmarchy*(manifestOut: string): seq[CaptureEntry] =
  ## Install the pinned ISO, read which repositories its pacman names and
  ## which packages are installed, and capture into the content cache each
  ## repository's database (as Omarchy serves it now) and every package
  ## file ``pacman -Sp`` / ``pacman -Syup`` resolves against them, each
  ## checked against its database's SHA-256; then write the list.
  var g: Guest
  let iso = omarchyIsoPath()
  result.add(CaptureEntry(sha256: OmarchyIso.digest,
    size: getFileSize(iso), path: "iso/" & OmarchyIso.file))
  try:
    g = newOmarchyBuildGuest()
    let disk = g.runDir / "omarchy.qcow2"
    g.installOmarchy(disk)
    g.bootInstalled(disk, OmarchyAccount)
    let repos = g.sudoRun("pacman-conf --repo-list", "listing repositories").
      splitLines()
    var sums: Table[string, Table[string, string]]
    for r0 in repos:
      let r = r0.strip()
      if r.len == 0: continue
      var server = ""
      for (k, v) in OmarchyRepoServers:
        if k == r: server = v
      if server.len == 0:
        raise newException(TestBedError, "the installed pacman names a " &
          "repository the capture has no server for: " & r)
      let tmp = casDir() / (".db-" & r & "-" & $getCurrentProcessId())
      download(server & "/" & r & ".db", tmp)
      sums[r] = dbChecksums(tmp)
      let size = getFileSize(tmp)
      let hex = casPut(tmp)
      result.add(CaptureEntry(sha256: hex, size: size,
                              path: "repo/" & r & "/" & r & ".db"))
    g.stageCapture(result)
    let wanted = g.sudoRun("pacman -Sy >/dev/null; " &
      "pacman -Qq | grep -Fx -f <(pacman -Slq) | " &
      "xargs pacman -Sp --print-format '%r %f'; " &
      "OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syup --print-format '%r %f'",
      "resolving the packages against the captured databases")
    var seen: seq[string]
    for line in wanted.splitLines():
      let f = line.strip().splitWhitespace()
      if f.len != 2 or not f[1].endsWith(".pkg.tar.zst") and
          not f[1].endsWith(".pkg.tar.xz"): continue
      let key = f[0] & "/" & f[1]
      if key in seen: continue
      seen.add(key)
      var server = ""
      for (k, v) in OmarchyRepoServers:
        if k == f[0]: server = v
      let want = sums[f[0]].getOrDefault(f[1])
      if want.len == 0:
        raise newException(TestBedError, f[1] & " is not in " & f[0] & ".db")
      if fileExists(casPath(want)):
        discard casVerified(want)
      else:
        let tmp = casDir() / (".pkg-" & $getCurrentProcessId())
        download(server & "/" & f[1], tmp)
        let hex = casPut(tmp)
        if hex != want:
          raise newException(TestBedError, server & "/" & f[1] & " hashes to " &
            hex & ", not the " & want & " its database names")
      result.add(CaptureEntry(sha256: want, size: getFileSize(casPath(want)),
                              path: "repo/" & key))
      # The detached signature beside it: pacman reads ``<file>.sig`` from a
      # ``file://`` server to verify the package (measured: a capture
      # without them fails ``pacman -Syu`` with "failed retrieving file
      # '<file>.sig' from disk"). Its bytes are pinned by the list like the
      # rest; pacman checks it against the keyring.
      let sigTmp = casDir() / (".sig-" & $getCurrentProcessId())
      download(server & "/" & f[1] & ".sig", sigTmp)
      let sigSize = getFileSize(sigTmp)
      let sigHex = casPut(sigTmp)
      result.add(CaptureEntry(sha256: sigHex, size: sigSize,
                              path: "repo/" & key & ".sig"))
  finally:
    if g != nil: g.destroy()
  createDir(parentDir(manifestOut))
  writeFile(manifestOut, renderCaptureManifest(result,
    "# Omarchy " & OmarchyVersion & " capture (spec ReproOS-Add-On-Mode " &
    "§12.1). SHA-256, size, path in the capture. Captured " &
    $now().utc & " from " & OmarchyIso.url & " and the servers in " &
    "arch_testbed.OmarchyRepoServers. Changed only by a commit.\n"))

proc newArchGuest*(b: BaseImage; diskGiB = ArchImageGiB; cpus = 0;
                   memoryMB = 0): Guest =
  ## Claim a run and prepare (not boot) a guest of the Arch base ``b``
  ## over its cached built image. ``prepareArchGuest`` after the boot.
  if useIncus():
    raise newException(TestBedError, "the Arch test bed is QEMU only")
  if isOmarchyBase(b):
    return newOmarchyGuest(diskGiB = max(diskGiB, OmarchyImageGiB),
      cpus = (if cpus > 0: cpus else: 4),
      memoryMB = (if memoryMB > 0: memoryMB else: 4096))
  if diskGiB < ArchImageGiB:
    raise newException(TestBedError, "an Arch guest's disk is at least " &
      $ArchImageGiB & " GiB")
  newGuest(b, diskGiB = diskGiB, cpus = cpus, memoryMB = memoryMB,
           image = archGoldenImage(archVariantOf(b)))

proc newArchGuestOver*(b: BaseImage; image: string;
                       diskGiB = ArchImageGiB): Guest =
  ## A guest of ``b`` over an image the caller built and owns (the pinning
  ## gate's independent builds and its negative control).
  if isOmarchyBase(b):
    return newOmarchyGuestOver(image, max(diskGiB, OmarchyImageGiB))
  newGuest(b, diskGiB = diskGiB, image = image)

proc prepareArchGuest*(g: Guest) =
  ## First-boot completion, then the pin check: refuses (raises) a guest
  ## whose pacman names anything but its archive date (an Omarchy guest:
  ## anything but the capture cache, ``prepareOmarchyGuest``).
  if isOmarchyBase(g.base):
    g.prepareOmarchyGuest()
    return
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

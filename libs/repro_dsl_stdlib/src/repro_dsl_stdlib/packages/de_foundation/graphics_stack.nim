## NDE0-G: native graphics-stack package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-G.
##
## This module is the build-time implementation backing the package
## declaration at ``recipes/packages/de-foundation/graphics-stack/repro.nim``.
## Mirrors the NDE0-S / NDE0-D layout: the DSL ``parsePackageDef`` macro
## at ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads, so the spec'd ``files <name>:`` and
## ``service <name>:`` block forms don't yet work and the impl is exposed
## as ordinary Nim procs.
##
## ## What this package owns
##
## Per spec §NDE0-G, the native package subsumes the Tier-2 shell script
## at ``recipes/reproos-mvp-config/build-linux-graphics-stack.sh``. The
## file-emission outputs:
##
##   * ``/etc/ld.so.conf.d/00-reproos-linux.conf`` via
##     ``fs.managedBlock()`` with the NDE-spec-block triple-form sentinel
##     (scope=system, packageName=graphics-stack, blockId=libpaths,
##     priority=100). The content lists the planted store paths'
##     ``usr/lib/x86_64-linux-gnu/`` directories per the 6-package
##     Mesa + libdrm + libwayland + libxkbcommon + fontconfig +
##     dejavu-fonts closure that NDE0-G fronts.
##   * ``/usr/lib/systemd/system/repro-ldconfig.service`` — the Type=oneshot
##     unit that runs ``/sbin/ldconfig`` before multi-user.target / sysinit.target
##     to populate ``/etc/ld.so.cache`` from the ld.so.conf.d snippet. Per
##     the cascade-G discipline: planted at ``usr/lib/systemd/system/``
##     NOT ``lib/systemd/system/`` (R9 systemd 257.9 dropped the legacy
##     /lib/systemd/system entry from UnitPath).
##   * Belt-and-braces: ``/etc/systemd/system/repro-ldconfig.service``
##     un-mask handle recording target =
##     ``/usr/lib/systemd/system/repro-ldconfig.service``.
##   * Activation symlink: ``/etc/systemd/system/multi-user.target.wants/
##     repro-ldconfig.service`` recording target = ``../repro-ldconfig.service``
##     so systemd activates the oneshot at boot.
##
## ## What this package consumes
##
## Per spec NDE0-G ``uses: apt-jammy(snapshot, debs=@[libgbm1, libegl1,
## libgl1, libegl-mesa0, libgles2, libglapi-mesa, libdrm2, libdrm-common,
## libwayland-client0, libwayland-server0, libwayland-egl1, libxkbcommon0,
## fontconfig, libfontconfig1, fonts-dejavu-core])``. v1 of NDE0-G records
## the snapshot pin in every cache key but does NOT extract the .debs --
## the Tier-2 shell script ``recipes/reproos-mvp-config/
## build-linux-graphics-stack.sh`` (which v1 of NDE0-G subsumes
## declaratively, not behaviourally) remains the path to a runnable
## graphics stack today. The NDE-spec-block contribution emitted here
## declares the ld.so.conf.d layout that the Tier-2 .deb planting feeds.
##
## ## Reuse from NDE0-S
##
## NDE0-S's ``systemd_session.nim`` already exports the minimal-viable
## ``configFile`` / ``managedBlock`` / ``symlinkUnmask`` helpers + the
## ``BlockScope`` enum + ``ManagedFiles`` typed output handle. This
## module imports them directly. Same pattern NDE0-D follows.
##
## ## Honest deferrals
##
## * **Build-time ldconfig integration is OUT of scope for v1.** The
##   spec's "the build engine runs ``ldconfig -r`` across the union of all
##   DE-foundation store contributions to produce ``/etc/ld.so.cache`` in
##   the active generation" requires a build-time host-side ldconfig
##   wrapper that knows the per-generation activation root. For v1 the
##   runtime ``repro-ldconfig.service`` is sufficient for the foundation:
##   first boot's oneshot reads the planted ``/etc/ld.so.conf.d/
##   00-reproos-linux.conf`` and populates ``/etc/ld.so.cache``
##   accordingly. This is the same model the Tier-2 shell script ships;
##   the native package preserves it. Build-time integration lands as a
##   follow-up NDEM milestone alongside the per-generation apply step.
##
## * **enableHardwareGl as a v1-near-no-op.** The configurable selects
##   between the full Mesa hardware-GL closure (default, ``true``) and a
##   software-rasterisation-only closure (``false``). v1 plants the same
##   .deb set in both branches (Mesa ships llvmpipe in the same package
##   tree as the hardware drivers); the configurable's runtime effect is
##   limited to a single comment line in the planted ld.so.conf.d block
##   documenting the selected mode. The closure-difference becomes
##   meaningful when source-build infra lands and the package can
##   conditionally pull a smaller Mesa variant.
##
## * **dbus-broker / dbus-user-session-style .deb extraction**: NDE0-G v1
##   emits a declarative ld.so.conf.d block + the runtime ldconfig unit
##   file but does NOT extract the 6 .debs into per-package content-
##   addressed store paths. That .deb-extraction work is what the Tier-2
##   shell script does; the NDE0-G migration shape is "declarative front
##   end + tier-2 backend until the per-package extraction lands".
##
## * **Multi-contributor /etc/ld.so.conf.d/ merge**: NDE-H/G/K each add
##   their own contribution to the libpaths block (per the spec's worked
##   example in Generated-Configuration-Files.md). v1 emits NDE0-G's
##   contribution to a content-addressed store path independently; the
##   activation layer that unions co-contributors into a single live
##   /etc/ld.so.conf.d/00-reproos-linux.conf is the NDE-spec-block
##   multi-contributor merge — scheduled for NDEM1 runtime implementation.
##   v1's sentinel shape is forward-compatible: the merge step consuming
##   this contribution sees a spec-shape-compatible block.

import std/[algorithm, os, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ./systemd_session

# Re-export the symbols downstream consumers need so a ``uses:
# "graphics-stack >=0.1.0"`` package can do everything from one import.
export apt_jammy.AptFiles
export systemd_session

# ---------------------------------------------------------------------------
# Version constant — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  Nde0gVersion* = "0.1.0"

  ## Canonical package name segment for the NDE-spec-block sentinels.
  ## Matches the ``package`` form's registered name in
  ## ``recipes/packages/de-foundation/graphics-stack/repro.nim``.
  Nde0gPackageName* = "graphics-stack"

  ## NDE-spec-block libpaths blockId. Per the spec worked example
  ## (Generated-Configuration-Files.md §"Worked example —
  ## /etc/ld.so.conf.d/") this is the canonical block-id every
  ## DE-foundation package contributes to.
  Nde0gLibpathsBlockId* = "libpaths"

  ## NDE-spec-block priority for the foundation graphics stack. Per the
  ## spec worked example: "NDE0-G has priority 100 and sorts first; the
  ## three priority-500 compositors then sort by package name". Lower
  ## numbers sort earlier in the (priority, packageName, blockId) order.
  Nde0gLibpathsPriority* = 100

  ## Path under the content-addressed store where the unit file lands.
  ## Cascade-G fix: ``usr/lib/systemd/system/`` (R9 systemd 257.9
  ## dropped the legacy /lib/systemd/system entry from UnitPath).
  Nde0gUnitPath* = "usr/lib/systemd/system/repro-ldconfig.service"

  ## Belt-and-braces /etc/systemd/system path that records the cascade-G
  ## target. The activation layer (NDEM1) plants the live symlink.
  Nde0gUnitEtcPath* = "etc/systemd/system/repro-ldconfig.service"

  ## multi-user.target.wants activation symlink path.
  Nde0gWantsSymlinkPath* =
    "etc/systemd/system/multi-user.target.wants/repro-ldconfig.service"

# ---------------------------------------------------------------------------
# sha256 helper (sidecar files; the main emissions go through NDE0-S's
# helpers which embed their own per-output Nde0sVersion in the hash).
# ---------------------------------------------------------------------------

proc sha256OfBytes(bytes: openArray[byte]): string =
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc sha256OfString(s: string): string =
  if s.len == 0:
    sha256OfBytes(default(array[0, byte]))
  else:
    sha256OfBytes(cast[ptr UncheckedArray[byte]](
      s[0].unsafeAddr).toOpenArray(0, s.len - 1))

# ---------------------------------------------------------------------------
# Configurables + outputs
# ---------------------------------------------------------------------------

type
  GraphicsStackConfig* = object
    ## NDE0-G configurables per the spec example. Defaults match the
    ## Tier-2 shell script's behaviour (jammy snapshot pin, hardware GL
    ## on by default, dejavu-core as the only seeded font package).
    aptSnapshot*: string

    ## When true (default), the planted ld.so.conf.d block + the
    ## documentation banner advertise the hardware-GL Mesa closure
    ## (the standard llvmpipe + drm-driver build). When false, the
    ## banner switches to "software rasterisation only" and the comment
    ## block records the configurable's choice. v1's .deb set is the
    ## same in both branches (see honest-deferrals in module preamble);
    ## the configurable's effect is mostly documentary today.
    enableHardwareGl*: bool

    ## Font packages provisioned into the graphics-stack closure. Each
    ## entry contributes a comment line to the planted ld.so.conf.d
    ## block (font packages don't add lib dirs but they DO change the
    ## closure fingerprint). Default = @["fonts-dejavu-core"] matches
    ## the Tier-2 catalog's font tier.
    fontPackages*: seq[string]

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  GraphicsStackOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent — toggling ``enableHardwareGl`` re-emits only the
    ## ldConfBlock; toggling the font set re-emits only the ldConfBlock;
    ## the ldconfigService unit + the belt-and-braces /etc record + the
    ## activation symlink stay cached across config knobs.
    ldConfBlock*:        ManagedFiles
    ldconfigService*:    ManagedFiles
    ldconfigServiceEtc*: ManagedFiles   # belt-and-braces /etc unmask
    ldconfigWanted*:     ManagedFiles   # multi-user.target.wants symlink

const
  ## Default 6 jammy .deb sets per spec §NDE0-G. These are the upstream
  ## debian source-package names whose binary packages get extracted
  ## under ``/opt/reproos-linux/store/<hash>/usr/lib/x86_64-linux-gnu/``
  ## by the Tier-2 script. The native package records these in the
  ## ld.so.conf.d block as comment lines (one per source-package
  ## bundle) and lists the store-paths' lib dirs.
  ##
  ## See ``recipes/catalog/linux/{mesa,libdrm,libwayland,libxkbcommon,
  ## fontconfig,dejavu-fonts}.json`` for the per-bundle .deb list.
  DefaultGraphicsBundles* = [
    ("mesa", @["libgbm1", "libegl1", "libgl1",
               "libegl-mesa0", "libgles2", "libglapi-mesa"]),
    ("libdrm", @["libdrm2", "libdrm-common"]),
    ("libwayland", @["libwayland-client0", "libwayland-server0",
                     "libwayland-egl1"]),
    ("libxkbcommon", @["libxkbcommon0"]),
    ("fontconfig", @["fontconfig", "libfontconfig1"]),
  ]

proc defaultGraphicsStackConfig*(): GraphicsStackConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation.
  result = GraphicsStackConfig(
    aptSnapshot:      "ubuntu/jammy/20260615T000000Z",
    enableHardwareGl: true,
    fontPackages:     @["fonts-dejavu-core"],
    storeRoot:        systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Helper: deterministic per-bundle store-hash stub. We can't compute the
# real .deb-extracted hash here (v1 defers .deb extraction; see preamble)
# but we want the planted ld.so.conf.d block to look like the spec's
# worked example — i.e., list ``/opt/reproos-linux/store/<hash>/usr/lib/
# x86_64-linux-gnu`` lines. The stub hash is a pure function of the
# (snapshot, bundle-name) pair so toggling the snapshot or extending the
# bundle list invalidates the block content (and therefore its
# content-addressed store path).
# ---------------------------------------------------------------------------

proc bundleStubHash*(snapshot, bundleName: string): string =
  ## 16-char hex stub mirroring the Tier-2 script's ``catalog_hash``
  ## function shape ``sha256(name + version + snapshot)[0..15]``. We
  ## elide the version field — v1 doesn't track per-bundle versions
  ## explicitly; a later milestone that wires the apt-jammy ``debs:``
  ## extraction in will fold the resolved versions in.
  let composed = "graphicsBundleStub" & Nde0gVersion & snapshot & bundleName
  result = sha256OfString(composed)[0 ..< 16]

# ---------------------------------------------------------------------------
# Render the ld.so.conf.d managed-block content.
# ---------------------------------------------------------------------------

proc renderLdConfBlockContent*(cfg: GraphicsStackConfig): string =
  ## The block content between the NDE-spec-block sentinels. Lists the
  ## per-bundle store paths' ``usr/lib/x86_64-linux-gnu`` directories in
  ## deterministic order (bundles enumerated in the canonical order
  ## above), preceded by a banner that records the resolved
  ## configurables (snapshot pin, GL mode, font packages). The banner
  ## is what makes ``enableHardwareGl`` + ``fontPackages`` propagate to
  ## the block content per the configurable-binding contract.
  result = "# NDE0-G: graphics-stack libpaths contribution.\n"
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  if cfg.enableHardwareGl:
    result.add("# GL mode: hardware (Mesa drm + llvmpipe fallback)\n")
  else:
    result.add("# GL mode: software-only (llvmpipe; no drm drivers active)\n")
  result.add("# font packages (" & $cfg.fontPackages.len & "):\n")
  for fp in cfg.fontPackages:
    result.add("#   - " & fp & "\n")
  result.add("#\n")
  result.add("# Store lib dirs (one per bundle; activation step unions\n")
  result.add("# co-contributors per NDE-spec-block multi-contributor rules):\n")
  for bundle in DefaultGraphicsBundles:
    let (bundleName, _) = bundle
    let h = bundleStubHash(cfg.aptSnapshot, bundleName)
    result.add("/opt/reproos-linux/store/" & h &
               "/usr/lib/x86_64-linux-gnu  # " & bundleName & "\n")

# ---------------------------------------------------------------------------
# Render the systemd unit-file content.
# ---------------------------------------------------------------------------

proc renderLdconfigUnit*(): string =
  ## ``repro-ldconfig.service`` content. Mirrors the Tier-2 shell
  ## script's planted unit verbatim (Tier-2 stage "linker cascade fix"):
  ##
  ##   - Type=oneshot — runs once at boot, RemainAfterExit=yes so
  ##     ``systemctl status`` shows "active (exited)".
  ##   - DefaultDependencies=no — needs to run before sysinit.target
  ##     so the cache is populated before user-mode services start.
  ##   - After=local-fs.target — wait for /opt to be mounted.
  ##   - Before=multi-user.target sysinit.target — ensures
  ##     /etc/ld.so.cache exists by the time other services dlopen
  ##     libs.
  ##   - ExecStart=/sbin/ldconfig — reads
  ##     /etc/ld.so.conf.d/00-reproos-linux.conf and updates the cache.
  ##   - WantedBy=multi-user.target — the .wants symlink activates it
  ##     at boot.
  result = "# NDE0-G: linker-cascade fix oneshot.\n" &
           "[Unit]\n" &
           "Description=ReproOS ldconfig refresh (linker cascade fix)\n" &
           "DefaultDependencies=no\n" &
           "After=local-fs.target\n" &
           "Before=multi-user.target sysinit.target\n" &
           "\n" &
           "[Service]\n" &
           "Type=oneshot\n" &
           "ExecStart=/sbin/ldconfig\n" &
           "RemainAfterExit=yes\n" &
           "\n" &
           "[Install]\n" &
           "WantedBy=multi-user.target\n"

# ---------------------------------------------------------------------------
# Activation symlink emitter — mirrors symlinkUnmask's shape for the
# multi-user.target.wants/repro-ldconfig.service link, but the recorded
# target is relative (../repro-ldconfig.service) because systemd's
# .wants symlinks are conventionally relative within the same
# /etc/systemd/system/ tree. The activation layer (NDEM1) reads the
# manifest and plants the live symlink.
# ---------------------------------------------------------------------------

proc activationSymlink(path, target, storeRoot: string): ManagedFiles =
  let rel = path  # already POSIX-relative per the spec'd contract
  let manifestPath = rel & ".symlink-target"
  let composed = "graphicsStackActivationSymlink" & Nde0gVersion &
                 rel & target
  let hash = sha256OfString(composed)[0 ..< 16]
  let storePath = storeRoot / hash
  let marker = storePath / ".nde0g-symlink"
  result.storePath = storePath
  result.relPath = manifestPath
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / manifestPath
  createDir(dest.parentDir)
  writeFile(dest, target & "\n")
  writeFile(marker, hash)

# ---------------------------------------------------------------------------
# Public materializer — emit every NDE0-G output.
# ---------------------------------------------------------------------------

proc materializeGraphicsStack*(cfg: GraphicsStackConfig): GraphicsStackOutputs =
  ## Emit every NDE0-G output. Each helper invocation is independent so
  ## the cache keys are per-output — see the docstring for
  ## ``GraphicsStackOutputs`` for the invalidation matrix.
  ##
  ## NB: ``repro-ldconfig.service`` is planted at
  ## ``usr/lib/systemd/system/`` (the cascade-G fix); it is NOT planted
  ## at ``lib/systemd/system/``. R9 systemd 257.9's default UnitPath
  ## dropped the legacy /lib/systemd/system entry, so anything planted
  ## there would be invisible at boot. See NDE0-D's preamble for the
  ## full historical analysis.

  result.ldConfBlock = managedBlock(
    path = "etc/ld.so.conf.d/00-reproos-linux.conf",
    scope = bsSystem,
    packageName = Nde0gPackageName,
    blockId = Nde0gLibpathsBlockId,
    content = renderLdConfBlockContent(cfg),
    priority = Nde0gLibpathsPriority,   # foundation; sorts first
    storeRoot = cfg.storeRoot)

  result.ldconfigService = configFile(
    path = Nde0gUnitPath,
    content = renderLdconfigUnit(),
    storeRoot = cfg.storeRoot)

  # Belt-and-braces cascade-G fix: record the
  # /etc/systemd/system/repro-ldconfig.service un-mask target so the
  # activation layer plants the live symlink.
  result.ldconfigServiceEtc = symlinkUnmask(
    path = Nde0gUnitEtcPath,
    target = "/usr/lib/systemd/system/repro-ldconfig.service",
    storeRoot = cfg.storeRoot)

  # Activation symlink: multi-user.target.wants/repro-ldconfig.service
  # points at ../repro-ldconfig.service (sibling in the same dir).
  result.ldconfigWanted = activationSymlink(
    path = Nde0gWantsSymlinkPath,
    target = "../repro-ldconfig.service",
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: GraphicsStackOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the spec'd activation order: ldConf block first (so the
  ## later ldconfig oneshot reads it), then the unit file, then the
  ## belt-and-braces /etc record, then the activation .wants symlink.
  result = @[
    outs.ldConfBlock.storePath,
    outs.ldconfigService.storePath,
    outs.ldconfigServiceEtc.storePath,
    outs.ldconfigWanted.storePath]

proc sortedStorePaths*(outs: GraphicsStackOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])

## NDEM1: native ``reproosDesktop`` system-level package impl module
## (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDEM1.
## This module is the build-time implementation backing the package
## declaration at ``recipes/packages/system/reproos-desktop/repro.nim``
## (note the new ``system/`` subdirectory for system-scope packages).
##
## ## What this package owns
##
## NDEM1 is the MAJOR integration milestone: it composes the 3 prior
## Tier-1 compositor packages (NDE-H1 sway, NDE-G1 gnome, NDE-K1 plasma)
## and the 4 prior NDE0 foundation packages (NDE0-S systemd-session,
## NDE0-D dbus-broker, NDE0-G graphics-stack, NDE0-K kernel) under a
## **variant + configurable** scheme and produces the NixOS-style
## **generation manifest** with **multi-contributor managedBlock
## merger**.
##
## Per ``Configurable-System.md`` §"Variant Or Configurable" worked
## example (the spec gap-fill NDE-spec-variant that landed 2026-06-17):
##
##   * ``desktopKind: seq[DesktopKind]`` is a **variant** — multi-valued
##     and **closure-affecting**: adding a kind pulls the corresponding
##     DE package tree into the closure; removing one shrinks it.
##   * ``activeAtBoot: DesktopKind`` is a **configurable** —
##     single-valued and **activation-only**: picks which installable DE
##     the generation boots into; does NOT alter closure.
##   * ``validate: activeAtBoot in desktopKind.value`` is enforced at
##     eval/finalize time via ``validateDesktopConfig`` which raises
##     ``EConfigViolation``.
##
## Per ``Generated-Configuration-Files.md`` §"Multi-Contributor Managed
## Blocks" (NDE-spec-block, landed 2026-06-17):
##
##   * Blocks are emitted in sorted ``(priority, packageName, blockId)``
##     order (ascending) and delimited by the triple-form sentinels
##     ``# >>> repro:<scope>:<packageName>:<blockId> >>>`` / matching
##     close. The materialiser owns a single blank line between
##     consecutive contributor blocks.
##   * Removing one contributor leaves the others byte-identical (a
##     pure function of the three sort keys + each contributor's
##     content).
##
## The canonical worked example for the multi-contributor merge is
## ``/etc/ld.so.conf.d/00-reproos-linux.conf``, which receives
## contributions from NDE0-G (priority 100, packageName=graphics-stack)
## + each active compositor (priority 500, packageName=gnome / plasma /
## sway). Sort order for the typical NDEM1 generation is:
##
##   1. graphics-stack (priority 100; sorts first)
##   2. gnome    (priority 500; alphabetical: gnome < plasma < sway)
##   3. plasma   (priority 500)
##   4. sway     (priority 500)
##
## ## What this package consumes
##
## Per spec NDEM1 ``uses:`` — the full Tier-1 DE foundation +
## compositor closure. Imports the impl modules directly so the
## materialiser can call each materialise* proc with the per-package
## sub-config derived from the system-level configurables.
##
## ## DSL limitation: variant vs configurable
##
## The spec's ``case`` / ``of`` ``variant`` block + the per-arm
## ``uses:`` + the ``validate:`` directive cannot be expressed in the
## existing ``parsePackageDef`` DSL (mirroring the limitation prior NDE
## packages documented). The package declaration at
## ``recipes/packages/system/reproos-desktop/repro.nim`` therefore uses
## ``seq[string]`` for ``desktopKind`` and ``string`` for
## ``activeAtBoot``; this module's ``validateDesktopConfig`` enforces
## the constraint at materialise time and raises ``EConfigViolation``
## when violated.
##
## ## Honest deferrals
##
## * **Real /etc/ activation is OUT of scope.** The materialiser emits
##   the ``mergedLdConf`` file content + the ``displayManagerSymlink``
##   intent record + the generation manifest. The activation layer that
##   plants the live ``/etc/`` symlinks into the booted system + swaps
##   the symlink farm on rollback is deferred to NDEM2 (vm-harness gate)
##   + a follow-up activation runtime milestone.
##
## * **Bootloader integration is DEFERRED.** Spec NDEM1 requires GRUB
##   menu entries per generation. v1 emits ``grubMenuEntries``
##   ``ManagedFiles`` (one entry per generation), but the actual
##   ``grub-mkconfig`` invocation + the bootable-ISO lift is NDEM2 work
##   alongside the vm-harness e2e test.
##
## * **Multi-generation persistence is DEFERRED.** v1 emits a SINGLE
##   generation manifest per ``materializeReproosDesktop`` call. The
##   generation-log persistence layer (which records every recent
##   generation manifest so ``reproos-rebuild rollback`` can re-activate
##   the previous one) is NDEM2 work.
##
## * **Garbage collection of unreachable closure** (deferred — variant
##   shrink) is NDEM2 work.
##
## * **``variant`` / ``validate`` DSL block forms**: pure DSL spec at
##   this point. Semantics encoded directly in the Nim
##   ``validateDesktopConfig`` proc + the typed ``DesktopKind`` enum.

import std/[algorithm, os, sequtils, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ../de_foundation/systemd_session
import ../de_foundation/dbus_broker
import ../de_foundation/graphics_stack
import ../de_foundation/kernel
import ../desktop_environments/sway
import ../desktop_environments/gnome
import ../desktop_environments/plasma

# Re-export the symbols downstream consumers + tests need so a single
# ``import .../system/reproos_desktop`` is sufficient. Mirror of the
# DE-level re-export discipline.
export apt_jammy.AptFiles
export systemd_session
export dbus_broker
export graphics_stack
export kernel
export sway
export gnome
export plasma

# ---------------------------------------------------------------------------
# Version constants — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  NdemVersion* = "0.1.0"

  ## Canonical package name segment for the NDEM1 emissions. Matches
  ## the ``package`` form's registered name in
  ## ``recipes/packages/system/reproos-desktop/repro.nim``.
  NdemPackageName* = "reproos-desktop"

  ## The libpaths host file path the multi-contributor merge lands at.
  ## Shared with NDE0-G's + each active DE's contribution.
  NdemLdConfPath* = "etc/ld.so.conf.d/00-reproos-linux.conf"

  ## Display-manager activation symlink path.
  NdemDisplayManagerSymlinkPath* =
    "etc/systemd/system/display-manager.service"

  ## GRUB menu entry path (one .cfg per generation under
  ## ``/boot/loader/entries/`` — systemd-boot shape; NDEM2 will write
  ## the equivalent ``/boot/grub/grub.cfg`` snippet via the bootloader
  ## driver).
  NdemGrubEntriesPath* = "boot/loader/entries/reproos-desktop.conf"

# ---------------------------------------------------------------------------
# Custom error for the spec's `validate:` clause.
# ---------------------------------------------------------------------------

type
  EConfigViolation* = object of CatchableError
    ## Raised by ``validateDesktopConfig`` when the spec's
    ## ``validate: activeAtBoot in desktopKind.value`` constraint is
    ## violated. Per Configurable-System.md §"Variant Or Configurable"
    ## worked example.

# ---------------------------------------------------------------------------
# DesktopKind enum + config / outputs shapes.
# ---------------------------------------------------------------------------

type
  DesktopKind* = enum
    ## Spec-mandated enum (Configurable-System.md §"Variant Or
    ## Configurable" worked example). Typed against an enum (rather
    ## than ``string``) so reprobuild rejects typos at macro-expansion
    ## time. The string form (``"sway"`` / ``"gnome"`` / ``"plasma"``)
    ## is the canonical kebab-case package name the sentinel triple
    ## emits.
    dkSway = "sway"
    dkGnome = "gnome"
    dkPlasma = "plasma"

  ReproosDesktopConfig* = object
    ## NDEM1 configurables per the spec's combined variant +
    ## configurable shape.
    ##
    ## ``desktopKind`` is the **variant** (closure-affecting, multi-
    ## valued); ``activeAtBoot`` is the **configurable** (activation-
    ## only, single-valued). The rest are ordinary configurables.
    desktopKind*: seq[DesktopKind]
      ## Which DEs are *installable* in this generation. Multi-valued:
      ## adding a kind grows the closure; removing one shrinks it.
      ## Spec literal: ``@variant``.
    activeAtBoot*: DesktopKind
      ## Which installable DE the generation boots into by default.
      ## Constrained to values present in ``desktopKind`` (see
      ## ``validateDesktopConfig``).
    defaultUser*: string
      ## Default account name (matches NDE0-S ``defaultUser``).
    bootloaderTimeout*: int
      ## GRUB menu timeout in seconds (default 5 per spec).
    aptSnapshot*: string
      ## apt-jammy snapshot pin propagated to every sub-package.
    storeRoot*: string
      ## Store root for the helpers. Tests override.

  GenerationManifest* = object
    ## Records every storePath the generation needs to activate.
    ##
    ## **Content-addressed** ``generationId`` is the load-bearing
    ## invariant for the spec's two contracts:
    ##   * variant difference → different ID (different closure)
    ##   * configurable difference → different ID (different
    ##     activation, even if closure is identical)
    generationId*: string
    desktopKind*: seq[DesktopKind]
    activeAtBoot*: DesktopKind
    storePaths*: seq[string]
      ## Every contributor's emitted paths, sorted lexicographically
      ## for stable serialisation.
    activationSymlinks*: seq[tuple[etcPath, target: string]]
      ## Each entry records an intent: ``etcPath`` is the live system
      ## location the activation layer must symlink; ``target`` is the
      ## resolved unit / store path.
    mergedFiles*: seq[tuple[etcPath, contents: string]]
      ## Multi-contributor merged files (currently the single
      ## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` union).

  ReproosDesktopOutputs* = object
    ## The reified generation manifest + the three first-class
    ## ``ManagedFiles`` outputs the activation layer reads.
    manifest*: GenerationManifest
    displayManagerSymlink*: ManagedFiles
      ## Records the symlink target for
      ## ``/etc/systemd/system/display-manager.service`` per the
      ## spec's worked example.
    mergedLdConf*: ManagedFiles
      ## The multi-contributor union of
      ## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` across the active
      ## ``graphics-stack`` + ``desktopKind`` contributors.
    grubMenuEntries*: ManagedFiles
      ## GRUB menu entry record (one per generation). v1 emits a single
      ## entry for the current generation; multi-generation persistence
      ## lands in NDEM2.

# ---------------------------------------------------------------------------
# sha256 helper (used to compose the merged-file hash + the generationId).
# Mirrors the helpers in sway / gnome / plasma exactly.
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
# Default config.
# ---------------------------------------------------------------------------

proc defaultReproosDesktopConfig*(): ReproosDesktopConfig =
  ## Spec'd defaults. Single-DE (sway) closure; sway boots. Tests use
  ## this then mutate one field at a time.
  result = ReproosDesktopConfig(
    desktopKind:       @[dkSway],
    activeAtBoot:      dkSway,
    defaultUser:       "repro",
    bootloaderTimeout: 5,
    aptSnapshot:       "ubuntu/jammy/20260615T000000Z",
    storeRoot:         systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Validate the variant + configurable cross-constraint.
# ---------------------------------------------------------------------------

proc validateDesktopConfig*(cfg: ReproosDesktopConfig) =
  ## Implements the spec's ``validate: activeAtBoot in
  ## desktopKind.value``. Raises ``EConfigViolation`` if the
  ## ``activeAtBoot`` configurable is not present in the
  ## ``desktopKind`` variant set.
  ##
  ## Also rejects an empty ``desktopKind`` — a generation that
  ## installs no DEs cannot boot any DE.
  if cfg.desktopKind.len == 0:
    raise newException(EConfigViolation,
      "NDEM1: desktopKind variant is empty; a reproosDesktop " &
      "generation must install at least one DesktopKind")
  if cfg.activeAtBoot notin cfg.desktopKind:
    let installable = cfg.desktopKind.mapIt($it).join(", ")
    raise newException(EConfigViolation,
      "NDEM1: activeAtBoot=" & $cfg.activeAtBoot &
      " not present in desktopKind variant set {" & installable &
      "}. The spec's `validate: activeAtBoot in desktopKind.value` " &
      "rejects activating a DE that is not installable.")

# ---------------------------------------------------------------------------
# Display-manager activation: which unit handles login for the active DE.
# ---------------------------------------------------------------------------

proc activateDisplayManager*(cfg: ReproosDesktopConfig):
                            tuple[etcPath, target: string] =
  ## Returns the activation-symlink intent for the active DE's display
  ## manager service. Per the spec NDEM1 ``displayManagerSymlink``
  ## worked example:
  ##
  ##   * dkSway   → /usr/lib/systemd/system/sway-session.service
  ##   * dkGnome  → /usr/lib/systemd/system/gdm.service
  ##   * dkPlasma → /usr/lib/systemd/system/sddm.service
  ##
  ## The ``etcPath`` is always
  ## ``/etc/systemd/system/display-manager.service``; the ``target``
  ## resolves into the cascade-G path the per-DE materialiser plants
  ## its unit under.
  result.etcPath = "/" & NdemDisplayManagerSymlinkPath
  case cfg.activeAtBoot
  of dkSway:
    result.target = "/usr/lib/systemd/system/sway-session.service"
  of dkGnome:
    result.target = "/usr/lib/systemd/system/gdm.service"
  of dkPlasma:
    result.target = "/usr/lib/systemd/system/sddm.service"

# ---------------------------------------------------------------------------
# Multi-contributor managed-block merge (the heart of NDE-spec-block).
# ---------------------------------------------------------------------------

type
  LdConfContribution* = object
    ## One contributor's data needed for the multi-contributor merge.
    ## Carries the (priority, packageName, blockId) sort triple + the
    ## raw block content + a back-reference to the contributor's
    ## ``ManagedFiles`` handle so downstream code can chase store paths
    ## if needed.
    handle*: ManagedFiles
    priority*: int
    packageName*: string
    blockId*: string
    scope*: BlockScope
    content*: string
      ## The block's CONTENT — i.e. the bytes BETWEEN the open/close
      ## sentinels (NOT the sentinels themselves; this proc re-emits
      ## sentinels from the (scope, packageName, blockId) triple).

proc mergeLdConfBlocks*(contributions: seq[LdConfContribution]): string =
  ## Multi-contributor merge per NDE-spec-block. Steps:
  ##
  ## 1. Sort by ``(priority, packageName, blockId)`` ascending.
  ## 2. Emit each block delimited by its triple-form sentinel pair.
  ##    Block content ends with a newline (sentinel-discipline).
  ## 3. Separate consecutive contributor blocks with a single blank
  ##    line (the materialiser-owned inter-block whitespace per spec).
  ##
  ## Returns the merged file bytes (no leading or trailing whitespace
  ## beyond the final block's close sentinel newline).
  ##
  ## The sort is a pure function of the three keys — adding or
  ## removing an unrelated contributor cannot reorder existing blocks
  ## (Generated-Configuration-Files.md §"Block ordering rule" /
  ## "Stability across builds").
  var sorted = contributions
  sorted.sort(proc(a, b: LdConfContribution): int =
    if a.priority != b.priority:
      return cmp(a.priority, b.priority)
    if a.packageName != b.packageName:
      return cmp(a.packageName, b.packageName)
    return cmp(a.blockId, b.blockId))

  result = ""
  for i, c in sorted:
    if i > 0:
      result.add('\n')
    result.add(openSentinel(c.scope, c.packageName, c.blockId))
    result.add('\n')
    result.add(c.content)
    if not c.content.endsWith("\n"):
      result.add('\n')
    result.add(closeSentinel(c.scope, c.packageName, c.blockId))
    result.add('\n')

# ---------------------------------------------------------------------------
# Internal: emit a merged ManagedFiles handle for the unioned
# /etc/ld.so.conf.d/00-reproos-linux.conf. Mirrors NDE0-S's configFile
# helper shape so the activation layer reads a uniform output.
# ---------------------------------------------------------------------------

proc mergedLdConfHash(packageName, relPath, content: string): string =
  ## Cache key for the merged ld.so.conf union. Composed from the
  ## NDEM version + the merged bytes + the relPath so the
  ## content-addressed store path re-keys deterministically when ANY
  ## contributor changes its content.
  let composed = "ndemMergedLdConf" & NdemVersion & packageName &
                 relPath & content
  let h = sha256OfString(composed)
  result = h[0 ..< 16]

proc emitMergedLdConf(relPath, content, storeRoot: string): ManagedFiles =
  ## Plants the merged file under
  ## ``<storeRoot>/<hash>/<relPath>``. Idempotent (mirror of NDE0-S
  ## ``configFile`` shape).
  let hash = mergedLdConfHash(NdemPackageName, relPath, content)
  let storePath = storeRoot / hash
  let marker = storePath / ".ndem-mergedLdConf"
  result.storePath = storePath
  result.relPath = relPath
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / relPath
  createDir(dest.parentDir)
  writeFile(dest, content)
  writeFile(marker, hash)

# ---------------------------------------------------------------------------
# Display-manager symlink output (records the activation intent).
# ---------------------------------------------------------------------------

proc emitDisplayManagerSymlink(cfg: ReproosDesktopConfig): ManagedFiles =
  ## Records the symlink intent for
  ## ``/etc/systemd/system/display-manager.service``. The activation
  ## layer reads the planted ``.symlink-target`` file at apply time
  ## and creates the live symlink. Mirrors NDE0-G's
  ## ``activationSymlink`` shape.
  let intent = activateDisplayManager(cfg)
  let rel = NdemDisplayManagerSymlinkPath
  let manifestPath = rel & ".symlink-target"
  let composed = "ndemDisplayManagerSymlink" & NdemVersion &
                 rel & intent.target
  let hash = sha256OfString(composed)[0 ..< 16]
  let storePath = cfg.storeRoot / hash
  let marker = storePath / ".ndem-dm-symlink"
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
  writeFile(dest, intent.target & "\n")
  writeFile(marker, hash)

# ---------------------------------------------------------------------------
# GRUB menu entries (single-generation v1 emission; multi-generation
# persistence lands in NDEM2 alongside the vm-harness gate).
# ---------------------------------------------------------------------------

proc renderGrubMenuEntry(cfg: ReproosDesktopConfig;
                        generationId: string): string =
  ## Emit a systemd-boot-style menu entry recording the current
  ## generation's bzImage + the active DE banner. v1 lands a single
  ## entry; NDEM2 will lift the per-generation entries onto the live
  ## bootloader directory.
  result = "# NDEM1: GRUB / systemd-boot menu entry for generation " &
           generationId & ".\n"
  result.add("title   ReproOS (" & $cfg.activeAtBoot & ") — gen-" &
             generationId[0 ..< 8] & "\n")
  result.add("version " & generationId & "\n")
  result.add("linux   /boot/bzImage\n")
  result.add("options activeAtBoot=" & $cfg.activeAtBoot &
             " defaultUser=" & cfg.defaultUser & "\n")
  result.add("# Installable desktopKind variant: " &
             cfg.desktopKind.mapIt($it).join(",") & "\n")
  result.add("# Bootloader timeout: " & $cfg.bootloaderTimeout & "s\n")

proc emitGrubMenuEntries(cfg: ReproosDesktopConfig;
                       generationId: string): ManagedFiles =
  ## Plants the GRUB menu entry text under
  ## ``<storeRoot>/<hash>/boot/loader/entries/reproos-desktop.conf``.
  ## Idempotent (mirror of NDE0-S ``configFile`` shape).
  let rel = NdemGrubEntriesPath
  let content = renderGrubMenuEntry(cfg, generationId)
  let composed = "ndemGrubMenuEntries" & NdemVersion & rel & content
  let hash = sha256OfString(composed)[0 ..< 16]
  let storePath = cfg.storeRoot / hash
  let marker = storePath / ".ndem-grub"
  result.storePath = storePath
  result.relPath = rel
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / rel
  createDir(dest.parentDir)
  writeFile(dest, content)
  writeFile(marker, hash)

# ---------------------------------------------------------------------------
# Generation ID — content-addressed across BOTH variant and configurable.
# ---------------------------------------------------------------------------

proc canonicaliseCfgForId(cfg: ReproosDesktopConfig): string =
  ## Render every input that affects identity into a stable string.
  ## Order matters for byte-determinism. Both variant (desktopKind)
  ## AND configurable (activeAtBoot) MUST flow into the ID per the
  ## spec's two-axis identity contract.
  var parts: seq[string] = @[
    "ndem-version=" & NdemVersion,
    "defaultUser=" & cfg.defaultUser,
    "bootloaderTimeout=" & $cfg.bootloaderTimeout,
    "aptSnapshot=" & cfg.aptSnapshot,
    "activeAtBoot=" & $cfg.activeAtBoot]
  # desktopKind is a SET semantically — sort to stable form so the
  # generationId is invariant under input-permutation.
  var kinds = cfg.desktopKind.mapIt($it)
  kinds.sort(cmp[string])
  parts.add("desktopKind=" & kinds.join(","))
  result = parts.join("|")

proc generationId*(cfg: ReproosDesktopConfig): string =
  ## Content-addressed generation ID. Inputs:
  ##   * variant: desktopKind (sorted seq[DesktopKind])
  ##   * configurable: activeAtBoot (DesktopKind)
  ##   * defaultUser / bootloaderTimeout / aptSnapshot
  ##   * NDEM version constant
  ##
  ## Returns a 32-char hex truncation of sha256. Per the spec's
  ## two-axis identity contract:
  ##   * Variant difference → different ID (closure differs).
  ##   * Configurable difference → different ID (activation differs,
  ##     closure identical).
  ##
  ## This is what makes ``reproos-rebuild list`` show distinct
  ## entries for variant + configurable changes both.
  let s = canonicaliseCfgForId(cfg)
  result = sha256OfString(s)[0 ..< 32]

# ---------------------------------------------------------------------------
# Sub-config derivation: convert the system-level configurables into the
# per-package configs each materialiser consumes. Spec note: the
# system-level aptSnapshot + defaultUser propagate atomically to every
# downstream so a snapshot bump invalidates the right thing transitively.
# ---------------------------------------------------------------------------

proc deriveSystemdSessionConfig(cfg: ReproosDesktopConfig):
                                SystemdSessionConfig =
  result = defaultSystemdSessionConfig()
  result.defaultUser = cfg.defaultUser
  result.aptSnapshot = cfg.aptSnapshot
  result.storeRoot = cfg.storeRoot

proc deriveDbusBrokerConfig(cfg: ReproosDesktopConfig): DbusBrokerConfig =
  result = defaultDbusBrokerConfig()
  result.aptSnapshot = cfg.aptSnapshot
  result.storeRoot = cfg.storeRoot

proc deriveGraphicsStackConfig(cfg: ReproosDesktopConfig):
                              GraphicsStackConfig =
  result = defaultGraphicsStackConfig()
  result.aptSnapshot = cfg.aptSnapshot
  result.storeRoot = cfg.storeRoot

proc deriveKernelConfig(cfg: ReproosDesktopConfig): KernelConfig =
  result = kernel.defaultConfig()
  result.storeRoot = cfg.storeRoot

proc deriveSwayConfig(cfg: ReproosDesktopConfig): SwayConfig =
  result = sway.defaultConfig()
  result.aptSnapshot = cfg.aptSnapshot
  result.storeRoot = cfg.storeRoot

proc deriveGnomeConfig(cfg: ReproosDesktopConfig): GnomeConfig =
  result = gnome.defaultConfig()
  result.aptSnapshot = cfg.aptSnapshot
  result.autoLoginUser = cfg.defaultUser
  result.storeRoot = cfg.storeRoot

proc derivePlasmaConfig(cfg: ReproosDesktopConfig): PlasmaConfig =
  result = plasma.defaultConfig()
  result.aptSnapshot = cfg.aptSnapshot
  result.sddmAutoLoginUser = cfg.defaultUser
  result.storeRoot = cfg.storeRoot

# ---------------------------------------------------------------------------
# Public materializer — compose the active variant + configurable set,
# merge the multi-contributor libpaths file, build the display-manager
# activation symlink, emit the GRUB entry, and return the manifest.
# ---------------------------------------------------------------------------

proc materializeReproosDesktop*(cfg: ReproosDesktopConfig):
                              ReproosDesktopOutputs =
  ## Spec NDEM1 entry point. Workflow:
  ##
  ## 1. ``validateDesktopConfig(cfg)`` — raises ``EConfigViolation``
  ##    when activeAtBoot is not in the desktopKind variant set.
  ## 2. Materialise the 4 foundation packages (systemd-session,
  ##    dbus-broker, graphics-stack, kernel) with the derived sub-
  ##    configs.
  ## 3. For each kind in ``cfg.desktopKind``, materialise the
  ##    corresponding DE package (variant-driven; closure shape).
  ## 4. Collect libpaths block contributions (graphics-stack + each
  ##    active DE) and merge per NDE-spec-block sort order.
  ## 5. Build the display-manager symlink for ``cfg.activeAtBoot``.
  ## 6. Emit the GRUB menu entry for the current generation.
  ## 7. Build the generation manifest recording every contributor's
  ##    storePaths.
  validateDesktopConfig(cfg)

  let genId = generationId(cfg)

  # --- Step 2: Foundation packages (always installed) ----------------
  let sessionOuts = materializeSystemdSession(
    deriveSystemdSessionConfig(cfg))
  let dbusOuts = materializeDbusBroker(deriveDbusBrokerConfig(cfg))
  let gfxOuts = materializeGraphicsStack(deriveGraphicsStackConfig(cfg))
  let kernelOuts = materializeKernel(deriveKernelConfig(cfg))

  # --- Step 3: Variant-driven DE materialisation ---------------------
  # Each DE is conditional on its kind appearing in the variant set.
  # The "Option-shaped" emission uses a default-zero ManagedFiles for
  # the unselected variants; downstream code checks the desktopKind
  # seq to decide whether the handle is meaningful.
  var swayOuts: SwayOutputs
  var swayActive = false
  if dkSway in cfg.desktopKind:
    swayOuts = materializeSway(deriveSwayConfig(cfg))
    swayActive = true

  var gnomeOuts: GnomeOutputs
  var gnomeActive = false
  if dkGnome in cfg.desktopKind:
    gnomeOuts = materializeGnome(deriveGnomeConfig(cfg))
    gnomeActive = true

  var plasmaOuts: PlasmaOutputs
  var plasmaActive = false
  if dkPlasma in cfg.desktopKind:
    plasmaOuts = materializePlasma(derivePlasmaConfig(cfg))
    plasmaActive = true

  # --- Step 4: Multi-contributor libpaths merge ----------------------
  var contributions: seq[LdConfContribution] = @[]

  # graphics-stack contribution — priority 100 (sorts first).
  contributions.add(LdConfContribution(
    handle: gfxOuts.ldConfBlock,
    priority: Nde0gLibpathsPriority,
    packageName: Nde0gPackageName,
    blockId: Nde0gLibpathsBlockId,
    scope: bsSystem,
    content: graphics_stack.renderLdConfBlockContent(
      deriveGraphicsStackConfig(cfg))))

  # DE compositor contributions — priority 500, sort alphabetically
  # by packageName (gnome < plasma < sway).
  if swayActive:
    contributions.add(LdConfContribution(
      handle: swayOuts.ldConfBlock,
      priority: NdeH1LibpathsPriority,
      packageName: NdeH1PackageName,
      blockId: NdeH1LibpathsBlockId,
      scope: bsSystem,
      content: sway.renderLdConfBlockContent(deriveSwayConfig(cfg))))
  if gnomeActive:
    contributions.add(LdConfContribution(
      handle: gnomeOuts.ldConfBlock,
      priority: NdeG1LibpathsPriority,
      packageName: NdeG1PackageName,
      blockId: NdeG1LibpathsBlockId,
      scope: bsSystem,
      content: gnome.renderLdConfBlockContent(deriveGnomeConfig(cfg))))
  if plasmaActive:
    contributions.add(LdConfContribution(
      handle: plasmaOuts.ldConfBlock,
      priority: NdeK1LibpathsPriority,
      packageName: NdeK1PackageName,
      blockId: NdeK1LibpathsBlockId,
      scope: bsSystem,
      content: plasma.renderLdConfBlockContent(derivePlasmaConfig(cfg))))

  let mergedBytes = mergeLdConfBlocks(contributions)
  result.mergedLdConf = emitMergedLdConf(
    relPath = NdemLdConfPath,
    content = mergedBytes,
    storeRoot = cfg.storeRoot)

  # --- Step 5: Display-manager activation symlink --------------------
  result.displayManagerSymlink = emitDisplayManagerSymlink(cfg)

  # --- Step 6: GRUB menu entry ---------------------------------------
  result.grubMenuEntries = emitGrubMenuEntries(cfg, genId)

  # --- Step 7: Generation manifest -----------------------------------
  var allStorePaths: seq[string] = @[]
  # Foundation packages: always present (closure-invariant).
  allStorePaths.add(systemd_session.storePaths(sessionOuts))
  allStorePaths.add(dbus_broker.storePaths(dbusOuts))
  allStorePaths.add(graphics_stack.storePaths(gfxOuts))
  allStorePaths.add(kernel.storePaths(kernelOuts))
  # Variant-driven DE packages.
  if swayActive:
    allStorePaths.add(sway.storePaths(swayOuts))
  if gnomeActive:
    allStorePaths.add(gnome.storePaths(gnomeOuts))
  if plasmaActive:
    allStorePaths.add(plasma.storePaths(plasmaOuts))
  # The merged ld.so.conf union + the display-manager symlink intent
  # + the GRUB menu entry are all part of the closure.
  allStorePaths.add(result.mergedLdConf.storePath)
  allStorePaths.add(result.displayManagerSymlink.storePath)
  allStorePaths.add(result.grubMenuEntries.storePath)
  allStorePaths.sort(cmp[string])

  # Activation-symlink intents.
  let dmIntent = activateDisplayManager(cfg)
  var activationSymlinks: seq[tuple[etcPath, target: string]] = @[
    (etcPath: dmIntent.etcPath, target: dmIntent.target)]

  # Merged-files manifest.
  let mergedFiles: seq[tuple[etcPath, contents: string]] = @[
    (etcPath: "/" & NdemLdConfPath, contents: mergedBytes)]

  result.manifest = GenerationManifest(
    generationId: genId,
    desktopKind: cfg.desktopKind,
    activeAtBoot: cfg.activeAtBoot,
    storePaths: allStorePaths,
    activationSymlinks: activationSymlinks,
    mergedFiles: mergedFiles)

# ---------------------------------------------------------------------------
# Convenience: enumerate the manifest's storePaths in stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: ReproosDesktopOutputs): seq[string] =
  ## Stable, sorted enumeration of every emitted store path the
  ## generation manifest covers. Mirrors the per-DE ``storePaths``
  ## helpers.
  result = outs.manifest.storePaths

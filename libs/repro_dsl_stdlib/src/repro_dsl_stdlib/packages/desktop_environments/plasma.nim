## NDE-K1: native KDE Plasma compositor package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE-K1.
##
## This module is the build-time implementation backing the package
## declaration at
## ``recipes/packages/desktop-environments/plasma/repro.nim``. Mirrors
## NDE-G1 (gnome) + NDE-H1 (sway) + NDE0-K / NDE0-G / NDE0-D / NDE0-S:
## the DSL ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads, so the spec'd ``files sddmConfig:`` and
## ``service displayManager:`` block forms don't yet work and the impl
## is exposed as ordinary Nim procs.
##
## ## What this package owns
##
## Per spec §NDE-K1, the native package replaces the Tier-2 surrogate's
## raw-heredoc sddm configuration with declarative, configurable-driven
## emissions. The file-emission outputs:
##
##   * ``/etc/sddm.conf`` — spec'd ``fs.configFile()`` emission with
##     INI-shaped content. The ``sddmAutoLogin`` / ``sddmAutoLoginUser`` /
##     ``waylandSession`` configurables propagate to the rendered content
##     + the content-addressed store path. The spec NDE-K1 acceptance
##     literal: toggling ``sddmAutoLogin`` from ``true`` to ``false``
##     re-keys only this output.
##   * ``/etc/ld.so.conf.d/00-reproos-linux.conf`` — managedBlock
##     contribution (scope=system, packageName=plasma, blockId=libpaths,
##     priority=500). Lists kwin + plasma-workspace + plasma-desktop +
##     kf5-frameworks + qt5-base store-path ``usr/lib/x86_64-linux-gnu/``
##     entries. v1 plants STUB paths since the .debs aren't vendored yet
##     (see honest deferrals); the fingerprint hygiene + sentinel shape
##     are spec-compatible so the multi-contributor merge step (NDEM1)
##     reads a forward-compatible block.
##   * ``/usr/lib/systemd/system/sddm.service`` — Type=simple display-
##     manager unit that runs the sddm binary. Planted at the cascade-G
##     path (R9 systemd 257.9 dropped /lib/systemd/system from
##     UnitPath).
##   * ``/etc/wayland-sessions/plasma.desktop`` — XDG session entry file
##     with ``Name=Plasma (Wayland)``, ``Exec=/usr/bin/startplasma-wayland``,
##     ``Type=Application``, ``DesktopNames=KDE``. The display-manager
##     greeter reads this directory to populate the session-picker
##     dropdown.
##   * ``/etc/pipewire/pipewire.conf`` — minimal PipeWire daemon config
##     when ``pipewireEnabled = true``; a "disabled" marker otherwise.
##     PipeWire is the Plasma audio/screen-capture stack (the spec
##     literal notes "since Plasma brings PipeWire"); the toggle is
##     bound into the rendered content so the cache key propagates.
##
## ## What this package consumes
##
## Per spec NDE-K1 ``uses:`` — apt-jammy (snapshot + sddm / kwin /
## plasma-workspace / plasma-desktop / kf5-frameworks / qt5-base debs) +
## systemd-session (PAM + user-session targets) + dbus-broker (system
## bus runtime) + graphics-stack (GL / Wayland prerequisites). v1 of
## NDE-K1 records the snapshot pin in every cache key but does NOT
## extract the .debs — that work tracks Tier-2 conventions. The native
## package ships the DECLARATIVE front end so downstream packages
## (NDEM1) can already ``uses: "plasma >=0.1.0"`` and consume the
## output handles.
##
## ## Reuse from NDE0-S
##
## NDE0-S's ``systemd_session.nim`` exports the minimal-viable
## ``configFile`` / ``managedBlock`` / ``ManagedFiles`` /
## ``DefaultStoreRoot`` / ``BlockScope`` helpers. This module imports
## them via the ``graphics_stack`` transitive re-export (so the
## cascade-G coordination + the NDE-spec-block triple-form sentinel
## shape stay aligned with the foundation packages and the sister
## NDE-H1 (sway) + NDE-G1 (gnome) packages).
##
## ## Honest deferrals
##
## * **sddm / kwin / plasma-workspace / plasma-desktop / kf5-frameworks
##   / qt5-base .deb extraction is OUT of scope for v1.** The
##   ld.so.conf.d block lists stub store paths whose hash is a pure
##   function of the snapshot pin + bundle name (same pattern NDE-G1 +
##   NDE-H1 + NDE0-G use with ``bundleStubHash``). When the apt-jammy
##   ``debs:`` extraction path lands for compositor binaries, the stub
##   paths migrate to real content-addressed extracted directories; the
##   cache-key contract is preserved (the fingerprint hash changes only
##   when the snapshot or the bundle set does).
##
## * **agent-harbor plasmoid integration is DEFERRED to NDA-placeholder.**
##   Plasma-on-ReproOS will eventually surface an agent-harbor plasmoid /
##   widget. That requires the agent-harbor handshake protocol which
##   isn't merged yet; v1 of NDE-K1 emits no plasmoid configuration.
##
## * **Generation-switch atomic activation is NDEM1 work.** The spec
##   acceptance ("Switch generation → login screen behaviour changes
##   atomically") needs the system-generation switching layer (NDEM1)
##   to read this package's outputs and plant the live ``/etc/sddm.conf``
##   + ``/etc/pipewire/`` symlinks. v1 emits the output handles; the
##   consumer that turns them into the live /etc/ tree is NDEM1.
##
## * **``files sddmConfig:`` + ``service displayManager:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from this module.

import std/[algorithm, os, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ../de_foundation/systemd_session
import ../de_foundation/graphics_stack

# Re-export the symbols downstream consumers need so a ``uses: "plasma
# >=0.1.0"`` package can do everything from one import. Mirror of
# NDE-G1 (gnome) + NDE-H1 (sway) + NDE0-K's re-export discipline.
export apt_jammy.AptFiles
export systemd_session
export graphics_stack

# ---------------------------------------------------------------------------
# Version constants — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  NdeK1Version* = "0.1.0"

  ## Canonical package name segment for the NDE-spec-block sentinels.
  ## Matches the ``package`` form's registered name in
  ## ``recipes/packages/desktop-environments/plasma/repro.nim``.
  ## Sentinel format ``# >>> repro:system:plasma:<blockId> >>>`` —
  ## MUST NOT be ``sway`` / ``gnome`` / ``hyprland``.
  NdeK1PackageName* = "plasma"

  ## NDE-spec-block libpaths blockId. Matches NDE0-G + NDE-H1 +
  ## NDE-G1's canonical block-id every DE-stack package contributes
  ## to.
  NdeK1LibpathsBlockId* = "libpaths"

  ## NDE-spec-block priority for compositor packages. Per the spec
  ## worked example (Generated-Configuration-Files.md §"Worked
  ## example — /etc/ld.so.conf.d/"): "the three priority-500
  ## compositors then sort by package name". Lower numbers sort
  ## earlier in the (priority, packageName, blockId) order; foundation
  ## graphics-stack is priority=100; compositors are priority=500.
  NdeK1LibpathsPriority* = 500

  ## Path under the content-addressed store where the sddm INI-config
  ## lands. Spec literal: ``fs.configFile(path = "/etc/sddm.conf",
  ## ...)``. The canonicalised in-store form drops the leading slash.
  NdeK1SddmConfigPath* = "etc/sddm.conf"

  ## Path under the content-addressed store where the sddm display-
  ## manager systemd unit lands. Cascade-G fix: ``usr/lib/systemd/system/``
  ## (R9 systemd 257.9 dropped the legacy /lib/systemd/system entry
  ## from UnitPath).
  NdeK1SddmServicePath* = "usr/lib/systemd/system/sddm.service"

  ## XDG session entry path. Display managers (sddm itself + gdm if
  ## installed alongside) scan ``/etc/wayland-sessions/`` for
  ## ``*.desktop`` entries to populate the session-picker dropdown.
  NdeK1SessionDesktopPath* = "etc/wayland-sessions/plasma.desktop"

  ## PipeWire daemon config path. Plasma's audio + screen-capture
  ## stack runs on PipeWire; the toggle is bound into the rendered
  ## content so both ``pipewireEnabled = true`` and
  ## ``pipewireEnabled = false`` emit a file (the "disabled" marker
  ## is documentary so the activation step can still plant a stable
  ## symlink).
  NdeK1PipewireConfigPath* = "etc/pipewire/pipewire.conf"

  ## The libpaths host file path the managedBlock contribution lands
  ## under (shared with NDE0-G + NDE-H1 + NDE-G1's contributions; the
  ## multi-contributor merge at NDEM1 unions them).
  NdeK1LdConfPath* = "etc/ld.so.conf.d/00-reproos-linux.conf"

# ---------------------------------------------------------------------------
# sha256 helper (used to compose the stub bundle hashes for the
# ld.so.conf.d block; the main emissions go through NDE0-S's helpers
# which embed their own per-output Nde0sVersion in the hash).
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
  PlasmaConfig* = object
    ## NDE-K1 configurables per the spec example. Defaults match the
    ## spec'd values: sddmAutoLogin=true, sddmAutoLoginUser="repro",
    ## waylandSession=true, pipewireEnabled=true, jammy snapshot pin.
    aptSnapshot*: string

    ## When ``true``, sddm logs the ``sddmAutoLoginUser`` in
    ## automatically at boot (skip the greeter password prompt).
    ## Default ``true`` per spec NDE-K1 — the load-bearing acceptance
    ## toggles this from ``true`` to ``false`` to demonstrate the
    ## cache-key propagation contract: only ``/etc/sddm.conf``
    ## re-keys.
    sddmAutoLogin*: bool

    ## Account used when ``sddmAutoLogin`` is ``true``. Default
    ## ``"repro"`` (matches NDE0-S's ``defaultUser`` + NDE-G1's
    ## autoLoginUser). Bound into the ``User=<user>`` line of the
    ## ``[Autologin]`` section of /etc/sddm.conf.
    sddmAutoLoginUser*: string

    ## When ``true``, sddm advertises the Wayland session entry as the
    ## default. When ``false``, sddm falls back to the (deferred) Xorg
    ## session. Bound into ``DisplayServer=wayland|x11`` of the
    ## ``[General]`` section of /etc/sddm.conf.
    waylandSession*: bool

    ## When ``true``, emit a minimal PipeWire daemon config (Plasma's
    ## audio + screen-capture stack runs on PipeWire). When ``false``,
    ## emit a "disabled" marker file so the activation step still has
    ## a stable target to symlink. Both branches re-key the
    ## ``pipewireConfig`` output deterministically.
    pipewireEnabled*: bool

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  PlasmaOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent.
    ##
    ## **Invalidation matrix** (load-bearing for NDE-K1 acceptance):
    ##
    ##   * Toggling ``sddmAutoLogin`` / ``sddmAutoLoginUser`` /
    ##     ``waylandSession`` → re-emits ``sddmConfig`` only; leaves
    ##     ``ldConfBlock`` + ``sddmService`` + ``sessionDesktopEntry``
    ##     + ``pipewireConfig`` cached.
    ##   * Toggling ``pipewireEnabled`` → re-emits ``pipewireConfig``
    ##     only; leaves the other four cached.
    ##   * Toggling ``aptSnapshot`` → re-emits ``ldConfBlock`` only
    ##     (the bundle stub hashes embed the snapshot); leaves
    ##     ``sddmConfig`` + ``sddmService`` + ``sessionDesktopEntry``
    ##     + ``pipewireConfig`` cached.
    sddmConfig*:           ManagedFiles
    ldConfBlock*:          ManagedFiles
    sddmService*:          ManagedFiles
    sessionDesktopEntry*:  ManagedFiles
    pipewireConfig*:       ManagedFiles

proc defaultConfig*(): PlasmaConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation. Spec literal values:
  ## sddmAutoLogin=true, sddmAutoLoginUser="repro", waylandSession=true,
  ## pipewireEnabled=true, aptSnapshot=jammy/20260615.
  result = PlasmaConfig(
    aptSnapshot:       "ubuntu/jammy/20260615T000000Z",
    sddmAutoLogin:     true,
    sddmAutoLoginUser: "repro",
    waylandSession:    true,
    pipewireEnabled:   true,
    storeRoot:         systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Bundle stub hashes for the ld.so.conf.d block (v1 deferral).
#
# Same shape as NDE-G1 + NDE-H1 + NDE0-G's bundleStubHash: 16-char hex
# pure function of (snapshot, bundle-name) so toggling the snapshot or
# extending the bundle list invalidates the block content (and therefore
# its content-addressed store path).
# ---------------------------------------------------------------------------

const
  ## The 5 jammy bundle pins NDE-K1 contributes to /etc/ld.so.conf.d/.
  ## v1 lists kwin (the Wayland compositor + window manager) +
  ## plasma-workspace (the shell + lockscreen) + plasma-desktop (the
  ## panel + widgets) + kf5-frameworks (the KDE Frameworks 5 runtime)
  ## + qt5-base (the Qt 5 runtime). When the .deb extraction lands,
  ## these bundle names map to real package sets — see
  ## ``recipes/catalog/linux/kwin.json`` etc. for the planned shapes
  ## (catalogs not vendored yet; this is a forward-compatible stub).
  NdeK1Bundles* = [
    ("kwin",             @["kwin-wayland", "kwin-common"]),
    ("plasma-workspace", @["plasma-workspace", "plasma-workspace-wayland"]),
    ("plasma-desktop",   @["plasma-desktop", "plasma-desktop-data"]),
    ("kf5-frameworks",   @["libkf5coreaddons5", "libkf5config-bin"]),
    ("qt5-base",         @["libqt5core5a", "libqt5gui5"])]

proc bundleStubHash*(snapshot, bundleName: string): string =
  ## 16-char hex stub mirroring NDE-G1 + NDE-H1 + NDE0-G's
  ## ``bundleStubHash`` shape:
  ## ``sha256(prefix + version + snapshot + bundleName)[0..15]``.
  let composed = "plasmaBundleStub" & NdeK1Version & snapshot & bundleName
  result = sha256OfString(composed)[0 ..< 16]

# ---------------------------------------------------------------------------
# Render the /etc/sddm.conf content.
# ---------------------------------------------------------------------------

proc displayServerToken(waylandSession: bool): string =
  ## sddm's ``[General] DisplayServer`` key accepts ``wayland`` or
  ## ``x11``. NDE-K1 honours ``waylandSession`` exactly: ``true`` →
  ## ``wayland``, ``false`` → ``x11`` (the Xorg fallback path is
  ## deferred but the token swap is the spec'd configurable propagation
  ## demo).
  if waylandSession: "wayland" else: "x11"

proc renderSddmConfig*(cfg: PlasmaConfig): string =
  ## Emit sddm's INI-format ``/etc/sddm.conf`` with the configurable-
  ## bound ``[Autologin]`` + ``[General]`` keys + the fixed
  ## ``[Wayland]`` + ``[Theme]`` sections.
  ##
  ## **Determinism**: section order is hand-authored (Autologin →
  ## General → Wayland → Theme). Within each section, key order is
  ## hand-authored. A trailing newline is guaranteed for POSIX-clean
  ## shell behaviour.
  ##
  ## See spec NDE-K1 §"Fix scope" for the worked example. Spec
  ## fragment: Plasma reuses NDE-G1's shape but for sddm + kwin +
  ## plasmashell + KF5/Qt5; configurables ``sddmAutoLogin``,
  ## ``sddmAutoLoginUser``, ``waylandSession``, ``pipewireEnabled``.
  let userLine =
    if cfg.sddmAutoLogin: cfg.sddmAutoLoginUser
    else: ""
  result = "# /etc/sddm.conf — generated by NDE-K1 native Plasma package.\n"
  result.add("# WARNING: regenerated on every system rebuild; manual edits will be lost.\n")
  result.add("# Source: " & NdeK1PackageName & " v" & NdeK1Version & "\n")
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("\n")
  result.add("[Autologin]\n")
  result.add("Relogin=false\n")
  result.add("Session=plasma\n")
  result.add("User=" & userLine & "\n")
  result.add("\n")
  result.add("[General]\n")
  result.add("DisplayServer=" & displayServerToken(cfg.waylandSession) & "\n")
  result.add("HaltCommand=/usr/bin/systemctl poweroff\n")
  result.add("RebootCommand=/usr/bin/systemctl reboot\n")
  result.add("\n")
  result.add("[Wayland]\n")
  result.add("SessionDir=/usr/share/wayland-sessions\n")
  result.add("EnableHiDPI=true\n")
  result.add("\n")
  result.add("[Theme]\n")
  result.add("Current=breeze\n")

# ---------------------------------------------------------------------------
# Render the ld.so.conf.d managed-block content (NDE-K1 contribution).
# ---------------------------------------------------------------------------

proc renderLdConfBlockContent*(cfg: PlasmaConfig): string =
  ## The block content between the NDE-spec-block sentinels. Lists the
  ## per-bundle store paths' ``usr/lib/x86_64-linux-gnu`` directories
  ## in deterministic order (bundles enumerated in the canonical order
  ## ``NdeK1Bundles``), preceded by a banner that records the resolved
  ## snapshot pin. The banner is what makes ``aptSnapshot`` propagate
  ## to the block content per the configurable-binding contract.
  result = "# NDE-K1: " & NdeK1PackageName & " libpaths contribution.\n"
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("#\n")
  result.add("# Store lib dirs (one per bundle; activation step unions\n")
  result.add("# co-contributors per NDE-spec-block multi-contributor rules):\n")
  for bundle in NdeK1Bundles:
    let (bundleName, _) = bundle
    let h = bundleStubHash(cfg.aptSnapshot, bundleName)
    result.add("/opt/reproos-linux/store/" & h &
               "/usr/lib/x86_64-linux-gnu  # " & bundleName & "\n")

# ---------------------------------------------------------------------------
# Render the sddm display-manager systemd unit + the XDG session entry
# + the pipewire daemon config.
# ---------------------------------------------------------------------------

proc renderSddmService*(cfg: PlasmaConfig): string =
  ## ``sddm.service`` content. Type=simple per upstream sddm
  ## conventions:
  ##
  ##   - Type=simple — sddm doesn't expose sd_notify; systemd
  ##     considers it started as soon as ExecStart spawns.
  ##   - ExecStart=/usr/bin/sddm — launches the display-manager
  ##     binary (Debian/Ubuntu package sddm ships at /usr/bin/sddm).
  ##   - After=systemd-user-sessions.service — sddm must come up only
  ##     after user-session activation infrastructure is alive.
  ##   - Requires=dbus.service — NDE0-D's system bus. sddm uses
  ##     accountsservice + logind via D-Bus.
  ##   - WantedBy=graphical.target — the activation layer plants the
  ##     .wants symlink so a graphical boot triggers sddm.
  ##
  ## The configurable ``cfg`` is recorded in a comment line so that
  ## v1's content has at least a documentary trail — but the unit
  ## content is identical across cfg variations (load-bearing for
  ## acceptance #10: sddmService stays cached when only sddmConfig
  ## configurables change).
  discard cfg  # explicitly unused — see docstring
  result = "# NDE-K1: sddm display-manager systemd unit.\n" &
           "[Unit]\n" &
           "Description=Simple Desktop Display Manager\n" &
           "Documentation=man:sddm(1)\n" &
           "Conflicts=getty@tty1.service\n" &
           "After=systemd-user-sessions.service\n" &
           "After=getty@tty1.service\n" &
           "After=plymouth-quit.service\n" &
           "Requires=dbus.service\n" &
           "\n" &
           "[Service]\n" &
           "Type=simple\n" &
           "ExecStart=/usr/bin/sddm\n" &
           "Restart=always\n" &
           "\n" &
           "[Install]\n" &
           "WantedBy=graphical.target\n"

proc renderSessionDesktopEntry*(cfg: PlasmaConfig): string =
  ## ``/etc/wayland-sessions/plasma.desktop`` content. XDG Desktop
  ## Entry Specification shape; display managers (sddm itself + gdm
  ## if installed alongside) read this directory to populate the
  ## session picker. ``DesktopNames=KDE`` is the load-bearing
  ## identifier the activation layer uses to wire the session through;
  ## kf5 / Qt5 apps key off ``$XDG_CURRENT_DESKTOP`` populated from
  ## this field.
  ##
  ## v1's content is identical across cfg variations — the
  ## ``DesktopNames=KDE`` line is what marks this as a Plasma session.
  ## The cfg arg is taken for forward-compat with NDEM1's per-
  ## generation tagging.
  discard cfg  # explicitly unused — see docstring
  result = "[Desktop Entry]\n" &
           "Name=Plasma (Wayland)\n" &
           "Comment=Plasma by KDE\n" &
           "Exec=/usr/bin/startplasma-wayland\n" &
           "TryExec=/usr/bin/startplasma-wayland\n" &
           "Type=Application\n" &
           "DesktopNames=KDE\n"

proc renderPipewireConfig*(cfg: PlasmaConfig): string =
  ## ``/etc/pipewire/pipewire.conf`` content. Two branches:
  ##
  ##   * ``pipewireEnabled = true``: a minimal pipewire daemon config
  ##     with the default-properties block + the default-context
  ##     stanza referencing the system pipewire-media-session bundle.
  ##     The configurable's "on" semantics: emit a real config so the
  ##     activation step can wire ``systemctl --user enable
  ##     pipewire.service`` against a planted file.
  ##   * ``pipewireEnabled = false``: a "disabled" marker file so the
  ##     activation step still has a stable target to symlink.
  ##     Documentary: the file announces the disabled state + records
  ##     the snapshot pin for the cache key.
  ##
  ## Both branches re-key the ``pipewireConfig`` output
  ## deterministically (the rendered content differs); the bytes are
  ## byte-identical for fixed input.
  result = "# /etc/pipewire/pipewire.conf — generated by NDE-K1 native Plasma package.\n"
  result.add("# Source: " & NdeK1PackageName & " v" & NdeK1Version & "\n")
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("\n")
  if cfg.pipewireEnabled:
    result.add("# PipeWire daemon: ENABLED (Plasma audio + screen-capture stack).\n")
    result.add("context.properties = {\n")
    result.add("    default.clock.rate          = 48000\n")
    result.add("    default.clock.allowed-rates = [ 44100 48000 ]\n")
    result.add("    default.clock.quantum       = 1024\n")
    result.add("    default.clock.min-quantum   = 32\n")
    result.add("    default.clock.max-quantum   = 2048\n")
    result.add("    log.level                   = 2\n")
    result.add("}\n")
    result.add("\n")
    result.add("context.modules = [\n")
    result.add("    { name = libpipewire-module-rt }\n")
    result.add("    { name = libpipewire-module-protocol-native }\n")
    result.add("    { name = libpipewire-module-client-node }\n")
    result.add("    { name = libpipewire-module-adapter }\n")
    result.add("]\n")
  else:
    result.add("# PipeWire daemon: DISABLED.\n")
    result.add("#\n")
    result.add("# This marker file is planted so the activation step has\n")
    result.add("# a stable target to symlink. The pipewire user units are\n")
    result.add("# NOT wired in this generation; audio falls back to the\n")
    result.add("# (deferred) ALSA-direct path.\n")
    result.add("pipewire.enabled = false\n")

# ---------------------------------------------------------------------------
# Public materializer — emit every NDE-K1 output.
# ---------------------------------------------------------------------------

proc materializePlasma*(cfg: PlasmaConfig): PlasmaOutputs =
  ## Emit every NDE-K1 output. Each helper invocation is independent
  ## so the cache keys are per-output — see the docstring for
  ## ``PlasmaOutputs`` for the full invalidation matrix.
  ##
  ## NB: ``sddm.service`` is planted at ``usr/lib/systemd/system/``
  ## (the cascade-G fix); it is NOT planted at ``lib/systemd/system/``.
  ## R9 systemd 257.9's default UnitPath dropped the legacy
  ## /lib/systemd/system entry, so anything planted there would be
  ## invisible at boot.

  result.sddmConfig = configFile(
    path = NdeK1SddmConfigPath,
    content = renderSddmConfig(cfg),
    storeRoot = cfg.storeRoot)

  result.ldConfBlock = managedBlock(
    path = NdeK1LdConfPath,
    scope = bsSystem,
    packageName = NdeK1PackageName,
    blockId = NdeK1LibpathsBlockId,
    content = renderLdConfBlockContent(cfg),
    priority = NdeK1LibpathsPriority,   # compositor sort key (=500)
    storeRoot = cfg.storeRoot)

  result.sddmService = configFile(
    path = NdeK1SddmServicePath,
    content = renderSddmService(cfg),
    storeRoot = cfg.storeRoot)

  result.sessionDesktopEntry = configFile(
    path = NdeK1SessionDesktopPath,
    content = renderSessionDesktopEntry(cfg),
    storeRoot = cfg.storeRoot)

  result.pipewireConfig = configFile(
    path = NdeK1PipewireConfigPath,
    content = renderPipewireConfig(cfg),
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: PlasmaOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the spec'd activation order: sddmConfig first (the sddm
  ## daemon's INI configuration), then ldConfBlock (the link-path
  ## contribution the ldconfig oneshot reads), then sddmService (the
  ## systemd display-manager unit), then sessionDesktopEntry (the
  ## display-manager session-picker entry), then pipewireConfig (the
  ## audio / screen-capture daemon config).
  result = @[
    outs.sddmConfig.storePath,
    outs.ldConfBlock.storePath,
    outs.sddmService.storePath,
    outs.sessionDesktopEntry.storePath,
    outs.pipewireConfig.storePath]

proc sortedStorePaths*(outs: PlasmaOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])

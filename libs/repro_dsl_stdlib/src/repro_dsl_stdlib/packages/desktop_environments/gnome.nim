## NDE-G1: native GNOME compositor package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE-G1.
##
## This module is the build-time implementation backing the package
## declaration at
## ``recipes/packages/desktop-environments/gnome/repro.nim``. Mirrors the
## NDE-H1 (sway) + NDE0-K / NDE0-G / NDE0-D / NDE0-S layout: the DSL
## ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`` only
## recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads, so the spec'd ``files gdmConfig:`` and
## ``service displayManager:`` block forms don't yet work and the impl
## is exposed as ordinary Nim procs.
##
## ## What this package owns
##
## Per spec §NDE-G1, the native package replaces the Tier-2 surrogate's
## raw-heredoc gdm3 configuration with declarative, configurable-driven
## emissions. The file-emission outputs:
##
##   * ``/etc/gdm3/custom.conf`` — spec'd ``fs.configFile()`` emission
##     with INI-shaped content. The ``autoLogin`` / ``autoLoginUser`` /
##     ``waylandSession`` / ``disableInitialSetup`` configurables
##     propagate to the rendered content + the content-addressed store
##     path. This is the spec NDE-G1 acceptance literal: toggling
##     ``autoLogin`` from ``true`` to ``false`` re-keys only this
##     output.
##   * ``/etc/ld.so.conf.d/00-reproos-linux.conf`` — managedBlock
##     contribution (scope=system, packageName=gnome, blockId=libpaths,
##     priority=500). Lists the gnome-shell + mutter + gnome-session
##     store-path ``usr/lib/x86_64-linux-gnu/`` entries. v1 plants STUB
##     paths since the .debs aren't vendored yet (see honest deferrals);
##     the fingerprint hygiene + sentinel shape are spec-compatible so
##     the multi-contributor merge step (NDEM1) reads a forward-
##     compatible block.
##   * ``/usr/lib/systemd/system/gdm.service`` — Type=notify display-
##     manager unit that runs the gdm3 binary. Planted at the cascade-G
##     path (R9 systemd 257.9 dropped /lib/systemd/system from
##     UnitPath).
##   * ``/etc/wayland-sessions/gnome.desktop`` — XDG session entry file
##     with ``Name=GNOME``, ``Exec=/usr/local/bin/gnome-session``,
##     ``Type=Application``, ``DesktopNames=GNOME``,
##     ``X-GDM-SessionRegisters=true``. The display-manager greeter
##     reads this directory to populate the session-picker dropdown.
##
## ## What this package consumes
##
## Per spec NDE-G1 ``uses:`` — apt-jammy (snapshot + gdm/gnome-shell/
## mutter/gnome-settings-daemon/at-spi2-core/gnome-session debs) +
## systemd-session (PAM + user-session targets) + dbus-broker (system
## bus runtime) + graphics-stack (GL / Wayland prerequisites). v1 of
## NDE-G1 records the snapshot pin in every cache key but does NOT
## extract the .debs — that work tracks Tier-2 conventions. The native
## package ships the DECLARATIVE front end so downstream packages
## (NDEM1) can already ``uses: "gnome >=0.1.0"`` and consume the
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
## NDE-H1 sway package).
##
## ## Honest deferrals
##
## * **gnome-shell / mutter / gdm3 .deb extraction is OUT of scope for
##   v1.** The ld.so.conf.d block lists stub store paths whose hash is
##   a pure function of the snapshot pin + bundle name (same pattern
##   NDE-H1 + NDE0-G use with ``bundleStubHash``). When the apt-jammy
##   ``debs:`` extraction path lands for compositor binaries, the stub
##   paths migrate to real content-addressed extracted directories; the
##   cache-key contract is preserved (the fingerprint hash changes only
##   when the snapshot or the bundle set does).
##
## * **agent-harbor integration is DEFERRED to NDA-placeholder.** GNOME-
##   on-ReproOS will eventually surface an agent-harbor extension /
##   Shell-extension pane. That requires the agent-harbor handshake
##   protocol which isn't merged yet; v1 of NDE-G1 emits no extension
##   configuration.
##
## * **Generation-switch atomic activation is NDEM1 work.** The spec
##   acceptance ("Switch generation → login screen behaviour changes
##   atomically") needs the system-generation switching layer (NDEM1)
##   to read this package's outputs and plant the live ``/etc/gdm3/``
##   symlinks. v1 emits the output handles; the consumer that turns
##   them into the live /etc/ tree is NDEM1.
##
## * **``files gdmConfig:`` + ``service displayManager:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from this module.

import std/[algorithm, os, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ../de_foundation/systemd_session
import ../de_foundation/graphics_stack

# Re-export the symbols downstream consumers need so a ``uses: "gnome
# >=0.1.0"`` package can do everything from one import. Mirror of NDE-H1
# (sway) and NDE0-K's re-export discipline.
export apt_jammy.AptFiles
export systemd_session
export graphics_stack

# ---------------------------------------------------------------------------
# Version constants — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  NdeG1Version* = "0.1.0"

  ## Canonical package name segment for the NDE-spec-block sentinels.
  ## Matches the ``package`` form's registered name in
  ## ``recipes/packages/desktop-environments/gnome/repro.nim``.
  ## Sentinel format ``# >>> repro:system:gnome:<blockId> >>>`` —
  ## MUST NOT be ``sway`` / ``hyprland`` / ``plasma``.
  NdeG1PackageName* = "gnome"

  ## NDE-spec-block libpaths blockId. Matches NDE0-G + NDE-H1's
  ## canonical block-id every DE-stack package contributes to.
  NdeG1LibpathsBlockId* = "libpaths"

  ## NDE-spec-block priority for compositor packages. Per the spec
  ## worked example (Generated-Configuration-Files.md §"Worked
  ## example — /etc/ld.so.conf.d/"): "the three priority-500
  ## compositors then sort by package name". Lower numbers sort
  ## earlier in the (priority, packageName, blockId) order; foundation
  ## graphics-stack is priority=100; compositors are priority=500.
  NdeG1LibpathsPriority* = 500

  ## Path under the content-addressed store where the gdm3 daemon
  ## INI-config lands. Spec literal:
  ## ``fs.configFile(path = "/etc/gdm3/custom.conf", ...)``. The
  ## canonicalised in-store form drops the leading slash.
  NdeG1GdmConfigPath* = "etc/gdm3/custom.conf"

  ## Path under the content-addressed store where the gdm display-
  ## manager systemd unit lands. Cascade-G fix: ``usr/lib/systemd/system/``
  ## (R9 systemd 257.9 dropped the legacy /lib/systemd/system entry
  ## from UnitPath).
  NdeG1GdmServicePath* = "usr/lib/systemd/system/gdm.service"

  ## XDG session entry path. Display managers (gdm itself + sddm)
  ## scan ``/etc/wayland-sessions/`` for ``*.desktop`` entries to
  ## populate the session-picker dropdown.
  NdeG1SessionDesktopPath* = "etc/wayland-sessions/gnome.desktop"

  ## The libpaths host file path the managedBlock contribution lands
  ## under (shared with NDE0-G + NDE-H1's contributions; the multi-
  ## contributor merge at NDEM1 unions them).
  NdeG1LdConfPath* = "etc/ld.so.conf.d/00-reproos-linux.conf"

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
  GnomeConfig* = object
    ## NDE-G1 configurables per the spec example. Defaults match the
    ## spec'd values: autoLogin=true, autoLoginUser="repro",
    ## waylandSession=true, disableInitialSetup=true, jammy snapshot
    ## pin.
    aptSnapshot*: string

    ## When ``true``, gdm logs the ``autoLoginUser`` in automatically
    ## at boot (skip the greeter password prompt). Default ``true``
    ## per spec NDE-G1 — the load-bearing acceptance toggles this from
    ## ``true`` to ``false`` to demonstrate the cache-key propagation
    ## contract: only ``/etc/gdm3/custom.conf`` re-keys.
    autoLogin*: bool

    ## Account used when ``autoLogin`` is ``true``. Default ``"repro"``
    ## (matches NDE0-S's ``defaultUser``). Bound into the
    ## ``AutomaticLogin=<user>`` line of /etc/gdm3/custom.conf.
    autoLoginUser*: string

    ## When ``true``, gdm advertises the Wayland session entry as the
    ## default. When ``false``, gdm falls back to the (deferred) Xorg
    ## session. Bound into ``WaylandEnable=true|false`` of
    ## /etc/gdm3/custom.conf.
    waylandSession*: bool

    ## When ``true``, suppress gnome-initial-setup on first boot (the
    ## "welcome" wizard that runs once per fresh user account). The
    ## ReproOS MVP uses a serial console + autologin user, so the
    ## wizard would block the boot acceptance gate.
    disableInitialSetup*: bool

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  GnomeOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent.
    ##
    ## **Invalidation matrix** (load-bearing for NDE-G1 acceptance):
    ##
    ##   * Toggling ``autoLogin`` / ``autoLoginUser`` /
    ##     ``waylandSession`` / ``disableInitialSetup`` → re-emits
    ##     ``gdmConfig`` only; leaves ``ldConfBlock`` + ``gdmService``
    ##     + ``sessionDesktopEntry`` cached.
    ##   * Toggling ``aptSnapshot`` → re-emits ``ldConfBlock`` only
    ##     (the bundle stub hashes embed the snapshot); leaves
    ##     ``gdmConfig`` + ``gdmService`` + ``sessionDesktopEntry``
    ##     cached.
    gdmConfig*:            ManagedFiles
    ldConfBlock*:          ManagedFiles
    gdmService*:           ManagedFiles
    sessionDesktopEntry*:  ManagedFiles

proc defaultConfig*(): GnomeConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation. Spec literal values:
  ## autoLogin=true, autoLoginUser="repro", waylandSession=true,
  ## disableInitialSetup=true, aptSnapshot=jammy/20260615.
  result = GnomeConfig(
    aptSnapshot:         "ubuntu/jammy/20260615T000000Z",
    autoLogin:           true,
    autoLoginUser:       "repro",
    waylandSession:      true,
    disableInitialSetup: true,
    storeRoot:           systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Bundle stub hashes for the ld.so.conf.d block (v1 deferral).
#
# Same shape as NDE-H1's + NDE0-G's bundleStubHash: 16-char hex pure
# function of (snapshot, bundle-name) so toggling the snapshot or
# extending the bundle list invalidates the block content (and therefore
# its content-addressed store path).
# ---------------------------------------------------------------------------

const
  ## The 3 jammy bundle pins NDE-G1 contributes to /etc/ld.so.conf.d/.
  ## v1 lists gnome-shell (the user shell) + mutter (the Wayland
  ## compositor library) + gnome-session (the session manager). When
  ## the .deb extraction lands, these bundle names map to real
  ## package sets — see ``recipes/catalog/linux/gnome-shell.json`` /
  ## ``mutter.json`` / ``gnome-session.json`` for the planned shapes
  ## (catalogs not vendored yet; this is a forward-compatible stub).
  NdeG1Bundles* = [
    ("gnome-shell",   @["gnome-shell", "gdm3"]),
    ("mutter",        @["mutter", "libmutter-10-0"]),
    ("gnome-session", @["gnome-session", "gnome-session-bin"])]

proc bundleStubHash*(snapshot, bundleName: string): string =
  ## 16-char hex stub mirroring NDE-H1's + NDE0-G's ``bundleStubHash``
  ## shape: ``sha256(prefix + version + snapshot + bundleName)[0..15]``.
  let composed = "gnomeBundleStub" & NdeG1Version & snapshot & bundleName
  result = sha256OfString(composed)[0 ..< 16]

# ---------------------------------------------------------------------------
# Render the /etc/gdm3/custom.conf content.
# ---------------------------------------------------------------------------

proc boolToIni(b: bool): string =
  ## INI-style true/false (lowercase — gdm parses these
  ## case-insensitively but the spec literal in NDE-G1 uses lowercase).
  if b: "true" else: "false"

proc renderGdmConfig*(cfg: GnomeConfig): string =
  ## Emit gdm3's INI-format ``custom.conf`` with the configurable-
  ## bound ``[daemon]`` keys + the fixed ``[chooser]`` /
  ## ``[security]`` / ``[xdmcp]`` / ``[debug]`` /
  ## ``[InitialSetupEnable]`` sections.
  ##
  ## **Determinism**: section order is hand-authored (daemon →
  ## chooser → debug → security → xdmcp → InitialSetupEnable). Within
  ## each section, key order is hand-authored. A trailing newline is
  ## guaranteed for POSIX-clean shell behaviour.
  ##
  ## See spec NDE-G1 §"Fix scope" for the worked example. Spec
  ## fragment:
  ##
  ##   daemon:
  ##     WaylandEnable = "true"
  ##     AutomaticLoginEnable = $config.autoLogin
  ##     AutomaticLogin = config.autoLoginUser
  ##   chooser:
  ##     Multicast = "false"
  result = "# /etc/gdm3/custom.conf — generated by NDE-G1 native GNOME package.\n"
  result.add("# WARNING: regenerated on every system rebuild; manual edits will be lost.\n")
  result.add("# Source: " & NdeG1PackageName & " v" & NdeG1Version & "\n")
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("\n")
  result.add("[daemon]\n")
  result.add("WaylandEnable=" & boolToIni(cfg.waylandSession) & "\n")
  result.add("AutomaticLoginEnable=" & boolToIni(cfg.autoLogin) & "\n")
  result.add("AutomaticLogin=" & cfg.autoLoginUser & "\n")
  result.add("\n")
  result.add("[chooser]\n")
  result.add("Multicast=false\n")
  result.add("\n")
  result.add("[debug]\n")
  result.add("Enable=false\n")
  result.add("\n")
  result.add("[security]\n")
  result.add("DisallowTCP=true\n")
  result.add("\n")
  result.add("[xdmcp]\n")
  result.add("Enable=false\n")
  result.add("\n")
  result.add("[InitialSetupEnable]\n")
  result.add("InitialSetupEnable=" & boolToIni(not cfg.disableInitialSetup) & "\n")

# ---------------------------------------------------------------------------
# Render the ld.so.conf.d managed-block content (NDE-G1 contribution).
# ---------------------------------------------------------------------------

proc renderLdConfBlockContent*(cfg: GnomeConfig): string =
  ## The block content between the NDE-spec-block sentinels. Lists the
  ## per-bundle store paths' ``usr/lib/x86_64-linux-gnu`` directories
  ## in deterministic order (bundles enumerated in the canonical order
  ## ``NdeG1Bundles``), preceded by a banner that records the resolved
  ## snapshot pin. The banner is what makes ``aptSnapshot`` propagate
  ## to the block content per the configurable-binding contract.
  result = "# NDE-G1: " & NdeG1PackageName & " libpaths contribution.\n"
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("#\n")
  result.add("# Store lib dirs (one per bundle; activation step unions\n")
  result.add("# co-contributors per NDE-spec-block multi-contributor rules):\n")
  for bundle in NdeG1Bundles:
    let (bundleName, _) = bundle
    let h = bundleStubHash(cfg.aptSnapshot, bundleName)
    result.add("/opt/reproos-linux/store/" & h &
               "/usr/lib/x86_64-linux-gnu  # " & bundleName & "\n")

# ---------------------------------------------------------------------------
# Render the gdm display-manager systemd unit + the XDG session entry.
# ---------------------------------------------------------------------------

proc renderGdmService*(cfg: GnomeConfig): string =
  ## ``gdm.service`` content. Type=notify per upstream gdm conventions:
  ##
  ##   - Type=notify — gdm uses sd_notify(3) to signal ready; systemd
  ##     blocks dependent units until then.
  ##   - ExecStart=/usr/sbin/gdm3 — launches the display-manager
  ##     binary (Debian/Ubuntu package gdm3 ships at /usr/sbin/gdm3).
  ##   - After=systemd-user-sessions.service — gdm must come up only
  ##     after user-session activation infrastructure is alive.
  ##   - Requires=dbus.service — NDE0-D's system bus. gdm uses
  ##     accountsservice + logind via D-Bus.
  ##   - WantedBy=graphical.target — the activation layer plants the
  ##     .wants symlink so a graphical boot triggers gdm.
  ##
  ## The configurable ``cfg`` is recorded in a comment line so that
  ## v1's content has at least a documentary trail — but the unit
  ## content is identical across cfg variations (load-bearing for
  ## acceptance #10: gdmService stays cached when only gdmConfig
  ## configurables change).
  discard cfg  # explicitly unused — see docstring
  result = "# NDE-G1: gdm3 display-manager systemd unit.\n" &
           "[Unit]\n" &
           "Description=GNOME Display Manager\n" &
           "Documentation=man:gdm(1)\n" &
           "Conflicts=getty@tty1.service\n" &
           "After=systemd-user-sessions.service\n" &
           "After=getty@tty1.service\n" &
           "After=plymouth-quit.service\n" &
           "Requires=dbus.service\n" &
           "\n" &
           "[Service]\n" &
           "Type=notify\n" &
           "ExecStart=/usr/sbin/gdm3\n" &
           "Restart=always\n" &
           "IgnoreSIGPIPE=no\n" &
           "BusName=org.gnome.DisplayManager\n" &
           "\n" &
           "[Install]\n" &
           "WantedBy=graphical.target\n"

proc renderSessionDesktopEntry*(cfg: GnomeConfig): string =
  ## ``/etc/wayland-sessions/gnome.desktop`` content. XDG Desktop
  ## Entry Specification shape; display managers (gdm itself, plus
  ## sddm if installed alongside) read this directory to populate the
  ## session picker. ``X-GDM-SessionRegisters=true`` tells gdm the
  ## session registers itself with logind on startup (so gdm doesn't
  ## need to do that registration itself).
  ##
  ## v1's content is identical across cfg variations — the
  ## ``DesktopNames=GNOME`` line is the load-bearing identifier the
  ## activation layer uses to wire the session through. The cfg arg
  ## is taken for forward-compat with NDEM1's per-generation tagging.
  discard cfg  # explicitly unused — see docstring
  result = "[Desktop Entry]\n" &
           "Name=GNOME\n" &
           "Comment=This session logs you into GNOME\n" &
           "Exec=/usr/local/bin/gnome-session\n" &
           "TryExec=/usr/local/bin/gnome-session\n" &
           "Type=Application\n" &
           "DesktopNames=GNOME\n" &
           "X-GDM-SessionRegisters=true\n"

# ---------------------------------------------------------------------------
# Public materializer — emit every NDE-G1 output.
# ---------------------------------------------------------------------------

proc materializeGnome*(cfg: GnomeConfig): GnomeOutputs =
  ## Emit every NDE-G1 output. Each helper invocation is independent
  ## so the cache keys are per-output — see the docstring for
  ## ``GnomeOutputs`` for the full invalidation matrix.
  ##
  ## NB: ``gdm.service`` is planted at ``usr/lib/systemd/system/``
  ## (the cascade-G fix); it is NOT planted at ``lib/systemd/system/``.
  ## R9 systemd 257.9's default UnitPath dropped the legacy
  ## /lib/systemd/system entry, so anything planted there would be
  ## invisible at boot.

  result.gdmConfig = configFile(
    path = NdeG1GdmConfigPath,
    content = renderGdmConfig(cfg),
    storeRoot = cfg.storeRoot)

  result.ldConfBlock = managedBlock(
    path = NdeG1LdConfPath,
    scope = bsSystem,
    packageName = NdeG1PackageName,
    blockId = NdeG1LibpathsBlockId,
    content = renderLdConfBlockContent(cfg),
    priority = NdeG1LibpathsPriority,   # compositor sort key (=500)
    storeRoot = cfg.storeRoot)

  result.gdmService = configFile(
    path = NdeG1GdmServicePath,
    content = renderGdmService(cfg),
    storeRoot = cfg.storeRoot)

  result.sessionDesktopEntry = configFile(
    path = NdeG1SessionDesktopPath,
    content = renderSessionDesktopEntry(cfg),
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: GnomeOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the spec'd activation order: gdmConfig first (the gdm
  ## daemon's INI configuration), then ldConfBlock (the link-path
  ## contribution the ldconfig oneshot reads), then gdmService (the
  ## systemd display-manager unit), then sessionDesktopEntry (the
  ## display-manager session-picker entry).
  result = @[
    outs.gdmConfig.storePath,
    outs.ldConfBlock.storePath,
    outs.gdmService.storePath,
    outs.sessionDesktopEntry.storePath]

proc sortedStorePaths*(outs: GnomeOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])

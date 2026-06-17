## NDE-H1: native sway compositor package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE-H1.
##
## This module is the build-time implementation backing the package
## declaration at
## ``recipes/packages/desktop-environments/sway/repro.nim``. Mirrors the
## NDE0-K / NDE0-G / NDE0-D / NDE0-S layout: the DSL ``parsePackageDef``
## macro at ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``
## only recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads, so the spec'd ``files config:`` and
## ``service sessionManager:`` block forms don't yet work and the impl
## is exposed as ordinary Nim procs.
##
## ## Naming decision (load-bearing)
##
## The campaign spec's Tier-2 work (DE-H1) shipped ``sway`` as a
## Hyprland surrogate. The user clarified on 2026-06-17 that Tier-1
## native packages should be true to their identity:
##
##   * **This package is named ``sway``** (or ``swayCompositor`` for the
##     camelCase DSL symbol). It is the minimal wlroots-tiling Wayland
##     compositor — the canonical i3-on-Wayland project.
##   * **packageName for NDE-spec-block sentinels = ``sway``**
##     (kebab-case). The triple-form sentinel is
##     ``# >>> repro:system:sway:<blockId> >>>``.
##   * Hyprland-the-package (a separate wlroots-derived compositor with
##     its own configuration syntax + ecosystem) is a **future
##     NDE-Hp1 milestone**, not in scope here. NDE-H1's surface is
##     sway-shaped: ``/etc/sway/config``, ``sway-session.service``,
##     ``/etc/wayland-sessions/sway.desktop``.
##
## ## What this package owns
##
## Per spec §NDE-H1, the native package replaces the Tier-2 surrogate's
## raw-heredoc configuration with declarative, configurable-driven
## emissions. The file-emission outputs:
##
##   * ``/etc/sway/config`` — the spec'd ``fs.configFile()`` emission
##     with sway's native config syntax. Configurables ``superKey`` +
##     ``terminalApp`` + ``launcherApp`` + ``extraModelines`` propagate
##     to the rendered content + the content-addressed store path. This
##     is the load-bearing acceptance: toggling ``terminalApp`` from
##     ``"foot"`` to ``"alacritty"`` re-keys only this output.
##   * ``/etc/ld.so.conf.d/00-reproos-linux.conf`` — managedBlock
##     contribution (scope=system, packageName=sway, blockId=libpaths,
##     priority=500). Lists the wlroots + sway store-path
##     ``usr/lib/x86_64-linux-gnu/`` entries. v1 plants STUB paths since
##     the .debs aren't vendored yet (see honest deferrals); the
##     fingerprint hygiene + sentinel shape are spec-compatible so the
##     multi-contributor merge step (NDEM1) reads a forward-compatible
##     block.
##   * ``/usr/lib/systemd/system/sway-session.service`` — Type=oneshot
##     user-session unit that runs ``sway``. Planted at the cascade-G
##     path (R9 systemd 257.9 dropped /lib/systemd/system from
##     UnitPath).
##   * ``/etc/wayland-sessions/sway.desktop`` — XDG session entry file
##     with ``Name=Sway``, ``Comment=An i3-compatible Wayland
##     compositor``, ``Exec=sway``, ``Type=Application``. The display-
##     manager greeters (gdm / sddm) read this directory to populate
##     the session-picker dropdown.
##
## ## What this package consumes
##
## Per spec NDE-H1 ``uses:`` — apt-jammy (snapshot + sway binary debs)
## + systemd-session (PAM + user-session targets) + dbus-broker (system
## bus runtime) + graphics-stack (wlroots libraries + DRM userland).
## v1 of NDE-H1 records the snapshot pin in every cache key but does
## NOT extract the sway / wlroots .debs — that work tracks Tier-2
## conventions. The native package ships the DECLARATIVE front end so
## downstream packages (NDEM1) can already ``uses: "sway >=0.1.0"`` and
## consume the output handles.
##
## ## Reuse from NDE0-S
##
## NDE0-S's ``systemd_session.nim`` exports the minimal-viable
## ``configFile`` / ``managedBlock`` / ``ManagedFiles`` /
## ``DefaultStoreRoot`` / ``BlockScope`` helpers. This module imports
## them via the ``graphics_stack`` transitive re-export (so the
## cascade-G coordination + the NDE-spec-block triple-form sentinel
## shape stay aligned with the foundation packages).
##
## ## Honest deferrals
##
## * **sway / wlroots .deb extraction is OUT of scope for v1.** The
##   ld.so.conf.d block lists stub store paths whose hash is a pure
##   function of the snapshot pin + sway version (same pattern NDE0-G
##   uses with ``bundleStubHash``). When the apt-jammy ``debs:``
##   extraction path lands for compositor binaries, the stub paths
##   migrate to real content-addressed extracted directories; the cache-
##   key contract is preserved (the fingerprint hash changes only when
##   the snapshot or the bundle set does).
##
## * **agent-harbor pane is DEFERRED to NDA-placeholder.** Spec note:
##   sway-on-ReproOS will host an agent-harbor pane as a status side-bar.
##   That requires the agent-harbor handshake protocol which isn't
##   merged yet; v1 of NDE-H1 emits no pane configuration.
##
## * **Generation-switch atomic activation is NDEM1 work.** The spec
##   acceptance ("Generation switch atomically activates") needs the
##   system-generation switching layer (NDEM1) to read this package's
##   outputs and plant the live ``/etc/sway/config`` symlink. v1 emits
##   the output handles; the consumer that turns them into the live
##   /etc/ tree is NDEM1.
##
## * **``files config:`` + ``service sessionManager:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from this module.

import std/[algorithm, os, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ../de_foundation/systemd_session
import ../de_foundation/graphics_stack

# Re-export the symbols downstream consumers need so a ``uses: "sway
# >=0.1.0"`` package can do everything from one import. Mirror of NDE0-K's
# re-export discipline.
export apt_jammy.AptFiles
export systemd_session
export graphics_stack

# ---------------------------------------------------------------------------
# Version constants — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  NdeH1Version* = "0.1.0"

  ## Canonical package name segment for the NDE-spec-block sentinels.
  ## Matches the ``package`` form's registered name in
  ## ``recipes/packages/desktop-environments/sway/repro.nim``.
  ## Per the naming decision in the module preamble: ``sway``
  ## (kebab-case), NOT ``hyprland`` and NOT ``sway-as-hyprland``.
  NdeH1PackageName* = "sway"

  ## NDE-spec-block libpaths blockId. Matches NDE0-G's canonical
  ## block-id every DE-stack package contributes to.
  NdeH1LibpathsBlockId* = "libpaths"

  ## NDE-spec-block priority for compositor packages. Per the spec
  ## worked example (Generated-Configuration-Files.md §"Worked
  ## example — /etc/ld.so.conf.d/"): "the three priority-500
  ## compositors then sort by package name". Lower numbers sort
  ## earlier in the (priority, packageName, blockId) order; foundation
  ## graphics-stack is priority=100; compositors are priority=500.
  NdeH1LibpathsPriority* = 500

  ## Path under the content-addressed store where the systemd user-
  ## session unit lands. Cascade-G fix: ``usr/lib/systemd/system/``
  ## (R9 systemd 257.9 dropped the legacy /lib/systemd/system entry
  ## from UnitPath).
  NdeH1SessionServicePath* = "usr/lib/systemd/system/sway-session.service"

  ## XDG session entry path. Display managers (gdm, sddm) scan
  ## ``/etc/wayland-sessions/`` for ``*.desktop`` entries to populate
  ## the session-picker dropdown.
  NdeH1SessionDesktopPath* = "etc/wayland-sessions/sway.desktop"

  ## Sway's main config file path. Spec literal — sway looks here
  ## first, then ``$HOME/.config/sway/config``, then
  ## ``/etc/sway/config.d/*``.
  NdeH1SwayConfigPath* = "etc/sway/config"

  ## The libpaths host file path the managedBlock contribution lands
  ## under (shared with NDE0-G's contribution; the multi-contributor
  ## merge at NDEM1 unions them).
  NdeH1LdConfPath* = "etc/ld.so.conf.d/00-reproos-linux.conf"

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
  SwayConfig* = object
    ## NDE-H1 configurables per the spec example. Defaults match the
    ## spec'd values (Super_L modifier, foot terminal, wofi launcher,
    ## empty modeline list, jammy snapshot pin).
    aptSnapshot*: string

    ## Modifier key bound to ``$mod`` in sway's config. Default
    ## ``"Super_L"`` (the left Super/Win key) per spec. Alternatives:
    ## ``"Mod1"`` (Alt), ``"Mod4"`` (right Super on some kbd layouts).
    superKey*: string

    ## Terminal launched by ``$mod+Return``. Default ``"foot"``
    ## (Wayland-native, minimal). The spec's acceptance toggles this
    ## from ``"foot"`` to ``"alacritty"`` to demonstrate the cache-key
    ## propagation contract.
    terminalApp*: string

    ## Application launcher launched by ``$mod+d``. Default ``"wofi"``
    ## (the canonical wlroots-DE menu).
    launcherApp*: string

    ## Optional ``output`` configurations (one entry per output line).
    ## Each entry is a sway ``output`` argument (e.g.
    ## ``"HDMI-A-1 resolution 1920x1080 position 0,0"``); the rendered
    ## config prefixes ``output `` to each entry. Default = empty
    ## (sway auto-configures every connected output).
    ##
    ## **Determinism note**: order matters in sway (the first matching
    ## output config wins). v1 preserves insertion order — the cache
    ## key includes the joined modeline lines so re-ordering changes
    ## the fingerprint deterministically.
    extraModelines*: seq[string]

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  SwayOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent.
    ##
    ## **Invalidation matrix** (load-bearing for NDE-H1 acceptance):
    ##
    ##   * Toggling ``superKey`` / ``terminalApp`` / ``launcherApp`` /
    ##     ``extraModelines`` → re-emits ``swayConfig`` only; leaves
    ##     ``ldConfBlock`` + ``sessionService`` + ``sessionDesktopEntry``
    ##     cached.
    ##   * Toggling ``aptSnapshot`` → re-emits ``ldConfBlock`` only
    ##     (the bundle stub hashes embed the snapshot); leaves
    ##     ``swayConfig`` + ``sessionService`` + ``sessionDesktopEntry``
    ##     cached.
    swayConfig*:           ManagedFiles
    ldConfBlock*:          ManagedFiles
    sessionService*:       ManagedFiles
    sessionDesktopEntry*:  ManagedFiles

proc defaultConfig*(): SwayConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation. Spec literal values:
  ## superKey=Super_L, terminalApp=foot, launcherApp=wofi,
  ## extraModelines=@[], aptSnapshot=jammy/20260615.
  result = SwayConfig(
    aptSnapshot:    "ubuntu/jammy/20260615T000000Z",
    superKey:       "Super_L",
    terminalApp:    "foot",
    launcherApp:    "wofi",
    extraModelines: @[],
    storeRoot:      systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Bundle stub hashes for the ld.so.conf.d block (v1 deferral).
#
# Same shape as NDE0-G's bundleStubHash: 16-char hex pure-function of
# (snapshot, bundle-name) so toggling the snapshot or extending the
# bundle list invalidates the block content (and therefore its
# content-addressed store path).
# ---------------------------------------------------------------------------

const
  ## The 2 jammy bundle pins NDE-H1 contributes to /etc/ld.so.conf.d/.
  ## v1 lists wlroots (the compositor library) + sway (the binary +
  ## helper utilities). When the .deb extraction lands, these bundle
  ## names map to real package sets — see
  ## ``recipes/catalog/linux/wlroots.json`` + ``sway.json`` for the
  ## planned shapes (catalogs not vendored yet; this is a forward-
  ## compatible stub).
  NdeH1Bundles* = [
    ("wlroots", @["libwlroots10"]),
    ("sway",    @["sway", "sway-backgrounds"])]

proc bundleStubHash*(snapshot, bundleName: string): string =
  ## 16-char hex stub mirroring NDE0-G's ``bundleStubHash`` shape:
  ## ``sha256(prefix + version + snapshot + bundleName)[0..15]``.
  let composed = "swayBundleStub" & NdeH1Version & snapshot & bundleName
  result = sha256OfString(composed)[0 ..< 16]

# ---------------------------------------------------------------------------
# Render the /etc/sway/config content.
# ---------------------------------------------------------------------------

proc renderSwayConfig*(cfg: SwayConfig): string =
  ## Emit sway's native config-file syntax with the configurable-
  ## bound bindsym + exec-once lines + optional output configurations.
  ##
  ## **Determinism**: the bindsym lines are emitted in a fixed,
  ## hand-authored order (``$mod`` set → ``Return`` → ``d`` →
  ## ``Shift+q`` → ``Shift+e``). The ``extraModelines`` are emitted
  ## in insertion-order (load-bearing for sway — the first matching
  ## ``output`` config wins, so user-supplied order is semantic).
  ##
  ## A trailing newline is guaranteed for POSIX-clean shell behaviour.
  result = "# /etc/sway/config — generated by NDE-H1 native sway package.\n"
  result.add("# WARNING: regenerated on every system rebuild; manual edits will be lost.\n")
  result.add("# Source: " & NdeH1PackageName & " v" & NdeH1Version & "\n")
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("\n")
  result.add("set $mod " & cfg.superKey & "\n")
  result.add("\n")
  result.add("# Keybindings (foundation set; user override goes in\n")
  result.add("# $HOME/.config/sway/config.d/).\n")
  result.add("bindsym $mod+Return exec " & cfg.terminalApp & "\n")
  result.add("bindsym $mod+d exec " & cfg.launcherApp & "\n")
  result.add("bindsym $mod+Shift+q exit\n")
  result.add("bindsym $mod+Shift+e exec swaymsg exit\n")
  if cfg.extraModelines.len > 0:
    result.add("\n")
    result.add("# Output configurations (insertion-order preserved; sway honours\n")
    result.add("# first-match-wins semantics).\n")
    for modeline in cfg.extraModelines:
      result.add("output " & modeline & "\n")

# ---------------------------------------------------------------------------
# Render the ld.so.conf.d managed-block content (NDE-H1 contribution).
# ---------------------------------------------------------------------------

proc renderLdConfBlockContent*(cfg: SwayConfig): string =
  ## The block content between the NDE-spec-block sentinels. Lists the
  ## per-bundle store paths' ``usr/lib/x86_64-linux-gnu`` directories
  ## in deterministic order (bundles enumerated in the canonical order
  ## ``NdeH1Bundles``), preceded by a banner that records the resolved
  ## snapshot pin. The banner is what makes ``aptSnapshot`` propagate
  ## to the block content per the configurable-binding contract.
  result = "# NDE-H1: " & NdeH1PackageName & " libpaths contribution.\n"
  result.add("# apt-jammy snapshot: " & cfg.aptSnapshot & "\n")
  result.add("#\n")
  result.add("# Store lib dirs (one per bundle; activation step unions\n")
  result.add("# co-contributors per NDE-spec-block multi-contributor rules):\n")
  for bundle in NdeH1Bundles:
    let (bundleName, _) = bundle
    let h = bundleStubHash(cfg.aptSnapshot, bundleName)
    result.add("/opt/reproos-linux/store/" & h &
               "/usr/lib/x86_64-linux-gnu  # " & bundleName & "\n")

# ---------------------------------------------------------------------------
# Render the systemd user-session unit + the XDG session entry.
# ---------------------------------------------------------------------------

proc renderSessionService*(): string =
  ## ``sway-session.service`` content. Type=oneshot per spec:
  ##
  ##   - Type=oneshot — the session is "complete" when sway exits;
  ##     systemd records active(exited) for status visibility.
  ##   - ExecStart=/usr/bin/sway — launches the compositor binary.
  ##   - PartOf=graphical-session.target — NDE0-S supplies the user-
  ##     instance graphical-session.target anchor; this unit hooks
  ##     against it.
  ##   - WantedBy=graphical-session.target — the activation layer
  ##     plants the .wants symlink so a graphical login triggers the
  ##     compositor.
  result = "# NDE-H1: sway user-session unit.\n" &
           "[Unit]\n" &
           "Description=Sway wlroots-tiling Wayland compositor session\n" &
           "Documentation=man:sway(5)\n" &
           "PartOf=graphical-session.target\n" &
           "After=graphical-session-pre.target\n" &
           "\n" &
           "[Service]\n" &
           "Type=oneshot\n" &
           "ExecStart=/usr/bin/sway\n" &
           "RemainAfterExit=yes\n" &
           "\n" &
           "[Install]\n" &
           "WantedBy=graphical-session.target\n"

proc renderSessionDesktopEntry*(): string =
  ## ``/etc/wayland-sessions/sway.desktop`` content. XDG Desktop Entry
  ## Specification shape; display managers (gdm, sddm) read this
  ## directory to populate the session picker.
  result = "[Desktop Entry]\n" &
           "Name=Sway\n" &
           "Comment=An i3-compatible Wayland compositor\n" &
           "Exec=sway\n" &
           "Type=Application\n"

# ---------------------------------------------------------------------------
# Public materializer — emit every NDE-H1 output.
# ---------------------------------------------------------------------------

proc materializeSway*(cfg: SwayConfig): SwayOutputs =
  ## Emit every NDE-H1 output. Each helper invocation is independent
  ## so the cache keys are per-output — see the docstring for
  ## ``SwayOutputs`` for the full invalidation matrix.
  ##
  ## NB: ``sway-session.service`` is planted at
  ## ``usr/lib/systemd/system/`` (the cascade-G fix); it is NOT
  ## planted at ``lib/systemd/system/``. R9 systemd 257.9's default
  ## UnitPath dropped the legacy /lib/systemd/system entry, so
  ## anything planted there would be invisible at boot.

  result.swayConfig = configFile(
    path = NdeH1SwayConfigPath,
    content = renderSwayConfig(cfg),
    storeRoot = cfg.storeRoot)

  result.ldConfBlock = managedBlock(
    path = NdeH1LdConfPath,
    scope = bsSystem,
    packageName = NdeH1PackageName,
    blockId = NdeH1LibpathsBlockId,
    content = renderLdConfBlockContent(cfg),
    priority = NdeH1LibpathsPriority,   # compositor sort key (=500)
    storeRoot = cfg.storeRoot)

  result.sessionService = configFile(
    path = NdeH1SessionServicePath,
    content = renderSessionService(),
    storeRoot = cfg.storeRoot)

  result.sessionDesktopEntry = configFile(
    path = NdeH1SessionDesktopPath,
    content = renderSessionDesktopEntry(),
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: SwayOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the spec'd activation order: swayConfig first (the user-
  ## facing keybind surface), then ldConfBlock (the link-path
  ## contribution the ldconfig oneshot reads), then sessionService
  ## (the systemd unit the user-session target activates), then
  ## sessionDesktopEntry (the display-manager session-picker entry).
  result = @[
    outs.swayConfig.storePath,
    outs.ldConfBlock.storePath,
    outs.sessionService.storePath,
    outs.sessionDesktopEntry.storePath]

proc sortedStorePaths*(outs: SwayOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])

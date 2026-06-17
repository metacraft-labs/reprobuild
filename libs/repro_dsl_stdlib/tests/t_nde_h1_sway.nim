## NDE-H1 unit tests: native sway compositor package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
## desktop_environments/sway.nim`` against synthetic configurations.
## Mirrors the NDE0-K + NDE0-G + NDE0-D + NDE0-S test layout
## (per-output ``ManagedFiles`` round-trip + per-configurable
## propagation + cache-key isolation + cascade-G discipline assertions
## in BOTH directions + byte-determinism).
##
## Required test surfaces (per the NDE-H1 sub-agent prompt §"Unit
## tests"):
##
##   1. **Configurable propagation: superKey** — change from
##      ``"Super_L"`` to ``"Mod1"``; assert sway config content has
##      ``set $mod Mod1``, not ``Super_L``; assert store paths differ.
##   2. **Configurable propagation: terminalApp** — change from
##      ``"foot"`` to ``"alacritty"``; assert ``bindsym
##      $mod+Return exec alacritty`` appears + ``exec foot`` does NOT;
##      assert store paths differ.
##   3. **Configurable propagation: launcherApp** — change from
##      ``"wofi"`` to ``"bemenu"``; same propagation contract as
##      terminalApp.
##   4. **extraModelines insertion** — add a modeline; verify it
##      appears in output prefixed by ``output ``.
##   5. **NDE-spec-block sentinel triple-form** for ldConfBlock:
##      ``# >>> repro:system:sway:libpaths >>>`` open +
##      ``# <<< repro:system:sway:libpaths <<<`` close. Sentinels
##      match the spec.
##   6. **Cascade-G unit path** — ``sway-session.service`` planted at
##      ``usr/lib/systemd/system/``, NOT ``lib/systemd/system/``.
##      Both directions.
##   7. **XDG session entry shape** —
##      ``/etc/wayland-sessions/sway.desktop`` has ``Name=Sway``,
##      ``Exec=sway``, ``Type=Application``.
##   8. **Idempotency** — same config produces same store paths.
##   9. **Cache-key invalidation: superKey change invalidates
##      swayConfig only**; ldConfBlock + sessionService +
##      sessionDesktopEntry stay cached.
##   10. **Byte-determinism** across two independent materialize roots.
##   11. **Priority=500 encoded in managedBlock hash** — toggling
##       priority changes the block hash; the planted block's hashHex
##       matches managedBlockHash computed at priority=500.
##   12. **Cache-key isolation + 16-char hex per output** + stable
##       activation order. Per-output regression guards.
##
## No try/except swallows. Failure paths use ``expect`` where
## applicable; this module's primitives are infallible by design
## (mirror of NDE0-K/G/S), so most assertions use ``check``.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/desktop_environments/sway
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # for managedBlockHash + ManagedFiles + bsSystem (priority test)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the NDE0-K/G helper
  ## exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): SwayConfig =
  result = defaultConfig()
  result.storeRoot = storeRoot

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE-H1 sway compositor package":

  test "configurable propagation: superKey change invalidates swayConfig + propagates to content":
    # Toggle superKey from "Super_L" (default) to "Mod1" (Alt). The
    # rendered config-text must swap the ``set $mod`` line value AND
    # the content-addressed swayConfig storePath must differ.
    let rootBase = createTempDir("ndeh1_super_base_", "")
    let rootMut = createTempDir("ndeh1_super_mut_", "")
    defer:
      removeDir(rootBase)
      removeDir(rootMut)

    var cfgBase = configWithRoot(rootBase)
    let outsBase = materializeSway(cfgBase)
    let baseBytes = readStoreFile(outsBase.swayConfig)

    var cfgMut = configWithRoot(rootMut)
    cfgMut.superKey = "Mod1"
    let outsMut = materializeSway(cfgMut)
    let mutBytes = readStoreFile(outsMut.swayConfig)

    # Baseline has Super_L; mutated has Mod1.
    check "set $mod Super_L" in baseBytes
    check "set $mod Mod1" notin baseBytes
    check "set $mod Mod1" in mutBytes
    check "set $mod Super_L" notin mutBytes

    # Content differs + store path differs (cache-key propagation).
    check baseBytes != mutBytes
    check outsBase.swayConfig.storePath != outsMut.swayConfig.storePath

  test "configurable propagation: terminalApp change (spec'd acceptance #1)":
    # The spec NDE-H1 acceptance literal: "User changing
    # config.terminalApp from foot to alacritty rebuilds only
    # /etc/sway/config + the alacritty package; rest of the closure
    # stays cached."
    let rootFoot = createTempDir("ndeh1_term_foot_", "")
    let rootAla = createTempDir("ndeh1_term_ala_", "")
    defer:
      removeDir(rootFoot)
      removeDir(rootAla)

    var cfgFoot = configWithRoot(rootFoot)
    cfgFoot.terminalApp = "foot"
    let outsFoot = materializeSway(cfgFoot)
    let footBytes = readStoreFile(outsFoot.swayConfig)

    var cfgAla = configWithRoot(rootAla)
    cfgAla.terminalApp = "alacritty"
    let outsAla = materializeSway(cfgAla)
    let alaBytes = readStoreFile(outsAla.swayConfig)

    # The bindsym $mod+Return exec <terminalApp> line swaps.
    check "bindsym $mod+Return exec foot" in footBytes
    check "bindsym $mod+Return exec alacritty" notin footBytes
    check "bindsym $mod+Return exec alacritty" in alaBytes
    check "bindsym $mod+Return exec foot" notin alaBytes

    # Content differs + store path differs.
    check footBytes != alaBytes
    check outsFoot.swayConfig.storePath != outsAla.swayConfig.storePath

  test "configurable propagation: launcherApp change":
    # Same shape as terminalApp: swap "wofi" → "bemenu" + assert the
    # $mod+d bindsym line changes + the storePath re-keys.
    let rootWofi = createTempDir("ndeh1_launch_wofi_", "")
    let rootBemu = createTempDir("ndeh1_launch_bemu_", "")
    defer:
      removeDir(rootWofi)
      removeDir(rootBemu)

    var cfgWofi = configWithRoot(rootWofi)
    cfgWofi.launcherApp = "wofi"
    let outsWofi = materializeSway(cfgWofi)
    let wofiBytes = readStoreFile(outsWofi.swayConfig)

    var cfgBemu = configWithRoot(rootBemu)
    cfgBemu.launcherApp = "bemenu"
    let outsBemu = materializeSway(cfgBemu)
    let bemuBytes = readStoreFile(outsBemu.swayConfig)

    check "bindsym $mod+d exec wofi" in wofiBytes
    check "bindsym $mod+d exec bemenu" notin wofiBytes
    check "bindsym $mod+d exec bemenu" in bemuBytes
    check "bindsym $mod+d exec wofi" notin bemuBytes

    check wofiBytes != bemuBytes
    check outsWofi.swayConfig.storePath != outsBemu.swayConfig.storePath

  test "extraModelines insertion: appears in rendered output prefixed with 'output '":
    # Default extraModelines = @[]; extend with a single modeline and
    # verify (a) the rendered config contains "output <modeline>",
    # (b) the storePath differs from the baseline, (c) order is
    # preserved across multiple entries (sway's first-match-wins
    # discipline).
    let rootEmpty = createTempDir("ndeh1_mode_empty_", "")
    let rootOne = createTempDir("ndeh1_mode_one_", "")
    let rootTwo = createTempDir("ndeh1_mode_two_", "")
    defer:
      removeDir(rootEmpty)
      removeDir(rootOne)
      removeDir(rootTwo)

    var cfgEmpty = configWithRoot(rootEmpty)
    let outsEmpty = materializeSway(cfgEmpty)
    let emptyBytes = readStoreFile(outsEmpty.swayConfig)
    # Empty case: the "Output configurations" comment block must NOT
    # appear when there are zero modelines.
    check "Output configurations" notin emptyBytes
    check "output " notin emptyBytes

    var cfgOne = configWithRoot(rootOne)
    cfgOne.extraModelines = @["HDMI-A-1 resolution 1920x1080 position 0,0"]
    let outsOne = materializeSway(cfgOne)
    let oneBytes = readStoreFile(outsOne.swayConfig)
    check "output HDMI-A-1 resolution 1920x1080 position 0,0" in oneBytes

    # Two modelines: insertion order preserved (HDMI-A-1 first, DP-1
    # second per insertion order — load-bearing for sway's
    # first-match-wins semantics).
    var cfgTwo = configWithRoot(rootTwo)
    cfgTwo.extraModelines = @[
      "HDMI-A-1 resolution 1920x1080 position 0,0",
      "DP-1 resolution 2560x1440 position 1920,0"]
    let outsTwo = materializeSway(cfgTwo)
    let twoBytes = readStoreFile(outsTwo.swayConfig)
    check "output HDMI-A-1 resolution 1920x1080" in twoBytes
    check "output DP-1 resolution 2560x1440" in twoBytes
    let hdmiIdx = twoBytes.find("output HDMI-A-1")
    let dpIdx = twoBytes.find("output DP-1")
    check hdmiIdx >= 0
    check dpIdx >= 0
    check hdmiIdx < dpIdx   # insertion-order preserved

    # Cache-key propagation: all three configs land at different paths.
    check outsEmpty.swayConfig.storePath != outsOne.swayConfig.storePath
    check outsOne.swayConfig.storePath  != outsTwo.swayConfig.storePath
    check outsEmpty.swayConfig.storePath != outsTwo.swayConfig.storePath

  test "sentinel triple-form: libpaths block uses NDE-spec-block shape with packageName=sway":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = sway, blockId = libpaths.
    # Critically: packageName MUST be "sway" — NOT "hyprland", NOT
    # "sway-as-hyprland" (the naming decision in the impl-module +
    # recipe preamble).
    let root = createTempDir("ndeh1_sentinel_", "")
    defer: removeDir(root)

    let outs = materializeSway(configWithRoot(root))
    let bytes = readStoreFile(outs.ldConfBlock)

    let expectOpen = "# >>> repro:system:sway:libpaths >>>"
    let expectClose = "# <<< repro:system:sway:libpaths <<<"

    check expectOpen in bytes
    check expectClose in bytes
    # Open MUST come before close.
    check bytes.find(expectOpen) < bytes.find(expectClose)

    # The naming-decision regression guard: the sentinel MUST NOT
    # reference "hyprland" (Tier-2 surrogate name) or
    # "sway-as-hyprland" (Tier-2 advisory note).
    check "repro:system:hyprland:" notin bytes
    check "repro:system:sway-as-hyprland:" notin bytes

    # And the content between the sentinels must have at least one
    # store-path lib dir.
    let openIdx = bytes.find(expectOpen)
    let closeIdx = bytes.find(expectClose)
    let between = bytes[openIdx + expectOpen.len ..< closeIdx]
    var libDirCount = 0
    for line in between.splitLines:
      if line.startsWith("/opt/reproos-linux/store/") and
         "/usr/lib/x86_64-linux-gnu" in line:
        libDirCount.inc
    check libDirCount >= 1

  test "cascade-G fix: sway-session.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # The load-bearing cascade-G assertion BOTH directions: AT
    # /usr/lib/systemd/system/, NOT AT /lib/systemd/system/. R9
    # systemd 257.9 dropped /lib/systemd/system/ from the default
    # UnitPath, so a unit planted only under /lib/ would be invisible
    # at boot. The native package must plant at /usr/lib/.
    let root = createTempDir("ndeh1_unit_path_", "")
    defer: removeDir(root)

    let outs = materializeSway(configWithRoot(root))

    # AT: usr/lib/systemd/system/
    check outs.sessionService.relPath ==
          "usr/lib/systemd/system/sway-session.service"
    check fileExists(outs.sessionService.storePath /
                     "usr/lib/systemd/system/sway-session.service")
    # NOT-AT: lib/systemd/system/
    check not fileExists(outs.sessionService.storePath /
                         "lib/systemd/system/sway-session.service")

    # And the unit content shape: Type=oneshot + ExecStart=/usr/bin/sway
    # + the [Unit]/[Service]/[Install] sections per spec.
    let bytes = readStoreFile(outs.sessionService)
    check "Type=oneshot" in bytes
    check "ExecStart=/usr/bin/sway" in bytes
    check "[Unit]" in bytes
    check "[Service]" in bytes
    check "[Install]" in bytes
    check "WantedBy=graphical-session.target" in bytes

  test "XDG session entry: /etc/wayland-sessions/sway.desktop has Name=Sway + Exec=sway + Type=Application":
    # Display managers (gdm, sddm) read this directory to populate the
    # session-picker dropdown. The .desktop entry shape per XDG Desktop
    # Entry Specification.
    let root = createTempDir("ndeh1_xdg_", "")
    defer: removeDir(root)

    let outs = materializeSway(configWithRoot(root))

    # Path is etc/wayland-sessions/sway.desktop (the cascade-G
    # discipline applies only to /usr/lib/systemd/; this is /etc/).
    check outs.sessionDesktopEntry.relPath == "etc/wayland-sessions/sway.desktop"

    let bytes = readStoreFile(outs.sessionDesktopEntry)
    check "[Desktop Entry]" in bytes
    check "Name=Sway" in bytes
    check "Exec=sway" in bytes
    check "Type=Application" in bytes
    # Honest naming: comment line records the "i3-compatible" identity.
    check "i3-compatible" in bytes

  test "idempotency: same config produces same store paths":
    let root = createTempDir("ndeh1_idem_", "")
    defer: removeDir(root)

    let outsA = materializeSway(configWithRoot(root))
    let outsB = materializeSway(configWithRoot(root))

    check outsA.swayConfig.storePath          == outsB.swayConfig.storePath
    check outsA.ldConfBlock.storePath         == outsB.ldConfBlock.storePath
    check outsA.sessionService.storePath      == outsB.sessionService.storePath
    check outsA.sessionDesktopEntry.storePath == outsB.sessionDesktopEntry.storePath

  test "cache-key invalidation: superKey change re-keys swayConfig only":
    # The spec's contract at the package-output granularity: a
    # /etc/sway/config configurable change (e.g. superKey, terminalApp,
    # launcherApp, extraModelines) re-keys ONLY the swayConfig output;
    # the ldConfBlock + sessionService + sessionDesktopEntry stay
    # cached because their inputs don't depend on those configurables.
    let root = createTempDir("ndeh1_invsuper_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.superKey = "Super_L"
    let outsA = materializeSway(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.superKey = "Mod4"
    let outsB = materializeSway(cfgB)

    # swayConfig MUST land at a different store path (superKey is
    # bound into the rendered config content).
    check outsA.swayConfig.storePath != outsB.swayConfig.storePath
    # All three other outputs MUST stay at the same store path
    # (their inputs don't reference superKey).
    check outsA.ldConfBlock.storePath         == outsB.ldConfBlock.storePath
    check outsA.sessionService.storePath      == outsB.sessionService.storePath
    check outsA.sessionDesktopEntry.storePath == outsB.sessionDesktopEntry.storePath

  test "determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirrors NDE0-K/G's determinism tests.
    let rootA = createTempDir("ndeh1_detA_", "")
    let rootB = createTempDir("ndeh1_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializeSway(configWithRoot(rootA))
    let outsB = materializeSway(configWithRoot(rootB))

    # Hash-segment basenames match.
    check extractFilename(outsA.swayConfig.storePath) ==
          extractFilename(outsB.swayConfig.storePath)
    check extractFilename(outsA.ldConfBlock.storePath) ==
          extractFilename(outsB.ldConfBlock.storePath)
    check extractFilename(outsA.sessionService.storePath) ==
          extractFilename(outsB.sessionService.storePath)
    check extractFilename(outsA.sessionDesktopEntry.storePath) ==
          extractFilename(outsB.sessionDesktopEntry.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.swayConfig)          ==
          readStoreFile(outsB.swayConfig)
    check readStoreFile(outsA.ldConfBlock)         ==
          readStoreFile(outsB.ldConfBlock)
    check readStoreFile(outsA.sessionService)      ==
          readStoreFile(outsB.sessionService)
    check readStoreFile(outsA.sessionDesktopEntry) ==
          readStoreFile(outsB.sessionDesktopEntry)

  test "priority=500 encoded in libpaths block cache key":
    # Per Generated-Configuration-Files.md §"Cache-key composition"
    # the managedBlock hash includes the priority value. The impl
    # module's ``NdeH1LibpathsPriority`` constant is the load-bearing
    # priority for compositors (spec worked example: "the three
    # priority-500 compositors then sort by package name"). Test
    # asserts (a) the constant value (b) the cache-key consequence:
    # re-hashing the same content + scope + packageName + blockId +
    # relPath with a different priority produces a different hash.
    check NdeH1LibpathsPriority == 500

    # Same content/scope/packageName/blockId/relPath; different
    # priority. Use the impl module's exposed hash helper.
    const path = "etc/ld.so.conf.d/00-reproos-linux.conf"
    let content = "test-content\n"
    let h500 = managedBlockHash(bsSystem, NdeH1PackageName,
                                NdeH1LibpathsBlockId, path, content, 500)
    let h100 = managedBlockHash(bsSystem, NdeH1PackageName,
                                NdeH1LibpathsBlockId, path, content, 100)
    check h500 != h100
    check h500.len == 16
    check h100.len == 16

    # And the planted block's hashHex (which derives from
    # priority=500 via the impl module's contract) matches the h500
    # computed against the rendered content.
    let root = createTempDir("ndeh1_prio_", "")
    defer: removeDir(root)

    let cfg = configWithRoot(root)
    let outs = materializeSway(cfg)
    let renderedContent = renderLdConfBlockContent(cfg)
    let expected = managedBlockHash(bsSystem, NdeH1PackageName,
                                    NdeH1LibpathsBlockId, path,
                                    renderedContent,
                                    NdeH1LibpathsPriority)
    check outs.ldConfBlock.hashHex == expected

  test "cache-key isolation: per-output hashes are distinct + 16 chars":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. Mirrors NDE0-K/G's
    # isolation test.
    let root = createTempDir("ndeh1_iso_", "")
    defer: removeDir(root)

    let outs = materializeSway(configWithRoot(root))

    check outs.swayConfig.hashHex          != outs.ldConfBlock.hashHex
    check outs.swayConfig.hashHex          != outs.sessionService.hashHex
    check outs.swayConfig.hashHex          != outs.sessionDesktopEntry.hashHex
    check outs.ldConfBlock.hashHex         != outs.sessionService.hashHex
    check outs.ldConfBlock.hashHex         != outs.sessionDesktopEntry.hashHex
    check outs.sessionService.hashHex      != outs.sessionDesktopEntry.hashHex

    # All hash-hex segments are exactly 16 chars (mirrors NDE0-A/S/D/G/K).
    check outs.swayConfig.hashHex.len          == 16
    check outs.ldConfBlock.hashHex.len         == 16
    check outs.sessionService.hashHex.len      == 16
    check outs.sessionDesktopEntry.hashHex.len == 16

  test "stable activation order: storePaths enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # swayConfig first (the user-facing keybind surface), then
    # ldConfBlock (the link-path contribution the ldconfig oneshot
    # reads), then sessionService (the systemd unit), then
    # sessionDesktopEntry (the display-manager session-picker entry).
    let root = createTempDir("ndeh1_order_", "")
    defer: removeDir(root)

    let outs = materializeSway(configWithRoot(root))
    let paths = storePaths(outs)

    check paths.len == 4
    check paths[0] == outs.swayConfig.storePath
    check paths[1] == outs.ldConfBlock.storePath
    check paths[2] == outs.sessionService.storePath
    check paths[3] == outs.sessionDesktopEntry.storePath

## NDE-K1 unit tests: native KDE Plasma compositor package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
## desktop_environments/plasma.nim`` against synthetic configurations.
## Mirrors the NDE-G1 (gnome) + NDE-H1 (sway) + NDE0-K + NDE0-G +
## NDE0-D + NDE0-S test layout (per-output ``ManagedFiles`` round-trip
## + per-configurable propagation + cache-key isolation + cascade-G
## discipline assertions in BOTH directions + byte-determinism).
##
## Required test surfaces (per the NDE-K1 sub-agent prompt §"Unit
## tests"):
##
##   1. **Configurable propagation: sddmAutoLogin** — change ``true``
##      → ``false``; content + paths differ.
##   2. **Configurable propagation: sddmAutoLoginUser** — change
##      ``"repro"`` → ``"alice"``; assert ``User=alice``.
##   3. **Configurable propagation: waylandSession** — change ``true``
##      → ``false``; assert ``DisplayServer=x11`` analog.
##   4. **Configurable propagation: pipewireEnabled** — toggle; the
##      pipewireConfig content reflects state.
##   5. **NDE-spec-block sentinel triple-form** for libpaths:
##      ``# >>> repro:system:plasma:libpaths >>>`` open +
##      ``# <<< repro:system:plasma:libpaths <<<`` close. Sentinel
##      does NOT contain ``sway`` / ``gnome`` / ``hyprland`` (regression
##      guards).
##   6. **Cascade-G unit path** — ``sddm.service`` planted at
##      ``usr/lib/systemd/system/``, NOT ``lib/systemd/system/``.
##      Both directions.
##   7. **sddm.service content shape** — Type=simple,
##      ExecStart=/usr/bin/sddm, WantedBy=graphical.target,
##      Requires=dbus.service.
##   8. **XDG session entry** — Name="Plasma (Wayland)",
##      Exec=/usr/bin/startplasma-wayland, Type=Application,
##      DesktopNames=KDE.
##   9. **Idempotency** — same config produces same store paths.
##   10. **Cache-key invalidation** — sddmAutoLoginUser change re-keys
##       sddmConfig only.
##   11. **Byte-determinism** across two independent materialize roots.
##   12. **Priority=500 encoded in libpaths block cache key**.
##   13. **Hash isolation + 16-char hex** for all 5 outputs.
##   14. **storePaths order** — five-element enumeration in the
##       documented activation order.
##
## No try/except swallows. Failure paths use ``expect`` where
## applicable; this module's primitives are infallible by design
## (mirror of NDE-H1 / NDE-G1 / NDE0-K/G/S), so most assertions use
## ``check``.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/desktop_environments/plasma
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # for managedBlockHash + ManagedFiles + bsSystem (priority test)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the NDE0-K/G/H1/G1
  ## helper exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): PlasmaConfig =
  result = defaultConfig()
  result.storeRoot = storeRoot

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE-K1 KDE Plasma compositor package":

  test "configurable propagation: sddmAutoLogin change re-keys sddmConfig (spec'd acceptance)":
    # Spec NDE-K1 acceptance literal: "Toggle sddmAutoLogin = false →
    # only /etc/sddm.conf rebuilds". The rendered INI must swap the
    # [Autologin] User= value (populated → blank) AND the content-
    # addressed sddmConfig storePath must differ.
    let rootOn = createTempDir("ndek1_alogin_on_", "")
    let rootOff = createTempDir("ndek1_alogin_off_", "")
    defer:
      removeDir(rootOn)
      removeDir(rootOff)

    var cfgOn = configWithRoot(rootOn)
    cfgOn.sddmAutoLogin = true
    let outsOn = materializePlasma(cfgOn)
    let onBytes = readStoreFile(outsOn.sddmConfig)

    var cfgOff = configWithRoot(rootOff)
    cfgOff.sddmAutoLogin = false
    let outsOff = materializePlasma(cfgOff)
    let offBytes = readStoreFile(outsOff.sddmConfig)

    # Baseline (autoLogin=true, default user "repro"): User=repro.
    # Mutated (autoLogin=false): User= (blank).
    check "User=repro" in onBytes
    check "User=\n" in offBytes
    check "User=repro" notin offBytes

    # Content differs + store path differs (cache-key propagation).
    check onBytes != offBytes
    check outsOn.sddmConfig.storePath != outsOff.sddmConfig.storePath

  test "configurable propagation: sddmAutoLoginUser change re-keys sddmConfig":
    # Swap sddmAutoLoginUser repro → alice; assert User=<user> line
    # changes + the storePath re-keys.
    let rootRepro = createTempDir("ndek1_user_repro_", "")
    let rootAlice = createTempDir("ndek1_user_alice_", "")
    defer:
      removeDir(rootRepro)
      removeDir(rootAlice)

    var cfgRepro = configWithRoot(rootRepro)
    cfgRepro.sddmAutoLoginUser = "repro"
    let outsRepro = materializePlasma(cfgRepro)
    let reproBytes = readStoreFile(outsRepro.sddmConfig)

    var cfgAlice = configWithRoot(rootAlice)
    cfgAlice.sddmAutoLoginUser = "alice"
    let outsAlice = materializePlasma(cfgAlice)
    let aliceBytes = readStoreFile(outsAlice.sddmConfig)

    check "User=repro" in reproBytes
    check "User=alice" notin reproBytes
    check "User=alice" in aliceBytes
    check "User=repro" notin aliceBytes

    check reproBytes != aliceBytes
    check outsRepro.sddmConfig.storePath != outsAlice.sddmConfig.storePath

  test "configurable propagation: waylandSession change re-keys sddmConfig":
    # Swap waylandSession true → false; assert
    # [General] DisplayServer= line swaps wayland → x11 + the
    # storePath re-keys.
    let rootWl = createTempDir("ndek1_wl_on_", "")
    let rootXorg = createTempDir("ndek1_wl_off_", "")
    defer:
      removeDir(rootWl)
      removeDir(rootXorg)

    var cfgWl = configWithRoot(rootWl)
    cfgWl.waylandSession = true
    let outsWl = materializePlasma(cfgWl)
    let wlBytes = readStoreFile(outsWl.sddmConfig)

    var cfgXorg = configWithRoot(rootXorg)
    cfgXorg.waylandSession = false
    let outsXorg = materializePlasma(cfgXorg)
    let xorgBytes = readStoreFile(outsXorg.sddmConfig)

    check "DisplayServer=wayland" in wlBytes
    check "DisplayServer=x11" notin wlBytes
    check "DisplayServer=x11" in xorgBytes
    check "DisplayServer=wayland" notin xorgBytes

    check wlBytes != xorgBytes
    check outsWl.sddmConfig.storePath != outsXorg.sddmConfig.storePath

  test "configurable propagation: pipewireEnabled toggle re-keys pipewireConfig":
    # Swap pipewireEnabled true → false; assert pipewireConfig
    # content reflects the state (ENABLED banner + context.properties
    # block vs DISABLED marker + pipewire.enabled = false).
    let rootEn = createTempDir("ndek1_pw_en_", "")
    let rootDis = createTempDir("ndek1_pw_dis_", "")
    defer:
      removeDir(rootEn)
      removeDir(rootDis)

    var cfgEn = configWithRoot(rootEn)
    cfgEn.pipewireEnabled = true
    let outsEn = materializePlasma(cfgEn)
    let enBytes = readStoreFile(outsEn.pipewireConfig)

    var cfgDis = configWithRoot(rootDis)
    cfgDis.pipewireEnabled = false
    let outsDis = materializePlasma(cfgDis)
    let disBytes = readStoreFile(outsDis.pipewireConfig)

    # Enabled branch: ENABLED banner + the context.properties block.
    check "PipeWire daemon: ENABLED" in enBytes
    check "context.properties" in enBytes
    check "PipeWire daemon: DISABLED" notin enBytes
    check "pipewire.enabled = false" notin enBytes

    # Disabled branch: DISABLED banner + the explicit
    # pipewire.enabled = false marker.
    check "PipeWire daemon: DISABLED" in disBytes
    check "pipewire.enabled = false" in disBytes
    check "PipeWire daemon: ENABLED" notin disBytes
    check "context.properties" notin disBytes

    check enBytes != disBytes
    check outsEn.pipewireConfig.storePath != outsDis.pipewireConfig.storePath

  test "sentinel triple-form: libpaths block uses NDE-spec-block shape with packageName=plasma":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = plasma, blockId = libpaths.
    # Critically: packageName MUST be "plasma" — NOT "sway", NOT
    # "gnome", NOT "hyprland" (regression guards against cross-DE
    # sentinel collisions).
    let root = createTempDir("ndek1_sentinel_", "")
    defer: removeDir(root)

    let outs = materializePlasma(configWithRoot(root))
    let bytes = readStoreFile(outs.ldConfBlock)

    let expectOpen = "# >>> repro:system:plasma:libpaths >>>"
    let expectClose = "# <<< repro:system:plasma:libpaths <<<"

    check expectOpen in bytes
    check expectClose in bytes
    # Open MUST come before close.
    check bytes.find(expectOpen) < bytes.find(expectClose)

    # Regression guard: the sentinel MUST NOT reference any sister-DE
    # packageName segment.
    check "repro:system:sway:" notin bytes
    check "repro:system:gnome:" notin bytes
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
    # NdeK1Bundles has 5 entries (kwin + plasma-workspace +
    # plasma-desktop + kf5-frameworks + qt5-base), so we expect ≥4
    # per the sub-agent prompt.
    check libDirCount >= 4

  test "cascade-G fix: sddm.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # The load-bearing cascade-G assertion BOTH directions: AT
    # /usr/lib/systemd/system/, NOT AT /lib/systemd/system/. R9
    # systemd 257.9 dropped /lib/systemd/system/ from the default
    # UnitPath, so a unit planted only under /lib/ would be invisible
    # at boot. The native package must plant at /usr/lib/.
    let root = createTempDir("ndek1_unit_path_", "")
    defer: removeDir(root)

    let outs = materializePlasma(configWithRoot(root))

    # AT: usr/lib/systemd/system/
    check outs.sddmService.relPath ==
          "usr/lib/systemd/system/sddm.service"
    check fileExists(outs.sddmService.storePath /
                     "usr/lib/systemd/system/sddm.service")
    # NOT-AT: lib/systemd/system/
    check not fileExists(outs.sddmService.storePath /
                         "lib/systemd/system/sddm.service")

  test "sddm.service content shape: Type=simple + ExecStart=/usr/bin/sddm + WantedBy=graphical.target + Requires=dbus.service":
    # The unit content shape: simple startup (sddm doesn't expose
    # sd_notify); sddm binary at /usr/bin/sddm (Debian/Ubuntu package
    # sddm ships at /usr/bin/sddm); WantedBy a system target (not
    # user); Requires the dbus.service NDE0-D provides.
    let root = createTempDir("ndek1_unit_shape_", "")
    defer: removeDir(root)

    let outs = materializePlasma(configWithRoot(root))
    let bytes = readStoreFile(outs.sddmService)

    check "[Unit]" in bytes
    check "[Service]" in bytes
    check "[Install]" in bytes
    check "Type=simple" in bytes
    check "ExecStart=/usr/bin/sddm" in bytes
    check "WantedBy=graphical.target" in bytes
    check "Requires=dbus.service" in bytes

  test "XDG session entry: /etc/wayland-sessions/plasma.desktop has Name=Plasma (Wayland) + Exec + Type=Application + DesktopNames=KDE":
    # Display managers (sddm itself + gdm if installed alongside) read
    # this directory to populate the session-picker dropdown. The
    # .desktop entry shape per XDG Desktop Entry Specification +
    # DesktopNames=KDE so kf5/Qt5 apps see $XDG_CURRENT_DESKTOP=KDE.
    let root = createTempDir("ndek1_xdg_", "")
    defer: removeDir(root)

    let outs = materializePlasma(configWithRoot(root))

    # Path is etc/wayland-sessions/plasma.desktop.
    check outs.sessionDesktopEntry.relPath ==
          "etc/wayland-sessions/plasma.desktop"

    let bytes = readStoreFile(outs.sessionDesktopEntry)
    check "[Desktop Entry]" in bytes
    check "Name=Plasma (Wayland)" in bytes
    check "Exec=/usr/bin/startplasma-wayland" in bytes
    check "Type=Application" in bytes
    check "DesktopNames=KDE" in bytes

  test "idempotency: same config produces same store paths":
    let root = createTempDir("ndek1_idem_", "")
    defer: removeDir(root)

    let outsA = materializePlasma(configWithRoot(root))
    let outsB = materializePlasma(configWithRoot(root))

    check outsA.sddmConfig.storePath          == outsB.sddmConfig.storePath
    check outsA.ldConfBlock.storePath         == outsB.ldConfBlock.storePath
    check outsA.sddmService.storePath         == outsB.sddmService.storePath
    check outsA.sessionDesktopEntry.storePath == outsB.sessionDesktopEntry.storePath
    check outsA.pipewireConfig.storePath      == outsB.pipewireConfig.storePath

  test "cache-key invalidation: sddmAutoLoginUser change re-keys sddmConfig only":
    # The spec's contract at the package-output granularity: a
    # /etc/sddm.conf configurable change (e.g. sddmAutoLogin,
    # sddmAutoLoginUser, waylandSession) re-keys ONLY the sddmConfig
    # output; the ldConfBlock + sddmService + sessionDesktopEntry +
    # pipewireConfig stay cached because their inputs don't depend on
    # those configurables.
    let root = createTempDir("ndek1_invuser_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.sddmAutoLoginUser = "repro"
    let outsA = materializePlasma(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.sddmAutoLoginUser = "alice"
    let outsB = materializePlasma(cfgB)

    # sddmConfig MUST land at a different store path
    # (sddmAutoLoginUser is bound into the rendered INI content).
    check outsA.sddmConfig.storePath != outsB.sddmConfig.storePath
    # All four other outputs MUST stay at the same store path
    # (their inputs don't reference sddmAutoLoginUser).
    check outsA.ldConfBlock.storePath         == outsB.ldConfBlock.storePath
    check outsA.sddmService.storePath         == outsB.sddmService.storePath
    check outsA.sessionDesktopEntry.storePath == outsB.sessionDesktopEntry.storePath
    check outsA.pipewireConfig.storePath      == outsB.pipewireConfig.storePath

  test "determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirrors NDE-G1/H1/0-K/G's determinism tests.
    let rootA = createTempDir("ndek1_detA_", "")
    let rootB = createTempDir("ndek1_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializePlasma(configWithRoot(rootA))
    let outsB = materializePlasma(configWithRoot(rootB))

    # Hash-segment basenames match.
    check extractFilename(outsA.sddmConfig.storePath) ==
          extractFilename(outsB.sddmConfig.storePath)
    check extractFilename(outsA.ldConfBlock.storePath) ==
          extractFilename(outsB.ldConfBlock.storePath)
    check extractFilename(outsA.sddmService.storePath) ==
          extractFilename(outsB.sddmService.storePath)
    check extractFilename(outsA.sessionDesktopEntry.storePath) ==
          extractFilename(outsB.sessionDesktopEntry.storePath)
    check extractFilename(outsA.pipewireConfig.storePath) ==
          extractFilename(outsB.pipewireConfig.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.sddmConfig)          ==
          readStoreFile(outsB.sddmConfig)
    check readStoreFile(outsA.ldConfBlock)         ==
          readStoreFile(outsB.ldConfBlock)
    check readStoreFile(outsA.sddmService)         ==
          readStoreFile(outsB.sddmService)
    check readStoreFile(outsA.sessionDesktopEntry) ==
          readStoreFile(outsB.sessionDesktopEntry)
    check readStoreFile(outsA.pipewireConfig)      ==
          readStoreFile(outsB.pipewireConfig)

  test "priority=500 encoded in libpaths block cache key":
    # Per Generated-Configuration-Files.md §"Cache-key composition"
    # the managedBlock hash includes the priority value. The impl
    # module's ``NdeK1LibpathsPriority`` constant is the load-bearing
    # priority for compositors (spec worked example: "the three
    # priority-500 compositors then sort by package name"). Test
    # asserts (a) the constant value (b) the cache-key consequence:
    # re-hashing the same content + scope + packageName + blockId +
    # relPath with a different priority produces a different hash.
    check NdeK1LibpathsPriority == 500

    # Same content/scope/packageName/blockId/relPath; different
    # priority. Use the impl module's exposed hash helper.
    const path = "etc/ld.so.conf.d/00-reproos-linux.conf"
    let content = "test-content\n"
    let h500 = managedBlockHash(bsSystem, NdeK1PackageName,
                                NdeK1LibpathsBlockId, path, content, 500)
    let h100 = managedBlockHash(bsSystem, NdeK1PackageName,
                                NdeK1LibpathsBlockId, path, content, 100)
    check h500 != h100
    check h500.len == 16
    check h100.len == 16

    # And the planted block's hashHex (which derives from
    # priority=500 via the impl module's contract) matches the h500
    # computed against the rendered content.
    let root = createTempDir("ndek1_prio_", "")
    defer: removeDir(root)

    let cfg = configWithRoot(root)
    let outs = materializePlasma(cfg)
    let renderedContent = renderLdConfBlockContent(cfg)
    let expected = managedBlockHash(bsSystem, NdeK1PackageName,
                                    NdeK1LibpathsBlockId, path,
                                    renderedContent,
                                    NdeK1LibpathsPriority)
    check outs.ldConfBlock.hashHex == expected

  test "cache-key isolation: per-output hashes are distinct + 16 chars":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. Mirrors
    # NDE-G1/H1/0-K/G's isolation test.
    let root = createTempDir("ndek1_iso_", "")
    defer: removeDir(root)

    let outs = materializePlasma(configWithRoot(root))

    # All 10 pairwise comparisons across the 5 outputs.
    check outs.sddmConfig.hashHex          != outs.ldConfBlock.hashHex
    check outs.sddmConfig.hashHex          != outs.sddmService.hashHex
    check outs.sddmConfig.hashHex          != outs.sessionDesktopEntry.hashHex
    check outs.sddmConfig.hashHex          != outs.pipewireConfig.hashHex
    check outs.ldConfBlock.hashHex         != outs.sddmService.hashHex
    check outs.ldConfBlock.hashHex         != outs.sessionDesktopEntry.hashHex
    check outs.ldConfBlock.hashHex         != outs.pipewireConfig.hashHex
    check outs.sddmService.hashHex         != outs.sessionDesktopEntry.hashHex
    check outs.sddmService.hashHex         != outs.pipewireConfig.hashHex
    check outs.sessionDesktopEntry.hashHex != outs.pipewireConfig.hashHex

    # All hash-hex segments are exactly 16 chars (mirrors
    # NDE0-A/S/D/G/K + NDE-H1 + NDE-G1).
    check outs.sddmConfig.hashHex.len          == 16
    check outs.ldConfBlock.hashHex.len         == 16
    check outs.sddmService.hashHex.len         == 16
    check outs.sessionDesktopEntry.hashHex.len == 16
    check outs.pipewireConfig.hashHex.len      == 16

  test "stable activation order: storePaths 5-element enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # sddmConfig first (the sddm daemon's INI configuration), then
    # ldConfBlock (the link-path contribution the ldconfig oneshot
    # reads), then sddmService (the systemd display-manager unit),
    # then sessionDesktopEntry (the display-manager session-picker
    # entry), then pipewireConfig (the audio + screen-capture daemon
    # config). The 5-element shape is the load-bearing contract: any
    # consumer of ``storePaths`` may rely on positional access.
    let root = createTempDir("ndek1_order_", "")
    defer: removeDir(root)

    let outs = materializePlasma(configWithRoot(root))
    let paths = storePaths(outs)

    check paths.len == 5
    check paths[0] == outs.sddmConfig.storePath
    check paths[1] == outs.ldConfBlock.storePath
    check paths[2] == outs.sddmService.storePath
    check paths[3] == outs.sessionDesktopEntry.storePath
    check paths[4] == outs.pipewireConfig.storePath

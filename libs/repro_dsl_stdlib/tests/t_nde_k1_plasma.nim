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

# The recipe — registers the package's M2 configurables + module-init
# fires every ``files <name>: build:`` arm + the ``service
# displayManager:`` arm so the M8/M9.A + M9.C tables are pre-populated
# against the default configurables. The recipe also re-exports the
# per-artifact ``register*`` helpers the NDE-H DSL-surface fixture
# below uses to re-register after a configurable toggle.
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/desktop-environments/plasma/repro" as recipe

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
# DSL-port helpers — used by the NDE-H DSL-surface suite at the end.
# ---------------------------------------------------------------------------

proc readDslStoreFile(handle: DslManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath`` for the M9.A materialiser
  ## handles (parallel to ``readStoreFile`` above for the shim's
  ## ``ManagedFiles``).
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc resetRecipeState(storeRoot: string) =
  ## Test-fixture reset: clear every M8/M9.A registry + materialiser
  ## row, drop any pending configurable overrides for the plasmaDesktop
  ## package, then re-register every fs.* output the recipe owns against
  ## the (now-default) configurables.
  ##
  ## The libpaths managedBlock crosses two packageName namespaces: the
  ## DSL package identifier (``plasmaDesktop``) the M3 ``files:`` arms
  ## register against AND the cohort-wide kebab-cased segment
  ## (``plasma``) the contribution carries for sentinel uniqueness. Both
  ## store-root entries are bound below so the ``consumeManagedBlock``
  ## lookup against the contribution's packageName finds an entry.
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetConfigurable("plasmaDesktop.aptSnapshot")
  resetConfigurable("plasmaDesktop.sddmAutoLogin")
  resetConfigurable("plasmaDesktop.sddmAutoLoginUser")
  resetConfigurable("plasmaDesktop.waylandSession")
  resetConfigurable("plasmaDesktop.pipewireEnabled")
  registerStoreRoot("plasmaDesktop", storeRoot, dhaSha256)
  registerStoreRoot(NdeK1PackageName, storeRoot, dhaSha256)
  recipe.registerPlasmaFiles()

proc reregisterWithCurrentConfigurables(storeRoot: string) =
  ## After ``setConfigurable(...)`` has flipped one or more cells, the
  ## previously-recorded M8/M9 entries still carry the OLD content;
  ## drop them, re-register against the new cells, and re-bind the
  ## store-root (the M9.A reset call below also wipes it).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  registerStoreRoot("plasmaDesktop", storeRoot, dhaSha256)
  registerStoreRoot(NdeK1PackageName, storeRoot, dhaSha256)
  recipe.registerPlasmaFiles()

proc consumeSddmConfigDsl(): DslManagedFiles =
  consumeConfigFile("plasmaDesktop", "/etc/sddm.conf")
proc consumeLdConfDsl(): DslManagedFiles =
  consumeManagedBlock("/etc/ld.so.conf.d/00-reproos-linux.conf")
proc consumeSddmServiceDsl(): DslManagedFiles =
  consumeConfigFile("plasmaDesktop",
                    "/usr/lib/systemd/system/sddm.service")
proc consumeSessionDesktopEntryDsl(): DslManagedFiles =
  consumeConfigFile("plasmaDesktop",
                    "/etc/wayland-sessions/plasma.desktop")
proc consumePipewireConfigDsl(): DslManagedFiles =
  consumeConfigFile("plasmaDesktop", "/etc/pipewire/pipewire.conf")

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

# ---------------------------------------------------------------------------
# NDE-H DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/desktop-environments/plasma/repro.nim`` actually
# exercises the new DSL surface (M3 ``files <name>:`` blocks + M8/M9.A
# ``fs.configFile`` / ``fs.managedBlock`` + M9.C ``service:`` block)
# rather than silently regressing to the legacy "shim does everything"
# shape. These are extra assertions on top of the v1 surface — the v1
# structural assertions above stay intact.
# ---------------------------------------------------------------------------

suite "NDE-K1 KDE Plasma compositor DSL surface":

  test "recipe registers exactly 5 files: artifacts":
    let arts = registeredArtifacts("plasmaDesktop")
    check arts.len == 5

  test "every recipe artifact is dakFiles":
    let arts = registeredArtifacts("plasmaDesktop")
    for a in arts:
      check a.kind == dakFiles

  test "recipe artifact names cover every emitted file":
    let arts = registeredArtifacts("plasmaDesktop")
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "sddmConfig"           in names
    check "ldConfContribution"   in names
    check "sddmService"          in names
    check "sessionDesktopEntry"  in names
    check "pipewireConfig"       in names

  test "M9.C service displayManager: records the systemd-unit metadata surface":
    # Pins the M9.C extended service: block. The recipe declares
    # description / `type` / execStart / wantedBy / after; the M5+M9.C
    # parser captures every one verbatim into the DslServiceDef
    # registry.
    let svcs = registeredServices("plasmaDesktop")
    check svcs.len == 1
    let svc = svcs[0]
    check svc.serviceName == "displayManager"
    check svc.description == "Simple Desktop Display Manager"
    check svc.serviceType == "simple"
    check svc.execStart   == "/usr/bin/sddm"
    check svc.wantedBy    == @["graphical.target"]
    check svc.after       == @["systemd-user-sessions.service"]
    # No ``executable <ident>`` setter → both the legacy
    # ``executableRef`` and the new ``executable`` alias stay empty.
    check svc.executable == ""
    check svc.executableRef == ""
    check svc.args.len == 0

  test "sentinel triple-form via DSL surface: libpaths block uses packageName=plasma, blockId=libpaths":
    # Same sentinel guard as the shim-side test above, but exercised
    # through the DSL's M9.A ``consumeManagedBlock`` materialiser to
    # confirm the recipe's ``fs.managedBlock(...)`` call carries the
    # cohort-wide identifiers verbatim.
    let root = createTempDir("ndek1_dsl_sentinel_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let ldConf = consumeLdConfDsl()
    let bytes = readDslStoreFile(ldConf)

    let expectOpen = "# >>> repro:system:plasma:libpaths >>>"
    let expectClose = "# <<< repro:system:plasma:libpaths <<<"

    check expectOpen in bytes
    check expectClose in bytes
    check bytes.find(expectOpen) < bytes.find(expectClose)
    # M9.A sha256 hashes are 64 lower-hex chars.
    check ldConf.hashHex.len == 64
    # Sanity: the store path is rooted under the override.
    check ldConf.storePath.startsWith(root)

  test "cascade-G fix via DSL surface: sddm.service planted at /usr/lib/systemd/system/":
    # The cascade-G assertion through the DSL surface. The M9.A
    # ``consumeConfigFile`` materialiser drops the leading / when
    # canonicalising the host path to the store-relative ``relPath``.
    let root = createTempDir("ndek1_dsl_unit_path_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let svc = consumeSddmServiceDsl()
    check svc.relPath ==
      "usr/lib/systemd/system/sddm.service"
    check fileExists(svc.storePath /
                     "usr/lib/systemd/system/sddm.service")
    check not fileExists(svc.storePath /
                         "lib/systemd/system/sddm.service")
    # M9.A sha256 hashes are 64 lower-hex chars.
    check svc.hashHex.len == 64

  test "DSL surface: /etc/sddm.conf has User= line + propagates via DSL configurables":
    # End-to-end propagation: setConfigurable(...) → re-register →
    # consumeConfigFile reads the materialised bytes. Mirrors the
    # NDE-G gnome DSL-surface propagation test.
    let root = createTempDir("ndek1_dsl_sddmconfig_", "")
    defer: removeDir(root)

    # Pass A — default (sddmAutoLoginUser = "repro").
    resetRecipeState(root)
    let cfgA = consumeSddmConfigDsl()
    let bytesA = readDslStoreFile(cfgA)
    check "User=repro" in bytesA
    check "User=alice" notin bytesA

    # Pass B — flip sddmAutoLoginUser to "alice" via setConfigurable.
    setConfigurable[string](
      "plasmaDesktop.sddmAutoLoginUser", "alice")
    reregisterWithCurrentConfigurables(root)
    let cfgB = consumeSddmConfigDsl()
    let bytesB = readDslStoreFile(cfgB)
    check "User=alice" in bytesB
    check "User=repro" notin bytesB

    # Store paths differ; the snapshot-independent unit + xdg outputs
    # stay cached.
    check cfgA.storePath != cfgB.storePath
    # Reset sddmAutoLoginUser for hygiene.
    resetConfigurable("plasmaDesktop.sddmAutoLoginUser")

  test "DSL surface: /etc/pipewire/pipewire.conf propagates pipewireEnabled toggle":
    # The extra fifth artifact's propagation test. pipewireEnabled
    # toggle swaps between the ENABLED daemon config + the DISABLED
    # marker file. The Plasma-specific path covering the cohort's
    # 5-artifact shape vs sway/gnome's 4-artifact shape.
    let root = createTempDir("ndek1_dsl_pipewire_", "")
    defer: removeDir(root)

    # Pass A — default (pipewireEnabled = true).
    resetRecipeState(root)
    let cfgA = consumePipewireConfigDsl()
    let bytesA = readDslStoreFile(cfgA)
    check "PipeWire daemon: ENABLED" in bytesA
    check "context.properties" in bytesA
    check "PipeWire daemon: DISABLED" notin bytesA

    # Pass B — flip pipewireEnabled to false via setConfigurable.
    setConfigurable[bool](
      "plasmaDesktop.pipewireEnabled", false)
    reregisterWithCurrentConfigurables(root)
    let cfgB = consumePipewireConfigDsl()
    let bytesB = readDslStoreFile(cfgB)
    check "PipeWire daemon: DISABLED" in bytesB
    check "pipewire.enabled = false" in bytesB
    check "PipeWire daemon: ENABLED" notin bytesB

    # Store paths differ.
    check cfgA.storePath != cfgB.storePath
    # Reset pipewireEnabled for hygiene.
    resetConfigurable("plasmaDesktop.pipewireEnabled")

  test "anchor constants: NDE-K1 libpaths identifiers match shim exports":
    # The cohort-wide identifiers for the libpaths overlay are sourced
    # from the shim's exported constants so a future rename / priority
    # bump propagates from one place. The recipe MUST NOT hardcode
    # "libpaths" / 500 / "plasma" — this test pins that contract.
    check NdeK1LibpathsBlockId  == "libpaths"
    check NdeK1LibpathsPriority == 500
    check NdeK1PackageName      == "plasma"

    # And the recipe's registered contribution carries exactly those
    # values verbatim.
    let root = createTempDir("ndek1_anchor_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let contribs = registeredManagedBlocks(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check contribs.len == 1
    let c = contribs[0]
    check c.blockId     == NdeK1LibpathsBlockId
    check c.priority    == NdeK1LibpathsPriority
    check c.packageName == NdeK1PackageName
    check c.scope       == bsSystem

  test "multi-contributor merge: NDE-D graphics-stack (priority=100) sorts BEFORE plasma (priority=500)":
    # The load-bearing NDE-H cohort-overlay test. NDE-D pinned the
    # ordering invariant from the ANCHOR side. NDE-F + NDE-G pinned it
    # from the sway + gnome OVERLAY sides. NDE-H now pins it from the
    # PLASMA overlay side: the recipe's priority=500 contribution is
    # already registered by ``resetRecipeState``; we add a synthetic
    # priority=100 graphics-stack contribution alongside and assert the
    # merger sorts (priority, packageName, blockId) ascending so
    # graphics-stack (priority=100) appears BEFORE plasma (priority=500)
    # per the spec §"Block ordering rule".
    let root = createTempDir("ndek1_merge_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # Add a synthetic graphics-stack contribution at priority=100
    # (simulating NDE-D's anchor). blockId differs to keep both
    # contributions visible per the (scope, packageName, blockId)
    # uniqueness rule.
    fs.managedBlock(
      path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
      blockId = "libpaths-anchor",
      scope = bsSystem,
      content = "/opt/reproos-linux/store/gfxAnchorStub/usr/lib/x86_64-linux-gnu\n",
      priority = 100,
      packageName = "graphics-stack",
      artifactName = "ldConfAnchor")

    # The merged file's contents have BOTH contributions, with
    # graphics-stack (priority=100) sorted before the priority=500
    # plasma overlay per the spec's ``(priority, packageName, blockId)``
    # rule.
    let merged =
      mergedManagedBlockFile("/etc/ld.so.conf.d/00-reproos-linux.conf")

    let gfxOpen    = "# >>> repro:system:graphics-stack:libpaths-anchor >>>"
    let plasmaOpen = "# >>> repro:system:plasma:libpaths >>>"

    check gfxOpen in merged
    check plasmaOpen in merged
    # Graphics-stack's sentinel MUST appear before plasma's — the
    # load-bearing NDE-H overlay-side invariant.
    check merged.find(gfxOpen) < merged.find(plasmaOpen)
    # Both sentinel pairs close.
    check "# <<< repro:system:graphics-stack:libpaths-anchor <<<" in merged
    check "# <<< repro:system:plasma:libpaths <<<" in merged
    # The graphics-stack anchor stub is present.
    check "gfxAnchorStub" in merged
    # And plasma's lib-dir contribution is present.
    check "/usr/lib/x86_64-linux-gnu" in merged

    # The merger registered both contributors. ``registeredManagedBlocks``
    # returns insertion order; sort discipline lives in
    # ``mergedManagedBlockFile`` itself.
    let contribs = registeredManagedBlocks(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check contribs.len == 2

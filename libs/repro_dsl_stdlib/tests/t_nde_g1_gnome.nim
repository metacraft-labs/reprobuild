## NDE-G1 unit tests: native GNOME compositor package (NDE-G migrated).
##
## Exercises the spec'd public surface of
## ``recipes/packages/desktop-environments/gnome/repro.nim`` through both:
##
##   (a) The shim's ``materializeGnome()`` orchestrator — the v1 invariant
##       suite below. Mirrors the NDE-H1 + NDE0-K + NDE0-G + NDE0-D +
##       NDE0-S test layout (per-output ``ManagedFiles`` round-trip +
##       per-configurable propagation + cache-key isolation + cascade-G
##       discipline assertions in BOTH directions + byte-determinism).
##
##   (b) The DSL's M8 / M9.A materialisation path (``fs.configFile`` /
##       ``fs.managedBlock`` registration + ``consumeConfigFile`` /
##       ``consumeManagedBlock`` materialisation) — the NDE-G "DSL
##       surface" suite at the end. Pins the recipe genuinely exercises
##       the typed surface rather than silently regressing to the legacy
##       "shim does everything" shape. Includes the multi-contributor
##       merge test that confirms NDE-D graphics-stack (priority=100)
##       sorts BEFORE this package's contribution (priority=500).
##
## Required test surfaces (per the NDE-G1 sub-agent prompt §"Unit
## tests"):
##
##   1. **Configurable propagation: autoLogin** — change ``true`` →
##      ``false``; assert ``AutomaticLoginEnable=false`` appears,
##      ``AutomaticLoginEnable=true`` does not; assert store paths
##      differ.
##   2. **Configurable propagation: autoLoginUser** — change
##      ``"repro"`` → ``"alice"``; assert ``AutomaticLogin=alice``.
##   3. **Configurable propagation: waylandSession** — change
##      ``true`` → ``false``; assert ``WaylandEnable=false``.
##   4. **Configurable propagation: disableInitialSetup** — toggle;
##      verify content differs.
##   5. **NDE-spec-block sentinel triple-form** for libpaths:
##      ``# >>> repro:system:gnome:libpaths >>>`` open +
##      ``# <<< repro:system:gnome:libpaths <<<`` close. Sentinel
##      does NOT contain ``sway`` or ``plasma`` (regression guard).
##   6. **Cascade-G unit path** — ``gdm.service`` planted at
##      ``usr/lib/systemd/system/``, NOT ``lib/systemd/system/``.
##      Both directions.
##   7. **gdm.service content shape** — Type=notify or simple,
##      ExecStart=/usr/sbin/gdm3, WantedBy=graphical.target,
##      Requires=dbus.service.
##   8. **XDG session entry** — ``Name=GNOME``,
##      ``Exec=/usr/local/bin/gnome-session``, ``Type=Application``,
##      ``DesktopNames=GNOME``.
##   9. **Idempotency** — same config produces same store paths.
##   10. **Cache-key invalidation** — autoLoginUser change re-keys
##       gdmConfig only; ldConfBlock + gdmService + sessionDesktopEntry
##       stay cached.
##   11. **Byte-determinism** across two independent materialize roots.
##   12. **Priority=500 encoded in libpaths block cache key**.
##   13. **Hash isolation + 16-char hex** for all 4 outputs.
##
## No try/except swallows. Failure paths use ``expect`` where
## applicable; this module's primitives are infallible by design
## (mirror of NDE-H1 + NDE0-K/G/S), so most assertions use ``check``.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/desktop_environments/gnome
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # for managedBlockHash + ManagedFiles + bsSystem (priority test)

# The recipe — registers the package's M2 configurables + module-init
# fires every ``files <name>: build:`` arm + the ``service
# displayManager:`` arm so the M8/M9.A + M9.C tables are pre-populated
# against the default configurables. The recipe also re-exports the
# per-artifact ``register*`` helpers the NDE-G DSL-surface fixture
# below uses to re-register after a configurable toggle.
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/desktop-environments/gnome/repro" as recipe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the NDE0-K/G/H1
  ## helper exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): GnomeConfig =
  result = defaultConfig()
  result.storeRoot = storeRoot

# ---------------------------------------------------------------------------
# DSL-port helpers — used by the NDE-G DSL-surface suite at the end.
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
  ## row, drop any pending configurable overrides for the gnomeDesktop
  ## package, then re-register every fs.* output the recipe owns against
  ## the (now-default) configurables.
  ##
  ## The libpaths managedBlock crosses two packageName namespaces: the
  ## DSL package identifier (``gnomeDesktop``) the M3 ``files:`` arms
  ## register against AND the cohort-wide kebab-cased segment
  ## (``gnome``) the contribution carries for sentinel uniqueness. Both
  ## store-root entries are bound below so the ``consumeManagedBlock``
  ## lookup against the contribution's packageName finds an entry.
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetConfigurable("gnomeDesktop.aptSnapshot")
  resetConfigurable("gnomeDesktop.autoLogin")
  resetConfigurable("gnomeDesktop.autoLoginUser")
  resetConfigurable("gnomeDesktop.waylandSession")
  resetConfigurable("gnomeDesktop.disableInitialSetup")
  registerStoreRoot("gnomeDesktop", storeRoot, dhaSha256)
  registerStoreRoot(NdeG1PackageName, storeRoot, dhaSha256)
  recipe.registerGnomeFiles()

proc reregisterWithCurrentConfigurables(storeRoot: string) =
  ## After ``setConfigurable(...)`` has flipped one or more cells, the
  ## previously-recorded M8/M9 entries still carry the OLD content;
  ## drop them, re-register against the new cells, and re-bind the
  ## store-root (the M9.A reset call below also wipes it).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  registerStoreRoot("gnomeDesktop", storeRoot, dhaSha256)
  registerStoreRoot(NdeG1PackageName, storeRoot, dhaSha256)
  recipe.registerGnomeFiles()

proc consumeGdmConfigDsl(): DslManagedFiles =
  consumeConfigFile("gnomeDesktop", "/etc/gdm3/custom.conf")
proc consumeLdConfDsl(): DslManagedFiles =
  consumeManagedBlock("/etc/ld.so.conf.d/00-reproos-linux.conf")
proc consumeGdmServiceDsl(): DslManagedFiles =
  consumeConfigFile("gnomeDesktop",
                    "/usr/lib/systemd/system/gdm.service")
proc consumeSessionDesktopEntryDsl(): DslManagedFiles =
  consumeConfigFile("gnomeDesktop",
                    "/etc/wayland-sessions/gnome.desktop")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE-G1 GNOME compositor package":

  test "configurable propagation: autoLogin change re-keys gdmConfig (spec'd acceptance)":
    # Spec NDE-G1 acceptance literal: "Toggle autoLogin = false →
    # only /etc/gdm3/custom.conf rebuilds". The rendered INI must
    # swap the AutomaticLoginEnable= value AND the content-addressed
    # gdmConfig storePath must differ.
    let rootOn = createTempDir("ndeg1_alogin_on_", "")
    let rootOff = createTempDir("ndeg1_alogin_off_", "")
    defer:
      removeDir(rootOn)
      removeDir(rootOff)

    var cfgOn = configWithRoot(rootOn)
    cfgOn.autoLogin = true
    let outsOn = materializeGnome(cfgOn)
    let onBytes = readStoreFile(outsOn.gdmConfig)

    var cfgOff = configWithRoot(rootOff)
    cfgOff.autoLogin = false
    let outsOff = materializeGnome(cfgOff)
    let offBytes = readStoreFile(outsOff.gdmConfig)

    # Baseline has AutomaticLoginEnable=true; mutated has false.
    check "AutomaticLoginEnable=true" in onBytes
    check "AutomaticLoginEnable=false" notin onBytes
    check "AutomaticLoginEnable=false" in offBytes
    check "AutomaticLoginEnable=true" notin offBytes

    # Content differs + store path differs (cache-key propagation).
    check onBytes != offBytes
    check outsOn.gdmConfig.storePath != outsOff.gdmConfig.storePath

  test "configurable propagation: autoLoginUser change re-keys gdmConfig":
    # Swap autoLoginUser repro → alice; assert AutomaticLogin=<user>
    # line changes + the storePath re-keys.
    let rootRepro = createTempDir("ndeg1_user_repro_", "")
    let rootAlice = createTempDir("ndeg1_user_alice_", "")
    defer:
      removeDir(rootRepro)
      removeDir(rootAlice)

    var cfgRepro = configWithRoot(rootRepro)
    cfgRepro.autoLoginUser = "repro"
    let outsRepro = materializeGnome(cfgRepro)
    let reproBytes = readStoreFile(outsRepro.gdmConfig)

    var cfgAlice = configWithRoot(rootAlice)
    cfgAlice.autoLoginUser = "alice"
    let outsAlice = materializeGnome(cfgAlice)
    let aliceBytes = readStoreFile(outsAlice.gdmConfig)

    check "AutomaticLogin=repro" in reproBytes
    check "AutomaticLogin=alice" notin reproBytes
    check "AutomaticLogin=alice" in aliceBytes
    check "AutomaticLogin=repro" notin aliceBytes

    check reproBytes != aliceBytes
    check outsRepro.gdmConfig.storePath != outsAlice.gdmConfig.storePath

  test "configurable propagation: waylandSession change re-keys gdmConfig":
    # Swap waylandSession true → false; assert WaylandEnable=<bool>
    # line changes + the storePath re-keys.
    let rootWl = createTempDir("ndeg1_wl_on_", "")
    let rootXorg = createTempDir("ndeg1_wl_off_", "")
    defer:
      removeDir(rootWl)
      removeDir(rootXorg)

    var cfgWl = configWithRoot(rootWl)
    cfgWl.waylandSession = true
    let outsWl = materializeGnome(cfgWl)
    let wlBytes = readStoreFile(outsWl.gdmConfig)

    var cfgXorg = configWithRoot(rootXorg)
    cfgXorg.waylandSession = false
    let outsXorg = materializeGnome(cfgXorg)
    let xorgBytes = readStoreFile(outsXorg.gdmConfig)

    check "WaylandEnable=true" in wlBytes
    check "WaylandEnable=false" notin wlBytes
    check "WaylandEnable=false" in xorgBytes
    check "WaylandEnable=true" notin xorgBytes

    check wlBytes != xorgBytes
    check outsWl.gdmConfig.storePath != outsXorg.gdmConfig.storePath

  test "configurable propagation: disableInitialSetup toggle re-keys gdmConfig":
    # disableInitialSetup=true (default) emits
    # InitialSetupEnable=false in the [InitialSetupEnable] section.
    # Toggling to disableInitialSetup=false swaps it to
    # InitialSetupEnable=true. Both content + storePath differ.
    let rootDis = createTempDir("ndeg1_initdis_", "")
    let rootEna = createTempDir("ndeg1_initena_", "")
    defer:
      removeDir(rootDis)
      removeDir(rootEna)

    var cfgDis = configWithRoot(rootDis)
    cfgDis.disableInitialSetup = true
    let outsDis = materializeGnome(cfgDis)
    let disBytes = readStoreFile(outsDis.gdmConfig)

    var cfgEna = configWithRoot(rootEna)
    cfgEna.disableInitialSetup = false
    let outsEna = materializeGnome(cfgEna)
    let enaBytes = readStoreFile(outsEna.gdmConfig)

    # The [InitialSetupEnable] section + the InitialSetupEnable= key
    # are present in both branches; only the boolean value swaps.
    check "[InitialSetupEnable]" in disBytes
    check "[InitialSetupEnable]" in enaBytes
    check "InitialSetupEnable=false" in disBytes
    check "InitialSetupEnable=true" notin disBytes
    check "InitialSetupEnable=true" in enaBytes
    check "InitialSetupEnable=false" notin enaBytes

    check disBytes != enaBytes
    check outsDis.gdmConfig.storePath != outsEna.gdmConfig.storePath

  test "sentinel triple-form: libpaths block uses NDE-spec-block shape with packageName=gnome":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = gnome, blockId = libpaths.
    # Critically: packageName MUST be "gnome" — NOT "sway", NOT
    # "plasma", NOT "hyprland" (regression guards against cross-DE
    # sentinel collisions).
    let root = createTempDir("ndeg1_sentinel_", "")
    defer: removeDir(root)

    let outs = materializeGnome(configWithRoot(root))
    let bytes = readStoreFile(outs.ldConfBlock)

    let expectOpen = "# >>> repro:system:gnome:libpaths >>>"
    let expectClose = "# <<< repro:system:gnome:libpaths <<<"

    check expectOpen in bytes
    check expectClose in bytes
    # Open MUST come before close.
    check bytes.find(expectOpen) < bytes.find(expectClose)

    # Regression guard: the sentinel MUST NOT reference any sister-DE
    # packageName segment.
    check "repro:system:sway:" notin bytes
    check "repro:system:plasma:" notin bytes
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

  test "cascade-G fix: gdm.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # The load-bearing cascade-G assertion BOTH directions: AT
    # /usr/lib/systemd/system/, NOT AT /lib/systemd/system/. R9
    # systemd 257.9 dropped /lib/systemd/system/ from the default
    # UnitPath, so a unit planted only under /lib/ would be invisible
    # at boot. The native package must plant at /usr/lib/.
    let root = createTempDir("ndeg1_unit_path_", "")
    defer: removeDir(root)

    let outs = materializeGnome(configWithRoot(root))

    # AT: usr/lib/systemd/system/
    check outs.gdmService.relPath ==
          "usr/lib/systemd/system/gdm.service"
    check fileExists(outs.gdmService.storePath /
                     "usr/lib/systemd/system/gdm.service")
    # NOT-AT: lib/systemd/system/
    check not fileExists(outs.gdmService.storePath /
                         "lib/systemd/system/gdm.service")

  test "gdm.service content shape: Type=notify + ExecStart=/usr/sbin/gdm3 + WantedBy=graphical.target + Requires=dbus.service":
    # The unit content shape: notify-based startup; gdm3 binary at
    # /usr/sbin/gdm3 (Debian/Ubuntu package gdm3); WantedBy a system
    # target (not user); Requires the dbus.service NDE0-D provides.
    let root = createTempDir("ndeg1_unit_shape_", "")
    defer: removeDir(root)

    let outs = materializeGnome(configWithRoot(root))
    let bytes = readStoreFile(outs.gdmService)

    check "[Unit]" in bytes
    check "[Service]" in bytes
    check "[Install]" in bytes
    check "Type=notify" in bytes
    check "ExecStart=/usr/sbin/gdm3" in bytes
    check "WantedBy=graphical.target" in bytes
    check "Requires=dbus.service" in bytes

  test "XDG session entry: /etc/wayland-sessions/gnome.desktop has Name=GNOME + Exec + Type=Application + DesktopNames=GNOME":
    # Display managers (gdm itself + sddm if installed alongside) read
    # this directory to populate the session-picker dropdown. The
    # .desktop entry shape per XDG Desktop Entry Specification +
    # gdm-specific X-GDM-SessionRegisters=true so gdm doesn't double-
    # register with logind.
    let root = createTempDir("ndeg1_xdg_", "")
    defer: removeDir(root)

    let outs = materializeGnome(configWithRoot(root))

    # Path is etc/wayland-sessions/gnome.desktop.
    check outs.sessionDesktopEntry.relPath ==
          "etc/wayland-sessions/gnome.desktop"

    let bytes = readStoreFile(outs.sessionDesktopEntry)
    check "[Desktop Entry]" in bytes
    check "Name=GNOME" in bytes
    check "Exec=/usr/local/bin/gnome-session" in bytes
    check "Type=Application" in bytes
    check "DesktopNames=GNOME" in bytes

  test "idempotency: same config produces same store paths":
    let root = createTempDir("ndeg1_idem_", "")
    defer: removeDir(root)

    let outsA = materializeGnome(configWithRoot(root))
    let outsB = materializeGnome(configWithRoot(root))

    check outsA.gdmConfig.storePath           == outsB.gdmConfig.storePath
    check outsA.ldConfBlock.storePath         == outsB.ldConfBlock.storePath
    check outsA.gdmService.storePath          == outsB.gdmService.storePath
    check outsA.sessionDesktopEntry.storePath == outsB.sessionDesktopEntry.storePath

  test "cache-key invalidation: autoLoginUser change re-keys gdmConfig only":
    # The spec's contract at the package-output granularity: a
    # /etc/gdm3/custom.conf configurable change (e.g. autoLogin,
    # autoLoginUser, waylandSession, disableInitialSetup) re-keys ONLY
    # the gdmConfig output; the ldConfBlock + gdmService +
    # sessionDesktopEntry stay cached because their inputs don't
    # depend on those configurables.
    let root = createTempDir("ndeg1_invuser_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.autoLoginUser = "repro"
    let outsA = materializeGnome(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.autoLoginUser = "alice"
    let outsB = materializeGnome(cfgB)

    # gdmConfig MUST land at a different store path (autoLoginUser
    # is bound into the rendered INI content).
    check outsA.gdmConfig.storePath != outsB.gdmConfig.storePath
    # All three other outputs MUST stay at the same store path
    # (their inputs don't reference autoLoginUser).
    check outsA.ldConfBlock.storePath         == outsB.ldConfBlock.storePath
    check outsA.gdmService.storePath          == outsB.gdmService.storePath
    check outsA.sessionDesktopEntry.storePath == outsB.sessionDesktopEntry.storePath

  test "determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirrors NDE0-K/G/H1's determinism tests.
    let rootA = createTempDir("ndeg1_detA_", "")
    let rootB = createTempDir("ndeg1_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializeGnome(configWithRoot(rootA))
    let outsB = materializeGnome(configWithRoot(rootB))

    # Hash-segment basenames match.
    check extractFilename(outsA.gdmConfig.storePath) ==
          extractFilename(outsB.gdmConfig.storePath)
    check extractFilename(outsA.ldConfBlock.storePath) ==
          extractFilename(outsB.ldConfBlock.storePath)
    check extractFilename(outsA.gdmService.storePath) ==
          extractFilename(outsB.gdmService.storePath)
    check extractFilename(outsA.sessionDesktopEntry.storePath) ==
          extractFilename(outsB.sessionDesktopEntry.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.gdmConfig)           ==
          readStoreFile(outsB.gdmConfig)
    check readStoreFile(outsA.ldConfBlock)         ==
          readStoreFile(outsB.ldConfBlock)
    check readStoreFile(outsA.gdmService)          ==
          readStoreFile(outsB.gdmService)
    check readStoreFile(outsA.sessionDesktopEntry) ==
          readStoreFile(outsB.sessionDesktopEntry)

  test "priority=500 encoded in libpaths block cache key":
    # Per Generated-Configuration-Files.md §"Cache-key composition"
    # the managedBlock hash includes the priority value. The impl
    # module's ``NdeG1LibpathsPriority`` constant is the load-bearing
    # priority for compositors (spec worked example: "the three
    # priority-500 compositors then sort by package name"). Test
    # asserts (a) the constant value (b) the cache-key consequence:
    # re-hashing the same content + scope + packageName + blockId +
    # relPath with a different priority produces a different hash.
    check NdeG1LibpathsPriority == 500

    # Same content/scope/packageName/blockId/relPath; different
    # priority. Use the impl module's exposed hash helper.
    const path = "etc/ld.so.conf.d/00-reproos-linux.conf"
    let content = "test-content\n"
    let h500 = managedBlockHash(bsSystem, NdeG1PackageName,
                                NdeG1LibpathsBlockId, path, content, 500)
    let h100 = managedBlockHash(bsSystem, NdeG1PackageName,
                                NdeG1LibpathsBlockId, path, content, 100)
    check h500 != h100
    check h500.len == 16
    check h100.len == 16

    # And the planted block's hashHex (which derives from
    # priority=500 via the impl module's contract) matches the h500
    # computed against the rendered content.
    let root = createTempDir("ndeg1_prio_", "")
    defer: removeDir(root)

    let cfg = configWithRoot(root)
    let outs = materializeGnome(cfg)
    let renderedContent = renderLdConfBlockContent(cfg)
    let expected = managedBlockHash(bsSystem, NdeG1PackageName,
                                    NdeG1LibpathsBlockId, path,
                                    renderedContent,
                                    NdeG1LibpathsPriority)
    check outs.ldConfBlock.hashHex == expected

  test "cache-key isolation: per-output hashes are distinct + 16 chars":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. Mirrors
    # NDE-H1/0-K/G's isolation test.
    let root = createTempDir("ndeg1_iso_", "")
    defer: removeDir(root)

    let outs = materializeGnome(configWithRoot(root))

    check outs.gdmConfig.hashHex           != outs.ldConfBlock.hashHex
    check outs.gdmConfig.hashHex           != outs.gdmService.hashHex
    check outs.gdmConfig.hashHex           != outs.sessionDesktopEntry.hashHex
    check outs.ldConfBlock.hashHex         != outs.gdmService.hashHex
    check outs.ldConfBlock.hashHex         != outs.sessionDesktopEntry.hashHex
    check outs.gdmService.hashHex          != outs.sessionDesktopEntry.hashHex

    # All hash-hex segments are exactly 16 chars (mirrors
    # NDE0-A/S/D/G/K + NDE-H1).
    check outs.gdmConfig.hashHex.len           == 16
    check outs.ldConfBlock.hashHex.len         == 16
    check outs.gdmService.hashHex.len          == 16
    check outs.sessionDesktopEntry.hashHex.len == 16

  test "stable activation order: storePaths enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # gdmConfig first (the gdm daemon's INI configuration), then
    # ldConfBlock (the link-path contribution the ldconfig oneshot
    # reads), then gdmService (the systemd display-manager unit),
    # then sessionDesktopEntry (the display-manager session-picker
    # entry).
    let root = createTempDir("ndeg1_order_", "")
    defer: removeDir(root)

    let outs = materializeGnome(configWithRoot(root))
    let paths = storePaths(outs)

    check paths.len == 4
    check paths[0] == outs.gdmConfig.storePath
    check paths[1] == outs.ldConfBlock.storePath
    check paths[2] == outs.gdmService.storePath
    check paths[3] == outs.sessionDesktopEntry.storePath

# ---------------------------------------------------------------------------
# NDE-G DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/desktop-environments/gnome/repro.nim`` actually
# exercises the new DSL surface (M3 ``files <name>:`` blocks + M8/M9.A
# ``fs.configFile`` / ``fs.managedBlock`` + M9.C ``service:`` block)
# rather than silently regressing to the legacy "shim does everything"
# shape. These are extra assertions on top of the v1 surface — the v1
# structural assertions above stay intact.
# ---------------------------------------------------------------------------

suite "NDE-G1 GNOME compositor DSL surface":

  test "recipe registers exactly 4 files: artifacts":
    let arts = registeredArtifacts("gnomeDesktop")
    check arts.len == 4

  test "every recipe artifact is dakFiles":
    let arts = registeredArtifacts("gnomeDesktop")
    for a in arts:
      check a.kind == dakFiles

  test "recipe artifact names cover every emitted file":
    let arts = registeredArtifacts("gnomeDesktop")
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "gdmConfig"            in names
    check "ldConfContribution"   in names
    check "gdmService"           in names
    check "sessionDesktopEntry"  in names

  test "M9.C service displayManager: records the systemd-unit metadata surface":
    # Pins the M9.C extended service: block. The recipe declares
    # description / `type` / execStart / wantedBy / after; the M5+M9.C
    # parser captures every one verbatim into the DslServiceDef
    # registry.
    let svcs = registeredServices("gnomeDesktop")
    check svcs.len == 1
    let svc = svcs[0]
    check svc.serviceName == "displayManager"
    check svc.description == "GNOME Display Manager"
    check svc.serviceType == "notify"
    check svc.execStart   == "/usr/sbin/gdm3"
    check svc.wantedBy    == @["graphical.target"]
    check svc.after       == @["systemd-user-sessions.service"]
    # No ``executable <ident>`` setter → both the legacy
    # ``executableRef`` and the new ``executable`` alias stay empty.
    check svc.executable == ""
    check svc.executableRef == ""
    check svc.args.len == 0

  test "sentinel triple-form via DSL surface: libpaths block uses packageName=gnome, blockId=libpaths":
    # Same sentinel guard as the shim-side test above, but exercised
    # through the DSL's M9.A ``consumeManagedBlock`` materialiser to
    # confirm the recipe's ``fs.managedBlock(...)`` call carries the
    # cohort-wide identifiers verbatim.
    let root = createTempDir("ndeg1_dsl_sentinel_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let ldConf = consumeLdConfDsl()
    let bytes = readDslStoreFile(ldConf)

    let expectOpen = "# >>> repro:system:gnome:libpaths >>>"
    let expectClose = "# <<< repro:system:gnome:libpaths <<<"

    check expectOpen in bytes
    check expectClose in bytes
    check bytes.find(expectOpen) < bytes.find(expectClose)
    # M9.A sha256 hashes are 64 lower-hex chars.
    check ldConf.hashHex.len == 64
    # Sanity: the store path is rooted under the override.
    check ldConf.storePath.startsWith(root)

  test "cascade-G fix via DSL surface: gdm.service planted at /usr/lib/systemd/system/":
    # The cascade-G assertion through the DSL surface. The M9.A
    # ``consumeConfigFile`` materialiser drops the leading / when
    # canonicalising the host path to the store-relative ``relPath``.
    let root = createTempDir("ndeg1_dsl_unit_path_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let svc = consumeGdmServiceDsl()
    check svc.relPath ==
      "usr/lib/systemd/system/gdm.service"
    check fileExists(svc.storePath /
                     "usr/lib/systemd/system/gdm.service")
    check not fileExists(svc.storePath /
                         "lib/systemd/system/gdm.service")
    # M9.A sha256 hashes are 64 lower-hex chars.
    check svc.hashHex.len == 64

  test "DSL surface: /etc/gdm3/custom.conf has AutomaticLogin line + propagates via DSL configurables":
    # End-to-end propagation: setConfigurable(...) → re-register →
    # consumeConfigFile reads the materialised bytes. Mirrors the
    # NDE-F sway DSL-surface propagation test.
    let root = createTempDir("ndeg1_dsl_gdmconfig_", "")
    defer: removeDir(root)

    # Pass A — default (autoLoginUser = "repro").
    resetRecipeState(root)
    let cfgA = consumeGdmConfigDsl()
    let bytesA = readDslStoreFile(cfgA)
    check "AutomaticLogin=repro" in bytesA
    check "AutomaticLogin=alice" notin bytesA

    # Pass B — flip autoLoginUser to "alice" via setConfigurable.
    setConfigurable[string](
      "gnomeDesktop.autoLoginUser", "alice")
    reregisterWithCurrentConfigurables(root)
    let cfgB = consumeGdmConfigDsl()
    let bytesB = readDslStoreFile(cfgB)
    check "AutomaticLogin=alice" in bytesB
    check "AutomaticLogin=repro" notin bytesB

    # Store paths differ; the snapshot-independent unit + xdg outputs
    # stay cached.
    check cfgA.storePath != cfgB.storePath
    # Reset autoLoginUser for hygiene.
    resetConfigurable("gnomeDesktop.autoLoginUser")

  test "anchor constants: NDE-G1 libpaths identifiers match shim exports":
    # The cohort-wide identifiers for the libpaths overlay are sourced
    # from the shim's exported constants so a future rename / priority
    # bump propagates from one place. The recipe MUST NOT hardcode
    # "libpaths" / 500 / "gnome" — this test pins that contract.
    check NdeG1LibpathsBlockId  == "libpaths"
    check NdeG1LibpathsPriority == 500
    check NdeG1PackageName      == "gnome"

    # And the recipe's registered contribution carries exactly those
    # values verbatim.
    let root = createTempDir("ndeg1_anchor_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let contribs = registeredManagedBlocks(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check contribs.len == 1
    let c = contribs[0]
    check c.blockId     == NdeG1LibpathsBlockId
    check c.priority    == NdeG1LibpathsPriority
    check c.packageName == NdeG1PackageName
    check c.scope       == bsSystem

  test "multi-contributor merge: NDE-D graphics-stack (priority=100) sorts BEFORE gnome (priority=500)":
    # The load-bearing NDE-G cohort-overlay test. NDE-D pinned the
    # ordering invariant from the ANCHOR side. NDE-F pinned it from the
    # sway OVERLAY side. NDE-G now pins it from the GNOME overlay side:
    # the recipe's priority=500 contribution is already registered by
    # ``resetRecipeState``; we add a synthetic priority=100
    # graphics-stack contribution alongside and assert the merger sorts
    # (priority, packageName, blockId) ascending so graphics-stack
    # (priority=100) appears BEFORE gnome (priority=500) per the spec
    # §"Block ordering rule".
    let root = createTempDir("ndeg1_merge_", "")
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
    # gnome overlay per the spec's ``(priority, packageName, blockId)``
    # rule.
    let merged =
      mergedManagedBlockFile("/etc/ld.so.conf.d/00-reproos-linux.conf")

    let gfxOpen   = "# >>> repro:system:graphics-stack:libpaths-anchor >>>"
    let gnomeOpen = "# >>> repro:system:gnome:libpaths >>>"

    check gfxOpen in merged
    check gnomeOpen in merged
    # Graphics-stack's sentinel MUST appear before gnome's — the
    # load-bearing NDE-G overlay-side invariant.
    check merged.find(gfxOpen) < merged.find(gnomeOpen)
    # Both sentinel pairs close.
    check "# <<< repro:system:graphics-stack:libpaths-anchor <<<" in merged
    check "# <<< repro:system:gnome:libpaths <<<" in merged
    # The graphics-stack anchor stub is present.
    check "gfxAnchorStub" in merged
    # And gnome's lib-dir contribution is present.
    check "/usr/lib/x86_64-linux-gnu" in merged

    # The merger registered both contributors. ``registeredManagedBlocks``
    # returns insertion order; sort discipline lives in
    # ``mergedManagedBlockFile`` itself.
    let contribs = registeredManagedBlocks(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check contribs.len == 2

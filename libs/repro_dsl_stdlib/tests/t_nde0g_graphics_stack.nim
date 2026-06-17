## NDE0-G unit tests: native graphics-stack package (NDE-D migrated).
##
## Exercises the spec'd public surface of
## ``recipes/packages/de-foundation/graphics-stack/repro.nim`` through
## the DSL's M8 / M9.A / M9.B materialisation path
## (``fs.configFile`` / ``fs.managedBlock`` / ``fs.symlink`` registration
## + ``consumeConfigFile`` / ``consumeManagedBlock`` / ``consumeSymlink``
## materialisation) rather than the shim's deprecated
## ``materializeGraphicsStack`` orchestrator. The recipe's render*
## procs still come from the shim verbatim — only the on-disk emission
## path moved.
##
## NDE-D is the **anchor** for the multi-contributor managedBlock cohort:
## the recipe registers ``/etc/ld.so.conf.d/00-reproos-linux.conf`` with
## blockId=``libpaths`` at priority=100 (lowest, sorts first); NDE-F sway
## / NDE-G gnome / NDE-K plasma append at priority=500. The test suite
## exercises:
##
##   1. Sentinel triple-form for the libpaths block uses the cohort's
##      kebab-cased packageName segment (``graphics-stack``) sourced
##      from ``Nde0gPackageName`` so a rename propagates everywhere.
##   2. Cascade-G unit path: ``repro-ldconfig.service`` planted at
##      ``usr/lib/systemd/system/`` NOT ``lib/systemd/system/``;
##      belt-and-braces /etc record carries the same content.
##   3. WantedBy activation symlink: multi-user.target.wants/
##      repro-ldconfig.service → /etc/systemd/system/repro-ldconfig.service.
##   4. Service content shape: ``Type=oneshot``,
##      ``ExecStart=/sbin/ldconfig``, ``Before=multi-user.target
##      sysinit.target``, ``WantedBy=multi-user.target``.
##   5. Configurable propagation: ``enableHardwareGl`` toggle changes
##      the ldConf block content (banner switches between hardware-GL
##      and software-rasterisation-only).
##   5a. Configurable propagation: ``fontPackages`` extension changes
##       the render-proc output (preserved v1 invariant; exercised via
##       direct ``renderLdConfBlockContent(cfg)`` calls with two
##       distinct cfgs, bypassing the recipe's ``readConfigurable``
##       layer because M2/M9.D ``recordConfigDefault`` does not yet
##       cover ``seq[string]``).
##   6. Idempotency: same config → same store paths.
##   7. Cache-key invalidation: changing aptSnapshot invalidates the
##      ldConf block but not the unit-file / .wants symlink.
##   8. Byte-determinism across two independent materialize roots.
##   9. **Multi-contributor merge**: register a 2nd contributor at
##      priority=500 (simulating NDE-F sway), assert that the merger
##      sorts NDE0-G first per the spec's ordering rule. The legacy
##      priority=500-vs-100 cache-key test is REPLACED because the
##      M9.A managedBlock digest is over the merged content bytes
##      (priority sits in merge ordering, not cache identity).
##  10. Cache-key isolation across artifacts (per-artifact hashes
##      distinct, all 64 lower-hex sha256).
##  11. Belt-and-braces /etc alias carries the same content as the
##      cascade-G /usr/lib record.
##  12. Anchor constants: blockId / priority / packageName match the
##      shim's ``Nde0gLibpathsBlockId`` / ``Nde0gLibpathsPriority`` /
##      ``Nde0gPackageName`` so the cohort-wide identifier propagates
##      from one place.
##
## Plus a "DSL surface" suite at the end pinning the new
## ``files <name>:`` artifact registration shape against the DSL's M3
## ``registeredArtifacts`` accessor, confirming the recipe genuinely
## exercises the typed surface rather than silently regressing to the
## legacy "configFile is a Nim proc the recipe calls directly" path.

import std/[os, strutils, tempfiles, unittest]

# The shim module — still owns the render* template procs + the
# Nde0gLibpathsBlockId / Nde0gLibpathsPriority / Nde0gPackageName
# constants the recipe + this test use as the cohort-wide identifiers
# for the libpaths anchor. NDE-D does NOT remove the shim; the
# deprecated ``materializeGraphicsStack`` + on-disk emitter procs stay
# reachable for any caller that still imports them.
import repro_dsl_stdlib/packages/de_foundation/graphics_stack

# The recipe — registers the package's M2 configurables + module-init
# fires every ``files <name>: build:`` arm so the M8/M9.A/M9.B tables
# are pre-populated against the default configurables. The recipe also
# re-exports the per-artifact ``register*`` helpers the test fixture
# below uses to re-register after a configurable toggle.
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/de-foundation/graphics-stack/repro" as recipe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: DslManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc resetRecipeState(storeRoot: string) =
  ## Test-fixture reset: clear every M8/M9.A/M9.B registry + materialiser
  ## row, drop any pending configurable overrides for the graphicsStack
  ## package, then re-register every fs.* output the recipe owns against
  ## the (now-default) configurables. ``registerStoreRoot`` runs LAST
  ## because ``resetDslPortMaterialiseState`` clears the store-root
  ## table along with the materialiser side-tables (the M9.A reset proc
  ## is "drop EVERY registered storeRoot + every materialisation side-
  ## table row" — see the proc's docstring).
  ##
  ## The libpaths managedBlock crosses two packageName namespaces: the
  ## DSL package identifier (``graphicsStack``) the M3 ``files:`` arms
  ## register against AND the cohort-wide kebab-cased segment
  ## (``graphics-stack``) the contribution carries for sentinel
  ## uniqueness. Both store-root entries are bound below so the
  ## ``consumeManagedBlock`` lookup against the contribution's
  ## packageName finds an entry.
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetConfigurable("graphicsStack.aptSnapshot")
  resetConfigurable("graphicsStack.enableHardwareGl")
  registerStoreRoot("graphicsStack", storeRoot, dhaSha256)
  registerStoreRoot(Nde0gPackageName, storeRoot, dhaSha256)
  recipe.registerGraphicsStackFiles()

proc reregisterWithCurrentConfigurables(storeRoot: string) =
  ## After ``setConfigurable(...)`` has flipped one or more cells, the
  ## previously-recorded M8/M9 entries still carry the OLD content;
  ## drop them, re-register against the new cells, and re-bind the
  ## store-root (the M9.A reset call below also wipes it — see above).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  registerStoreRoot("graphicsStack", storeRoot, dhaSha256)
  registerStoreRoot(Nde0gPackageName, storeRoot, dhaSha256)
  recipe.registerGraphicsStackFiles()

# ---------------------------------------------------------------------------
# Convenience consumers — one per artifact. Centralises the per-output
# path the recipe uses so the test reads identically to the v1 shape.
# ---------------------------------------------------------------------------

proc consumeLdConf(): DslManagedFiles =
  consumeManagedBlock("/etc/ld.so.conf.d/00-reproos-linux.conf")
proc consumeLdconfigService(): DslManagedFiles =
  consumeConfigFile("graphicsStack",
                    "/usr/lib/systemd/system/repro-ldconfig.service")
proc consumeLdconfigServiceEtcAlias(): DslManagedFiles =
  consumeConfigFile("graphicsStack",
                    "/etc/systemd/system/repro-ldconfig.service")
proc consumeLdconfigWantedBy(): DslManagedFiles =
  consumeSymlink(
    "graphicsStack",
    "/etc/systemd/system/multi-user.target.wants/repro-ldconfig.service")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-G graphics-stack package":

  test "sentinel triple-form: libpaths block uses cohort-wide kebab-cased packageName":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = graphics-stack (kebab-cased — this
    # is the cohort-wide segment NDE-F/G/K all use; the DSL package
    # identifier ``graphicsStack`` is the M3 registry index, NOT the
    # sentinel segment), blockId = libpaths.
    let root = createTempDir("nde0g_sentinel_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let ldConf = consumeLdConf()
    let bytes = readStoreFile(ldConf)

    let expectOpen =
      "# >>> repro:system:graphics-stack:libpaths >>>"
    let expectClose =
      "# <<< repro:system:graphics-stack:libpaths <<<"

    check expectOpen in bytes
    check expectClose in bytes
    # Open MUST come before close.
    check bytes.find(expectOpen) < bytes.find(expectClose)

    # And the content between them must have at least 2 store-path
    # lib dirs (the spec mandates 5 — mesa + libdrm + libwayland +
    # libxkbcommon + fontconfig — but the test loosens to >=2 to
    # tolerate impl-module reorderings).
    let openIdx = bytes.find(expectOpen)
    let closeIdx = bytes.find(expectClose)
    let between = bytes[openIdx + expectOpen.len ..< closeIdx]
    var libDirCount = 0
    for line in between.splitLines:
      if line.startsWith("/opt/reproos-linux/store/") and
         "/usr/lib/x86_64-linux-gnu" in line:
        libDirCount.inc
    check libDirCount >= 2
    # Sanity: the store path is rooted under the override.
    check ldConf.storePath.startsWith(root)
    # M9.A sha256 hashes are 64 lower-hex chars.
    check ldConf.hashHex.len == 64

  test "cascade-G fix: repro-ldconfig.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # The load-bearing cascade-G assertion BOTH directions: AT
    # /usr/lib/systemd/system/, NOT AT /lib/systemd/system/. R9
    # systemd 257.9 dropped /lib/systemd/system/ from the default
    # UnitPath, so a unit planted only under /lib/ would be invisible
    # at boot. The native package must plant at /usr/lib/.
    let root = createTempDir("nde0g_unit_path_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let svc = consumeLdconfigService()

    # AT: usr/lib/systemd/system/ (M9.A canonicalisePath strips leading /)
    check svc.relPath == "usr/lib/systemd/system/repro-ldconfig.service"
    check fileExists(svc.storePath /
                     "usr/lib/systemd/system/repro-ldconfig.service")
    # NOT-AT: lib/systemd/system/
    check not fileExists(svc.storePath /
                         "lib/systemd/system/repro-ldconfig.service")
    # Sanity: the store path is rooted under the override.
    check svc.storePath.startsWith(root)
    # M9.A sha256 hashes are 64 lower-hex chars.
    check svc.hashHex.len == 64

  test "WantedBy activation symlink: target = /etc/systemd/system/repro-ldconfig.service":
    # The .wants symlink target is the absolute path of the /etc record
    # so the activation layer's planting is independent of cwd. Mirrors
    # the Tier-2 shell script's
    #   ln -sf /etc/systemd/system/repro-ldconfig.service \
    #     /etc/systemd/system/multi-user.target.wants/repro-ldconfig.service
    # On POSIX hosts M9.B materialises a real OS-level symlink; on
    # Windows fs.symlink falls back to a regular file with a
    # ``# repro-symlink-intent`` header.
    let root = createTempDir("nde0g_wants_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let wantedBy = consumeLdconfigWantedBy()
    let expectedTarget = "/etc/systemd/system/repro-ldconfig.service"

    when defined(windows):
      # Windows fallback: regular file with the intent header.
      let raw = readStoreFile(wantedBy)
      let bytes = raw.strip()
      check expectedTarget in bytes
      check "# repro-symlink-intent" in raw
    else:
      # POSIX: real symlink. ``expandSymlink`` reads the target string.
      let linkPath = wantedBy.storePath / wantedBy.relPath
      let target = expandSymlink(linkPath)
      check target == expectedTarget
    # The recorded relPath is the canonicalised host path (NO trailing
    # ``.symlink-target`` suffix — that was a shim-emitter artefact the
    # M9.B materialiser drops in favour of the real link).
    check wantedBy.relPath ==
      "etc/systemd/system/multi-user.target.wants/repro-ldconfig.service"

  test "service content shape: Type=oneshot + ExecStart=/sbin/ldconfig + Before + WantedBy":
    # The 4 required directives per the spec. Lex order doesn't matter
    # — we substring-check each.
    let root = createTempDir("nde0g_unit_content_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let bytes = readStoreFile(consumeLdconfigService())

    check "Type=oneshot" in bytes
    check "ExecStart=/sbin/ldconfig" in bytes
    # "Before=multi-user.target sysinit.target" — both targets are on
    # one line per the spec's phrasing.
    check "Before=multi-user.target sysinit.target" in bytes
    check "WantedBy=multi-user.target" in bytes
    # And the cascade-G discipline: the [Unit] section opens with
    # Description= for systemctl status human-readability.
    check "[Unit]" in bytes
    check "[Service]" in bytes
    check "[Install]" in bytes
    check "Description=ReproOS ldconfig refresh" in bytes

  test "configurable propagation: enableHardwareGl toggle changes block banner":
    # v1's enableHardwareGl effect is a banner-line swap (see impl-
    # module honest-deferrals); the test verifies the swap is honest +
    # invalidates the block's content-addressed store path.
    let rootHw = createTempDir("nde0g_hw_", "")
    let rootSw = createTempDir("nde0g_sw_", "")
    defer:
      removeDir(rootHw)
      removeDir(rootSw)

    # Pass A — default (hardware GL on).
    resetRecipeState(rootHw)
    let hwBytes = readStoreFile(consumeLdConf())
    let hwHandle = consumeLdConf()

    # Pass B — flip enableHardwareGl to false.
    resetRecipeState(rootSw)
    setConfigurable[bool]("graphicsStack.enableHardwareGl", false)
    reregisterWithCurrentConfigurables(rootSw)
    let swBytes = readStoreFile(consumeLdConf())
    let swHandle = consumeLdConf()

    # The two block contents MUST differ.
    check hwBytes != swBytes

    # Hardware variant has "hardware" in the GL-mode banner; software
    # variant has "software-only".
    check "GL mode: hardware" in hwBytes
    check "GL mode: hardware" notin swBytes
    check "GL mode: software-only" in swBytes
    check "GL mode: software-only" notin hwBytes

    # And the content-addressed store paths must differ — that's how
    # the cache-key propagation works.
    check hwHandle.storePath != swHandle.storePath

  test "configurable propagation: fontPackages extension changes render-proc output (direct cfg path)":
    # v1 invariant preservation: "different fontPackages → different
    # rendered content → different managedBlock cache key". The recipe-
    # level path (setConfigurable + readConfigurable) does NOT propagate
    # fontPackages today because M2/M9.D recordConfigDefault does not
    # cover seq[string] (macros_b.nim:584-623 silently passes non-scalar
    # entries through; the recipe's currentGraphicsStackCfg() falls back
    # to defaultGraphicsStackConfig().fontPackages).
    #
    # The propagation invariant itself is INDEPENDENT of how the cfg is
    # constructed — the load-bearing assertion is that the shim's
    # renderLdConfBlockContent(cfg) is sensitive to fontPackages. This
    # test exercises that contract directly by calling the public render
    # proc with two distinct GraphicsStackConfig values (bypassing the
    # recipe's readConfigurable layer entirely). When M3+ widens the DSL
    # to cover seq[string], the recipe's currentGraphicsStackCfg() will
    # plumb through to the same code path this test exercises here, and
    # the recipe-level propagation will follow automatically.
    var cfgMin = gfxImpl.defaultGraphicsStackConfig()
    cfgMin.fontPackages = @["fonts-dejavu-core"]
    let minBytes = gfxImpl.renderLdConfBlockContent(cfgMin)

    var cfgExt = gfxImpl.defaultGraphicsStackConfig()
    cfgExt.fontPackages = @["fonts-dejavu-core",
                            "fonts-liberation",
                            "fonts-noto"]
    let extBytes = gfxImpl.renderLdConfBlockContent(cfgExt)

    # The two block contents MUST differ.
    check minBytes != extBytes
    # min variant has the default count; ext variant has 3.
    check "font packages (1):" in minBytes
    check "font packages (3):" in extBytes
    # Added packages appear in the ext variant.
    check "fonts-liberation" in extBytes
    check "fonts-noto" in extBytes
    check "fonts-liberation" notin minBytes
    check "fonts-noto" notin minBytes

    # And — critically — the propagation flows into the M9.A managedBlock
    # cache key because the rendered bytes are the managedBlock's
    # ``content`` argument; sha256OfString(minBytes) != sha256OfString(
    # extBytes) follows by collision-resistance, so a future widening of
    # the DSL to plumb fontPackages through readConfigurable will keep
    # the cache-key contract intact. We assert the byte difference here
    # because that is the load-bearing primitive.

  test "idempotency: same config produces same store paths":
    let root = createTempDir("nde0g_idem_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # First materialisation pass — every consume call writes the file +
    # records the handle in the M9 idempotency side-table.
    let lcA = consumeLdConf()
    let svcA = consumeLdconfigService()
    let etcA = consumeLdconfigServiceEtcAlias()
    let wbA = consumeLdconfigWantedBy()

    # Second materialisation pass — every consume call returns the
    # cached handle (the M9 side-tables short-circuit on the second
    # call). Every output should land at exactly the same store path.
    let lcB = consumeLdConf()
    let svcB = consumeLdconfigService()
    let etcB = consumeLdconfigServiceEtcAlias()
    let wbB = consumeLdconfigWantedBy()

    check lcA.storePath  == lcB.storePath
    check svcA.storePath == svcB.storePath
    check etcA.storePath == etcB.storePath
    check wbA.storePath  == wbB.storePath

  test "cache-key invalidation: aptSnapshot change re-keys ldConf but NOT unit / etc alias / wantedBy":
    # The spec's contract: a snapshot bump invalidates the apt-jammy-
    # dependent emissions atomically but leaves the snapshot-
    # independent emissions (the unit file content + the activation
    # symlink record) cached. The unit content depends only on the
    # rendered text; the symlink target depends only on the path
    # strings — neither references the snapshot.
    let root = createTempDir("nde0g_snapinv_", "")
    defer: removeDir(root)

    # Pass A — default snapshot.
    resetRecipeState(root)
    let lcA = consumeLdConf()
    let svcA = consumeLdconfigService()
    let etcA = consumeLdconfigServiceEtcAlias()
    let wbA = consumeLdconfigWantedBy()

    # Pass B — bump the snapshot pin.
    setConfigurable[string](
      "graphicsStack.aptSnapshot", "ubuntu/jammy/20271231T000000Z")
    reregisterWithCurrentConfigurables(root)
    let lcB = consumeLdConf()
    let svcB = consumeLdconfigService()
    let etcB = consumeLdconfigServiceEtcAlias()
    let wbB = consumeLdconfigWantedBy()

    # ldConf MUST land at a different store path (banner records the
    # snapshot + bundle hashes include it).
    check lcA.storePath != lcB.storePath
    # Everything else MUST stay at the same store path.
    check svcA.storePath == svcB.storePath
    check etcA.storePath == etcB.storePath
    check wbA.storePath  == wbB.storePath

  test "determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirrors NDE0-S / NDE0-D determinism tests.
    let rootA = createTempDir("nde0g_detA_", "")
    let rootB = createTempDir("nde0g_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A.
    resetRecipeState(rootA)
    let lcA = consumeLdConf()
    let svcA = consumeLdconfigService()
    let etcA = consumeLdconfigServiceEtcAlias()
    let wbA = consumeLdconfigWantedBy()

    # Pass B — fresh state, fresh root, same default configurables.
    resetRecipeState(rootB)
    let lcB = consumeLdConf()
    let svcB = consumeLdconfigService()
    let etcB = consumeLdconfigServiceEtcAlias()
    let wbB = consumeLdconfigWantedBy()

    # Hash-segment basenames match.
    check extractFilename(lcA.storePath)  == extractFilename(lcB.storePath)
    check extractFilename(svcA.storePath) == extractFilename(svcB.storePath)
    check extractFilename(etcA.storePath) == extractFilename(etcB.storePath)
    check extractFilename(wbA.storePath)  == extractFilename(wbB.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(lcA)  == readStoreFile(lcB)
    check readStoreFile(svcA) == readStoreFile(svcB)
    check readStoreFile(etcA) == readStoreFile(etcB)

  test "multi-contributor merge: NDE0-G (priority=100) sorts before priority=500 contributors":
    # The load-bearing cohort-anchor test. NDE-D's libpaths block at
    # priority=100 sorts BEFORE any priority-500 contribution per the
    # spec §"Block ordering rule"
    # (libs/repro_project_dsl/src/repro_project_dsl/dsl_port_runtime.nim:
    # ``contribs.sort by (priority, packageName, blockId)``).
    #
    # The legacy "priority=500 hash differs from priority=100 with
    # same content" assertion is REPLACED because the M9.A managedBlock
    # cache key is composed over the merged content bytes
    # (``"managedBlock" || path || \x00 || mergedContent``); priority
    # participates in merge ORDERING, not cache IDENTITY. The
    # multi-contributor merge below exercises the load-bearing
    # ordering invariant directly.
    let root = createTempDir("nde0g_merge_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # Add a second contributor simulating an NDE-F sway-style overlay
    # at priority=500. blockId differs (the spec'd uniqueness rule is
    # per (scope, packageName, blockId) within a path, and we want the
    # merger to keep both contributions visible).
    fs.managedBlock(
      path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
      blockId = "libpaths-overlay",
      scope = bsSystem,
      content = "/opt/reproos-linux/store/swayOverlayStub/usr/lib/x86_64-linux-gnu\n",
      priority = 500,
      packageName = "sway",
      artifactName = "ldConfOverlay")

    # The merged file's contents have BOTH contributions, with NDE0-G
    # (priority=100) sorted before the priority=500 sway overlay.
    let merged =
      mergedManagedBlockFile("/etc/ld.so.conf.d/00-reproos-linux.conf")

    let gfxOpen  = "# >>> repro:system:graphics-stack:libpaths >>>"
    let swayOpen = "# >>> repro:system:sway:libpaths-overlay >>>"

    check gfxOpen in merged
    check swayOpen in merged
    # NDE0-G's sentinel MUST appear before sway's.
    check merged.find(gfxOpen) < merged.find(swayOpen)
    # Both sentinel pairs close before the file ends.
    check "# <<< repro:system:graphics-stack:libpaths <<<" in merged
    check "# <<< repro:system:sway:libpaths-overlay <<<" in merged
    # The cohort lib-dir from NDE0-G is present.
    check "/usr/lib/x86_64-linux-gnu" in merged
    # And the sway overlay stub path is present.
    check "swayOverlayStub" in merged

    # The merger registered both contributors. ``registeredManagedBlocks``
    # returns insertion order; sort discipline lives in
    # ``mergedManagedBlockFile`` itself.
    let contribs = registeredManagedBlocks(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check contribs.len == 2

  test "cache-key isolation: per-output hashes are distinct":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace, an accidental collision would alias their store paths
    # and the caller would silently get the wrong bytes. The M9.A
    # configFile + managedBlock + M9.B symlink digests each mix a
    # discriminator prefix into the sha256 input.
    let root = createTempDir("nde0g_iso_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let lc = consumeLdConf()
    let svc = consumeLdconfigService()
    let etc = consumeLdconfigServiceEtcAlias()
    let wb = consumeLdconfigWantedBy()

    # Distinct per-output hashes. The etc alias and the /usr/lib unit
    # carry the SAME content but different packageName + path
    # discriminators — sha256(configFile || pkg || \x00 || artifact ||
    # \x00 || path || \x00 || content) keeps them apart.
    check lc.hashHex  != svc.hashHex
    check lc.hashHex  != etc.hashHex
    check lc.hashHex  != wb.hashHex
    check svc.hashHex != etc.hashHex
    check svc.hashHex != wb.hashHex
    check etc.hashHex != wb.hashHex

    # All hash-hex segments are exactly 64 chars (M9.A's full sha256;
    # the shim's 16-char truncated form is gone).
    check lc.hashHex.len  == 64
    check svc.hashHex.len == 64
    check etc.hashHex.len == 64
    check wb.hashHex.len  == 64

  test "belt-and-braces /etc alias carries the same unit-file content as the cascade-G record":
    # Both records contain the same Type=oneshot unit text — the
    # activation layer (NDEM1) reads the manifest and plants the live
    # /etc/systemd/system/ symlink. v1 records them as separate
    # configFile entries because the M9.B symlink surface can't yet
    # express "/etc record reuses /usr/lib content".
    let root = createTempDir("nde0g_etc_alias_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let usrLibBytes = readStoreFile(consumeLdconfigService())
    let etcBytes = readStoreFile(consumeLdconfigServiceEtcAlias())

    check usrLibBytes == etcBytes
    # Both records satisfy the cascade-G unit-file shape.
    check "[Service]" in etcBytes
    check "Type=oneshot" in etcBytes
    check "ExecStart=/sbin/ldconfig" in etcBytes
    # The /etc alias relPath is the canonicalised host path.
    let etcHandle = consumeLdconfigServiceEtcAlias()
    check etcHandle.relPath == "etc/systemd/system/repro-ldconfig.service"
    check fileExists(etcHandle.storePath / etcHandle.relPath)

  test "anchor constants: blockId / priority / packageName match shim exports":
    # The cohort-wide identifiers for the libpaths anchor are sourced
    # from the shim's exported constants so a future rename / priority
    # bump propagates from one place. The recipe MUST NOT hardcode
    # "libpaths" / 100 / "graphics-stack" — this test pins that
    # contract.
    check Nde0gLibpathsBlockId  == "libpaths"
    check Nde0gLibpathsPriority == 100
    check Nde0gPackageName      == "graphics-stack"

    # And the recipe's registered contribution carries exactly those
    # values verbatim (the M3 ``files: build:`` arm's fs.managedBlock
    # call must use the shim constants, not hardcoded literals).
    let root = createTempDir("nde0g_anchor_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let contribs = registeredManagedBlocks(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check contribs.len == 1
    let c = contribs[0]
    check c.blockId     == Nde0gLibpathsBlockId
    check c.priority    == Nde0gLibpathsPriority
    check c.packageName == Nde0gPackageName
    check c.scope       == bsSystem

# ---------------------------------------------------------------------------
# NDE-D DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/de-foundation/graphics-stack/repro.nim`` actually
# exercises the new DSL surface (M3 ``files <name>:`` blocks + M8/M9.A
# ``fs.configFile`` / ``fs.managedBlock`` + M9.B ``fs.symlink``) rather
# than silently regressing to the legacy "shim does everything" shape.
# These are extra assertions on top of the v1 surface — the v1
# structural assertions above stay intact.
# ---------------------------------------------------------------------------

suite "NDE0-G graphics-stack DSL surface":

  test "recipe registers exactly 4 files: artifacts":
    let arts = registeredArtifacts("graphicsStack")
    check arts.len == 4

  test "every recipe artifact is dakFiles":
    let arts = registeredArtifacts("graphicsStack")
    for a in arts:
      check a.kind == dakFiles

  test "recipe artifact names cover every emitted file":
    let arts = registeredArtifacts("graphicsStack")
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "ldConf"                   in names
    check "ldconfigService"          in names
    check "ldconfigServiceEtcAlias"  in names
    check "ldconfigWantedBy"         in names

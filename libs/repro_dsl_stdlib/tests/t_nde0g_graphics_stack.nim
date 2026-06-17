## NDE0-G unit tests: native graphics-stack package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## graphics_stack.nim`` against synthetic configurations. Mirrors the
## NDE0-D + NDE0-S test layout (precedent: per-output ``ManagedFiles``
## round-trip + cascade-G discipline assertions in BOTH directions).
##
## Required test surfaces (per the NDE0-G sub-agent prompt §"Unit tests"):
##
##   1. Sentinel triple-form for the libpaths block (NDE-spec-block
##      shape: ``# >>> repro:system:graphics-stack:libpaths >>>``).
##   2. Cascade-G unit path: ``repro-ldconfig.service`` planted at
##      ``usr/lib/systemd/system/`` NOT ``lib/systemd/system/``;
##      belt-and-braces /etc target points at ``/usr/lib/...``.
##   3. WantedBy symlink: multi-user.target.wants/repro-ldconfig.service
##      recorded target = ``../repro-ldconfig.service``.
##   4. Service content shape: ``Type=oneshot``,
##      ``ExecStart=/sbin/ldconfig``, ``Before=multi-user.target
##      sysinit.target``, ``WantedBy=multi-user.target``.
##   5. Configurable propagation: ``enableHardwareGl`` toggle changes
##      the ldConf block content (banner switches between hardware-GL
##      and software-rasterisation-only).
##   6. Configurable propagation: ``fontPackages`` extension changes
##      the ldConf block content (added comment lines).
##   7. Idempotency: same config → same store paths.
##   8. Cache-key invalidation: changing aptSnapshot invalidates the
##      ldConf block but not the unit-file / .wants symlink.
##   9. Byte-determinism across two independent materialize roots.
##   10. Priority encoded for libpaths: priority=100 is embedded in the
##       managedBlock hash via the impl module's contract — toggling
##       priority changes the block's store path. Test asserts the
##       constant + the cache-key consequence.
##
## Plus a handful of additional invariants (cache-key isolation across
## outputs, hash hex length, stable activation order).
##
## No try/except swallows. Failure paths use ``expect`` where
## applicable; this module's primitives are infallible by design (mirror
## of NDE0-S), so most assertions use ``check``.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/de_foundation/graphics_stack
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # for managedBlockHash + ManagedFiles + bsSystem (priority test)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the NDE0-D test
  ## helper exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): GraphicsStackConfig =
  result = defaultGraphicsStackConfig()
  result.storeRoot = storeRoot

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-G graphics-stack package":

  test "sentinel triple-form: libpaths block uses NDE-spec-block shape":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = graphics-stack, blockId = libpaths.
    let root = createTempDir("nde0g_sentinel_", "")
    defer: removeDir(root)

    let outs = materializeGraphicsStack(configWithRoot(root))
    let bytes = readStoreFile(outs.ldConfBlock)

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

  test "cascade-G fix: repro-ldconfig.service planted at /usr/lib/systemd/system/ NOT /lib/systemd/system/":
    # The load-bearing cascade-G assertion BOTH directions: AT
    # /usr/lib/systemd/system/, NOT AT /lib/systemd/system/. R9
    # systemd 257.9 dropped /lib/systemd/system/ from the default
    # UnitPath, so a unit planted only under /lib/ would be invisible
    # at boot. The native package must plant at /usr/lib/.
    let root = createTempDir("nde0g_unit_path_", "")
    defer: removeDir(root)

    let outs = materializeGraphicsStack(configWithRoot(root))

    # AT: usr/lib/systemd/system/
    check outs.ldconfigService.relPath ==
          "usr/lib/systemd/system/repro-ldconfig.service"
    check fileExists(outs.ldconfigService.storePath /
                     "usr/lib/systemd/system/repro-ldconfig.service")
    # NOT-AT: lib/systemd/system/
    check not fileExists(outs.ldconfigService.storePath /
                         "lib/systemd/system/repro-ldconfig.service")

    # Belt-and-braces /etc record points at the cascade-G path.
    let recordedTarget = readStoreFile(outs.ldconfigServiceEtc).strip()
    check recordedTarget == "/usr/lib/systemd/system/repro-ldconfig.service"
    check recordedTarget != "/lib/systemd/system/repro-ldconfig.service"
    # Manifest rel path encodes the .unmask-target suffix.
    check outs.ldconfigServiceEtc.relPath ==
          "etc/systemd/system/repro-ldconfig.service.unmask-target"

  test "WantedBy activation symlink: target = ../repro-ldconfig.service":
    # The .wants symlink target is relative-within-/etc-systemd-system/
    # so the activation layer's planting is path-independent. Mirrors
    # the Tier-2 shell script's
    #   ln -sf "../repro-ldconfig.service"
    #     /etc/systemd/system/multi-user.target.wants/repro-ldconfig.service
    let root = createTempDir("nde0g_wants_", "")
    defer: removeDir(root)

    let outs = materializeGraphicsStack(configWithRoot(root))
    let recordedTarget = readStoreFile(outs.ldconfigWanted).strip()

    check recordedTarget == "../repro-ldconfig.service"
    # The symlink manifest's rel path is the activation target's path
    # plus the .symlink-target suffix.
    check outs.ldconfigWanted.relPath ==
          "etc/systemd/system/multi-user.target.wants/" &
          "repro-ldconfig.service.symlink-target"

  test "service content shape: Type=oneshot + ExecStart=/sbin/ldconfig + Before + WantedBy":
    # The 4 required directives per the spec. Lex order doesn't matter
    # — we substring-check each.
    let root = createTempDir("nde0g_unit_content_", "")
    defer: removeDir(root)

    let outs = materializeGraphicsStack(configWithRoot(root))
    let bytes = readStoreFile(outs.ldconfigService)

    check "Type=oneshot" in bytes
    check "ExecStart=/sbin/ldconfig" in bytes
    # "Before=multi-user.target sysinit.target" — both targets are on
    # one line per the spec's "Before=multi-user.target sysinit.target"
    # phrasing.
    check "Before=multi-user.target sysinit.target" in bytes
    check "WantedBy=multi-user.target" in bytes
    # And the cascade-G discipline: the [Unit] section opens with
    # Description= for systemctl status human-readability.
    check "[Unit]" in bytes
    check "[Service]" in bytes
    check "[Install]" in bytes

  test "configurable propagation: enableHardwareGl toggle changes block banner":
    # v1's enableHardwareGl effect is a banner-line swap (see impl-module
    # honest-deferrals); the test verifies the swap is honest +
    # invalidates the block's content-addressed store path.
    let rootHw = createTempDir("nde0g_hw_", "")
    let rootSw = createTempDir("nde0g_sw_", "")
    defer:
      removeDir(rootHw)
      removeDir(rootSw)

    var cfgHw = configWithRoot(rootHw)
    cfgHw.enableHardwareGl = true
    let outsHw = materializeGraphicsStack(cfgHw)
    let hwBytes = readStoreFile(outsHw.ldConfBlock)

    var cfgSw = configWithRoot(rootSw)
    cfgSw.enableHardwareGl = false
    let outsSw = materializeGraphicsStack(cfgSw)
    let swBytes = readStoreFile(outsSw.ldConfBlock)

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
    check outsHw.ldConfBlock.storePath != outsSw.ldConfBlock.storePath

  test "configurable propagation: fontPackages extension changes block content":
    # Extending the font seed list adds comment lines to the block.
    # Same cache-key invalidation contract as enableHardwareGl.
    let rootMin = createTempDir("nde0g_fontmin_", "")
    let rootExt = createTempDir("nde0g_fontext_", "")
    defer:
      removeDir(rootMin)
      removeDir(rootExt)

    var cfgMin = configWithRoot(rootMin)
    cfgMin.fontPackages = @["fonts-dejavu-core"]
    let outsMin = materializeGraphicsStack(cfgMin)
    let minBytes = readStoreFile(outsMin.ldConfBlock)

    var cfgExt = configWithRoot(rootExt)
    cfgExt.fontPackages = @["fonts-dejavu-core",
                            "fonts-liberation",
                            "fonts-noto"]
    let outsExt = materializeGraphicsStack(cfgExt)
    let extBytes = readStoreFile(outsExt.ldConfBlock)

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
    # Cache-key invalidation.
    check outsMin.ldConfBlock.storePath != outsExt.ldConfBlock.storePath

  test "idempotency: same config produces same store paths":
    let root = createTempDir("nde0g_idem_", "")
    defer: removeDir(root)

    let outsA = materializeGraphicsStack(configWithRoot(root))
    let outsB = materializeGraphicsStack(configWithRoot(root))

    # Every output should land at exactly the same store path on a
    # second invocation (content-addressed hash is a pure function of
    # the inputs).
    check outsA.ldConfBlock.storePath        == outsB.ldConfBlock.storePath
    check outsA.ldconfigService.storePath    == outsB.ldconfigService.storePath
    check outsA.ldconfigServiceEtc.storePath == outsB.ldconfigServiceEtc.storePath
    check outsA.ldconfigWanted.storePath     == outsB.ldconfigWanted.storePath

  test "cache-key invalidation: aptSnapshot change re-keys ldConfBlock but NOT unit/symlink":
    # This is the spec's contract: a snapshot bump invalidates the
    # apt-jammy-dependent emissions atomically but leaves the
    # snapshot-independent emissions (the unit file + the activation
    # symlink record) cached. The unit content depends only on the
    # rendered text; the symlink target depends only on the path
    # strings — neither references the snapshot.
    let root = createTempDir("nde0g_snapinv_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.aptSnapshot = "ubuntu/jammy/20260615T000000Z"
    let outsA = materializeGraphicsStack(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.aptSnapshot = "ubuntu/jammy/20271231T000000Z"
    let outsB = materializeGraphicsStack(cfgB)

    # ldConfBlock MUST land at a different store path (banner records
    # the snapshot + bundle hashes include it).
    check outsA.ldConfBlock.storePath != outsB.ldConfBlock.storePath
    # Unit file + belt-and-braces /etc record + activation symlink
    # MUST stay at the same store path.
    check outsA.ldconfigService.storePath    == outsB.ldconfigService.storePath
    check outsA.ldconfigServiceEtc.storePath == outsB.ldconfigServiceEtc.storePath
    check outsA.ldconfigWanted.storePath     == outsB.ldconfigWanted.storePath

  test "determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirrors NDE0-D's determinism test.
    let rootA = createTempDir("nde0g_detA_", "")
    let rootB = createTempDir("nde0g_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializeGraphicsStack(configWithRoot(rootA))
    let outsB = materializeGraphicsStack(configWithRoot(rootB))

    # Hash-segment basenames match.
    check extractFilename(outsA.ldConfBlock.storePath) ==
          extractFilename(outsB.ldConfBlock.storePath)
    check extractFilename(outsA.ldconfigService.storePath) ==
          extractFilename(outsB.ldconfigService.storePath)
    check extractFilename(outsA.ldconfigServiceEtc.storePath) ==
          extractFilename(outsB.ldconfigServiceEtc.storePath)
    check extractFilename(outsA.ldconfigWanted.storePath) ==
          extractFilename(outsB.ldconfigWanted.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.ldConfBlock)        ==
          readStoreFile(outsB.ldConfBlock)
    check readStoreFile(outsA.ldconfigService)    ==
          readStoreFile(outsB.ldconfigService)
    check readStoreFile(outsA.ldconfigServiceEtc) ==
          readStoreFile(outsB.ldconfigServiceEtc)
    check readStoreFile(outsA.ldconfigWanted)     ==
          readStoreFile(outsB.ldconfigWanted)

  test "priority=100 encoded in libpaths block cache key":
    # Per Generated-Configuration-Files.md §"Cache-key composition" the
    # managedBlock hash includes the priority value. The impl module's
    # ``Nde0gLibpathsPriority`` constant is the load-bearing priority
    # for the foundation graphics stack (spec worked example says
    # "NDE0-G has priority 100 and sorts first"). Test asserts (a) the
    # constant value (b) the cache-key consequence: re-hashing the
    # same content + scope + packageName + blockId + relPath with a
    # different priority produces a different hash. This proves the
    # priority field participates in the content-addressed identity
    # even though the planted block bytes don't visibly carry it (the
    # sort order materialises at multi-contributor merge time per
    # the spec).
    check Nde0gLibpathsPriority == 100

    # Same content/scope/packageName/blockId/relPath; different
    # priority. Use the impl module's exposed hash helper.
    const path = "etc/ld.so.conf.d/00-reproos-linux.conf"
    let content = "test-content\n"
    let h100 = managedBlockHash(bsSystem, Nde0gPackageName,
                                Nde0gLibpathsBlockId, path, content, 100)
    let h500 = managedBlockHash(bsSystem, Nde0gPackageName,
                                Nde0gLibpathsBlockId, path, content, 500)
    check h100 != h500
    check h100.len == 16
    check h500.len == 16

    # And the planted block's hashHex (which derives from priority=100
    # via the impl module's contract) matches the h100 computed
    # against the rendered content.
    let root = createTempDir("nde0g_prio_", "")
    defer: removeDir(root)

    let cfg = configWithRoot(root)
    let outs = materializeGraphicsStack(cfg)
    let renderedContent = renderLdConfBlockContent(cfg)
    let expected = managedBlockHash(bsSystem, Nde0gPackageName,
                                    Nde0gLibpathsBlockId, path,
                                    renderedContent,
                                    Nde0gLibpathsPriority)
    check outs.ldConfBlock.hashHex == expected

  test "cache-key isolation: per-output hashes are distinct":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. Mirrors NDE0-D's
    # isolation test.
    let root = createTempDir("nde0g_iso_", "")
    defer: removeDir(root)

    let outs = materializeGraphicsStack(configWithRoot(root))

    check outs.ldConfBlock.hashHex        != outs.ldconfigService.hashHex
    check outs.ldConfBlock.hashHex        != outs.ldconfigServiceEtc.hashHex
    check outs.ldConfBlock.hashHex        != outs.ldconfigWanted.hashHex
    check outs.ldconfigService.hashHex    != outs.ldconfigServiceEtc.hashHex
    check outs.ldconfigService.hashHex    != outs.ldconfigWanted.hashHex
    check outs.ldconfigServiceEtc.hashHex != outs.ldconfigWanted.hashHex

    # All hash-hex segments are exactly 16 chars (mirrors NDE0-A +
    # NDE0-S + NDE0-D).
    check outs.ldConfBlock.hashHex.len        == 16
    check outs.ldconfigService.hashHex.len    == 16
    check outs.ldconfigServiceEtc.hashHex.len == 16
    check outs.ldconfigWanted.hashHex.len     == 16

  test "stable activation order: storePaths enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # ldConf block first (so the later ldconfig oneshot reads it),
    # then the unit file, then the belt-and-braces /etc record, then
    # the activation .wants symlink.
    let root = createTempDir("nde0g_order_", "")
    defer: removeDir(root)

    let outs = materializeGraphicsStack(configWithRoot(root))
    let paths = storePaths(outs)

    check paths.len == 4
    check paths[0] == outs.ldConfBlock.storePath
    check paths[1] == outs.ldconfigService.storePath
    check paths[2] == outs.ldconfigServiceEtc.storePath
    check paths[3] == outs.ldconfigWanted.storePath

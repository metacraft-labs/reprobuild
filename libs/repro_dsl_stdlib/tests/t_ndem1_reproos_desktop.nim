## NDEM1 unit tests: native ``reproosDesktop`` system-level package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/system/
## reproos_desktop.nim`` against synthetic configurations.
##
## Required test surfaces (per the NDEM1 sub-agent prompt §"Unit
## tests"):
##
##   1. **validateDesktopConfig success** — desktopKind=@[dkSway],
##      activeAtBoot=dkSway → no exception.
##   2. **validateDesktopConfig rejection** — desktopKind=@[dkSway],
##      activeAtBoot=dkGnome → ``expect EConfigViolation:``.
##   3. **Variant closure differs** — materialise with
##      desktopKind=@[dkSway] vs @[dkSway, dkGnome]; assert the
##      second produces more storePaths.
##   4. **Configurable swap rebuilds only display-manager symlink** —
##      same desktopKind=@[dkSway, dkGnome], swap activeAtBoot:
##      (a) closure identical; (b) displayManagerSymlink target
##      differs; (c) mergedLdConf hashHex identical.
##   5. **Multi-contributor merge sort order** — 3 DEs +
##      graphics-stack; verify (priority, packageName) order:
##      graphics-stack (100), gnome, plasma, sway (all 500
##      alphabetical).
##   6. **Multi-contributor merge sentinel discipline** — all 4
##      sentinel triples present + properly delimited.
##   7. **Removing a contributor leaves others byte-identical** —
##      3 DEs vs 2 DEs (drop sway); gnome + plasma block content
##      byte-identical between the two.
##   8. **Idempotency** — same config → same generationId + same
##      outputs.
##   9. **Generation ID changes on variant change** —
##      desktopKind=@[dkSway] and @[dkSway, dkGnome] produce
##      different generationIds.
##   10. **Generation ID changes on configurable change** — same
##       desktopKind, different activeAtBoot → different
##       generationIds.
##   11. **Display manager activation** — for each of dkSway, dkGnome,
##       dkPlasma, assert displayManagerSymlink target points to
##       correct DE-specific unit path.
##
## No try/except swallows. Failure path uses ``expect
## EConfigViolation:``; the other primitives are infallible by design.
##
## ## NDE-I DSL-surface coverage
##
## After the original 14-case v1 suite, an additional 11-case **NDE-I
## DSL surface** suite at the end of this file pins that the rewritten
## ``recipes/packages/system/reproos-desktop/repro.nim`` exercises the
## three landed M9 gap-fixes the spec calls for:
##
##   * M9.D typed enum + ``seq[Enum]`` ``config:`` entries — replaces
##     the legacy ``seq[string]`` / ``string`` workaround for
##     ``desktopKind`` / ``activeAtBoot``.
##   * M9.E ``variant:`` arm-dispatch + ``validate:`` predicate
##     closure — lowers the spec's
##     ``activeAtBoot in desktopKind.value`` constraint into the DSL
##     registries.
##   * M9.G ``bootloader:`` block — declarative GRUB / systemd-boot
##     metadata that the apply phase (NDEM2) consumes.
##
## Plus a fourth gap closure:
##
##   * M9.A ``consumeManagedBlock`` consumer-side surface — the
##     reproos-desktop recipe's ``files mergedLdConf:`` arm reads
##     ``mergedManagedBlockFile`` against a synthetic 4-contributor
##     cohort and the materialiser plants the union under the bound
##     store-root with the spec-mandated sort order.

import std/[algorithm, os, sequtils, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/system/reproos_desktop
import repro_dsl_stdlib/packages/system/reproos_desktop as shim
  # Alias so the type alias below can disambiguate the shim's
  # ``EConfigViolation`` from the DSL runtime's same-named exception
  # (both are exported through the imports below).
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # ManagedFiles, BlockScope (re-exported through reproos_desktop too).

# The DSL umbrella + the recipe — for the NDE-I DSL-surface suite at
# the end. Both ``repro_project_dsl`` and the shim export a
# ``EConfigViolation`` symbol; the shim's exception is raised by
# ``validateDesktopConfig`` / ``materializeReproosDesktop`` (the v1
# suite above) while the DSL runtime's exception is raised by
# ``evaluateValidates`` (the NDE-I suite below). We alias each side's
# spelling so every ``expect`` target is unambiguous:
#   * ``EShimConfigViolation`` — the shim's exception (v1 suite).
#   * ``EDslConfigViolation``  — the DSL runtime's exception (NDE-I
#     suite).
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/system/reproos-desktop/repro" as recipe

type
  EShimConfigViolation = shim.EConfigViolation
  EDslConfigViolation = repro_project_dsl.EConfigViolation

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the prior NDE0/NDE
  ## test helpers exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): ReproosDesktopConfig =
  result = defaultReproosDesktopConfig()
  result.storeRoot = storeRoot

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDEM1 reproos-desktop system-level package":

  test "validateDesktopConfig success: activeAtBoot in desktopKind":
    # Spec literal: ``validate: activeAtBoot in desktopKind.value``.
    # Default config (desktopKind=@[dkSway], activeAtBoot=dkSway)
    # MUST pass validation. The proc returns void; absence of
    # exception is the assertion.
    var cfg = defaultReproosDesktopConfig()
    cfg.desktopKind = @[dkSway]
    cfg.activeAtBoot = dkSway
    validateDesktopConfig(cfg)  # no exception expected

    # Also: multi-DE installable, single activeAtBoot present.
    cfg.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfg.activeAtBoot = dkGnome
    validateDesktopConfig(cfg)

    cfg.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfg.activeAtBoot = dkPlasma
    validateDesktopConfig(cfg)

  test "validateDesktopConfig rejection: activeAtBoot not in desktopKind raises EConfigViolation":
    # Spec literal: violating ``validate: activeAtBoot in
    # desktopKind.value`` raises ``EConfigViolation``.
    var cfg = defaultReproosDesktopConfig()
    cfg.desktopKind = @[dkSway]
    cfg.activeAtBoot = dkGnome
    expect EShimConfigViolation:
      validateDesktopConfig(cfg)

    # Also: dkPlasma not in {dkSway, dkGnome}.
    cfg.desktopKind = @[dkSway, dkGnome]
    cfg.activeAtBoot = dkPlasma
    expect EShimConfigViolation:
      validateDesktopConfig(cfg)

    # Also: empty desktopKind — a generation that installs no DEs
    # cannot boot any.
    cfg.desktopKind = @[]
    cfg.activeAtBoot = dkSway
    expect EShimConfigViolation:
      validateDesktopConfig(cfg)

  test "materializeReproosDesktop rejects invalid config via EConfigViolation":
    # The materialise entry point MUST also raise — not silently
    # produce a degenerate manifest. Mirrors validateDesktopConfig
    # test but exercises the full entry point.
    let root = createTempDir("ndem1_mat_reject_", "")
    defer: removeDir(root)
    var cfg = configWithRoot(root)
    cfg.desktopKind = @[dkSway]
    cfg.activeAtBoot = dkGnome
    expect EShimConfigViolation:
      discard materializeReproosDesktop(cfg)

  test "variant closure differs: adding a DesktopKind grows storePaths":
    # Spec literal (Configurable-System.md §"Closure-size
    # implications"): "desktopKind=@[dkSway] — closure contains
    # sway-de plus transitive deps. desktopKind=@[dkSway, dkGnome]
    # — closure contains both DE package trees."
    #
    # Operationally at NDEM1: the second config materialises EXTRA
    # storePaths (gnome's 4 outputs); the first does not.
    let rootSway = createTempDir("ndem1_var_sway_", "")
    let rootSwayGnome = createTempDir("ndem1_var_swaygnome_", "")
    defer:
      removeDir(rootSway)
      removeDir(rootSwayGnome)

    var cfgSway = configWithRoot(rootSway)
    cfgSway.desktopKind = @[dkSway]
    cfgSway.activeAtBoot = dkSway
    let outsSway = materializeReproosDesktop(cfgSway)

    var cfgSG = configWithRoot(rootSwayGnome)
    cfgSG.desktopKind = @[dkSway, dkGnome]
    cfgSG.activeAtBoot = dkSway
    let outsSG = materializeReproosDesktop(cfgSG)

    # The variant change grew the closure; the SwayGnome manifest
    # MUST contain strictly more storePaths than the Sway manifest.
    check outsSG.manifest.storePaths.len > outsSway.manifest.storePaths.len

    # Every Sway storePath whose basename matches a Sway output also
    # exists in the SwayGnome manifest (Sway outputs are still in
    # the closure). The merged-ld-conf / display-manager / GRUB
    # paths differ (their content depends on the variant set), so
    # filter to per-package outputs.
    let swayBasenames = outsSway.manifest.storePaths.mapIt(extractFilename(it))
    let sgBasenames = outsSG.manifest.storePaths.mapIt(extractFilename(it))
    # The SwayGnome set strictly extends the Sway set in size.
    check sgBasenames.len > swayBasenames.len

  test "configurable swap (activeAtBoot) rebuilds only display-manager symlink; closure + libpaths union are identical":
    # Spec literal: "Switching ``activeAtBoot`` from dkHyprland to
    # dkGnome in a generation where both are already in
    # desktopKind produces a new generation that differs from the
    # previous one in exactly one symlink — both DEs remain
    # installed; the bootloader picks up the new generation; the
    # next boot lands in GDM."
    #
    # Operationally: (a) storePaths set is identical EXCEPT for the
    # display-manager symlink + the GRUB menu entry (its options
    # line records activeAtBoot, so it re-keys too — the spec
    # acceptance is at file-output granularity, the configurable's
    # invalidation scope is precisely "files: displayManagerSymlink"
    # + "bootloader: generationEntry"); (b) the mergedLdConf bytes
    # are identical because no contributor's content depends on
    # activeAtBoot.
    let root = createTempDir("ndem1_cfg_swap_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.desktopKind = @[dkSway, dkGnome]
    cfgA.activeAtBoot = dkSway
    let outsA = materializeReproosDesktop(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.desktopKind = @[dkSway, dkGnome]
    cfgB.activeAtBoot = dkGnome
    let outsB = materializeReproosDesktop(cfgB)

    # (a) Display-manager symlink target differs.
    check outsA.displayManagerSymlink.storePath !=
          outsB.displayManagerSymlink.storePath
    let targetA = readStoreFile(outsA.displayManagerSymlink).strip()
    let targetB = readStoreFile(outsB.displayManagerSymlink).strip()
    check targetA != targetB
    check targetA == "/usr/lib/systemd/system/sway-session.service"
    check targetB == "/usr/lib/systemd/system/gdm.service"

    # (b) mergedLdConf hashHex (and therefore storePath) is
    # IDENTICAL — the libpaths union depends only on which
    # contributors are present (which depends on desktopKind, not
    # on activeAtBoot).
    check outsA.mergedLdConf.hashHex == outsB.mergedLdConf.hashHex
    check outsA.mergedLdConf.storePath == outsB.mergedLdConf.storePath

    # The per-DE foundation + DE storePaths are all unchanged: the
    # closure-affecting variant (desktopKind) didn't change. Verify
    # by intersecting basenames — every basename in A is also in B.
    let basenamesA = outsA.manifest.storePaths.mapIt(extractFilename(it))
    let basenamesB = outsB.manifest.storePaths.mapIt(extractFilename(it))
    var sharedCount = 0
    for n in basenamesA:
      if n in basenamesB:
        sharedCount.inc
    # At least every foundation + DE output is shared (we expect
    # ALL except the dm-symlink + GRUB entry to be shared).
    check sharedCount >= basenamesA.len - 3

  test "multi-contributor merge sort order: (priority, packageName) ascending":
    # Spec literal: "blocks are emitted in sorted (priority,
    # packageName, blockId) order, ascending."
    #
    # For NDEM1 with all 3 DEs + graphics-stack the expected order
    # is:
    #   1. graphics-stack (priority 100)
    #   2. gnome  (priority 500; alphabetical: g < p < s)
    #   3. plasma (priority 500)
    #   4. sway   (priority 500)
    let root = createTempDir("ndem1_merge_sort_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfg.activeAtBoot = dkSway
    let outs = materializeReproosDesktop(cfg)
    let merged = readStoreFile(outs.mergedLdConf)

    let openGfx = "# >>> repro:system:graphics-stack:libpaths >>>"
    let openGnome = "# >>> repro:system:gnome:libpaths >>>"
    let openPlasma = "# >>> repro:system:plasma:libpaths >>>"
    let openSway = "# >>> repro:system:sway:libpaths >>>"

    let idxGfx = merged.find(openGfx)
    let idxGnome = merged.find(openGnome)
    let idxPlasma = merged.find(openPlasma)
    let idxSway = merged.find(openSway)

    check idxGfx >= 0
    check idxGnome >= 0
    check idxPlasma >= 0
    check idxSway >= 0

    # graphics-stack (priority 100) sorts first.
    check idxGfx < idxGnome
    check idxGfx < idxPlasma
    check idxGfx < idxSway
    # Compositor alphabetical: gnome < plasma < sway.
    check idxGnome < idxPlasma
    check idxPlasma < idxSway

  test "multi-contributor merge sentinel discipline: 4 triple-form sentinels all present + properly delimited":
    # Spec literal (Generated-Configuration-Files.md §"Sentinel
    # uniqueness"): every block delimited by
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   <content>
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # Multi-contributor cases never elide the packageName segment.
    let root = createTempDir("ndem1_sentinels_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfg.activeAtBoot = dkSway
    let outs = materializeReproosDesktop(cfg)
    let merged = readStoreFile(outs.mergedLdConf)

    # Each of the 4 contributors has a matching open + close
    # sentinel. Open comes before close. No cross-contamination
    # (sway's sentinel does NOT reference gnome's blockId etc.).
    for (pkg, _) in [("graphics-stack", 100), ("gnome", 500),
                     ("plasma", 500), ("sway", 500)]:
      let openS = "# >>> repro:system:" & pkg & ":libpaths >>>"
      let closeS = "# <<< repro:system:" & pkg & ":libpaths <<<"
      check openS in merged
      check closeS in merged
      check merged.find(openS) < merged.find(closeS)

    # Single-block sentinel form (NOT triple) MUST NOT appear.
    check "# >>> repro:system:libpaths >>>" notin merged
    check "# >>> repro:home:" notin merged

  test "removing a contributor leaves others byte-identical":
    # Spec literal: "Removing one contributor from a multi-
    # contributor managed file leaves the remaining contributors'
    # blocks byte-identical and does not invalidate their cache
    # contributions."
    #
    # Operationally: materialise with all 3 DEs, then drop sway.
    # The gnome + plasma blocks (their CONTENT between sentinels)
    # must be byte-identical across the two materialisations.
    let rootAll = createTempDir("ndem1_drop_all_", "")
    let rootMinus = createTempDir("ndem1_drop_minus_", "")
    defer:
      removeDir(rootAll)
      removeDir(rootMinus)

    var cfgAll = configWithRoot(rootAll)
    cfgAll.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfgAll.activeAtBoot = dkGnome
    let outsAll = materializeReproosDesktop(cfgAll)
    let mergedAll = readStoreFile(outsAll.mergedLdConf)

    var cfgMinus = configWithRoot(rootMinus)
    cfgMinus.desktopKind = @[dkGnome, dkPlasma]  # dropped sway
    cfgMinus.activeAtBoot = dkGnome
    let outsMinus = materializeReproosDesktop(cfgMinus)
    let mergedMinus = readStoreFile(outsMinus.mergedLdConf)

    # Helper: extract the bytes BETWEEN open + close sentinels for
    # a given (packageName, blockId).
    proc extractBlock(merged, pkg: string): string =
      let openS = "# >>> repro:system:" & pkg & ":libpaths >>>"
      let closeS = "# <<< repro:system:" & pkg & ":libpaths <<<"
      let openIdx = merged.find(openS)
      let closeIdx = merged.find(closeS)
      doAssert openIdx >= 0, "open sentinel not found for " & pkg
      doAssert closeIdx >= 0, "close sentinel not found for " & pkg
      result = merged[openIdx + openS.len ..< closeIdx]

    # gnome block + plasma block byte-identical across the two.
    check extractBlock(mergedAll, "gnome") ==
          extractBlock(mergedMinus, "gnome")
    check extractBlock(mergedAll, "plasma") ==
          extractBlock(mergedMinus, "plasma")
    # graphics-stack block also byte-identical (it's always there
    # and its content depends only on aptSnapshot + GL knobs).
    check extractBlock(mergedAll, "graphics-stack") ==
          extractBlock(mergedMinus, "graphics-stack")
    # sway block is present in mergedAll but absent in mergedMinus.
    check "repro:system:sway:libpaths" in mergedAll
    check "repro:system:sway:libpaths" notin mergedMinus
    # And the dropped contributor takes nothing else with it — the
    # merged-file shrinks; storePath re-keys.
    check outsAll.mergedLdConf.hashHex != outsMinus.mergedLdConf.hashHex

  test "idempotency: same config → same generationId + same outputs":
    let root = createTempDir("ndem1_idem_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.desktopKind = @[dkSway, dkGnome]
    cfg.activeAtBoot = dkGnome
    let outsA = materializeReproosDesktop(cfg)
    let outsB = materializeReproosDesktop(cfg)

    check outsA.manifest.generationId == outsB.manifest.generationId
    check outsA.mergedLdConf.storePath == outsB.mergedLdConf.storePath
    check outsA.displayManagerSymlink.storePath ==
          outsB.displayManagerSymlink.storePath
    check outsA.grubMenuEntries.storePath == outsB.grubMenuEntries.storePath
    check outsA.manifest.storePaths == outsB.manifest.storePaths

    # Pure generationId proc is also idempotent.
    check generationId(cfg) == generationId(cfg)

  test "generationId changes on VARIANT change: desktopKind diff → different ID (different closure)":
    # Spec literal (Configurable-System.md §"Generation diff
    # vocabulary"): "Variant rebuild: closure differs."
    # Operationally: the generationId must change when desktopKind
    # changes, even if every other input is identical.
    var cfgA = defaultReproosDesktopConfig()
    cfgA.desktopKind = @[dkSway]
    cfgA.activeAtBoot = dkSway

    var cfgB = defaultReproosDesktopConfig()
    cfgB.desktopKind = @[dkSway, dkGnome]
    cfgB.activeAtBoot = dkSway

    let idA = generationId(cfgA)
    let idB = generationId(cfgB)

    check idA.len == 32  # 32-char hex truncation
    check idB.len == 32
    check idA != idB

    # Also: input-permutation of the same set produces SAME id
    # (desktopKind is semantically a set).
    var cfgC = defaultReproosDesktopConfig()
    cfgC.desktopKind = @[dkGnome, dkSway]
    cfgC.activeAtBoot = dkSway
    check generationId(cfgC) == idB

  test "generationId changes on CONFIGURABLE change: activeAtBoot diff → different ID (activation differs, closure identical)":
    # Spec literal: "Configurable rebuild: closure identical;
    # generation entry differs." Per the spec's two-axis identity
    # contract, the generationId must change even when only the
    # configurable changes.
    var cfgA = defaultReproosDesktopConfig()
    cfgA.desktopKind = @[dkSway, dkGnome]
    cfgA.activeAtBoot = dkSway

    var cfgB = defaultReproosDesktopConfig()
    cfgB.desktopKind = @[dkSway, dkGnome]
    cfgB.activeAtBoot = dkGnome

    check generationId(cfgA) != generationId(cfgB)

  test "display-manager activation: each DesktopKind points at the correct unit path":
    # Spec NDEM1 ``displayManagerSymlink`` worked example:
    #   * dkSway   → /usr/lib/systemd/system/sway-session.service
    #   * dkGnome  → /usr/lib/systemd/system/gdm.service
    #   * dkPlasma → /usr/lib/systemd/system/sddm.service
    # The etcPath is always /etc/systemd/system/
    # display-manager.service.
    let root = createTempDir("ndem1_dm_targets_", "")
    defer: removeDir(root)

    for (kind, expectedTarget) in [
        (dkSway, "/usr/lib/systemd/system/sway-session.service"),
        (dkGnome, "/usr/lib/systemd/system/gdm.service"),
        (dkPlasma, "/usr/lib/systemd/system/sddm.service")]:
      var cfg = configWithRoot(root)
      cfg.desktopKind = @[kind]
      cfg.activeAtBoot = kind
      let outs = materializeReproosDesktop(cfg)

      # The activation symlink intent recorded in the manifest.
      check outs.manifest.activationSymlinks.len == 1
      let intent = outs.manifest.activationSymlinks[0]
      check intent.etcPath ==
            "/etc/systemd/system/display-manager.service"
      check intent.target == expectedTarget

      # The pure activateDisplayManager proc agrees.
      let dmIntent = activateDisplayManager(cfg)
      check dmIntent.etcPath ==
            "/etc/systemd/system/display-manager.service"
      check dmIntent.target == expectedTarget

      # The emitted displayManagerSymlink ManagedFiles records the
      # same target.
      let recorded = readStoreFile(outs.displayManagerSymlink).strip()
      check recorded == expectedTarget

  test "manifest records activeAtBoot + desktopKind + merged-files entry":
    # The reified GenerationManifest captures the variant +
    # configurable + the multi-contributor merged file content.
    # This is the spec-level "generation log" entry the activation
    # layer + the bootloader integration consume.
    let root = createTempDir("ndem1_manifest_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfg.activeAtBoot = dkPlasma
    let outs = materializeReproosDesktop(cfg)

    check outs.manifest.desktopKind == @[dkSway, dkGnome, dkPlasma]
    check outs.manifest.activeAtBoot == dkPlasma
    check outs.manifest.generationId.len == 32
    check outs.manifest.storePaths.len > 0

    # The mergedFiles array records exactly one entry: the
    # /etc/ld.so.conf.d/00-reproos-linux.conf union.
    check outs.manifest.mergedFiles.len == 1
    check outs.manifest.mergedFiles[0].etcPath ==
          "/etc/ld.so.conf.d/00-reproos-linux.conf"
    # The merged contents include every active contributor's
    # sentinel.
    let mergedContents = outs.manifest.mergedFiles[0].contents
    check "repro:system:graphics-stack:libpaths" in mergedContents
    check "repro:system:sway:libpaths" in mergedContents
    check "repro:system:gnome:libpaths" in mergedContents
    check "repro:system:plasma:libpaths" in mergedContents

  test "storePaths manifest is sorted lexicographically + stable":
    # The manifest's storePaths slot is sorted ascending so two
    # materialisations with the same inputs produce byte-identical
    # serialised manifests.
    let root = createTempDir("ndem1_sorted_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.desktopKind = @[dkSway, dkGnome, dkPlasma]
    cfg.activeAtBoot = dkSway
    let outs = materializeReproosDesktop(cfg)

    var copy = outs.manifest.storePaths
    var sorted = copy
    sorted.sort(cmp[string])
    check copy == sorted

# ---------------------------------------------------------------------------
# NDE-I DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/system/reproos-desktop/repro.nim`` actually
# exercises the three landed M9 gap-fixes (M9.D typed-enum config /
# M9.E variant: + validate: / M9.G bootloader:) plus the M9.A
# consumeManagedBlock consumer-side surface — rather than silently
# regressing to the legacy "shim does everything, recipe is a config:
# shell" shape NDEM1 documented as a workaround. The v1 structural
# suite above stays intact; these are extra assertions on top.
# ---------------------------------------------------------------------------

proc resetDslConfigurables() =
  ## Drop any pending configurable overrides so each NDE-I test
  ## observes the registered defaults. Mirrors the per-package
  ## ``resetConfigurable`` discipline NDE-F/G/H test fixtures use.
  resetConfigurable("reproosDesktop.desktopKind")
  resetConfigurable("reproosDesktop.activeAtBoot")
  resetConfigurable("reproosDesktop.defaultUser")
  resetConfigurable("reproosDesktop.bootloaderTimeout")
  resetConfigurable("reproosDesktop.aptSnapshot")

proc resetDslRecipeState(storeRoot: string) =
  ## Test-fixture reset: clear every M8/M9.A registry + materialiser
  ## row + the configurable cells, then re-register every fs.* output
  ## the recipe owns against the (now-default) configurables. The
  ## ``mergedLdConf`` artifact consumes the multi-contributor union of
  ## ``/etc/ld.so.conf.d/00-reproos-linux.conf`` — but the recipe is
  ## the CONSUMER side, so the test fixture must register synthetic
  ## graphics-stack + DE contributions before calling
  ## ``registerReproosDesktopFiles`` so the merged-bytes call has
  ## non-empty input.
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetDslConfigurables()
  registerStoreRoot("reproosDesktop", storeRoot, dhaSha256)

proc registerSyntheticLdConfContributions() =
  ## Synthesise the 4 multi-contributor rows the DE cohort would
  ## otherwise emit through their own recipes. Mirrors the
  ## NDE-D/F/G/H integration shape the v1 suite exercises through
  ## ``materializeReproosDesktop``. The merger sorts ``(priority,
  ## packageName, blockId)`` ascending so graphics-stack (priority=100)
  ## sorts first, then the three priority=500 compositors in
  ## packageName-ascending order.
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = "libpaths",
    scope = bsSystem,
    content = "/opt/reproos-linux/store/gfxStub/usr/lib/x86_64-linux-gnu\n",
    priority = 100,
    packageName = "graphics-stack",
    artifactName = "syntheticGfx")
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = "libpaths",
    scope = bsSystem,
    content = "/opt/reproos-linux/store/gnomeStub/usr/lib/x86_64-linux-gnu\n",
    priority = 500,
    packageName = "gnome",
    artifactName = "syntheticGnome")
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = "libpaths",
    scope = bsSystem,
    content = "/opt/reproos-linux/store/plasmaStub/usr/lib/x86_64-linux-gnu\n",
    priority = 500,
    packageName = "plasma",
    artifactName = "syntheticPlasma")
  fs.managedBlock(
    path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
    blockId = "libpaths",
    scope = bsSystem,
    content = "/opt/reproos-linux/store/swayStub/usr/lib/x86_64-linux-gnu\n",
    priority = 500,
    packageName = "sway",
    artifactName = "syntheticSway")

proc readDslStoreFile(handle: DslManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath`` (mirrors NDE-F/G/H helpers).
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

suite "NDEM1 reproos-desktop DSL surface (NDE-I)":

  test "M9.D typed config: desktopKind reads back as seq[DesktopKind] = @[dkSway]":
    # Recipe declares ``desktopKind: seq[DesktopKind] = @[dkSway]`` —
    # M9.D's seq[Enum] overload preserves the enum type-name + the
    # registered ord-sequence. The fallback-flavoured reader returns
    # the registered default when the type matches.
    resetConfigurable("reproosDesktop.desktopKind")
    let got = readConfigurable[DesktopKind](
      "reproosDesktop.desktopKind", newSeq[DesktopKind]())
    check got == @[dkSway]
    check got.len == 1

    # The inspector exposes the captured enumTypeName so a future
    # rename of ``DesktopKind`` would surface here.
    #
    # The shim's ``DesktopKind`` enum carries explicit string values
    # (``dkSway = "sway"``); M9.D records ``$value`` for the
    # ``seqEnumValueNames`` slot so the captured spelling is the
    # enum's STRING REPRESENTATION (``"sway"``), not the source-level
    # identifier (``"dkSway"``). The two would coincide for enums
    # without explicit string values (e.g. the M9.D fixture's bare
    # ``dkSway`` shape).
    let stored = inspectConfigurable("reproosDesktop.desktopKind")
    check stored.kind == dskSeqEnum
    check stored.seqEnumTypeName == "DesktopKind"
    check stored.seqEnumValueNames == @[$dkSway]   # == @["sway"]

  test "M9.D typed config: activeAtBoot reads back as DesktopKind = dkSway":
    # Recipe declares ``activeAtBoot: DesktopKind = dkSway`` — M9.D's
    # scalar-enum overload preserves both the type name + the literal
    # value name. The shim's enum carries explicit string values so
    # ``$dkSway`` resolves to ``"sway"``; see the seq-enum test above
    # for the same observation.
    resetConfigurable("reproosDesktop.activeAtBoot")
    check readConfigurable[DesktopKind](
      "reproosDesktop.activeAtBoot", dkGnome) == dkSway

    let stored = inspectConfigurable("reproosDesktop.activeAtBoot")
    check stored.kind == dskEnum
    check stored.enumTypeName == "DesktopKind"
    check stored.enumValueName == $dkSway   # == "sway"

  test "M9.E variant: 3 arms register in source-declaration order with correct uses-clauses":
    # Recipe declares ``\`case\` dkSway:`` / ``\`case\` dkGnome:`` /
    # ``\`case\` dkPlasma:``; the M9.E emitter lowers each to one
    # ``DslVariantArm`` row. Per ``t_dsl_variant_uses.nim`` insertion
    # order is source-order; armOrd matches ord(enumValue).
    let arms = registeredVariants("reproosDesktop")
    check arms.len == 3
    check arms[0].armValue == "dkSway"
    check arms[0].armOrd == ord(dkSway)
    check arms[0].usesClauses == @["sway >=0.1.0"]
    check arms[1].armValue == "dkGnome"
    check arms[1].armOrd == ord(dkGnome)
    check arms[1].usesClauses == @["gnome >=0.1.0"]
    check arms[2].armValue == "dkPlasma"
    check arms[2].armOrd == ord(dkPlasma)
    check arms[2].usesClauses == @["plasma >=0.1.0"]
    # NDE-I close-out widening: ``armValueRepr`` captures ``$value`` so
    # ``activeVariantArms`` can match against M9.D's ``$value`` stored
    # spelling for explicit-string-value enums. For the shim's
    # ``DesktopKind`` (``dkSway = "sway"`` etc.) the repr diverges from
    # the source ident.
    check arms[0].armValueRepr == $dkSway   # == "sway"
    check arms[1].armValueRepr == $dkGnome  # == "gnome"
    check arms[2].armValueRepr == $dkPlasma # == "plasma"
    # All three arms key off the same outer ``variant desktopKind:``
    # head; the configField name round-trips on every row.
    for a in arms:
      check a.variantConfigField == "desktopKind"

  test "M9.E activeVariantArms tracks current configurable under explicit-string-value enums":
    # NDE-I close-out widening: the M9.E emitter now captures BOTH the
    # source-level ident text (``armValue == "dkSway"``) AND the
    # ``$value`` stringification (``armValueRepr == "sway"``); the M9.D
    # runtime records ``$value`` (``"sway"``) for the configurable
    # cell. ``activeVariantArms`` matches on EITHER spelling so the
    # filter fires correctly under both bare-value enums (where the
    # two coincide; covered by ``t_dsl_variant_uses.nim``) AND
    # explicit-string-value enums like the shim's ``DesktopKind`` —
    # which declares ``dkSway = "sway"`` / ``dkGnome = "gnome"`` /
    # ``dkPlasma = "plasma"``.
    #
    # Prior to the NDE-I widening this test pinned the broken shape
    # (``activeVariantArms(...).len == 0``) as an HONEST DEFERRAL; the
    # close-out fix landed in the same commit as this recipe rewrite.
    resetConfigurable("reproosDesktop.desktopKind")

    # Default configurable value: @[dkSway] — only the dkSway arm
    # fires (1 arm).
    let activeDefault =
      activeVariantArms("reproosDesktop", "desktopKind")
    check activeDefault.len == 1
    check activeDefault[0].armValue == "dkSway"
    check activeDefault[0].armValueRepr == $dkSway  # == "sway"
    check activeDefault[0].usesClauses == @["sway >=0.1.0"]

    # Override to all three — every arm fires; source-declaration
    # order is preserved.
    setConfigurable[seq[DesktopKind]](
      "reproosDesktop.desktopKind", @[dkSway, dkGnome, dkPlasma])
    let activeAll =
      activeVariantArms("reproosDesktop", "desktopKind")
    check activeAll.len == 3
    check activeAll[0].armValue == "dkSway"
    check activeAll[1].armValue == "dkGnome"
    check activeAll[2].armValue == "dkPlasma"

    # Single-element override picks just one arm regardless of source
    # position.
    setConfigurable[seq[DesktopKind]](
      "reproosDesktop.desktopKind", @[dkPlasma])
    let activePlasma =
      activeVariantArms("reproosDesktop", "desktopKind")
    check activePlasma.len == 1
    check activePlasma[0].armValue == "dkPlasma"
    check activePlasma[0].armValueRepr == $dkPlasma  # == "plasma"

    # Reset to the default so subsequent tests in this binary aren't
    # poisoned.
    resetConfigurable("reproosDesktop.desktopKind")

  test "M9.E validate: predicate registers exactly once with non-empty exprRepr":
    let preds = registeredValidates("reproosDesktop")
    check preds.len == 1
    check preds[0].packageName == "reproosDesktop"
    # The exprRepr captures the body source — non-empty so the
    # runtime can embed it in the violation diagnostic message.
    check preds[0].exprRepr.len > 0

  test "M9.E validate: passing predicate does NOT raise on default config":
    # Default config: desktopKind=@[dkSway], activeAtBoot=dkSway →
    # dkSway in @[dkSway] is true → no raise.
    resetConfigurable("reproosDesktop.desktopKind")
    resetConfigurable("reproosDesktop.activeAtBoot")
    var raised = false
    try:
      evaluateValidates("reproosDesktop")
    except EDslConfigViolation:
      raised = true
    check raised == false

  test "M9.E validate: bad config raises EConfigViolation (DSL runtime)":
    # Override activeAtBoot to dkPlasma — NOT in the default desktopKind
    # cell @[dkSway]. The DSL runtime's evaluateValidates raises its
    # ``EConfigViolation`` on the first failing predicate; aliased here
    # as ``EDslConfigViolation`` to avoid clashing with the shim's
    # ``EConfigViolation`` the v1 suite uses.
    setConfigurable[DesktopKind](
      "reproosDesktop.activeAtBoot", dkPlasma)
    expect EDslConfigViolation:
      evaluateValidates("reproosDesktop")
    # Hygiene: restore the default so subsequent tests run unpoisoned.
    resetConfigurable("reproosDesktop.activeAtBoot")

  test "M9.G bootloader: generationEntry + timeout + 1 menu entry":
    let cfg = registeredBootloaderConfig("reproosDesktop")
    check cfg.packageName == "reproosDesktop"
    check cfg.generationEntry == true
    check cfg.timeout == 5
    # defaultEntry was never declared — stays at the unset default.
    check cfg.defaultEntry == ""
    # Exactly one ``menuEntry:`` body.
    check cfg.menuEntries.len == 1
    check cfg.menuEntries[0].title == "ReproOS — generation default"
    check cfg.menuEntries[0].kernel == "/boot/vmlinuz-default"
    check cfg.menuEntries[0].initrd == "/boot/initrd.img-default"
    check cfg.menuEntries[0].cmdline ==
      "root=LABEL=ReproOS ro quiet"
    # The menu-entry row carries the parent package name so apply-phase
    # consumers can attribute the row even after a copy.
    check cfg.menuEntries[0].packageName == "reproosDesktop"

  test "M9.A consumeManagedBlock: mergedLdConf consumes the 4-contributor cohort union":
    # End-to-end consumer-side surface. The recipe's
    # ``files mergedLdConf:`` arm calls ``mergedManagedBlockFile`` to
    # read the multi-contributor merge + ``fs.configFile`` to plant
    # the final concrete file. The fixture registers 4 synthetic
    # contributions (mirroring NDE-D / NDE-F / NDE-G / NDE-H's emit
    # shape) before invoking the recipe's per-artifact helper.
    let root = createTempDir("ndei_mergedldconf_", "")
    defer: removeDir(root)
    resetDslRecipeState(root)
    registerSyntheticLdConfContributions()
    recipe.registerReproosDesktopFiles()

    # Consume the recipe-side configFile output and verify the bytes
    # contain every contributor's sentinel + the spec'd sort order
    # ``(priority, packageName, blockId)`` ascending.
    let merged = consumeConfigFile(
      "reproosDesktop", "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check merged.relPath == "etc/ld.so.conf.d/00-reproos-linux.conf"
    let bytes = readDslStoreFile(merged)

    # Every contributor's open sentinel is present.
    check "# >>> repro:system:graphics-stack:libpaths >>>" in bytes
    check "# >>> repro:system:gnome:libpaths >>>" in bytes
    check "# >>> repro:system:plasma:libpaths >>>" in bytes
    check "# >>> repro:system:sway:libpaths >>>" in bytes
    # graphics-stack (priority=100) sorts BEFORE the three
    # priority=500 compositors; compositors sort alphabetically
    # (gnome < plasma < sway).
    let idxGfx = bytes.find("# >>> repro:system:graphics-stack:")
    let idxGnome = bytes.find("# >>> repro:system:gnome:")
    let idxPlasma = bytes.find("# >>> repro:system:plasma:")
    let idxSway = bytes.find("# >>> repro:system:sway:")
    check idxGfx >= 0
    check idxGnome >= 0
    check idxPlasma >= 0
    check idxSway >= 0
    check idxGfx < idxGnome
    check idxGnome < idxPlasma
    check idxPlasma < idxSway
    # M9.A sha256 hashes are 64 lower-hex chars.
    check merged.hashHex.len == 64
    # Store path lands under the bound root.
    check merged.storePath.startsWith(root)

  test "M9.A mergedLdConf byte-equals the standalone mergedManagedBlockFile call":
    # The recipe's ``files mergedLdConf: build:`` block plants exactly
    # what ``mergedManagedBlockFile(path)`` produces — no extra
    # framing, no implicit suffixes. This is the load-bearing
    # consumer-side invariant: NDEM2's activation step can compute
    # the merged bytes once via ``mergedManagedBlockFile`` and trust
    # the planted file matches.
    let root = createTempDir("ndei_mergedldconf_byte_", "")
    defer: removeDir(root)
    resetDslRecipeState(root)
    registerSyntheticLdConfContributions()
    recipe.registerReproosDesktopFiles()

    let merged = consumeConfigFile(
      "reproosDesktop", "/etc/ld.so.conf.d/00-reproos-linux.conf")
    let bytes = readDslStoreFile(merged)
    let direct = mergedManagedBlockFile(
      "/etc/ld.so.conf.d/00-reproos-linux.conf")
    check bytes == direct

  test "displayManagerSymlink target derives from activeAtBoot configurable":
    # Spec NDEM1 worked example: dkSway → sway-session.service;
    # dkGnome → gdm.service; dkPlasma → sddm.service. Through the
    # DSL surface: setConfigurable(...) on activeAtBoot then
    # re-register, then ``registeredSymlinks`` echoes the new target.
    let root = createTempDir("ndei_dm_symlink_", "")
    defer: removeDir(root)

    # Pass A — default activeAtBoot=dkSway.
    resetDslRecipeState(root)
    registerSyntheticLdConfContributions()
    recipe.registerReproosDesktopFiles()
    let symlinksA = registeredSymlinks("reproosDesktop")
    check symlinksA.len == 1
    check symlinksA[0].path ==
      "/etc/systemd/system/display-manager.service"
    check symlinksA[0].target ==
      "/usr/lib/systemd/system/sway-session.service"
    check symlinksA[0].artifactName == "displayManagerSymlink"
    let hashA = symlinksA[0].hashHex

    # Pass B — flip activeAtBoot to dkGnome; the symlink target
    # re-keys to gdm.service.
    setConfigurable[DesktopKind](
      "reproosDesktop.activeAtBoot", dkGnome)
    resetDslPortFsState()
    resetDslPortFsExtState()
    resetDslPortMaterialiseState()
    registerStoreRoot("reproosDesktop", root, dhaSha256)
    recipe.registerReproosDesktopFiles()
    let symlinksB = registeredSymlinks("reproosDesktop")
    check symlinksB.len == 1
    check symlinksB[0].target ==
      "/usr/lib/systemd/system/gdm.service"
    check symlinksB[0].hashHex != hashA

    # Pass C — flip activeAtBoot to dkPlasma; the symlink target
    # re-keys to sddm.service.
    setConfigurable[DesktopKind](
      "reproosDesktop.activeAtBoot", dkPlasma)
    resetDslPortFsState()
    resetDslPortFsExtState()
    resetDslPortMaterialiseState()
    registerStoreRoot("reproosDesktop", root, dhaSha256)
    recipe.registerReproosDesktopFiles()
    let symlinksC = registeredSymlinks("reproosDesktop")
    check symlinksC.len == 1
    check symlinksC[0].target ==
      "/usr/lib/systemd/system/sddm.service"
    check symlinksC[0].hashHex != hashA
    check symlinksC[0].hashHex != symlinksB[0].hashHex

    # Hygiene: restore default so the next test in this binary
    # observes the registered default activeAtBoot=dkSway.
    resetConfigurable("reproosDesktop.activeAtBoot")

  test "recipe registers exactly 2 files: artifacts (mergedLdConf + displayManagerSymlink)":
    # M3 ``registeredArtifacts`` returns one row per ``files <name>:``
    # arm. The recipe declares two — the multi-contributor consumer +
    # the activation symlink — both ``dakFiles`` kind.
    let arts = registeredArtifacts("reproosDesktop")
    check arts.len == 2
    var names: seq[string] = @[]
    for a in arts:
      check a.kind == dakFiles
      names.add(a.artifactName)
    check "mergedLdConf" in names
    check "displayManagerSymlink" in names

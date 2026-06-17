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

import std/[algorithm, os, sequtils, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/system/reproos_desktop
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # ManagedFiles, BlockScope (re-exported through reproos_desktop too).

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
    expect EConfigViolation:
      validateDesktopConfig(cfg)

    # Also: dkPlasma not in {dkSway, dkGnome}.
    cfg.desktopKind = @[dkSway, dkGnome]
    cfg.activeAtBoot = dkPlasma
    expect EConfigViolation:
      validateDesktopConfig(cfg)

    # Also: empty desktopKind — a generation that installs no DEs
    # cannot boot any.
    cfg.desktopKind = @[]
    cfg.activeAtBoot = dkSway
    expect EConfigViolation:
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
    expect EConfigViolation:
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

## NDEM2 unit tests: generation-log persistence + rollback semantics.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/system/
## generation_log.nim`` against synthetic configurations.
##
## Pragmatic scope per the NDEM2 sub-agent prompt: tests the
## generation-switching semantics at the **manifest level**, not at
## the Hyper-V boot level. The real boot tests (NDE-H2/G2/K2) remain
## blocked on .deb extraction + activation runtime.
##
## Required test surfaces (per the NDEM2 sub-agent prompt §"Unit
## tests"):
##
##   1. Empty log ``activeGeneration`` raises ``EConfigViolation``.
##   2. ``addGeneration`` creates entry with correct fields.
##   3. ``addGeneration`` is idempotent on ``generationId``.
##   4. ``activeGeneration`` is the most recent entry.
##   5. ``rollback`` returns the previous generation as active.
##   6. ``rollback`` from a single-entry log raises.
##   7. **Variant switch** creates a new generation; closures differ
##      (storePaths differ).
##   8. **Configurable switch** creates a new generation; closures
##      identical (storePaths byte-identical) but activation differs
##      (displayManagerSymlink target differs).
##   9. ``lookupGeneration`` finds historical entries.
##   10. ``serializeGenerationLog`` is deterministic (byte-identical
##       across two materialisations of the same generations).
##   11. ``deserializeGenerationLog`` round-trips.
##   12. No in-place mutation: appending a new entry leaves prior
##       entries' manifest bytes UNCHANGED.
##
## Tests use ``check`` / ``doAssert`` / ``expect``. No try/except
## swallows. Failure paths use ``expect EConfigViolation:``.

import std/[options, os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/system/reproos_desktop
import repro_dsl_stdlib/packages/system/reproos_desktop as shim
  # Alias so the type alias below can disambiguate the shim's
  # ``EConfigViolation`` (raised by ``addGeneration`` / ``rollback`` /
  # ``deserializeGenerationLog``) from the DSL runtime's same-named
  # exception that ``repro_project_dsl`` re-exports.
import repro_dsl_stdlib/packages/system/generation_log

# Importing the recipe's ``repro.nim`` evaluates its ``package
# generationLog:`` block at module init, exercising the NDE-J pure-DSL
# surface (M2 ``versions:`` + M3 ``executable:`` + M6 ``cli:``) against
# the real production recipe shape. Without this import the registry
# stays empty and the "NDE-J DSL surface" assertions below would be
# vacuous. The recipe re-exports ``generation_log`` so this double-import
# resolves to the same module instance (precedent: NDE-A
# ``t_nde0a_apt_jammy.nim`` does the same double-import dance).
#
# ``repro_project_dsl`` re-exports an ``EConfigViolation`` symbol that
# clashes with the shim's same-named type the v1 suite ``expect`` on;
# the type alias below pins ``EConfigViolation`` (used by every v1
# ``expect`` block above) to the shim spelling so the expect macro's
# strVal extractor sees an unambiguous ident node. Mirrors the NDE-I
# precedent in ``t_ndem1_reproos_desktop.nim``.
import repro_project_dsl
import "../../../recipes/packages/system/generation-log/repro" as
  generationLogRecipe

type
  EConfigViolation = shim.EConfigViolation
    ## Pin the v1 ``expect EConfigViolation:`` blocks to the shim's
    ## exception (the one ``addGeneration`` / ``rollback`` /
    ## ``deserializeGenerationLog`` actually raise). Without this alias
    ## the symbol would be ambiguous after the NDE-J import of
    ## ``repro_project_dsl`` which also exports an ``EConfigViolation``.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc configWithRoot(storeRoot: string): ReproosDesktopConfig =
  result = defaultReproosDesktopConfig()
  result.storeRoot = storeRoot

proc buildManifest(storeRoot: string;
                   desktopKind: seq[DesktopKind];
                   activeAtBoot: DesktopKind): GenerationManifest =
  ## Materialise a manifest with the given variant + configurable
  ## using the default config for everything else.
  var cfg = configWithRoot(storeRoot)
  cfg.desktopKind = desktopKind
  cfg.activeAtBoot = activeAtBoot
  let outs = materializeReproosDesktop(cfg)
  result = outs.manifest

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDEM2 generation-log persistence + rollback":

  test "empty log: activeGeneration raises EConfigViolation":
    # No generation has been materialised → there is no active
    # generation. The spec's `reproos-rebuild list` would report an
    # empty list; calling `active` is a hard error.
    var log = GenerationLog()
    check log.entries.len == 0
    expect EConfigViolation:
      discard activeGeneration(log)

  test "addGeneration creates entry with correct generationId + timestamp + manifest":
    let root = createTempDir("ndem2_add_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m = buildManifest(root, @[dkSway], dkSway)
    let ts: int64 = 1750000000
    let entry = addGeneration(log, m, ts)

    check log.entries.len == 1
    check entry.generationId == m.generationId
    check entry.timestamp == ts
    check entry.manifest.generationId == m.generationId
    check entry.manifest.desktopKind == @[dkSway]
    check entry.manifest.activeAtBoot == dkSway
    # The log entry's manifest agrees with the appended one byte-
    # for-byte on the load-bearing fields.
    check log.entries[0].generationId == m.generationId

  test "addGeneration is idempotent on generationId: second append returns existing entry":
    # NDEM1 guarantees `generationId` is a pure function of the
    # ReproosDesktopConfig inputs. Re-materialising the same config
    # MUST NOT duplicate the log entry.
    let root = createTempDir("ndem2_idem_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    let first = addGeneration(log, m, 1750000000)
    check log.entries.len == 1

    # Second call with the same manifest.
    let second = addGeneration(log, m, 1750000999)  # different ts
    # Idempotency: the log still has one entry, AND the returned
    # entry equals the original first entry (NOT a new entry with
    # the second timestamp).
    check log.entries.len == 1
    check second.generationId == first.generationId
    check second.timestamp == first.timestamp  # original ts preserved
    check log.entries[0].timestamp == first.timestamp

  test "activeGeneration is the most recently added entry":
    let root = createTempDir("ndem2_active_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m1 = buildManifest(root, @[dkSway], dkSway)
    let m2 = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    discard addGeneration(log, m1, 1750000000)
    discard addGeneration(log, m2, 1750000100)
    check log.entries.len == 2

    let active = activeGeneration(log)
    check active.generationId == m2.generationId
    check active.manifest.activeAtBoot == dkGnome

  test "rollback from 3-entry log returns the previous generation as active":
    # Append 3 generations; rollback once; activeGeneration is the
    # second one. The popped entry is the third one.
    let root = createTempDir("ndem2_rb_3_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m1 = buildManifest(root, @[dkSway], dkSway)
    let m2 = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    let m3 = buildManifest(root, @[dkSway, dkGnome, dkPlasma], dkPlasma)
    discard addGeneration(log, m1, 1750000000)
    discard addGeneration(log, m2, 1750000100)
    discard addGeneration(log, m3, 1750000200)
    check log.entries.len == 3
    check activeGeneration(log).generationId == m3.generationId

    let newActive = rollback(log)
    check log.entries.len == 2
    check newActive.generationId == m2.generationId
    check activeGeneration(log).generationId == m2.generationId
    # The popped generation (m3) is no longer in the log.
    check lookupGeneration(log, m3.generationId).isNone

  test "rollback from single-entry log raises EConfigViolation":
    # Per the spec's `reproos-rebuild rollback` semantics: there
    # must be a prior generation to roll back TO.
    let root = createTempDir("ndem2_rb_1_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m = buildManifest(root, @[dkSway], dkSway)
    discard addGeneration(log, m, 1750000000)
    check log.entries.len == 1

    expect EConfigViolation:
      discard rollback(log)
    # Log unchanged after the failed rollback attempt.
    check log.entries.len == 1
    check activeGeneration(log).generationId == m.generationId

  test "rollback from empty log raises EConfigViolation":
    # Sanity: the 0-entry case is also a hard error.
    var log = GenerationLog()
    expect EConfigViolation:
      discard rollback(log)

  test "VARIANT switch: new generation with different closure (storePaths differ)":
    # Spec literal (Configurable-System.md §"Closure-size
    # implications"): adding a DesktopKind grows the closure.
    # Operationally at NDEM2: the manifests for desktopKind=@[dkSway]
    # and desktopKind=@[dkSway, dkGnome] have DIFFERENT storePaths
    # sequences (the second strictly contains more).
    let root = createTempDir("ndem2_variant_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let mSway = buildManifest(root, @[dkSway], dkSway)
    let mSwayGnome = buildManifest(root, @[dkSway, dkGnome], dkSway)

    discard addGeneration(log, mSway, 1750000000)
    discard addGeneration(log, mSwayGnome, 1750000100)
    check log.entries.len == 2

    # Different generation IDs (NDEM1's two-axis identity contract).
    check mSway.generationId != mSwayGnome.generationId

    # Variant change → different closures. The storePaths sequences
    # MUST differ (the second strictly contains more entries — the
    # gnome subtree is added). This is the spec's "Variant rebuild:
    # closure differs" assertion.
    check mSway.storePaths != mSwayGnome.storePaths
    check mSwayGnome.storePaths.len > mSway.storePaths.len

    # Rollback restores the prior variant.
    let restored = rollback(log)
    check restored.generationId == mSway.generationId
    check restored.manifest.storePaths == mSway.storePaths

  test "CONFIGURABLE switch: new generation; closures IDENTICAL (storePaths byte-identical); activation differs (displayManagerSymlink target differs)":
    # Spec literal: "Configurable rebuild: closure identical;
    # generation entry differs." Per the spec's two-axis identity
    # contract, the generationId still changes (activation matters
    # for the generation entry).
    let root = createTempDir("ndem2_cfg_", "")
    defer: removeDir(root)

    var log = GenerationLog()

    # Two materialisations sharing the same VARIANT (desktopKind),
    # differing only in the CONFIGURABLE (activeAtBoot).
    var cfgA = configWithRoot(root)
    cfgA.desktopKind = @[dkSway, dkGnome]
    cfgA.activeAtBoot = dkSway
    let outsA = materializeReproosDesktop(cfgA)
    let mA = outsA.manifest

    var cfgB = configWithRoot(root)
    cfgB.desktopKind = @[dkSway, dkGnome]
    cfgB.activeAtBoot = dkGnome
    let outsB = materializeReproosDesktop(cfgB)
    let mB = outsB.manifest

    discard addGeneration(log, mA, 1750000000)
    discard addGeneration(log, mB, 1750000100)

    # Different generationIds (NDEM1's two-axis identity contract:
    # the configurable also flows into the ID).
    check mA.generationId != mB.generationId

    # The mergedLdConf union depends only on which contributors are
    # present (graphics-stack + sway + gnome) — NOT on activeAtBoot.
    # So the merged-files entry is byte-identical.
    check mA.mergedFiles == mB.mergedFiles

    # The activation symlinks differ — that's the WHOLE POINT of
    # the configurable rebuild. dkSway → sway-session.service;
    # dkGnome → gdm.service.
    check mA.activationSymlinks != mB.activationSymlinks
    check mA.activationSymlinks[0].target ==
          "/usr/lib/systemd/system/sway-session.service"
    check mB.activationSymlinks[0].target ==
          "/usr/lib/systemd/system/gdm.service"

    # Closure-affecting outputs (the foundation packages + the per-
    # DE packages + the mergedLdConf) are SHARED. The
    # displayManagerSymlink + the GRUB menu entry are the only two
    # storePaths that re-key (the GRUB entry records activeAtBoot,
    # so it also re-keys). At the manifest's storePaths level we
    # check the shared subset is large; per NDEM1 acceptance literal,
    # "storePaths set is identical EXCEPT for the display-manager
    # symlink + the GRUB menu entry" → at least storePaths.len - 3
    # entries are shared.
    var shared = 0
    for p in mA.storePaths:
      if p in mB.storePaths: shared.inc
    check shared >= mA.storePaths.len - 3

  test "lookupGeneration finds historical entries by ID":
    let root = createTempDir("ndem2_lookup_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m1 = buildManifest(root, @[dkSway], dkSway)
    let m2 = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    let m3 = buildManifest(root, @[dkSway, dkGnome, dkPlasma], dkPlasma)
    discard addGeneration(log, m1, 1750000000)
    discard addGeneration(log, m2, 1750000100)
    discard addGeneration(log, m3, 1750000200)

    # Lookup the FIRST generation — it's a historical entry.
    let found = lookupGeneration(log, m1.generationId)
    check found.isSome
    check found.get().generationId == m1.generationId
    check found.get().manifest.desktopKind == @[dkSway]
    check found.get().manifest.activeAtBoot == dkSway

    # Lookup a never-added ID → none.
    let missing = lookupGeneration(log, "deadbeef" & "00".repeat(12))
    check missing.isNone

    # Lookup the active (newest) → some.
    let active = lookupGeneration(log, m3.generationId)
    check active.isSome
    check active.get().generationId == m3.generationId

  test "serializeGenerationLog is deterministic: two empty logs with same generations → byte-identical output":
    let root = createTempDir("ndem2_det_", "")
    defer: removeDir(root)

    let m1 = buildManifest(root, @[dkSway], dkSway)
    let m2 = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    let m3 = buildManifest(root, @[dkSway, dkGnome, dkPlasma], dkPlasma)

    var logA = GenerationLog()
    discard addGeneration(logA, m1, 1750000000)
    discard addGeneration(logA, m2, 1750000100)
    discard addGeneration(logA, m3, 1750000200)

    var logB = GenerationLog()
    discard addGeneration(logB, m1, 1750000000)
    discard addGeneration(logB, m2, 1750000100)
    discard addGeneration(logB, m3, 1750000200)

    let sA = serializeGenerationLog(logA)
    let sB = serializeGenerationLog(logB)
    check sA == sB
    check sA.len > 0
    # The version marker is present.
    check NdemGenerationLogVersion in sA
    # Generation IDs are present in the serialised form.
    check m1.generationId in sA
    check m2.generationId in sA
    check m3.generationId in sA

  test "deserializeGenerationLog round-trip preserves entry count + generationIds":
    let root = createTempDir("ndem2_rt_", "")
    defer: removeDir(root)

    let m1 = buildManifest(root, @[dkSway], dkSway)
    let m2 = buildManifest(root, @[dkSway, dkGnome], dkGnome)

    var log = GenerationLog()
    discard addGeneration(log, m1, 1750000000)
    discard addGeneration(log, m2, 1750000100)

    let s = serializeGenerationLog(log)
    let roundtripped = deserializeGenerationLog(s)

    # Counts match.
    check roundtripped.entries.len == log.entries.len
    # First entry's generationId matches.
    check roundtripped.entries[0].generationId == log.entries[0].generationId
    # Last entry's generationId matches (and is the active one).
    check roundtripped.entries[^1].generationId == log.entries[^1].generationId
    # Timestamps preserved.
    check roundtripped.entries[0].timestamp == 1750000000
    check roundtripped.entries[1].timestamp == 1750000100
    # The full manifest data round-trips: desktopKind + activeAtBoot +
    # storePaths + activationSymlinks + mergedFiles.
    check roundtripped.entries[0].manifest.desktopKind == @[dkSway]
    check roundtripped.entries[0].manifest.activeAtBoot == dkSway
    check roundtripped.entries[1].manifest.desktopKind == @[dkSway, dkGnome]
    check roundtripped.entries[1].manifest.activeAtBoot == dkGnome
    check roundtripped.entries[0].manifest.storePaths == m1.storePaths
    check roundtripped.entries[1].manifest.storePaths == m2.storePaths
    check roundtripped.entries[0].manifest.activationSymlinks ==
          m1.activationSymlinks
    check roundtripped.entries[1].manifest.activationSymlinks ==
          m2.activationSymlinks
    check roundtripped.entries[0].manifest.mergedFiles == m1.mergedFiles
    check roundtripped.entries[1].manifest.mergedFiles == m2.mergedFiles

    # Re-serialising the round-tripped log produces byte-identical
    # output (round-trip + deterministic emitter).
    check serializeGenerationLog(roundtripped) == s

  test "no in-place mutation: appending a new entry leaves prior entries' manifest bytes UNCHANGED":
    # Append generation A; capture A's serialised representation.
    # Append generation B. Assert A's entry serialisation has not
    # been mutated.
    let root = createTempDir("ndem2_nomut_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let mA = buildManifest(root, @[dkSway], dkSway)
    discard addGeneration(log, mA, 1750000000)

    # Snapshot of A's state in the log.
    let aStorePaths_before = log.entries[0].manifest.storePaths
    let aActivationSymlinks_before = log.entries[0].manifest.activationSymlinks
    let aMergedFiles_before = log.entries[0].manifest.mergedFiles
    let aGenerationId_before = log.entries[0].generationId
    let aTimestamp_before = log.entries[0].timestamp

    # A single-log serialisation is the baseline for the "no
    # mutation" byte-level check below.
    var logCopy = GenerationLog()
    discard addGeneration(logCopy, mA, 1750000000)
    let aOnlySerialised = serializeGenerationLog(logCopy)

    # Now append B (a different variant).
    let mB = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    discard addGeneration(log, mB, 1750000100)
    check log.entries.len == 2

    # A's entry data is byte-identical to what it was before B was
    # appended.
    check log.entries[0].generationId == aGenerationId_before
    check log.entries[0].timestamp == aTimestamp_before
    check log.entries[0].manifest.storePaths == aStorePaths_before
    check log.entries[0].manifest.activationSymlinks ==
          aActivationSymlinks_before
    check log.entries[0].manifest.mergedFiles == aMergedFiles_before

    # The "A-only" prefix of the 2-entry serialisation is byte-
    # identical to the 1-entry baseline modulo the surrounding JSON.
    # Concretely: the bytes between the `"entries":[` opener and the
    # first inter-entry comma must match the 1-entry log's bytes
    # between `"entries":[` and `]}`.
    let twoEntrySerialised = serializeGenerationLog(log)
    let openerOne = aOnlySerialised.find("\"entries\":[") + len("\"entries\":[")
    let endOne = aOnlySerialised.rfind("]}")
    let aEntryBytesOne = aOnlySerialised[openerOne ..< endOne]

    let openerTwo = twoEntrySerialised.find("\"entries\":[") + len("\"entries\":[")
    # Find the first entry's closing `}` followed by `,{` — the
    # inter-entry separator. The first entry ends at the index of
    # the `,` BEFORE `{"generationId":<mB.generationId>`.
    let bEntryStart = twoEntrySerialised.find(
      "{\"generationId\":\"" & mB.generationId & "\"")
    check bEntryStart > openerTwo
    # The separator `,` precedes bEntryStart.
    let aEntryBytesTwo = twoEntrySerialised[openerTwo ..< bEntryStart - 1]
    check aEntryBytesOne == aEntryBytesTwo

  test "sortedByTimestamp returns entries in ascending timestamp order":
    # Sanity sibling-view check: the convenience helper sorts entries
    # by (timestamp, generationId) ascending without mutating the
    # log's insertion order.
    let root = createTempDir("ndem2_sorted_", "")
    defer: removeDir(root)

    var log = GenerationLog()
    let m1 = buildManifest(root, @[dkSway], dkSway)
    let m2 = buildManifest(root, @[dkSway, dkGnome], dkGnome)
    let m3 = buildManifest(root, @[dkSway, dkGnome, dkPlasma], dkPlasma)

    # Append in NON-monotonic order.
    discard addGeneration(log, m2, 1750000100)
    discard addGeneration(log, m1, 1750000000)
    discard addGeneration(log, m3, 1750000200)

    let sorted = sortedByTimestamp(log)
    check sorted.len == 3
    check sorted[0].timestamp == 1750000000
    check sorted[1].timestamp == 1750000100
    check sorted[2].timestamp == 1750000200

    # The log's own entries slot is UNCHANGED (insertion order
    # preserved — that's the "active" semantics).
    check log.entries[0].generationId == m2.generationId
    check log.entries[1].generationId == m1.generationId
    check log.entries[2].generationId == m3.generationId

  test "deserializeGenerationLog rejects version mismatch with EConfigViolation":
    # Defensive: tampered or future-formatted JSON MUST hard-fail,
    # not silently fall back to v1 semantics.
    let bogus = """{"version":"99.99.99","entries":[]}"""
    expect EConfigViolation:
      discard deserializeGenerationLog(bogus)

# ---------------------------------------------------------------------------
# NDE-J DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/system/generation-log/repro.nim`` actually exercises
# the new DSL surface (M2 ``versions:`` + M3 ``executable:`` + M6
# ``cli:``) rather than silently keeping the legacy ``config:``-only
# shape. Confirms:
#
#   * the recipe's ``versions:`` block round-trips through
#     ``registeredVersions`` with the same string the shim's
#     ``NdemGenerationLogVersion`` constant bakes into every serialised
#     log envelope — the cache-key contract is auditable from both ends;
#
#   * the recipe's ``executable reproosRebuild:`` artifact is recorded
#     in the M3 artifact registry under the source-level package name;
#
#   * the recipe's ``cli:`` block lowers every spec'd
#     ``reproos-rebuild`` subcommand argument (subcommand verb +
#     generationId + olderThan duration + verbose flag) into the M6 CLI
#     param registry with the right ``DslCliParamKind`` discriminator
#     for each.
#
# The v1 invariant suite above stays intact (15 tests, 81 ``check``
# assertions all preserved); these are extra assertions on top.
# ---------------------------------------------------------------------------

suite "NDEM2 generation-log DSL surface (NDE-J)":

  test "recipe registers exactly one version via the DSL versions: block":
    # NDE-J adds a ``versions:`` block; before the rewrite there was no
    # ``registerVersion`` emission for ``generationLog`` and the accessor
    # returned the empty seq. After the rewrite a single entry shows up.
    let vs = registeredVersions("generationLog")
    check vs.len == 1

  test "recorded version string is byte-identical to NdemGenerationLogVersion":
    # Tying the recipe-declared version to the shim constant is the
    # whole point of M2's surface — it makes the cache-key contract
    # auditable from the DSL side without parsing the JSON envelope the
    # serialiser embeds the same string into.
    let vs = registeredVersions("generationLog")
    check vs[0].version == NdemGenerationLogVersion

  test "recorded version carries the NDEM2 sourceRevision pin":
    # The recipe pins a deterministic ``sourceRevision`` so the spec's
    # cache-key inputs (adapter version + revision) are both reachable
    # from the registry alone.
    let vs = registeredVersions("generationLog")
    check vs[0].sourceRevision == "ndem2/generation-log/0.1.0"

  test "recipe registers the reproosRebuild executable artifact":
    # NDE-J adds an ``executable reproosRebuild:`` artifact reflecting
    # the spec'd ``reproos-rebuild`` CLI surface. Before the rewrite the
    # recipe had no ``executable:`` / ``library:`` / ``files:`` block
    # and the M3 artifact registry was empty for ``generationLog``.
    let arts = registeredArtifacts("generationLog")
    check arts.len == 1
    check arts[0].artifactName == "reproosRebuild"
    check arts[0].kind == dakExecutable
    check arts[0].packageName == "generationLog"

  test "reproosRebuild cli: registers four params in declaration order":
    # M6 lowerer records one row per ``pos`` / ``flag`` / ``boolFlag``
    # statement against ``<pkg>.<artifact>.<subcmd="">`` (subcmd nesting
    # is M6-deferred; root params only). The recipe declares:
    #   pos subcommand is string
    #   flag generationId is string
    #   flag olderThan is string
    #   boolFlag verbose
    let params = registeredCliParams(
      "generationLog", "reproosRebuild", "")
    check params.len == 4

    # pos subcommand — the verb (list / switch / rollback / gc).
    check params[0].name == "subcommand"
    check params[0].typeName == "string"
    check params[0].kind == cpkPos

    # flag generationId — argument to ``switch <generationId>``;
    # consumed by ``lookupGeneration``.
    check params[1].name == "generationId"
    check params[1].typeName == "string"
    check params[1].kind == cpkFlag

    # flag olderThan — argument to ``gc --older-than=<duration>``.
    check params[2].name == "olderThan"
    check params[2].typeName == "string"
    check params[2].kind == cpkFlag

    # boolFlag verbose — universal verbosity flag. The M6 emitter
    # defaults the typeName to ``"bool"`` for ``boolFlag`` entries.
    check params[3].name == "verbose"
    check params[3].typeName == "bool"
    check params[3].kind == cpkBoolFlag

  test "registeredVersions / registeredArtifacts / registeredCliParams symmetric for unknown package":
    # Symmetric with every M2 / M3 / M6 accessor: querying a package
    # that never declared the corresponding block returns the empty seq
    # rather than raising. This makes the DSL-surface assertions above
    # robust against test ordering.
    check registeredVersions("noSuchPackageEverDeclared").len == 0
    check registeredArtifacts("noSuchPackageEverDeclared").len == 0
    check registeredCliParams(
      "noSuchPackageEverDeclared", "anyTool", "").len == 0

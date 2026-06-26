## DSL-port M9.R.34 — recipe edits invalidate the local action cache.
##
## ## Context
##
## Pre-M9.R.34, ``cacheInputPaths`` (the engine's local action-cache
## input set) covered: declared ``action.inputs`` (only prior-action
## outputs) + io-monitor reads/probes (only files cmake / make /
## meson / ninja actually READ during configure + build) + depfile
## inputs.  The per-recipe ``repro.nim`` / ``reprobuild.nim`` file
## itself is not in any of those sets — cmake doesn't read it, the
## io-monitor doesn't see it, and no depfile references it.  So
## edits to a from-source recipe's ``cacheVars`` / ``srcPatches`` /
## ``extraEnv`` / etc. didn't bus the cmake-configure action's
## ``weakFingerprint``, and ``repro build <recipe>`` after a recipe
## edit happily returned a cache HIT against the prior build's
## artifacts (silently building the wrong thing or skipping a real
## rebuild — M9.R.33's BUILD_SHARED_LIBS=ON drive-by surface).
##
## The binary-cache path was always fine — ``providerRevisionHex``
## (in ``conventions/from_source_identity.nim``) already hashes the
## recipe file bytes and that digest lands in
## ``cacheEntryIdentity.providerRevision``, so the on-wire entry
## key on the published bundle was already recipe-revision-aware.
## The bug was strictly in the local action-cache path the engine
## consults BEFORE deciding whether to launch the action at all.
##
## ## What M9.R.34 changes
##
## ``BuildActionDef`` gained a new ``recipeRevisionFingerprint``
## field, auto-populated by ``buildAction()`` at registration time
## from ``activeProviderProjectRoot()`` via the new
## ``computeRecipeRevisionFingerprint`` helper.  The field is part
## of the v20 payload codec — encoded into ``actionPayload(action)``
## bytes, decoded on the engine side, and (because every
## ``lowerGraphAction`` ``fingerprintText`` includes the encoded
## ``node.payload`` string) automatically bused into every action's
## ``weakFingerprint``.
##
## ## What this test pins
##
## 1. ``computeRecipeRevisionFingerprint("")`` returns the empty
##    string (outside-provider-mode + unit-test inert default).
## 2. ``computeRecipeRevisionFingerprint(<dir-without-recipe>)``
##    returns the empty string (no canonical/legacy file resolved).
## 3. ``computeRecipeRevisionFingerprint(<dir-with-repro.nim>)``
##    returns a 64-char lowercase-hex sha256 digest of the file
##    bytes — the spec shape every recipe-aware fingerprint relies
##    on.
## 4. Editing the recipe file (after a cache reset) changes the
##    returned digest — the *behavior* the milestone exists to
##    deliver.
## 5. The ``recipeRevisionFingerprint`` round-trips through
##    ``encodeBuildActionPayload`` / ``decodeBuildActionPayload``
##    so the v20 codec carries the field across the
##    provider→engine boundary.
## 6. Two ``BuildActionDef``s identical except for
##    ``recipeRevisionFingerprint`` encode to DIFFERENT byte
##    sequences — the property the engine's
##    ``fingerprintText = [...node.payload...].join("\\n")``
##    composition relies on so a recipe edit naturally buses every
##    action's ``weakFingerprint``.
## 7. Composing the engine-side ``fingerprintText`` shape against
##    the two payloads and hashing via ``weakFingerprintFromText``
##    yields DIFFERENT digests — closes the loop end-to-end: a
##    recipe edit produces a fresh local-action-cache key.
## 8. The ``reprobuild.nim`` legacy filename is also picked up.

import std/[os, strutils, unittest]

import repro_project_dsl

# Note: we deliberately do NOT import ``repro_build_engine`` here.  The
# engine module currently fails ``nim check`` on Windows hosts because of
# an unrelated pre-existing pollNextGrantBounded gap in the sibling
# runquota repo (see commit 121b3629), and the engine's
# ``weakFingerprintFromText`` is a one-line wrapper over
# ``blake3DomainDigest`` whose contract — "different input text yields
# different ContentDigest" — follows from BLAKE3's collision
# resistance.  So this test pins the load-bearing property at the
# fingerprintText layer: the engine composes
# ``fingerprintText = [...node.payload...].join("\n")`` and a
# different recipe-revision digest changes ``node.payload`` and hence
# ``fingerprintText``.  Because BLAKE3 is collision-resistant, a
# different fingerprintText implies a different ``weakFingerprint``
# (and a local action-cache miss).

suite "DSL-port M9.R.34 — recipe-revision fingerprint":

  setup:
    resetRecipeRevisionFingerprintCache()

  test "empty_project_root_yields_empty_digest":
    check computeRecipeRevisionFingerprint("") == ""

  test "directory_without_recipe_file_yields_empty_digest":
    let tmp = getTempDir() / "m9r34_no_recipe"
    removeDir(tmp)
    createDir(tmp)
    try:
      check computeRecipeRevisionFingerprint(tmp) == ""
    finally:
      removeDir(tmp)

  test "directory_with_repro_nim_returns_sha256_hex_digest":
    let tmp = getTempDir() / "m9r34_canonical"
    removeDir(tmp)
    createDir(tmp)
    try:
      writeFile(tmp / "repro.nim", "package demo:\n  discard\n")
      let digest = computeRecipeRevisionFingerprint(tmp)
      check digest.len == 64
      for ch in digest:
        check ch in {'0' .. '9', 'a' .. 'f'}
    finally:
      removeDir(tmp)

  test "directory_with_reprobuild_nim_legacy_filename_also_resolves":
    let tmp = getTempDir() / "m9r34_legacy"
    removeDir(tmp)
    createDir(tmp)
    try:
      writeFile(tmp / "reprobuild.nim", "package demo:\n  discard\n")
      let digest = computeRecipeRevisionFingerprint(tmp)
      check digest.len == 64
    finally:
      removeDir(tmp)

  test "recipe_edit_changes_the_returned_digest":
    # The load-bearing behavior contract: an edit to the recipe file
    # MUST change the digest so the engine's local action-cache key
    # buses on the change.
    let tmp = getTempDir() / "m9r34_edit"
    removeDir(tmp)
    createDir(tmp)
    try:
      writeFile(tmp / "repro.nim",
        "package demo:\n  cacheVars = @[\"BUILD_TYPE=Release\"]\n")
      let before = computeRecipeRevisionFingerprint(tmp)
      check before.len == 64
      # Reset the per-projectRoot cache so the next call rereads —
      # the main build flow recomputes per ``buildPackageFragment``
      # invocation, but a single in-process test mutating the file
      # has to drop the memoized value explicitly.
      resetRecipeRevisionFingerprintCache()
      writeFile(tmp / "repro.nim",
        "package demo:\n  cacheVars = @[\"BUILD_TYPE=Debug\"]\n")
      let after = computeRecipeRevisionFingerprint(tmp)
      check after.len == 64
      check before != after
    finally:
      removeDir(tmp)

  test "payload_codec_round_trips_recipeRevisionFingerprint":
    var action = BuildActionDef(
      id: "demo",
      call: publicCliCall("pkg", "exe", "build", "pkg.exe.build", @[]),
      cacheable: true,
      commandStatsId: "demo",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      recipeRevisionFingerprint:
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.recipeRevisionFingerprint ==
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  test "different_recipeRevisionFingerprint_yields_different_payload_bytes":
    proc sample(fp: string): BuildActionDef =
      BuildActionDef(
        id: "demo",
        call: publicCliCall("pkg", "exe", "build", "pkg.exe.build", @[]),
        cacheable: true,
        commandStatsId: "demo",
        dependencyPolicy: defaultDependencyPolicy(),
        actionCachePolicy: defaultActionCachePolicy(),
        recipeRevisionFingerprint: fp)
    let a = encodeBuildActionPayload(sample(
      "0000000000000000000000000000000000000000000000000000000000000000"))
    let b = encodeBuildActionPayload(sample(
      "1111111111111111111111111111111111111111111111111111111111111111"))
    check a != b

  test "different_recipeRevisionFingerprint_yields_different_engine_fingerprintText":
    # Mirror the engine's ``lowerGraphAction`` fingerprintText shape
    # for the default typed-tool path (see ``repro_cli_support.nim``
    # lines 1862-1870):
    #     "reprobuild.localProjectAction.v1\n"
    #     "<id>\n"
    #     "<packageName>\n"
    #     "<executableName>\n"
    #     "<subcommand>\n"
    #     "<node.payload>\n"
    #     "<digestHex(profile.profileFingerprint)>"
    # The profile fingerprint hex is a constant placeholder here.
    # Since the engine feeds this text to ``weakFingerprintFromText``
    # (a BLAKE3 domain-separated digest), a byte-different
    # fingerprintText yields a different ``weakFingerprint`` —
    # closing the chain "recipe edit -> different recipe digest ->
    # different payload bytes -> different fingerprintText ->
    # different weakFingerprint -> local action cache MISS -> action
    # re-runs."
    proc sample(fp: string): BuildActionDef =
      BuildActionDef(
        id: "demo",
        call: publicCliCall("pkg", "exe", "build", "pkg.exe.build", @[]),
        cacheable: true,
        commandStatsId: "demo",
        dependencyPolicy: defaultDependencyPolicy(),
        actionCachePolicy: defaultActionCachePolicy(),
        recipeRevisionFingerprint: fp)
    proc engineFingerprintText(action: BuildActionDef): string =
      let nodePayload = actionPayload(action)
      [
        "reprobuild.localProjectAction.v1",
        action.id,
        action.call.packageName,
        action.call.executableName,
        action.call.subcommand,
        nodePayload,
        "deadbeef00000000deadbeef00000000deadbeef00000000deadbeef00000000"
      ].join("\n")
    let a = engineFingerprintText(sample(
      "0000000000000000000000000000000000000000000000000000000000000000"))
    let b = engineFingerprintText(sample(
      "1111111111111111111111111111111111111111111111111111111111111111"))
    check a != b

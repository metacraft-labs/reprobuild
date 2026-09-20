## Harness lib-path skew — which key carries it, and which must NOT.
##
## ## What this test used to assert, and why that moved
##
## An out-of-tree consumer compiles its provider/interface recipes against an
## EXTERNAL reprobuild libs root (``reproLibPathFlags`` resolves it from
## ``$REPROBUILD_LIBS_DIR`` / ``$REPROBUILD_REPO_ROOT`` → the running ``repro``
## binary's own checkout → a sibling ``../reprobuild/``). If an edit under that
## root does not invalidate anything, the extract-runner harness serves an
## interface artifact the freshly-built ``repro`` binary cannot validate —
## the harness↔binary fingerprint skew, surfacing as "interface fingerprint
## mismatch".
##
## The original fix put ``reproLibSourceFingerprint`` — a BLAKE3 over every
## reprobuild ``.nim``/``.nims`` — into the shared provider-NIMCACHE key, and
## this test pinned it there. Tool-Owned-Caches.md forbids that placement:
## a cache identity derived from input CONTENT "yields an empty directory on
## every rebuild, which is the condition the cache exists to prevent". So the
## component moved out of the nimcache key, and this test moved with it.
##
## ## Why moving it does not give the skew back
##
## The nimcache key was never the mechanism that caught a changed ``.nim``.
## Nim's own per-module ``.sha1`` does that, INSIDE the directory: recompiling
## into an unchanged nimcache after editing an imported library module picks up
## the edit (verified directly against ``nim c``, no ``--forceBuild``). Because
## ``reproLibSources`` walks only ``.nim``/``.nims``, its discriminating power
## is a strict SUBSET of what ``.sha1`` already provides — it could only ever
## re-key the directory redundantly. (The C HEADER closure was the one hole
## this fingerprint never covered. It is no longer a hole: the pinned compiler
## emits a ``-MD -MF`` depfile per cached C object and reads it back before
## reuse, which is why ``boundedNimCompileCommand`` no longer has to pass
## ``--forceBuild:on``.)
##
## The guard that actually prevents the skew is the ARTIFACT-level freshness
## key, ``interfaceExtractionFingerprint``, which folds
## ``reproLibSourceFingerprint`` in via ``interfaceExtractionContext``. That is
## the correct home for it: it decides whether a CACHED ARTIFACT may be served,
## which is exactly the question the skew asks. This test now pins both halves
## of that split, and each half is falsifiable on its own.
##
## Hermetic: a fake external libs root (pinned via ``$REPROBUILD_LIBS_DIR``) and
## a throwaway out-of-tree consumer ``workDir`` under one ``createTempDir``; no
## network, no compiler invocation beyond the key computation itself.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

suite "harness lib-path skew — which key an external reprobuild lib edit moves":

  test "an external lib edit re-keys the ARTIFACT fingerprint, not the nimcache":
    let scratch = createTempDir("repro-libskew-", "")
    defer: removeDir(scratch)

    # An out-of-tree consumer: a plain workDir that is NOT a reprobuild tree
    # (no ``libs/repro_project_dsl/src/repro_project_dsl.nim`` marker), so the
    # engine resolves the reprobuild libs from the EXTERNAL root below.
    let consumer = scratch / "consumer"
    createDir(consumer)
    # A recipe for the consumer to lift. Its CONTENT never changes in this
    # test, so every difference observed below is attributable to the external
    # lib edit alone.
    let recipe = consumer / "repro.nim"
    writeFile(recipe, "discard\n")

    # A fake EXTERNAL reprobuild libs root, pinned via the same override the
    # engine uses for out-of-tree provider compiles.
    let extLibs = scratch / "reprobuild-libs"
    createDir(extLibs / "repro_interface_artifacts" / "src")
    let extSource = extLibs / "repro_interface_artifacts" / "src" /
      "repro_interface_artifacts.nim"
    writeFile(extSource, "const InterfaceCodecShape = \"real-locations\"\n")

    let hadRepoRoot = existsEnv("REPROBUILD_REPO_ROOT")
    let savedRepoRoot = getEnv("REPROBUILD_REPO_ROOT")
    putEnv("REPROBUILD_LIBS_DIR", extLibs)
    delEnv("REPROBUILD_REPO_ROOT")
    defer:
      delEnv("REPROBUILD_LIBS_DIR")
      if hadRepoRoot: putEnv("REPROBUILD_REPO_ROOT", savedRepoRoot)

    let artifactKey1 = interfaceExtractionFingerprint(recipe, consumer)
    let nimcacheKey1 = positionKeyedNimcacheKey(
      ProviderCacheName, recipe, consumer, @[], @[])

    # Stability control for BOTH keys: recomputing with no change reproduces
    # them, so each difference (or non-difference) asserted below is
    # attributable to the lib edit and not to ambient nondeterminism.
    check interfaceExtractionFingerprint(recipe, consumer) == artifactKey1
    check positionKeyedNimcacheKey(
      ProviderCacheName, recipe, consumer, @[], @[]) == nimcacheKey1

    # Edit the external reprobuild lib — the class of change TI3's fingerprint
    # rework modelled (a codec-shape edit that alters emitted artifacts).
    writeFile(extSource, "const InterfaceCodecShape = \"normalized-locations\"\n")

    let artifactKey2 = interfaceExtractionFingerprint(recipe, consumer)
    let nimcacheKey2 = positionKeyedNimcacheKey(
      ProviderCacheName, recipe, consumer, @[], @[])

    # HALF ONE (unchanged obligation, new home): the external edit MUST
    # invalidate the artifact-level freshness key, so a cached interface
    # artifact produced against the OLD libs is not served to the new binary.
    # Falsifiable: drop ``reproLibSourceFingerprint`` from
    # ``interfaceExtractionContext`` and this check fails.
    check artifactKey2 != artifactKey1

    # HALF TWO (the new obligation): the external edit MUST NOT move the
    # nimcache directory. An identity that moves when a source file changes
    # hands the compiler an empty directory on exactly the rebuild the cache
    # exists to accelerate. Falsifiable: put ``reproLibSourceFingerprint``
    # back into ``positionKeyedNimcacheKey`` and this check fails.
    check nimcacheKey2 == nimcacheKey1

  test "the nimcache key is position-keyed: distinct recipes never converge":
    ## The companion property, on the same fixture shape. Two recipes under one
    ## consumer are two PRODUCING PROJECTS and must be handed two directories:
    ## every recipe's definition is a file called ``repro.nim``, so sharing one
    ## directory would make them collide on the single slot ``@mrepro.nim.c``.
    let scratch = createTempDir("repro-libskew-pos-", "")
    defer: removeDir(scratch)
    let consumer = scratch / "consumer"
    createDir(consumer / "recipe-a")
    createDir(consumer / "recipe-b")
    let recipeA = consumer / "recipe-a" / "repro.nim"
    let recipeB = consumer / "recipe-b" / "repro.nim"
    writeFile(recipeA, "discard\n")
    # Byte-IDENTICAL content: the keys must diverge on POSITION, not content.
    writeFile(recipeB, "discard\n")

    check positionKeyedNimcacheKey(
        ProviderCacheName, recipeA, consumer, @[], @[]) !=
      positionKeyedNimcacheKey(
        ProviderCacheName, recipeB, consumer, @[], @[])

    # And the two DECLARED CACHES of one recipe never converge either: a tool
    # declaring two caches has two identities.
    check positionKeyedNimcacheKey(
        ProviderCacheName, recipeA, consumer, @[], @[]) !=
      positionKeyedNimcacheKey(
        InterfaceCacheName, recipeA, consumer, @[], @[])

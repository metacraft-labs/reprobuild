## Harness lib-path skew regression (interface/provider fingerprint).
##
## The provider-nimcache key (``sharedProviderNimcacheKey``) MUST reflect the
## EXTERNAL reprobuild libs an out-of-tree consumer compiles its provider /
## interface recipes against — not ONLY the consumer's own ``workDir/libs``.
## ``reproLibPathFlags`` resolves that external root (``$REPROBUILD_LIBS_DIR`` /
## ``$REPROBUILD_REPO_ROOT`` → the running ``repro`` binary's own checkout →
## a sibling ``../reprobuild/``) and puts it on the recipe compile's ``--path``.
##
## If the freshness key omits that root, a reprobuild lib edit (e.g. the
## interface-artifact codec's fingerprint shape) does NOT invalidate the shared
## nimcache: the extract-runner harness reuses a STALE compiled
## ``repro_interface_artifacts`` and emits interface artifacts the freshly-built
## ``repro`` binary cannot validate — surfacing as "interface fingerprint
## mismatch". This is the harness↔binary skew.
##
## Falsifiability: mutating a ``.nim`` file under the external reprobuild libs
## root MUST change ``sharedProviderNimcacheKey``. Before the fix (which
## fingerprinted only ``workDir/libs``) the key was invariant to that edit, so
## ``key2 == key1`` and the final check fails.
##
## Hermetic: a fake external libs root (pinned via ``$REPROBUILD_LIBS_DIR``) and
## a throwaway out-of-tree consumer ``workDir`` under one ``createTempDir``; no
## network, no compiler invocation beyond the key computation itself.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

suite "harness lib-path skew — provider-nimcache key tracks external reprobuild libs":

  test "external reprobuild lib edit invalidates the shared provider-nimcache key":
    let scratch = createTempDir("repro-libskew-", "")
    defer: removeDir(scratch)

    # An out-of-tree consumer: a plain workDir that is NOT a reprobuild tree
    # (no ``libs/repro_project_dsl/src/repro_project_dsl.nim`` marker), so the
    # engine resolves the reprobuild libs from the EXTERNAL root below.
    let consumer = scratch / "consumer"
    createDir(consumer)

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

    let key1 = sharedProviderNimcacheKey(consumer, @[], @[])
    # Stability control: recomputing with no change yields the SAME key, so the
    # difference asserted below is attributable to the lib edit alone.
    check sharedProviderNimcacheKey(consumer, @[], @[]) == key1

    # Edit the external reprobuild lib — the class of change TI3's fingerprint
    # rework modelled (a codec-shape edit that alters emitted artifacts).
    writeFile(extSource, "const InterfaceCodecShape = \"normalized-locations\"\n")
    let key2 = sharedProviderNimcacheKey(consumer, @[], @[])

    # The fix: the external edit MUST invalidate the key so the harness
    # recompiles against the current libs (matching the running binary).
    check key2 != key1

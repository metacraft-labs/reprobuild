## The provider-compile cache entry's identity must be a content-addressed
## function of everything the compile consumes, and of nothing else.
##
## This is the whole safety argument for putting a compiled ELF into a cache
## other machines read. A fingerprint keyed on a timestamp is a statement
## about one machine's clock and must never cross that boundary, and the
## failure mode of getting the key wrong is not a miss — it is serving a
## binary built from inputs the consumer does not have, silently, behind a
## green build.
##
## The property that matters most is the reprobuild library sources: they are
## compiled INTO the provider binary, and a key that does not move when they
## change serves a binary linked against code the consumer does not have. The
## identity covers them twice — through ``providerFingerprint`` directly, and
## through the action key's ``ProviderArtifactId``, which folds
## ``frontendRuntimeIdentity`` (itself ``reproLibSourceFingerprint``).
##
## Stated so a reader is not misled about what this gate can catch: because
## the coverage is doubled, removing EITHER term from the identity leaves
## every case below green. Removing BOTH reddens the first two. The gate
## therefore pins the PROPERTY — "content moves the key" — and not the
## particular derivation, which is the right thing for it to pin; the
## redundancy is defended in the module's own comment, not here.
##
## No mock objects. The identities are derived by the shipped
## ``providerCompileCacheIdentity`` from plans built by the shipped
## ``providerCompilePlan``, against real files. The work directory is
## synthetic so the library source set is the handful of files this test owns
## rather than the checkout it runs from.

import std/[os, strutils, tables, times, unittest]

import repro_core
import repro_hash
import repro_interface_artifacts
import repro_binary_cache_client/cache_key
import repro_binary_cache_client/provider_compile_cache
import repro_build_engine/platform as enginePlatform

const
  dslStub = "const reproProjectDslStub* = 1\n"
  libV1 = "const libraryConstant* = 1\n"
  libV2 = "const libraryConstant* = 2\n"
  recipeV1 = """
package cacheKeyGate:
  build:
    discard
"""
  recipeV2 = """
package cacheKeyGate:
  build:
    discard
    discard
"""

type Fixture = object
  root, workDir, libPath, modulePath, binPath: string

proc newFixture(name: string): Fixture =
  result.root = getTempDir() / "provider-cache-key-" & name & "-" &
    $getCurrentProcessId()
  removeDir(extendedPath(result.root))
  result.workDir = result.root / "workspace"
  result.libPath = result.workDir / "libs" / "demo" / "src" / "demo.nim"
  createDir(extendedPath(parentDir(result.libPath)))
  writeFile(extendedPath(result.libPath), libV1)
  let dslPath = result.workDir / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim"
  createDir(extendedPath(parentDir(dslPath)))
  writeFile(extendedPath(dslPath), dslStub)
  result.modulePath = result.root / "project" / "repro.nim"
  createDir(extendedPath(parentDir(result.modulePath)))
  writeFile(extendedPath(result.modulePath), recipeV1)
  result.binPath = result.root / "out" / "provider" / "project-provider"
  createDir(extendedPath(result.root / "out"))

proc ifpA(): ContentDigest = casDigest(toBytes("interface-A"))
proc ifpB(): ContentDigest = casDigest(toBytes("interface-B"))

proc keyOf(fx: Fixture; ifp: ContentDigest; project = "cacheKeyGate"): string =
  let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp, fx.workDir)
  providerCompileEntryKeyHex(plan, project, fx.root)

suite "the provider-compile cache entry key is content-addressed":

  test "a reprobuild library source edit moves the key":
    # THE case. The action key alone does not mention these files, so a key
    # that does not move here is a key that serves a binary linked against
    # different libraries.
    let fx = newFixture("lib")
    defer: removeDir(extendedPath(fx.root))
    let before = keyOf(fx, ifpA())
    writeFile(extendedPath(fx.libPath), libV2)
    let after = keyOf(fx, ifpA())
    check before.len == 64
    check before != after

  test "a recipe source edit moves the key":
    let fx = newFixture("recipe")
    defer: removeDir(extendedPath(fx.root))
    let before = keyOf(fx, ifpA())
    writeFile(extendedPath(fx.modulePath), recipeV2)
    check before != keyOf(fx, ifpA())

  test "a different project interface moves the key":
    let fx = newFixture("iface")
    defer: removeDir(extendedPath(fx.root))
    check keyOf(fx, ifpA()) != keyOf(fx, ifpB())

  test "a different project name moves the key":
    let fx = newFixture("name")
    defer: removeDir(extendedPath(fx.root))
    check keyOf(fx, ifpA(), "cacheKeyGate") != keyOf(fx, ifpA(), "otherGate")

  test "nothing but content moves the key — touching a file does not":
    # The negative that makes the four positives mean something. If the key
    # were keyed on stamps rather than content this would move, and the entry
    # would be re-published on every run and never hit.
    let fx = newFixture("touch")
    defer: removeDir(extendedPath(fx.root))
    let before = keyOf(fx, ifpA())
    # Rewrite both files with byte-identical content and a new mtime.
    writeFile(extendedPath(fx.libPath), libV1)
    writeFile(extendedPath(fx.modulePath), recipeV1)
    setLastModificationTime(extendedPath(fx.libPath),
      getLastModificationTime(extendedPath(fx.libPath)) + initDuration(hours = 3))
    check before == keyOf(fx, ifpA())

  test "the entry is scoped to a concrete platform, not the native sentinel":
    # An ELF must not be reachable under a key a consumer on another
    # architecture can derive. The engine's own publish sites fold the
    # ``native`` sentinel for same-platform builds, which is right for a
    # recipe and wrong for a compiled artifact.
    let fx = newFixture("platform")
    defer: removeDir(extendedPath(fx.root))
    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifpA(),
      fx.workDir)
    let identity = providerCompileCacheIdentity(plan, "cacheKeyGate", fx.root)
    let tag = identity.selectedOptions[enginePlatform.CachePlatformTagOptionKey]
    check tag == enginePlatform.buildPlatformTriple()
    check tag != enginePlatform.NativeTriple
    check tag.contains("-")
    # And the platform triple itself is populated, not left at a default.
    check identity.platform.cpu.len > 0
    check identity.platform.os.len > 0

  test "the derived key is a stable 64-char hex and survives a round trip":
    let fx = newFixture("stable")
    defer: removeDir(extendedPath(fx.root))
    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifpA(),
      fx.workDir)
    let identity = providerCompileCacheIdentity(plan, "cacheKeyGate", fx.root)
    let hex = deriveCacheEntryKeyHex(identity)
    check hex.len == 64
    check hex == hex.toLowerAscii()
    check hex == providerCompileEntryKeyHex(plan, "cacheKeyGate", fx.root)

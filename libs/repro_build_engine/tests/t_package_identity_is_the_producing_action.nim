## reprobuild#171 — a source package's cache identity must change with
## everything that decides what the package is, and lookup and publication
## must use the same key.
##
## The legacy materialized-package key hashed the entry `repro.nim` alone, so
## a change in an IMPORTED recipe (`const implementation = 1` -> `2`) kept
## the key and could alias two implementations. That key now refuses reuse
## outright (`sourceCacheEntryIdentity`'s pending marker). Substitution goes
## through the portable memo plane instead, BuildXL-style: a package is
## identified by the portable strong fingerprint of the action that produces
## it -- its whole static description (whatever recipe code, however
## imported, put into it) plus the content of everything it consumed.
##
## Each case below changes one thing a recipe decides and checks the key
## moves; the first checks two checkouts of an unchanged recipe agree; the
## last checks the record published is the record a lookup finds.

import std/[options, os, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core/paths
import repro_hash
import repro_local_store

let TmpDir = "build/test-tmp/t_package_identity_is_the_producing_action-" &
  testCaseScratchSlug()

type Recipe = object
  implementation: string   ## what an imported recipe module contributes
  option: string           ## a package option, reaching the action's env
  toolchain: string        ## the bytes of a tool the action consumes
  prefix: string           ## where the package installs

proc baseline(): Recipe =
  Recipe(implementation: "1", option: "--enable-x", toolchain: "cc v1",
         prefix: "prefix")

type Produced = object
  result: ActionResult
  published: seq[PortableMemoRecord]
  sharedRoot: string
  project: string

proc produce(checkout: string; recipe: Recipe): Produced =
  let project = absolutePath(TmpDir / checkout / "pkg")
  createDir(project / "toolchain")
  writeFile(project / "toolchain" / "cc", recipe.toolchain)
  createDir(project / recipe.prefix / "bin")
  writeFile(project / recipe.prefix / "bin" / "tool", "tool bytes")
  createDir(project / "out")
  let action = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "install-mirror-pkg",
    inputs: @[project / "toolchain" / "cc"],
    outputs: @[project / "out" / "mirror.stamp"],
    declaredOutputs: @[project / recipe.prefix],
    env: @["PKG_OPTIONS=" & recipe.option],
    cwd: project,
    cacheable: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: weakFingerprintFromText("install-mirror-pkg"),
    builtinText: "implementation=" & recipe.implementation & "\n",
    publishToBinaryCache: true)
  result.project = project
  result.sharedRoot = absolutePath(TmpDir / checkout / "shared")
  var config = defaultBuildEngineConfig(TmpDir / checkout / "cache")
  config.maxParallelism = 1
  config.actionCacheRoot = result.sharedRoot
  config.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked)]
  var published: ref seq[PortableMemoRecord]
  new(published)
  config.portableMemoPublisher = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
    {.cast(gcsafe).}:
      published[].add(record)
    ""
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  require run.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
  require run.results[0].portable
  result.result = run.results[0]
  result.published = published[]

suite "reprobuild#171: a package is identified by the action producing it":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "two checkouts of an unchanged recipe agree":
    let a = produce("a", baseline())
    let b = produce("somewhere/much/deeper/b", baseline())
    check a.result.portableWeakHex == b.result.portableWeakHex
    check a.result.portableStrongHex == b.result.portableStrongHex

  test "a change in imported recipe code moves the key (the #171 case)":
    var changed = baseline()
    changed.implementation = "2"
    let a = produce("a", baseline())
    let b = produce("b", changed)
    check a.result.portableStrongHex != b.result.portableStrongHex

  test "a changed option moves the key":
    var changed = baseline()
    changed.option = "--disable-x"
    let a = produce("a", baseline())
    let b = produce("b", changed)
    check a.result.portableStrongHex != b.result.portableStrongHex

  test "a changed toolchain moves the key":
    var changed = baseline()
    changed.toolchain = "cc v2"
    let a = produce("a", baseline())
    let b = produce("b", changed)
    # Same description, different consumed bytes: the weak key stays, the
    # strong one -- the package's identity -- moves.
    check a.result.portableWeakHex == b.result.portableWeakHex
    check a.result.portableStrongHex != b.result.portableStrongHex

  test "a changed install prefix moves the key":
    var changed = baseline()
    changed.prefix = "other-prefix"
    let a = produce("a", baseline())
    let b = produce("b", changed)
    check a.result.portableStrongHex != b.result.portableStrongHex

  test "the record published is the record a lookup finds":
    let a = produce("a", baseline())
    require a.published.len == 1
    let sent = a.published[0]
    check sent.weakHex == a.result.portableWeakHex
    check sent.strongHex == a.result.portableStrongHex
    check sent.outputs == a.result.portableOutputs
    # Another checkout of the same recipe, looking the package up by what it
    # would build, finds exactly that record.
    let b = produce("b", baseline())
    let roots = @[LogicalRoot(label: "project", path: b.project,
                              kind: lrkTracked)]
    let found = lookupMemo(a.sharedRoot / "portable-memo", roots,
      sent.weakHex)
    require found.isSome
    check found.get().strongHex == sent.strongHex
    check found.get().outputs == sent.outputs

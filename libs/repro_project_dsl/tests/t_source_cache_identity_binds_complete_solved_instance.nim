## M13 / Reprobuild #171 — a source package's cache identity must be a
## function of the COMPLETE solved instance, and every lookup/publication
## path must agree on the key it produces.
##
## NO MOCKS. Every case builds a real project tree in a real temporary
## directory on the real filesystem and drives the real production
## entry points:
##
##   * ``solvedSourceCacheEntryIdentity`` — the canonical identity;
##   * ``substituteMaterializedBinaryCacheEntries`` (repro_cli_support) —
##     the materialized-substitution LOOKUP path;
##   * ``publishMaterializedBinaryCacheEntries`` (repro_build_engine) —
##     the explicit-publication / operator-BACKFILL path;
##   * ``deriveActionCacheKeyHex`` (repro_build_engine) — the helper the
##     engine's AUTOMATIC publication hook folds the cache-platform tag
##     through before handing the identity to the publisher closure;
##   * ``materializedCacheActionJsonForTest`` — graph inspection's
##     ``binaryCacheKey`` / ``binaryCacheIdentityError``.
##
## The only argument passed as ``nil`` is the engine's
## ``BinaryCachePublisher`` closure, which is a production parameter of
## ``publishMaterializedBinaryCacheEntries`` and not a stand-in for a
## collaborator: the key under test is already recorded on the result
## before the publisher would be consulted, so the case reads the real
## backfill key without contacting a cache endpoint. Likewise both
## materialized paths are driven with an empty publish prefix, which is
## the production early-return that reports the key without touching the
## filesystem or the network.
##
## Non-vacuity: "relocation alone does not change the identity" is the
## control that forbids the cheap wrong fix of hashing absolute paths,
## and "missing evidence fails closed" is the control that forbids
## deleting the pending guard.

{.define: reproMaterializedCacheTest.}

import std/[json, options, os, strutils, tempfiles, unittest]

import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcsTypes
import repro_build_engine
import repro_cli_support
import repro_project_dsl
import repro_project_dsl/source_cache_identity

const
  DepAlpha = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
  DepBeta = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

proc writeProject(root: string) =
  ## A project whose entry recipe reaches imported recipe code, a
  ## transitively imported module, an ``include``-d SDK generator, and a
  ## local non-Nim source input.
  createDir(root)
  writeFile(root / "repro.nim",
    "import recipe\n" &
    "include sdk/generator\n" &
    "const entry = 1\n")
  writeFile(root / "recipe.nim",
    "import ./internal/helpers\n" &
    "const implementation = 1\n")
  createDir(root / "internal")
  writeFile(root / "internal" / "helpers.nim", "const helper = 1\n")
  createDir(root / "sdk")
  writeFile(root / "sdk" / "generator.nim", "const generated = 1\n")
  createDir(root / "src")
  writeFile(root / "src" / "impl.c", "int impl(void) { return 1; }\n")

proc solvedInstance(root: string): SolvedSourceInstance =
  SolvedSourceInstance(
    projectRoot: root,
    packageName: "probe",
    packageVersion: "1.0",
    declaredSourceInputs: @["src/impl.c"],
    selectedOptions: @[("featureX", "on")],
    optionsSolved: true,
    dependencyInstances: @[DepAlpha],
    dependenciesResolved: true,
    platform: bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
    toolchain: bcsTypes.ToolchainIdentity(
      name: "cmake", version: "3.29.2",
      hostLdSoAbi: "x86_64-linux-gnu", extraFingerprint: ""))

proc probeAction(root: string; identity: CacheEntryIdentity): BuildAction =
  ## A tagged public-interface action with no publish prefix: both
  ## materialized paths record the derived key and then return on the
  ## empty-prefix / no-publisher arm, so no cache endpoint is contacted.
  BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakStamp,
    id: "m13-source-package",
    cwd: root,
    publishToBinaryCache: true,
    cacheEntryIdentity: some(identity))

const
  LookupMarker = "materialized-binary-cache-substitute key="
  BackfillMarker = "materialized-binary-cache-publish key="

proc keyAfter(text, marker: string): string =
  let idx = text.find(marker)
  if idx < 0: "" else: text[idx + marker.len .. ^1].strip()

proc lookupResult(action: BuildAction): ActionResult =
  ## The real materialized-substitution LOOKUP path.
  let run = substituteMaterializedBinaryCacheEntries(graph(@[action]))
  doAssert run.results.len == 1
  run.results[0]

proc backfillResult(action: BuildAction): ActionResult =
  ## The real explicit-publication / operator-backfill path.
  let run = publishMaterializedBinaryCacheEntries(graph(@[action]), nil)
  doAssert run.results.len == 1
  run.results[0]

template identityKeyOnEveryPath(instance: SolvedSourceInstance): string =
  ## Derive the key through every production path and require that all of
  ## them produced the same 64-char hex. Evaluates to that key.
  ##
  ## A template, not a proc: ``unittest.check`` only marks the enclosing
  ## CASE failed when it expands inside the case's body, so assertions
  ## hidden in a helper proc would silently degrade to an exit-code-only
  ## signal.
  block:
    let identity = solvedSourceCacheEntryIdentity(instance)
    check cacheEntryIdentityError(identity) == ""
    let action = probeAction(instance.projectRoot, identity)
    let direct = deriveActionCacheKeyHex(action)
    let lookupRes = lookupResult(action)
    let backfillRes = backfillResult(action)
    let inspected = materializedCacheActionJsonForTest(action)
    check direct.len == 64
    check keyAfter(lookupRes.reason, LookupMarker) == direct
    check keyAfter(backfillRes.reason, BackfillMarker) == direct
    check inspected["binaryCacheIdentityError"].getStr() == ""
    check inspected["binaryCacheKey"].getStr() == direct
    direct

template failsClosed(instance: SolvedSourceInstance) =
  ## Missing evidence must refuse a key on every path, not silently
  ## produce one over partial data.
  block:
    let identity = solvedSourceCacheEntryIdentity(instance)
    check cacheEntryIdentityError(identity).len > 0
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(identity)
    let action = probeAction(instance.projectRoot, identity)
    let lookupRes = lookupResult(action)
    check lookupRes.cacheDecision == cdMiss
    check "incomplete binary-cache identity" in lookupRes.stderr
    check "incomplete binary-cache identity" in backfillResult(action).stderr
    let inspected = materializedCacheActionJsonForTest(action)
    check inspected["binaryCacheKey"].getStr() == ""
    check "incomplete binary-cache identity" in
      inspected["binaryCacheIdentityError"].getStr()

suite "test_source_cache_identity_binds_complete_solved_instance":

  test "a complete solved instance yields one key on every path":
    let root = createTempDir("m13-complete-", "")
    defer: removeDir(root)
    writeProject(root)
    let key = identityKeyOnEveryPath(solvedInstance(root))
    check key.len == 64
    # Positive control from #171: editing the ENTRY recipe moves the key.
    writeFile(root / "repro.nim",
      "import recipe\ninclude sdk/generator\nconst entry = 2\n")
    check identityKeyOnEveryPath(solvedInstance(root)) != key

  test "mutating an imported recipe module changes the identity":
    # The headline defect of Reprobuild #171: repro.nim says
    # ``import recipe``; recipe.nim's implementation changes.
    let root = createTempDir("m13-imported-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    writeFile(root / "recipe.nim",
      "import ./internal/helpers\nconst implementation = 2\n")
    check identityKeyOnEveryPath(solvedInstance(root)) != before

  test "mutating transitively imported code changes the identity":
    let root = createTempDir("m13-transitive-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    writeFile(root / "internal" / "helpers.nim", "const helper = 2\n")
    check identityKeyOnEveryPath(solvedInstance(root)) != before

  test "mutating an SDK generator input changes the identity":
    let root = createTempDir("m13-sdk-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    writeFile(root / "sdk" / "generator.nim", "const generated = 2\n")
    check identityKeyOnEveryPath(solvedInstance(root)) != before

  test "mutating a local non-Nim source input changes the identity":
    let root = createTempDir("m13-local-source-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    writeFile(root / "src" / "impl.c", "int impl(void) { return 2; }\n")
    check identityKeyOnEveryPath(solvedInstance(root)) != before

  test "changing a selected option changes the identity":
    let root = createTempDir("m13-option-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    var mutated = solvedInstance(root)
    mutated.selectedOptions = @[("featureX", "off")]
    check identityKeyOnEveryPath(mutated) != before

  test "changing a dependency instance changes the identity":
    let root = createTempDir("m13-dependency-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    var mutated = solvedInstance(root)
    mutated.dependencyInstances = @[DepBeta]
    check identityKeyOnEveryPath(mutated) != before

  test "changing the target ABI changes the identity":
    let root = createTempDir("m13-abi-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    var mutated = solvedInstance(root)
    mutated.platform = bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "musl", libcVariant: "musl")
    check identityKeyOnEveryPath(mutated) != before

  test "changing the toolchain changes the identity":
    let root = createTempDir("m13-toolchain-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = identityKeyOnEveryPath(solvedInstance(root))
    var mutated = solvedInstance(root)
    mutated.toolchain = bcsTypes.ToolchainIdentity(
      name: "cmake", version: "3.30.0",
      hostLdSoAbi: "x86_64-linux-gnu", extraFingerprint: "")
    check identityKeyOnEveryPath(mutated) != before

  test "relocation alone does not change the identity":
    # The non-vacuity control: an identity that merely hashed absolute
    # paths would pass every "changes it" case above and fail here.
    let origin = createTempDir("m13-relocation-origin-", "")
    defer: removeDir(origin)
    let relocatedParent = createTempDir("m13-relocation-target-", "")
    defer: removeDir(relocatedParent)
    writeProject(origin)
    let relocated = relocatedParent / "a-differently-named-deeper-root"
    copyDir(origin, relocated)
    check origin != relocated
    check identityKeyOnEveryPath(solvedInstance(origin)) ==
      identityKeyOnEveryPath(solvedInstance(relocated))
    # ...and the relocated copy is still sensitive to its own content.
    let before = identityKeyOnEveryPath(solvedInstance(relocated))
    writeFile(relocated / "recipe.nim",
      "import ./internal/helpers\nconst implementation = 3\n")
    check identityKeyOnEveryPath(solvedInstance(relocated)) != before

  test "missing evidence fails closed":
    let root = createTempDir("m13-fail-closed-", "")
    defer: removeDir(root)
    writeProject(root)

    # A declared local source input that does not exist.
    var noInput = solvedInstance(root)
    noInput.declaredSourceInputs = @["src/impl.c", "src/absent.c"]
    failsClosed(noInput)

    # An explicitly relative import that does not resolve.
    writeFile(root / "recipe.nim",
      "import ./internal/helpers\nimport ./internal/vanished\n")
    failsClosed(solvedInstance(root))
    writeFile(root / "recipe.nim",
      "import ./internal/helpers\nconst implementation = 1\n")

    # Options that were never solved.
    var noOptions = solvedInstance(root)
    noOptions.optionsSolved = false
    failsClosed(noOptions)

    # Dependency instances that were never resolved.
    var noDeps = solvedInstance(root)
    noDeps.dependenciesResolved = false
    failsClosed(noDeps)

    # A dependency instance key that is not a well-formed entry key.
    var badDep = solvedInstance(root)
    badDep.dependencyInstances = @["not-a-cache-entry-key"]
    failsClosed(badDep)

    # An unresolved target triple.
    var noTarget = solvedInstance(root)
    noTarget.platform = bcsTypes.PlatformTriple()
    failsClosed(noTarget)

    # A toolchain that was never actually identified.
    var noToolchain = solvedInstance(root)
    noToolchain.toolchain = bcsTypes.ToolchainIdentity(name: "cmake")
    failsClosed(noToolchain)

    # The reserved pending marker may never arrive through the option
    # channel as ordinary data.
    var smuggled = solvedInstance(root)
    smuggled.selectedOptions = @[(PendingCacheIdentityOptionKey, "")]
    failsClosed(smuggled)

    # No project file at all.
    let empty = createTempDir("m13-fail-closed-empty-", "")
    defer: removeDir(empty)
    failsClosed(solvedInstance(empty))

  test "the legacy unsolved constructor stays pending":
    # M13 keeps every production call site that cannot yet supply a
    # solved instance non-substitutable and non-publishable.
    let root = createTempDir("m13-legacy-", "")
    defer: removeDir(root)
    writeProject(root)
    let identity = sourceCacheEntryIdentity(root, "probe", "1.0", "cmake")
    check cacheEntryIdentityError(identity).len > 0
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(identity)

  test "the source/provider revision moves with imported recipe code":
    # Production-API regression pin for Reprobuild #171 itself.
    let root = createTempDir("m13-provider-revision-", "")
    defer: removeDir(root)
    writeProject(root)
    let before = sourceProviderRevisionHex(root)
    check before.len == 32
    writeFile(root / "recipe.nim",
      "import ./internal/helpers\nconst implementation = 2\n")
    check sourceProviderRevisionHex(root) != before

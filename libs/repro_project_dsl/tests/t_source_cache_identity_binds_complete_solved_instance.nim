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
## Two arguments are supplied in-process rather than by production
## wiring, and both are production PARAMETERS of the entry point under
## test rather than stand-ins for a collaborator:
##
##   * ``nil`` as ``publishMaterializedBinaryCacheEntries``'s
##     ``BinaryCachePublisher``. The key under test is already recorded
##     on the result before the publisher would be consulted, so the
##     case reads the real backfill key without contacting a cache
##     endpoint. Both materialized paths are additionally driven with an
##     empty publish prefix, which is the production early-return that
##     reports the key without touching the filesystem or the network.
##   * a RECORDING ``BinaryCachePublisher`` closure that captures the
##     ``BinaryCachePublishRequest`` and returns ``ok``. This one is
##     load-bearing and is the reason the four-path assertion is no
##     longer inert. The publisher seam is the only place the identity
##     the engine actually PUBLISHES becomes observable: reading the
##     result's reason string (what this test used to do) reads a value
##     re-derived by ``deriveActionCacheKeyHex``, so every "path" folded
##     through the same helper and no two of them could ever disagree.
##     Verification proved that inert by injecting a junk option into
##     ``applyCachePlatformTag`` and watching all 13 cases stay green.
##     The recorder is not a mock of the cache: it performs no cache
##     behaviour, asserts nothing itself, and exists only so the real
##     ``BinaryCachePublishRequest.identity`` can be compared against the
##     lookup key. The same shape is used by
##     ``repro_build_engine/tests/test_binary_cache_publisher_hook.nim``.
##
## Non-vacuity: "relocation alone does not change the identity" is the
## control that forbids the cheap wrong fix of hashing absolute paths;
## "missing evidence fails closed" is the control that forbids deleting
## the pending guard; and "a genuine external import does not make the
## identity refuse" is the control that forbids the equally cheap wrong
## fix of refusing on everything that does not resolve locally, which
## would make every identity permanently PENDING.
##
## The same pairing governs the cases added for the command-line
## ``--path`` channel and the compile-time-read scan. "supplied search
## roots do not make an external import refuse" and "a genuine
## compile-time read is still caught" are the controls; "supplied search
## roots do not leak absolute paths into the digest" is the relocation
## control for an input that ARRIVES as an absolute path, and it is
## needed because hashing the supplied root, or the absolute spelling of
## what it reaches, would pass every "changes the identity" case while
## breaking relocation.
##
## What this file does NOT prove, stated so the green result is not read
## for more than it is: that a caller's ``effectiveSearchRoots`` is the
## COMPLETE or correct root set of the real compile command (nothing
## inside the identity can check that; the cases only fix what happens
## when it is supplied and when it is not); that the compile-time-read
## scan is a parse rather than a better-informed textual scan — a file
## that shadows ``slurp`` and ALSO reaches ``system``'s through an
## overload its declaration does not shadow is missed, and missed there
## means aliased rather than refused, which ``ca7864d0`` was not; that any
## real cache endpoint, upload or substitution works; and that any
## production call site produces a keyable identity — every one of them
## still uses the legacy constructor and is still refused.

{.define: reproMaterializedCacheTest.}

import std/[algorithm, json, options, os, strutils, tables, tempfiles, unittest]

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
    effectiveSearchRoots: @[],
    searchRootsKnown: true,
    selectedOptions: @[("featureX", "on")],
    optionsSolved: true,
    dependencyInstances: @[DepAlpha],
    dependenciesResolved: true,
    platform: bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
    toolchain: bcsTypes.ToolchainIdentity(
      name: "cmake", version: "3.29.2",
      hostLdSoAbi: "x86_64-linux-gnu", extraFingerprint: ""))

proc bareInstance(root: string): SolvedSourceInstance =
  ## Same solved instance, but with no declared non-Nim source inputs —
  ## for the trees the resolution cases build, which have none.
  result = solvedInstance(root)
  result.declaredSourceInputs = @[]

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

const MaterializedPrefixName = ".m13-materialized-prefix"

proc publishProbeAction(root: string; identity: CacheEntryIdentity):
    BuildAction =
  ## The SAME tagged action, but materialized: a real declared output
  ## that really exists on disk, so ``publishMaterializedBinaryCacheEntries``
  ## walks all the way to the publisher hand-off instead of returning on
  ## the empty-prefix arm. That hand-off is the only place the identity
  ## the engine actually publishes becomes observable.
  let prefix = root / MaterializedPrefixName
  createDir(prefix)
  writeFile(prefix / "artifact.txt", "materialized\n")
  BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakStamp,
    id: "m13-source-package",
    cwd: root,
    publishToBinaryCache: true,
    declaredOutputs: @[prefix],
    outputs: @[prefix],
    cacheEntryIdentity: some(identity))

type
  PublishRecorder = ref object
    ## Capture for the recording publisher closure — see the file header.
    requests: seq[BinaryCachePublishRequest]

proc recordingPublisher(recorder: PublishRecorder): BinaryCachePublisher =
  result = proc(req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    recorder.requests.add(req)
    BinaryCachePublishResult(ok: true, statusCode: 200, error: "",
      bytesUploaded: 0)

proc publishedIdentityFor(root: string; identity: CacheEntryIdentity):
    CacheEntryIdentity =
  ## The identity ``publishMaterializedBinaryCacheEntries`` actually
  ## hands the publisher. Raises via ``doAssert`` when the publisher was
  ## never reached, so a silently skipped publish cannot pass as agreement.
  let recorder = PublishRecorder(requests: @[])
  let action = publishProbeAction(root, identity)
  let run = publishMaterializedBinaryCacheEntries(
    graph(@[action]), recordingPublisher(recorder))
  doAssert run.results.len == 1, "publish path produced no result"
  doAssert recorder.requests.len == 1,
    "publisher was never reached: " & run.results[0].stderr
  recorder.requests[0].identity

proc optionNames(idy: CacheEntryIdentity): seq[string] =
  if not idy.selectedOptions.isNil:
    for name in idy.selectedOptions.keys:
      result.add(name)
  result.sort(cmp)

proc expectedPublishedOptionNames(instance: SolvedSourceInstance): seq[string] =
  for (name, _) in instance.selectedOptions:
    result.add(name)
  result.add(CachePlatformTagOptionKey)
  result.sort(cmp)

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
    # The identity the PUBLISHER is actually handed — not a reason string
    # re-derived by the same helper every other path already calls.
    let published = publishedIdentityFor(instance.projectRoot, identity)
    check deriveCacheEntryKeyHex(published) == direct
    # ...and its option set is pinned exactly, so a junk option folded in
    # by ``applyCachePlatformTag`` (which every path shares, and which a
    # pure agreement assertion therefore cannot see) fails this case.
    check optionNames(published) == expectedPublishedOptionNames(instance)
    check published.selectedOptions[CachePlatformTagOptionKey] == NativeTriple
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

  # -------------------------------------------------------------------
  # Resolution gaps the first pass at #171 left open. Each of these was
  # a module Nim compiles into the package that the closure scan did not
  # see -- and, crucially, did not REFUSE over either: it produced a
  # digest across the rest, so two implementations differing only in the
  # invisible input shared one key. That is the #171 aliasing class
  # surviving inside the fix for #171.
  # -------------------------------------------------------------------

  test "a module reachable only through a --path search root binds":
    let root = createTempDir("m13-search-root-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "config.nims", "switch(\"path\", \"lib\")\n")
    writeFile(root / "repro.nim", "import searchmod\nconst entry = 1\n")
    createDir(root / "lib")
    writeFile(root / "lib" / "searchmod.nim", "const searched = 1\n")
    let before = identityKeyOnEveryPath(bareInstance(root))
    check "lib/searchmod.nim" in solvedSourceClosure(root).files
    writeFile(root / "lib" / "searchmod.nim", "const searched = 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

  test "an include carrying its own extension binds":
    let root = createTempDir("m13-include-ext-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "include \"frag.inc\"\ninclude other.nim\nconst entry = 1\n")
    writeFile(root / "frag.inc", "const fragment = 1\n")
    writeFile(root / "other.nim", "const other = 1\n")
    let before = identityKeyOnEveryPath(bareInstance(root))
    check "frag.inc" in solvedSourceClosure(root).files
    writeFile(root / "frag.inc", "const fragment = 2\n")
    let afterInc = identityKeyOnEveryPath(bareInstance(root))
    check afterInc != before
    writeFile(root / "other.nim", "const other = 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != afterInc

  test "a package-directory import binds":
    let root = createTempDir("m13-pkgdir-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim", "import pkgdir\nconst entry = 1\n")
    createDir(root / "pkgdir")
    writeFile(root / "pkgdir" / "pkgdir.nim", "const inside = 1\n")
    let before = identityKeyOnEveryPath(bareInstance(root))
    check "pkgdir/pkgdir.nim" in solvedSourceClosure(root).files
    writeFile(root / "pkgdir" / "pkgdir.nim", "const inside = 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

  test "a compile-time file read binds":
    # ``staticRead`` / ``slurp`` have no import syntax at all, so the
    # bytes they fold into the build were invisible to the closure, and
    # no production call site populates ``declaredSourceInputs``.
    let root = createTempDir("m13-static-read-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "const blob = staticRead(\"data/payload.txt\")\n" &
      "import ./helper\n" &
      "const entry = 1\n")
    writeFile(root / "helper.nim", "const slurped = slurp \"note.txt\"\n")
    createDir(root / "data")
    writeFile(root / "data" / "payload.txt", "payload 1\n")
    writeFile(root / "note.txt", "note 1\n")
    let before = identityKeyOnEveryPath(bareInstance(root))
    let files = solvedSourceClosure(root).files
    check "data/payload.txt" in files
    check "note.txt" in files
    writeFile(root / "data" / "payload.txt", "payload 2\n")
    let afterPayload = identityKeyOnEveryPath(bareInstance(root))
    check afterPayload != before
    writeFile(root / "note.txt", "note 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != afterPayload

  test "an unresolvable candidate local module fails closed":
    # The rule: anything that COULD be project source and cannot be
    # resolved is missing evidence, not an assumed external library.
    let dirEvidence = createTempDir("m13-unresolved-dir-", "")
    defer: removeDir(dirEvidence)
    createDir(dirEvidence)
    writeFile(dirEvidence / "repro.nim", "import internal/vanished\n")
    createDir(dirEvidence / "internal")
    writeFile(dirEvidence / "internal" / "present.nim", "const p = 1\n")
    failsClosed(bareInstance(dirEvidence))

    let includeEvidence = createTempDir("m13-unresolved-include-", "")
    defer: removeDir(includeEvidence)
    createDir(includeEvidence)
    writeFile(includeEvidence / "repro.nim", "include \"absent.inc\"\n")
    failsClosed(bareInstance(includeEvidence))

    let extEvidence = createTempDir("m13-unresolved-ext-", "")
    defer: removeDir(extEvidence)
    createDir(extEvidence)
    writeFile(extEvidence / "repro.nim", "import gone.nim\n")
    failsClosed(bareInstance(extEvidence))

    # A project whose search-root set cannot be evaluated: the scanner
    # cannot rule ANY unresolved spec out, so it must refuse.
    let dynamicPaths = createTempDir("m13-unresolved-dynamic-", "")
    defer: removeDir(dynamicPaths)
    createDir(dynamicPaths)
    writeFile(dynamicPaths / "config.nims",
      "import std/os\nswitch(\"path\", getEnv(\"SOMEWHERE\"))\n")
    writeFile(dynamicPaths / "repro.nim", "import mystery\nconst e = 1\n")
    failsClosed(bareInstance(dynamicPaths))

  test "a genuine external import does not make the identity refuse":
    # The control that forbids "refuse on everything unresolved". An
    # identity that is permanently PENDING can neither substitute nor
    # publish, so over-refusal is as useless as under-binding.
    let root = createTempDir("m13-external-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "import std/os\n" &
      "import std/[strutils, tables]\n" &
      "from std/sequtils import toSeq\n" &
      "import pkg/somepackage\n" &
      "import repro_project_dsl\n" &
      "import repro_binary_cache_client/cache_key\n" &
      "import ./local_helper\n" &
      "const entry = 1\n")
    writeFile(root / "local_helper.nim", "const helper = 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check closure.files == @["local_helper.nim", "repro.nim"]
    let before = identityKeyOnEveryPath(bareInstance(root))
    check before.len == 64
    # ...and the local module next to the external ones is still bound.
    writeFile(root / "local_helper.nim", "const helper = 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

  test "path de-duplication follows the filesystem's case rule":
    # The visited-set key used to fold case unconditionally. On a
    # case-SENSITIVE filesystem -- Linux, the build target -- that
    # merges two genuinely distinct files into one closure entry, which
    # is the same aliasing class #171 is about, re-introduced by the
    # dedup table. The rule is a platform fact, not a convenience.
    when defined(windows):
      check sourceClosurePathKey("C:/tree/Module.nim") ==
        sourceClosurePathKey("C:/tree/module.nim")
    else:
      check sourceClosurePathKey("/tree/Module.nim") !=
        sourceClosurePathKey("/tree/module.nim")
    # Reachable on either platform: one file reached under two spellings
    # of the SAME path must be bound once, not twice.
    let root = createTempDir("m13-case-dedup-", "")
    defer: removeDir(root)
    createDir(root)
    createDir(root / "internal")
    writeFile(root / "internal" / "helpers.nim", "const helper = 1\n")
    when defined(windows):
      writeFile(root / "repro.nim",
        "import ./internal/helpers\nimport ./internal/Helpers\n")
    else:
      writeFile(root / "repro.nim", "import ./internal/helpers\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check closure.files.len == 2

  test "a source input outside the project root fails closed":
    # ``relativePath`` does NOT raise for a cross-drive pair on Windows;
    # it returns the ABSOLUTE path, which used to land straight in the
    # digest and destroy relocation stability silently.
    let root = createTempDir("m13-outside-root-", "")
    defer: removeDir(root)
    writeProject(root)
    var outside = solvedInstance(root)
    outside.declaredSourceInputs = @["src/impl.c", currentSourcePath()]
    check not currentSourcePath().startsWith(root)
    failsClosed(outside)
    # No absolute path may appear in the bound closure of the good case.
    for rel in solvedSourceClosure(root, @["src/impl.c"]).files:
      check not rel.isAbsolute
      check ":" notin rel

  test "a commented-out or quoted import is not evidence":
    # Bytes Nim does not read are provably not an input. Refusing on
    # them is not failing closed, it is failing ALWAYS: a correct
    # project would be permanently unkeyable.
    let root = createTempDir("m13-masked-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "#[\n" &
      "import ./ghost\n" &
      "]#\n" &
      "const doc = \"\"\"\n" &
      "import ./phantom\n" &
      "\"\"\"\n" &
      "## import ./spectre\n" &
      "import ./real\n" &
      "const entry = 1\n")
    writeFile(root / "real.nim", "const real = 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check closure.files == @["real.nim", "repro.nim"]
    check identityKeyOnEveryPath(bareInstance(root)).len == 64

  test "compile-time command execution fails closed":
    # ``gorge`` / ``staticExec`` fold the output of an arbitrary command
    # into the build. There is nothing to bind, so there is no honest
    # digest to produce.
    for call in ["staticExec(\"echo hi\")", "gorge(\"echo hi\")",
                 "gorgeEx(\"echo hi\")"]:
      let root = createTempDir("m13-gorge-", "")
      defer: removeDir(root)
      createDir(root)
      writeFile(root / "repro.nim", "const v = " & call & "\nconst e = 1\n")
      failsClosed(bareInstance(root))

    # A compile-time read whose path is not a literal cannot be bound
    # either, and must not be silently skipped.
    let computed = createTempDir("m13-computed-read-", "")
    defer: removeDir(computed)
    createDir(computed)
    writeFile(computed / "repro.nim",
      "const name = \"data.txt\"\nconst blob = staticRead(name)\n")
    writeFile(computed / "data.txt", "data\n")
    failsClosed(bareInstance(computed))

  # -------------------------------------------------------------------
  # The command-line ``--path`` channel. A search root the compiler is
  # given but no config file records is invisible to any scan of the
  # tree, so a module reachable only through it used to be assumed
  # external, dropped, and a digest produced over the rest: the #171
  # aliasing class, surviving inside the fix for #171. Measured at
  # ca7864d0 on exactly the tree the first case builds — closure digest
  # 337050709747f16fc8c7531ad53184db82f172106ff4377fc5d0e42583179bc1 and
  # cache key 2e5bde3c356780... identical across a change to
  # ``internal/helper.nim``'s ``const implementation`` from 1 to 2.
  #
  # The effective search-root set is therefore a REQUIRED input of the
  # solved instance: supplied, it resolves; unsupplied, the identity
  # refuses instead of digesting.
  # -------------------------------------------------------------------

  test "a module reachable only through a supplied search root binds":
    let root = createTempDir("m13-cmdline-path-", "")
    defer: removeDir(root)
    createDir(root)
    # No config.nims, no nim.cfg, no .nimble: nothing on disk records
    # ``internal`` as a search root. Only the compile command does.
    writeFile(root / "repro.nim", "import helper\nconst entry = 1\n")
    createDir(root / "internal")
    writeFile(root / "internal" / "helper.nim",
      "const implementation = 1\n")

    var instance = bareInstance(root)
    instance.effectiveSearchRoots = @[root / "internal"]
    let closure = solvedSourceClosure(root, @[], instance.effectiveSearchRoots)
    check closure.missing.len == 0
    check "internal/helper.nim" in closure.files
    let before = identityKeyOnEveryPath(instance)

    writeFile(root / "internal" / "helper.nim",
      "const implementation = 2\n")
    check identityKeyOnEveryPath(instance) != before

  test "an unsupplied search-root set fails closed":
    # The other half of the same rule, and the one that makes it
    # fail-CLOSED rather than merely fixable: when the effective compile
    # command was never reconstructed, the scanner cannot know whether a
    # bare spec is external or a module behind an unseen ``--path``, so
    # it must refuse rather than key over the part it can see.
    let root = createTempDir("m13-cmdline-path-unsupplied-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim", "import helper\nconst entry = 1\n")
    createDir(root / "internal")
    writeFile(root / "internal" / "helper.nim",
      "const implementation = 1\n")

    var unsupplied = bareInstance(root)
    unsupplied.searchRootsKnown = false
    unsupplied.effectiveSearchRoots = @[]
    failsClosed(unsupplied)
    # ...and the refusal NAMES the missing evidence rather than failing
    # anonymously, which is what makes it actionable at the call site.
    check "effective compiler search roots" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(unsupplied))
    # A tree with nothing to miss refuses just the same: the input is
    # missing evidence in its own right, not a conditional consequence.
    let plain = createTempDir("m13-cmdline-path-plain-", "")
    defer: removeDir(plain)
    writeProject(plain)
    var plainUnsupplied = solvedInstance(plain)
    plainUnsupplied.searchRootsKnown = false
    failsClosed(plainUnsupplied)

  test "supplied search roots do not make an external import refuse":
    # The no-false-refusal control for the new input. Supplying the
    # effective roots must not turn "this spec resolves nowhere I was
    # told about" into a refusal for specs Nim satisfies from the
    # stdlib or a package, or every real compile command would be
    # permanently unkeyable — as useless as aliasing.
    let root = createTempDir("m13-supplied-external-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "import std/os\n" &
      "import std/[strutils, tables]\n" &
      "from std/sequtils import toSeq\n" &
      "import pkg/somepackage\n" &
      "import repro_project_dsl\n" &
      "import ./local_helper\n" &
      "const entry = 1\n")
    writeFile(root / "local_helper.nim", "const helper = 1\n")
    createDir(root / "lib")
    writeFile(root / "lib" / "unrelated.nim", "const unrelated = 1\n")

    var instance = bareInstance(root)
    # A real supplied root that reaches NONE of the external imports.
    instance.effectiveSearchRoots = @[root / "lib"]
    let closure = solvedSourceClosure(root, @[], instance.effectiveSearchRoots)
    check closure.missing.len == 0
    check closure.files == @["local_helper.nim", "repro.nim"]
    let before = identityKeyOnEveryPath(instance)
    check before.len == 64
    # A supplied root that does not exist is ignored, exactly as the
    # compiler ignores it — not refused, not digested.
    var absentRoot = bareInstance(root)
    absentRoot.effectiveSearchRoots =
      @[root / "lib", root / "no-such-directory"]
    check identityKeyOnEveryPath(absentRoot) == before

  test "supplied search roots do not leak absolute paths into the digest":
    # The relocation control for the new input, and the reason it is
    # needed: the roots arrive as ABSOLUTE paths from a compile command,
    # and hashing them (or the absolute spelling of the files they
    # reach) would pass every "changes the identity" case above while
    # breaking relocation stability — the exact cheap wrong fix the
    # original relocation control forbids.
    let origin = createTempDir("m13-supplied-relocation-origin-", "")
    defer: removeDir(origin)
    let relocatedParent = createTempDir("m13-supplied-relocation-target-", "")
    defer: removeDir(relocatedParent)
    createDir(origin)
    writeFile(origin / "repro.nim", "import helper\nconst entry = 1\n")
    createDir(origin / "internal")
    writeFile(origin / "internal" / "helper.nim",
      "const implementation = 1\n")
    let relocated = relocatedParent / "a-differently-named-deeper-root"
    copyDir(origin, relocated)
    check origin != relocated

    var originInstance = bareInstance(origin)
    originInstance.effectiveSearchRoots = @[absolutePath(origin / "internal")]
    var relocatedInstance = bareInstance(relocated)
    relocatedInstance.effectiveSearchRoots =
      @[absolutePath(relocated / "internal")]
    check originInstance.effectiveSearchRoots[0].isAbsolute
    check relocatedInstance.effectiveSearchRoots[0] !=
      originInstance.effectiveSearchRoots[0]
    let originKey = identityKeyOnEveryPath(originInstance)
    check identityKeyOnEveryPath(relocatedInstance) == originKey

    # The same tree keyed with the root spelled RELATIVE to the project
    # root produces the same key as the absolute spelling: the root is
    # resolution evidence, never digest input.
    var relativeSpelling = bareInstance(origin)
    relativeSpelling.effectiveSearchRoots = @["internal"]
    check identityKeyOnEveryPath(relativeSpelling) == originKey

    # And nothing absolute reaches the bound file list either way.
    let originFiles = solvedSourceClosure(origin, @[],
      originInstance.effectiveSearchRoots).files
    for rel in originFiles:
      check not rel.isAbsolute
      check ":" notin rel
    check originFiles == solvedSourceClosure(relocated, @[],
      relocatedInstance.effectiveSearchRoots).files
    # Non-vacuity: the relocated copy is still bound to its own bytes.
    writeFile(relocated / "internal" / "helper.nim",
      "const implementation = 2\n")
    check identityKeyOnEveryPath(relocatedInstance) != originKey

  # -------------------------------------------------------------------
  # The compile-time-read scan. It used to be a bare whole-identifier
  # grep over masked source, which refused three shapes of CORRECT
  # recipe — a permanently unkeyable project, which is as useless as an
  # aliased one. Each case below was measured refusing at ca7864d0.
  # -------------------------------------------------------------------

  test "a recipe that defines its own slurp is not a compile-time read":
    let root = createTempDir("m13-own-slurp-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "proc slurp(label: string): string = \"local:\" & label\n" &
      "const banner = slurp(\"greeting\")\n" &
      "const entry = 1\n")
    # ``greeting`` is not a file and never was: at ca7864d0 this refused
    # with ``compile-time file read slurp("greeting")``.
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check closure.files == @["repro.nim"]
    let before = identityKeyOnEveryPath(bareInstance(root))
    check before.len == 64
    # Non-vacuity: the recipe is still bound to its own bytes.
    writeFile(root / "repro.nim",
      "proc slurp(label: string): string = \"local:\" & label\n" &
      "const banner = slurp(\"greetings\")\n" &
      "const entry = 1\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

    # The same for a ``let``/``var``/``const`` section declaration, in
    # both its one-line and its indented-block form.
    for declaration in ["const gorge = 3\n",
                        "const\n  gorge = 3\n",
                        "let gorge = 3\n",
                        "var gorge* = 3\n"]:
      let sectionRoot = createTempDir("m13-own-gorge-decl-", "")
      defer: removeDir(sectionRoot)
      createDir(sectionRoot)
      writeFile(sectionRoot / "repro.nim",
        declaration & "const entry = gorge\n")
      check solvedSourceClosure(sectionRoot).missing.len == 0
      check identityKeyOnEveryPath(bareInstance(sectionRoot)).len == 64

  test "slurp or gorge inside a kept string literal is not evidence":
    # The masking rule already covers comments. A KEPT single-line
    # string literal is the other place the word can appear without Nim
    # ever reading it as a call — and kept it must stay, because the
    # ``staticRead`` argument and ``import "./x"`` live in one.
    for text in ["const note = \"run slurp on the payload\"\n",
                 "const note = \"gorge on the payload\"\n",
                 "const note = \"staticExec is a word\"\n",
                 "const note = \"gorgeEx and staticRead too\"\n"]:
      let root = createTempDir("m13-literal-mention-", "")
      defer: removeDir(root)
      createDir(root)
      writeFile(root / "repro.nim", text & "const entry = 1\n")
      let closure = solvedSourceClosure(root)
      check closure.missing.len == 0
      check closure.files == @["repro.nim"]
      check identityKeyOnEveryPath(bareInstance(root)).len == 64

  test "a genuine compile-time read is still caught":
    # The positive control for the two exclusions above. Without it they
    # are indistinguishable from deleting the compile-time-read scan.
    let unresolved = createTempDir("m13-real-read-", "")
    defer: removeDir(unresolved)
    createDir(unresolved)
    writeFile(unresolved / "repro.nim",
      "const blob = staticRead(\"absent.txt\")\nconst entry = 1\n")
    failsClosed(bareInstance(unresolved))

    # The exclusion is per-IDENTIFIER, not a blanket off-switch: a file
    # that shadows ``slurp`` still refuses on its real ``gorge``.
    let mixed = createTempDir("m13-real-read-mixed-", "")
    defer: removeDir(mixed)
    createDir(mixed)
    writeFile(mixed / "repro.nim",
      "proc slurp(label: string): string = label\n" &
      "const banner = slurp(\"greeting\")\n" &
      "const built = gorge(\"echo hi\")\n")
    failsClosed(bareInstance(mixed))

    # An EXPLICIT ``system.slurp`` is the stdlib one whatever the file
    # shadows, so shadowing cannot be used to hide a real read.
    let qualified = createTempDir("m13-real-read-qualified-", "")
    defer: removeDir(qualified)
    createDir(qualified)
    writeFile(qualified / "repro.nim",
      "proc slurp(label: string): string = label\n" &
      "const blob = system.slurp(\"absent.txt\")\n")
    failsClosed(bareInstance(qualified))

    # ...and a real read that DOES resolve still binds its bytes.
    let bound = createTempDir("m13-real-read-bound-", "")
    defer: removeDir(bound)
    createDir(bound)
    writeFile(bound / "repro.nim",
      "const blob = staticRead(\"payload.txt\")\nconst entry = 1\n")
    writeFile(bound / "payload.txt", "payload 1\n")
    check "payload.txt" in solvedSourceClosure(bound).files
    let beforeRead = identityKeyOnEveryPath(bareInstance(bound))
    writeFile(bound / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(bound)) != beforeRead

  test "case-distinct modules bind as two entries on a case-sensitive fs":
    # The Linux branch of the case-folding rule, proved by CONSEQUENCE
    # rather than only by ``sourceClosurePathKey``'s inequality. An
    # unconditional ``toLowerAscii`` dedup key collapses these two
    # genuinely distinct files into ONE closure entry and leaves the
    # digest unchanged when the dropped one is edited — the #171
    # aliasing class, re-introduced by the visited set, on the build
    # target.
    when defined(windows):
      # NTFS resolves both spellings to the same file, so the two-entry
      # proof is not expressible here; the folding rule's Windows branch
      # is asserted by "path de-duplication follows the filesystem's
      # case rule" instead.
      skip()
    else:
      let root = createTempDir("m13-case-distinct-", "")
      defer: removeDir(root)
      createDir(root)
      writeFile(root / "CaseProbe.marker", "probe\n")
      if fileExists(root / "caseprobe.marker"):
        # A case-INSENSITIVE filesystem on a non-Windows host (an
        # APFS/HFS+ default, a mounted NTFS volume). Skipping is honest:
        # asserting two entries here would assert a filesystem fact that
        # is false on this host.
        skip()
      else:
        removeFile(root / "CaseProbe.marker")
        writeFile(root / "repro.nim",
          "import ./Helper\nimport ./helper\nconst entry = 1\n")
        writeFile(root / "Helper.nim", "const upper = 1\n")
        writeFile(root / "helper.nim", "const lower = 1\n")
        let closure = solvedSourceClosure(root)
        check closure.missing.len == 0
        check closure.files == @["Helper.nim", "helper.nim", "repro.nim"]
        let before = identityKeyOnEveryPath(bareInstance(root))
        # The digest moves when EITHER file changes. One entry standing
        # for both would leave one of these two checks green by luck.
        writeFile(root / "Helper.nim", "const upper = 2\n")
        let afterUpper = identityKeyOnEveryPath(bareInstance(root))
        check afterUpper != before
        writeFile(root / "helper.nim", "const lower = 2\n")
        check identityKeyOnEveryPath(bareInstance(root)) != afterUpper

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

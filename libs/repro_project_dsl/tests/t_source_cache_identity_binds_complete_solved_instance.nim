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
## Three cases exist because EARLIER ROUNDS OF THIS WORK opened
## fail-opens and this file did not catch them, so each names the
## measurement rather than the intention.
##
##   * "a shadowing declaration that cannot bind the call does not hide
##     a read". ``18e3f3b0`` ignored every unqualified occurrence of
##     ``slurp`` / ``gorge`` / ``staticRead`` in a file that declared
##     the name. Measured on ``proc slurp(n: int)`` plus a real
##     ``slurp("payload.txt")``: the payload was ABSENT from the closure
##     and the key did NOT move when the payload changed, where
##     ``ca7864d0`` refused the same file. That is the #171 defect
##     re-created inside the fix for it. The exclusion is now decided
##     per CALL against the file's own overloads, and the three shapes
##     of correct recipe the previous round un-refused stay keyable
##     because each is safe under the same rule — verified against nim
##     2.2.8, not assumed.
##   * "a declaration the compiler does not apply does not hide a read".
##     The per-CALL rule still asked the wrong question of the FILE: it
##     recorded every declaration of the name at any indentation and
##     applied it to every occurrence, while the compiler applies one
##     only where it is in scope, textually before the call, and in a
##     live ``when`` branch. Four shapes were COMPILED AND RUN against
##     the real compiler and all four print the payload — the
##     declaration placed after the call, nested inside another
##     routine's body, under ``when false:``, and under a
##     ``when defined(...)`` that is never set — yet each produced a
##     64-hex key that did not move with the payload. A declaration now
##     excludes a call only at column 0 and before it; one at indent > 0
##     leaves the overload set undecidable and REFUSES. The case also
##     pins the two directions that must not follow from that: an
##     indented NON-routine declaration still binds (measured: it reads
##     the payload), and the top-level declaration-before-call shape is
##     still excluded, so closing the hole did not just switch the
##     exclusion off.
##   * "a supplied search root that does not exist fails closed".
##     ``18e3f3b0`` ignored a supplied root that was not on disk "as the
##     compiler ignores it". Measured: a typo'd ``internl`` for
##     ``internal`` dropped the module and produced ONE key across
##     ``implementation`` 1 -> 2. The case also PINS the residual next
##     to it — an existing but incomplete root set still aliases — so
##     the documented open item is checked rather than asserted.
##
## What this file does NOT prove, stated so the green result is not read
## for more than it is.
##
##   * That a caller's ``effectiveSearchRoots`` is the COMPLETE root set
##     of the real compile command — only that a root it names must
##     exist. A set of existing roots that misses a module still keys
##     and still aliases, which a case above pins as the open residual.
##     ``searchRootsKnown``, ``optionsSolved`` and the resolved
##     dependency instances are the CALLER's assertions and are taken on
##     trust; root existence is the only part checkable from inside.
##   * That the compile-time-read scan is a parse. It is a
##     better-informed textual scan that reads one declaration line at a
##     time. Stated by DIRECTION, because "not a parse" does not say
##     which way a gap fails: an imported overload is invisible, so a
##     call it would capture is still treated as the stdlib read (it
##     binds, or refuses — it never ignores); ``when`` is not evaluated,
##     so a ROUTINE declaration under one refuses and a read or import
##     inside one is bound whether or not the branch is live; but
##     MACRO-GENERATED code is invisible and therefore ALIASES, which is
##     the one gap that fails the dangerous way and is pinned as an
##     explicit residual case rather than left as prose.
##   * That any real cache endpoint, upload or substitution works.
##   * That any production call site produces a keyable identity. Every
##     one of them still uses the legacy four-argument constructor, is
##     PENDING by construction, and can neither substitute nor publish.
##     This suite proves a CAPABILITY, not a behaviour anything relies
##     on today.

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
    # A supplied root that does not EXIST is a wrong reconstruction of
    # the compile command, not a harmless extra, and is refused rather
    # than ignored — see "a supplied search root that does not exist
    # fails closed" for what ignoring it aliased.
    var absentRoot = bareInstance(root)
    absentRoot.effectiveSearchRoots =
      @[root / "lib", root / "no-such-directory"]
    failsClosed(absentRoot)

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

  test "a supplied search root that does not exist fails closed":
    # A caller that ASSERTS "these are the effective compiler search
    # roots" and names a directory that is not there has given
    # demonstrably wrong evidence about the compile command. Measured at
    # 18e3f3b0, where such a root was ignored "as the compiler ignores
    # it": a typo'd ``internl`` for ``internal`` dropped the module and
    # produced closure digest ``337050709747f16f…``, the SAME key across
    # ``implementation`` 1 -> 2 — the #171 aliasing class, reached
    # through the input that was added to close it.
    let root = createTempDir("m13-supplied-absent-root-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim", "import helper\nconst entry = 1\n")
    createDir(root / "internal")
    writeFile(root / "internal" / "helper.nim",
      "const implementation = 1\n")

    var typo = bareInstance(root)
    typo.effectiveSearchRoots = @[root / "internl"]
    failsClosed(typo)
    # ...and the refusal NAMES the bad root, so the wrong evidence is
    # actionable at the call site rather than anonymous.
    check "internl" in cacheEntryIdentityError(
      solvedSourceCacheEntryIdentity(typo))

    # The correctly spelled root still keys and still binds what it
    # reaches: the refusal is about the WRONG root, not about supplying
    # roots at all.
    var correct = bareInstance(root)
    correct.effectiveSearchRoots = @[root / "internal"]
    let before = identityKeyOnEveryPath(correct)
    check before.len == 64
    writeFile(root / "internal" / "helper.nim",
      "const implementation = 2\n")
    check identityKeyOnEveryPath(correct) != before

    # The documented RESIDUAL, pinned so it cannot decay silently and so
    # the docs' claim is checked rather than asserted: a root set whose
    # every root EXISTS but which does not reach a module the project
    # imports still KEYS, and still aliases across that module's change,
    # because a bare unresolved spec with no on-disk evidence is
    # classified external by the pre-existing rule. Refusing every such
    # spec instead is what would make the real project roots unkeyable,
    # so this stays open rather than being closed the cheap way.
    let incomplete = createTempDir("m13-supplied-incomplete-root-", "")
    defer: removeDir(incomplete)
    createDir(incomplete)
    writeFile(incomplete / "repro.nim", "import helper\nconst entry = 1\n")
    createDir(incomplete / "internal")
    writeFile(incomplete / "internal" / "helper.nim",
      "const implementation = 1\n")
    createDir(incomplete / "other")
    var partial = bareInstance(incomplete)
    partial.effectiveSearchRoots = @[incomplete / "other"]
    let partialKey = identityKeyOnEveryPath(partial)
    check partialKey.len == 64
    writeFile(incomplete / "internal" / "helper.nim",
      "const implementation = 2\n")
    check identityKeyOnEveryPath(partial) == partialKey

  # -------------------------------------------------------------------
  # The compile-time-read scan. It used to be a bare whole-identifier
  # grep over masked source, which refused three shapes of CORRECT
  # recipe — a permanently unkeyable project, which is as useless as an
  # aliased one. Each of the first three cases below was measured
  # refusing at ca7864d0. The two after them are the other direction:
  # 18e3f3b0's cure for those refusals ignored the identifier per FILE,
  # which ALIASED, and they pin the per-CALL rule that replaced it.
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

  test "a shadowing declaration that cannot bind the call does not hide a read":
    # The fail-open the previous round's per-FILE exclusion opened, and
    # the reason the exclusion is now decided per CALL. Measured against
    # the real compiler (nim 2.2.8): a file declaring
    # ``proc slurp(n: int)`` and calling ``slurp("payload.txt")``
    # compiles to ``system.slurp`` and reads the file, because the local
    # overload cannot accept a string. Skipping every unqualified
    # occurrence in that file dropped the payload from the closure and
    # left the key unmoved when the payload changed — an ALIAS, where
    # ca7864d0's bare grep refused. Binding it is the better of the two
    # safe answers, so that is what is pinned here.
    let bound = createTempDir("m13-shadow-nonbinding-", "")
    defer: removeDir(bound)
    createDir(bound)
    writeFile(bound / "repro.nim",
      "proc slurp(n: int): string = \"local\"\n" &
      "const blob = slurp(\"payload.txt\")\n" &
      "const entry = 1\n")
    writeFile(bound / "payload.txt", "payload 1\n")
    let closure = solvedSourceClosure(bound)
    check closure.missing.len == 0
    check "payload.txt" in closure.files
    let before = identityKeyOnEveryPath(bareInstance(bound))
    writeFile(bound / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(bound)) != before

    # The same file with CRLF line endings, which a recipe authored on
    # Windows has. The declaration is located by BYTE OFFSET so that it
    # is not mistaken for a use of the symbol, and a line walk that
    # treats \r\n as one byte drifts and stops matching -- which would
    # silently turn this file into a refusal or, worse, back into a
    # skipped occurrence.
    let crlf = createTempDir("m13-shadow-crlf-", "")
    defer: removeDir(crlf)
    createDir(crlf)
    writeFile(crlf / "repro.nim",
      # The declaration is deliberately NOT the first line: a byte
      # counter that treats \r\n as one separator is still correct at
      # offset zero, so a file whose declaration leads would pass a
      # drifting walk by luck.
      "const entry = 1\r\n" &
      "proc slurp(n: int): string = \"local\"\r\n" &
      "const blob = slurp(\"payload.txt\")\r\n")
    writeFile(crlf / "payload.txt", "payload 1\r\n")
    check "payload.txt" in solvedSourceClosure(crlf).files
    let beforeCrlf = identityKeyOnEveryPath(bareInstance(crlf))
    writeFile(crlf / "payload.txt", "payload 2\r\n")
    check identityKeyOnEveryPath(bareInstance(crlf)) != beforeCrlf

    # A non-routine declaration is the same story, and measured the same
    # way: ``const gorge = 3`` does NOT stop ``gorge("echo hi")`` from
    # reaching ``system.gorge``, so it cannot license ignoring the call.
    let nonRoutine = createTempDir("m13-shadow-nonroutine-", "")
    defer: removeDir(nonRoutine)
    createDir(nonRoutine)
    writeFile(nonRoutine / "repro.nim",
      "const gorge = 3\n" &
      "const built = gorge(\"echo hi\")\n")
    failsClosed(bareInstance(nonRoutine))

    # Where the overload set cannot be decided from the text the
    # identity REFUSES rather than ignoring — an unrecognised parameter
    # type is missing evidence, not permission...
    let opaque = createTempDir("m13-shadow-opaque-", "")
    defer: removeDir(opaque)
    createDir(opaque)
    writeFile(opaque / "repro.nim",
      "type Payload = object\n" &
      "proc slurp(p: Payload): string = \"local\"\n" &
      "const blob = slurp(\"payload.txt\")\n")
    writeFile(opaque / "payload.txt", "payload 1\n")
    failsClosed(bareInstance(opaque))

    # ...and so is an argument that is not a string literal, which
    # neither binds nor rules the local overload out.
    let computed = createTempDir("m13-shadow-computed-", "")
    defer: removeDir(computed)
    createDir(computed)
    writeFile(computed / "repro.nim",
      "proc slurp(n: int): string = \"local\"\n" &
      "const name = \"payload.txt\"\n" &
      "const blob = slurp(name)\n")
    writeFile(computed / "payload.txt", "payload 1\n")
    failsClosed(bareInstance(computed))

  test "a declaration the compiler does not apply does not hide a read":
    # The third fail-open this campaign's own rounds opened, closed here.
    # The per-CALL rule above still asked the WRONG question of the file:
    # ``localDeclarationsOf`` recorded every declaration of the name
    # anywhere in the file at any indentation, and ``shadowVerdict``
    # applied it to every occurrence. The compiler applies a declaration
    # only where it is in SCOPE, TEXTUALLY BEFORE the call, and in a LIVE
    # ``when`` branch. Each shape below was compiled and RUN against the
    # real compiler (nim 2.2.8 on this host, nim 2.2.4 on the Linux one):
    # every one of them PRINTS the payload, so every one is a genuine
    # compile-time read. At =18e3f3b0= plus the previous round's working
    # tree each produced a 64-hex key that did NOT move when the payload
    # changed — the #171 alias, re-created for the third time inside the
    # fix for it.
    #
    # ``bindsPayload`` pins WHICH of the two safe answers each shape gets
    # rather than accepting either, so the rule cannot drift silently:
    # only the out-of-order shape is decidable from the text (the
    # declaration is at column 0, so the file's overload set is readable;
    # it simply does not exist yet at the call). A declaration at indent
    # > 0 — nested in a body, or under a ``when`` — leaves the overload
    # set undecidable, and undecidable refuses.
    const OutOfScopeShapes = [
      # 1. The declaration comes AFTER the call. Nim resolves top-level
      #    code in order, so the call is ``system.slurp``.
      (source: "const blob = slurp(\"payload.txt\")\n" &
               "proc slurp(label: string): string = \"local:\" & label\n" &
               "const entry = 1\n",
       bindsPayload: true),
      # 2. The declaration is nested inside another routine's body and is
      #    invisible at module scope.
      (source: "proc outer() =\n" &
               "  proc slurp(label: string): string = \"local:\" & label\n" &
               "  discard slurp(\"x\")\n" &
               "const blob = slurp(\"payload.txt\")\n",
       bindsPayload: false),
      # 3. The declaration is in a dead ``when`` branch and is never
      #    compiled at all.
      (source: "when false:\n" &
               "  proc slurp(label: string): string = \"local:\" & label\n" &
               "const blob = slurp(\"payload.txt\")\n",
       bindsPayload: false),
      # 4. The same through a ``defined`` this build never sets.
      (source: "when defined(flagNeverSet):\n" &
               "  proc slurp(label: string): string = \"local:\" & label\n" &
               "const blob = slurp(\"payload.txt\")\n",
       bindsPayload: false)]
    for shape in OutOfScopeShapes:
      let root = createTempDir("m13-shadow-outofscope-", "")
      defer: removeDir(root)
      createDir(root)
      writeFile(root / "repro.nim", shape.source)
      writeFile(root / "payload.txt", "payload 1\n")
      if shape.bindsPayload:
        let closure = solvedSourceClosure(root)
        check closure.missing.len == 0
        check "payload.txt" in closure.files
        let before = identityKeyOnEveryPath(bareInstance(root))
        check before.len == 64
        # The assertion the fail-open failed: the key MOVES with the
        # payload it reads.
        writeFile(root / "payload.txt", "payload 2\n")
        check identityKeyOnEveryPath(bareInstance(root)) != before
      else:
        check solvedSourceClosure(root).missing.len > 0
        failsClosed(bareInstance(root))

    # The refusing side is not a blanket "any indented declaration
    # refuses the file": only a ROUTINE can join an overload set, so an
    # indented non-routine declaration leaves the call decidable and the
    # payload binds. Measured against nim 2.2.8: a file whose ``outer``
    # body declares ``const slurp = 3`` still reads the payload at
    # module scope, so refusing here would be a false refusal, not
    # caution.
    let nested = createTempDir("m13-shadow-nested-nonroutine-", "")
    defer: removeDir(nested)
    createDir(nested)
    writeFile(nested / "repro.nim",
      "proc outer() =\n" &
      "  const slurp = 3\n" &
      "  discard slurp\n" &
      "const blob = slurp(\"payload.txt\")\n")
    writeFile(nested / "payload.txt", "payload 1\n")
    let nestedClosure = solvedSourceClosure(nested)
    check nestedClosure.missing.len == 0
    check "payload.txt" in nestedClosure.files
    let nestedBefore = identityKeyOnEveryPath(bareInstance(nested))
    writeFile(nested / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(nested)) != nestedBefore

    # And the top-level declaration-before-call shape — the one the
    # compiler DOES apply — is still excluded, so closing this did not
    # simply turn the exclusion off.
    let applied = createTempDir("m13-shadow-applied-", "")
    defer: removeDir(applied)
    createDir(applied)
    writeFile(applied / "repro.nim",
      "proc slurp(label: string): string = \"local:\" & label\n" &
      "const banner = slurp(\"payload.txt\")\n" &
      "const entry = 1\n")
    writeFile(applied / "payload.txt", "payload 1\n")
    let appliedClosure = solvedSourceClosure(applied)
    check appliedClosure.missing.len == 0
    check appliedClosure.files == @["repro.nim"]
    check identityKeyOnEveryPath(bareInstance(applied)).len == 64

    # The documented RESIDUAL that goes the OTHER way, pinned here so it
    # cannot decay silently and so the docs' claim about it is checked
    # rather than asserted. Every other gap in this not-a-parse scan
    # over-approximates (it binds, or it refuses). MACRO-GENERATED code
    # does not: a compile-time read that exists only after expansion
    # leaves no text to scan, so it is not bound and the key does NOT
    # move when what it reads changes. Closing this needs a real
    # semantic pass, not a better scan, so it stays open and stays
    # measured.
    let generated = createTempDir("m13-macro-generated-read-", "")
    defer: removeDir(generated)
    createDir(generated)
    writeFile(generated / "repro.nim",
      "import std/macros\n" &
      "macro readPayload(): untyped =\n" &
      "  parseStmt(\"const blob = slurp(\\\"payload.txt\\\")\")\n" &
      "readPayload()\n" &
      "const entry = 1\n")
    writeFile(generated / "payload.txt", "payload 1\n")
    let generatedClosure = solvedSourceClosure(generated)
    check generatedClosure.missing.len == 0
    check "payload.txt" notin generatedClosure.files
    let generatedKey = identityKeyOnEveryPath(bareInstance(generated))
    check generatedKey.len == 64
    writeFile(generated / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(generated)) == generatedKey

  test "the shadowing controls still identify a real compile-time read":
    # A declaration that exists only inside a KEPT string literal
    # declares nothing, so the read below is the stdlib's.
    let quoted = createTempDir("m13-shadow-quoted-decl-", "")
    defer: removeDir(quoted)
    createDir(quoted)
    writeFile(quoted / "repro.nim",
      "const note = \"proc slurp(label: string): string = label\"\n" &
      "const blob = slurp(\"absent.txt\")\n")
    failsClosed(bareInstance(quoted))

    # A different identifier that merely starts with the same letters
    # shadows nothing.
    let prefixed = createTempDir("m13-shadow-prefix-", "")
    defer: removeDir(prefixed)
    createDir(prefixed)
    writeFile(prefixed / "repro.nim",
      "proc slurpish(label: string): string = label\n" &
      "const blob = slurp(\"absent.txt\")\n")
    failsClosed(bareInstance(prefixed))

    # A qualifier other than ``system`` names a symbol this scanner
    # cannot see at all, so shadowing must not turn it into silence: the
    # occurrence is treated as a compile-time read whatever the file
    # declares. What that costs is measured rather than described — a
    # foreign qualifier is NOT "missing evidence" by itself. When its
    # argument is a literal that resolves, the payload BINDS and the key
    # moves with it (an over-approximation, which is the safe direction);
    # it is missing evidence only when the argument does not resolve.
    let foreign = createTempDir("m13-shadow-foreign-qualifier-", "")
    defer: removeDir(foreign)
    createDir(foreign)
    writeFile(foreign / "repro.nim",
      "proc slurp(label: string): string = label\n" &
      "const blob = mymod.slurp(\"absent.txt\")\n")
    failsClosed(bareInstance(foreign))

    let foreignBound = createTempDir("m13-shadow-foreign-bound-", "")
    defer: removeDir(foreignBound)
    createDir(foreignBound)
    writeFile(foreignBound / "repro.nim",
      "proc slurp(label: string): string = label\n" &
      "const blob = mymod.slurp(\"payload.txt\")\n")
    writeFile(foreignBound / "payload.txt", "payload 1\n")
    let foreignClosure = solvedSourceClosure(foreignBound)
    check foreignClosure.missing.len == 0
    check "payload.txt" in foreignClosure.files
    let foreignBefore = identityKeyOnEveryPath(bareInstance(foreignBound))
    check foreignBefore.len == 64
    writeFile(foreignBound / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(foreignBound)) != foreignBefore

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

  # -------------------------------------------------------------------------
  # Cases added by the retroactive PER-GUARD mutation audit.
  #
  # Everything above was validated per CASE: every case had a falsifying
  # mutation. That is a weaker property than it reads as, and the
  # difference was measured on this module: applying a mutation to each
  # GUARD individually, 69 of 122 guards could be disabled with the whole
  # suite staying green, because several guards happened to cover the same
  # case. The cases below pin the guards whose failure mode is a FALSE
  # ACCEPT — a digest silently produced where the module owes a refusal, or
  # a digest that fails to move when an input changes. That is the #171
  # class itself, and it is the only failure this identity may not have.
  #
  # Each case names the guard it pins and the mutation that falsifies it,
  # so a later refactor that deletes the guard cannot also pass.
  # -------------------------------------------------------------------------

  test "a bare import satisfied by the project root binds":
    # Guard: ``collectSearchRoots`` seeds the search-root set with the
    # project root itself. Nim resolves a bare ``import toplevel`` from a
    # SUBDIRECTORY module against the project root, and without that root
    # the spec resolves nowhere, has no on-disk evidence under any other
    # root, and is therefore classified EXTERNAL and dropped — a digest
    # over a closure that is missing a module the recipe compiles.
    # Falsified by deleting ``addSearchRoot(roots, projectRoot,
    # projectRoot, projectRoot)`` (and, equivalently, by deleting
    # ``projectRelative``'s path==root branch, which is what makes that
    # call record anything).
    let root = createTempDir("m13-root-is-a-search-root-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim", "import ./sub/child\nconst entry = 1\n")
    createDir(root / "sub")
    writeFile(root / "sub" / "child.nim", "import toplevel\nconst c = 1\n")
    writeFile(root / "toplevel.nim", "const top = 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check "toplevel.nim" in closure.files
    let before = identityKeyOnEveryPath(bareInstance(root))
    writeFile(root / "toplevel.nim", "const top = 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

  test "a renamed, a from-import and a multi-line import each bind":
    # Guards: ``expandImportSpec``'s ``as`` / ``except`` reduction,
    # ``importRefsOf``'s ``from x import y`` arm, and its multi-line
    # continuation handling. Each one, disabled alone, drops a module
    # from the closure SILENTLY: the spec stops resolving, carries no
    # on-disk evidence in the shape the scanner then sees, is classified
    # external, and the key stops moving with that module's bytes.
    let root = createTempDir("m13-import-shapes-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "import ./alpha as a\n" &
      "from ./beta import thing\n" &
      "import\n" &
      "  ./gamma,\n" &
      "  ./delta\n" &
      "const entry = 1\n")
    for name in ["alpha", "beta", "gamma", "delta"]:
      writeFile(root / (name & ".nim"), "const " & name & " = 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    for name in ["alpha", "beta", "gamma", "delta"]:
      check (name & ".nim") in closure.files
    # Each module's bytes must move the key ON ITS OWN, so one shape
    # standing in for another cannot leave this green by luck.
    var previous = identityKeyOnEveryPath(bareInstance(root))
    for name in ["alpha", "beta", "gamma", "delta"]:
      writeFile(root / (name & ".nim"), "const " & name & " = 2\n")
      let now = identityKeyOnEveryPath(bareInstance(root))
      check now != previous
      previous = now

  test "an extensionless include that resolves nowhere fails closed":
    # Guard: ``isCandidateLocalSpec`` rule 2 — an ``include`` names a file
    # by construction, because Nim textually inlines the target and an
    # ``include`` of a library is not a thing recipes do. The extension
    # rule (rule 3) covers ``include "frag.inc"`` and ``include x.nim``
    # and therefore MASKS this one; an extensionless include is the input
    # that separates them, and without rule 2 it is silently dropped.
    let root = createTempDir("m13-include-bare-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim", "include ghostfrag\nconst entry = 1\n")
    failsClosed(bareInstance(root))
    check "ghostfrag" in cacheEntryIdentityError(
      solvedSourceCacheEntryIdentity(bareInstance(root)))
    # The no-false-refusal control: the same shape that DOES resolve binds.
    let present = createTempDir("m13-include-bare-present-", "")
    defer: removeDir(present)
    createDir(present)
    writeFile(present / "repro.nim", "include realfrag\nconst entry = 1\n")
    writeFile(present / "realfrag.nim", "const fragment = 1\n")
    let before = identityKeyOnEveryPath(bareInstance(present))
    writeFile(present / "realfrag.nim", "const fragment = 2\n")
    check identityKeyOnEveryPath(bareInstance(present)) != before

  test "a search path this scanner cannot evaluate is missing evidence":
    # Guard: ``parseConfigPaths``' ``quotedOnly`` rule for
    # ``switch("path", <expr>)``. A computed search path means the
    # search-root SET is unknown, so no unresolved spec can be ruled out
    # (rule 4) and the identity must refuse. Treating the unquoted
    # argument as a literal instead silently drops a root that does not
    # exist AND clears the unknown flag, so an import the compiler
    # satisfies through that root is classified external and a digest is
    # produced over the rest.
    let root = createTempDir("m13-dynamic-path-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "config.nims",
      "let computedRoot = \"lib\"\nswitch(\"path\", computedRoot)\n")
    writeFile(root / "repro.nim", "import mystery\nconst entry = 1\n")
    failsClosed(bareInstance(root))
    # Control: the same tree with a STRING-LITERAL switch does not refuse,
    # so the rule is not "every config file refuses".
    let literal = createTempDir("m13-literal-path-", "")
    defer: removeDir(literal)
    createDir(literal)
    writeFile(literal / "config.nims", "switch(\"path\", \"lib\")\n")
    writeFile(literal / "repro.nim", "import mystery\nconst entry = 1\n")
    check solvedSourceClosure(literal).missing.len == 0

  test "a $projectDir search root is expanded rather than guessed":
    # Two guards, and they are NOT a redundant pair — measured, each one
    # disabled alone leaves the whole suite green, and disabling both
    # leaves it green too:
    #
    #   * ``expandConfigValue`` expands ``$projectDir`` / ``$projectPath``
    #     / ``$config``. Without it the root keeps its ``$``, which the
    #     next guard turns into a refusal — a false REFUSAL of a correct
    #     recipe;
    #   * ``parseConfigPaths`` marks the root set UNKNOWN when a ``$``
    #     survives expansion. Without it the unexpanded root is silently
    #     dropped and the module behind it is classified external — a
    #     digest that does not move with that module, the #171 class.
    let root = createTempDir("m13-projectdir-path-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "nim.cfg", "--path:\"$projectDir/vendor\"\n")
    writeFile(root / "repro.nim", "import vendormod\nconst entry = 1\n")
    createDir(root / "vendor")
    writeFile(root / "vendor" / "vendormod.nim", "const vendored = 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check "vendor/vendormod.nim" in closure.files
    let before = identityKeyOnEveryPath(bareInstance(root))
    writeFile(root / "vendor" / "vendormod.nim", "const vendored = 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

    # The second guard needs a token this scanner does NOT expand, which
    # is the only input on which it fires: a ``$`` that survives
    # expansion means the root the compiler will use is unknown, so no
    # unresolved spec can be ruled out and the identity must refuse.
    let unknownToken = createTempDir("m13-unknown-token-path-", "")
    defer: removeDir(unknownToken)
    createDir(unknownToken)
    writeFile(unknownToken / "nim.cfg", "--path:\"$nimbleDir/pkgs\"\n")
    writeFile(unknownToken / "repro.nim", "import mystery\nconst entry = 1\n")
    failsClosed(bareInstance(unknownToken))

  test "an entry-specific config and a nimble srcDir are search roots":
    # Guards: the ``<entry>.nim.cfg`` / ``<entry>.nims`` config names, and
    # ``parseNimbleSrcDir``. Both are resolution channels Nim really uses;
    # losing either drops a module out of the closure without any
    # refusal, because a bare spec with no on-disk evidence under the
    # REMAINING roots is classified external.
    let cfgRoot = createTempDir("m13-entry-config-", "")
    defer: removeDir(cfgRoot)
    createDir(cfgRoot)
    writeFile(cfgRoot / "repro.nim.cfg", "--path:\"tools\"\n")
    writeFile(cfgRoot / "repro.nim", "import toolmod\nconst entry = 1\n")
    createDir(cfgRoot / "tools")
    writeFile(cfgRoot / "tools" / "toolmod.nim", "const tooled = 1\n")
    check solvedSourceClosure(cfgRoot).missing.len == 0
    check "tools/toolmod.nim" in solvedSourceClosure(cfgRoot).files
    let cfgBefore = identityKeyOnEveryPath(bareInstance(cfgRoot))
    writeFile(cfgRoot / "tools" / "toolmod.nim", "const tooled = 2\n")
    check identityKeyOnEveryPath(bareInstance(cfgRoot)) != cfgBefore

    let nimbleRoot = createTempDir("m13-nimble-srcdir-", "")
    defer: removeDir(nimbleRoot)
    createDir(nimbleRoot)
    writeFile(nimbleRoot / "probe.nimble",
      "version = \"0.1.0\"\nsrcDir = \"src\"\n")
    writeFile(nimbleRoot / "repro.nim", "import libmod\nconst entry = 1\n")
    createDir(nimbleRoot / "src")
    writeFile(nimbleRoot / "src" / "libmod.nim", "const libbed = 1\n")
    check solvedSourceClosure(nimbleRoot).missing.len == 0
    check "src/libmod.nim" in solvedSourceClosure(nimbleRoot).files
    let nimbleBefore = identityKeyOnEveryPath(bareInstance(nimbleRoot))
    writeFile(nimbleRoot / "src" / "libmod.nim", "const libbed = 2\n")
    check identityKeyOnEveryPath(bareInstance(nimbleRoot)) != nimbleBefore

  test "supplied search roots are searched after the project's own":
    # Guard: ``collectSearchRoots`` appends the CALLER's effective roots
    # last, matching Nim's own order (config files before the command
    # line). Searching them first makes the same spec resolve to the
    # OTHER tree's copy, which lands outside the project root, is
    # therefore classified as external code, and drops out of the closure
    # — so the key stops moving with the in-project module the compiler
    # would actually have used.
    let base = createTempDir("m13-root-order-", "")
    defer: removeDir(base)
    let root = base / "proj"
    createDir(root)
    writeFile(root / "config.nims", "switch(\"path\", \"lib\")\n")
    writeFile(root / "repro.nim", "import shared\nconst entry = 1\n")
    createDir(root / "lib")
    writeFile(root / "lib" / "shared.nim", "const inProject = 1\n")
    createDir(base / "other")
    writeFile(base / "other" / "shared.nim", "const elsewhere = 1\n")

    var instance = bareInstance(root)
    instance.effectiveSearchRoots = @[base / "other"]
    let closure = solvedSourceClosure(root, @[], instance.effectiveSearchRoots)
    check closure.missing.len == 0
    check "lib/shared.nim" in closure.files
    let before = identityKeyOnEveryPath(instance)
    writeFile(root / "lib" / "shared.nim", "const inProject = 2\n")
    check identityKeyOnEveryPath(instance) != before

  test "a spec resolving outside the project root is external, not missing":
    # Guard: the closure walk SKIPS a spec that resolves to a file
    # outside the project root instead of queueing it. Queueing it turns
    # every legitimate ``--path`` into another tree — a nimble
    # dependency, a vendored sibling — into a permanent refusal, which is
    # the "everything is PENDING" uselessness the external-vs-local rule
    # exists to avoid.
    #
    # The second half is the part that is NOT a convenience: such a file
    # must not enter the digest either, because no relocation-stable
    # spelling exists for it. Its code is bound through
    # ``dependencyInstances`` instead.
    let base = createTempDir("m13-outside-external-", "")
    defer: removeDir(base)
    let root = base / "proj"
    createDir(root)
    writeFile(root / "repro.nim", "import vendored\nconst entry = 1\n")
    createDir(base / "vendor")
    writeFile(base / "vendor" / "vendored.nim", "const outside = 1\n")

    var instance = bareInstance(root)
    instance.effectiveSearchRoots = @[base / "vendor"]
    let closure = solvedSourceClosure(root, @[], instance.effectiveSearchRoots)
    check closure.missing.len == 0
    check closure.files == @["repro.nim"]
    let before = identityKeyOnEveryPath(instance)
    writeFile(base / "vendor" / "vendored.nim", "const outside = 2\n")
    check identityKeyOnEveryPath(instance) == before

  test "a sibling directory sharing the root's prefix is outside the root":
    # Guard: ``projectRelative`` requires a SEPARATOR after the root
    # prefix. Without it ``<root>X/data.txt`` reads as inside ``<root>``
    # and is digested under a mangled relative spelling — a file from
    # another tree inside the identity, and relocation invariance gone.
    let base = createTempDir("m13-prefix-sibling-", "")
    defer: removeDir(base)
    let root = base / "proj"
    createDir(root)
    writeFile(root / "repro.nim", "const entry = 1\n")
    createDir(base / "projX")
    writeFile(base / "projX" / "data.txt", "outside\n")
    var instance = bareInstance(root)
    instance.declaredSourceInputs = @[base / "projX" / "data.txt"]
    failsClosed(instance)
    check "outside the project root" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(instance))

  test "a compile-time read is bound against the project root, and only inside it":
    # Two guards of the compile-time-read resolution, each a silent
    # failure on its own:
    #
    #   * the read is resolved against the reading file's directory AND
    #     the project root. Dropping the root fallback refuses a correct
    #     recipe whose payload is addressed from the project root;
    #   * a read that resolves OUTSIDE the project root is missing
    #     evidence. Dropping that refusal binds nothing and produces a
    #     digest that does not move with the file the build really reads.
    let base = createTempDir("m13-read-scope-", "")
    defer: removeDir(base)
    let root = base / "proj"
    createDir(root)
    createDir(root / "sub")
    createDir(root / "data")
    writeFile(root / "repro.nim", "import ./sub/reader\nconst entry = 1\n")
    writeFile(root / "sub" / "reader.nim",
      "const payload = staticRead(\"data/payload.txt\")\n")
    writeFile(root / "data" / "payload.txt", "payload 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check "data/payload.txt" in closure.files
    let before = identityKeyOnEveryPath(bareInstance(root))
    writeFile(root / "data" / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

    let outsideRoot = base / "outsidereader"
    createDir(outsideRoot)
    createDir(base / "elsewhere")
    writeFile(base / "elsewhere" / "payload.txt", "elsewhere\n")
    writeFile(outsideRoot / "repro.nim",
      "const payload = staticRead(\"../elsewhere/payload.txt\")\n")
    failsClosed(bareInstance(outsideRoot))
    check "outside the project root" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(
        bareInstance(outsideRoot)))

  test "a compile-time read's payload is not scanned as Nim source":
    # Guard: the closure walk queues a compile-time-read target with
    # ``scan: false``. Scanning it treats the DATA as code, so a payload
    # that happens to contain the word ``import`` or ``slurp`` invents
    # evidence that does not exist and refuses a correct recipe.
    let root = createTempDir("m13-payload-not-code-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim",
      "const payload = staticRead(\"payload.txt\")\n")
    writeFile(root / "payload.txt",
      "import ./ghost\ninclude ./phantom\nslurp(\"nothing.txt\")\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 0
    check "payload.txt" in closure.files
    let before = identityKeyOnEveryPath(bareInstance(root))
    writeFile(root / "payload.txt", "import ./ghost\nchanged\n")
    check identityKeyOnEveryPath(bareInstance(root)) != before

  test "an overload that cannot take the call does not hide the read":
    # Guards: ``routineFit``'s arity rejections, and ``shadowVerdict``'s
    # unknown-arity refusal. The measured failure of the per-file
    # exclusion this module replaced was exactly this shape — a local
    # declaration that the compiler does NOT apply at the call, used to
    # drop a real ``system.slurp`` out of the closure, which is the #171
    # defect re-created inside the fix for it. The parameter-TYPE half of
    # the rule is pinned by "a shadowing declaration that cannot bind the
    # call does not hide a read"; the ARITY half is pinned here.
    let tooFew = createTempDir("m13-arity-too-few-", "")
    defer: removeDir(tooFew)
    createDir(tooFew)
    writeFile(tooFew / "repro.nim",
      "proc slurp(a, b: string): string = a & b\n" &
      "const blob = slurp(\"payload.txt\")\n")
    writeFile(tooFew / "payload.txt", "payload 1\n")
    check solvedSourceClosure(tooFew).missing.len == 0
    check "payload.txt" in solvedSourceClosure(tooFew).files
    let tooFewBefore = identityKeyOnEveryPath(bareInstance(tooFew))
    writeFile(tooFew / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(tooFew)) != tooFewBefore

    let tooMany = createTempDir("m13-arity-too-many-", "")
    defer: removeDir(tooMany)
    createDir(tooMany)
    writeFile(tooMany / "repro.nim",
      "proc slurp(): string = \"local\"\n" &
      "const blob = slurp(\"payload.txt\")\n")
    writeFile(tooMany / "payload.txt", "payload 1\n")
    check solvedSourceClosure(tooMany).missing.len == 0
    check "payload.txt" in solvedSourceClosure(tooMany).files
    let tooManyBefore = identityKeyOnEveryPath(bareInstance(tooMany))
    writeFile(tooMany / "payload.txt", "payload 2\n")
    check identityKeyOnEveryPath(bareInstance(tooMany)) != tooManyBefore

    # A call whose ARITY the text does not decide, in a file that
    # declares the name: undecidable, therefore missing evidence.
    let unknownArity = createTempDir("m13-arity-unknown-", "")
    defer: removeDir(unknownArity)
    createDir(unknownArity)
    writeFile(unknownArity / "repro.nim",
      "proc slurp(label: string): string = label\n" &
      "const name = \"payload.txt\"\n" &
      "const blob = slurp name\n")
    writeFile(unknownArity / "payload.txt", "payload 1\n")
    failsClosed(bareInstance(unknownArity))
    check "cannot be told apart" in cacheEntryIdentityError(
      solvedSourceCacheEntryIdentity(bareInstance(unknownArity)))

  test "no digest and no revision are reported over incomplete evidence":
    # Guards: ``solvedSourceClosure`` suppresses ``digestHex`` whenever
    # ``missing`` is non-empty, and ``sourceProviderRevisionHex`` returns
    # the empty string on the same condition. Each one alone, and both
    # together, left the whole suite green: the pending marker that
    # ``sourceIdentity`` stamps covered every case, so the DIAGNOSTIC
    # surface these two guards own — the value a caller reads directly
    # off the closure — was unpinned.
    let root = createTempDir("m13-no-partial-digest-", "")
    defer: removeDir(root)
    createDir(root)
    # The two unresolvable specs are named so that DISCOVERY order and
    # SORTED order disagree; a missing list that merely happens to be
    # discovered alphabetically proves nothing about the sort.
    writeFile(root / "repro.nim",
      "import ./zulu\nimport ./alpha\nconst entry = 1\n")
    let closure = solvedSourceClosure(root)
    check closure.missing.len == 2
    check closure.digestHex.len == 0
    check sourceProviderRevisionHex(root).len == 0
    # The missing list is sorted, so the diagnostic is a function of the
    # tree rather than of the traversal order that discovered it.
    check closure.missing == closure.missing.sorted(cmp)
    check closure.missing[0].contains("alpha")
    # Non-vacuity: the same tree WITH both modules present reports both a
    # digest and a revision.
    writeFile(root / "zulu.nim", "const zulu = 1\n")
    writeFile(root / "alpha.nim", "const alpha = 1\n")
    let complete = solvedSourceClosure(root)
    check complete.missing.len == 0
    check complete.digestHex.len == 64
    check sourceProviderRevisionHex(root).len == 32

  test "an instance with no root, no project file or no package name refuses":
    # Guards: the empty-project-root refusal, the absent-project-file
    # refusal (in both of its arms — ``resolveProjectFile`` raising and
    # ``resolveProjectFile`` answering with an empty path), and the
    # package-name refusal. Every one of them was unprotected: the legacy
    # constructor's cases reach them, but that constructor is PENDING for
    # four other reasons at once, so none of these could be falsified.
    let empty = SolvedSourceInstance(
      projectRoot: "",
      packageName: "probe",
      packageVersion: "1.0",
      searchRootsKnown: true,
      optionsSolved: true,
      dependenciesResolved: true,
      platform: bcsTypes.PlatformTriple(
        cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
      toolchain: bcsTypes.ToolchainIdentity(
        name: "cmake", version: "3.29.2",
        hostLdSoAbi: "x86_64-linux-gnu", extraFingerprint: ""))
    let emptyIdentity = solvedSourceCacheEntryIdentity(empty)
    check cacheEntryIdentityError(emptyIdentity).len > 0
    check "project root is empty" in cacheEntryIdentityError(emptyIdentity)
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(emptyIdentity)

    let noProjectFile = createTempDir("m13-no-project-file-", "")
    defer: removeDir(noProjectFile)
    createDir(noProjectFile)
    writeFile(noProjectFile / "readme.txt", "not a project\n")
    failsClosed(bareInstance(noProjectFile))
    check "project file" in cacheEntryIdentityError(
      solvedSourceCacheEntryIdentity(bareInstance(noProjectFile)))

    # The OTHER arm of the same refusal, and a separate guard:
    # ``resolveProjectFile`` RAISES when both ``repro.nim`` and
    # ``reprobuild.nim`` exist. Swallowing that exception without
    # recording missing evidence leaves ``entryPath`` empty, the closure
    # empty, and a digest over nothing — which the empty-path arm above
    # masks, so neither could be falsified alone.
    let ambiguous = createTempDir("m13-ambiguous-project-file-", "")
    defer: removeDir(ambiguous)
    createDir(ambiguous)
    writeFile(ambiguous / "repro.nim", "const entry = 1\n")
    writeFile(ambiguous / "reprobuild.nim", "const legacy = 1\n")
    failsClosed(bareInstance(ambiguous))
    check "project file is unresolvable" in cacheEntryIdentityError(
      solvedSourceCacheEntryIdentity(bareInstance(ambiguous)))

    let named = createTempDir("m13-no-package-name-", "")
    defer: removeDir(named)
    writeProject(named)
    var nameless = solvedInstance(named)
    nameless.packageName = ""
    failsClosed(nameless)
    check "package name" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(nameless))

  test "a dependency instance key of the wrong width or alphabet refuses":
    # Guard: ``isHex64``, in BOTH of its halves. The existing fail-closed
    # case supplies a dependency key that is wrong in both respects at
    # once, so either half alone could be deleted with the suite green —
    # and a truncated-but-hex key is exactly the shape a caller produces
    # by accident.
    let root = createTempDir("m13-dep-key-shape-", "")
    defer: removeDir(root)
    writeProject(root)

    var shortHex = solvedInstance(root)
    shortHex.dependencyInstances = @["a1b2c3d4e5f60718293a4b5c6d7e8f90"]
    failsClosed(shortHex)
    check "malformed dependency instance key" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(shortHex))

    var wideNonHex = solvedInstance(root)
    wideNonHex.dependencyInstances = @[repeat('z', 64)]
    failsClosed(wideNonHex)
    check "malformed dependency instance key" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(wideNonHex))

    # Non-vacuity: a well-formed key of the right width still keys.
    check identityKeyOnEveryPath(solvedInstance(root)).len == 64

  test "an empty supplied effective search root refuses":
    # Guard: ``sourceIdentity`` rejects an EMPTY entry in a root set the
    # caller asserts it reconstructed. An empty root is not a root the
    # compiler was given, so the assertion is demonstrably wrong in the
    # one respect this module can check — the same reasoning the
    # non-existent-root refusal rests on, and separately unprotected.
    let root = createTempDir("m13-empty-supplied-root-", "")
    defer: removeDir(root)
    writeProject(root)
    var instance = solvedInstance(root)
    instance.effectiveSearchRoots = @[root / "internal", "   "]
    failsClosed(instance)
    check "supplied effective search root is empty" in
      cacheEntryIdentityError(solvedSourceCacheEntryIdentity(instance))

  test "the pending diagnostic names every missing input in one order":
    # Guard: ``sourceIdentity`` sorts ``missing`` before it stamps the
    # marker, so the refusal text is a function of the instance rather
    # than of the order the checks happen to run in. Diagnostic only —
    # a PENDING identity cannot be keyed either way — but the value is
    # part of the identity object, and an order-dependent one makes two
    # equal instances compare unequal.
    let root = createTempDir("m13-pending-order-", "")
    defer: removeDir(root)
    writeProject(root)
    var instance = solvedInstance(root)
    instance.optionsSolved = false
    instance.dependenciesResolved = false
    instance.toolchain.version = ""
    instance.platform.abi = ""
    let error = cacheEntryIdentityError(
      solvedSourceCacheEntryIdentity(instance))
    let head = "unbound solved source instance: "
    let idx = error.find(head)
    check idx >= 0
    let listed = error[idx + head.len .. ^1].split("; ")
    check listed.len == 4
    check listed == listed.sorted(cmp)

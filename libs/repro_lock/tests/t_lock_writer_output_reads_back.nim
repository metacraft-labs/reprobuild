## Every lock document this repository WRITES, this repository can READ back.
##
## Named-Lock-Files NLF-M5 groundwork. Design reference: `Locking-And-Solver.md`
## ("the committed solved-graph lock") and `Workspace-Manifest-Optional`
## MO-8 (the self-describing `…lock.v2` document).
##
## THE DEFECT THIS IS THE REGRESSION FOR. `serializeSolvedGraphLock` emitted a
## document tagged `reprobuild.solved-graph-lock.v1` while `parseSolvedGraphLock`
## accepted only `…v2` and raised `SolvedGraphLockParseError` on anything else.
## The module's own writer therefore produced bytes the module's own reader
## rejected outright. `repro build --print-solved-graph` printed exactly those
## bytes, so its output LOOKED like a lock file and was not one: redirect it to
## `repro.lock` and the next `repro build` refuses to load it. The workarounds
## were spread across the tree — `repro lock validate` reserializes through
## `serializeLockedDependencies` for its own round-trip check, and NLF-M4's
## fixtures avoid the writer entirely — which is what kept the defect alive
## rather than fatal.
##
## NLF-M5 makes lock GENERATION a rule-generator edge, so a generator would be
## emitting documents through this writer. The invariant has to hold first.
##
## ## What makes this discriminating rather than tautological
##
## Asserting only "the parse did not raise" would pass against a reader that
## returns a zero value, and asserting only "parsed == serialized" would pass
## against a writer/reader pair that both collapse to a constant. So each pair
## is pinned from both sides:
##
##   * the ROUND-TRIP half — write a solved graph, read it back, and require
##     FULL structural equality with the object that was written (schema tag
##     included, since the schema tag is precisely what the defect got wrong);
##   * the CONTROL half — two genuinely different solved graphs must read back
##     as two different objects, so a constant-returning reader fails;
##   * the STABILITY half — write -> read -> write is byte-identical, so a
##     reader that silently drops a field it cannot represent fails.
##
## The `LockedDependencies` pair is exercised the same way over ALL FOUR
## coordinate kinds (`vcs` / `store` / `registry` / `foreign`), because a case
## object is exactly where a writer/reader pair drifts one branch at a time.
##
## Test-double policy: NO mocks, doubles, or fakes — and none would be
## meaningful here, since the property under test IS the behaviour of the real
## serializer and the real parser. Real `serializeSolvedGraphLock` /
## `parseSolvedGraphLock` and real `serializeLockedDependencies` /
## `parseLockedDependencies`, over real documents built by the real
## `solutionToLock` from a real `UnifiedSolution`. No filesystem is involved
## because the defect is in the byte layer, not in the IO layer.

import std/[strutils, unittest]

import repro_lock

import ./nlf_lock_fixtures

const Platform = "amd64-linux"

proc solvedGraph(packages: openArray[(string, string)];
                 variants: openArray[(string, string)] = [];
                 inputsText = "packages: demo"): SolvedGraphLock =
  solutionToLock(solutionOf(packages, variants), Platform, inputsText)

proc sameCoordinates(a, b: Coordinates): bool =
  ## Structural equality for the coordinate sum. Written by hand because Nim's
  ## derived `==` refuses to compare `case` objects ("parallel 'fields' iterator
  ## does not work for 'case' objects"), NOT because anything here is a stand-in
  ## for the product: every field compared is the product's own field, read out
  ## of the product's own parser.
  if a.kind != b.kind: return false
  case a.kind
  of ckVcs:
    a.url == b.url and a.gitRef == b.gitRef and a.revision == b.revision
  of ckStore:
    a.storeHash == b.storeHash
  of ckRegistry:
    a.registryName == b.registryName and
      a.registryVersion == b.registryVersion
  of ckForeign:
    a.provisioner == b.provisioner and
      a.foreignCoordinates == b.foreignCoordinates

proc sameDep(a, b: LockedDep): bool =
  a.name == b.name and a.path == b.path and
    sameCoordinates(a.coordinates, b.coordinates) and
    a.integrity == b.integrity and a.version == b.version and
    a.visibility == b.visibility and a.participation == b.participation and
    a.depends == b.depends and a.tags == b.tags

proc sameLockedDependencies(a, b: LockedDependencies): bool =
  if a.schema != b.schema or a.platform != b.platform or
      a.optimal != b.optimal or a.inputsDigest != b.inputsDigest or
      a.variants != b.variants or a.packages != b.packages or
      a.deps.len != b.deps.len:
    return false
  for i in 0 ..< a.deps.len:
    if not sameDep(a.deps[i], b.deps[i]): return false
  true

proc depsOfEveryCoordinateKind(): seq[LockedDep] =
  ## One `LockedDep` per `CoordKind`, each with every scalar field populated
  ## with a DISTINCT value. Distinctness matters: a writer that emitted the
  ## right number of fields in the wrong order, or a reader that read `url`
  ## into `revision`, would survive a fixture whose fields all read alike.
  ##
  ## Listed in the writer's CANONICAL order (by name, then path), because
  ## `serializeLockedDependencies` sorts the `deps` set on the way out — a
  ## documented normalization, not a loss, and the case below measures the
  ## normalization separately rather than letting it blur this fixture.
  @[
    LockedDep(name: "alpha", path: "deps/alpha",
      coordinates: Coordinates(kind: ckVcs,
        url: "https://example.invalid/alpha.git",
        gitRef: "refs/heads/main",
        revision: "1111111111111111111111111111111111111111"),
      integrity: "blake3:aa01", version: "1.2.3", visibility: "public",
      participation: "source", depends: @["beta", "gamma"],
      tags: @["core", "vendored"]),
    LockedDep(name: "beta", path: "",
      coordinates: Coordinates(kind: ckStore, storeHash: "bb02"),
      integrity: "blake3:bb02", version: "0.9.0", visibility: "private",
      participation: "binary", depends: @[], tags: @[]),
    LockedDep(name: "delta", path: "vendor/delta",
      coordinates: Coordinates(kind: ckForeign,
        provisioner: "nix", foreignCoordinates: "nixpkgs#hello"),
      integrity: "blake3:dd04", version: "2.10", visibility: "public",
      participation: "source", depends: @[], tags: @["foreign"]),
    LockedDep(name: "gamma", path: "",
      coordinates: Coordinates(kind: ckRegistry,
        registryName: "nimble", registryVersion: "3.4.5"),
      integrity: "blake3:cc03", version: "3.4.5", visibility: "public",
      participation: "", depends: @["alpha"], tags: @["registry"]),
  ]

suite "a written lock document reads back":

  test "serializeSolvedGraphLock output parses back to the same solved graph":
    # The direct regression. On the pre-fix tree this raised, verbatim:
    #   Unhandled exception: unsupported lock schema
    #   'reprobuild.solved-graph-lock.v1'
    #   (expected reprobuild.solved-graph-lock.v2);
    #   regenerate with `repro lock refresh` [SolvedGraphLockParseError]
    # (The v1 diagnostic has since been reworded — see the rejection case
    # below, which is what pins its current text.)
    let written = solvedGraph(
      @[("libfoo", "1.4.2"), ("nim", "2.2.0"), ("zlib", "1.3.1")],
      @[("compiler", "clang"), ("enableTLS", "true")])
    let document = serializeSolvedGraphLock(written)

    let readBack = parseSolvedGraphLock(document)

    # FULL structural equality, schema tag included: the tag is the field the
    # defect got wrong, so a test that compared only the payload would still
    # pass against a writer emitting an unreadable tag.
    check readBack == written
    check readBack.schema == SolvedGraphLockSchemaV2

    # The solved graph the build path actually consumes survives too.
    check sameSolution(lockToSolution(readBack), lockToSolution(written))

    # And the document is a lock document by the standard the rest of the tree
    # uses: the unified reader accepts it as well, so `--print-solved-graph`
    # output redirected to a file is a lock file `repro build` can load.
    let unified = parseLockedDependencies(document)
    check solvedPartOf(unified) == written

  test "the CONTROL: two different solved graphs read back as different":
    # Without this, the case above passes against a reader that returns a
    # constant and a writer that emits a constant.
    let a = solvedGraph(@[("libfoo", "1.4.2")])
    let b = solvedGraph(@[("libfoo", "2.0.0")])
    check serializeSolvedGraphLock(a) != serializeSolvedGraphLock(b)
    check parseSolvedGraphLock(serializeSolvedGraphLock(a)) !=
      parseSolvedGraphLock(serializeSolvedGraphLock(b))

    # Each axis of the document independently survives the trip, so a reader
    # that dropped one of them could not hide behind the others.
    let full = solvedGraph(@[("libfoo", "1.4.2")], @[("enableTLS", "false")],
      inputsText = "distinct inputs body")
    let round = parseSolvedGraphLock(serializeSolvedGraphLock(full))
    check round.platform == Platform
    check round.optimal == full.optimal
    check round.inputsDigest == full.inputsDigest
    check round.inputsDigest.len > 0
    check round.variants == full.variants
    check round.packages == full.packages

  test "write -> read -> write is byte-identical":
    # A reader that silently dropped a field it could not represent would
    # round-trip "equal enough" for the checks above only if the writer dropped
    # it too; comparing the BYTES closes that.
    let written = solvedGraph(
      @[("libfoo", "1.4.2"), ("nim", "2.2.0")], @[("compiler", "clang")])
    let first = serializeSolvedGraphLock(written)
    let second = serializeSolvedGraphLock(parseSolvedGraphLock(first))
    check first == second

  test "a v1-tagged document is still rejected, and named as stale":
    # The fix is "the writer emits what the reader accepts", NOT "the reader
    # accepts anything". A lock committed by an older Reprobuild must still be
    # refused rather than silently misread, and the diagnostic must say which
    # kind of wrong it is so the reader is not left guessing between a typo and
    # a superseded format.
    let stale = serializeSolvedGraphLock(solvedGraph(@[("libfoo", "1.4.2")]))
      .replace(SolvedGraphLockSchemaV2, SolvedGraphLockSchemaV1)
    expect SolvedGraphLockParseError:
      discard parseSolvedGraphLock(stale)
    try:
      discard parseSolvedGraphLock(stale)
    except SolvedGraphLockParseError as e:
      check SolvedGraphLockSchemaV1 in e.msg
      check "superseded" in e.msg
      check "repro lock refresh" in e.msg

  test "escaped scalars survive the trip":
    # `tomlEscape` / `tomlUnescape` are the module's other writer/reader pair.
    # They are private, so they are exercised through the public documents.
    let written = solvedGraph(
      @[("weird\"name", "1.0\\beta"), ("tabbed\tpkg", "2.0")],
      @[("quote\"axis", "back\\slash")])
    check parseSolvedGraphLock(serializeSolvedGraphLock(written)) == written

suite "the unified lock document reads back":

  test "serializeLockedDependencies round-trips over every coordinate kind":
    var written = lockedDepsFromSolved(solvedGraph(
      @[("libfoo", "1.4.2"), ("nim", "2.2.0")], @[("compiler", "clang")]))
    written.deps = depsOfEveryCoordinateKind()

    let readBack = parseLockedDependencies(serializeLockedDependencies(written))

    check readBack.deps.len == written.deps.len
    for i in 0 ..< written.deps.len:
      check sameDep(readBack.deps[i], written.deps[i])
    check sameLockedDependencies(readBack, written)

    # Write -> read -> write is byte-identical for this pair too.
    check serializeLockedDependencies(readBack) ==
      serializeLockedDependencies(written)

  test "an out-of-order deps set normalizes rather than being lost":
    # The one way this pair is NOT the identity: the writer sorts `deps` by
    # (name, path). Nothing is dropped — the same set comes back — so state the
    # normalization explicitly instead of letting the fixture order hide it.
    var canonical = lockedDepsFromSolved(solvedGraph(@[("libfoo", "1.4.2")]))
    canonical.deps = depsOfEveryCoordinateKind()
    var shuffled = canonical
    shuffled.deps = @[canonical.deps[3], canonical.deps[0],
                      canonical.deps[2], canonical.deps[1]]

    check serializeLockedDependencies(shuffled) ==
      serializeLockedDependencies(canonical)
    check sameLockedDependencies(
      parseLockedDependencies(serializeLockedDependencies(shuffled)), canonical)

  test "the CONTROL: a changed coordinate reads back changed":
    var a = lockedDepsFromSolved(solvedGraph(@[("libfoo", "1.4.2")]))
    a.deps = depsOfEveryCoordinateKind()
    var b = a
    b.deps[0].coordinates = Coordinates(kind: ckVcs,
      url: "https://example.invalid/alpha.git",
      gitRef: "refs/heads/main",
      revision: "2222222222222222222222222222222222222222")
    check serializeLockedDependencies(a) != serializeLockedDependencies(b)
    check not sameLockedDependencies(
      parseLockedDependencies(serializeLockedDependencies(a)),
      parseLockedDependencies(serializeLockedDependencies(b)))

  test "lockedDepsFromSolved / solvedPartOf agree on the solved sub-part":
    # The in-memory counterpart of the same invariant: the lift and the
    # projection are a pair, and a pair that disagrees on the schema tag is the
    # same defect one layer up.
    let solved = solvedGraph(
      @[("libfoo", "1.4.2"), ("nim", "2.2.0")], @[("compiler", "clang")])
    check solvedPartOf(lockedDepsFromSolved(solved)) == solved

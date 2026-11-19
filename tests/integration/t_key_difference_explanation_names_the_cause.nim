## `repro cache explain` names why two library edges' cache keys differ:
## exactly the one cause that separates them, and no other.
##
## Five pairs of the `mathlib` library edge (`writeFeatureLibraryProject`),
## each pair two projects at different absolute paths that differ in one
## thing:
##
## | pair         | the second project                         | edge    | cause |
## |--------------|--------------------------------------------|---------|-------|
## | source       | the library source returns `a + b + 1`     | compile | `input` `${project}/vendor/mathlib/src/add.c` |
## | flag         | compiles the library with `-O1`, not `-O2` | compile | `flag` `-O` |
## | define       | selects `MATHLIB_WITH_MUL`                 | compile | `define` `MATHLIB_WITH_MUL` |
## | compiler     | is planned with the host's GCC (`--tool-provisioning=path`) instead of the store-realized GCC 15.3.0 | compile | `toolchain` `PATH`, naming the two versions |
## | dependency   | selects `MATHLIB_WITH_MUL`                 | archive | `dependency` on the object, because of the `define` |
##
## Each pair is asked BEFORE either project has been built: the explanation
## comes from the planned graph and the source files, the evidence the
## engine keys by, so it is usable without running the build. The compiler
## pair is asked from two `repro cache key --json` documents, because its two
## sides are planned under two provisioning modes. The other pairs are asked
## by selector. Then both projects of each pair are built (the compiler pair
## only under tarball: the host's GCC reads `/nix/store`, so its edges have
## no portable record at all), and the explanation is asked again, now with
## the recorded executions: the cause must not change.
##
## VACUITY GUARD: each pair is asserted to have different keys, as the ENGINE
## computed them when it built the projects (`portable-fingerprint`): the
## weak keys for the flag and define pairs, the strong keys for the source
## and dependency pairs, whose static descriptions agree. The weak key the
## explanation reports for a side is asserted to be the one the engine
## computed, so the explanation describes the key the engine uses. The
## compiler pair's weak keys are asserted to differ in the key documents.
##
## NEGATIVE CONTROL: a copy of the base project at another path is
## `undetermined` with no cause before anything is built (the planned keys
## agree; what the edges read is known only from an execution), and
## `same-key`, substitutable, once the base project has been built: its
## record, evaluated against the copy's files, gives the copy the same strong
## key, which is the engine's own lookup.
##
## FALSIFYING MUTATION (run when this test was written, 2026-11-19): an `explainKeyDifference` that reports
## every differing pair as one generic `input` cause ("inputs differ") without
## the component turns the flag, define, compiler and dependency cases red.
##
## No mocks: the built `repro`, the engine-provisioned GCC and `ar`, the
## host's GCC for the one planned comparison, real Git checkouts at
## different paths, the real monitor and action cache, the build reports the
## engine writes, and the JSON `repro cache` prints. Network: a store that
## does not hold the toolchain yet fetches the pinned archive (102 MB) once;
## set `REPRO_CONFORMANCE_STORE` to pay that once per pin.

import std/[json, os, unittest]

import repro_test_support
import library_cache_sharing_fixture

type
  Pair = object
    name: string
    edge: string
    variant: string       ## the second project's path
    kind: string          ## the expected cause's kind
    subject: string       ## and subject

proc causesOf(doc: JsonNode): seq[JsonNode] =
  for cause in doc["causes"]:
    result.add(cause)

proc describe(doc: JsonNode): string =
  doc.pretty()

proc checkOneCause(doc: JsonNode; pair: Pair) =
  checkpoint(pair.name & ": " & describe(doc))
  check doc["schema"].getStr() == "reprobuild.key-explanation.v1"
  check doc["verdict"].getStr() == "different-key"
  check doc["substitutable"].getBool() == false
  let causes = causesOf(doc)
  check causes.len == 1
  if causes.len == 1:
    check causes[0]["kind"].getStr() == pair.kind
    check causes[0]["subject"].getStr() == pair.subject

suite "the explanation of a key difference names its cause":
  test "source, flag, define, compiler and dependency pairs":
    var host = newSharedHost("rbc4-explain-")
    defer: host.cleanup()
    let base = host.scratch / "base" / "app"
    writeFeatureLibraryProject(base, "base", [])
    let source = host.scratch / "source" / "app"
    writeFeatureLibraryProject(source, "source", [], addend = 1)
    let flag = host.scratch / "flag" / "app"
    writeFeatureLibraryProject(flag, "flag", [], libFlags = ["-O1"])
    let define = host.scratch / "define" / "app"
    writeFeatureLibraryProject(define, "define", [MathlibFeature])
    let copy = host.scratch / "copy" / "app"
    writeFeatureLibraryProject(copy, "copy", [])

    let pairs = @[
      Pair(name: "source", edge: LibraryCompileEdge, variant: source,
        kind: "input", subject: "${project}/vendor/mathlib/src/add.c"),
      Pair(name: "flag", edge: LibraryCompileEdge, variant: flag,
        kind: "flag", subject: "-O"),
      Pair(name: "define", edge: LibraryCompileEdge, variant: define,
        kind: "define", subject: MathlibFeature),
      Pair(name: "dependency", edge: LibraryArchiveEdge, variant: define,
        kind: "dependency",
        subject: "${project}/" & LibraryObject)]

    proc sel(project, edge: string): string = project & "#" & edge

    # --- Before anything is built: planned evidence only. ---------------
    for pair in pairs:
      let doc = host.explainKeys(sel(base, pair.edge),
        sel(pair.variant, pair.edge))
      checkOneCause(doc, pair)
      check doc["a"]["strong"].kind == JNull
      check doc["b"]["strong"].kind == JNull
      let cause = causesOf(doc)
      if cause.len == 1:
        check cause[0]["evidence"].getStr() == "planned"
        if pair.name == "dependency":
          # The dependency names why its producer's key differs.
          check cause[0]["because"].len == 1
          check cause[0]["because"][0]["kind"].getStr() == "define"
          check cause[0]["because"][0]["subject"].getStr() == MathlibFeature

    # The compiler: the same project planned with the store-realized GCC and
    # with the host's, through two key documents.
    let tarballKey = host.actionKeyDocument(sel(base, LibraryCompileEdge),
      host.scratch / "key-tarball.json", provisioning = "tarball")
    let pathKey = host.actionKeyDocument(sel(base, LibraryCompileEdge),
      host.scratch / "key-path.json", provisioning = "path")
    check tarballKey["schema"].getStr() == "reprobuild.action-key.v1"
    check tarballKey["weak"].getStr() != pathKey["weak"].getStr()
    let compilerPair = Pair(name: "compiler", edge: LibraryCompileEdge,
      kind: "toolchain", subject: "PATH")
    let compilerDoc = host.explainKeys(host.scratch / "key-tarball.json",
      host.scratch / "key-path.json")
    checkOneCause(compilerDoc, compilerPair)
    let compilerCause = causesOf(compilerDoc)
    if compilerCause.len == 1:
      check compilerCause[0]["toolA"].getStr() == "gcc 15.3.0"
      let toolB = compilerCause[0]["toolB"].getStr()
      checkpoint("the host's compiler: " & toolB)
      check toolB.len > 0
      check toolB != compilerCause[0]["toolA"].getStr()

    # Negative control, before a build: the planned keys agree.
    let copyBefore = host.explainKeys(sel(base, LibraryCompileEdge),
      sel(copy, LibraryCompileEdge))
    checkpoint("copy before: " & describe(copyBefore))
    check copyBefore["verdict"].getStr() == "undetermined"
    check copyBefore["causes"].len == 0
    check copyBefore["a"]["weak"].getStr() == copyBefore["b"]["weak"].getStr()

    # --- Build the base project and each variant. ------------------------
    let baseRun = host.build(base, portable = false, provisioning = "tarball")
    checkpoint(baseRun.output)
    checkpoint(allEngineReasons(baseRun))
    require baseRun.code == 0

    # Negative control, after the base build: the copy would be served.
    let copyAfter = host.explainKeys(sel(base, LibraryCompileEdge),
      sel(copy, LibraryCompileEdge))
    checkpoint("copy after: " & describe(copyAfter))
    check copyAfter["verdict"].getStr() == "same-key"
    check copyAfter["substitutable"].getBool()
    check copyAfter["causes"].len == 0
    check copyAfter["a"]["strong"].getStr().len == 64
    check copyAfter["a"]["strong"].getStr() ==
      copyAfter["b"]["strong"].getStr()

    var runs: seq[(string, BuildRun)] = @[]
    proc runOf(project: string): BuildRun =
      for (path, run) in runs:
        if path == project:
          return run
      result = host.build(project, portable = false, provisioning = "tarball")
      if result.code != 0:
        raise newException(AssertionDefect, "repro build of " & project &
          " exited " & $result.code & ":\n" & result.output & "\n" &
          allEngineReasons(result))
      runs.add((project, result))

    for pair in pairs:
      let variantRun = runOf(pair.variant)
      # Vacuity guard: the ENGINE's keys of the two edges differ, as it
      # computed them when it executed each.
      let engineA = baseRun.recordedPortableKey(pair.edge)
      let engineB = variantRun.recordedPortableKey(pair.edge)
      checkpoint(pair.name & ": engine keys " & $engineA & " / " & $engineB)
      require engineA.strong.len == 64
      require engineB.strong.len == 64
      check engineA.strong != engineB.strong
      if pair.name in ["flag", "define"]:
        check engineA.weak != engineB.weak
      else:
        check engineA.weak == engineB.weak
      # The same cause, now with the recorded executions, and the keys the
      # explanation reports are the engine's.
      let doc = host.explainKeys(sel(base, pair.edge),
        sel(pair.variant, pair.edge))
      checkOneCause(doc, pair)
      check doc["a"]["weak"].getStr() == engineA.weak
      check doc["b"]["weak"].getStr() == engineB.weak
      check doc["a"]["strong"].getStr() == engineA.strong
      check doc["b"]["strong"].getStr() == engineB.strong

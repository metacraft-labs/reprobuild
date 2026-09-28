## Portable memoization store (Cache-Scope P3.3): BuildXL's weak -> candidate
## path sets -> strong -> record, over portable identities.
##
## The properties: a record made on one checkout is found from ANOTHER checkout
## at a different absolute path; a content change misses; with several
## candidate path sets the one matching the current state wins; and — the
## lookup-without-materialization property P3.4 builds on — a downstream
## action is found when its input is an upstream OUTPUT that is not on disk,
## identified only through the upstream record's output digest.

import std/[options, os, tempfiles, unittest]

import repro_core/paths
import repro_local_store/portable_fingerprint
import repro_local_store/portable_memo

proc roots(project: string): seq[LogicalRoot] =
  @[LogicalRoot(label: "project", path: project, kind: lrkTracked)]

proc checkout(base, source: string): string =
  result = base / "p"
  createDir(result / "src")
  writeFile(result / "src" / "a.c", source)

proc execute(project: string): PortableMemoRecord =
  ## "Run" an action that reads src/a.c and writes out/a.o, and return the
  ## portable memo record the engine would store for it. Keyed by the
  ## action's OWN portable weak fingerprint, as the engine keys it.
  let fp = computePortableFingerprint(roots(project), argv = @["cc", "a.c"],
    cwd = project, env = @[], declaredInputs = @[],
    reads = @[project / "src" / "a.c"], probes = @[], enumerations = @[])
  doAssert fp.portable
  createDir(project / "out")
  writeFile(project / "out" / "a.o",
    "object(" & readFile(project / "src" / "a.c") & ")")
  let outs = portableOutputs(roots(project), [project / "out" / "a.o"])
  doAssert outs.portable
  PortableMemoRecord(weakHex: fp.weakHex, pathSet: pathSetOf(fp.inputs),
    strongHex: fp.strongHex, outputs: outs.outputs)

suite "portable memo store":

  test "path set and memo codecs round-trip and are deterministic":
    let record = PortableMemoRecord(weakHex: "w", strongHex: "s",
      pathSet: @[PathSetEntry(kind: pikRead, path: "project:b"),
                 PathSetEntry(kind: pikProbe, path: "project:a")],
      outputs: @[PortableOutput(path: "project:o", digest: "d",
                                directory: true)])
    let bytes = encodeMemo(record)
    check encodeMemo(record) == bytes
    let back = decodeMemo(bytes)
    check back.weakHex == "w"
    check back.strongHex == "s"
    check back.pathSet == pathSetOf([
      PortableInput(kind: pikRead, path: "project:b"),
      PortableInput(kind: pikProbe, path: "project:a")])
    check back.outputs == record.outputs
    check decodePathSet(encodePathSet(record.pathSet)) == back.pathSet
    expect MemoCodecError:
      discard decodeMemo(encodePathSet(record.pathSet))  # wrong tag

  test "a record made on one checkout is found from another checkout":
    let a = createTempDir("repro-memo-a-", "")
    let b = createTempDir("repro-memo-bbbbbbbbbbbb-", "")
    let store = createTempDir("repro-memo-store-", "")
    defer:
      removeDir(a)
      removeDir(b)
      removeDir(extendedPath(store))
    let produced = execute(checkout(a, "int x;\n"))
    recordMemo(store, produced)
    let pb = checkout(b, "int x;\n")
    let found = lookupMemo(store, roots(pb), produced.weakHex)
    check found.isSome
    check found.get().outputs == produced.outputs
    # And its promised output is exactly what a local execution would make.
    check execute(pb).outputs == produced.outputs

  test "a content change misses":
    let a = createTempDir("repro-memo-miss-a-", "")
    let b = createTempDir("repro-memo-miss-b-", "")
    let store = createTempDir("repro-memo-miss-store-", "")
    defer:
      removeDir(a)
      removeDir(b)
      removeDir(extendedPath(store))
    let produced = execute(checkout(a, "int x;\n"))
    recordMemo(store, produced)
    check lookupMemo(store, roots(checkout(b, "int y;\n")),
      produced.weakHex).isNone

  test "with several candidate path sets, the one matching now wins":
    let a = createTempDir("repro-memo-multi-", "")
    let store = createTempDir("repro-memo-multi-store-", "")
    defer:
      removeDir(a)
      removeDir(extendedPath(store))
    let project = checkout(a, "int x;\n")
    # Execution 1 observed only src/a.c.
    let first = execute(project)
    recordMemo(store, first)
    # Execution 2 of the SAME static action also probed a header, which
    # EXISTED then and produced different bytes.
    writeFile(project / "src" / "a.h", "")
    let fp2 = computePortableFingerprint(roots(project), @["cc", "a.c"],
      project, @[], @[], reads = @[project / "src" / "a.c"],
      probes = @[project / "src" / "a.h"], enumerations = @[])
    check fp2.weakHex == first.weakHex
    recordMemo(store, PortableMemoRecord(weakHex: fp2.weakHex,
      pathSet: pathSetOf(fp2.inputs), strongHex: fp2.strongHex,
      outputs: @[PortableOutput(path: "project:out/a.o", digest: "second")]))
    check candidatePathSets(store, first.weakHex).len == 2
    # Now the header exists: only execution 2's path set matches.
    let withHeader = lookupMemo(store, roots(project), first.weakHex)
    check withHeader.isSome
    check withHeader.get().outputs[0].digest == "second"
    # Remove it: execution 2's path set now computes a DIFFERENT strong
    # fingerprint (probe absent), and execution 1's matches.
    removeFile(project / "src" / "a.h")
    let without = lookupMemo(store, roots(project), first.weakHex)
    check without.isSome
    check without.get().strongHex == first.strongHex

  test "lookup without materialization: an upstream output need not exist":
    let a = createTempDir("repro-memo-lazy-", "")
    let store = createTempDir("repro-memo-lazy-store-", "")
    defer:
      removeDir(a)
      removeDir(extendedPath(store))
    let project = checkout(a, "int x;\n")
    # Upstream: compile src/a.c -> out/a.o.
    let upstream = execute(project)
    recordMemo(store, upstream)
    # Downstream: link out/a.o -> out/app. Recorded while out/a.o exists.
    let link = computePortableFingerprint(roots(project), @["ld", "a.o"],
      project, @[], @[], reads = @[project / "out" / "a.o"], probes = @[],
      enumerations = @[])
    recordMemo(store, PortableMemoRecord(weakHex: link.weakHex,
      pathSet: pathSetOf(link.inputs), strongHex: link.strongHex,
      outputs: @[PortableOutput(path: "project:out/app", digest: "app")]))
    # Now a FRESH host state: the object file was never built here.
    removeDir(project / "out")
    check lookupMemo(store, roots(project), link.weakHex).isNone
    # Resolving out/a.o from the upstream RECORD finds the downstream result
    # with no upstream bytes on disk and nothing executed.
    let hitUp = lookupMemo(store, roots(project), upstream.weakHex)
    require hitUp.isSome
    let hitDown = lookupMemo(store, roots(project), link.weakHex,
      outputResolver([hitUp.get()]))
    check hitDown.isSome
    check hitDown.get().outputs[0].path == "project:out/app"

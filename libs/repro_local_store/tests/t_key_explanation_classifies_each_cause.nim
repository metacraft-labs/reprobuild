## The classification rules of `key_explanation`, one per cause kind, over
## descriptions built with `portableKeyDescription` (the function the engine
## keys the portable weak fingerprint with) from physical paths under real
## temporary roots, and source identities read from real files.
##
## No mocks: nothing here stands in for the engine or the cache. The values
## compared are the ones the engine itself computes from an action's argv,
## environment, declared inputs and static fields; this test pins how two of
## them are told apart. The end-to-end counterpart, over real builds with a
## real compiler, is `tests/integration/t_key_difference_explanation_names_the_cause`.
##
## Each case asserts the keys differ (a case whose keys agree would pass any
## classifier vacuously) and that the explanation names exactly one cause of
## exactly the expected kind and subject.

import std/[json, options, os, strutils, tempfiles, unittest]

import repro_local_store/portable_fingerprint
import repro_local_store/portable_memo
import repro_local_store/key_explanation

type Side = object
  root: string
  argv: seq[string]
  env: seq[(string, string)]
  inputs: seq[string]
  outputs: seq[string]

proc evidenceOf(side: Side; producers: seq[(string, ActionKeyEvidence)] = @[];
                id = "lib-compile"): ActionKeyEvidence =
  let roots = @[LogicalRoot(label: "project", path: side.root,
    kind: lrkTracked)]
  var fields = @["kind=bakProcess", "builtinText="]
  for output in side.outputs:
    fields.add("output=" & output)
  let description = portableKeyDescription(roots, side.argv, side.root,
    side.env, side.inputs, fields)
  result = ActionKeyEvidence(actionId: id, project: side.root,
    eligible: true, description: description,
    weakHex: portableWeakFingerprint(description))
  for i, path in side.inputs:
    var input = InputEvidence(path: description.declaredInputs[i])
    var produced = false
    for (output, producer) in producers:
      if output == path:
        input.producer.add(producer)
        produced = true
    if not produced:
      input.identity = readIdentity(path)
    result.inputs.add(input)
  result.recordedNote = "not built"

proc project(prefix, source: string): string =
  result = createTempDir(prefix, "")
  createDir(result / "src")
  writeFile(result / "src" / "add.c", source)

proc compileSide(root: string; flags: seq[string] = @["-O2"];
                 path = "${store}/tool-store/prefixes/gcc/15.3.0-aaaa/bin"):
    Side =
  Side(root: root,
    argv: @["gcc", "-c"] & flags & @["-o", root / "add.o", root / "src/add.c"],
    env: @[("PATH", path)], inputs: @[root / "src/add.c"],
    outputs: @[root / "add.o"])

proc onlyCause(explanation: KeyExplanation): KeyCause =
  checkpoint($toJson(explanation, ActionKeyEvidence(), ActionKeyEvidence()))
  check explanation.verdict == kvDifferentKey
  check explanation.causes.len == 1
  if explanation.causes.len > 0:
    result = explanation.causes[0]

suite "key_explanation names the one component that differs":
  let rootA = project("keys-a", "int add(int a, int b) { return a + b; }\n")
  let rootB = project("keys-b", "int add(int a, int b) { return a + b; }\n")
  let rootC = project("keys-c", "int add(int a, int b) { return b + a; }\n")

  test "two checkouts at different paths have the same key":
    let a = evidenceOf(compileSide(rootA))
    let b = evidenceOf(compileSide(rootB))
    check a.weakHex == b.weakHex
    let explanation = explainKeyDifference(a, b)
    check explanation.causes.len == 0
    # No execution recorded: what the actions read is not known yet.
    check explanation.verdict == kvUndetermined
    check explanation.unanswered.len == 1

  test "a source file with other content is an input":
    let a = evidenceOf(compileSide(rootA))
    let c = evidenceOf(compileSide(rootC))
    check a.weakHex == c.weakHex
    check a.inputs[0].identity != c.inputs[0].identity
    let cause = onlyCause(explainKeyDifference(a, c))
    check cause.kind == kcInput
    check cause.component == "declared-input"
    check cause.subject == "${project}/src/add.c"

  test "one changed compile flag is a flag":
    let a = evidenceOf(compileSide(rootA, @["-O2"]))
    let b = evidenceOf(compileSide(rootB, @["-O1"]))
    check a.weakHex != b.weakHex
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcFlag
    check cause.subject == "-O"
    check cause.a == "-O2"
    check cause.b == "-O1"

  test "a define present on one side is a define, with its name":
    let a = evidenceOf(compileSide(rootA, @["-O2", "-DWITH_MUL"]))
    let b = evidenceOf(compileSide(rootB, @["-O2"]))
    check a.weakHex != b.weakHex
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcDefine
    check cause.subject == "WITH_MUL"
    check cause.inA and not cause.inB

  test "a define with another value, and the separate `-D NAME` spelling":
    let a = evidenceOf(compileSide(rootA, @["-O2", "-D", "LEVEL=1"]))
    let b = evidenceOf(compileSide(rootB, @["-O2", "-D", "LEVEL=2"]))
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcDefine
    check cause.subject == "LEVEL"

  test "a changed include directory is the -I flag, not a positional":
    var sa = compileSide(rootA)
    var sb = compileSide(rootB)
    sa.argv = sa.argv[0 .. 1] & @["-I", rootA / "include"] & sa.argv[2 .. ^1]
    sb.argv = sb.argv[0 .. 1] & @["-I", rootB / "other"] & sb.argv[2 .. ^1]
    let cause = onlyCause(explainKeyDifference(evidenceOf(sa), evidenceOf(sb)))
    check cause.kind == kcFlag
    check cause.subject == "-I"

  test "another compiler on PATH is the toolchain, with its version":
    let a = evidenceOf(compileSide(rootA))
    let b = evidenceOf(compileSide(rootB,
      path = "/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin"))
    check a.weakHex != b.weakHex
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcToolchain
    check cause.subject == "PATH"
    check cause.toolA == "gcc 15.3.0"
    check cause.toolB == "gcc-wrapper-14.3.0"

  test "a tool's provisioning receipt is the toolchain, and not twice":
    proc withReceipt(side: Side; name, content: string): Side =
      result = side
      let receipt = side.root / "tool-store/provisioning/receipts" / name
      createDir(receipt.parentDir)
      writeFile(receipt, content)
      result.inputs.add(receipt)
    # Another realization of the same tool, and nothing else: one cause.
    let a = evidenceOf(withReceipt(compileSide(rootA),
      "tarball-provision.gcc.aaaa.receipt", "one"))
    let b = evidenceOf(withReceipt(compileSide(rootB),
      "tarball-provision.gcc.aaaa.receipt", "two"))
    let alone = onlyCause(explainKeyDifference(a, b))
    check alone.kind == kcToolchain
    check alone.subject == "gcc"
    # Another tool on PATH brings its own receipt: still one cause, PATH.
    let c = evidenceOf(withReceipt(compileSide(rootC,
      path = "/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin"),
      "nix-tool-provision.gcc.bbbb.receipt", "three"))
    var aSameSource = evidenceOf(withReceipt(compileSide(rootB),
      "tarball-provision.gcc.cccc.receipt", "one"))
    aSameSource.inputs[0].identity = c.inputs[0].identity
    let both = onlyCause(explainKeyDifference(aSameSource, c))
    check both.kind == kcToolchain
    check both.subject == "PATH"

  test "another program is the toolchain":
    var sb = compileSide(rootB)
    sb.argv[0] = "clang"
    let cause = onlyCause(explainKeyDifference(evidenceOf(compileSide(rootA)),
      evidenceOf(sb)))
    check cause.kind == kcToolchain
    check cause.subject == "program"

  test "an input produced by an action whose key differs is a dependency":
    let compileA = evidenceOf(compileSide(rootA, @["-O2", "-DWITH_MUL"]))
    let compileB = evidenceOf(compileSide(rootB, @["-O2"]))
    proc archive(root: string; producer: ActionKeyEvidence):
        ActionKeyEvidence =
      evidenceOf(Side(root: root,
        argv: @["ar", "rcs", root / "lib.a", root / "add.o"],
        inputs: @[root / "add.o"], outputs: @[root / "lib.a"]),
        @[(root / "add.o", producer)], id = "lib-archive")
    let a = archive(rootA, compileA)
    let b = archive(rootB, compileB)
    # The archive's own description is the same: only its input differs.
    check a.weakHex == b.weakHex
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcDependency
    check cause.subject == "${project}/add.o"
    check cause.because.len == 1
    check cause.because[0].kind == kcDefine
    check cause.because[0].subject == "WITH_MUL"
    # Same producer key on both sides: not a cause, and not determined
    # either until something has run.
    let same = explainKeyDifference(archive(rootA, compileB),
      archive(rootB, compileB))
    check same.causes.len == 0

  test "a recorded header read with other content is an observed input":
    var a = evidenceOf(compileSide(rootA))
    var b = evidenceOf(compileSide(rootB))
    let header = PortableInput(kind: pikRead, path: "project:include/add.h",
      digest: "file:" & repeat('1', 64), role: irObserved)
    var other = header
    other.digest = "file:" & repeat('2', 64)
    a.recorded = some(RecordedKeyEvidence(source: "recorded",
      strongHex: repeat('a', 64), inputs: @[header]))
    b.recorded = some(RecordedKeyEvidence(source: "recorded",
      strongHex: repeat('b', 64), inputs: @[other]))
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcInput
    check cause.component == "observed-input"
    check cause.subject == "${project}/include/add.h"
    check cause.evidence == "recorded"

  test "recorded differences behind a planned cause are not causes":
    var a = evidenceOf(compileSide(rootA, @["-O2"]))
    var b = evidenceOf(compileSide(rootB, @["-O1"]))
    a.recorded = some(RecordedKeyEvidence(source: "recorded",
      strongHex: repeat('a', 64), inputs: @[PortableInput(kind: pikRead,
        path: "store:tool-store/prefixes/gcc/15.3.0-aaaa/libexec/cc1",
        digest: "exec:" & repeat('1', 64), role: irObserved)]))
    b.recorded = some(RecordedKeyEvidence(source: "recorded",
      strongHex: repeat('b', 64), inputs: @[]))
    let explanation = explainKeyDifference(a, b)
    check onlyCause(explanation).kind == kcFlag
    check explanation.alsoObserved.len == 1
    check explanation.alsoObserved[0].kind == kcToolchain

  test "the same key with the same recorded execution is substitutable":
    var a = evidenceOf(compileSide(rootA))
    var b = evidenceOf(compileSide(rootB))
    let record = RecordedKeyEvidence(source: "recorded",
      strongHex: repeat('a', 64), inputs: @[])
    a.recorded = some(record)
    b.recorded = some(record)
    let explanation = explainKeyDifference(a, b)
    check explanation.verdict == kvSameKey
    check explanation.substitutable

  test "include directories in another order are one change of order":
    # The same two `-I` directories, swapped. Their order is the header
    # search order, so the keys differ; but no directory was added or
    # removed, and the cause must not say one was.
    var sa = compileSide(rootA)
    var sb = compileSide(rootB)
    sa.argv = sa.argv[0 .. 1] & @["-I", rootA / "x", "-I", rootA / "y"] &
      sa.argv[2 .. ^1]
    sb.argv = sb.argv[0 .. 1] & @["-I", rootB / "y", "-I", rootB / "x"] &
      sb.argv[2 .. ^1]
    let a = evidenceOf(sa)
    let b = evidenceOf(sb)
    check a.weakHex != b.weakHex
    let cause = onlyCause(explainKeyDifference(a, b))
    check cause.kind == kcFlag
    check cause.subject == "-I"
    check cause.a == "-I ${project}/x -I ${project}/y"
    check cause.b == "-I ${project}/y -I ${project}/x"

  test "a positional argument moved among the others says where":
    var sa = compileSide(rootA)
    var sb = compileSide(rootB)
    sa.argv = @["ar", "rcs", rootA / "lib.a", rootA / "one.o", rootA / "two.o"]
    sb.argv = @["ar", "rcs", rootB / "lib.a", rootB / "two.o", rootB / "one.o"]
    let explanation = explainKeyDifference(evidenceOf(sa), evidenceOf(sb))
    check explanation.verdict == kvDifferentKey
    check explanation.causes.len >= 1
    for cause in explanation.causes:
      checkpoint($toJson(cause))
      check cause.kind == kcArgument
      # Never "x against x": a moved item names its two places.
      check cause.a != cause.b

  test "an action-key document round-trips, and a forged one is refused":
    var a = evidenceOf(compileSide(rootA, @["-O2", "-DWITH_MUL"]))
    let observed = @[PortableInput(kind: pikRead,
        path: "project:include/add.h", digest: "file:" & repeat('1', 64),
        role: irObserved)]
    a.recorded = some(RecordedKeyEvidence(source: "recorded",
      strongHex: portableStrongFingerprint(a.weakHex, observed),
      inputs: observed))
    let text = $toJson(a)
    check "\"kind\":\"read\"" in text
    let back = actionKeyEvidenceFromJson(text)
    check back.weakHex == a.weakHex
    check back.recorded.isSome
    check back.recorded.get().inputs == a.recorded.get().inputs
    check explainKeyDifference(a, back).causes.len == 0
    var node = parseJson(text)
    node["description"]["argv"].elems[2] = %"-O3"
    expect ValueError:
      discard actionKeyEvidenceFromJson($node)
    expect ValueError:
      discard actionKeyEvidenceFromJson("""{"schema": "something.else"}""")
    # A recorded half edited to read another header's content no longer
    # gives the strong key it names: refused, not compared.
    var forged = parseJson(text)
    forged["recorded"]["inputs"].elems[0]["identity"] =
      %("file:" & repeat('2', 64))
    expect ValueError:
      discard actionKeyEvidenceFromJson($forged)

  removeDir(rootA)
  removeDir(rootB)
  removeDir(rootC)

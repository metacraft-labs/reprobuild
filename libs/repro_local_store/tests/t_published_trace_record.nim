## Campaign M17 chunk 2 (ReproOS-Campaign-Completion.milestones.org, M17
## deliverables 2, 4 and 7): the published-trace record of
## Edge-Derived-Identities.md §3.1, `PortableMemoRecord` carried to `rbpm-v2`
## (§3.3 rider of 2026-10-27; §10 decision 13).
##
## What is pinned, each against a falsifier named in the case:
##
##   * ROUND TRIP: a record with every field set -- weak fingerprint, policy,
##     evidence level and source, fixed-output flag, declared and observed
##     inputs of every access (each with entry kind, executable bit and
##     digest), strong fingerprint, file and tree outputs with executable
##     bits -- encodes deterministically and decodes to itself.
##   * SEPARATION: an access of a declared input is DECLARED, every other one
##     OBSERVED; the record keeps two lists, the strong fingerprint binds the
##     role, and a miss says which kind of input differed.
##   * EXECUTABLE BIT: a consumer whose input has another executable bit
##     misses.
##   * ENTRY KIND: a consumer whose probed path holds another kind (a file
##     where a directory was) misses on the PORTABLE path, which identified
##     every present probe as "present" until rbpm-v2.
##   * v1 REFUSED: an `rbpm-v1` record or `rbps-v1` path set is refused with
##     `LegacyMemoFormatError`, and a store holding only v1 files misses.
##   * DIGEST DOMAIN: published content digests are BLAKE3-256 under
##     `PublishedDigestDomain`; the same bytes digested without it, or under
##     another domain, do not verify.
##   * EVIDENCE SOURCE: carried by the record, and the publication rule
##     refuses a record that does not state it.
##   * TAMPER: every new field is part of the encoded (signed) bytes, and an
##     identity, role or kind altered without the strong fingerprint makes the
##     record inconsistent, so a lookup refuses it.
##
## MOCK POLICY -- none: real files, the real codec, the real lookup.

import std/[options, os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix

import blake3
import cbor

import repro_core/paths
import repro_local_store

proc roots(project: string): seq[LogicalRoot] =
  @[LogicalRoot(label: "project", path: project, kind: lrkTracked)]

proc hex(c: char): string = repeat(c, 64)

proc everyFieldRecord(): PortableMemoRecord =
  ## A record exercising every field and every identity shape.
  let inputs = @[
    PortableInput(kind: pikRead, path: "project:src/a.c",
      digest: "file:" & hex('1'), role: irDeclared),
    PortableInput(kind: pikRead, path: "project:tools/run",
      digest: "exec:" & hex('2'), role: irDeclared),
    PortableInput(kind: pikRead, path: "project:src/missing.h",
      digest: ReadOfAbsent, role: irObserved),
    PortableInput(kind: pikRead, path: "project:src",
      digest: ReadOfDirectory, role: irObserved),
    PortableInput(kind: pikRead, path: "project:dev/fifo",
      digest: ReadOfSpecial, role: irObserved),
    PortableInput(kind: pikProbe, path: "project:inc/a.h",
      digest: ProbeAbsent, role: irObserved),
    PortableInput(kind: pikProbe, path: "project:inc",
      digest: "directory", role: irObserved),
    PortableInput(kind: pikProbe, path: "project:inc/b.h",
      digest: "file", role: irObserved),
    PortableInput(kind: pikProbe, path: "^project:node_modules",
      digest: ProbeAbsent, role: irObserved),
    PortableInput(kind: pikEnumeration, path: "project:lib",
      digest: hex('3'), role: irObserved),
    PortableInput(kind: pikEnvironment, path: "env:FEATURE",
      digest: hex('4'), role: irObserved),
    PortableInput(kind: pikEnvironment, path: "env:UNSET_ONE",
      digest: EnvUnset, role: irObserved)]
  let tree = @[
    TreeEntry(rel: "bin", kind: tekDirectory),
    TreeEntry(rel: "bin/tool", kind: tekFile, identity: hex('5'),
      executable: true),
    TreeEntry(rel: "readme", kind: tekFile, identity: hex('6')),
    TreeEntry(rel: "link", kind: tekLinkToFile, identity: "readme")]
  let outputs = @[
    PortableOutput(path: "project:out/app", digest: hex('7'),
      executable: true),
    PortableOutput(path: "project:out/tree", digest: treeDigestOf(tree),
      directory: true, entries: tree)]
  newPortableMemoRecord(hex('a'), inputs,
    portableStrongFingerprint(hex('a'), inputs), outputs, ffpHybrid,
    elComplete, formatEvidence("make-depfile"), fixedOutput = true)

proc runAction(project: string; declared: seq[string];
               reads, probes: seq[string];
               tool = "cc"): PortableMemoRecord =
  ## The record the engine stores for an action that declared `declared`,
  ## read `reads` and probed `probes` (a monitored, checksum, Level-0 run).
  ## `tool` names the action, so two cases do not share a weak fingerprint.
  let fp = computePortableFingerprint(roots(project), @[tool, "a.c"],
    project, @[], declared, reads, probes, @[])
  doAssert fp.portable, fp.reason
  newPortableMemoRecord(fp.weakHex, fp.inputs, fp.strongHex,
    newSeq[PortableOutput](), ffpChecksum, elComplete, MonitoredEvidence)

proc withIdentity(record: PortableMemoRecord; path,
                  identity: string): PortableMemoRecord =
  ## `record` with the input at `path` claiming `identity`, its strong
  ## fingerprint untouched.
  result = record
  for input in result.declared.mitems:
    if input.path == path: input.digest = identity
  for input in result.observed.mitems:
    if input.path == path: input.digest = identity

proc setExecutable(path: string; on: bool) =
  when defined(posix):
    discard chmod(path.cstring, Mode(if on: 0o755 else: 0o644))
  else:
    discard

suite "M17 chunk 2: the published-trace record rbpm-v2":

  test "round trip: every field encodes deterministically and decodes to itself":
    let record = everyFieldRecord()
    let bytes = encodeMemo(record)
    check encodeMemo(record) == bytes
    let back = decodeMemo(bytes)
    check back == record
    check back.weakHex == hex('a')
    check back.policy == ffpHybrid
    check back.evidenceLevel == elComplete
    check back.evidenceSource == formatEvidence("make-depfile")
    check back.fixedOutput
    check back.declared.len == 2
    check back.observed.len == 10
    check back.strongHex == record.strongHex
    check back.outputs == record.outputs
    check recordConsistencyReason(back) == ""
    check manifestsConsistent(back)
    # The path set (rbps-v2) round-trips too, with its roles.
    check decodePathSet(encodePathSet(back.pathSet)) == back.pathSet
    check pathSetHash(back.pathSet) == pathSetHash(record.pathSet)

  test "the codec states entry kind and executable bit as fields of their own":
    # The record does not merely carry an opaque identity string: decoding the
    # CBOR shows the kind and the bit, which is what a reader that is not this
    # module sees.
    let root = decodeItem(encodeMemo(everyFieldRecord()))
    check root.elems[0].text == MemoTag
    let declared = root.elems[6].elems
    # [access, path, entryKind, executable, digest]
    var sawExec = false
    for item in declared:
      check item.elems.len == 5
      if item.elems[1].text == "project:tools/run":
        sawExec = true
        check item.elems[2].arg == uint64(ord(iekFile))
        check item.elems[3].arg == 1
        check item.elems[4].text == hex('2')
    check sawExec
    # An identity the parts cannot express is refused by the codec.
    var bad = everyFieldRecord()
    bad.observed[0].digest = "file-but-not-hex"
    expect MemoCodecError:
      discard encodeMemo(bad)

  test "separation: declared inputs stay apart from observed inputs":
    let base = createTempDir("m17-sep-", "")
    defer: removeDir(extendedPath(base))
    let project = base / "p"
    createDir(project / "src")
    writeFile(project / "src" / "a.c", "int a;\n")
    writeFile(project / "src" / "a.h", "#define A\n")
    let record = runAction(project, @[project / "src" / "a.c"],
      reads = @[project / "src" / "a.c", project / "src" / "a.h"],
      probes = @[project / "src" / "b.h"])
    check record.declared.len == 1
    check record.declared[0].path == "project:src/a.c"
    check record.declared[0].role == irDeclared
    check record.observed.len == 2
    for input in record.observed:
      check input.role == irObserved
      check input.path != "project:src/a.c"
    # The role survives the codec and is part of the path set.
    let back = decodeMemo(encodeMemo(record))
    check back.declared == record.declared
    check back.observed == record.observed
    var roles: seq[InputRole] = @[]
    for entry in back.pathSet:
      if entry.path == "project:src/a.c":
        roles.add(entry.role)
    check roles == @[irDeclared]
    # The strong fingerprint binds the role: the same accesses with nothing
    # declared are a different record.
    let undeclared = runAction(project, @[],
      reads = @[project / "src" / "a.c", project / "src" / "a.h"],
      probes = @[project / "src" / "b.h"])
    check undeclared.declared.len == 0
    check undeclared.strongHex != record.strongHex
    # ...and under the SAME weak fingerprint: one input, identical but for its
    # role, is a different strong fingerprint. (Added by the independent
    # verification of chunk 2: the case above also differs in its weak
    # fingerprint, so it passed with the role left out of the strong one.)
    let asDeclared = @[PortableInput(kind: pikRead, path: "project:src/a.c",
      digest: "file:" & repeat('0', 64), role: irDeclared)]
    var asObserved = asDeclared
    asObserved[0].role = irObserved
    check portableStrongFingerprint(hex('d'), asDeclared) !=
      portableStrongFingerprint(hex('d'), asObserved)
    # A miss says which kind of input differed.
    let store = base / "store"
    recordMemo(store, record)
    writeFile(project / "src" / "a.c", "int b;\n")
    check lookupMemo(store, roots(project), record.weakHex).isNone
    let why = explainMemoMiss(store, roots(project), record.weakHex)
    checkpoint(why)
    check "declared input project:src/a.c" in why
    writeFile(project / "src" / "a.c", "int a;\n")
    writeFile(project / "src" / "a.h", "#define B\n")
    let why2 = explainMemoMiss(store, roots(project), record.weakHex)
    checkpoint(why2)
    check "observed input project:src/a.h" in why2
    writeFile(project / "src" / "a.h", "#define A\n")
    check lookupMemo(store, roots(project), record.weakHex).isSome

  test "executable bit: a consumer whose input has another executable bit misses":
    # Falsifier: an identity without the executable bit (`readIdentity`
    # returning `file:<hex>` for an executable file) turns this red.
    let base = createTempDir("m17-exec-", "")
    defer: removeDir(extendedPath(base))
    let project = base / "p"
    createDir(project / "tools")
    let tool = project / "tools" / "gen"
    writeFile(tool, "#!/bin/sh\necho gen\n")
    setExecutable(tool, false)
    check not executableBit(tool)
    let here = readIdentity(tool)
    check here.startsWith("file:")
    # The record a producer whose copy of the tool is executable made: the
    # same bytes, the bit set.
    var parts: IdentityParts
    check identityParts(pikRead, here, parts)
    parts.executable = true
    var producerIdentity = ""
    check identityFromParts(pikRead, parts, producerIdentity)
    check producerIdentity == "exec:" & parts.digest
    let weak = hex('e')
    let inputs = @[PortableInput(kind: pikRead, path: "project:tools/gen",
      digest: producerIdentity, role: irDeclared)]
    let record = newPortableMemoRecord(weak, inputs,
      portableStrongFingerprint(weak, inputs), newSeq[PortableOutput](),
      ffpChecksum, elComplete, MonitoredEvidence)
    let store = base / "store"
    recordMemo(store, record)
    check lookupMemo(store, roots(project), weak).isNone
    let why = explainMemoMiss(store, roots(project), weak)
    checkpoint(why)
    check "exec:" in why and "file:" in why
    # Control: the same record made from a non-executable copy hits.
    let plainInputs = @[PortableInput(kind: pikRead, path: "project:tools/gen",
      digest: here, role: irDeclared)]
    let plain = newPortableMemoRecord(hex('f'), plainInputs,
      portableStrongFingerprint(hex('f'), plainInputs),
      newSeq[PortableOutput](), ffpChecksum, elComplete, MonitoredEvidence)
    recordMemo(store, plain)
    check lookupMemo(store, roots(project), hex('f')).isSome
    when defined(posix):
      # On a host with the bit, flipping it on disk misses, and flipping it
      # back hits again.
      setExecutable(tool, true)
      check readIdentity(tool) == producerIdentity
      check lookupMemo(store, roots(project), weak).isSome
      check lookupMemo(store, roots(project), hex('f')).isNone
      setExecutable(tool, false)
      check lookupMemo(store, roots(project), hex('f')).isSome

  test "entry kind: a probed path that changes kind misses on the portable path":
    # Falsifier: identifying every present probe target as one value (the
    # rbpm-v1 "present") turns this red.
    let base = createTempDir("m17-kind-", "")
    defer: removeDir(extendedPath(base))
    let project = base / "p"
    createDir(project / "src")
    writeFile(project / "src" / "a.c", "int a;\n")
    createDir(project / "inc")
    let record = runAction(project, @[], reads = @[project / "src" / "a.c"],
      probes = @[project / "inc"])
    var probe = ""
    for input in record.observed:
      if input.kind == pikProbe:
        probe = input.digest
    check probe == "directory"
    let store = base / "store"
    recordMemo(store, record)
    check lookupMemo(store, roots(project), record.weakHex).isSome
    # A FILE now stands where the directory was.
    removeDir(project / "inc")
    writeFile(project / "inc", "")
    check probeIdentity(project / "inc") == "file"
    check lookupMemo(store, roots(project), record.weakHex).isNone
    # And a read that found a file misses when a directory stands there.
    let reads = runAction(project, @[], reads = @[project / "inc"], @[],
      tool = "reader")
    recordMemo(store, reads)
    removeFile(project / "inc")
    createDir(project / "inc")
    check lookupMemo(store, roots(project), reads.weakHex).isNone
    # An absent probe that becomes an EMPTY regular file is a change too.
    let absent = runAction(project, @[], reads = @[project / "src" / "a.c"],
      probes = @[project / "src" / "a.h"], tool = "prober")
    recordMemo(store, absent)
    check lookupMemo(store, roots(project), absent.weakHex).isSome
    writeFile(project / "src" / "a.h", "")
    check lookupMemo(store, roots(project), absent.weakHex).isNone

  test "v1: an rbpm-v1 record or rbps-v1 path set is refused, naming the format":
    let legacyMemo = encodeDeterministic(cArray([cText(LegacyMemoTag),
      cText(hex('a')), cArray([cArray([cUInt(0), cText("project:src/a.c")])]),
      cText(hex('b')), cArray([])]))
    try:
      discard decodeMemo(legacyMemo)
      check false
    except LegacyMemoFormatError as err:
      check LegacyMemoTag in err.msg
    let legacyPathSet = encodeDeterministic(cArray([cText(LegacyPathSetTag),
      cArray([cArray([cUInt(0), cText("project:src/a.c")])])]))
    expect LegacyMemoFormatError:
      discard decodePathSet(legacyPathSet)
    # A store that holds only a v1 path set and record misses.
    let base = createTempDir("m17-v1-", "")
    defer: removeDir(extendedPath(base))
    let project = base / "p"
    createDir(project / "src")
    writeFile(project / "src" / "a.c", "int a;\n")
    let store = base / "store"
    let weakDir = store / hex('a')
    createDir(extendedPath(weakDir / "ps"))
    writeFile(extendedPath(weakDir / "ps.pathset"), legacyPathSet)
    writeFile(extendedPath(weakDir / "ps" / (hex('b') & ".memo")), legacyMemo)
    check candidatePathSets(store, hex('a')).len == 0
    check lookupMemo(store, roots(project), hex('a')).isNone

  test "digest domain: a digest without the domain, or under another, does not verify":
    let base = createTempDir("m17-domain-", "")
    defer: removeDir(extendedPath(base))
    let project = base / "p"
    createDir(project / "src")
    let content = "int a;\n"
    writeFile(project / "src" / "a.c", content)
    let published = fileContentHex(project / "src" / "a.c")
    # The documented construction: BLAKE3-256 over the framed domain, the
    # framed purpose, then the bytes.
    proc frame(text: string): string = $text.len & ":" & text
    check published ==
      blake3.digest(frame(PublishedDigestDomain) & frame("content") &
        content).toHex()
    let undomained = blake3.digest(content).toHex()
    let otherDomain = blake3.digest(frame("reprobuild.some-other.v1") &
      frame("content") & content).toHex()
    let otherPurpose = publishedDigestHex(pdpMembership, content)
    check undomained != published
    check otherDomain != published
    check otherPurpose != published
    # A record whose input digest was computed without the domain (or under
    # another) does not verify against this host's files: a miss.
    let store = base / "store"
    for (label, digest) in [("undomained", undomained),
                            ("other domain", otherDomain),
                            ("other purpose", otherPurpose),
                            ("the domain", published)]:
      let weak = blake3.digest(label).toHex()
      let inputs = @[PortableInput(kind: pikRead, path: "project:src/a.c",
        digest: "file:" & digest, role: irDeclared)]
      recordMemo(store, newPortableMemoRecord(weak, inputs,
        portableStrongFingerprint(weak, inputs), newSeq[PortableOutput](),
        ffpChecksum, elComplete, MonitoredEvidence))
      checkpoint(label)
      check lookupMemo(store, roots(project), weak).isSome ==
        (label == "the domain")
    # Membership and environment digests are under the domain too.
    check membershipHexOfNames(["a", "b/"]) ==
      publishedDigestHex(pdpMembership, "a\nb/")
    check envIdentity(roots(project), true, "x") ==
      publishedDigestHex(pdpEnvironment, "x")

  test "evidence source: carried, and the publication rule refuses an unstated one":
    var record = everyFieldRecord()
    for source in [MonitoredEvidence, BuiltinEvidence,
                   formatEvidence("make-depfile"),
                   convertedEvidence("repro-path-set")]:
      record.evidenceSource = source
      check decodeMemo(encodeMemo(record)).evidenceSource == source
    record.evidenceSource = UnstatedEvidence
    check decodeMemo(encodeMemo(record)).evidenceSource == UnstatedEvidence
    let refusal = portableRecordRefusal(record)
    check "evidence source" in refusal
    # The rest of the rule, over what the record states.
    record.evidenceSource = MonitoredEvidence
    record.policy = ffpTimestamp
    check "ffpTimestamp" in portableRecordRefusal(record)
    record.policy = ffpChecksum
    record.evidenceLevel = elKnownScopeLoss
    check "Level 1" in portableRecordRefusal(record)
    record.evidenceLevel = elComplete
    check "no content hash" in portableRecordRefusal(
      record.withIdentity("project:dev/fifo", ReadOfUnreadable))
    # Zero inputs: refused unless the action is fixed-output.
    var empty = newPortableMemoRecord(hex('c'), newSeq[PortableInput](),
      portableStrongFingerprint(hex('c'), @[]), newSeq[PortableOutput](),
      ffpChecksum, elComplete, MonitoredEvidence)
    check "names no observed input" in portableRecordRefusal(empty)
    empty.fixedOutput = true
    check portableRecordRefusal(empty) == ""
    # Owner decision 2026-10-29 ("builtins yes, depfiles no"): a monitored
    # or builtin record publishes; a record evidenced by a dependency report
    # does not, whichever format or converter reported it, except a format
    # EDI assigns to an edge kind (`nix-pure-flake`). Falsifiers: letting
    # `nonMonitoredSourceRefusal` pass a `format:` source publishes the
    # depfile record; refusing every non-monitored source refuses the
    # builtin.
    for source in [MonitoredEvidence, BuiltinEvidence,
                   formatEvidence("nix-pure-flake")]:
      record.evidenceSource = source
      checkpoint($source)
      check portableRecordRefusal(record) == ""
    for source in [formatEvidence("make-depfile"),
                   formatEvidence("msvc-includes"),
                   formatEvidence("iomon"),
                   formatEvidence("make-depfile+nix-pure-flake"),
                   convertedEvidence("repro-path-set"),
                   convertedEvidence("nix-pure-flake")]:
      record.evidenceSource = source
      checkpoint($source)
      let refused = portableRecordRefusal(record)
      check refused.len > 0
      check source.format in refused
    record.evidenceSource = MonitoredEvidence
    # The text form parses back and rejects what no writer produces.
    var parsed: EvidenceSource
    check parseEvidenceSource("format:make-depfile", parsed)
    check parsed == formatEvidence("make-depfile")
    check not parseEvidenceSource("format:", parsed)
    check not parseEvidenceSource("monitored:x", parsed)
    check not parseEvidenceSource("guessed", parsed)

  test "tamper: every new field is in the signed bytes; altered identities are inconsistent":
    let record = everyFieldRecord()
    let original = encodeMemo(record)
    # Each new field, altered or stripped, changes the encoded bytes, which
    # are what the binary-cache manifest signs (`portable_memo_cache`), so a
    # changed field cannot keep the producer's signature.
    var variants: seq[(string, PortableMemoRecord)] = @[]
    var r = record
    r.policy = ffpChecksum
    variants.add(("policy", r))
    r = record
    r.evidenceLevel = elKnownScopeLoss
    variants.add(("evidence level", r))
    r = record
    r.evidenceSource = MonitoredEvidence
    variants.add(("evidence source", r))
    r = record
    r.evidenceSource = UnstatedEvidence
    variants.add(("evidence source stripped", r))
    r = record
    r.fixedOutput = false
    variants.add(("fixed-output flag", r))
    r = record
    r.outputs[0].executable = false
    variants.add(("output executable bit", r))
    r = record
    r.outputs[1].entries[1].executable = false
    variants.add(("tree entry executable bit", r))
    for (label, altered) in variants:
      checkpoint(label)
      check encodeMemo(altered) != original
    # An input's identity, role or kind altered without recomputing the strong
    # fingerprint leaves the record inconsistent, and a lookup refuses it.
    var identityVariants: seq[(string, PortableMemoRecord)] = @[]
    identityVariants.add(("executable bit",          # bit stripped
      record.withIdentity("project:tools/run", "file:" & hex('2'))))
    identityVariants.add(("entry kind",              # absent probe -> file
      record.withIdentity("project:inc/a.h", "file")))
    r = record
    let moved = r.declared[0]
    r.declared.delete(0)
    var observedNow = moved
    observedNow.role = irObserved
    r.observed.add(observedNow)                      # declared -> observed
    identityVariants.add(("role", r))
    identityVariants.add(("digest",
      record.withIdentity("project:src/a.c", "file:" & hex('9'))))
    for (label, altered) in identityVariants:
      checkpoint(label)
      check recordConsistencyReason(altered) != ""
      check encodeMemo(altered) != original
    # Such a record is never returned by a lookup, even under the key it
    # claims.
    let base = createTempDir("m17-tamper-", "")
    defer: removeDir(extendedPath(base))
    let project = base / "p"
    createDir(project / "src")
    writeFile(project / "src" / "a.c", "int a;\n")
    let honest = runAction(project, @[project / "src" / "a.c"],
      reads = @[project / "src" / "a.c"], @[])
    var forged = honest
    forged.declared[0].digest = "exec:" &
      forged.declared[0].digest["file:".len .. ^1]
    let store = base / "store"
    recordMemo(store, forged)
    check lookupMemo(store, roots(project), honest.weakHex).isNone
    recordMemo(store, honest)
    check lookupMemo(store, roots(project), honest.weakHex).isSome

## Portable memoization store — Cache-Scope Phase 3, P3.3; the published-trace
## record of Edge-Derived-Identities.md §3.1 (campaign M17 chunk 2, `rbpm-v2`).
##
## BuildXL's memoization model over the PORTABLE identities of
## `portable_fingerprint` (Caching-Architecture.md, "Selectors And Candidate
## Path Sets"):
##
##   portable weak fingerprint
##     -> candidate path sets        (which logical paths the action accessed)
##     -> portable strong fingerprint (weak + those paths' CURRENT identities)
##     -> memo record                 (the action's outputs, by content)
##
## A weak fingerprint may have several path sets — different executions of
## one action can observe different inputs — so lookup walks each candidate,
## recomputes the strong fingerprint from what is true NOW, and returns the
## record whose strong fingerprint matches. Nothing is executed.
##
## Recomputing takes each input's identity from wherever it is known: the
## file on disk, or — the point of P3.4 — the output digests an upstream
## action's memo record promises, so a downstream lookup needs no upstream
## bytes on disk (`resolve` below).
##
## ## The record, `rbpm-v2`
##
## The published trace of §3.1 is THIS record carried to a new version, not a
## second format (EDI §3.3 rider of 2026-10-27, §10 decision 13). It holds:
##
## * the portable weak fingerprint;
## * the DECLARED inputs and, kept apart from them, the OBSERVED inputs (reads,
##   absent and present probes, directory enumerations, environment reads),
##   each with its logical path, its entry kind, its executable bit and its
##   digest — content, membership or value, every one BLAKE3-256 under
##   `PortableFingerprint.PublishedDigestDomain`;
## * the input-check policy the local record was made under, the
##   monitor-evidence level and the evidence source of the execution
##   (monitored, a recognized format by name, a builtin), and whether the
##   action is fixed-output;
## * the portable strong fingerprint, over every input's role and identity;
## * the outputs: logical path, kind (file or tree), executable bit and
##   published content digest, a tree with its manifest.
##
## Its path set is `rbps-v2`: each entry is (role, access, logical path).
##
## `rbpm-v1` / `rbps-v1` are NOT read. Decoding one raises
## `LegacyMemoFormatError`, which a lookup reports as a miss naming the
## format; the strong fingerprint domain moved with it (`strong.v2`), so no v1
## record is ever looked up again. That is the one-time re-key EDI §3.3's
## rider describes: nothing relies on v1 records by default.
##
## Layout, under a store root (the local half; the remote half ships these same
## encoded bytes as binary-cache entries):
##
##   <root>/<weak>/<pathSetHash>.pathset
##   <root>/<weak>/<pathSetHash>/<strong>.memo
##
## Encoding follows the spec's policy for persistent metadata: deterministic
## CBOR, version-tagged.

import std/[algorithm, options, os, strutils, tables]

import blake3
import cbor

import repro_core/evidence_level
import repro_core/evidence_source
import repro_core/input_check_policy
import repro_core/paths

import ./portable_fingerprint
import ./publication_rule

export evidence_level, evidence_source, input_check_policy

type
  PathSetEntry* = object
    kind*: PortableInputKind
    path*: string  ## `<label>:<rel>`.
    role*: InputRole

  PathSet* = seq[PathSetEntry]

  PortableMemoRecord* = object
    ## `rbpm-v2`: see the module doc.
    weakHex*: string
    policy*: FileFingerprintPolicy
      ## The input-check policy of the local record this one projects.
    evidenceLevel*: EvidenceLevel
    evidenceSource*: EvidenceSource
    fixedOutput*: bool
      ## The action's outputs are fixed by content hashes its description
      ## declares and verifies, so an EMPTY input set is complete for it
      ## (the observation count of the publication rule exempts it).
    declared*: seq[PortableInput]
      ## Inputs at paths the action declared, every one `irDeclared`.
    observed*: seq[PortableInput]
      ## Every other input, every one `irObserved`.
    strongHex*: string
    outputs*: seq[PortableOutput]

  IdentityResolver* = proc (entry: PathSetEntry): Option[string] {.closure.}
    ## Supplies an input's CURRENT identity without the filesystem — e.g.
    ## from an upstream memo record's output digests. `none` falls back to
    ## the file on disk.

  MemoCodecError* = object of CatchableError
  LegacyMemoFormatError* = object of MemoCodecError
    ## An `rbpm-v1` record or `rbps-v1` path set: well formed for its writer,
    ## never read by this build (see the module doc). A miss, not a forgery.

const
  PathSetTag* = "rbps-v2"
  MemoTag* = "rbpm-v2"
  LegacyPathSetTag* = "rbps-v1"
  LegacyMemoTag* = "rbpm-v1"

proc legacyRefusal(tag: string): string =
  "an " & tag & " record (written before the published-trace record " &
    "rbpm-v2 of Edge-Derived-Identities.md §3.1): it states no declared/" &
    "observed split, entry kind, executable bit, evidence source or " &
    "input-check policy, and its digests carry no published-digest domain, " &
    "so it is not used across hosts"

# --- record helpers ----------------------------------------------------------

proc inputs*(record: PortableMemoRecord): seq[PortableInput] =
  ## Every input, declared first.
  record.declared & record.observed

proc newPortableMemoRecord*(weakHex: string; inputs: openArray[PortableInput];
                            strongHex: string;
                            outputs: openArray[PortableOutput];
                            policy: FileFingerprintPolicy;
                            evidenceLevel: EvidenceLevel;
                            evidenceSource: EvidenceSource;
                            fixedOutput = false): PortableMemoRecord =
  ## A record over `inputs`, split by role, every list in the canonical order
  ## the codec writes (so a decoded record equals the one encoded).
  result = PortableMemoRecord(weakHex: weakHex, strongHex: strongHex,
    outputs: @outputs, policy: policy, evidenceLevel: evidenceLevel,
    evidenceSource: evidenceSource, fixedOutput: fixedOutput)
  for input in inputs:
    if input.role == irDeclared: result.declared.add(input)
    else: result.observed.add(input)
  let byAccessThenPath = proc (a, b: PortableInput): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.path, b.path)
  result.declared.sort(byAccessThenPath)
  result.observed.sort(byAccessThenPath)
  result.outputs.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))

proc canonical(pathSet: PathSet): PathSet =
  result = pathSet
  result.sort(proc (a, b: PathSetEntry): int =
    result = cmp(ord(a.role), ord(b.role))
    if result == 0:
      result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.path, b.path))

proc pathSetOf*(inputs: openArray[PortableInput]): PathSet =
  ## The path set of an execution: its inputs WITHOUT their identities,
  ## canonically ordered.
  for input in inputs:
    result.add(PathSetEntry(kind: input.kind, path: input.path,
      role: input.role))
  result = canonical(result)

proc pathSet*(record: PortableMemoRecord): PathSet =
  pathSetOf(record.inputs)

proc encodePathSet*(pathSet: PathSet): seq[byte] =
  var elems: seq[CborItem] = @[]
  for entry in canonical(pathSet):
    elems.add(cArray([cUInt(uint64(ord(entry.role))),
      cUInt(uint64(ord(entry.kind))), cText(entry.path)]))
  encodeDeterministic(cArray([cText(PathSetTag), cArray(elems)]))

proc pathSetHash*(pathSet: PathSet): string =
  let bytes = encodePathSet(pathSet)
  blake3.digest(bytes).toHex()

proc expect(cond: bool; what: string) =
  if not cond:
    raise newException(MemoCodecError, "malformed portable memo: " & what)

proc decodePathSet*(bytes: openArray[byte]): PathSet =
  let root = decodeItem(bytes)
  expect(root.kind == ckArray and root.elems.len >= 1, "path-set envelope")
  expect(root.elems[0].kind == ckText, "path-set tag")
  if root.elems[0].text == LegacyPathSetTag:
    raise newException(LegacyMemoFormatError, legacyRefusal(LegacyPathSetTag))
  expect(root.elems[0].text == PathSetTag and root.elems.len == 2,
    "path-set tag")
  let entries = root.elems[1]
  expect(entries.kind == ckArray, "path set is not an array")
  for elem in entries.elems:
    expect(elem.kind == ckArray and elem.elems.len == 3, "path-set entry")
    let r = elem.elems[0]
    let k = elem.elems[1]
    let p = elem.elems[2]
    expect(r.kind == ckUInt and r.arg <= uint64(ord(high(InputRole))),
      "path-set entry role")
    expect(k.kind == ckUInt and k.arg <= uint64(ord(high(PortableInputKind))),
      "path-set entry kind")
    expect(p.kind == ckText, "path-set entry path")
    result.add(PathSetEntry(role: InputRole(r.arg),
      kind: PortableInputKind(k.arg), path: p.text))
  expect(result == canonical(result), "path set is not canonical")

proc encodeInputs(inputs: openArray[PortableInput]): CborItem =
  var sorted = @inputs
  sorted.sort(proc (a, b: PortableInput): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.path, b.path))
  var items: seq[CborItem] = @[]
  for input in sorted:
    var parts: IdentityParts
    if not identityParts(input.kind, input.digest, parts):
      raise newException(MemoCodecError, "cannot encode the identity '" &
        input.digest & "' of " & $input.kind & " " & input.path)
    items.add(cArray([cUInt(uint64(ord(input.kind))), cText(input.path),
      cUInt(uint64(ord(parts.entryKind))),
      cUInt(if parts.executable: 1'u64 else: 0'u64), cText(parts.digest)]))
  cArray(items)

proc decodeInputs(item: CborItem; role: InputRole): seq[PortableInput] =
  expect(item.kind == ckArray, $role & " inputs")
  for elem in item.elems:
    expect(elem.kind == ckArray and elem.elems.len == 5, $role & " input")
    let k = elem.elems[0]
    let p = elem.elems[1]
    let e = elem.elems[2]
    let x = elem.elems[3]
    let d = elem.elems[4]
    expect(k.kind == ckUInt and k.arg <= uint64(ord(high(PortableInputKind))),
      $role & " input access")
    expect(p.kind == ckText, $role & " input path")
    expect(e.kind == ckUInt and e.arg <= uint64(ord(high(InputEntryKind))),
      $role & " input entry kind")
    expect(x.kind == ckUInt and x.arg <= 1, $role & " input executable bit")
    expect(d.kind == ckText, $role & " input digest")
    let access = PortableInputKind(k.arg)
    var identity = ""
    expect(identityFromParts(access, IdentityParts(
      entryKind: InputEntryKind(e.arg), executable: x.arg == 1,
      digest: d.text), identity), $role & " input identity of " & p.text)
    result.add(PortableInput(kind: access, path: p.text, digest: identity,
      role: role))

proc encodeOutputs(outputs: openArray[PortableOutput]): CborItem =
  var sorted = @outputs
  sorted.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))
  var outItems: seq[CborItem] = @[]
  for output in sorted:
    var entryItems: seq[CborItem] = @[]
    for entry in output.entries:
      entryItems.add(cArray([cText(entry.rel), cUInt(uint64(ord(entry.kind))),
        cText(entry.identity),
        cUInt(if entry.executable: 1'u64 else: 0'u64)]))
    outItems.add(cArray([cText(output.path), cText(output.digest),
      cUInt(if output.directory: 1'u64 else: 0'u64),
      cUInt(if output.executable: 1'u64 else: 0'u64), cArray(entryItems)]))
  cArray(outItems)

proc decodeOutputs(outs: CborItem): seq[PortableOutput] =
  expect(outs.kind == ckArray, "memo outputs")
  for elem in outs.elems:
    expect(elem.kind == ckArray and elem.elems.len == 5 and
      elem.elems[0].kind == ckText and elem.elems[1].kind == ckText and
      elem.elems[2].kind == ckUInt and elem.elems[2].arg <= 1 and
      elem.elems[3].kind == ckUInt and elem.elems[3].arg <= 1, "memo output")
    var output = PortableOutput(path: elem.elems[0].text,
      digest: elem.elems[1].text, directory: elem.elems[2].arg == 1,
      executable: elem.elems[3].arg == 1)
    expect(not (output.directory and output.executable),
      "memo output: an executable directory")
    let entries = elem.elems[4]
    expect(entries.kind == ckArray, "memo output entries")
    for item in entries.elems:
      expect(item.kind == ckArray and item.elems.len == 4 and
        item.elems[0].kind == ckText and item.elems[1].kind == ckUInt and
        item.elems[1].arg <= uint64(ord(high(TreeEntryKind))) and
        item.elems[2].kind == ckText and item.elems[3].kind == ckUInt and
        item.elems[3].arg <= 1, "memo output entry")
      let entry = TreeEntry(rel: item.elems[0].text,
        kind: TreeEntryKind(item.elems[1].arg),
        identity: item.elems[2].text, executable: item.elems[3].arg == 1)
      expect(not entry.executable or entry.kind == tekFile,
        "memo output entry: executable bit on a non-file")
      output.entries.add(entry)
    result.add(output)

proc encodeMemo*(record: PortableMemoRecord): seq[byte] =
  ## `["rbpm-v2", weak, policy, evidenceLevel, evidenceSource, fixedOutput,
  ##   declared[], observed[], strong, outputs[]]`; an input is
  ## `[access, logicalPath, entryKind, executable, digest]`, an output
  ## `[logicalPath, digest, directory, executable, entries[]]`, a tree entry
  ## `[rel, kind, identity, executable]`. Every list is canonically ordered.
  for input in record.declared:
    if input.role != irDeclared:
      raise newException(MemoCodecError,
        "a declared input carries the role " & $input.role)
  for input in record.observed:
    if input.role != irObserved:
      raise newException(MemoCodecError,
        "an observed input carries the role " & $input.role)
  encodeDeterministic(cArray([cText(MemoTag), cText(record.weakHex),
    cText($record.policy),
    cUInt(uint64(evidenceLevelByte(record.evidenceLevel))),
    cText($record.evidenceSource),
    cUInt(if record.fixedOutput: 1'u64 else: 0'u64),
    encodeInputs(record.declared), encodeInputs(record.observed),
    cText(record.strongHex), encodeOutputs(record.outputs)]))

proc decodeMemo*(bytes: openArray[byte]): PortableMemoRecord =
  ## Raises `LegacyMemoFormatError` for an `rbpm-v1` record and
  ## `MemoCodecError` for anything else that is not a well-formed `rbpm-v2`
  ## record.
  let root = decodeItem(bytes)
  expect(root.kind == ckArray and root.elems.len >= 1, "memo envelope")
  expect(root.elems[0].kind == ckText, "memo tag")
  if root.elems[0].text == LegacyMemoTag:
    raise newException(LegacyMemoFormatError, legacyRefusal(LegacyMemoTag))
  expect(root.elems[0].text == MemoTag and root.elems.len == 10,
    "memo tag")
  let e = root.elems
  expect(e[1].kind == ckText, "memo weak fingerprint")
  expect(e[2].kind == ckText, "memo input-check policy")
  expect(e[3].kind == ckUInt and e[3].arg <= 255, "memo evidence level")
  expect(e[4].kind == ckText, "memo evidence source")
  expect(e[5].kind == ckUInt and e[5].arg <= 1, "memo fixed-output flag")
  expect(e[8].kind == ckText, "memo strong fingerprint")
  result.weakHex = e[1].text
  var policyKnown = false
  for policy in FileFingerprintPolicy:
    if $policy == e[2].text:
      result.policy = policy
      policyKnown = true
  expect(policyKnown, "memo input-check policy '" & e[2].text & "'")
  expect(evidenceLevelFromByte(uint8(e[3].arg), result.evidenceLevel),
    "memo evidence level")
  expect(parseEvidenceSource(e[4].text, result.evidenceSource),
    "memo evidence source '" & e[4].text & "'")
  result.fixedOutput = e[5].arg == 1
  result.declared = decodeInputs(e[6], irDeclared)
  result.observed = decodeInputs(e[7], irObserved)
  result.strongHex = e[8].text
  result.outputs = decodeOutputs(e[9])

# --- the publication rule, over an rbpm-v2 record ----------------------------

proc portableRecordRefusal*(record: PortableMemoRecord): string =
  ## Why `record` may not cross hosts, or "" when it may: THE publication
  ## rule (`publication_rule.publicationRuleRefusal`), over the facts the
  ## record states. The portable publisher asks it of the record it is about
  ## to publish (together with the local record's own content hashes), and a
  ## consumer asks it of every record another host published -- whatever that
  ## producer's version or conformance -- before using it.
  var unhashed = ""
  for input in record.inputs:
    if input.kind == pikRead and input.digest == ReadOfUnreadable:
      unhashed = input.path
      break
  let count = record.declared.len + record.observed.len
  publicationRuleRefusal(record.policy, unhashed, record.evidenceLevel,
    record.evidenceSource,
    (if record.fixedOutput: max(count, 1) else: count))

proc recordConsistencyReason*(record: PortableMemoRecord): string =
  ## "" when the record is self-consistent: its strong fingerprint is the one
  ## its own inputs compute. A record whose stated identities do not produce
  ## its key was altered after it was made (or never made by this format's
  ## writer), and is not trusted.
  if portableStrongFingerprint(record.weakHex, record.inputs) !=
      record.strongHex:
    return "the record's inputs do not compute its strong fingerprint"
  ""

# --- identity resolution ----------------------------------------------------

proc toPhysicalPath*(roots: openArray[LogicalRoot]; logical: string):
    Option[string] =
  ## Inverse of `toLogicalPath` for a `<label>:<rel>` path on THIS host.
  let colon = logical.find(':')
  if colon <= 0:
    return none(string)
  let label = logical[0 ..< colon]
  let rel = logical[colon + 1 .. ^1]
  for root in roots:
    if root.label == label and root.kind == lrkTracked:
      return some(if rel.len == 0: root.path else: root.path / rel)
  none(string)

proc currentIdentity*(roots: openArray[LogicalRoot]; entry: PathSetEntry;
                      resolve: IdentityResolver = nil): Option[string] =
  ## An input's identity as it stands now: from `resolve` when it knows (an
  ## upstream record), else from the filesystem. `none` when the input cannot
  ## be located on this host at all. The role does not change how an input is
  ## identified, only where the record lists it.
  if resolve != nil:
    let known = resolve(entry)
    if known.isSome:
      return known
  if entry.kind == pikEnvironment:
    # Only the caller knows the environment the action would launch with;
    # the looking-up process's own environment is not it.
    return none(string)
  if entry.path.startsWith(AncestorPrefix):
    # A probe above the root, evaluated over the whole ancestry exactly as
    # it was when recorded (`ancestorProbeIdentity`).
    if entry.kind != pikProbe:
      return none(string)
    let identity = ancestorProbeIdentity(roots, entry.path)
    return if identity.len > 0: some(identity) else: none(string)
  let physical = toPhysicalPath(roots, entry.path)
  if physical.isNone:
    return none(string)
  let p = physical.get()
  case entry.kind
  # Existence is asked in the extended-length form: a path past MAX_PATH
  # otherwise reads as absent, so the same file was "present" under a short
  # checkout path and "absent" under a longer one.
  of pikRead:
    some(readIdentity(p))
  of pikProbe:
    some(probeIdentity(p))
  of pikEnumeration:
    if not dirExists(extendedPath(p)):
      return none(string)
    some(membershipHex(p))
  of pikEnvironment:
    none(string)   # answered above, and only ever by the caller's resolver

proc manifestsConsistent*(record: PortableMemoRecord): bool =
  ## A directory output's manifest must be the tree its digest names: the
  ## manifest is what resolves downstream reads inside the directory, so a
  ## record whose listing disagrees with its digest is not trusted.
  for output in record.outputs:
    if output.directory and output.entries.len > 0 and
        treeDigestOf(output.entries) != output.digest:
      return false
  true

proc outputsOnDiskReason*(roots: openArray[LogicalRoot];
                          record: PortableMemoRecord): string =
  ## "" when every output the record names is on THIS host with the content
  ## (and, for a file, the executable bit) the record names; otherwise why
  ## not.
  for output in record.outputs:
    let physical = toPhysicalPath(roots, output.path)
    if physical.isNone:
      return "output " & output.path & " has no location on this host"
    let p = physical.get()
    let actual =
      if output.directory:
        if dirExists(extendedPath(p)): treeContentHex(p) else: ""
      else:
        if fileExists(extendedPath(p)): fileContentHex(p) else: ""
    if actual.len == 0:
      return "output " & output.path & " is missing"
    if actual != output.digest:
      return "output " & output.path & " does not have the content the " &
        "record names"
    if not output.directory and executableBit(p) != output.executable:
      return "output " & output.path & " does not have the executable bit " &
        "the record names"
  ""

proc strongForPathSet*(roots: openArray[LogicalRoot]; weakHex: string;
                       pathSet: PathSet; resolve: IdentityResolver = nil):
    Option[string] =
  ## The strong fingerprint this path set WOULD have now — the BuildXL
  ## selector step. `none` if any input cannot be identified.
  var inputs: seq[PortableInput] = @[]
  for entry in pathSet:
    let identity = currentIdentity(roots, entry, resolve)
    if identity.isNone:
      return none(string)
    inputs.add(PortableInput(kind: entry.kind, path: entry.path,
      digest: identity.get(), role: entry.role))
  some(portableStrongFingerprint(weakHex, inputs))

proc differingInput*(roots: openArray[LogicalRoot];
                     record: PortableMemoRecord;
                     resolve: IdentityResolver = nil): string =
  ## Why `record` does not verify on THIS host, naming the first input whose
  ## identity here differs from the one the record states, and whether it is
  ## a DECLARED or an OBSERVED input (Edge-Derived-Identities.md §3.1:
  ## "a consumer that misses must be able to say whether a declared or an
  ## observed input differed"). "" when every input agrees.
  for input in record.inputs:
    let entry = PathSetEntry(kind: input.kind, path: input.path,
      role: input.role)
    let here = currentIdentity(roots, entry, resolve)
    if here.isNone:
      return $input.role & " input " & input.path & " (" & $input.kind &
        ") cannot be identified on this host"
    if here.get() != input.digest:
      return $input.role & " input " & input.path & " (" & $input.kind &
        ") differs: the record states '" & input.digest & "', this host " &
        "has '" & here.get() & "'"
  ""

# --- local store -------------------------------------------------------------

proc atomicWrite(path: string; bytes: openArray[byte]) =
  ## Every store path goes through `extendedPath`: root + three 64-hex
  ## components + a temp suffix exceeds Windows' 260-character MAX_PATH.
  createDir(extendedPath(parentDir(path)))
  let temp = path & ".tmp-" & $getCurrentProcessId()
  writeFile(extendedPath(temp), bytes)
  moveFile(extendedPath(temp), extendedPath(path))

proc recordMemo*(storeRoot: string; record: PortableMemoRecord) =
  ## Persist a record and its path set. Idempotent; each file is written
  ## through a temporary name so a reader never sees a torn record.
  let weakDir = storeRoot / record.weakHex
  let psHash = pathSetHash(record.pathSet)
  let psFile = weakDir / (psHash & ".pathset")
  if not fileExists(extendedPath(psFile)):
    atomicWrite(psFile, encodePathSet(record.pathSet))
  atomicWrite(weakDir / psHash / (record.strongHex & ".memo"),
    encodeMemo(record))

proc publishedMarker(storeRoot: string; record: PortableMemoRecord): string =
  storeRoot / record.weakHex / pathSetHash(record.pathSet) /
    (record.strongHex & ".published")

proc memoContentHex(record: PortableMemoRecord): string =
  blake3.digest(encodeMemo(record)).toHex()

proc memoPublished*(storeRoot: string; record: PortableMemoRecord;
                    withOutputs: bool): bool =
  ## Whether this host already published `record` — THIS content of it, with
  ## its output bytes when `withOutputs`. A warm build re-derives the same
  ## records, and each need go out only once.
  ##
  ## The marker names the content it was written for. Records are named by
  ## their keys, and one key can come to describe different outputs: a
  ## fetch whose tree a later action used to mutate was recorded with the
  ## mutated tree, and the record re-derived once that stopped is a CORRECTION
  ## under the same name. A marker that only said "published" kept the stale
  ## one on the remote for good. (A marker from before the content was named
  ## reads as unpublished, which costs one re-publish.)
  let marker = publishedMarker(storeRoot, record)
  if not fileExists(extendedPath(marker)):
    return false
  let held = readFile(extendedPath(marker)).split(' ')
  if held.len != 2 or held[1] != memoContentHex(record):
    return false
  not withOutputs or held[0] == "outputs"

proc markMemoPublished*(storeRoot: string; record: PortableMemoRecord;
                        withOutputs: bool) =
  let text = (if withOutputs: "outputs" else: "record") & " " &
    memoContentHex(record)
  atomicWrite(publishedMarker(storeRoot, record),
    text.toOpenArrayByte(0, text.high))

proc candidatePathSets*(storeRoot, weakHex: string): seq[PathSet] =
  ## Every `rbps-v2` path set stored for `weakHex`. A corrupt candidate, and a
  ## legacy `rbps-v1` one, is skipped, never trusted.
  let weakDir = storeRoot / weakHex
  if not dirExists(extendedPath(weakDir)):
    return
  var files: seq[string] = @[]
  for kind, path in walkDir(extendedPath(weakDir)):
    if kind == pcFile and path.endsWith(".pathset"):
      files.add(path)
  files.sort()
  for path in files:
    try:
      let raw = readFile(extendedPath(path))
      result.add(decodePathSet(raw.toOpenArrayByte(0, raw.high)))
    except CatchableError:
      discard  # a corrupt candidate is skipped, never trusted

proc readStoredMemo(path: string): Option[PortableMemoRecord] =
  try:
    let raw = readFile(extendedPath(path))
    some(decodeMemo(raw.toOpenArrayByte(0, raw.high)))
  except CatchableError:
    none(PortableMemoRecord)

proc lookupMemo*(storeRoot: string; roots: openArray[LogicalRoot];
                 weakHex: string; resolve: IdentityResolver = nil):
    Option[PortableMemoRecord] =
  ## BuildXL's two-phase lookup: for each candidate path set of `weakHex`,
  ## compute its strong fingerprint from what is true now and return the
  ## matching record, if one was stored. Executes nothing.
  for pathSet in candidatePathSets(storeRoot, weakHex):
    let strong = strongForPathSet(roots, weakHex, pathSet, resolve)
    if strong.isNone:
      continue
    let memo = storeRoot / weakHex / pathSetHash(pathSet) /
      (strong.get() & ".memo")
    if fileExists(extendedPath(memo)):
      let record = readStoredMemo(memo)
      if record.isSome and record.get().weakHex == weakHex and
          record.get().strongHex == strong.get() and
          record.get().pathSet == pathSet and
          recordConsistencyReason(record.get()).len == 0 and
          manifestsConsistent(record.get()):
        return record
  none(PortableMemoRecord)

proc explainMemoMiss*(storeRoot: string; roots: openArray[LogicalRoot];
                      weakHex: string; resolve: IdentityResolver = nil):
    string =
  ## After `lookupMemo` missed: which input of which stored record differs
  ## here (`differingInput`), declared or observed. "" when nothing is stored
  ## for `weakHex`.
  var reasons: seq[string] = @[]
  for pathSet in candidatePathSets(storeRoot, weakHex):
    let dir = storeRoot / weakHex / pathSetHash(pathSet)
    if not dirExists(extendedPath(dir)):
      continue
    for kind, path in walkDir(extendedPath(dir)):
      if kind != pcFile or not path.endsWith(".memo"):
        continue
      let record = readStoredMemo(path)
      if record.isNone:
        continue
      let why = differingInput(roots, record.get(), resolve)
      if why.len > 0:
        reasons.add(why)
      break   # one record per path set says which of its inputs moved
  reasons.join("; ")

proc outputResolver*(records: openArray[PortableMemoRecord]):
    IdentityResolver =
  ## Resolve reads of paths that upstream records PRODUCED from those
  ## records' outputs — the lookup-without-materialization step.
  var produced = initTable[string, string]()
  for record in records:
    for output in record.outputs:
      produced[output.path] = readIdentityOf(output)
  result = proc (entry: PathSetEntry): Option[string] =
    if entry.kind == pikRead and entry.path in produced:
      some(produced[entry.path])
    else:
      none(string)

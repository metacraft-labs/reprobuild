## Portable memoization store — Cache-Scope Phase 3, P3.3.
##
## BuildXL's memoization model over the PORTABLE identities of
## `portable_fingerprint` (Caching-Architecture.md, "Selectors And Candidate
## Path Sets"):
##
##   portable weak fingerprint
##     -> candidate path sets        (which logical paths the action observed)
##     -> portable strong fingerprint (weak + those paths' CURRENT identities)
##     -> memo record                 (the action's outputs, by content)
##
## A weak fingerprint may have several path sets — different executions of
## one action can observe different inputs — so lookup walks each candidate,
## recomputes the strong fingerprint from what is true NOW, and returns the
## record whose strong fingerprint matches. Nothing is executed.
##
## Recomputing takes each observed input's identity from wherever it is known:
## the file on disk, or — the point of P3.4 — the output digests an upstream
## action's memo record promises, so a downstream lookup needs no upstream
## bytes on disk (`resolve` below).
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

import repro_core/paths

import ./portable_fingerprint

type
  PathSetEntry* = object
    kind*: PortableInputKind
    path*: string  ## `<label>:<rel>`.

  PathSet* = seq[PathSetEntry]

  PortableMemoRecord* = object
    weakHex*: string
    pathSet*: PathSet
    strongHex*: string
    outputs*: seq[PortableOutput]

  IdentityResolver* = proc (entry: PathSetEntry): Option[string] {.closure.}
    ## Supplies an input's CURRENT identity without the filesystem — e.g.
    ## from an upstream memo record's output digests. `none` falls back to
    ## the file on disk.

  MemoCodecError* = object of CatchableError

const
  PathSetTag = "rbps-v1"
  MemoTag = "rbpm-v1"

proc canonical(pathSet: PathSet): PathSet =
  result = pathSet
  result.sort(proc (a, b: PathSetEntry): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.path, b.path))

proc pathSetOf*(inputs: openArray[PortableInput]): PathSet =
  ## The path set of an execution: its observed inputs WITHOUT their
  ## identities, canonically ordered.
  for input in inputs:
    result.add(PathSetEntry(kind: input.kind, path: input.path))
  result = canonical(result)

proc encodePathSet*(pathSet: PathSet): seq[byte] =
  var elems: seq[CborItem] = @[]
  for entry in canonical(pathSet):
    elems.add(cArray([cUInt(uint64(ord(entry.kind))), cText(entry.path)]))
  encodeDeterministic(cArray([cText(PathSetTag), cArray(elems)]))

proc pathSetHash*(pathSet: PathSet): string =
  let bytes = encodePathSet(pathSet)
  blake3.digest(bytes).toHex()

proc expect(cond: bool; what: string) =
  if not cond:
    raise newException(MemoCodecError, "malformed portable memo: " & what)

proc decodeEntries(item: CborItem): PathSet =
  expect(item.kind == ckArray, "path set is not an array")
  for elem in item.elems:
    expect(elem.kind == ckArray and elem.elems.len == 2, "path-set entry")
    let k = elem.elems[0]
    let p = elem.elems[1]
    expect(k.kind == ckUInt and k.arg <= uint64(ord(high(PortableInputKind))),
      "path-set entry kind")
    expect(p.kind == ckText, "path-set entry path")
    result.add(PathSetEntry(kind: PortableInputKind(k.arg), path: p.text))

proc decodePathSet*(bytes: openArray[byte]): PathSet =
  let root = decodeItem(bytes)
  expect(root.kind == ckArray and root.elems.len == 2, "path-set envelope")
  expect(root.elems[0].kind == ckText and root.elems[0].text == PathSetTag,
    "path-set tag")
  decodeEntries(root.elems[1])

proc encodeMemo*(record: PortableMemoRecord): seq[byte] =
  var pathItems: seq[CborItem] = @[]
  for entry in canonical(record.pathSet):
    pathItems.add(cArray([cUInt(uint64(ord(entry.kind))), cText(entry.path)]))
  var outputs = record.outputs
  outputs.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))
  var outItems: seq[CborItem] = @[]
  for output in outputs:
    var entryItems: seq[CborItem] = @[]
    for entry in output.entries:
      entryItems.add(cArray([cText(entry.rel), cUInt(uint64(ord(entry.kind))),
        cText(entry.identity)]))
    outItems.add(cArray([cText(output.path), cText(output.digest),
      cUInt(if output.directory: 1'u64 else: 0'u64), cArray(entryItems)]))
  encodeDeterministic(cArray([cText(MemoTag), cText(record.weakHex),
    cArray(pathItems), cText(record.strongHex), cArray(outItems)]))

proc decodeMemo*(bytes: openArray[byte]): PortableMemoRecord =
  let root = decodeItem(bytes)
  expect(root.kind == ckArray and root.elems.len == 5, "memo envelope")
  expect(root.elems[0].kind == ckText and root.elems[0].text == MemoTag,
    "memo tag")
  expect(root.elems[1].kind == ckText, "memo weak fingerprint")
  expect(root.elems[3].kind == ckText, "memo strong fingerprint")
  result.weakHex = root.elems[1].text
  result.pathSet = decodeEntries(root.elems[2])
  result.strongHex = root.elems[3].text
  let outs = root.elems[4]
  expect(outs.kind == ckArray, "memo outputs")
  for elem in outs.elems:
    expect(elem.kind == ckArray and elem.elems.len in 3 .. 4 and
      elem.elems[0].kind == ckText and elem.elems[1].kind == ckText and
      elem.elems[2].kind == ckUInt, "memo output")
    var output = PortableOutput(path: elem.elems[0].text,
      digest: elem.elems[1].text, directory: elem.elems[2].arg == 1)
    if elem.elems.len == 4:
      let entries = elem.elems[3]
      expect(entries.kind == ckArray, "memo output entries")
      for item in entries.elems:
        expect(item.kind == ckArray and item.elems.len == 3 and
          item.elems[0].kind == ckText and item.elems[1].kind == ckUInt and
          item.elems[1].arg <= uint64(ord(high(TreeEntryKind))) and
          item.elems[2].kind == ckText, "memo output entry")
        output.entries.add(TreeEntry(rel: item.elems[0].text,
          kind: TreeEntryKind(item.elems[1].arg),
          identity: item.elems[2].text))
    result.outputs.add(output)

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
  ## An observed input's identity as it stands now: from `resolve` when it
  ## knows (an upstream record), else from the filesystem. `none` when the
  ## input cannot be located on this host at all.
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
  of pikRead:
    if not fileExists(p):
      return none(string)
    some(fileContentHex(p))
  of pikProbe:
    some(if fileExists(p) or dirExists(p): "present" else: "absent")
  of pikEnumeration:
    if not dirExists(p):
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
  ## the record names; otherwise why not.
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
      digest: identity.get()))
  some(portableStrongFingerprint(weakHex, inputs))

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
      try:
        let raw = readFile(extendedPath(memo))
        let record = decodeMemo(raw.toOpenArrayByte(0, raw.high))
        if record.weakHex == weakHex and record.strongHex == strong.get() and
            manifestsConsistent(record):
          return some(record)
      except CatchableError:
        discard
  none(PortableMemoRecord)

proc outputResolver*(records: openArray[PortableMemoRecord]):
    IdentityResolver =
  ## Resolve reads of paths that upstream records PRODUCED from those
  ## records' output digests — the lookup-without-materialization step.
  var produced = initTable[string, string]()
  for record in records:
    for output in record.outputs:
      produced[output.path] = output.digest
  result = proc (entry: PathSetEntry): Option[string] =
    if entry.kind == pikRead and entry.path in produced:
      some(produced[entry.path])
    else:
      none(string)

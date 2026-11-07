## Search index snapshots (`Remix-Registry.md` §"Index and search").
##
## The index is a derived view the registrar rebuilds from logged records
## and publishes as immutable snapshots; search runs over a snapshot on the
## client. It deliberately carries no popularity, interest or safety
## numbers: those are Trust And Reputation statements, never values the
## registry invents.

import std/[algorithm, strutils]

import ssz_serialization
import repro_remix

const
  MaxIndexEntries* = 1 shl 20

type
  IndexEntry* = object
    release*: Digest32
    logIndex*: uint64
    remixName*: string
    version*: string
    intent*: string
    license*: string
    packages*: seq[string]
    permissions*: seq[string]
    platforms*: seq[string]
    authors*: seq[Digest32]
    parents*: seq[Digest32]

  IndexSnapshot* = object
    treeSize*: uint64
    entries*: seq[IndexEntry]

  IndexEntryW = object
    release: Digest32
    logIndex: uint64
    remixName: List[byte, MaxNameBytes]
    version: List[byte, MaxNameBytes]
    intent: List[byte, MaxIntentBytes]
    license: List[byte, MaxNameBytes]
    packages: List[List[byte, MaxNameBytes], MaxEntries]
    permissions: List[List[byte, MaxNameBytes], MaxSmallLists]
    platforms: List[List[byte, MaxNameBytes], MaxPlatforms]
    authors: List[Digest32, MaxSignatures]
    parents: List[Digest32, MaxParents]

  IndexSnapshotW = object
    treeSize: uint64
    entries: List[IndexEntryW, MaxIndexEntries]

  Query* = object
    ## All present criteria must match; empty criteria match everything.
    text*: string
      ## Case-insensitive substring of name or intent.
    package*: string
    license*: string
    platform*: string
    author*: Digest32
    hasAuthor*: bool
    withoutPermission*: string
      ## Exclude releases declaring this permission (e.g. "pkNetworkListen").

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc names(xs: seq[string]; N: static int): List[List[byte, MaxNameBytes], N] =
  var ls: seq[List[byte, MaxNameBytes]]
  for x in xs: ls.add List[byte, MaxNameBytes].init(bytesOf(x))
  List[List[byte, MaxNameBytes], N].init(ls)

proc entryFor*(m: Manifest; release: Digest32; logIndex: uint64): IndexEntry =
  result = IndexEntry(release: release, logIndex: logIndex,
    remixName: m.remixName, version: m.version, intent: m.intent,
    license: m.license, platforms: m.platforms, authors: m.authors,
    parents: m.parents)
  for t in m.targets:
    if t.original.package notin result.packages:
      result.packages.add t.original.package
  for p in m.permissions:
    result.permissions.add($p.kind & (if p.scope.len > 0: ":" & p.scope else: ""))
  result.packages.sort()

proc encodeIndex*(s: IndexSnapshot): seq[byte] =
  var ws: seq[IndexEntryW]
  for e in s.entries:
    ws.add IndexEntryW(release: e.release, logIndex: e.logIndex,
      remixName: List[byte, MaxNameBytes].init(bytesOf(e.remixName)),
      version: List[byte, MaxNameBytes].init(bytesOf(e.version)),
      intent: List[byte, MaxIntentBytes].init(bytesOf(e.intent)),
      license: List[byte, MaxNameBytes].init(bytesOf(e.license)),
      packages: names(e.packages, MaxEntries),
      permissions: names(e.permissions, MaxSmallLists),
      platforms: names(e.platforms, MaxPlatforms),
      authors: List[Digest32, MaxSignatures].init(e.authors),
      parents: List[Digest32, MaxParents].init(e.parents))
  SSZ.encode(IndexSnapshotW(treeSize: s.treeSize,
    entries: List[IndexEntryW, MaxIndexEntries].init(ws)))

proc decodeIndex*(bytes: openArray[byte]): IndexSnapshot =
  var w: IndexSnapshotW
  try:
    w = SSZ.decode(bytes, IndexSnapshotW)
  except SerializationError as e:
    refuse(rrMalformed, "index snapshot: " & e.msg)
  result.treeSize = w.treeSize
  for e in asSeq(w.entries):
    var x = IndexEntry(release: e.release, logIndex: e.logIndex,
      remixName: strOf(asSeq(e.remixName)), version: strOf(asSeq(e.version)),
      intent: strOf(asSeq(e.intent)), license: strOf(asSeq(e.license)),
      authors: asSeq(e.authors), parents: asSeq(e.parents))
    for p in asSeq(e.packages): x.packages.add strOf(asSeq(p))
    for p in asSeq(e.permissions): x.permissions.add strOf(asSeq(p))
    for p in asSeq(e.platforms): x.platforms.add strOf(asSeq(p))
    result.entries.add x

proc search*(s: IndexSnapshot; q: Query): seq[IndexEntry] =
  ## Deterministic: results are in log order.
  let needle = q.text.toLowerAscii
  for e in s.entries:
    if needle.len > 0 and needle notin e.remixName.toLowerAscii and
       needle notin e.intent.toLowerAscii:
      continue
    if q.package.len > 0 and q.package notin e.packages: continue
    if q.license.len > 0 and q.license notin e.license: continue
    if q.platform.len > 0 and q.platform notin e.platforms: continue
    if q.hasAuthor and q.author notin e.authors: continue
    if q.withoutPermission.len > 0:
      var hit = false
      for p in e.permissions:
        if p == q.withoutPermission or p.startsWith(q.withoutPermission & ":"):
          hit = true
      if hit: continue
    result.add e

## Deterministic text and JSON views of the Nimble index objects, for
## inspection, review and tests. Views of the canonical binary data, never a
## stored form: one object always renders to the same text, every field is
## shown, and lists appear in their canonical order.

import std/[json, options, strutils]

import ./types
import ./codec

proc q(s: string): string = s.escape()

proc renderCondition*(nodes: seq[ConditionNode]): string =
  ## A condition in infix form, fully parenthesized below the top level:
  ## `defined(linux) and not (hostCPU == "arm64")`. Empty: "".
  if nodes.len == 0:
    return ""
  var i = 0
  proc walk(top: bool): string =
    if i >= nodes.len:
      return "?"
    let n = nodes[i]
    inc i
    case n.kind
    of cnDefinedOs, cnDefinedCpu: "defined(" & n.name & ")"
    of cnHostOs: "hostOS == " & q(n.name)
    of cnHostCpu: "hostCPU == " & q(n.name)
    of cnNot:
      let operand = walk(false)
      "not " & (if operand.contains(' ') and not operand.startsWith("("):
                  "(" & operand & ")"
                else: operand)
    of cnAnd, cnOr:
      let a = walk(false)
      let b = walk(false)
      let s = a & " " & $n.kind & " " & b
      if top: s else: "(" & s & ")"
  walk(true)

proc renderRequirement(r: RequirementEntry): string =
  result = $r.targetKind & " " & q(r.target)
  if r.subdir.len > 0:
    result.add " subdir=" & q(r.subdir)
  result.add " " & $r.versionKind
  if r.constraint.len > 0:
    result.add " " & q(r.constraint)
  if r.features.len > 0:
    result.add " features=[" & r.features.join(",") & "]"
  if r.condition.len > 0:
    result.add " when " & renderCondition(r.condition)
  result.add " source=" & q(r.source)

proc listLine(name: string; items: seq[string]): string =
  var quoted: seq[string]
  for i in items: quoted.add q(i)
  name & ": [" & quoted.join(", ") & "]"

proc renderRecord(lines: var seq[string]; r: VersionRecord; indent: string) =
  let v = r.version
  lines.add indent & "version " & versionText(v) & " kind=" & $v.kind &
    " tag=" & q(v.tag)
  let i2 = indent & "  "
  lines.add i2 & "commit: " & r.commit
  lines.add i2 & "tree: blake3:" & $r.tree
  lines.add i2 & "archive_sha256: " & toHexLower(r.archiveSha256)
  lines.add i2 & "size: " & $r.size
  lines.add i2 & "first_seen: " & $r.firstSeen
  lines.add i2 & "origin: " & $r.origin
  var flags: seq[string]
  for f in r.flags: flags.add $f
  lines.add i2 & "flags: [" & flags.join(", ") & "]"
  lines.add i2 & "reader_class: " & $r.readerClass & " resolution_class: " &
    $r.resolutionClass
  if r.probePlatform.len > 0:
    lines.add i2 & "probe_platform: " & r.probePlatform
  lines.add i2 & "nimble_file: " &
    (if r.nimbleFile.isSome: "blake3:" & $r.nimbleFile.get else: "-")
  for e in r.nim:
    lines.add i2 & "nim " & renderRequirement(e)
  for e in r.requires:
    lines.add i2 & "requires " & renderRequirement(e)
  for f in r.features:
    lines.add i2 & "feature " & q(f.name) & (if f.rootOnly: " root-only" else: "")
    for e in f.requires:
      lines.add i2 & "  requires " & renderRequirement(e)
  let l = r.layout
  lines.add i2 & "layout srcDir: " & q(l.srcDir)
  for (name, items) in [("installDirs", l.installDirs),
      ("installFiles", l.installFiles), ("installExt", l.installExt),
      ("skipDirs", l.skipDirs), ("skipFiles", l.skipFiles),
      ("skipExt", l.skipExt), ("paths", l.paths), ("modules", l.modules)]:
    if items.len > 0:
      lines.add i2 & "layout " & listLine(name, items)
  for c in l.conditional:
    var s = i2 & "layout " & $c.field & (if c.append: " += " else: " = ")
    if c.field == rfNamedBin:
      var ps: seq[string]
      for p in c.pairs: ps.add q(p.key) & ": " & q(p.value)
      s.add "{" & ps.join(", ") & "}"
    else:
      var vs: seq[string]
      for x in c.values: vs.add q(x)
      s.add "[" & vs.join(", ") & "]"
    s.add " when " & renderCondition(c.condition)
    lines.add s
  let b = r.binaries
  if b.bin.len > 0: lines.add i2 & "binaries " & listLine("bin", b.bin)
  for p in b.namedBin:
    lines.add i2 & "binaries namedBin " & q(p.key) & ": " & q(p.value)
  if b.binDir.len > 0: lines.add i2 & "binaries binDir: " & q(b.binDir)
  if b.backend.len > 0: lines.add i2 & "binaries backend: " & b.backend
  for d in r.foreign:
    lines.add i2 & "foreign " & q(d.name) &
      (if d.condition.len > 0: " when " & renderCondition(d.condition) else: "")

proc renderShard*(s: NimbleShard): string =
  var lines = @["nimble-index shard schema=" & $NimbleIndexSchemaVersion &
    " bits=" & $s.shardBits & " bucket=" & $s.bucket &
    " packages=" & $s.packages.len & " aliases=" & $s.aliases.len]
  for p in s.packages:
    lines.add "package " & p.name & " registry_origin=" & $p.registryOrigin
    for i, o in p.origins:
      lines.add "  origin[" & $i & "] " & $o.vcs & " " & o.url &
        (if o.subdir.len > 0: " subdir=" & q(o.subdir) else: "")
    for r in p.versions:
      renderRecord(lines, r, "  ")
  for a in s.aliases:
    lines.add "alias " & a.alias & " -> " & a.target
  lines.join("\n")

proc renderRoot*(r: NimbleIndexRoot): string =
  var lines = @["nimble-index root schema=" & $NimbleIndexSchemaVersion]
  lines.add "generator: " & q(r.generator)
  lines.add "source_set: blake3:" & $r.sourceSet
  lines.add "generated_at: " & $r.generatedAt
  lines.add "previous_root: " &
    (if r.previousRoot.isSome: "blake3:" & $r.previousRoot.get else: "-")
  lines.add "counts: packages=" & $r.packageCount & " versions=" &
    $r.versionCount & " events=" & $r.eventCount
  lines.add "shard_bits: " & $r.shardBits
  lines.add "name_map: blake3:" & $r.nameMap.id & " size=" & $r.nameMap.size
  lines.add "events: blake3:" & $r.events.id & " size=" & $r.events.size
  for s in r.shards:
    lines.add "shard " & $s.bucket & " blake3:" & $s.id & " size=" & $s.size &
      " packages=" & $s.packages
  lines.join("\n")

proc renderNameMap*(m: NimbleNameMap): string =
  var lines = @["nimble-index name-map schema=" & $NimbleIndexSchemaVersion &
    " entries=" & $m.entries.len]
  for e in m.entries:
    lines.add(if e.target.len == 0: "name " & e.name
              else: "alias " & e.name & " -> " & e.target)
  lines.join("\n")

proc renderEvents*(e: NimbleEvents): string =
  var lines = @["nimble-index events schema=" & $NimbleIndexSchemaVersion &
    " events=" & $e.events.len]
  for ev in e.events:
    lines.add "event " & $ev.kind & " " & ev.package &
      (if ev.version.len > 0: " " & ev.version else: "") &
      " before=" & q(ev.before) & " after=" & q(ev.after) &
      " observed_at=" & $ev.observedAt
  lines.join("\n")

proc isNimbleIndexObject*(bytes: openArray[byte]): bool =
  ## True when ``bytes`` start with the frame of a Nimble index object.
  try:
    discard peekObjectKind(bytes)
    true
  except NimbleIndexError:
    false

proc renderIndexObject*(bytes: openArray[byte]): string =
  ## Decode (bounded, fail-closed, canonical) and render one index object.
  ## The first line names the kind and the object's identity.
  let id = indexObjectId(bytes)
  let body =
    case peekObjectKind(bytes)
    of nokRoot: renderRoot(decodeRoot(bytes))
    of nokShard: renderShard(decodeShard(bytes))
    of nokNameMap: renderNameMap(decodeNameMap(bytes))
    of nokEvents: renderEvents(decodeEvents(bytes))
  "object blake3:" & $id & " bytes=" & $bytes.len & "\n" & body

# ---------------------------------------------------------------------------
# JSON view
# ---------------------------------------------------------------------------

proc `%`(id: IndexObjectId): JsonNode =
  ## An object id or digest as lower-case hex, as the text view prints it.
  %toHexLower(id)

proc `%`(flags: set[RecordFlag]): JsonNode =
  result = newJArray()
  for f in flags: result.add %($f)

proc renderIndexObjectJson*(bytes: openArray[byte]): string =
  ## Decode (bounded, fail-closed, canonical) and render one index object as
  ## JSON: ``{"object": {"kind", "blake3", "bytes"}, "value": ...}``, where
  ## ``value`` holds every field of the decoded object under its Nim field
  ## name, enumerations as their spellings, ids and digests as hex. An
  ## inspection view: nothing reads it back.
  let kind = peekObjectKind(bytes)
  let value =
    case kind
    of nokRoot: %decodeRoot(bytes)
    of nokShard: %decodeShard(bytes)
    of nokNameMap: %decodeNameMap(bytes)
    of nokEvents: %decodeEvents(bytes)
  let doc = %*{"object": {"kind": $kind, "blake3": $indexObjectId(bytes),
    "bytes": bytes.len}, "value": value}
  $doc

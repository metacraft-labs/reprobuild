## The outputs of the generator's fetch edges, as the publisher reads them.
##
## A fetch edge (`refs`, `source`, history) hands the publisher (`shard`,
## `root`) a small text object of a closed vocabulary: a header naming the
## kind and version, then one record per line, each a keyword and
## percent-encoded fields. The reader refuses an unknown header, keyword or
## field count, so a worker's output is data of a fixed shape and nothing
## else (threat model §3.2: the worker → publisher crossing). The bytes are
## a function of what the origin answered alone (no time, no path, no
## host), so the object is named by its hash.

import std/[algorithm, strutils]

import ./source_tree

const
  RefsHeader* = "reprobuild.nimble-generator.refs.v1"
  SourceHeader* = "reprobuild.nimble-generator.source.v1"
  HistoryHeader* = "reprobuild.nimble-generator.history.v1"
  MaxEdgeObjectBytes* = 64 * 1024 * 1024

type
  EdgeObjectError* = object of ValueError

  AnswerState* = enum
    anOk = "ok"
    anFailed = "failed"   ## the origin did not answer, or not as asked
    anRefused = "refused" ## the egress policy refused before any contact

  RefsAnswer* = object
    state*: AnswerState
    detail*: string
    refusal*: string ## the egress refusal kind, for `anRefused` and limits
    headRef*, head*: string
    tags*: seq[(string, string)] ## (name, peeled object), sorted by name

  SourceAnswer* = object
    state*: AnswerState
    detail*: string
    refusal*: string
    commit*: string
    facts*: SourceFacts

  HistoryAnswer* = object
    state*: AnswerState
    detail*: string
    refusal*: string
    branchCommits*: seq[string]
    allCommits*: seq[string]

proc enc*(s: string): string =
  ## Percent-encoding of every byte outside printable ASCII, `%` included;
  ## the empty string is `-`.
  if s.len == 0: return "-"
  for c in s:
    if ord(c) < 0x21 or ord(c) > 0x7e or c == '%' or (c == '-' and s.len == 1):
      result.add '%' & toHex(ord(c), 2)
    else:
      result.add c

proc dec*(s: string): string =
  if s == "-": return ""
  var i = 0
  while i < s.len:
    if s[i] == '%':
      if i + 2 >= s.len:
        raise newException(EdgeObjectError, "truncated escape in " & s.escape())
      try:
        result.add chr(parseHexInt(s[i + 1 .. i + 2]))
      except ValueError:
        raise newException(EdgeObjectError, "bad escape in " & s.escape())
      i += 3
    else:
      result.add s[i]
      inc i

proc line(fields: varargs[string]): string =
  var parts: seq[string]
  for f in fields: parts.add enc(f)
  parts.join(" ") & "\n"

iterator records(text, header: string): seq[string] =
  if text.len > MaxEdgeObjectBytes:
    raise newException(EdgeObjectError, "edge object larger than " &
      $MaxEdgeObjectBytes & " bytes")
  let lines = text.split('\n')
  if lines.len == 0 or lines[0] != header:
    raise newException(EdgeObjectError, "not a " & header & " object")
  if lines[^1] != "":
    raise newException(EdgeObjectError, "an edge object ends with a newline")
  for i in 1 ..< lines.len - 1:
    var fs: seq[string]
    for f in lines[i].split(' '): fs.add dec(f)
    yield fs

proc need(fs: seq[string]; n: int) =
  if fs.len != n:
    raise newException(EdgeObjectError, "record " & fs[0].escape() &
      " has " & $(fs.len - 1) & " fields, not " & $(n - 1))

proc parseState(s: string): AnswerState =
  case s
  of "ok": anOk
  of "failed": anFailed
  of "refused": anRefused
  else: raise newException(EdgeObjectError, "unknown state " & s.escape())

# ---------------------------------------------------------------------------

proc encodeRefs*(a: RefsAnswer): string =
  result = RefsHeader & "\n"
  result.add line("state", $a.state, a.refusal, a.detail)
  if a.state == anOk:
    result.add line("head", a.headRef, a.head)
    var tags = a.tags
    tags.sort(proc (x, y: (string, string)): int = cmp(x[0], y[0]))
    for (n, c) in tags: result.add line("tag", n, c)

proc decodeRefs*(text: string): RefsAnswer =
  var sawState = false
  for fs in records(text, RefsHeader):
    case fs[0]
    of "state":
      need(fs, 4)
      result.state = parseState(fs[1])
      result.refusal = fs[2]
      result.detail = fs[3]
      sawState = true
    of "head":
      need(fs, 3)
      result.headRef = fs[1]
      result.head = fs[2]
    of "tag":
      need(fs, 3)
      result.tags.add (fs[1], fs[2])
    else:
      raise newException(EdgeObjectError, "unknown refs record " &
        fs[0].escape())
  if not sawState:
    raise newException(EdgeObjectError, "a refs object without a state")

# ---------------------------------------------------------------------------

proc encodeSource*(a: SourceAnswer): string =
  result = SourceHeader & "\n"
  result.add line("state", $a.state, a.refusal, a.detail)
  result.add line("commit", a.commit)
  if a.state != anOk:
    return
  let f = a.facts
  result.add line("tree", f.treeDigest)
  result.add line("archive", f.archiveSha256, $f.archiveSize)
  result.add line("committed", $f.commitTime)
  result.add line("nimble", $f.nimble, f.nimblePath)
  for c in f.nimbleCandidates: result.add line("nimble-candidate", c)
  for p in f.files: result.add line("file", p)
  for l in f.links: result.add line("link", l.path, l.target, $l.verdict)
  for (p, c) in f.gitlinks: result.add line("gitlink", p, c)
  for s in f.submodules: result.add line("submodule", s.path, s.url, s.verdict)

proc decodeSource*(text: string): SourceAnswer =
  var sawState = false
  for fs in records(text, SourceHeader):
    case fs[0]
    of "state":
      need(fs, 4)
      result.state = parseState(fs[1])
      result.refusal = fs[2]
      result.detail = fs[3]
      sawState = true
    of "commit":
      need(fs, 2)
      result.commit = fs[1]
    of "tree":
      need(fs, 2)
      result.facts.treeDigest = fs[1]
    of "archive":
      need(fs, 3)
      result.facts.archiveSha256 = fs[1]
      result.facts.archiveSize = parseBiggestInt(fs[2])
    of "committed":
      need(fs, 2)
      result.facts.commitTime = parseBiggestInt(fs[1])
    of "nimble":
      need(fs, 3)
      case fs[1]
      of "found": result.facts.nimble = nlFound
      of "none": result.facts.nimble = nlNone
      of "ambiguous": result.facts.nimble = nlAmbiguous
      else: raise newException(EdgeObjectError, "unknown nimble lookup")
      result.facts.nimblePath = fs[2]
    of "nimble-candidate":
      need(fs, 2)
      result.facts.nimbleCandidates.add fs[1]
    of "file":
      need(fs, 2)
      result.facts.files.add fs[1]
    of "link":
      need(fs, 4)
      let v = case fs[3]
        of "in": lvInside
        of "out": lvOutside
        else: raise newException(EdgeObjectError, "unknown link verdict")
      result.facts.links.add SourceLink(path: fs[1], target: fs[2], verdict: v)
    of "gitlink":
      need(fs, 3)
      result.facts.gitlinks.add (fs[1], fs[2])
    of "submodule":
      need(fs, 4)
      result.facts.submodules.add SubmoduleUrl(path: fs[1], url: fs[2],
        verdict: fs[3])
    else:
      raise newException(EdgeObjectError, "unknown source record " &
        fs[0].escape())
  if not sawState:
    raise newException(EdgeObjectError, "a source object without a state")

# ---------------------------------------------------------------------------

proc encodeHistory*(a: HistoryAnswer): string =
  result = HistoryHeader & "\n"
  result.add line("state", $a.state, a.refusal, a.detail)
  var branch = a.branchCommits
  branch.sort()
  var all = a.allCommits
  all.sort()
  for c in branch: result.add line("branch", c)
  for c in all: result.add line("commit", c)

proc decodeHistory*(text: string): HistoryAnswer =
  var sawState = false
  for fs in records(text, HistoryHeader):
    case fs[0]
    of "state":
      need(fs, 4)
      result.state = parseState(fs[1])
      result.refusal = fs[2]
      result.detail = fs[3]
      sawState = true
    of "branch":
      need(fs, 2)
      result.branchCommits.add fs[1]
    of "commit":
      need(fs, 2)
      result.allCommits.add fs[1]
    else:
      raise newException(EdgeObjectError, "unknown history record " &
        fs[0].escape())
  if not sawState:
    raise newException(EdgeObjectError, "a history object without a state")

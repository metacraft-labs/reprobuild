## Strict, bounded reader for the unified diffs a Remix patch blob holds.
##
## Normative source: `reprobuild-pm/spec/Remix-Protocol.md` §"Manifest
## body" (`patches`) and §"Conflict classes" (`patch`). Composition needs
## only which files a patch touches and which original line ranges each
## hunk replaces, so this reads headers and hunk ranges and checks that each
## hunk's body has exactly the line counts its header declares. It does not
## apply patches; application belongs to the build graph.
##
## Format: GNU diffutils "Detailed Unified" —
## https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html
##
## Hostile-input posture: a patch is attacker-authored. Paths are refused
## if absolute, if they contain `..`, a backslash or a NUL, or if they
## would name the source root itself; counts are bounded; a body that
## disagrees with its header is refused rather than resynchronised.

import std/strutils

import ./types

const
  MaxPatchFiles* = 4096
  MaxHunksPerFile* = 65536
  MaxLineNumber = 100_000_000

type
  Hunk* = object
    oldStart*, oldCount*: int
      ## 1-based start and length of the original lines this hunk replaces.
      ## A pure insertion has `oldCount == 0` and sits after `oldStart`.

  FilePatch* = object
    path*: string
      ## Path relative to the source root after stripping `strip` leading
      ## components, as patch(1) `-p` does.
    hunks*: seq[Hunk]

proc stripPath(raw: string; strip: int): string =
  ## Apply `-p<strip>` to a header path and validate the result.
  var p = raw
  let tab = p.find('\t')
  if tab >= 0:
    p = p[0 ..< tab]               # drop the optional timestamp
  if p.len == 0 or p[0] == '/' or '\\' in p or '\0' in p:
    refuse(rrInvalidText, "patch path is absolute or contains a forbidden byte")
  var parts = p.split('/')
  if parts.len <= strip:
    refuse(rrInvalidText, "patch path has fewer components than strip " & $strip)
  parts = parts[strip .. ^1]
  for part in parts:
    if part == ".." or part == "." or part.len == 0:
      refuse(rrInvalidText, "patch path contains an empty, '.' or '..' component")
  parts.join("/")

proc parseRange(text: string): (int, int) =
  ## `l` or `l,s` from a hunk header.
  let comma = text.find(',')
  try:
    if comma < 0:
      result = (parseInt(text), 1)
    else:
      result = (parseInt(text[0 ..< comma]), parseInt(text[comma + 1 .. ^1]))
  except ValueError:
    refuse(rrMalformed, "hunk range is not numeric")
  if result[0] < 0 or result[1] < 0 or result[0] > MaxLineNumber or
     result[1] > MaxLineNumber:
    refuse(rrBound, "hunk range out of bounds")

proc parseUnifiedDiff*(text: string; strip: int): seq[FilePatch] =
  ## Parse every file section. Refuses `/dev/null` sides (file creation and
  ## deletion are not v1 patch operations: a new file belongs in a graph
  ## fragment, where ownership is declared), renames, and binary diffs.
  let lines = text.split('\n')
  var i = 0
  while i < lines.len:
    let line = lines[i]
    if line.startsWith("--- "):
      if i + 1 >= lines.len or not lines[i + 1].startsWith("+++ "):
        refuse(rrMalformed, "'---' header without a following '+++' header")
      let oldRaw = line[4 .. ^1]
      let newRaw = lines[i + 1][4 .. ^1]
      if oldRaw.startsWith("/dev/null") or newRaw.startsWith("/dev/null"):
        refuse(rrForbiddenContent, "patch creates or deletes a file")
      let oldPath = stripPath(oldRaw, strip)
      let newPath = stripPath(newRaw, strip)
      if oldPath != newPath:
        refuse(rrForbiddenContent, "patch renames " & oldPath & " to " & newPath)
      var fp = FilePatch(path: newPath)
      i += 2
      while i < lines.len and lines[i].startsWith("@@ "):
        let h = lines[i]
        let close = h.find(" @@", 3)
        if close < 0:
          refuse(rrMalformed, "unterminated hunk header")
        let ranges = h[3 ..< close].split(' ')
        if ranges.len != 2 or not ranges[0].startsWith("-") or
           not ranges[1].startsWith("+"):
          refuse(rrMalformed, "hunk header is not '-l,s +l,s'")
        let (os, oc) = parseRange(ranges[0][1 .. ^1])
        let (_, nc) = parseRange(ranges[1][1 .. ^1])
        var seenOld, seenNew = 0
        inc i
        while (seenOld < oc or seenNew < nc) and i < lines.len:
          let body = lines[i]
          if body.len == 0:
            refuse(rrMalformed, "empty line inside a hunk body")
          case body[0]
          of ' ': inc seenOld; inc seenNew
          of '-': inc seenOld
          of '+': inc seenNew
          of '\\': discard                 # "\ No newline at end of file"
          else: refuse(rrMalformed, "hunk body line has no ' ', '-' or '+' prefix")
          inc i
        if seenOld != oc or seenNew != nc:
          refuse(rrMalformed, "hunk body disagrees with its header counts")
        while i < lines.len and lines[i].startsWith("\\"):
          inc i
        fp.hunks.add Hunk(oldStart: os, oldCount: oc)
        if fp.hunks.len > MaxHunksPerFile:
          refuse(rrBound, "too many hunks in one file")
      if fp.hunks.len == 0:
        refuse(rrMalformed, "file section with no hunks")
      result.add fp
      if result.len > MaxPatchFiles:
        refuse(rrBound, "patch touches too many files")
    elif line.startsWith("Binary files ") or line.startsWith("GIT binary patch"):
      refuse(rrForbiddenContent, "binary diffs are not v1 patch content")
    elif line.startsWith("rename from ") or line.startsWith("copy from "):
      refuse(rrForbiddenContent, "renames and copies are not v1 patch operations")
    else:
      inc i                               # preamble / git extended headers
  if result.len == 0:
    refuse(rrMalformed, "patch contains no file sections")

proc overlaps*(a, b: Hunk): bool =
  ## Whether two hunks against the same original file conflict. Ranges that
  ## overlap or touch conflict: two edits to adjacent lines cannot both be
  ## applied with a context-checked patch without one invalidating the
  ## other's context, so adjacency is treated as a conflict too. Insertions
  ## (`oldCount == 0`) occupy the gap after `oldStart`.
  let aEnd = a.oldStart + max(a.oldCount, 1) - 1
  let bEnd = b.oldStart + max(b.oldCount, 1) - 1
  not (aEnd + 1 < b.oldStart or bEnd + 1 < a.oldStart)

## The ``-embedcfg`` document of the Go standard convention.
##
## ``go tool compile`` compiles a package with ``//go:embed`` directives only
## when it is handed an embed configuration: a JSON document naming, for each
## pattern, the files that pattern embeds, and for each file the path to read
## it from. cmd/go writes it in ``(*Builder).build``
## (https://github.com/golang/go/blob/master/src/cmd/go/internal/work/exec.go)
## from the per-pattern resolution in ``resolveEmbed``
## (https://github.com/golang/go/blob/master/src/cmd/go/internal/load/pkg.go).
##
## ``go list -json`` reports a package's patterns (``EmbedPatterns``) and the
## UNION of the files they resolve to (``EmbedFiles``), but not which pattern
## matched which file — and the compiler needs that, because each embed
## variable receives exactly the files of its own patterns. This module
## recovers the per-pattern lists by FILTERING ``EmbedFiles`` with cmd/go's
## own rule, as reprobuild-pm ``spec/Language-Conventions/Go.md``
## §"The embedcfg file" specifies. It never globs the file system and never
## names a file ``go list`` did not report.
##
## Pure functions over strings: no I/O, so the unit tests exercise exactly the
## code the convention runs.

import std/[algorithm, json, os, strutils, unicode]

type
  GoBadPattern* = object of ValueError
    ## A pattern ``path.Match`` itself would reject (``path.ErrBadPattern``).
    ## ``go list`` validates embed patterns before reporting them, so meeting
    ## one here means the listing and this module disagree about the syntax.

proc badPattern(pattern: string) {.noreturn.} =
  raise newException(GoBadPattern,
    "go convention: syntax error in embed pattern " & pattern.escape())

proc getEsc(chunk: string; pattern: string): tuple[r: Rune; rest: string] =
  ## Port of ``path.getEsc``: one possibly-escaped character of a class.
  var c = chunk
  if c.len == 0 or c[0] == '-' or c[0] == ']':
    badPattern(pattern)
  if c[0] == '\\':
    c = c[1 .. ^1]
    if c.len == 0:
      badPattern(pattern)
  let n = c.runeLenAt(0)
  let r = c.runeAt(0)
  # Go's ``utf8.RuneError`` with width 1: a byte that starts no valid
  # encoding.
  if n == 1 and ord(c[0]) >= 0x80:
    badPattern(pattern)
  if validateUtf8(c[0 ..< n]) >= 0:
    badPattern(pattern)
  result.rest = c[n .. ^1]
  if result.rest.len == 0:
    badPattern(pattern)
  result.r = r

proc matchChunk(chunk, s, pattern: string): tuple[rest: string; ok: bool] =
  ## Port of ``path.matchChunk``: match ``chunk`` (no ``*``) against a prefix
  ## of ``s``. Continues to the end of the chunk after a failure so a syntax
  ## error later in it is still reported, exactly as Go does.
  var chunk = chunk
  var s = s
  var failed = false
  while chunk.len > 0:
    if not failed and s.len == 0:
      failed = true
    case chunk[0]
    of '[':
      var r = Rune(0)
      if not failed:
        let n = s.runeLenAt(0)
        r = s.runeAt(0)
        s = s[n .. ^1]
      chunk = chunk[1 .. ^1]
      var negated = false
      if chunk.len > 0 and chunk[0] == '^':
        negated = true
        chunk = chunk[1 .. ^1]
      var matched = false
      var nrange = 0
      while true:
        if chunk.len > 0 and chunk[0] == ']' and nrange > 0:
          chunk = chunk[1 .. ^1]
          break
        let lo = getEsc(chunk, pattern)
        chunk = lo.rest
        var hi = lo.r
        if chunk[0] == '-':
          let h = getEsc(chunk[1 .. ^1], pattern)
          hi = h.r
          chunk = h.rest
        if int(lo.r) <= int(r) and int(r) <= int(hi):
          matched = true
        inc nrange
      if matched == negated:
        failed = true
    of '?':
      if not failed:
        if s[0] == '/':
          failed = true
        let n = s.runeLenAt(0)
        s = s[n .. ^1]
      chunk = chunk[1 .. ^1]
    else:
      if chunk[0] == '\\':
        chunk = chunk[1 .. ^1]
        if chunk.len == 0:
          badPattern(pattern)
      if not failed:
        if chunk[0] != s[0]:
          failed = true
        s = s[1 .. ^1]
      chunk = chunk[1 .. ^1]
  if failed:
    return ("", false)
  (s, true)

proc scanChunk(pattern: string): tuple[star: bool; chunk, rest: string] =
  ## Port of ``path.scanChunk``.
  var p = pattern
  while p.len > 0 and p[0] == '*':
    p = p[1 .. ^1]
    result.star = true
  var inrange = false
  var i = 0
  block scan:
    while i < p.len:
      case p[i]
      of '\\':
        if i + 1 < p.len:
          inc i
      of '[':
        inrange = true
      of ']':
        inrange = false
      of '*':
        if not inrange:
          break scan
      else:
        discard
      inc i
  result.chunk = p[0 ..< i]
  result.rest = p[i .. ^1]

proc goPathMatch*(pattern, name: string): bool =
  ## Port of Go's ``path.Match``
  ## (https://pkg.go.dev/path#Match): ``*`` matches any run of non-``/``
  ## characters, ``?`` one non-``/`` character, ``[...]`` a class with
  ## ranges and ``^`` negation, ``\\`` escapes the next character. Raises
  ## ``GoBadPattern`` where Go returns ``ErrBadPattern``.
  var pattern = pattern
  var name = name
  let original = pattern
  block outer:
    while pattern.len > 0:
      let sc = scanChunk(pattern)
      pattern = sc.rest
      if sc.star and sc.chunk.len == 0:
        return '/' notin name
      let first = matchChunk(sc.chunk, name, original)
      if first.ok and (first.rest.len == 0 or pattern.len > 0):
        name = first.rest
        continue
      if sc.star:
        var i = 0
        var advanced = false
        while i < name.len and name[i] != '/':
          let t = matchChunk(sc.chunk, name[i + 1 .. ^1], original)
          if t.ok:
            if pattern.len == 0 and t.rest.len > 0:
              inc i
              continue
            name = t.rest
            advanced = true
            break
          inc i
        if advanced:
          continue
      # Before reporting no match, check that the rest of the pattern is
      # syntactically valid (Go does).
      while pattern.len > 0:
        let rest = scanChunk(pattern)
        pattern = rest.rest
        discard matchChunk(rest.chunk, "", original)
      return false
  name.len == 0

proc goGlobMatch*(glob, relPath: string): bool =
  ## Whether ``fs.Glob``/``filepath.Glob`` rooted at the package directory
  ## would return ``relPath`` for ``glob``: Glob matches ELEMENT BY ELEMENT
  ## (it splits the pattern at its separators, never inside ``Match``), so the
  ## two must have the same number of ``/``-separated elements and each
  ## element must ``path.Match`` its counterpart.
  let globParts = glob.split('/')
  let pathParts = relPath.split('/')
  if globParts.len != pathParts.len:
    return false
  for i in 0 ..< globParts.len:
    if not goPathMatch(globParts[i], pathParts[i]):
      return false
  true

const VcsDirNames = [".bzr", ".git", ".hg", ".svn"]
  ## ``isBadEmbedName``'s fixed list: never embedded from a directory walk,
  ## ``all:`` or not.

proc embedFilesOfPattern*(pattern: string; embedFiles: openArray[string]):
    seq[string] =
  ## The files of ``embedFiles`` (``go list``'s ``EmbedFiles``, slash paths
  ## relative to the package directory) that ``pattern`` (one entry of
  ## ``EmbedPatterns``, ``all:`` prefix included) embeds, sorted — the rule of
  ## Go.md §"The embedcfg file":
  ##
  ##   * the glob matches the file itself, or
  ##   * the glob matches a proper ancestor directory ``d`` of the file and no
  ##     path element below ``d`` is a VCS directory name, nor — without
  ##     ``all:`` — begins with ``.`` or ``_``.
  var glob = pattern
  var all = false
  if glob.startsWith("all:"):
    glob = glob[4 .. ^1]
    all = true
  for file in embedFiles:
    var included = goGlobMatch(glob, file)
    if not included:
      let parts = file.split('/')
      # Ancestors from the shallowest; ``k`` elements form the ancestor.
      for k in 1 ..< parts.len:
        let ancestor = parts[0 ..< k].join("/")
        if not goGlobMatch(glob, ancestor):
          continue
        var ok = true
        for element in parts[k .. ^1]:
          if element in VcsDirNames:
            ok = false
            break
          if not all and element.len > 0 and element[0] in {'.', '_'}:
            ok = false
            break
        if ok:
          included = true
          break
    if included and file notin result:
      result.add(file)
  result.sort(system.cmp[string])

proc renderEmbedcfg*(packageDir: string; embedPatterns,
                     embedFiles: openArray[string]): string =
  ## The ``-embedcfg`` JSON for one package: ``Patterns`` maps each entry of
  ## ``embedPatterns`` to its files (``embedFilesOfPattern``), ``Files`` maps
  ## each entry of ``embedFiles`` to its absolute path under ``packageDir``.
  ## Keys and lists are sorted so the document is byte-stable. A pattern that
  ## embeds nothing is refused: ``go list`` reports such a package as an
  ## error, so reaching it means the two resolutions disagree.
  var patterns = newJObject()
  var sortedPatterns = @embedPatterns
  sortedPatterns.sort(system.cmp[string])
  for pattern in sortedPatterns:
    let files = embedFilesOfPattern(pattern, embedFiles)
    if files.len == 0:
      raise newException(ValueError,
        "go convention: embed pattern " & pattern.escape() & " in " &
          packageDir & " matches none of the files go list reported " &
          "(EmbedFiles: " & $(@embedFiles) & ")")
    var arr = newJArray()
    for f in files:
      arr.add(%f)
    patterns[pattern] = arr
  var filesNode = newJObject()
  var sortedFiles = @embedFiles
  sortedFiles.sort(system.cmp[string])
  for f in sortedFiles:
    filesNode[f] = %(packageDir / f.replace('/', DirSep))
  var doc = newJObject()
  doc["Patterns"] = patterns
  doc["Files"] = filesNode
  doc.pretty() & "\n"

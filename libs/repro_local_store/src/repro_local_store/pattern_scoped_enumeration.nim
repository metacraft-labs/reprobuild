## Pattern-scoped directory enumerations: a directory listed only to find
## the entries that match one glob pattern component.
##
## glob(3) keeps only the entries of a directory that match one component of
## its pattern, so a scan such as Nim's search for `<dir>/*.nimble` depends on
## WHICH entries match, not on the whole listing. io-mon reports such a scan
## as a pattern-scoped `mrDirectoryEnumerate` (`io_mon.globScanPattern`), and
## `Incremental-Invalidation.md` §"Validation Criteria" keys it on the
## matching entries alone: keyed on the whole listing, every unrelated file
## created next to a project's sources, including the `build/` directory the
## first build makes, re-ran every Nim compile in the project.
##
## THE NAME. A pattern-scoped enumeration travels through every channel an
## ordinary one does (evidence, record inputs, portable accesses, prompt
## watch) under one path: the directory, a `/`, a NUL byte, then the pattern.
## The NUL is the whole design, for two reasons:
##
## * it cannot occur in a real path, so the name never collides with a
##   directory that is really spelled that way;
## * the OS ends a path at the first NUL, so code that does not know the
##   convention, including an older `repro` reading a record this one wrote,
##   treats the name as the directory ITSELF and keys it on its full
##   listing. That is a superset of the scoped key and so always sound: a
##   full listing can equal a recorded scoped one only when every entry
##   present now matched then, in which case the scoped listing is unchanged
##   too. Such a reader misses where this one hits; it never hits wrongly.
##
## Everything that knows the convention goes through this module, so the
## digest a record stores and the one a lookup recomputes are the same
## function of the same names.

import std/strutils

const
  PatternScopeSeparator* = '\0'
    ## Separates a pattern-scoped enumeration's directory from its pattern;
    ## see the module note for why it is a NUL.

func patternScopedEnumerationPath*(dir, pattern: string): string =
  ## The name of the enumeration of `dir` scoped to `pattern`. A trailing
  ## `/` on `dir` is dropped (the monitor reports some directories with
  ## one), except for the root itself, so one directory has one name.
  var base = dir
  while base.len > 1 and base[^1] in {'/', '\\'}:
    base.setLen(base.len - 1)
  if base.len == 0 or base[^1] notin {'/', '\\'}:
    base.add('/')
  base & PatternScopeSeparator & pattern

func splitPatternScopedEnumeration*(path: string):
    tuple[dir, pattern: string] =
  ## The directory and pattern of a pattern-scoped name, or `(path, "")` for
  ## any other path. The directory comes back without the separating `/`
  ## unless it is the root.
  let at = path.find(PatternScopeSeparator)
  if at < 0:
    return (path, "")
  var dir = path[0 ..< at]
  if dir.len > 1 and dir[^1] in {'/', '\\'}:
    dir.setLen(dir.len - 1)
  (dir, path[at + 1 .. ^1])

func isPatternScopedEnumeration*(path: string): bool {.inline.} =
  PatternScopeSeparator in path

func patternScopedBase*(path: string): string =
  ## The directory a path names when it is a pattern-scoped enumeration,
  ## and the path itself otherwise. For filters that decide by WHERE an
  ## observation is (a tool root, an untracked scope, an action's own output
  ## directory): the scope narrows what was read there, not where.
  ##
  ## Spelled out rather than as `splitPatternScopedEnumeration(path).dir`:
  ## the field of a temporary tuple, read inside a closure, made the C
  ## backend of the pinned Nim reference an undeclared temporary.
  let at = path.find(PatternScopeSeparator)
  if at < 0:
    return path
  result = path[0 ..< at]
  if result.len > 1 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

func globComponentMatches*(pattern, name: string): bool =
  ## Whether `name` may match the glob pattern component `pattern`, which
  ## holds only literals, `*` and `?` (io-mon reports nothing else).
  ##
  ## Errs toward TRUE, because a name this rejects and glob accepted would be
  ## a dependency left out of the key:
  ## * `?` matches one character, which in a UTF-8 locale is up to four
  ##   bytes, so here it matches one byte or more;
  ## * glob's rule that a leading `.` is matched only by a literal `.` is not
  ##   applied, so `*` also matches hidden names.
  ##
  ## Classic dynamic programming over (pattern position, name position);
  ## names and patterns are short, so O(len(pattern) * len(name)) is cheap.
  let n = name.len
  # `reach[j]`: the pattern consumed so far can end exactly at name[j].
  var reach = newSeq[bool](n + 1)
  reach[0] = true
  for c in pattern:
    var next = newSeq[bool](n + 1)
    case c
    of '*':
      var any = false
      for j in 0 .. n:
        any = any or reach[j]
        next[j] = any
    of '?':
      var any = false
      for j in 1 .. n:
        any = any or reach[j - 1]
        next[j] = any
    else:
      for j in 1 .. n:
        next[j] = reach[j - 1] and name[j - 1] == c
    reach = next
  reach[n]

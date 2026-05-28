import std/[strutils]
from std/os import absolutePath

type
  NormalizedPathKind* = enum
    npRelative
    npAbsolute

  NormalizedPath* = object
    kind*: NormalizedPathKind
    value*: string

proc normalizeSeparators(path: string): string =
  path.replace('\\', '/')

proc collapseSlashes(path: string): string =
  result = newStringOfCap(path.len)
  var priorSlash = false
  for ch in path:
    if ch == '/':
      if not priorSlash:
        result.add(ch)
      priorSlash = true
    else:
      result.add(ch)
      priorSlash = false

proc normalizedPath*(path: string): NormalizedPath =
  let cleaned = collapseSlashes(normalizeSeparators(path).strip())
  if cleaned.len == 0:
    raise newException(ValueError, "normalized path must not be empty")
  if cleaned == ".":
    return NormalizedPath(kind: npRelative, value: ".")
  for part in cleaned.split('/'):
    if part == "..":
      raise newException(ValueError, "normalized path must not contain '..'")
  let kind =
    if cleaned.startsWith("/"): npAbsolute
    else: npRelative
  NormalizedPath(kind: kind, value: cleaned)

proc `$`*(path: NormalizedPath): string =
  path.value

proc extendedPath*(path: string): string =
  ## On Windows, rewrites a path into the `\\?\` extended-length form so
  ## file-system calls bypass the 260-character `MAX_PATH` limit. Returns
  ## `path` unchanged on non-Windows platforms, for the empty string, and
  ## for paths already in `\\?\` / `\\.\` / UNC (`\\`) form.
  ##
  ## Apply this only where a path is handed to a file-system call; never
  ## store, compare, log, or pass it to a child process, because `\\?\`
  ## paths do not compare equal to (and are not understood the same way
  ## as) the ordinary form.
  ##
  ## The body collapses any internal `\\` that results from joining a
  ## directory ending in `\\` with a path component beginning with `/`
  ## (a common quirk on Windows when `~` resolves to `C:\Users\X\` and
  ## the relative path uses forward slashes). The `\\?\` namespace is
  ## strict-canonical — Windows rejects paths with `\\` mid-segment —
  ## so this collapse is mandatory, not cosmetic.
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      var canonical = absolutePath(path).replace('/', '\\')
      while "\\\\" in canonical:
        canonical = canonical.replace("\\\\", "\\")
      "\\\\?\\" & canonical
  else:
    path

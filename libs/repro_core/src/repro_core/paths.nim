import std/[strutils]

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

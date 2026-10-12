## Recipe-relative naming for the engine's own recipe compiles.
##
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles": interface extraction and the provider compile run IN the
## directory of the `repro.nim` they compile, and everything they observe or
## produce beside that directory is named relative to it. The same recipe
## bytes at another path, in another worktree or under another work root
## then present the same names, so the engine's action cache can serve one
## compile to all of them, and what the compile wrote describes the copy
## that consults it.
##
## What is NOT reached relative to the recipe — the toolchain, the
## reprobuild libraries, host configuration — is reached by ABSOLUTE path
## from every location, so it stays named absolutely. Those roots are the
## ANCHORS. One rule decides both how the engine records an input
## (`repro_build_engine.recordedInputNames`) and how an interface artifact
## records a source location, so the two cannot disagree about which files
## travel with the recipe.

import std/[os, strutils]

proc normalizedKey(path: string): string =
  result = os.normalizedPath(path).replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc isWithin(path, root: string): bool =
  root == "/" or path == root or path.startsWith(root & "/")

proc effectiveAnchors*(base: string; anchors: openArray[string]): seq[string] =
  ## `anchors` normalized, minus every anchor that contains `base` (an anchor
  ## around the recipe itself — a recipe checked into the reprobuild tree, a
  ## fixture under the home directory — would otherwise pin the recipe's own
  ## files to one location) and every relative or root anchor.
  let baseKey = normalizedKey(base)
  for anchor in anchors:
    if anchor.len == 0 or not anchor.isAbsolute:
      continue
    let key = normalizedKey(anchor)
    if key == "/" or baseKey.isWithin(key):
      continue
    if key notin result:
      result.add(key)

proc relocatableName*(path, base: string; anchors: openArray[string]): string =
  ## `path` as a recipe-relative compile names it: relative to `base` (the
  ## recipe directory, the compile's cwd) unless it lies under one of
  ## `anchors` (already passed through `effectiveAnchors`), in which case
  ## the absolute path. Relative and empty paths are returned unchanged.
  if path.len == 0 or not path.isAbsolute or base.len == 0 or
      not base.isAbsolute:
    return path
  let key = normalizedKey(path)
  for anchor in anchors:
    if key.isWithin(anchor):
      return path
  let relative =
    try: relativePath(key, normalizedKey(base))
    except CatchableError: ""
  if relative.len == 0 or relative.isAbsolute:
    path
  else:
    relative

proc rebasedName*(name, base: string): string =
  ## The inverse of `relocatableName` at the location `base`: a relative
  ## name resolved against it, an absolute one unchanged.
  if name.len == 0 or name.isAbsolute or base.len == 0:
    name
  else:
    os.normalizedPath(base / name)

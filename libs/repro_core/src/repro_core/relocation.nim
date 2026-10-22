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

import std/[macros, os, strutils]

const
  reproRecipeRelative* {.booldefine.} = false
    ## Set (with `reproRecipeAnchors`) on a recipe-relative PROVIDER compile
    ## (`repro_interface_artifacts.providerCompilePlan`). The DSL then records
    ## the source sites it serializes - package, target, variant and
    ## provisioning sites, nix expression files - relative to the recipe
    ## (`recipeSourceName`), so the binary describes whichever copy of the
    ## recipe runs it. Nim's own line information is always absolute, even
    ## for a compile run in the recipe's directory with a relative module.
  reproRecipeAnchors* {.strdefine.} = ""
    ## The compile's anchors (`effectiveAnchors`), `:`-separated.

proc normalizedKey(path: string): string =
  ## The lexical spelling every comparison here uses: `os.normalizedPath`,
  ## forward slashes, no trailing separator. Only ever applied directly to a
  ## path with no `..` component (`foldedPath` is the entry point for the
  ## rest), where it cannot pop anything and is therefore exact.
  result = os.normalizedPath(path).replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc isSeparator(c: char): bool {.inline.} =
  ## A path separator as the kernel splits components: `\` only on
  ## Windows. On POSIX `a\..\b` is ONE component, which a fold must leave
  ## alone; were it split there, `foldedPath` and `rebasedName` would pop
  ## `a` and name a different file from the one the kernel opens.
  when defined(windows):
    c == '/' or c == '\\'
  else:
    c == '/'

proc hasParentComponent(path: string): bool =
  ## Whether any component of `path` is `..`. A pure scan, so the paths
  ## without one — every ordinary observed input — never reach the
  ## filesystem in `foldedPath`.
  var start = 0
  for i in 0 .. path.len:
    if i == path.len or path[i].isSeparator:
      if i - start == 2 and path[start] == '.' and path[start + 1] == '.':
        return true
      start = i + 1
  false

proc isRealDirectory(path: string): bool =
  ## Whether `path` is, by `lstat`, an existing directory that is NOT a
  ## symlink: the only component a `..` after it may pop lexically. A
  ## failed `lstat` answers false, which keeps the `..` unfolded.
  try:
    getFileInfo(path, followSymlink = false).kind == pcDir
  except OSError:
    false

proc foldedPath*(path: string): tuple[path: string; exact: bool] =
  ## `path` with `.` components and duplicate and trailing separators
  ## removed, `\\` spelled `/` on Windows, and every `..` folded — but only
  ## where folding it names the file the kernel would reach. (A path with
  ## no `..` keeps `normalizedKey`'s spelling, which turns `\\` into `/` on
  ## every platform, as these names always have.)
  ##
  ## Monitor-Hook-Shim.md §"Metadata, Probe, And Symlink APIs": "`..` after
  ## a link applies to where the link points, not to the text before it",
  ## and "Never pop a symlink component lexically". With `link ->
  ## sub/target`, `/root/link/../file` is `/root/sub/file` to the kernel and
  ## `/root/file` to `os.normalizedPath`. So a `..` pops the component
  ## before it only when `lstat` shows that component to be an existing
  ## directory that is not a symlink; a `..` at the root stays at the root,
  ## as it does for the kernel, and a leading `..` of a relative path is
  ## kept.
  ##
  ## `exact` is false when some `..` could not be folded that way: the
  ## component before it is a symlink, absent, not a directory, or could not
  ## be examined, or the path is relative (there is no directory to examine
  ## it in). `path` is then the input UNCHANGED, because the only spelling
  ## that still names what the kernel would reach is the one that keeps the
  ## `..` for the kernel to resolve. Callers keep that spelling rather than
  ## invent a lexical one.
  ##
  ## A path with no `..` component is folded purely lexically and never
  ## touches the filesystem, so its result and its cost are what
  ## `os.normalizedPath` alone gives.
  if not hasParentComponent(path):
    return (normalizedKey(path), true)
  let text =
    when defined(windows): path.replace('\\', '/')
    else: path
  var prefix = ""
  var rest = text
  when defined(windows):
    if text.startsWith("//"):
      # A UNC root (`//server/share`) has components that are not
      # directories to pop; nothing in a recipe compile is reached that
      # way, so do not guess.
      return (path, false)
    if text.len >= 2 and text[1] == ':' and text[0].isAlphaAscii:
      if text.len >= 3 and text[2] == '/':
        prefix = text[0 .. 2]
        rest = text[3 .. ^1]
      else:
        # Drive-relative (`C:foo`): relative to a per-drive cwd.
        return (path, false)
  if prefix.len == 0 and text.startsWith("/"):
    prefix = "/"
    rest = text[1 .. ^1]
  var parts: seq[string] = @[]
  for component in rest.split('/'):
    if component.len == 0 or component == ".":
      continue
    if component != "..":
      parts.add(component)
      continue
    if parts.len == 0 or parts[^1] == "..":
      if prefix.len > 0:
        continue # `..` at the root is the root
      parts.add("..") # a leading `..` of a relative path is kept
      continue
    if prefix.len == 0:
      return (path, false)
    when nimvm:
      # The Nim VM has no `lstat`. The only compile-time caller is
      # `recipeSourceName`, on Nim's line-information filenames, which the
      # compiler spells without `..`, so this branch is not reached in
      # practice; were it reached, an unfolded `..` keeps the name absolute,
      # which costs only relocatability.
      return (path, false)
    else:
      if not isRealDirectory(prefix & parts.join("/")):
        return (path, false)
    parts.setLen(parts.len - 1)
  result = (prefix & parts.join("/"), true)
  if result.path.len == 0:
    result.path = "."

proc isWithin(path, root: string): bool =
  root == "/" or path == root or path.startsWith(root & "/")

proc effectiveAnchors*(base: string; anchors: openArray[string]): seq[string] =
  ## `anchors` normalized, minus every anchor that contains `base` (an anchor
  ## around the recipe itself — a recipe checked into the reprobuild tree, a
  ## fixture under the home directory — would otherwise pin the recipe's own
  ## files to one location) and every relative or root anchor.
  ##
  ## Anchors and `base` are folded lexically here, not through
  ## `foldedPath`. They are roots the engine composes (`absolutePath` of
  ## configured directories, already `normalizedPath`ed into the edge's argv
  ## by `recipeCompileRelocationAnchors`); the result is part of the edge's
  ## identity, which must not depend on the state of the filesystem; and an
  ## anchor spelt differently from what the kernel reaches costs only
  ## relocatability, never soundness. A path it wrongly anchors keeps its
  ## absolute name, which the lookup `lstat`s as spelled; a path it fails to
  ## anchor is named relative to `base`, and `rebasedName` resolves that
  ## name against the consulting tree without folding through a symlink.
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
  ##
  ## A path whose `..` cannot be folded exactly (`foldedPath`) — one that
  ## follows a symlink, as the shims record `open("link/../file")` — is
  ## also returned unchanged: no lexical name relative to `base` is known to
  ## reach the file the kernel opened, and an absolute name the lookup
  ## `lstat`s as spelled does. That costs relocatability for that input
  ## only. The same holds for a `base` that cannot be folded.
  ##
  ## A relative name that climbs out of `base` (`../x`) is kept only if
  ## `rebasedName` resolves it, at `base`, back to the observed file.
  ## `relativePath` spells the climb lexically, but `rebasedName` folds a
  ## `..` only where `lstat` shows a real directory: with `base` a symlink
  ## (or under one that the climb pops), `../x` would revalidate a file
  ## beside the link's target, and an edit to the file observed would be
  ## served from the record. Such a path is returned unchanged. At compile
  ## time (`recipeSourceName`) there is no `lstat`, and the climb is kept as
  ## spelled, as it always was.
  if path.len == 0 or not path.isAbsolute or base.len == 0 or
      not base.isAbsolute:
    return path
  let (key, exact) = foldedPath(path)
  if not exact:
    return path
  for anchor in anchors:
    if key.isWithin(anchor):
      return path
  let (baseKey, baseExact) = foldedPath(base)
  if not baseExact:
    return path
  let relative =
    try: relativePath(key, baseKey)
    except CatchableError: ""
  if relative.len == 0 or relative.isAbsolute:
    return path
  if hasParentComponent(relative):
    when nimvm:
      discard
    else:
      let (back, backExact) = foldedPath(baseKey & "/" & relative)
      if not backExact or cmpPaths(back, key) != 0:
        return path
  relative

proc rebasedName*(name, base: string): string =
  ## The inverse of `relocatableName` at the location `base`: a relative
  ## name resolved against it, an absolute one unchanged.
  ##
  ## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
  ## compiles": a relative recorded name resolves against the CONSULTING
  ## location, so its `..` components are folded against THAT tree
  ## (`foldedPath`), never lexically: a `../config.nims` from a real
  ## directory folds, but a `..` that follows a symlink in the consulting
  ## copy is kept, and the result is `base` and `name` joined as spelled for
  ## the kernel to resolve. (`os.joinPath` is not that join: it folds a
  ## `..` in its tail lexically.) A name with no `..` is resolved exactly as
  ## it always was, without touching the filesystem.
  if name.len == 0 or name.isAbsolute or base.len == 0:
    return name
  let joined =
    if base[^1].isSeparator: base & name
    else: base & "/" & name
  if not hasParentComponent(joined):
    return os.normalizedPath(base / name)
  let (folded, exact) = foldedPath(joined)
  if exact:
    os.normalizedPath(folded)
  else:
    joined

proc recipeSourceName*(file: string): string {.compileTime.} =
  ## A DSL source site (`lineInfoObj().filename`, always absolute) as the
  ## compiled program records it. In a recipe-relative provider compile
  ## (`reproRecipeRelative`) a file outside the anchors is named relative to
  ## the main module's directory - the recipe - which is the provider's
  ## working directory when it runs (Provider-Runtime-Protocol-v1.md, "Paths
  ## in responses"). Everywhere else the name is unchanged.
  when reproRecipeRelative:
    let base = getProjectPath()
    var anchors: seq[string] = @[]
    for anchor in reproRecipeAnchors.split(':'):
      if anchor.len > 0:
        anchors.add(anchor)
    relocatableName(file, base, effectiveAnchors(base, anchors))
  else:
    file

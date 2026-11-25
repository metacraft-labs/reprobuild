## Naming the skew between a recipe compile's reprobuild DSL and a newer
## reprobuild recipe the compile would include.
##
## A consumer recipe that says `uses: "<selector>"` with `../<selector>/repro.nim`
## beside it compiles that sibling's recipe as part of its own compile
## (`usesImportCode`, Cross-Repo-Source-Consumption.md §9.2). When the sibling
## is a reprobuild source tree NEWER than the DSL doing the compile, its recipe
## calls DSL procs with parameters that DSL does not have, and the compile used
## to die inside the sibling's `repro.nim` with a raw Nim `type mismatch`,
## and the only remedy printed, `repro lock refresh`, ran the same old engine
## and failed the same way. The rule
## (Cross-Repo-Source-Consumption.md §9.2a): such a producer is refused before
## its recipe is compiled, with a diagnostic naming both builds and the remedy.
##
## This module is that rule's one implementation. The macro layer runs it at
## compile time, before it emits the include of a producer (the only point
## where the producers a compile includes are known exactly, because only
## there are they resolved). It therefore asks the file system only through
## `fileExists` and `readFile`, which the Nim VM provides, and reads a
## checkout's `HEAD` from its git directory (`checkoutHeadRevision`) rather
## than running git.
##
## The engine runs `parseEngineRecipeSkew` at run time: the diagnostic carries
## one machine-readable record line (`EngineRecipeSkewRecordPrefix`), written
## by `engineOlderThanSiblingRecipeMessage` and read back here, so a caller
## that sees the failed compile's text (the pre-push gate's dependency-set
## stage) recovers the typed `EngineRecipeSkew` instead of matching compiler
## wording.

import std/strutils
from std/os import `/`, fileExists, parentDir
from ./reprobuild_packages_catalog import checkoutHeadRevision

const
  ReprobuildSourceTreeMarker* = "libs/repro_project_dsl/src/repro_project_dsl.nim"
    ## The file that makes a directory a reprobuild source tree: the DSL's
    ## umbrella module. A producer root carrying it ships its own DSL, so its
    ## recipe is written against that DSL's version.
  ReprobuildVersionModule* = "libs/repro_core/src/repro_core.nim"
    ## Where a reprobuild source tree states its version
    ## (`const ReprobuildVersion* {.strdefine.} = "<version>"`).
  ReprobuildNimbleFile* = "reprobuild.nimble"
    ## The tree's nimble file (`version = "<version>"`); read when the version
    ## module does not state one. `tests/unit/t_version.nim` keeps the two in
    ## agreement.
  EngineRecipeSkewRecordPrefix* = "[engine-recipe-skew v1 "
    ## Opens the record line `engineOlderThanSiblingRecipeMessage` appends;
    ## the line ends with `]`. The payload between them is hex, so no path or
    ## revision can end it early.
  UnknownIdentity = "unknown"

type
  EngineRecipeSkew* = object
    ## A recipe compile whose DSL is older than a reprobuild recipe it would
    ## include.
    engineVersion*: string      ## the version of the DSL source the compile uses
    engineRevision*: string     ## the engine image's source revision, or ""
    enginePath*: string         ## the engine image that runs the compile, or ""
    engineSourceRoot*: string   ## the reprobuild source tree the DSL comes from
    siblingVersion*: string     ## the producer tree's version
    siblingRevision*: string    ## the producer checkout's HEAD, or ""
    siblingRoot*: string        ## the producer's project root
    selector*: string           ## the `uses:` selector that reached it
    consumerRecipe*: string     ## the recipe whose `uses:` names it
    workspaceRoot*: string      ## the directory the producer was found under

proc versionLiteralAfter(text, prefix: string): string =
  ## The first double-quoted string on the first line of `text` that starts
  ## with `prefix` (after indentation), or "".
  for raw in text.splitLines():
    let line = raw.strip()
    if not line.startsWith(prefix):
      continue
    let open = line.find('"', prefix.len)
    if open < 0:
      continue
    let close = line.find('"', open + 1)
    if close > open + 1:
      return line[open + 1 ..< close]

proc reprobuildVersionLiteral*(versionModuleText: string): string =
  ## The release literal `repro_core.nim` declares
  ## (`const ReprobuildVersion* {.strdefine.} = "0.2.33"`), or "".
  versionLiteralAfter(versionModuleText, "const ReprobuildVersion*")

proc nimbleVersionLiteral*(nimbleText: string): string =
  ## The `version = "<v>"` of a nimble file, or "".
  for raw in nimbleText.splitLines():
    let line = raw.strip()
    if line.startsWith("version") and line.find('=') > 0 and
        line[0 ..< line.find('=')].strip() == "version":
      return versionLiteralAfter(line, "version")

proc isReprobuildSourceTree*(root: string): bool =
  root.len > 0 and fileExists(root / ReprobuildSourceTreeMarker)

proc reprobuildSourceTreeVersion*(root: string): string =
  ## The version a reprobuild source tree at `root` states, or "" when `root`
  ## is not one or states none. The version module is read first because it
  ## is what an image built from the tree reports (`repro --version`).
  if not isReprobuildSourceTree(root):
    return
  let module = root / ReprobuildVersionModule
  if fileExists(module):
    result = reprobuildVersionLiteral(readFile(module))
  if result.len == 0 and fileExists(root / ReprobuildNimbleFile):
    result = nimbleVersionLiteral(readFile(root / ReprobuildNimbleFile))

proc parseVersionCore(v: string): tuple[ok: bool; parts: seq[int];
    prerelease: string] =
  ## `MAJOR.MINOR.PATCH[-pre][+build]` (https://semver.org/). Missing
  ## trailing components read as 0; anything else that is not a number makes
  ## the version unreadable.
  var core = v.strip()
  if core.startsWith("v"): core = core[1 .. ^1]
  let plus = core.find('+')
  if plus >= 0: core = core[0 ..< plus]
  let dash = core.find('-')
  if dash >= 0:
    result.prerelease = core[dash + 1 .. ^1]
    core = core[0 ..< dash]
  if core.len == 0:
    return
  for piece in core.split('.'):
    if piece.len == 0 or not piece.allCharsInSet(Digits):
      return
    try:
      result.parts.add(parseInt(piece))
    except ValueError:
      return
  result.ok = true

proc compareVersions*(a, b: string): tuple[comparable: bool; order: int] =
  ## Semantic-version order of `a` and `b`: `order` < 0, 0 or > 0 as `a` is
  ## older than, equal to or newer than `b`. `comparable` is false when
  ## either does not read as a version; such a pair is never ordered.
  ## A pre-release precedes its release (semver §11); two pre-releases of one
  ## release are ordered by their text.
  let x = parseVersionCore(a)
  let y = parseVersionCore(b)
  if not x.ok or not y.ok:
    return (false, 0)
  result.comparable = true
  for i in 0 ..< max(x.parts.len, y.parts.len):
    let l = if i < x.parts.len: x.parts[i] else: 0
    let r = if i < y.parts.len: y.parts[i] else: 0
    if l != r:
      result.order = cmp(l, r)
      return
  if x.prerelease == y.prerelease:
    return
  if x.prerelease.len == 0:
    result.order = 1
  elif y.prerelease.len == 0:
    result.order = -1
  else:
    result.order = cmp(x.prerelease, y.prerelease)

proc detectEngineRecipeSkew*(dslRoot, dslVersion, producerRoot: string):
    tuple[skewed: bool; skew: EngineRecipeSkew] =
  ## Whether a compile whose DSL is reprobuild `dslVersion` (from the tree at
  ## `dslRoot`) must refuse to include the recipe at `producerRoot`: true
  ## exactly when `producerRoot` is a reprobuild source tree stating a
  ## version newer than `dslVersion`. A producer that is not a reprobuild
  ## tree, states no readable version, or is the DSL's own tree is never
  ## refused: the rule is about the one skew this module can measure.
  ## `skew` carries the two trees' identities; the caller adds who asked.
  if producerRoot.len == 0 or not isReprobuildSourceTree(producerRoot):
    return
  let producerVersion = reprobuildSourceTreeVersion(producerRoot)
  let order = compareVersions(producerVersion, dslVersion)
  if not order.comparable or order.order <= 0:
    return
  result.skewed = true
  result.skew = EngineRecipeSkew(
    engineVersion: dslVersion,
    engineSourceRoot: dslRoot,
    siblingVersion: producerVersion,
    siblingRevision: checkoutHeadRevision(producerRoot),
    siblingRoot: producerRoot)

proc orUnknown(s: string): string =
  if s.len > 0: s else: UnknownIdentity

proc recordFields(skew: EngineRecipeSkew): seq[(string, string)] =
  @[("engine-version", skew.engineVersion),
    ("engine-revision", skew.engineRevision),
    ("engine-path", skew.enginePath),
    ("engine-source-root", skew.engineSourceRoot),
    ("sibling-version", skew.siblingVersion),
    ("sibling-revision", skew.siblingRevision),
    ("sibling-root", skew.siblingRoot),
    ("selector", skew.selector),
    ("consumer-recipe", skew.consumerRecipe),
    ("workspace-root", skew.workspaceRoot)]

proc engineRecipeSkewRemedy*(skew: EngineRecipeSkew): string =
  ## What to run instead: the repro the newer pin provides. Not
  ## `repro lock refresh`, which runs this same engine and fails the same way.
  let anchorRoot =
    if skew.workspaceRoot.len > 0: skew.workspaceRoot else: "<workspace-root>"
  "run the repro the newer pin provides: re-enter the dev shell " &
    "(`direnv reload` or `nix develop`) or build it (`nix build .#default` " &
    "in " & orUnknown(skew.siblingRoot) & "), then re-anchor the hooks with " &
    "that build (`<that build>/bin/repro hooks ensure --vcs --re-anchor " &
    anchorRoot & "`) and run the command again"

proc engineOlderThanSiblingRecipeMessage*(skew: EngineRecipeSkew): string =
  ## The refusal, ending in the record line `parseEngineRecipeSkew` reads.
  let recipe = skew.siblingRoot / "repro.nim"
  result = "the running reprobuild engine is older than the sibling recipe " &
    "it imports: " & orUnknown(skew.consumerRecipe) & " uses \"" &
    skew.selector & "\", whose recipe " & recipe & " is reprobuild " &
    skew.siblingVersion & " (revision " & orUnknown(skew.siblingRevision) &
    "), but this compile's reprobuild DSL is " & skew.engineVersion &
    " (engine " & orUnknown(skew.enginePath) & ", revision " &
    orUnknown(skew.engineRevision) & ", DSL source " &
    orUnknown(skew.engineSourceRoot) & "). The older DSL cannot compile the " &
    "newer recipe, so it was not compiled. Remedy: " &
    engineRecipeSkewRemedy(skew) & ".\n"
  var payload = ""
  for (key, value) in skew.recordFields():
    payload.add(key & "=" & value & "\n")
  result.add(EngineRecipeSkewRecordPrefix & toHex(payload) & "]")

proc parseEngineRecipeSkew*(text: string):
    tuple[found: bool; skew: EngineRecipeSkew] =
  ## The skew a failed compile's output reports, read from the record line
  ## `engineOlderThanSiblingRecipeMessage` wrote; `found` is false when the
  ## text carries none (the failure had another cause).
  let start = text.find(EngineRecipeSkewRecordPrefix)
  if start < 0:
    return
  let payloadStart = start + EngineRecipeSkewRecordPrefix.len
  let close = text.find(']', payloadStart)
  if close < 0:
    return
  var payload: string
  try:
    payload = parseHexStr(text[payloadStart ..< close])
  except ValueError:
    return
  for line in payload.splitLines():
    let eq = line.find('=')
    if eq <= 0:
      continue
    let value = line[eq + 1 .. ^1]
    case line[0 ..< eq]
    of "engine-version": result.skew.engineVersion = value
    of "engine-revision": result.skew.engineRevision = value
    of "engine-path": result.skew.enginePath = value
    of "engine-source-root": result.skew.engineSourceRoot = value
    of "sibling-version": result.skew.siblingVersion = value
    of "sibling-revision": result.skew.siblingRevision = value
    of "sibling-root": result.skew.siblingRoot = value
    of "selector": result.skew.selector = value
    of "consumer-recipe": result.skew.consumerRecipe = value
    of "workspace-root": result.skew.workspaceRoot = value
    else: discard
  result.found = result.skew.siblingVersion.len > 0 and
    result.skew.engineVersion.len > 0

proc thisTreeRoot(): string {.compileTime.} =
  ## The reprobuild source tree this module was compiled from: the directory
  ## that holds `libs/repro_project_dsl/src/repro_project_dsl/`.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

const
  DslSourceRoot* = thisTreeRoot()
    ## The reprobuild tree whose DSL this compile uses. The skew check
    ## compares against it, not against the engine binary's own version: a
    ## compile pointed at a newer source tree (`REPROBUILD_SOURCE_ROOT`) has
    ## the newer DSL and is not skewed.
  DslVersion* = reprobuildVersionLiteral(
    staticRead("../../../repro_core/src/repro_core.nim"))
    ## That tree's own version literal.

## Lowering a gated install plan into Reprobuild recipes
## (`Remix-Protocol.md` §"Install planning (M6)", activation step 1; the
## open half of M2 deliverable 1).
##
## For every original package the plan patches, the original's from-source
## recipe is copied into a scratch catalog directory named after the
## composition, the plan's patches for that package are written beside it
## in plan order, and the recipe's `autotools_package` / `cmake_package` /
## `meson_package` call gains `srcPatches` commands that apply them with
## `git apply -p<strip>`. Building that catalog with `repro build` (with
## `REPRO_FROM_SOURCE_ROOT` pointing at it) produces the patched package.
##
## Each patch command is idempotent (`git apply -R --check` first) because
## a recipe's fetch step may re-extract sources while a configure step is
## replayed from cache.
##
## What this prototype does not lower, it reports instead of dropping:
## configuration contributions and graph fragments land in
## `LoweredCatalog.notLowered`, and a caller must refuse to activate while
## that list is non-empty. Patches against non-catalog source repositories,
## recipes that already carry `srcPatches`, and recipes built by another
## constructor are refused.

import std/[algorithm, os, strutils, tables]

import ./types
import ./identity
import ./composition
import ./install

type
  LoweredPackage* = object
    package*: string
    recipeDir*: string
      ## The scratch copy to build.
    patchFiles*: seq[string]
      ## In application order.

  LoweredCatalog* = object
    root*: string
      ## `REPRO_FROM_SOURCE_ROOT` for the build.
    packages*: seq[LoweredPackage]
    notLowered*: seq[string]
      ## Plan items this lowering does not yet turn into graph edges.

const PatchConstructors = ["autotools_package(", "cmake_package(", "meson_package("]

proc shellQuote(s: string): string =
  "'" & s.replace("'", "'\\''") & "'"

proc applyCommand(patchRel: string; strip: uint8): string =
  ## One idempotent `git apply`, run from the recipe root inside `src`.
  ## Git is isolated from any enclosing repository and from user config.
  let p = shellQuote("../" & patchRel)
  "(cd src && export GIT_CEILING_DIRECTORIES=\"$PWD/..\" GIT_CONFIG_NOSYSTEM=1 " &
    "GIT_CONFIG_GLOBAL=/dev/null; git apply -R --check -p" & $strip & " " & p &
    " 2>/dev/null || git apply -p" & $strip & " --whitespace=nowarn " & p & ")"

proc nimString(s: string): string =
  ## A Nim string literal for `s`.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    else: result.add c
  result.add "\""

proc rewriteRecipe*(recipe: string; commands: seq[string]): string =
  ## Add `git` to the native build dependencies and the patch commands to
  ## the package constructor. Refuses recipes it cannot rewrite safely.
  if "srcPatches" in recipe:
    refuse(rrForbiddenContent, "the recipe already has srcPatches; merging is not supported yet")
  var at = -1
  var ctor = ""
  for c in PatchConstructors:
    let i = recipe.find(c)
    if i >= 0:
      if at >= 0:
        refuse(rrForbiddenContent, "the recipe calls more than one package constructor")
      at = i
      ctor = c
  if at < 0:
    refuse(rrForbiddenContent, "the recipe is not built by autotools, cmake or meson")
  let deps = recipe.find("nativeBuildDeps:")
  if deps < 0:
    refuse(rrForbiddenContent, "the recipe declares no nativeBuildDeps block")
  if at < deps:
    refuse(rrForbiddenContent, "the package constructor precedes nativeBuildDeps; not a recipe shape this rewrites")
  var lit = "@["
  for i, c in commands:
    if i > 0: lit.add ", "
    lit.add nimString(c)
  lit.add "]"
  result = recipe
  # Insert the patch argument first (it is after nativeBuildDeps in every
  # recipe shape this accepts), then the dependency, so offsets stay valid.
  let argAt = at + ctor.len
  result.insert("srcPatches = " & lit & ", ", argAt)
  let lineEnd = result.find('\n', deps)
  result.insert("\n    \"git\"  # Remix lowering: applies the composition's patches", lineEnd)

proc lowerPlan*(plan: InstallPlan; outRoot: string;
                recipeDir: proc (package: string): string;
                blobs: proc (id: Digest32): (bool, seq[byte])): LoweredCatalog =
  ## Write the scratch catalog for `plan` under `outRoot/<composition id>`.
  plan.requireGated()
  let comp = plan.composition
  result.root = outRoot / toHex(comp.id)
  if comp.plan.configuration.len > 0:
    result.notLowered.add $comp.plan.configuration.len & " configuration contribution(s)"
  if comp.plan.graphFragments.len > 0:
    result.notLowered.add $comp.plan.graphFragments.len & " graph fragment(s)"
  # Group patch steps by target, keeping plan order (already canonical).
  var byTarget = initOrderedTable[string, seq[PatchStep]]()
  for step in comp.plan.patches:
    if step.target.startsWith("source:"):
      refuse(rrForbiddenContent, "patches to non-catalog source repositories are not lowered yet")
    byTarget.mgetOrPut(step.target, @[]).add step
  for target, steps in byTarget:
    let package = target[0 ..< target.find('@')]
    let src = recipeDir(package)
    if src.len == 0 or not fileExists(src / "repro.nim"):
      refuse(rrMissingBlob, "no from-source recipe for " & package)
    let dst = result.root / package
    removeDir(dst)
    createDir(dst / "remix")
    for kind, path in walkDir(src):
      let name = path.extractFilename
      if name == ".repro": continue
      if kind == pcFile: copyFile(path, dst / name)
      elif kind == pcDir: copyDir(path, dst / name)
    var lowered = LoweredPackage(package: package, recipeDir: dst)
    var commands: seq[string]
    for i, step in steps:
      let (found, bytes) = blobs(step.patch.blob.id)
      if not found:
        refuse(rrMissingBlob, "patch blob " & toHex(step.patch.blob.id) & " is unavailable")
      if blobId(bytes) != step.patch.blob.id:
        refuse(rrDigestMismatch, "patch blob does not match its digest")
      let rel = "remix" / (align($(i + 1), 4, '0') & "-" & toHex(step.member)[0 ..< 12] & ".patch")
      var s = newString(bytes.len)
      for j, b in bytes: s[j] = char(b)
      writeFile(dst / rel, s)
      lowered.patchFiles.add rel
      commands.add applyCommand(rel, step.patch.strip)
    writeFile(dst / "repro.nim", rewriteRecipe(readFile(dst / "repro.nim"), commands))
    result.packages.add lowered

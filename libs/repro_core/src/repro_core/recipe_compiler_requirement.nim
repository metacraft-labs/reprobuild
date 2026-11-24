## The Nim release a recipe compile requires.
##
## Operator decision of 2026-11-24 (reprobuild-pm
## `issues/2026-10-20-interface-extraction-nimcache-name-exceeds-name-max-for-deep-recipe-paths.md`):
## recipe compilation, which is interface extraction and the provider compile,
## REQUIRES Nim 2.2.10. Nim 2.2.4 names a module's generated C file after its
## path relative to the project only, so a recipe at a deep path makes a file
## name longer than NAME_MAX and the compile dies with `cannot open`; Nim
## 2.2.6 and later also weigh the `--path` roots, which is what lets the
## engine keep those names short
## (https://github.com/nim-lang/Nim/blob/v2.2.10/compiler/modulepaths.nim).
##
## This module holds the number and the refusal, with no I/O, so every place
## that meets a compiler version (a lock's provider pin, an explicit
## `REPRO_NIM_COMPILER`) says the same thing.

import std/[strutils]

const
  RecipeCompilerMinimumVersion* = "2.2.10"
    ## The oldest Nim a recipe compile accepts. A newer release (the
    ## dev shell's 2.3.x fork) is accepted.
  RecipeCompilerDecision* = "operator decision of 2026-11-24"

type
  RecipeCompilerTooOldError* = object of CatchableError
    ## A compiler older than `RecipeCompilerMinimumVersion` was named for a
    ## recipe compile. The message says which, where it came from, and how to
    ## fix it.

proc parseNimVersionTriple*(version: string): array[3, int] =
  ## `"2.2.10"` -> `[2, 2, 10]`. A component that is missing or not a number
  ## reads as -1, so the result never compares as a valid release; callers
  ## use `isNimVersion` first.
  result = [-1, -1, -1]
  let parts = version.strip().split('.')
  for i in 0 ..< min(3, parts.len):
    var digits = ""
    for c in parts[i]:
      if c in Digits: digits.add(c)
      else: break
    if digits.len > 0:
      result[i] = parseInt(digits)

proc isNimVersion*(version: string): bool =
  ## Whether `version` reads as at least `major.minor.patch`.
  let triple = parseNimVersionTriple(version)
  triple[0] >= 0 and triple[1] >= 0 and triple[2] >= 0

proc nimVersionAtLeast*(version, minimum: string): bool =
  ## Numeric, component by component: `2.2.10` is newer than `2.2.4`
  ## (a string compare gets that backwards). False when either does not
  ## read as a version.
  if not isNimVersion(version) or not isNimVersion(minimum):
    return false
  let a = parseNimVersionTriple(version)
  let b = parseNimVersionTriple(minimum)
  for i in 0 ..< 3:
    if a[i] != b[i]:
      return a[i] > b[i]
  true

proc parseNimCompilerVersionOutput*(output: string): string =
  ## The release in `nim --version` output ("Nim Compiler Version 2.2.10
  ## [Linux: amd64]"), or "" when the output is not a Nim compiler's. A stub
  ## that prints something else is therefore not judged.
  const marker = "Nim Compiler Version "
  let at = output.find(marker)
  if at < 0:
    return ""
  var version = ""
  for c in output[at + marker.len .. ^1]:
    if c in Digits or c == '.': version.add(c)
    else: break
  if isNimVersion(version): version else: ""

proc recipeCompilerRefusal*(version, source: string): string =
  ## "" when `version` may compile a recipe, otherwise the refusal text.
  ## A version that does not parse is not refused: nothing is known against
  ## it. `source` says where the compiler came from ("the lock pins ...",
  ## "$REPRO_NIM_COMPILER names ...").
  if not isNimVersion(version) or
      nimVersionAtLeast(version, RecipeCompilerMinimumVersion):
    return ""
  source & " Nim " & version & ", but recipe compilation requires Nim " &
    RecipeCompilerMinimumVersion & " or newer (" & RecipeCompilerDecision &
    "). Nim " & version & " names a module's generated C file after its " &
    "path relative to the project only, so a recipe at a deep path makes " &
    "a file name longer than the filesystem allows and the compile fails " &
    "with `cannot open`. Remove the older pin or `REPRO_NIM_COMPILER`, or " &
    "point it at Nim " & RecipeCompilerMinimumVersion & " or newer " &
    "(reprobuild-pm issues/2026-10-20-interface-extraction-nimcache-name-" &
    "exceeds-name-max-for-deep-recipe-paths.md)."

proc requireRecipeCompilerVersion*(version, source: string) =
  ## Raises `RecipeCompilerTooOldError` with `recipeCompilerRefusal`'s text.
  let refusal = recipeCompilerRefusal(version, source)
  if refusal.len > 0:
    raise newException(RecipeCompilerTooOldError, refusal)

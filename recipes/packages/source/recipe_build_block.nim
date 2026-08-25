## Test-support helpers for the ``recipes/packages/source/*`` from-source
## recipe smoke tests.
##
## ## Why this module exists
##
## M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry together
## with the ``mesonOptions:`` / ``cmakeFlags:`` / ``configureFlags:`` /
## ``makeFlags:`` DSL sections that fed it. At that point the 82 recipe
## smoke tests that pinned each recipe's per-channel build flags lost their
## observation surface and their assertions were replaced with ``check
## true``, which reports ``[OK]`` while proving nothing.
##
## The PROPERTY those tests pinned did not disappear with the registry. The
## flags moved one layer down, into each recipe's explicit ``build:`` block,
## where they are handed to one of the M9.R.2b Layer-1 constructors
## (``meson_package`` / ``cmake_package`` / ``autotools_package``). The DSL's
## M4 emitter records every recognised ``build:`` block verbatim as
## ``DslBuildAction.bodyRepr`` and exposes it through the production
## accessor ``registeredBuildActions``. That is the surface these helpers
## read, so the recipe tests can pin the same property again.
##
## ## Not a mock
##
## Nothing here stubs, fakes or reimplements any part of the DSL. The input
## is the AST the ``package`` macro actually captured from the recipe under
## test, obtained through the same public accessor the M9.R.5b sweep test
## and the M9.R.10b synthesis-wiring test already use. The helpers only
## slice that text: strip comment lines, locate the options sequence the
## build block hands to its constructor, and report which Layer-1
## constructors the block calls.
##
## ## What can and cannot be asserted
##
## ``declaredBuildOptions`` reports ``complete = false`` when the recipe's
## options sequence contains a non-literal element (a host-derived target
## triple, a resolver-provided include path, ...). Recipes in that shape can
## only be pinned on their statically declared literals; the tests that
## consume them say so in place rather than silently asserting less than
## their name claims.

import std/[strutils]

import repro_project_dsl

type
  BuildOptions* = object
    ## The options sequence a recipe's ``build:`` block hands to its
    ## Layer-1 package constructor.
    values*: seq[string]
      ## Every string literal element, in declared order.
    complete*: bool
      ## True when EVERY element of the sequence was a string literal, so
      ## ``values`` is the whole sequence rather than a projection of it.
    found*: bool
      ## True when an options sequence was located at all.

const LayerOneConstructors* = [
  "meson_package",
  "cmake_package",
  "autotools_package",
]
  ## The M9.R.2b Layer-1 package constructors. A from-source recipe routes
  ## its build through exactly one of them, or through raw ``shell``
  ## actions and none of them.

proc stripCommentLines(text: string): string =
  ## Drop whole-line ``#`` and ``##`` comments. ``NimNode.repr`` renders doc
  ## comments back into the block text, and several recipes explain their
  ## flag choices in prose that quotes the flags themselves — matching
  ## against un-stripped text would let a deleted flag keep passing because
  ## the comment above it still mentions it.
  var kept: seq[string] = @[]
  for line in text.splitLines:
    if line.strip().startsWith("#"):
      continue
    kept.add(line)
  kept.join("\n")

proc packageBuildBlockCode*(packageName: string): string =
  ## The package-level ``build:`` block of ``packageName``, comment lines
  ## removed. Empty when the recipe declares no package-level ``build:``
  ## block.
  ##
  ## ``registerBuildAction`` is deliberately non-collapsing (see its doc
  ## comment), so importing a recipe module can append the same row more
  ## than once. Identical repeats are folded here; genuinely different
  ## blocks are concatenated.
  var seen: seq[string] = @[]
  for action in registeredBuildActions(packageName):
    if action.artifactName.len != 0:
      continue
    let code = stripCommentLines(action.bodyRepr)
    if code notin seen:
      seen.add(code)
  seen.join("\n")

proc identifierBoundary(text: string; index: int): bool =
  if index <= 0:
    return true
  let c = text[index - 1]
  not (c.isAlphaNumeric or c == '_')

proc buildBlockConstructors*(packageName: string): seq[string] =
  ## Which Layer-1 package constructors the recipe's ``build:`` block calls,
  ## in ``LayerOneConstructors`` order, without repeats.
  ##
  ## This is the post-M9.R.6.1 form of the retired per-channel flag
  ## registry's channel-isolation property: a recipe drives exactly one
  ## upstream build system, so exactly one constructor may appear.
  let code = packageBuildBlockCode(packageName)
  for ctor in LayerOneConstructors:
    let needle = ctor & "("
    var index = code.find(needle)
    while index >= 0:
      if identifierBoundary(code, index):
        result.add(ctor)
        break
      index = code.find(needle, index + 1)

proc buildBlockPassesArgument*(packageName, argName: string): bool =
  ## True when the recipe's ``build:`` block passes ``argName = ...`` as a
  ## NAMED ARGUMENT to a call, rather than merely binding a local of that
  ## name.
  ##
  ## Used by the per-channel isolation tests: an autotools recipe whose
  ## flags reached the make step would pass ``makeVars = ...`` /
  ## ``installMakeVars = ...`` to ``autotools_package``, and one recipe
  ## (iproute2) happens to bind a LOCAL called ``makeVars`` that it then
  ## hands to ``configureOptions`` — the two must not be confused.
  let code = packageBuildBlockCode(packageName)
  var index = code.find(argName)
  while index >= 0:
    block candidate:
      if not identifierBoundary(code, index):
        break candidate
      var after = index + argName.len
      while after < code.len and code[after] in {' ', '\t'}:
        after += 1
      if after >= code.len or code[after] != '=':
        break candidate
      if after + 1 < code.len and code[after + 1] == '=':
        break candidate
      # Reject ``let <argName> = ...`` / ``var <argName> = ...`` bindings.
      var before = index
      while before > 0 and code[before - 1] in {' ', '\t'}:
        before -= 1
      let head = code[max(0, before - 4) ..< before]
      if head.endsWith("let") or head.endsWith("var"):
        break candidate
      return true
    index = code.find(argName, index + 1)
  false

proc parseSeqLiteral(code: string; start: int): BuildOptions =
  ## Parse a ``@[ ... ]`` sequence constructor starting at ``start`` (the
  ## index just past the opening bracket). String literals are collected;
  ## any other element marks the result incomplete.
  result.found = true
  result.complete = true
  var i = start
  var depth = 1
  while i < code.len:
    let c = code[i]
    case c
    of '"':
      var value = ""
      var j = i + 1
      while j < code.len and code[j] != '"':
        if code[j] == '\\' and j + 1 < code.len:
          # Re-fold the escapes ``repr`` emits so the reported value equals
          # the string the recipe author wrote.
          case code[j + 1]
          of 'n': value.add('\n')
          of 't': value.add('\t')
          of '\\': value.add('\\')
          of '"': value.add('"')
          else:
            value.add(code[j])
            value.add(code[j + 1])
          j += 2
          continue
        value.add(code[j])
        j += 1
      result.values.add(value)
      i = j + 1
    of '[':
      depth += 1
      i += 1
    of ']':
      depth -= 1
      if depth == 0:
        return
      i += 1
    of ' ', '\t', '\n', '\r', ',':
      i += 1
    else:
      result.complete = false
      i += 1

proc declaredBuildOptions*(packageName: string; optionsVar = ""): BuildOptions =
  ## The options sequence the recipe's ``build:`` block declares.
  ##
  ## ``optionsVar`` names the local the block binds the sequence to
  ## (``opts`` in the overwhelming majority of recipes). Left empty, the
  ## first ``let``/``var`` sequence binding in the block is used.
  ##
  ## "First sequence binding" is not a guess: across all 78 option-bearing
  ## from-source recipes, the first ``let``/``var ... = @[...]`` in the
  ## ``build:`` block is exactly the local handed to the constructor's
  ## ``configureOptions`` / ``cacheVars`` argument -- checked mechanically
  ## over the corpus, with zero exceptions. Recipes that also bind a
  ## ``srcPatches`` or ``makeVars`` sequence bind it AFTER the options.
  ## A recipe that breaks the convention makes its test fail on the
  ## ``values`` comparison rather than pass on the wrong sequence.
  let code = packageBuildBlockCode(packageName)
  var search = 0
  while search < code.len:
    let letIndex = code.find("let ", search)
    let varIndex = code.find("var ", search)
    var head = -1
    if letIndex >= 0 and (varIndex < 0 or letIndex < varIndex):
      head = letIndex
    elif varIndex >= 0:
      head = varIndex
    if head < 0 or not identifierBoundary(code, head):
      if head < 0:
        return
      search = head + 4
      continue
    var nameEnd = head + 4
    while nameEnd < code.len and
        (code[nameEnd].isAlphaNumeric or code[nameEnd] == '_'):
      nameEnd += 1
    let name = code[head + 4 ..< nameEnd].strip()
    let rest = code[nameEnd ..< min(code.len, nameEnd + 8)]
    let opensSeq = rest.strip().startsWith("= @[")
    if opensSeq and (optionsVar.len == 0 or name == optionsVar):
      let openIndex = code.find("@[", nameEnd) + 2
      return parseSeqLiteral(code, openIndex)
    search = nameEnd

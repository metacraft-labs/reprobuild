## How a package selector string becomes a Nim identifier and a module name.
##
## A package's name is a selector string, as a ``uses:`` selector is: it may
## start with a digit (``7zip``), carry punctuation (``dotnet-sdk``) or be a
## Nim keyword (``nil``). The ``package`` macro derives every identifier it
## emits — the package value, the ``<Title>Package`` type — and the
## ``repro_dsl_stdlib/packages/<module>`` basename ``usesImportCode`` imports
## from that string through ``selectorModuleName``. The catalog harvester
## names the module it writes for a name that is not a Nim identifier with
## the same function, so that module is the one ``usesImportCode`` would
## import for the name.
##
## ``isNimIdentifier`` is the one answer to "can this name be written bare
## as Nim code?" that the macro, the harvester and the home-profile editor
## share, so none of them can accept a keyword the lexer rejects.
##
## A ``std``-only leaf, so the harvester can name modules without compiling
## the whole DSL.

import std/strutils

const IdentifierEscapePrefix* = "pkg_"
  ## Prefixed to a sanitized name that cannot stand as a Nim identifier or
  ## module name as it is, for either of two reasons: it would begin with a
  ## digit (``7zip`` -> ``pkg_7zip``), which neither may, or it is a Nim
  ## keyword (``nil`` -> ``pkg_nil``), which the lexer never reads as an
  ## identifier. The prefixed form is neither: it starts with a letter, and
  ## no Nim keyword starts with ``pkg``.

# Nim's reserved words, from the manual's §"Identifiers & Keywords"
# (https://nim-lang.org/docs/manual.html#lexical-analysis-identifiers-amp-keywords),
# the same set as the compiler's ``wordrecg`` keyword range and the
# ``nimKeywords`` table in ``lib/packages/docutils/highlite.nim``. Each was
# checked against the compiler (``var <word> = 1`` fails with ``identifier
# expected, but got 'keyword <word>'``).
const NimKeywords* = [
  "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard",
  "distinct", "div", "do", "elif", "else", "end", "enum", "except",
  "export", "finally", "for", "from", "func", "if", "import", "in",
  "include", "interface", "is", "isnot", "iterator", "let", "macro",
  "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
  "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
  "template", "try", "tuple", "type", "using", "var", "when", "while",
  "xor", "yield"]

proc isNimKeyword*(word: string): bool =
  ## True when the Nim lexer reads ``word`` as a keyword rather than an
  ## identifier. Nim compares identifiers — keywords included — style
  ## insensitively: the first character exactly, the rest ignoring case and
  ## underscores (manual §"Identifier equality"). So ``nIL``, ``n_il`` and
  ## ``is_not`` are the keywords ``nil`` and ``isnot``, while ``Nil`` is an
  ## identifier, because every keyword starts with a lowercase letter.
  if word.len == 0:
    return false
  var normalized = newStringOfCap(word.len)
  normalized.add(word[0])
  for i in 1 ..< word.len:
    if word[i] != '_':
      normalized.add(word[i].toLowerAscii())
  normalized in NimKeywords

proc isNimIdentifier*(name: string): bool =
  ## True when ``name`` can be written bare as a Nim identifier: it starts
  ## with a letter or ``_``, holds only letters, digits and single ``_``,
  ## does not end with ``_``, and is not a keyword (``isNimKeyword``).
  ## ``std/strutils.validIdentifier`` checks only the character classes, so
  ## it accepts ``nil`` and ``a__b``, both of which the lexer rejects.
  if not name.validIdentifier():
    return false
  if name[^1] == '_' or "__" in name:
    return false
  not isNimKeyword(name)

proc selectorModuleName*(selector: string): string =
  ## Lowercase ``snake_case`` spelling of ``selector``: every run of
  ## non-alphanumeric characters becomes one ``_``, a lower-to-upper case
  ## change inserts one (``myEmptyPkg`` -> ``my_empty_pkg``), and a name
  ## that would begin with a digit or is a Nim keyword gets
  ## ``IdentifierEscapePrefix`` (``7zip`` -> ``pkg_7zip``, ``nil`` ->
  ## ``pkg_nil``, ``is-not`` -> ``pkg_is_not``). A selector with no
  ## alphanumeric character maps to ``package``. The result is always a
  ## valid Nim identifier (``isNimIdentifier``).
  var previousWasWord = false
  for ch in selector:
    if ch.isAlphaNumeric():
      if ch.isUpperAscii() and previousWasWord and
          result.len > 0 and result[^1] != '_':
        result.add('_')
      result.add(ch.toLowerAscii())
      previousWasWord = true
    else:
      if result.len > 0 and result[^1] != '_':
        result.add('_')
      previousWasWord = false
  while result.len > 0 and result[^1] == '_':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "package"
  elif result[0].isDigit() or isNimKeyword(result):
    result = IdentifierEscapePrefix & result

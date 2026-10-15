## How a package selector string becomes a Nim identifier and a module name.
##
## A package's name is a selector string, as a ``uses:`` selector is: it may
## start with a digit (``7zip``) or carry punctuation (``dotnet-sdk``). The
## ``package`` macro derives every identifier it emits — the package value,
## the ``<Title>Package`` type — and the ``repro_dsl_stdlib/packages/<module>``
## basename ``usesImportCode`` imports from that string through
## ``selectorModuleName``. The catalog harvester names the module it writes
## for a name that is not a Nim identifier with the same function, so that
## module is the one ``usesImportCode`` would import for the name.
##
## A ``std``-only leaf, so the harvester can name modules without compiling
## the whole DSL.

import std/strutils

const DigitLeadPrefix* = "pkg_"
  ## Prefixed to a sanitized name that would otherwise begin with a digit:
  ## neither a Nim identifier nor a Nim module name may.

proc selectorModuleName*(selector: string): string =
  ## Lowercase ``snake_case`` spelling of ``selector``: every run of
  ## non-alphanumeric characters becomes one ``_``, a lower-to-upper case
  ## change inserts one (``myEmptyPkg`` -> ``my_empty_pkg``), and a name
  ## that would begin with a digit gets ``DigitLeadPrefix``
  ## (``7zip`` -> ``pkg_7zip``). A selector with no alphanumeric character
  ## maps to ``package``. The result is always a valid Nim identifier.
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
  elif result[0].isDigit():
    result = DigitLeadPrefix & result

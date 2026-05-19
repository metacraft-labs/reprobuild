## Exception types raised by the home profile intent layer.
##
## Each exception carries enough structured context that a CLI can format
## a useful diagnostic without re-parsing the underlying file.

import std/strutils

type
  EHomeIntent* = object of CatchableError
    ## Common base for every diagnostic this library raises. Carries the
    ## file path (when known) so error formatting can attach a source
    ## location uniformly.
    profilePath*: string

  ENoProfile* = object of EHomeIntent
    ## The expected `home.nim` does not exist at the resolved profile
    ## directory. Recoverable: the caller (CLI) decides whether to
    ## scaffold a new profile or surface this as an error. The resolved
    ## directory and the path that was probed are both embedded.
    profileDir*: string

  EUnstructured* = object of EHomeIntent
    ## The parser saw a top-level form, an activity body element, or a
    ## conditional shape it cannot recognize, OR the recognized patterns
    ## are obscured by user control flow (a `for` loop building an
    ## activity body, etc.). The structural editor refuses to touch
    ## the file in this case.
    line*: int          ## 1-based line number
    column*: int        ## 1-based column number; 0 if column unknown
    seen*: string       ## a short, literal description of what was seen
    expected*: string   ## what the parser expected at this position

  EUnknownPredicate* = object of EHomeIntent
    ## A predicate identifier appeared in a `when`/`if` clause that is
    ## not in the standard set and was not found in any of the searched
    ## user modules. The identifier and the list of searched module
    ## paths are both attached.
    identifier*: string
    searchedModules*: seq[string]
    line*: int
    column*: int

  EUnknownConfigurable* = object of EHomeIntent
    ## `setConfigurable` was called for a `<pkg>.<configurable>` pair
    ## whose configurable name is not declared by the package's
    ## Configurable schema (consulted through the injected lookup proc).
    package*: string
    configurable*: string

  EInvalidConfigurable* = object of EHomeIntent
    ## `setConfigurable` was called with a string that is not in the
    ## `<pkg>.<configurable>` form.
    raw*: string

  EProfileWriteError* = object of EHomeIntent
    ## A write to the profile file failed at the filesystem level.

proc raiseNoProfile*(profileDir, expectedPath: string) {.noreturn.} =
  var e = newException(ENoProfile,
    "no home.nim found at '" & expectedPath & "'")
  e.profileDir = profileDir
  e.profilePath = expectedPath
  raise e

proc raiseUnstructured*(profilePath: string; line: int; column: int;
                        seen, expected: string) {.noreturn.} =
  var msg = "unstructured profile at " & profilePath & ":" & $line
  if column > 0:
    msg.add ":" & $column
  msg.add " — saw " & seen & "; expected " & expected
  var e = newException(EUnstructured, msg)
  e.profilePath = profilePath
  e.line = line
  e.column = column
  e.seen = seen
  e.expected = expected
  raise e

proc raiseUnknownPredicate*(profilePath, identifier: string;
                            line, column: int;
                            searchedModules: seq[string]) {.noreturn.} =
  var msg = "unknown predicate identifier '" & identifier & "' at " &
    profilePath & ":" & $line
  if searchedModules.len > 0:
    msg.add " (searched: " & searchedModules.join(", ") & ")"
  var e = newException(EUnknownPredicate, msg)
  e.profilePath = profilePath
  e.identifier = identifier
  e.line = line
  e.column = column
  e.searchedModules = searchedModules
  raise e

proc raiseUnknownConfigurable*(profilePath, package,
                               configurable: string) {.noreturn.} =
  var e = newException(EUnknownConfigurable,
    "configurable '" & configurable & "' is not declared by package '" &
    package & "'")
  e.profilePath = profilePath
  e.package = package
  e.configurable = configurable
  raise e

proc raiseInvalidConfigurable*(raw: string) {.noreturn.} =
  var e = newException(EInvalidConfigurable,
    "configurable name '" & raw &
    "' is not in '<package>.<configurable>' form")
  e.raw = raw
  raise e

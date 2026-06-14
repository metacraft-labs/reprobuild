## Structured exception types raised by the B1 system-scope DSL parser
## + lowering pass. Mirrors the home-profile intent-layer error shape:
## every exception carries enough context (file path, 1-based line,
## 1-based column, "saw / expected" pair, optional secondary detail)
## that the CLI can render a diagnostic without re-parsing the file.
##
## All exceptions inherit `ESystemConfig` so a single `except
## ESystemConfig` clause catches every B1-emitted diagnostic.

import std/strutils

type
  ESystemConfig* = object of CatchableError
    configPath*: string                ## the file the diagnostic refers
                                       ## to; empty when the diagnostic
                                       ## predates parsing (e.g.
                                       ## "file not found")

  ENoConfig* = object of ESystemConfig
    ## The expected `configuration.nim` does not exist.
    expectedPath*: string

  EUnstructured* = object of ESystemConfig
    ## The parser saw a line it cannot interpret (unknown keyword, bad
    ## indent, malformed expression on the right-hand side).
    line*: int                         ## 1-based
    column*: int                       ## 1-based; 0 if column unknown
    seen*: string
    expected*: string

  EMissingRequiredField* = object of ESystemConfig
    ## A required field on a sub-record was omitted (e.g. a mount with
    ## no `source = ...` line, a user with no `shell = ...`).
    section*: string                   ## "user" / "mount" / ...
    key*: string                       ## the record's identifier in
                                       ## that section (user name,
                                       ## mount point, ...)
    field*: string                     ## the missing field name
    line*: int

  EUnknownForeignDistro* = object of ESystemConfig
    ## A `package(<distro>, ...)` call passed a distro name outside the
    ## closed set in `types.KnownForeignDistros`.
    distro*: string
    line*: int

  EMalformedSnapshot* = object of ESystemConfig
    ## A Tier 3 `package(..., snapshot = "...")` carried a snapshot
    ## string that doesn't match the
    ## `<distro>/<release>/<rfc3339-compact>` shape.
    raw*: string
    line*: int

  EUnknownService* = object of ESystemConfig
    ## A `services:` entry referenced a unit name with an unrecognized
    ## suffix or shape (e.g. `enable "foo.bar"` — `.bar` is not a
    ## known systemd unit type).
    unit*: string
    line*: int

  EUnknownFstype* = object of ESystemConfig
    ## A `mount` entry's `fstype = ...` value is outside the closed
    ## set in `types.KnownFstypes`.
    fstype*: string
    line*: int

  ECircularImport* = object of ESystemConfig
    ## An `imports:` block declares a path whose transitive imports
    ## reach back to a file already on the import stack.
    cycle*: seq[string]                ## the cycle, in
                                       ## stack order; first and last
                                       ## entries are identical.

  EImportNotFound* = object of ESystemConfig
    ## An `imports:` block referenced a path that doesn't resolve to a
    ## readable file relative to the importing file's directory.
    importPath*: string
    resolvedPath*: string

proc raiseUnstructured*(configPath: string; line, column: int;
                        seen, expected: string) {.noreturn.} =
  var msg = "unstructured config at " & configPath & ":" & $line
  if column > 0:
    msg.add ":" & $column
  msg.add " - saw " & seen & "; expected " & expected
  var e = newException(EUnstructured, msg)
  e.configPath = configPath
  e.line = line
  e.column = column
  e.seen = seen
  e.expected = expected
  raise e

proc raiseMissingRequiredField*(configPath, section, key, field: string;
                                line: int) {.noreturn.} =
  var msg = "missing required field '" & field &
    "' on " & section
  if key.len > 0:
    msg.add " '" & key & "'"
  msg.add " at " & configPath & ":" & $line
  var e = newException(EMissingRequiredField, msg)
  e.configPath = configPath
  e.section = section
  e.key = key
  e.field = field
  e.line = line
  raise e

proc raiseUnknownForeignDistro*(configPath, distro: string;
                                line: int) {.noreturn.} =
  var e = newException(EUnknownForeignDistro,
    "unknown foreign-package distro '" & distro &
    "' at " & configPath & ":" & $line &
    " (known: apt, dnf, pacman)")
  e.configPath = configPath
  e.distro = distro
  e.line = line
  raise e

proc raiseMalformedSnapshot*(configPath, raw: string;
                             line: int) {.noreturn.} =
  var e = newException(EMalformedSnapshot,
    "malformed snapshot pin '" & raw &
    "' at " & configPath & ":" & $line &
    " (expected: <distro>/<release>/<rfc3339-compact>)")
  e.configPath = configPath
  e.raw = raw
  e.line = line
  raise e

proc raiseUnknownService*(configPath, unit: string;
                          line: int) {.noreturn.} =
  var e = newException(EUnknownService,
    "unknown service unit '" & unit &
    "' at " & configPath & ":" & $line)
  e.configPath = configPath
  e.unit = unit
  e.line = line
  raise e

proc raiseUnknownFstype*(configPath, fstype: string;
                         line: int) {.noreturn.} =
  var e = newException(EUnknownFstype,
    "unknown fstype '" & fstype &
    "' at " & configPath & ":" & $line)
  e.configPath = configPath
  e.fstype = fstype
  e.line = line
  raise e

proc raiseCircularImport*(configPath: string;
                          cycle: seq[string]) {.noreturn.} =
  var e = newException(ECircularImport,
    "circular import detected: " & cycle.join(" -> "))
  e.configPath = configPath
  e.cycle = cycle
  raise e

proc raiseImportNotFound*(configPath, importPath,
                          resolvedPath: string) {.noreturn.} =
  var e = newException(EImportNotFound,
    "import '" & importPath & "' resolved to '" &
    resolvedPath & "' but the file does not exist")
  e.configPath = configPath
  e.importPath = importPath
  e.resolvedPath = resolvedPath
  raise e

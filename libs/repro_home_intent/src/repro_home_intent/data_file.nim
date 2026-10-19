## Plan-time data files (GM4): the fixed row schema, its reader and the
## structural editor's row writer.
##
## A profile's `data:` section names TOML files beside `home.nim`
## (Gradual-Nix-To-Reprobuild-Migration.md §Declarative data files read at
## plan time). The profile binary records the names only; `repro home
## plan` / `apply` / `export` read the files through `readDataFile` and the
## planner merges the rows into the intent
## (`repro_profile_compile/data_expansion`). Nix reads the same files with
## `builtins.fromTOML` and selects rows with the same semantics (GM5).
##
## The schema is FIXED, not a query language. A data file holds two kinds
## of row. A package reference:
##
## ```toml
## [[package]]
## name = "ghostty"           # canonical Reprobuild package name (required)
## activity = "desktop_apps"  # the activity the reference joins (required)
## when = "macos"             # built-in predicate grammar only (optional)
## version = "1.2.3"          # literal version pin (optional)
## binaries = ["ghostty"]     # binary names, when they differ (optional)
## ```
##
## A row is exactly the activity-body line `package(<name>, "<version>",
## binaries = @[...])` placed in `activity <activity>:`, under
## `when <when>:` when given.
##
## And a resource:
##
## ```toml
## [[resource]]
## kind = "fs.userFile"             # selects the resource constructor
## when = "linux"                   # built-in predicate grammar only (optional)
## activity = "desktop_core"        # the activity it belongs to (optional, GM9)
## hostFile = "~/.config/foo.conf"  # the constructor's own parameters
## content = "bar = 1\n"
## ```
##
## A resource row is exactly the call `fsUserFile(hostFile = ..., content =
## ...)` in `resources:`, under `when <when>:` when given: it is built by
## calling that constructor (`repro_profile/resource_rows`), whose parameter
## list is the row's schema. A row without an `activity` key is profile-wide,
## like an entry of the profile-level `resources:`; with `activity = "<name>"`
## it belongs to that activity (GM9), like a call in a `resources:` block
## inside `activity <name>:`. Which rows apply on a host is therefore the
## planner's ordinary rule (the host's activities, then the guard) — there
## is no per-file selection expression to keep in step across Reprobuild
## and Nix. Anything the schema does not define — another top-level key,
## another row key, a value of the wrong type, a `when` naming a
## user-defined predicate (which has no evaluator outside the profile's Nim
## code) — is rejected with `EDataFile`, never skipped
## (Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped).

import std/[os, strutils, tables]
from repro_core/paths import extendedPath

import toml_serialization
import toml_serialization/types as toml_types

import repro_profile/types
import repro_profile/resource_rows

import ./errors
import ./predicate

const
  DataRowTable* = "package"
    ## Package rows: `[[package]]`.
  ResourceRowTable* = "resource"
    ## Resource rows: `[[resource]]`.
  PackageRowKeys* = ["name", "activity", "when", "version", "binaries"]
    ## The closed key set of a `[[package]]` row.

type
  DataPackageRow* = object
    ## One `[[package]]` row, validated.
    name*: string         ## canonical package name
    activity*: string     ## activity the reference joins
    whenPredicate*: string
      ## The `when` field as written ("" = every host). Validated by
      ## `validateBuiltinPredicate`; the planner carries it as the guard.
    version*: string      ## literal version pin, "" for none
    binaries*: seq[string]

  DataFile* = object
    ## A data file as the planner read it.
    path*: string         ## the reference, relative to the profile dir
    content*: string      ## the bytes read (recorded in the generation)
    rows*: seq[DataPackageRow]
    resources*: seq[ResourceIntent]
      ## The `[[resource]]` rows, each already built by its constructor and
      ## carrying its `when` as the canonical guard.

  DataFileRows* = object
    packages*: seq[DataPackageRow]
    resources*: seq[ResourceIntent]

proc isPackageNameChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '+', '-'}

proc packageNameProblem*(name: string): string =
  ## Why `name` cannot be a canonical package name in a data row, or "".
  ## The character set is the one canonical package names use (letters,
  ## digits, `.`, `_`, `+`, `-`); nothing here can smuggle Nim or TOML
  ## syntax into a generated profile line or a Nix attribute lookup.
  if name.len == 0:
    return "the package name is empty"
  for c in name:
    if not isPackageNameChar(c):
      return "`" & name & "` contains '" & $c & "'; a canonical package " &
        "name uses letters, digits, `.`, `_`, `+` and `-`"
  ""

proc activityNameProblem*(name: string): string =
  ## Why `name` cannot name an activity, or "". Activities are Nim
  ## identifiers in `home.nim` (`activity desktop_apps:`), so a row may only
  ## name one that could be declared there.
  if name.len == 0:
    return "the activity name is empty"
  if name[0] notin {'a'..'z', 'A'..'Z'}:
    return "`" & name & "` must start with a letter"
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return "`" & name & "` contains '" & $c & "'; an activity name " &
        "uses letters, digits and `_`"
  ""

proc stringField(profilePath, dataPath: string; row: int; key: string;
                 value: TomlValueRef): string =
  if value.kind != TomlKind.String:
    raiseDataFile(profilePath, dataPath, row, key,
      "expected a string, got " & $value.kind)
  value.stringVal

proc validateRowGuard(profilePath, dataPath: string; row: int;
                      predicate: string) =
  ## A row's `when`: non-empty and of the built-in predicate grammar only.
  if predicate.strip().len == 0:
    raiseDataFile(profilePath, dataPath, row, "when",
      "an empty predicate; omit the key for every host")
  try:
    discard validateBuiltinPredicate(predicate, dataPath, row)
  except EUnknownPredicate as e:
    raiseDataFile(profilePath, dataPath, row, "when",
      "`" & predicate & "` names '" & e.identifier &
      "', which is not a built-in predicate; data files accept only " &
      "windows, macos, linux, bsd, wsl, x86_64, arm64, arm32 and " &
      "host ==/!=/in, combined with and/or/not (a user-defined " &
      "predicate has no evaluator outside the profile's Nim code)")
  except EUnstructured as e:
    raiseDataFile(profilePath, dataPath, row, "when",
      "`" & predicate & "` is not a valid predicate: " &
      e.seen & "; expected " & e.expected)

proc tomlFieldValue(profilePath, dataPath: string; row: int; key: string;
                    value: TomlValueRef): FieldValue =
  ## A resource row's value as the constructor-facing `FieldValue`. Only
  ## the plain data a constructor parameter can take is accepted.
  case value.kind
  of TomlKind.String: strField(value.stringVal)
  of TomlKind.Bool: boolField(value.boolVal)
  of TomlKind.Int: intField(int(value.intVal))
  of TomlKind.Array:
    var items: seq[string]
    for item in value.arrayVal:
      if item.kind != TomlKind.String:
        raiseDataFile(profilePath, dataPath, row, key,
          "expected an array of strings, got an element of kind " &
          $item.kind)
      items.add item.stringVal
    listField(items)
  else:
    raiseDataFile(profilePath, dataPath, row, key,
      "a resource row value must be a string, boolean, integer or array " &
      "of strings, got " & $value.kind)

proc decodeResourceRow(profilePath, dataPath: string; row: int;
                       table: TomlTableRef): ResourceIntent =
  ## Build the resource a `[[resource]]` row declares by calling its
  ## constructor (`constructResourceRow`); every schema decision is the
  ## constructor's.
  let label = dataPath
  if not table[].hasKey("kind"):
    raiseDataFile(profilePath, label, row, "kind", "required key missing " &
      "(resource row)")
  let kindNode = table[]["kind"]
  if kindNode.kind != TomlKind.String:
    raiseDataFile(profilePath, label, row, "kind",
      "expected a string, got " & $kindNode.kind)
  var guard = ""
  var activity = ""
  var fields: ResourceRowFields
  for key, value in table[].pairs:
    case key
    of "kind": discard
    of "when":
      if value.kind != TomlKind.String:
        raiseDataFile(profilePath, label, row, key,
          "expected a string, got " & $value.kind)
      validateRowGuard(profilePath, label, row, value.stringVal)
      guard = canonicalize(value.stringVal)
    of "activity":
      # GM9: the row belongs to this activity, as a call inside
      # `activity <name>: resources:` does; omitted = profile-wide.
      activity = stringField(profilePath, label, row, key, value)
      let problem = activityNameProblem(activity)
      if problem.len > 0:
        raiseDataFile(profilePath, label, row, key, problem)
    else:
      fields[key] = tomlFieldValue(profilePath, label, row, key, value)
  # Keys in a stable order so a diagnostic does not depend on hashing.
  fields.sort(proc (a, b: (string, FieldValue)): int = cmp(a[0], b[0]))
  try:
    result = constructResourceRow(kindNode.stringVal, fields, guard)
  except EResourceRow as e:
    raiseDataFile(profilePath, label, row, e.key,
      "resource row: " & e.msg)
  result.activity = activity

proc decodeRow(profilePath, dataPath: string; row: int;
               table: TomlTableRef): DataPackageRow =
  for key, value in table[].pairs:
    if key notin PackageRowKeys:
      raiseDataFile(profilePath, dataPath, row, key,
        "unknown key; a `[[" & DataRowTable & "]]` row has " &
        PackageRowKeys.join(", "))
    case key
    of "name":
      result.name = stringField(profilePath, dataPath, row, key, value)
    of "activity":
      result.activity = stringField(profilePath, dataPath, row, key, value)
    of "when":
      result.whenPredicate = stringField(profilePath, dataPath, row, key,
        value)
    of "version":
      result.version = stringField(profilePath, dataPath, row, key, value)
    of "binaries":
      if value.kind != TomlKind.Array:
        raiseDataFile(profilePath, dataPath, row, key,
          "expected an array of strings, got " & $value.kind)
      for item in value.arrayVal:
        let b = stringField(profilePath, dataPath, row, key, item)
        if b.len == 0:
          raiseDataFile(profilePath, dataPath, row, key,
            "a binary name is empty")
        result.binaries.add b
    else: discard
  if not table[].hasKey("name"):
    raiseDataFile(profilePath, dataPath, row, "name", "required key missing")
  if not table[].hasKey("activity"):
    raiseDataFile(profilePath, dataPath, row, "activity",
      "required key missing")
  let nameProblem = packageNameProblem(result.name)
  if nameProblem.len > 0:
    raiseDataFile(profilePath, dataPath, row, "name", nameProblem)
  let activityProblem = activityNameProblem(result.activity)
  if activityProblem.len > 0:
    raiseDataFile(profilePath, dataPath, row, "activity", activityProblem)
  if table[].hasKey("version") and result.version.len == 0:
    raiseDataFile(profilePath, dataPath, row, "version",
      "an empty version; omit the key for an unpinned reference")
  if table[].hasKey("when"):
    validateRowGuard(profilePath, dataPath, row, result.whenPredicate)

proc isArrayOfTables(value: TomlValueRef): bool =
  ## Whether a top-level row key holds an array of tables. TOML writes one
  ## either with `[[package]]` headers or as an inline array of inline
  ## tables (`package = [{ name = "jq", activity = "cli" }]`, or `[]`);
  ## both are the same data (https://toml.io/en/v1.0.0#array-of-tables),
  ## and Nix's `builtins.fromTOML` cannot tell them apart, so the Nix
  ## helper library's `readData` must read the same files this reader
  ## reads. Anything else (`[package]`, a scalar, an array holding a
  ## non-table) is refused.
  case value.kind
  of TomlKind.Tables: true
  of TomlKind.Array:
    for item in value.arrayVal:
      if item.kind notin {TomlKind.Table, TomlKind.InlineTable}:
        return false
    true
  else: false

proc rowTablesOf(value: TomlValueRef): seq[TomlTableRef] =
  ## The rows of a value `isArrayOfTables` accepted, in file order.
  case value.kind
  of TomlKind.Tables: value.tablesVal
  of TomlKind.Array:
    var rows: seq[TomlTableRef]
    for item in value.arrayVal:
      rows.add item.tableVal
    rows
  else: @[]

proc parseDataFileRows*(profilePath, dataPath, content: string):
    DataFileRows =
  ## Decode and validate the text of the data file `dataPath` (the
  ## reference, used in diagnostics): its package rows, and its resource
  ## rows built by their constructors. Raises `EDataFile` for anything the
  ## fixed schema does not define.
  var root: TomlValueRef
  try:
    root = Toml.decode(content, TomlValueRef)
  except TomlError as e:
    raiseDataFile(profilePath, dataPath, 0, "",
      "not valid TOML: " & (if e.msg.len > 0: e.msg else: "malformed"))
  except CatchableError as e:
    raiseDataFile(profilePath, dataPath, 0, "",
      "not valid TOML: " & (if e.msg.len > 0: e.msg else: "malformed"))
  if root.isNil or root.kind notin {TomlKind.Table, TomlKind.InlineTable}:
    raiseDataFile(profilePath, dataPath, 0, "", "the file is not a TOML table")
  for key, value in root.tableVal[].pairs:
    if key notin [DataRowTable, ResourceRowTable]:
      raiseDataFile(profilePath, dataPath, 0, key,
        "unknown top-level key; a data file holds `[[" & DataRowTable &
        "]]` and `[[" & ResourceRowTable & "]]` rows only")
    if not isArrayOfTables(value):
      raiseDataFile(profilePath, dataPath, 0, key,
        "`" & key & "` must be an array of tables (`[[" & key &
        "]]`), got " & $value.kind)
  # Package rows first, then resource rows, each in file order.
  if root.tableVal[].hasKey(DataRowTable):
    for i, table in rowTablesOf(root.tableVal[][DataRowTable]):
      result.packages.add decodeRow(profilePath, dataPath, i + 1, table)
  if root.tableVal[].hasKey(ResourceRowTable):
    for i, table in rowTablesOf(root.tableVal[][ResourceRowTable]):
      result.resources.add decodeResourceRow(profilePath,
        dataPath & " resource", i + 1, table)

proc parseDataFileText*(profilePath, dataPath, content: string):
    seq[DataPackageRow] =
  ## The package rows of a data file (validating the whole file).
  parseDataFileRows(profilePath, dataPath, content).packages

proc dataFileAbsolutePath*(profileDir, dataPath: string): string =
  ## Where the reference `dataPath` (already validated by
  ## `dataFilePathProblem`) lives on this host.
  var native = dataPath
  when defined(windows):
    native = native.replace('/', '\\')
  profileDir / native

proc readDataFile*(profilePath, profileDir, dataPath: string): DataFile =
  ## Read and validate the data file `dataPath` relative to `profileDir`.
  ## A declared file that is missing or unreadable is an error, not an
  ## empty table.
  result.path = dataPath
  let abs = dataFileAbsolutePath(profileDir, dataPath)
  if not fileExists(extendedPath(abs)):
    raiseDataFile(profilePath, dataPath, 0, "",
      "declared in the profile's `data:` section but " & abs &
      " does not exist")
  try:
    result.content = readFile(extendedPath(abs))
  except IOError, OSError:
    raiseDataFile(profilePath, dataPath, 0, "",
      "cannot read " & abs & ": " & getCurrentExceptionMsg())
  let parsed = parseDataFileRows(profilePath, dataPath, result.content)
  result.rows = parsed.packages
  result.resources = parsed.resources

# ---------------------------------------------------------------------------
# Structural editor: append a row.
# ---------------------------------------------------------------------------

proc tomlString(s: string): string =
  ## A TOML basic string (https://toml.io/en/v1.0.0#string) for `s`.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\x00'..'\x08', '\x0B', '\x0C', '\x0E'..'\x1F', '\x7F':
      result.add "\\u" & toHex(ord(c), 4)
    else: result.add c
  result.add "\""

proc renderPackageRow*(row: DataPackageRow; lineEnding = "\n"): string =
  ## The canonical TOML text of one row, keys in schema order, ending in a
  ## newline.
  result = "[[" & DataRowTable & "]]" & lineEnding
  result.add "name = " & tomlString(row.name) & lineEnding
  result.add "activity = " & tomlString(row.activity) & lineEnding
  if row.whenPredicate.len > 0:
    result.add "when = " & tomlString(row.whenPredicate) & lineEnding
  if row.version.len > 0:
    result.add "version = " & tomlString(row.version) & lineEnding
  if row.binaries.len > 0:
    var items: seq[string]
    for b in row.binaries: items.add tomlString(b)
    result.add "binaries = [" & items.join(", ") & "]" & lineEnding

proc sameRow*(a, b: DataPackageRow): bool =
  ## Two rows that declare the same reference: same package, activity,
  ## version and binaries, and guards whose normalized predicates are equal
  ## (Home-Profile-Intent-Layer.md §Predicate Normalization).
  if a.name != b.name or a.activity != b.activity or
     a.version != b.version or a.binaries != b.binaries:
    return false
  if a.whenPredicate.len == 0 or b.whenPredicate.len == 0:
    return a.whenPredicate.len == b.whenPredicate.len
  canonicalize(a.whenPredicate) == canonicalize(b.whenPredicate)

type
  AppendRowOutcome* = enum
    aroAppended        ## the row was written
    aroCreated         ## the file did not exist; it was created with the row
    aroAlreadyPresent  ## an equal row exists; the file is unchanged

proc appendPackageRow*(profilePath, profileDir, dataPath: string;
                       row: DataPackageRow): AppendRowOutcome =
  ## The structural editor's data-file edit (`repro home add --data`):
  ## validate `row` exactly as the planner will read it, validate the
  ## existing file, and append the row's canonical text at the end without
  ## touching any existing byte (comments and formatting included). The
  ## result is re-read before it is written, so a file the planner would
  ## refuse is never produced. Written atomically (temp file + rename), like
  ## `home.nim`. A missing file is created. `dataPath` must already be
  ## validated against `dataFilePathProblem` and declared by the profile.
  let abs = dataFileAbsolutePath(profileDir, dataPath)
  # The new row alone first, so its diagnostic names the row, not the file.
  let rendered = renderPackageRow(row)
  discard parseDataFileText(profilePath, dataPath & " (new row)", rendered)
  var existing = ""
  let exists = fileExists(extendedPath(abs))
  if exists:
    try:
      existing = readFile(extendedPath(abs))
    except IOError, OSError:
      raiseDataFile(profilePath, dataPath, 0, "",
        "cannot read " & abs & ": " & getCurrentExceptionMsg())
    for present in parseDataFileText(profilePath, dataPath, existing):
      if sameRow(present, row):
        return aroAlreadyPresent
  let ending = if existing.contains("\r\n"): "\r\n" else: "\n"
  var updated = existing
  if updated.len > 0:
    if not updated.endsWith("\n"):
      updated.add ending
    updated.add ending
  updated.add renderPackageRow(row, ending)
  let reread = parseDataFileText(profilePath, dataPath, updated)
  if reread.len == 0 or not sameRow(reread[^1], row):
    raiseDataFile(profilePath, dataPath, 0, "",
      "internal: the appended row does not read back as written")
  try:
    createDir(extendedPath(abs.parentDir))
    let tmp = abs & ".tmp"
    writeFile(extendedPath(tmp), updated)
    moveFile(extendedPath(tmp), extendedPath(abs))
  except IOError, OSError:
    var err = newException(EProfileWriteError,
      "writing data file " & abs & " failed: " & getCurrentExceptionMsg())
    err.profilePath = profilePath
    raise err
  if exists: aroAppended else: aroCreated

# ---------------------------------------------------------------------------
# Structural editor: remove package rows.
# ---------------------------------------------------------------------------

type
  RowSpan = object
    table: string   ## "package" / "resource"
    first: int      ## index of the `[[...]]` header line
    last: int       ## index of the row's last non-blank, non-comment line

proc headerTable(line: string): string =
  ## "package" / "resource" for a `[[package]]` / `[[resource]]` header line
  ## (trailing comment allowed), "?" for any other table header, "" for a
  ## line that is not a header.
  var text = line.strip()
  let hash = text.find('#')
  if hash >= 0 and text.startsWith("[["):
    text = text[0 ..< hash].strip()
  if not text.startsWith("["):
    return ""
  if text == "[[" & DataRowTable & "]]": return DataRowTable
  if text == "[[" & ResourceRowTable & "]]": return ResourceRowTable
  "?"

proc rowSpans(lines: seq[string]): seq[RowSpan] =
  ## The text span of every row: from its header through its last key line.
  ## Blank lines and comments between rows belong to no row.
  var i = 0
  while i < lines.len:
    let table = headerTable(lines[i])
    if table.len == 0:
      inc i
      continue
    var span = RowSpan(table: table, first: i, last: i)
    var j = i + 1
    while j < lines.len and headerTable(lines[j]).len == 0:
      let s = lines[j].strip()
      if s.len > 0 and not s.startsWith("#"):
        span.last = j
      inc j
    result.add span
    i = j

proc removePackageRows*(profilePath, profileDir, dataPath, name: string;
                        activity = ""; predicate = ""; version = ""): int =
  ## The structural editor's row removal (`repro home remove <pkg> --data
  ## FILE`): delete every `[[package]]` row naming `name` (and, when given,
  ## `activity`, a normalized-equal `predicate`, `version`) from the data
  ## file. Only the removed rows' own lines go — from the header through the
  ## row's last key line, plus the blank separator after it (before it, for
  ## the last row) — so every other row, comment and blank line keeps its
  ## bytes. The result is re-read before it is written and must hold exactly
  ## the old rows minus the removed ones; a file whose layout defeats that
  ## (rows written as inline tables, a header inside a multi-line string) is
  ## refused rather than guessed at. Returns the number of rows removed (0:
  ## the file is unchanged). Written atomically.
  let abs = dataFileAbsolutePath(profileDir, dataPath)
  if not fileExists(extendedPath(abs)):
    raiseDataFile(profilePath, dataPath, 0, "",
      abs & " does not exist")
  var content: string
  try:
    content = readFile(extendedPath(abs))
  except IOError, OSError:
    raiseDataFile(profilePath, dataPath, 0, "",
      "cannot read " & abs & ": " & getCurrentExceptionMsg())
  let before = parseDataFileRows(profilePath, dataPath, content)
  proc matches(row: DataPackageRow): bool =
    row.name == name and
      (activity.len == 0 or row.activity == activity) and
      (version.len == 0 or row.version == version) and
      (predicate.len == 0 or (row.whenPredicate.len > 0 and
        canonicalize(row.whenPredicate) == canonicalize(predicate)))
  var keep: seq[DataPackageRow]
  var removeIdx: seq[int]          # indices among the package rows
  for i, row in before.packages:
    if matches(row): removeIdx.add i
    else: keep.add row
  if removeIdx.len == 0:
    return 0
  # Lines with their terminators, so joining them back is byte-exact.
  var lines: seq[string]
  var start = 0
  for i, ch in content:
    if ch == '\n':
      lines.add content[start .. i]
      start = i + 1
  if start < content.len:
    lines.add content[start .. ^1]
  let spans = rowSpans(lines)
  var packageSpans: seq[RowSpan]
  for span in spans:
    if span.table == "?":
      raiseDataFile(profilePath, dataPath, 0, "",
        "cannot remove a row structurally: the file has a table header " &
        "other than [[" & DataRowTable & "]] / [[" & ResourceRowTable &
        "]]; edit it by hand")
    if span.table == DataRowTable:
      packageSpans.add span
  if packageSpans.len != before.packages.len:
    raiseDataFile(profilePath, dataPath, 0, "",
      "cannot remove a row structurally: the file does not write each " &
      "package row as a `[[" & DataRowTable & "]]` header; edit it by hand")
  var drop = newSeq[bool](lines.len)
  for idx in removeIdx:
    let span = packageSpans[idx]
    for l in span.first .. span.last:
      drop[l] = true
    # One blank separator goes with the row: the blank lines after it, or —
    # when nothing but blanks follows — the blank lines before it.
    var after = span.last + 1
    while after < lines.len and lines[after].strip().len == 0:
      drop[after] = true
      inc after
    if after >= lines.len:
      var b = span.first - 1
      while b >= 0 and lines[b].strip().len == 0 and not drop[b]:
        drop[b] = true
        dec b
  var updated = ""
  for i, line in lines:
    if not drop[i]:
      updated.add line
  let after = parseDataFileRows(profilePath, dataPath, updated)
  var same = after.packages.len == keep.len and
    after.resources.len == before.resources.len
  if same:
    for i in 0 ..< keep.len:
      if not sameRow(after.packages[i], keep[i]):
        same = false
  if not same:
    raiseDataFile(profilePath, dataPath, 0, "",
      "internal: removing the row would change other rows; edit by hand")
  try:
    let tmp = abs & ".tmp"
    writeFile(extendedPath(tmp), updated)
    moveFile(extendedPath(tmp), extendedPath(abs))
  except IOError, OSError:
    var err = newException(EProfileWriteError,
      "writing data file " & abs & " failed: " & getCurrentExceptionMsg())
    err.profilePath = profilePath
    raise err
  removeIdx.len

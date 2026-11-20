## Configuration written for a described program, checked against the
## program's description.
##
## A tool's `cli:` description may say which settings the tool reads from its
## configuration files: a parameter with `key = "<dotted.key>"` (or, for a
## program in clispec's own file layout, `configSchema` and every parameter's
## key). The package macro then emits, beside the tool, a constant
## `<executable>ConfigDescription`: the description's configuration keys as a
## `CliConfigTable` (clispec's `config_check` module), derived once, with
## each key's value type and closed value set.
##
## The configuration writers read that table:
##
## * at COMPILE time, a block such as `tomlContent(ctx, cargoConfigDescription):`
##   checks every key it writes, and the type of every value it writes, in one
##   compile-time evaluation per block (`snippetIssues`); an unknown key, a
##   section where a value belongs, a wrongly typed value or a literal outside
##   a closed set is a compile error naming the key, at the line that wrote
##   it;
## * at RUN time, the same block checks the value tree it built
##   (`checkStructured`), which covers what the compiler cannot see: a
##   configurable's resolved value, a `StructuredValue` built by code, a value
##   outside a closed set that only exists once evaluated. `fs.writeStructured`
##   with a description does the same for a tree built by hand, and
##   `checkConfigText` validates a whole file's text (TOML), naming the file,
##   the line and the key.
##
## Every check is a lookup in the table; none re-reads the description, so a
## recipe that writes many snippets for one tool pays for the derivation once.
##
## Only fixed keys are described. A table whose keys are names the writer
## chooses (cargo's `[source.<name>]` or `[target.<triple>]`) cannot be
## declared in a description, so a file holding one cannot be checked here:
## such "open" tables are out of scope, and a writer of such a file does not
## name a description.

import std/[macros, strutils, tables]

import clispec/config_check
import confutils/layers/toml_source

import ./structured
import ../configurables

export config_check

type
  ConfigValidationError* = object of CatchableError
    ## Configuration that does not fit the description of the program that
    ## reads it. `msg` names the document and every key that does not fit,
    ## one per line.
    issues*: seq[CliConfigIssue]
    program*: string
      ## The described program.

  SnippetField* = object
    ## One key a block writes, as the compile-time check sees it.
    path*: seq[string]
    shape*: CliConfigValue
    checked*: bool
      ## False for a value whose shape only exists at run time (a
      ## `StructuredValue`); the run-time check covers it.
    textKnown*: bool
      ## The value is a literal, so its text is known (and a closed set can
      ## be checked at compile time).

func snippetIssues*(t: CliConfigTable;
                    fields: openArray[SnippetField]): seq[CliConfigIssue] =
  ## One issue per field (`cikNone` when it fits), in one evaluation: the
  ## block macro's compile-time check reads the table once per block, not
  ## once per key.
  for f in fields:
    if f.checked:
      result.add cliCheckEntry(t, f.path, f.shape, f.textKnown)
    else:
      result.add CliConfigIssue(kind: cikNone)

proc resolvedValueOf[U](c: Configurable[U]): U =
  ## Never called: its return type names a configurable's value type.
  discard

template valueTypeOf(T: typedesc): typedesc =
  ## The type a block field's expression contributes: `Configurable[U]`
  ## contributes `U`.
  when T is Configurable: typeof(resolvedValueOf(default(T))) else: T

proc snippetField*[T](path: openArray[string]; t: typedesc[T];
                      literal: string; literalKnown: bool): SnippetField =
  ## The compile-time shape of a field whose expression has type `T`.
  type V = valueTypeOf(T)
  when V is StructuredValue:
    SnippetField(path: @path, shape: CliConfigValue(kind: ccvTable),
      checked: false)
  else:
    SnippetField(path: @path, shape: cliConfigShapeOf(V, literal),
      checked: true, textKnown: literalKnown)

func sectionField*(path: openArray[string]): SnippetField =
  ## A `name:` section of a block.
  SnippetField(path: @path, shape: CliConfigValue(kind: ccvTable),
    checked: true, textKnown: true)

func snippetErrorText*(t: CliConfigTable; writer: string;
                       issue: CliConfigIssue): string =
  ## The compile error of a field that does not fit.
  writer & ": configuration of '" & t.program & "': " &
    cliConfigIssueText(issue)

func cliValueOf(v: StructuredValue): CliConfigValue =
  case v.kind
  of svNull: CliConfigValue(kind: ccvString)
  of svBool: CliConfigValue(kind: ccvBool,
    text: (if v.boolVal: "true" else: "false"))
  of svInt: CliConfigValue(kind: ccvInteger, text: $v.intVal)
  of svFloat: CliConfigValue(kind: ccvFloat, text: $v.floatVal)
  of svString: CliConfigValue(kind: ccvString, text: v.strVal)
  of svArray:
    var r = CliConfigValue(kind: ccvArray)
    for item in v.items:
      r.items.add(if item.kind == svObject: CliConfigValue(kind: ccvTable)
                  else: cliValueOf(item))
    r
  of svObject: CliConfigValue(kind: ccvTable)

proc collectIssues(t: CliConfigTable; v: StructuredValue;
                   path: var seq[string]; issues: var seq[CliConfigIssue]) =
  for key, child in v.members:
    path.add key
    if child.kind == svObject:
      let issue = cliCheckEntry(t, path, CliConfigValue(kind: ccvTable))
      if issue.kind != cikNone:
        issues.add issue
      else:
        collectIssues(t, child, path, issues)
    elif child.kind != svNull:
      let issue = cliCheckEntry(t, path, cliValueOf(child))
      if issue.kind != cikNone:
        issues.add issue
    discard path.pop()

proc raiseIssues(t: CliConfigTable; document: string;
                 issues: seq[CliConfigIssue]) =
  var lines: seq[string] = @[]
  for issue in issues:
    lines.add cliConfigIssueMessage(issue, document)
  var e = newException(ConfigValidationError,
    "configuration of '" & t.program & "' does not fit its description:\n" &
      lines.join("\n"))
  e.issues = issues
  e.program = t.program
  raise e

proc structuredIssues*(t: CliConfigTable;
                       value: StructuredValue): seq[CliConfigIssue] =
  ## Every key of a value tree that does not fit the description, from one
  ## walk over the tree. The root must be an object (a document).
  if value.isNil or value.kind != svObject:
    return
  var path: seq[string] = @[]
  collectIssues(t, value, path, result)

proc checkStructured*(t: CliConfigTable; value: StructuredValue;
                      document: string) =
  ## Raises a `ConfigValidationError` naming `document` and every key of
  ## `value` that does not fit the description.
  let issues = structuredIssues(t, value)
  if issues.len > 0:
    raiseIssues(t, document, issues)

proc configTextIssues*(t: CliConfigTable; path, text: string;
                       format: ConfigFormat): seq[CliConfigIssue] =
  ## Every key of a whole file's text that does not fit the description,
  ## each with its line, from one pass over the parsed file. `path` names
  ## the file in messages. TOML is the format read; another format raises a
  ## `ConfigValidationError` saying so (validate its value tree before
  ## serializing it instead, with `checkStructured`).
  case format
  of cfToml:
    var doc: CliConfigDocument
    try:
      doc = parseTomlConfig(path, text)
    except CliConfigError as e:
      var err = newException(ConfigValidationError, e.msg)
      err.program = t.program
      raise err
    result = cliValidateDocument(t, doc)
  else:
    var err = newException(ConfigValidationError,
      "configuration of '" & t.program & "': whole-file validation reads " &
        "TOML only, not " & $format & "; check the value tree instead")
    err.program = t.program
    raise err

proc checkConfigText*(t: CliConfigTable; path, text: string;
                      format = cfToml) =
  ## Raises a `ConfigValidationError` naming the file, the line and the key
  ## of every entry of `text` that does not fit the description.
  let issues = configTextIssues(t, path, text, format)
  if issues.len > 0:
    raiseIssues(t, path, issues)

# ---------------------------------------------------------------------------
# Configuration value overrides: one `key=value`, as a tool takes it on its
# command line (cargo's `--config build.jobs=4`).
# ---------------------------------------------------------------------------

func overrideValueText(v: string): string =
  ## A TOML basic string (https://toml.io/en/v1.0.0#string).
  result = "\""
  for ch in v:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    elif ord(ch) < 0x20 or ord(ch) == 0x7f:
      result.add("\\u00" & toHex(ord(ch), 2))
    else: result.add(ch)
  result.add("\"")

func overrideValueText(v: bool): string = (if v: "true" else: "false")
func overrideValueText(v: SomeInteger): string = $v
func overrideValueText(v: SomeFloat): string = $v

func overrideValueOf(v: string): CliConfigValue =
  CliConfigValue(kind: ccvString, text: v)
func overrideValueOf(v: bool): CliConfigValue =
  CliConfigValue(kind: ccvBool, text: overrideValueText(v))
func overrideValueOf(v: SomeInteger): CliConfigValue =
  CliConfigValue(kind: ccvInteger, text: $v)
func overrideValueOf(v: SomeFloat): CliConfigValue =
  CliConfigValue(kind: ccvFloat, text: $v)

proc checkedOverride*[T](t: CliConfigTable; path: openArray[string];
                         key: string; value: T): string =
  ## The run-time half of `configOverride`: checks the value (its closed
  ## set, which a computed value only meets here) and renders `key=value`.
  let issue = cliCheckEntry(t, path, overrideValueOf(value))
  if issue.kind != cikNone:
    raiseIssues(t, "configuration override", @[issue])
  key & "=" & overrideValueText(value)

macro configOverride*(description: untyped; key: static[string];
                      value: untyped): string =
  ## One configuration value override for a described program, as
  ## `key=value` with the value in TOML's syntax (what cargo's `--config`
  ## takes). The key and the value's type are checked against the
  ## description at compile time, a compile error naming the key; a literal
  ## is checked against the key's closed set then too, a computed value at
  ## run time (a `ConfigValidationError`).
  let path = key.split('.')
  var pathLit = nnkBracket.newTree()
  for segment in path:
    pathLit.add newLit(segment)
  var literal = ""
  var known = false
  case value.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    literal = value.strVal
    known = true
  of nnkIntLit .. nnkInt64Lit:
    literal = $value.intVal
    known = true
  of nnkIdent:
    if value.eqIdent("true") or value.eqIdent("false"):
      literal = ($value).toLowerAscii
      known = true
  else:
    discard
  let v = genSym(nskLet, "overrideValue")
  let issue = genSym(nskConst, "overrideIssue")
  let check = nnkWhenStmt.newTree(nnkElifBranch.newTree(
    infix(newDotExpr(issue, ident"kind"), "!=", bindSym"cikNone"),
    newStmtList(nnkPragma.newTree(nnkExprColonExpr.newTree(ident"error",
      newCall(bindSym"snippetErrorText", description,
        newLit("configOverride"), issue))))))
  proc placeAt(node, site: NimNode) =
    node.copyLineInfo(site)
    for child in node:
      placeAt(child, site)
  placeAt(check, value)
  result = newStmtList(
    newLetStmt(v, value),
    nnkConstSection.newTree(nnkConstDef.newTree(issue, newEmptyNode(),
      newCall(bindSym"cliCheckEntry", description, pathLit,
        newDotExpr(newCall(bindSym"snippetField", pathLit,
          newCall(ident"typeof", v), newLit(literal), newLit(known)),
          ident"shape"),
        newLit(known)))),
    check,
    newCall(bindSym"checkedOverride", description, pathLit, newLit(key), v))
  result = newBlockStmt(result)

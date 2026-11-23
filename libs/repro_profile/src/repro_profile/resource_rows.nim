## Resource rows of plan-time data files (GM4): a `[[resource]]` row is a
## CALL of the profile's own resource constructor.
##
## A data file declared in a profile's `data:` section may hold
## `[[resource]]` rows besides `[[package]]` rows
## (Gradual-Nix-To-Reprobuild-Migration.md §Declarative data files read at
## plan time):
##
## ```toml
## [[resource]]
## kind = "fs.userFile"          # selects the constructor
## when = "linux"                # optional guard, built-in predicates only
## hostFile = "~/.config/foo.conf"
## content = "bar = 1\n"
## ```
##
## The row's schema is the constructor's signature: every key other than
## `kind` and `when` must be one of the constructor's parameters, of that
## parameter's type, required parameters must be present, and an omitted
## optional parameter takes the constructor's own default. The row is then
## turned into a `ResourceIntent` by CALLING that constructor
## (`fsUserFile(...)`), so the fields it records, their defaults and the
## auto-address are exactly what the same call in `resources:` produces —
## there is no second statement of any constructor's rules to keep in step.
## The per-kind schemas are derived at compile time from the constructors'
## parameter lists (`rowConstructor`), not written out again here.
##
## Supported kinds are the home-scope constructors whose parameters are plain
## data (`string`, `bool`, `int`, `seq[string]`). Not supported, and refused
## as unknown kinds: `windows.registryValueHKCU`, whose value kind is a Nim
## identifier (`REG_SZ`), not data; and every system-scope kind — data rows
## are home-profile intent, and system profiles refuse a `data:` section.

import std/[macros, strutils, tables]

import ./types
import ./resources

type
  EResourceRow* = object of ValueError
    ## A resource row the constructor's signature does not accept. `key` is
    ## the offending row key ("" when the problem is not key-specific).
    key*: string

  ResourceRowFields* = OrderedTable[string, FieldValue]
    ## A row's keys other than `kind` and `when`, as decoded from TOML:
    ## strings as `fvkString`, booleans `fvkBool`, integers `fvkInt`, arrays
    ## of strings `fvkList`.

  ResourceRowConstructor* = proc (target: var seq[ResourceIntent];
                                  fields: ResourceRowFields) {.nimcall.}

  ResourceRowKind* = object
    kind*: string                 ## the resource kind tag, e.g. `fs.userFile`
    parameters*: seq[string]      ## the row keys the constructor accepts
    required*: seq[string]        ## those without a default
    construct*: ResourceRowConstructor

proc rowError(key, msg: string) {.noreturn.} =
  var e = newException(EResourceRow, msg)
  e.key = key
  raise e

proc typeLabel(v: FieldValue): string =
  case v.kind
  of fvkString: "a string"
  of fvkInt: "an integer"
  of fvkBool: "a boolean"
  of fvkExpr: "an expression"
  of fvkList: "an array"

proc rowString*(fields: ResourceRowFields; key: string): string =
  let v = fields[key]
  if v.kind != fvkString:
    rowError(key, "expected a string, got " & typeLabel(v))
  v.s

proc rowBool*(fields: ResourceRowFields; key: string): bool =
  let v = fields[key]
  if v.kind != fvkBool:
    rowError(key, "expected a boolean, got " & typeLabel(v))
  v.b

proc rowInt*(fields: ResourceRowFields; key: string): int =
  let v = fields[key]
  if v.kind != fvkInt:
    rowError(key, "expected an integer, got " & typeLabel(v))
  v.i

proc rowStrings*(fields: ResourceRowFields; key: string): seq[string] =
  let v = fields[key]
  if v.kind != fvkList:
    rowError(key, "expected an array of strings, got " & typeLabel(v))
  v.items

proc checkRowKeys*(kind: string; fields: ResourceRowFields;
                   parameters, required: openArray[string]) =
  ## Every key must be a parameter of the constructor, every required
  ## parameter must be present.
  for key in fields.keys:
    if key notin parameters:
      rowError(key, "unknown key for kind `" & kind & "`; its constructor " &
        "takes " & parameters.join(", "))
  for key in required:
    if key notin fields:
      rowError(key, "required key missing (kind `" & kind & "`)")

macro rowConstructor(kind: static string; ctor: typed): untyped =
  ## Generate the `ResourceRowKind` for constructor `ctor` from its own
  ## parameter list: one row key per parameter after the target sequence,
  ## the parameter's default when the row omits the key, and a call of
  ## `ctor` with every argument named.
  let impl = ctor.getImpl
  if impl.isNil or impl.kind notin {nnkTemplateDef, nnkProcDef}:
    error("rowConstructor expects a resource constructor template", ctor)
  let formals = impl[3]
  let target = genSym(nskParam, "target")
  let fields = genSym(nskParam, "fields")
  var parameters = newNimNode(nnkBracket)
  var required = newNimNode(nnkBracket)
  var body = newStmtList()
  var call = newCall(ctor, target)
  for i in 2 ..< formals.len:   # [0] return type, [1] targetResources
    let defs = formals[i]
    let typ = defs[^2]
    let default = defs[^1]
    for j in 0 ..< defs.len - 2:
      let name = $defs[j]
      let typeText = typ.repr
      let getter =
        case typeText
        of "string": "rowString"
        of "bool": "rowBool"
        of "int": "rowInt"
        of "seq[string]": "rowStrings"
        else:
          error("rowConstructor: parameter `" & name & "` of " & kind &
            " has type " & typeText & ", which is not plain data", defs)
          ""
      parameters.add newLit(name)
      let local = genSym(nskLet, name)
      let nameLit = newLit(name)
      let read = newCall(ident(getter), fields, nameLit)
      if default.kind == nnkEmpty:
        required.add newLit(name)
        body.add newLetStmt(local, read)
      else:
        body.add newLetStmt(local, quote do:
          (if `fields`.hasKey(`nameLit`): `read` else: `default`))
      call.add newNimNode(nnkExprEqExpr).add(ident(name), local)
  let kindLit = newLit(kind)
  result = quote do:
    ResourceRowKind(kind: `kindLit`, parameters: @`parameters`,
      required: @`required`,
      construct: proc (`target`: var seq[ResourceIntent];
                       `fields`: ResourceRowFields) {.nimcall.} =
        checkRowKeys(`kindLit`, `fields`, @`parameters`, @`required`)
        `body`
        `call`)

let ResourceRowKinds*: seq[ResourceRowKind] = @[
  rowConstructor("env.userPath", envUserPath),
  rowConstructor("env.userVariable", envUserVariable),
  rowConstructor("fs.managedBlock", fsManagedBlock),
  rowConstructor("shell.integration", shellIntegration),
  rowConstructor("windows.startup", windowsStartup),
  rowConstructor("fs.userFile", fsUserFile),
  rowConstructor("systemd.userUnit", systemdUserUnit),
  rowConstructor("linux.dconfKey", linuxDconfKey),
  rowConstructor("linux.kdeConfigKey", linuxKdeConfigKey),
  rowConstructor("pkg.homebrewFormula", homebrewFormula),
  rowConstructor("pkg.homebrewCask", homebrewCask),
  rowConstructor("launchd.userAgent", launchdUserAgent),
  rowConstructor("vscode.extension", vscodeExtension)]
  ## Every kind a `[[resource]]` row may name, each with the constructor
  ## that builds it. A kind not listed here is refused.

proc resourceRowKindNames*(): seq[string] =
  for k in ResourceRowKinds:
    result.add k.kind

proc constructResourceRow*(kind: string; fields: ResourceRowFields;
                           guard = ""): ResourceIntent =
  ## Build the `ResourceIntent` a `[[resource]]` row declares by calling
  ## its kind's constructor; `guard` (canonical predicate text, "" for
  ## every host) is attached afterwards, exactly as a `when <pred>:` around
  ## the call in `resources:` would. Raises `EResourceRow` naming the key for
  ## an unknown kind, an unknown or mistyped key, or a missing required one.
  for k in ResourceRowKinds:
    if k.kind == kind:
      var built: seq[ResourceIntent]
      k.construct(built, fields)
      doAssert built.len == 1, "a resource constructor declares one resource"
      result = built[0]
      result.guard = PredicateExpr(expr: guard)
      return
  rowError("kind", "`" & kind & "` is not a resource kind a data row can " &
    "declare (known: " & resourceRowKindNames().join(", ") & ")")

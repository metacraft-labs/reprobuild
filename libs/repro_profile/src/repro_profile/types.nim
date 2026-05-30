## ProfileIntent data types for the M83 Phase A profile compilation
## model. The macros under `./macros.nim`, `./resources.nim`, and
## `./predicates.nim` build values of these types at compile time;
## `./emit.nim` serializes the result to JSON.
##
## See `reprobuild-specs/Profile-Compilation-Model.md` for the design.
## Phase A keeps the data shape JSON-friendly. Phase B replaces JSON
## with the RBPI binary envelope while keeping the same Nim-side
## record types.

import std/tables

type
  ProfileIntent* = object
    name*: string
    activities*: seq[ActivityIntent]
    configOverrides*: seq[ConfigOverride]
    hosts*: Table[string, seq[string]]
    resources*: seq[ResourceIntent]

  ActivityElementKind* = enum
    aekPackageRef
    aekWhenGuard

  ActivityElement* = object
    case kind*: ActivityElementKind
    of aekPackageRef:
      pkgName*: string
      pkgVersion*: string             ## M69: the literal version pin from
                                      ## `package(<id>, "<version>")`; "" for
                                      ## a bare identifier reference or
                                      ## the bare `package(<id>)` call form.
    of aekWhenGuard:
      predicate*: PredicateExpr
      guardedBody*: seq[ActivityElement]

  ActivityIntent* = object
    name*: string
    body*: seq[ActivityElement]

  ConfigValueKind* = enum
    cvkString
    cvkInt
    cvkBool
    cvkExpr

  ConfigValue* = object
    case kind*: ConfigValueKind
    of cvkString: s*: string
    of cvkInt: i*: int
    of cvkBool: b*: bool
    of cvkExpr: expr*: string

  ConfigOverride* = object
    pkg*: string
    key*: string
    value*: ConfigValue

  FieldValueKind* = enum
    fvkString
    fvkInt
    fvkBool
    fvkList
    fvkExpr

  FieldValue* = object
    case kind*: FieldValueKind
    of fvkString: s*: string
    of fvkInt: i*: int
    of fvkBool: b*: bool
    of fvkList: items*: seq[string]
    of fvkExpr: expr*: string

  ResourceAddress* = object
    kind*: string
    name*: string

  ResourceIntent* = object
    kind*: string         ## e.g. "fs.userFile", "windows.capability"
    address*: string      ## optional named address; empty if unset
    fields*: Table[string, FieldValue]
    dependsOn*: seq[ResourceAddress]

  PredicateExpr* = object
    expr*: string         ## canonical-stringified predicate; apply-
                          ## time parser handles evaluation

# Convenience constructors -- intentionally simple so macros can use
# them at compile time without needing to know about variant tagging
# specifics.

proc strValue*(s: string): ConfigValue =
  ConfigValue(kind: cvkString, s: s)

proc intValue*(i: int): ConfigValue =
  ConfigValue(kind: cvkInt, i: i)

proc boolValue*(b: bool): ConfigValue =
  ConfigValue(kind: cvkBool, b: b)

proc exprValue*(expr: string): ConfigValue =
  ConfigValue(kind: cvkExpr, expr: expr)

proc strField*(s: string): FieldValue =
  FieldValue(kind: fvkString, s: s)

proc intField*(i: int): FieldValue =
  FieldValue(kind: fvkInt, i: i)

proc boolField*(b: bool): FieldValue =
  FieldValue(kind: fvkBool, b: b)

proc listField*(items: seq[string]): FieldValue =
  FieldValue(kind: fvkList, items: items)

proc exprField*(expr: string): FieldValue =
  FieldValue(kind: fvkExpr, expr: expr)

proc parseResourceAddress*(s: string): ResourceAddress =
  ## Parse a `kind:name` string into a ResourceAddress. The address
  ## form mirrors the apply-time pipeline's existing convention.
  ## Empty string returns an empty address (kind == "" and name == "").
  if s.len == 0:
    return ResourceAddress(kind: "", name: "")
  let colonIdx = s.find(':')
  if colonIdx < 0:
    return ResourceAddress(kind: s, name: "")
  ResourceAddress(kind: s[0 ..< colonIdx], name: s[colonIdx + 1 .. ^1])

proc `$`*(a: ResourceAddress): string =
  if a.name.len == 0:
    a.kind
  else:
    a.kind & ":" & a.name

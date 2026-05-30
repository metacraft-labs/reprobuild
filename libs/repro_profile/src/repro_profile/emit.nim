## Serialise a `ProfileIntent` to JSON for inspection and golden-file
## testing. Phase A uses JSON as the single output format; Phase B
## introduces the RBPI binary envelope and keeps this JSON form as a
## `--debug` fallback.
##
## The encoder is hand-rolled (not `std/json`) so we can guarantee:
##   - keys are emitted in a deterministic, sorted order
##   - the byte stream is identical given identical input
##   - we control the spacing + escaping
##
## A separate decoder is exposed so the unit tests can round-trip a
## `ProfileIntent` through JSON without depending on std/json's object-
## variant gymnastics.

import std/[algorithm, json, strutils, tables]

import ./types

# ---------------------------------------------------------------------
# Encode.
# ---------------------------------------------------------------------

proc encodeStr(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    else:
      if c.int < 0x20:
        result.add "\\u"
        result.add toHex(c.int, 4).toLowerAscii()
      else:
        result.add c
  result.add "\""

proc encodeFieldValue(v: FieldValue): string =
  case v.kind
  of fvkString:
    result = "{\"kind\":\"string\",\"value\":" & encodeStr(v.s) & "}"
  of fvkInt:
    result = "{\"kind\":\"int\",\"value\":" & $v.i & "}"
  of fvkBool:
    result = "{\"kind\":\"bool\",\"value\":" & (if v.b: "true" else: "false") & "}"
  of fvkList:
    var items = "["
    for i, it in v.items:
      if i > 0:
        items.add ","
      items.add encodeStr(it)
    items.add "]"
    result = "{\"kind\":\"list\",\"value\":" & items & "}"
  of fvkExpr:
    result = "{\"kind\":\"expr\",\"value\":" & encodeStr(v.expr) & "}"

proc encodeConfigValue(v: ConfigValue): string =
  case v.kind
  of cvkString:
    result = "{\"kind\":\"string\",\"value\":" & encodeStr(v.s) & "}"
  of cvkInt:
    result = "{\"kind\":\"int\",\"value\":" & $v.i & "}"
  of cvkBool:
    result = "{\"kind\":\"bool\",\"value\":" & (if v.b: "true" else: "false") & "}"
  of cvkExpr:
    result = "{\"kind\":\"expr\",\"value\":" & encodeStr(v.expr) & "}"

proc encodeAddress(a: ResourceAddress): string =
  result = "{\"kind\":" & encodeStr(a.kind) &
    ",\"name\":" & encodeStr(a.name) & "}"

proc encodeActivityElement(e: ActivityElement): string

proc encodeActivityElementSeq(es: seq[ActivityElement]): string =
  result = "["
  for i, e in es:
    if i > 0:
      result.add ","
    result.add encodeActivityElement(e)
  result.add "]"

proc encodeActivityElement(e: ActivityElement): string =
  case e.kind
  of aekPackageRef:
    result = "{\"kind\":\"packageRef\",\"name\":" & encodeStr(e.pkgName) &
      ",\"version\":" & encodeStr(e.pkgVersion) & "}"
  of aekWhenGuard:
    result = "{\"kind\":\"whenGuard\",\"predicate\":" &
      encodeStr(e.predicate.expr) &
      ",\"body\":" & encodeActivityElementSeq(e.guardedBody) & "}"

proc encodeActivity(a: ActivityIntent): string =
  result = "{\"name\":" & encodeStr(a.name) &
    ",\"body\":" & encodeActivityElementSeq(a.body) & "}"

proc encodeConfigOverride(c: ConfigOverride): string =
  result = "{\"pkg\":" & encodeStr(c.pkg) &
    ",\"key\":" & encodeStr(c.key) &
    ",\"value\":" & encodeConfigValue(c.value) & "}"

proc encodeResource(r: ResourceIntent): string =
  result = "{\"kind\":" & encodeStr(r.kind) &
    ",\"address\":" & encodeStr(r.address) &
    ",\"fields\":{"
  var fieldKeys: seq[string] = @[]
  for k in r.fields.keys:
    fieldKeys.add k
  fieldKeys.sort(cmp[string])
  for i, k in fieldKeys:
    if i > 0:
      result.add ","
    result.add encodeStr(k)
    result.add ":"
    result.add encodeFieldValue(r.fields[k])
  result.add "},\"dependsOn\":["
  for i, dep in r.dependsOn:
    if i > 0:
      result.add ","
    result.add encodeAddress(dep)
  result.add "]}"

proc encodeHosts(h: Table[string, seq[string]]): string =
  var keys: seq[string] = @[]
  for k in h.keys:
    keys.add k
  keys.sort(cmp[string])
  result = "{"
  for i, k in keys:
    if i > 0:
      result.add ","
    result.add encodeStr(k)
    result.add ":["
    let acts = h[k]
    for j, a in acts:
      if j > 0:
        result.add ","
      result.add encodeStr(a)
    result.add "]"
  result.add "}"

proc emitProfileIntentJson*(p: ProfileIntent): string =
  ## Serialise `p` to a deterministic JSON form. Field order is
  ## fixed (name, activities, configOverrides, hosts, resources).
  ## Map keys (host names, resource fields) are emitted in sorted
  ## order. The encoder does NOT pretty-print -- one line, no spaces.
  result = "{"
  result.add "\"name\":" & encodeStr(p.name)
  result.add ",\"activities\":["
  for i, a in p.activities:
    if i > 0:
      result.add ","
    result.add encodeActivity(a)
  result.add "]"
  result.add ",\"configOverrides\":["
  for i, c in p.configOverrides:
    if i > 0:
      result.add ","
    result.add encodeConfigOverride(c)
  result.add "]"
  result.add ",\"hosts\":" & encodeHosts(p.hosts)
  result.add ",\"resources\":["
  for i, r in p.resources:
    if i > 0:
      result.add ","
    result.add encodeResource(r)
  result.add "]"
  result.add "}"

# ---------------------------------------------------------------------
# Decode (for tests + future tooling).
# ---------------------------------------------------------------------

proc parseFieldValue(n: JsonNode): FieldValue =
  let kind = n["kind"].getStr()
  case kind
  of "string": result = strField(n["value"].getStr())
  of "int": result = intField(n["value"].getInt())
  of "bool": result = boolField(n["value"].getBool())
  of "list":
    var items: seq[string] = @[]
    for it in n["value"]:
      items.add it.getStr()
    result = listField(items)
  of "expr": result = exprField(n["value"].getStr())
  else:
    raise newException(ValueError,
      "unknown FieldValue kind: '" & kind & "'")

proc parseConfigValue(n: JsonNode): ConfigValue =
  let kind = n["kind"].getStr()
  case kind
  of "string": result = strValue(n["value"].getStr())
  of "int": result = intValue(n["value"].getInt())
  of "bool": result = boolValue(n["value"].getBool())
  of "expr": result = exprValue(n["value"].getStr())
  else:
    raise newException(ValueError,
      "unknown ConfigValue kind: '" & kind & "'")

proc parseAddress(n: JsonNode): ResourceAddress =
  ResourceAddress(kind: n["kind"].getStr(), name: n["name"].getStr())

proc parseActivityElement(n: JsonNode): ActivityElement =
  let kind = n["kind"].getStr()
  case kind
  of "packageRef":
    result = ActivityElement(kind: aekPackageRef,
      pkgName: n["name"].getStr(),
      pkgVersion:
        (if n.hasKey("version"): n["version"].getStr() else: ""))
  of "whenGuard":
    var body: seq[ActivityElement] = @[]
    for it in n["body"]:
      body.add parseActivityElement(it)
    result = ActivityElement(kind: aekWhenGuard,
      predicate: PredicateExpr(expr: n["predicate"].getStr()),
      guardedBody: body)
  else:
    raise newException(ValueError,
      "unknown ActivityElement kind: '" & kind & "'")

proc parseProfileIntentJson*(s: string): ProfileIntent =
  ## Decode a JSON-emitted ProfileIntent. Used by the unit tests to
  ## round-trip the encoding. Also expected to be useful in Phase B
  ## as a debug-format reader.
  let root = parseJson(s)
  result.name = root["name"].getStr()
  for a in root["activities"]:
    var act = ActivityIntent(name: a["name"].getStr())
    for be in a["body"]:
      act.body.add parseActivityElement(be)
    result.activities.add act
  for c in root["configOverrides"]:
    result.configOverrides.add ConfigOverride(
      pkg: c["pkg"].getStr(),
      key: c["key"].getStr(),
      value: parseConfigValue(c["value"]))
  for k, v in root["hosts"]:
    var acts: seq[string] = @[]
    for it in v:
      acts.add it.getStr()
    result.hosts[k] = acts
  for r in root["resources"]:
    var ri = ResourceIntent(kind: r["kind"].getStr(),
      address: r["address"].getStr())
    for fk, fv in r["fields"]:
      ri.fields[fk] = parseFieldValue(fv)
    for dep in r["dependsOn"]:
      ri.dependsOn.add parseAddress(dep)
    result.resources.add ri

# ---------------------------------------------------------------------
# Entry-point helper.
# ---------------------------------------------------------------------

template emitProfileIntent*(p: ProfileIntent): typed =
  ## Convenience: emit the JSON form to stdout and quit. Phase A's
  ## `profile name: body` macro autogenerates a trailing invocation of
  ## this template so the user does not need a `when isMainModule:`
  ## block.
  echo emitProfileIntentJson(p)
  quit(0)

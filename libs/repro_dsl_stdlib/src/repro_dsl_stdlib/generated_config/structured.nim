## Structured-value intermediate representation for generated configuration
## files. All three coordinate approaches (`fs.writeStructured`, block macros,
## external template wrappers' helper construction) lower into this same
## `StructuredValue` tree, then route through the format-specific
## serializers.
##
## The tree preserves insertion order via `OrderedTable`, which is the
## explicit contract from `Generated-Configuration-Files.md`.

import std/[json, strutils, tables]

type
  ConfigFormat* = enum
    cfToml
    cfYaml
    cfJson
    cfIni
    cfShellExports
    cfText

  StructuredKind* = enum
    svNull
    svBool
    svInt
    svFloat
    svString
    svArray
    svObject

  StructuredValue* = ref object
    case kind*: StructuredKind
    of svNull: discard
    of svBool: boolVal*: bool
    of svInt: intVal*: int64
    of svFloat: floatVal*: float
    of svString: strVal*: string
    of svArray: items*: seq[StructuredValue]
    of svObject: members*: OrderedTable[string, StructuredValue]

  ConfigSerializeError* = object of CatchableError

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc svNull*(): StructuredValue = StructuredValue(kind: svNull)
proc svBool*(v: bool): StructuredValue =
  StructuredValue(kind: svBool, boolVal: v)
proc svInt*(v: SomeInteger): StructuredValue =
  StructuredValue(kind: svInt, intVal: int64(v))
proc svFloat*(v: SomeFloat): StructuredValue =
  StructuredValue(kind: svFloat, floatVal: float(v))
proc svString*(v: string): StructuredValue =
  StructuredValue(kind: svString, strVal: v)

proc svArray*(items: seq[StructuredValue] = @[]): StructuredValue =
  StructuredValue(kind: svArray, items: items)

proc svObject*(): StructuredValue =
  StructuredValue(kind: svObject,
    members: initOrderedTable[string, StructuredValue]())

proc add*(arr: StructuredValue; child: StructuredValue) =
  if arr.kind != svArray:
    raise newException(ConfigSerializeError, "add: not an array")
  arr.items.add child

proc setField*(obj: StructuredValue; key: string;
               value: StructuredValue) =
  if obj.kind != svObject:
    raise newException(ConfigSerializeError, "setField: not an object")
  obj.members[key] = value

# ---------------------------------------------------------------------------
# JsonNode interop
# ---------------------------------------------------------------------------

proc fromJsonNode*(node: JsonNode): StructuredValue =
  if node.isNil:
    return svNull()
  case node.kind
  of JNull: svNull()
  of JBool: svBool(node.bval)
  of JInt: svInt(node.num)
  of JFloat: svFloat(node.fnum)
  of JString: svString(node.str)
  of JArray:
    let arr = svArray()
    for child in node.elems:
      arr.add fromJsonNode(child)
    arr
  of JObject:
    let obj = svObject()
    for key, child in node.fields:
      obj.setField(key, fromJsonNode(child))
    obj

proc toJsonNode*(v: StructuredValue): JsonNode =
  case v.kind
  of svNull: newJNull()
  of svBool: newJBool(v.boolVal)
  of svInt: newJInt(v.intVal)
  of svFloat: newJFloat(v.floatVal)
  of svString: newJString(v.strVal)
  of svArray:
    let r = newJArray()
    for child in v.items:
      r.add toJsonNode(child)
    r
  of svObject:
    let r = newJObject()
    for k, child in v.members:
      r[k] = toJsonNode(child)
    r

# ---------------------------------------------------------------------------
# Serializers
# ---------------------------------------------------------------------------

proc tomlEscapeString(s: string): string =
  result = newStringOfCap(s.len + 2)
  result.add('"')
  for ch in s:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else:
      if byte(ch) < 0x20'u8:
        result.add("\\u")
        result.add(toHex(int(byte(ch)), 4))
      else:
        result.add(ch)
  result.add('"')

proc isPlainTomlKey(s: string): bool =
  if s.len == 0: return false
  for ch in s:
    if not (ch in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}):
      return false
  result = true

proc tomlKey(s: string): string =
  if isPlainTomlKey(s): s else: tomlEscapeString(s)

proc tomlInlineValue(v: StructuredValue): string =
  case v.kind
  of svNull:
    raise newException(ConfigSerializeError,
      "TOML has no representation for null values")
  of svBool: (if v.boolVal: "true" else: "false")
  of svInt: $v.intVal
  of svFloat:
    if v.floatVal == 0.0: "0.0" else: $v.floatVal
  of svString: tomlEscapeString(v.strVal)
  of svArray:
    var parts: seq[string] = @[]
    for child in v.items: parts.add tomlInlineValue(child)
    "[" & parts.join(", ") & "]"
  of svObject:
    var parts: seq[string] = @[]
    for k, child in v.members:
      parts.add tomlKey(k) & " = " & tomlInlineValue(child)
    "{ " & parts.join(", ") & " }"

proc tomlWriteSection(buf: var string; v: StructuredValue;
                      pathParts: seq[string]) =
  ## Emit `[a.b.c]` section header (when there is one) followed by scalar
  ## and inline-table fields, then recurse into nested objects.
  if pathParts.len > 0:
    buf.add('[')
    var first = true
    for part in pathParts:
      if not first: buf.add('.')
      buf.add(tomlKey(part))
      first = false
    buf.add(']')
    buf.add('\n')
  # Pass 1: scalar / inline-table / array fields.
  for k, child in v.members:
    if child.kind == svObject:
      continue
    buf.add(tomlKey(k))
    buf.add(" = ")
    buf.add(tomlInlineValue(child))
    buf.add('\n')
  # Pass 2: nested sections.
  for k, child in v.members:
    if child.kind != svObject:
      continue
    buf.add('\n')
    var nextParts = pathParts
    nextParts.add k
    tomlWriteSection(buf, child, nextParts)

proc serializeToml*(v: StructuredValue): string =
  if v.kind != svObject:
    raise newException(ConfigSerializeError,
      "TOML root must be an object")
  result = ""
  tomlWriteSection(result, v, @[])

# --- JSON ------------------------------------------------------------------
proc jsonEscape(s: string): string =
  result = newStringOfCap(s.len + 2)
  result.add('"')
  for ch in s:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else:
      if byte(ch) < 0x20'u8:
        result.add("\\u")
        result.add(toHex(int(byte(ch)), 4))
      else:
        result.add(ch)
  result.add('"')

proc jsonWrite(buf: var string; v: StructuredValue; indent: int) =
  let pad = repeat("  ", indent)
  case v.kind
  of svNull: buf.add("null")
  of svBool: buf.add(if v.boolVal: "true" else: "false")
  of svInt: buf.add($v.intVal)
  of svFloat:
    if v.floatVal == 0.0: buf.add("0.0") else: buf.add($v.floatVal)
  of svString: buf.add(jsonEscape(v.strVal))
  of svArray:
    if v.items.len == 0:
      buf.add("[]")
      return
    buf.add('[')
    var first = true
    for child in v.items:
      if not first: buf.add(',')
      first = false
      buf.add('\n')
      buf.add(repeat("  ", indent + 1))
      jsonWrite(buf, child, indent + 1)
    buf.add('\n')
    buf.add(pad)
    buf.add(']')
  of svObject:
    if v.members.len == 0:
      buf.add("{}")
      return
    buf.add('{')
    var first = true
    for k, child in v.members:
      if not first: buf.add(',')
      first = false
      buf.add('\n')
      buf.add(repeat("  ", indent + 1))
      buf.add(jsonEscape(k))
      buf.add(": ")
      jsonWrite(buf, child, indent + 1)
    buf.add('\n')
    buf.add(pad)
    buf.add('}')

proc serializeJson*(v: StructuredValue): string =
  result = ""
  jsonWrite(result, v, 0)
  result.add('\n')

# --- YAML ------------------------------------------------------------------
proc yamlScalar(s: string): string =
  ## Minimal-quote YAML scalar: quote when needed, leave plain otherwise.
  if s.len == 0: return "\"\""
  let plainOk = block:
    var ok = true
    if s[0] in {'-', '?', ':', ',', '[', ']', '{', '}',
                '#', '&', '*', '!', '|', '>', '\'', '\"',
                '%', '@', '`'}:
      ok = false
    else:
      for ch in s:
        if byte(ch) < 0x20'u8 or ch == '\n':
          ok = false; break
    if s in ["true", "false", "null", "yes", "no", "~", "True", "False",
             "Null", "Yes", "No", "TRUE", "FALSE", "NULL"]:
      ok = false
    # Numeric-shaped strings must quote.
    var asNum = true
    var i = 0
    if i < s.len and s[i] in {'+', '-'}: inc i
    if i >= s.len: asNum = false
    while i < s.len:
      if not (s[i] in {'0'..'9', '.', 'e', 'E', '+', '-'}):
        asNum = false; break
      inc i
    if asNum: ok = false
    ok
  if plainOk: return s
  result = jsonEscape(s)

proc yamlWrite(buf: var string; v: StructuredValue; indent: int;
               atRoot: bool) =
  let pad = repeat("  ", indent)
  case v.kind
  of svNull: buf.add("null")
  of svBool: buf.add(if v.boolVal: "true" else: "false")
  of svInt: buf.add($v.intVal)
  of svFloat:
    if v.floatVal == 0.0: buf.add("0.0") else: buf.add($v.floatVal)
  of svString: buf.add(yamlScalar(v.strVal))
  of svArray:
    if v.items.len == 0:
      buf.add("[]")
      return
    for i, child in v.items:
      if not atRoot or i > 0:
        buf.add('\n')
      buf.add(pad)
      buf.add("- ")
      case child.kind
      of svObject, svArray:
        # Inline first key on same line for objects.
        if child.kind == svObject and child.members.len > 0:
          var first = true
          for k, sub in child.members:
            if first:
              buf.add(yamlScalar(k))
              buf.add(":")
              case sub.kind
              of svObject, svArray:
                yamlWrite(buf, sub, indent + 1, atRoot = false)
              else:
                buf.add(' ')
                yamlWrite(buf, sub, indent + 1, atRoot = false)
              first = false
            else:
              buf.add('\n')
              buf.add(repeat("  ", indent + 1))
              buf.add(yamlScalar(k))
              buf.add(":")
              case sub.kind
              of svObject, svArray:
                yamlWrite(buf, sub, indent + 2, atRoot = false)
              else:
                buf.add(' ')
                yamlWrite(buf, sub, indent + 2, atRoot = false)
        else:
          yamlWrite(buf, child, indent + 1, atRoot = false)
      else:
        yamlWrite(buf, child, indent + 1, atRoot = false)
  of svObject:
    if v.members.len == 0:
      buf.add("{}")
      return
    var first = true
    for k, child in v.members:
      if not atRoot or not first:
        buf.add('\n')
      buf.add(pad)
      buf.add(yamlScalar(k))
      buf.add(":")
      case child.kind
      of svObject:
        if child.members.len == 0:
          buf.add(" {}")
        else:
          yamlWrite(buf, child, indent + 1, atRoot = false)
      of svArray:
        if child.items.len == 0:
          buf.add(" []")
        else:
          yamlWrite(buf, child, indent + 1, atRoot = false)
      else:
        buf.add(' ')
        yamlWrite(buf, child, indent + 1, atRoot = false)
      first = false

proc serializeYaml*(v: StructuredValue): string =
  result = ""
  yamlWrite(result, v, 0, atRoot = true)
  result.add('\n')

# --- INI -------------------------------------------------------------------
proc iniScalar(v: StructuredValue): string =
  case v.kind
  of svNull: ""
  of svBool: (if v.boolVal: "true" else: "false")
  of svInt: $v.intVal
  of svFloat:
    if v.floatVal == 0.0: "0.0" else: $v.floatVal
  of svString: v.strVal
  of svArray:
    var parts: seq[string] = @[]
    for child in v.items: parts.add iniScalar(child)
    parts.join(",")
  of svObject:
    raise newException(ConfigSerializeError,
      "INI inline objects are not supported")

proc serializeIni*(v: StructuredValue): string =
  ## Two-level INI: root members that are scalars go into a default
  ## (unnamed) section at the top; object members become `[section]`
  ## blocks. Nested objects beyond depth 2 are an error.
  if v.kind != svObject:
    raise newException(ConfigSerializeError,
      "INI root must be an object")
  result = ""
  var hasRootScalars = false
  for k, child in v.members:
    if child.kind != svObject:
      result.add k
      result.add('=')
      result.add(iniScalar(child))
      result.add('\n')
      hasRootScalars = true
  for k, child in v.members:
    if child.kind != svObject: continue
    if result.len > 0: result.add('\n')
    result.add('[')
    result.add(k)
    result.add(']')
    result.add('\n')
    for ck, sub in child.members:
      if sub.kind == svObject:
        raise newException(ConfigSerializeError,
          "INI does not support nesting beyond two levels (at " &
          k & "." & ck & ")")
      result.add(ck)
      result.add('=')
      result.add(iniScalar(sub))
      result.add('\n')
  if not hasRootScalars and v.members.len == 0:
    result = "\n"

# --- shell exports ---------------------------------------------------------
proc shellQuote(s: string): string =
  ## POSIX shell single-quote with escape-via-double-quote-and-back.
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add('\'')

proc serializeShellExports*(v: StructuredValue): string =
  if v.kind != svObject:
    raise newException(ConfigSerializeError,
      "shellExports root must be an object")
  result = ""
  for k, child in v.members:
    if child.kind == svObject:
      raise newException(ConfigSerializeError,
        "shellExports does not support nested objects (at " & k & ")")
    let raw =
      case child.kind
      of svArray:
        var parts: seq[string] = @[]
        for item in child.items: parts.add iniScalar(item)
        parts.join(":")
      else:
        iniScalar(child)
    result.add("export ")
    result.add(k)
    result.add('=')
    result.add(shellQuote(raw))
    result.add('\n')

# --- text ------------------------------------------------------------------
proc serializeText*(v: StructuredValue): string =
  ## Text content carries a single string under the key `"text"`, or a
  ## raw string at the root.
  case v.kind
  of svString: v.strVal
  of svObject:
    if v.members.len == 1 and v.members.hasKey("text"):
      let inner = v.members["text"]
      if inner.kind == svString: inner.strVal
      else: raise newException(ConfigSerializeError,
        "textContent: must hold a string")
    else:
      raise newException(ConfigSerializeError,
        "textContent: expected a single string value")
  else:
    raise newException(ConfigSerializeError,
      "textContent: expected a string")

# --- dispatcher ------------------------------------------------------------
proc serialize*(format: ConfigFormat; v: StructuredValue): string =
  case format
  of cfToml:         serializeToml(v)
  of cfYaml:         serializeYaml(v)
  of cfJson:         serializeJson(v)
  of cfIni:          serializeIni(v)
  of cfShellExports: serializeShellExports(v)
  of cfText:         serializeText(v)

# ---------------------------------------------------------------------------
# Insertion-order iteration helpers (used by callers in tests).
# ---------------------------------------------------------------------------

iterator pairsInOrder*(v: StructuredValue): tuple[key: string;
                                                  value: StructuredValue] =
  if v.kind == svObject:
    for k, child in v.members:
      yield (k, child)

proc len*(v: StructuredValue): int =
  case v.kind
  of svArray: v.items.len
  of svObject: v.members.len
  else: 0

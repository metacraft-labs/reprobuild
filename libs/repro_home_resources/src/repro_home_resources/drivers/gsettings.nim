## `linux.gsettings` driver — Phase B.
##
## Reads / writes / resets GNOME's dconf database via the
## `gsettings` command-line tool. The `when defined(linux)` branch
## shells out; on every other platform the apply / destroy / observe
## entry points raise `ENotImplementedPlatform` (fail-closed, NOT a
## silent no-op).
##
## Per the spec ("`linux.gsettings`"):
##   - get:   `gsettings get <schema>[:<path>] <key>`
##   - set:   `gsettings set <schema>[:<path>] <key> <gvariant-literal>`
##   - reset: `gsettings reset <schema>[:<path>] <key>`
##
## Value type follows the schema; the driver typed-encodes the value
## as a GVariant literal. Relocatable schemas (per-keybinding dconf
## paths) take an optional `path` argument that produces the
## `<schema>:<path>` form.
##
## ## Pure logic isolated for off-Linux unit testing
##
## `gsettingsSchemaSpec`, the GVariant ENCODER (`GVariantValue` +
## `encodeGVariant`), and the GVariant PARSER (`parseGVariant`) are
## pure functions: they never invoke `gsettings`, so the smoke
## suite exercises them on Windows. Only the shell-out is
## platform-bound.

import std/[osproc, strutils]

import ./../errors
import ./../manifest_record
import ./../types

type
  GVariantKind* = enum
    ## The common GVariant value shapes the `linux.gsettings`
    ## driver supports (per the spec: bool, int, string, double,
    ## string-array).
    gvkString = "string"
    gvkBool = "bool"
    gvkInt32 = "int32"
    gvkDouble = "double"
    gvkStringArray = "stringArray"

  GVariantValue* = object
    ## A typed GVariant value. The driver encodes this into the
    ## textual GVariant literal `gsettings set` expects, and the
    ## parser turns a `gsettings get` line back into one of these.
    case kind*: GVariantKind
    of gvkString:
      strVal*: string
    of gvkBool:
      boolVal*: bool
    of gvkInt32:
      intVal*: int32
    of gvkDouble:
      dblVal*: float
    of gvkStringArray:
      arrVal*: seq[string]

# ---------------------------------------------------------------------------
# Schema-spec helper (pure).
# ---------------------------------------------------------------------------

proc gsettingsSchemaSpec*(schema, path: string): string =
  ## Produce the `<schema>` or `<schema>:<path>` argument. A
  ## non-empty `path` selects a relocatable-schema instance.
  if path.len == 0: schema
  else: schema & ":" & path

# ---------------------------------------------------------------------------
# GVariant string escaping (pure).
# ---------------------------------------------------------------------------

proc escapeGVariantString*(s: string): string =
  ## Escape a string for a single-quoted GVariant literal. GVariant
  ## string literals escape backslash and the surrounding quote.
  result = ""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '\'': result.add("\\'")
    else: result.add(ch)

proc unescapeGVariantString*(s: string): string =
  ## Inverse of `escapeGVariantString`: decode the body of a
  ## single-quoted GVariant string literal.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      result.add(s[i + 1])
      i += 2
    else:
      result.add(s[i])
      inc i

# ---------------------------------------------------------------------------
# GVariant ENCODER (pure).
# ---------------------------------------------------------------------------

proc encodeGVariant*(v: GVariantValue): string =
  ## Encode a typed value into the GVariant textual literal that
  ## `gsettings set` accepts:
  ##   - string        -> `'...'`
  ##   - bool          -> `true` / `false`
  ##   - int32         -> the decimal integer
  ##   - double        -> the decimal float (always with a `.`)
  ##   - string-array  -> `['a', 'b']`
  case v.kind
  of gvkString:
    return "'" & escapeGVariantString(v.strVal) & "'"
  of gvkBool:
    return (if v.boolVal: "true" else: "false")
  of gvkInt32:
    return $v.intVal
  of gvkDouble:
    var s = $v.dblVal
    # gsettings double literals are unambiguous when they carry a
    # decimal point; `$` already does for non-integral floats, but
    # an integral float (`1.0`) renders as `1.0` in Nim — keep it.
    if '.' notin s and 'e' notin s and 'E' notin s:
      s.add(".0")
    return s
  of gvkStringArray:
    var parts: seq[string] = @[]
    for item in v.arrVal:
      parts.add("'" & escapeGVariantString(item) & "'")
    return "[" & parts.join(", ") & "]"

# ---------------------------------------------------------------------------
# GVariant PARSER (pure).
# ---------------------------------------------------------------------------

proc parseGVariant*(literal: string): GVariantValue =
  ## Parse the textual GVariant literal a `gsettings get` call emits
  ## back into a typed value. Recognizes the same five shapes the
  ## encoder produces. Unrecognized literals fall back to a string
  ## value carrying the raw text so drift comparison still works
  ## byte-for-byte (the digest is over the raw bytes regardless).
  let s = literal.strip()
  if s.len == 0:
    return GVariantValue(kind: gvkString, strVal: "")
  # Single-quoted string.
  if s.len >= 2 and s[0] == '\'' and s[^1] == '\'':
    return GVariantValue(kind: gvkString,
      strVal: unescapeGVariantString(s[1 ..< s.len - 1]))
  # Boolean.
  if s == "true":
    return GVariantValue(kind: gvkBool, boolVal: true)
  if s == "false":
    return GVariantValue(kind: gvkBool, boolVal: false)
  # String array `['a', 'b']`.
  if s.len >= 2 and s[0] == '[' and s[^1] == ']':
    var items: seq[string] = @[]
    let body = s[1 ..< s.len - 1].strip()
    if body.len > 0:
      var i = 0
      while i < body.len:
        # Skip whitespace and commas between elements.
        while i < body.len and (body[i] == ' ' or body[i] == ','):
          inc i
        if i >= body.len:
          break
        if body[i] != '\'':
          # Malformed array element — treat the whole literal as a
          # raw string fallback.
          return GVariantValue(kind: gvkString, strVal: s)
        inc i  # skip opening quote
        var elem = ""
        while i < body.len:
          if body[i] == '\\' and i + 1 < body.len:
            elem.add(body[i + 1])
            i += 2
          elif body[i] == '\'':
            inc i
            break
          else:
            elem.add(body[i])
            inc i
        items.add(elem)
    return GVariantValue(kind: gvkStringArray, arrVal: items)
  # Integer.
  block tryInt:
    try:
      let n = parseInt(s)
      if n >= int(low(int32)) and n <= int(high(int32)):
        return GVariantValue(kind: gvkInt32, intVal: int32(n))
    except ValueError:
      break tryInt
  # Double.
  block tryFloat:
    try:
      let f = parseFloat(s)
      return GVariantValue(kind: gvkDouble, dblVal: f)
    except ValueError:
      break tryFloat
  # Fallback: keep the raw text as a string value.
  return GVariantValue(kind: gvkString, strVal: s)

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

proc observeGsettings*(schema, path, key: string): ObservedState =
  ## `gsettings get <schema>[:<path>] <key>`. The raw output line
  ## (a GVariant literal) is the canonical bytes the digest covers.
  when defined(linux):
    let spec = gsettingsSchemaSpec(schema, path)
    let (output, exitCode) = execCmdEx("gsettings get " & spec & " " & key)
    if exitCode != 0:
      result.present = false
      result.digest = zeroDigest()
      return
    let val = output.strip()
    var raw = newSeq[byte](val.len)
    for i, ch in val:
      raw[i] = byte(ord(ch))
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform("linux.gsettings", "linux")

proc applyGsettings*(schema, path, key, valueLiteral: string):
    seq[byte] =
  ## `gsettings set <schema>[:<path>] <key> <gvariant-literal>`. The
  ## recorded payload bytes are the literal itself.
  when defined(linux):
    let spec = gsettingsSchemaSpec(schema, path)
    let (output, exitCode) = execCmdEx(
      "gsettings set " & spec & " " & key & " " & valueLiteral)
    if exitCode != 0:
      raiseResourceDriver("gsettings:" & spec & ":" & key,
        "linux.gsettings", "gsettings set",
        "exit " & $exitCode & ": " & output.strip())
    result = newSeq[byte](valueLiteral.len)
    for i, ch in valueLiteral:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("linux.gsettings", "linux")

proc destroyGsettings*(schema, path, key: string) =
  ## `gsettings reset <schema>[:<path>] <key>` — restore the schema
  ## default.
  when defined(linux):
    let spec = gsettingsSchemaSpec(schema, path)
    discard execCmd("gsettings reset " & spec & " " & key)
  else:
    raiseNotImplementedPlatform("linux.gsettings", "linux")

## Doc-comment directive parser.
##
## A run of leading `## doc` lines preceding a recognized declaration
## attaches to that declaration. Within the attached doc text, lines
## of the form `@<name> <value>` are extracted as structured
## directives and removed from the displayed description.
##
## v1 directive set:
##
## - `@id <stable-identifier>` — explicit persistent id; identifier
##   MUST match `[a-z][a-z0-9-]*`. Uppercase or other punctuation is
##   rejected with `EInvalidId`.
##
## Future-reserved directive names: `@deprecated`, `@since`,
## `@hidden`, `@unit`. They are parsed but produce a structured
## "not yet supported" diagnostic (`EFutureDirective`).
##
## Unknown directive names produce `EUnknownDirective`.

import std/[strutils]

import ./types

type
  ParsedDocComment* = object
    description*: string
    explicitId*: string
    unsupportedDirectives*: seq[string]
      ## Reserved-future directives that were present but produce
      ## "not yet supported" diagnostics if surfaced.

  DocDirectiveError* = object of ConfigurableError

const
  ReservedFutureDirectives* = ["deprecated", "since", "hidden", "unit"]

proc isValidExplicitId*(id: string): bool =
  if id.len == 0: return false
  if id[0] notin {'a'..'z'}: return false
  for ch in id:
    if ch notin {'a'..'z', '0'..'9', '-'}: return false
  return true

proc parseDirective(line: string; outBuf: var ParsedDocComment) =
  ## `line` has the leading `@` already and possibly trailing spaces.
  let trimmed = line.strip()
  if trimmed.len == 0 or trimmed[0] != '@':
    raise newException(DocDirectiveError,
      "internal error: parseDirective called on non-directive line")
  # split on first whitespace
  var splitPos = -1
  for i in 1 ..< trimmed.len:
    if trimmed[i] in {' ', '\t'}:
      splitPos = i; break
  let name = if splitPos < 0: trimmed[1 ..^ 1] else: trimmed[1 ..< splitPos]
  let value =
    if splitPos < 0: ""
    else: trimmed[splitPos + 1 ..^ 1].strip()
  case name
  of "id":
    if not isValidExplicitId(value):
      raise newException(EInvalidId,
        "invalid @id '" & value & "': must match [a-z][a-z0-9-]*")
    if outBuf.explicitId.len > 0:
      raise newException(EUnknownDirective,
        "duplicate @id directive (' " & outBuf.explicitId &
        "' followed by '" & value & "')")
    outBuf.explicitId = value
  else:
    var isReserved = false
    for r in ReservedFutureDirectives:
      if r == name:
        isReserved = true; break
    if isReserved:
      outBuf.unsupportedDirectives.add(name)
      raise newException(EFutureDirective,
        "@" & name & " is reserved for a future revision and not yet " &
        "supported")
    raise newException(EUnknownDirective,
      "unknown directive @" & name &
      " (supported: @id; reserved-future: @" &
      ReservedFutureDirectives.join(", @") & ")")

proc parseDocComment*(raw: string): ParsedDocComment =
  ## Walk a joined doc-comment block, extract directives, return the
  ## remaining text as the description plus the parsed metadata.
  ##
  ## Multiple consecutive doc lines have already been joined with
  ## newlines (see `extractLeadDoc` in the v8 prototype).
  var descLines: seq[string] = @[]
  for rawLine in splitLines(raw):
    let stripped = rawLine.strip(leading = true, trailing = false)
    if stripped.startsWith("@"):
      parseDirective(stripped, result)
    else:
      descLines.add rawLine
  result.description = descLines.join("\n").strip(leading = false,
    trailing = true)

proc parseDocCommentChecked*(raw: string;
                             allowUnsupported: bool): ParsedDocComment =
  ## Variant that surfaces `EFutureDirective` for reserved-future
  ## directives unless `allowUnsupported` is set.
  try:
    result = parseDocComment(raw)
  except EFutureDirective:
    if not allowUnsupported: raise
    # Rebuild while collecting only @id; ignore future directives.
    var partial: ParsedDocComment
    var descLines: seq[string] = @[]
    for rawLine in splitLines(raw):
      let stripped = rawLine.strip(leading = true, trailing = false)
      if stripped.startsWith("@"):
        try: parseDirective(stripped, partial)
        except EFutureDirective: discard
      else:
        descLines.add rawLine
    partial.description = descLines.join("\n").strip(leading = false,
      trailing = true)
    result = partial

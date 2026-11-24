## Nimble's version order, for the packages of a Nimble catalog
## (`nimble:` packages, Nimble package catalog spec NPC-AREQ6, "Versions with
## any number of components").
##
## A Nimble version is one or more dot-separated decimal components, as many
## as the tag has. Two versions compare as Nimble 0.20.1 compares them
## (`nimblepkg/version.nim`, `<` and `==`, tag `v0.20.1` = `9207e8b2`):
## component by component from the left, the first that differs decides, and
## a component one version lacks counts as 0. So trailing zeros never matter
## (`1.2`, `1.2.0` and `1.2.0.0` are equal) and a longer version is greater
## only through a non-zero component (`0.6.0.3.1 > 0.6.0.3`).
##
## A range is the solver's range grammar (`version_constraints`) read over
## such versions: tokens split on commas and before an operator; `>=`, `>`,
## `<=`, `<` compare by the order above; `=`, `==` and a bare version are
## Nimble equality (so `== 1.2` admits `1.2.0.0`, which the semver reading's
## `[1.2.0, 1.2.1)` would also admit, and nothing between it and `1.2.0.1`);
## `^` and `~` mean what they mean in the semver grammar, for a version of at
## most three components, and are refused for a longer one. Every token must
## hold for a version to be admitted. A pre-release suffix is refused: a
## Nimble tag that has one is a label, never a version.
##
## This is the comparison the solver uses for a package declared with
## ``vsNimble`` (``version_encoder.PackageDecl.versionScheme``). Every other
## package keeps the semver order of ``version_constraints``.

{.push raises: [].}

import std/[options, strutils]

import ./version_constraints

type
  NimbleVersion* = seq[uint64]
    ## The numeric components, as many as written.

  NimbleRangeOp* = enum
    nroGe, nroGt, nroLe, nroLt, nroEq

  NimbleRangeToken* = object
    op*: NimbleRangeOp
    version*: NimbleVersion

  NimbleRange* = object
    ## The conjunction of ``tokens``; empty admits every version.
    tokens*: seq[NimbleRangeToken]

const MaxNimbleComponents* = 64
  ## A bound on what a parser accepts; the index keeps at most 8.

proc parseNimbleVersion*(s: string): NimbleVersion {.raises: [ESemverParse].} =
  ## `X`, `X.Y`, `X.Y.Z.W...`, with an optional leading `v`. Each component
  ## is decimal digits only.
  var raw = s.strip()
  if raw.len > 0 and raw[0] in {'v', 'V'}:
    raw = raw[1 .. ^1]
  if raw.len == 0:
    raise newException(ESemverParse, "empty version string")
  let parts = raw.split('.')
  if parts.len > MaxNimbleComponents:
    raise newException(ESemverParse, "too many components in version '" &
      s & "'")
  for p in parts:
    if p.len == 0 or not p.allCharsInSet(Digits):
      raise newException(ESemverParse, "version '" & s & "' is not " &
        "dot-separated decimal components")
    try:
      result.add uint64(parseBiggestUInt(p))
    except ValueError:
      raise newException(ESemverParse, "component '" & p & "' of version '" &
        s & "' is out of range")

proc cmpNimble*(a, b: NimbleVersion): int =
  ## Nimble's order: from the left, the first differing component decides;
  ## a missing component is 0.
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0'u64
    let y = if i < b.len: b[i] else: 0'u64
    if x != y:
      return (if x < y: -1 else: 1)
  0

proc cmpNimbleText*(a, b: string): int {.raises: [ESemverParse].} =
  cmpNimble(parseNimbleVersion(a), parseNimbleVersion(b))

proc nimbleVersionText*(v: NimbleVersion): string =
  for i, c in v:
    if i > 0: result.add '.'
    result.add $c

proc fromSemver(v: SemverVersion): NimbleVersion =
  @[uint64(v.major), uint64(v.minor), uint64(v.patch)]

proc tokenize(raw: string): seq[string] =
  ## The token split of ``parseSemverRange``: a comma always splits; a space
  ## splits when the next non-space character starts an operator.
  var current = ""
  var i = 0
  while i < raw.len:
    let c = raw[i]
    if c == ',':
      if current.strip.len > 0: result.add current.strip
      current = ""
    elif c in {' ', '\t'}:
      var j = i + 1
      while j < raw.len and raw[j] in {' ', '\t'}:
        inc j
      if j < raw.len and raw[j] in {'>', '<', '=', '^', '~'}:
        if current.strip.len > 0: result.add current.strip
        current = ""
      i = j
      continue
    else:
      current.add c
    inc i
  if current.strip.len > 0: result.add current.strip

proc parseNimbleRange*(s: string): NimbleRange {.raises: [ESemverParse].} =
  ## See the module header. Raises ``ESemverParse`` on an empty range, an
  ## unknown operator, a malformed version, or `^`/`~` over more than three
  ## components.
  let raw = s.strip()
  if raw.len == 0:
    raise newException(ESemverParse, "empty range string")
  let tokens = tokenize(raw)
  if tokens.len == 0:
    raise newException(ESemverParse, "no constraint tokens in range '" & s &
      "'")
  for t in tokens:
    var op = ""
    var i = 0
    while i < t.len and t[i] in {'>', '<', '=', '^', '~'}:
      op.add t[i]
      inc i
    let body = t[i .. ^1].strip()
    case op
    of ">=": result.tokens.add NimbleRangeToken(op: nroGe,
      version: parseNimbleVersion(body))
    of ">": result.tokens.add NimbleRangeToken(op: nroGt,
      version: parseNimbleVersion(body))
    of "<=": result.tokens.add NimbleRangeToken(op: nroLe,
      version: parseNimbleVersion(body))
    of "<": result.tokens.add NimbleRangeToken(op: nroLt,
      version: parseNimbleVersion(body))
    of "", "=", "==": result.tokens.add NimbleRangeToken(op: nroEq,
      version: parseNimbleVersion(body))
    of "^", "~":
      if parseNimbleVersion(body).len > 3:
        raise newException(ESemverParse, "'" & t & "': `" & op & "` takes " &
          "a version of at most three components")
      # The semver grammar's meaning, bounds included.
      let r = parseSemverRange(t)
      if r.lower.isSome:
        result.tokens.add NimbleRangeToken(op: nroGe,
          version: fromSemver(r.lower.get))
      if r.upper.isSome:
        result.tokens.add NimbleRangeToken(op: nroLt,
          version: fromSemver(r.upper.get))
    else:
      raise newException(ESemverParse, "unknown operator '" & op &
        "' in range '" & s & "'")

proc admits*(r: NimbleRange; v: NimbleVersion): bool =
  for t in r.tokens:
    let c = cmpNimble(v, t.version)
    let ok = case t.op
      of nroGe: c >= 0
      of nroGt: c > 0
      of nroLe: c <= 0
      of nroLt: c < 0
      of nroEq: c == 0
    if not ok:
      return false
  true

proc nimbleRangeAdmits*(rangeText, version: string): bool =
  ## Whether the range ``rangeText`` admits ``version`` in Nimble's order. A
  ## range or version that does not parse admits nothing, as in the semver
  ## reading.
  let r = try: parseNimbleRange(rangeText)
          except ESemverParse: return false
  let v = try: parseNimbleVersion(version)
          except ESemverParse: return false
  admits(r, v)

{.pop.}

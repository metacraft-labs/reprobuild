## ``repro_solver/version_constraints`` — Spec-Implementation M2c semver
## range parser.
##
## Parses the semver-range constraint strings that appear in package
## ``uses:`` declarations and produces a typed ``SemverRange`` record
## the M2c version encoder grounds against the catalog of declared
## versions.
##
## ## Supported operators
##
## * ``==1.2.3`` / ``=1.2.3`` / bare ``1.2.3`` — exact pin.
## * ``>=X``, ``<=X``, ``>X``, ``<X`` — half-open bounds.
## * ``^1.5.0`` — caret: bumps the next breaking version. For
##   ``^1.5.0`` the range is ``>=1.5.0 <2.0.0``; for ``^0.5.0`` it
##   becomes ``>=0.5.0 <0.6.0`` per npm's pre-1.0 caret semantics; for
##   ``^0.0.3`` it becomes ``>=0.0.3 <0.0.4``. Only the leading-zero
##   pre-1.0 cases differ from a straight major bump.
## * ``~2.1.0`` — tilde: pinned minor. For ``~2.1.0`` the range is
##   ``>=2.1.0 <2.2.0``; for ``~2.1`` it is ``>=2.1.0 <2.2.0``; for
##   ``~2`` it is ``>=2.0.0 <3.0.0``.
## * Comma- or space-separated combinator: ``>=2.2 <3.0`` and
##   ``>=2.2, <3.0`` both intersect into a single range. M2c does NOT
##   model disjunctions (``||``) — the spec's ``uses:`` declarations
##   are restricted to a single conjunction per dependency edge, and
##   modeling alternates would require non-deterministic ASP atoms we
##   intentionally defer to M2e.
##
## Pre-releases are accepted in the version literal
## (``2.2.4-rc1``). M2c compares pre-releases lexicographically against
## the version's stable form: a pre-release version is strictly LESS
## than the same triple without a pre-release suffix, mirroring the
## semver.org §11 rule. That covers the cases ``uses:`` declarations
## actually express in practice ("at least 2.2 and below 3.0 with rc
## acceptable").
##
## ## Why a dedicated module rather than reusing ``std/strutils``
##
## The encoder needs typed bounds, not strings, so it can ground the
## ``version_in_range/3`` predicate at encoding time. A range object
## also gives M2e (explanation paths) a stable surface to render. The
## parser intentionally does NOT depend on the ASP encoder so it can be
## reused by the lock-file serializer and by the catalog adapters
## without a clingo round-trip.

import std/[options, strutils]

# ---------------------------------------------------------------------------
# Public data model
# ---------------------------------------------------------------------------

type
  ESemverParse* = object of CatchableError
    ## Raised on malformed semver / range input. Carries the offending
    ## input verbatim in ``msg`` so callers can replay the diagnostic.

  SemverVersion* = object
    ## A parsed semver triple. ``major``, ``minor``, ``patch`` are
    ## non-negative integers; ``prerelease`` is the empty string when no
    ## pre-release suffix is present.
    major*: int
    minor*: int
    patch*: int
    prerelease*: string

  SemverRange* = object
    ## A half-open semver range: ``[lower, upper)``. ``lower`` is
    ## inclusive; ``upper`` is exclusive (matching cargo / npm
    ## semantics). Either bound may be absent (``none(SemverVersion)``)
    ## for an unbounded half. An exact-pin range encodes as
    ## ``lower == upper-with-patch-bump`` (so ``==1.2.3`` becomes
    ## ``[1.2.3, 1.2.4)``).
    lower*: Option[SemverVersion]  # inclusive
    upper*: Option[SemverVersion]  # exclusive

# ---------------------------------------------------------------------------
# Constructors (terse construction for tests / encoder)
# ---------------------------------------------------------------------------

proc semver*(major, minor, patch: int; prerelease: string = ""): SemverVersion =
  SemverVersion(major: major, minor: minor, patch: patch,
                prerelease: prerelease)

proc unboundedRange*(): SemverRange =
  SemverRange(lower: none(SemverVersion), upper: none(SemverVersion))

# ---------------------------------------------------------------------------
# Version parsing
# ---------------------------------------------------------------------------

proc parseIntComponent(s: string; what: string): int =
  if s.len == 0:
    raise newException(ESemverParse,
      "expected " & what & " digit in semver but got empty component")
  for c in s:
    if c notin {'0'..'9'}:
      raise newException(ESemverParse,
        "non-digit character " & $c & " in " & what & " component '" & s & "'")
  try:
    result = parseInt(s)
  except ValueError:
    raise newException(ESemverParse,
      "could not parse " & what & " component '" & s & "' as integer")

proc parseSemver*(s: string): SemverVersion =
  ## Parse a semver literal. Accepts ``X``, ``X.Y``, ``X.Y.Z`` and any
  ## of the above with a trailing ``-prerelease`` suffix. Missing
  ## components default to ``0`` (so ``2.2`` becomes ``2.2.0``).
  ##
  ## Raises ``ESemverParse`` on empty input, non-digit characters in
  ## the numeric components, or trailing garbage after the
  ## pre-release suffix.
  let raw = s.strip()
  if raw.len == 0:
    raise newException(ESemverParse, "empty semver string")

  # Split off the pre-release / build metadata. We treat anything after
  # ``+`` (build metadata) the same as anything after ``-`` for the
  # purposes of comparison: it's an opaque label.
  var versionPart = raw
  var prerelease = ""
  let dashAt = raw.find('-')
  let plusAt = raw.find('+')
  var suffixAt = -1
  if dashAt >= 0 and (plusAt < 0 or dashAt < plusAt):
    suffixAt = dashAt
  elif plusAt >= 0:
    suffixAt = plusAt
  if suffixAt >= 0:
    versionPart = raw[0 ..< suffixAt]
    prerelease = raw[suffixAt + 1 .. ^1]
    if prerelease.len == 0:
      raise newException(ESemverParse,
        "empty pre-release suffix in semver '" & raw & "'")

  let parts = versionPart.split('.')
  if parts.len < 1 or parts.len > 3:
    raise newException(ESemverParse,
      "expected 1-3 dot-separated components in semver '" & raw & "'")

  let major = parseIntComponent(parts[0], "major")
  let minor = if parts.len >= 2: parseIntComponent(parts[1], "minor") else: 0
  let patch = if parts.len >= 3: parseIntComponent(parts[2], "patch") else: 0

  SemverVersion(major: major, minor: minor, patch: patch,
                prerelease: prerelease)

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

proc cmpSemver*(a, b: SemverVersion): int =
  ## Total order matching semver.org §11. Stable triples come before
  ## pre-release suffixes on the same triple (``1.0.0-rc1 < 1.0.0``);
  ## pre-release suffixes compare lexicographically against each other.
  if a.major != b.major: return cmp(a.major, b.major)
  if a.minor != b.minor: return cmp(a.minor, b.minor)
  if a.patch != b.patch: return cmp(a.patch, b.patch)
  # Same triple — compare pre-release tags. A version without a
  # pre-release is greater than the same version with one.
  if a.prerelease.len == 0 and b.prerelease.len == 0: return 0
  if a.prerelease.len == 0: return 1
  if b.prerelease.len == 0: return -1
  cmp(a.prerelease, b.prerelease)

proc `<`*(a, b: SemverVersion): bool = cmpSemver(a, b) < 0
proc `<=`*(a, b: SemverVersion): bool = cmpSemver(a, b) <= 0
proc `==`*(a, b: SemverVersion): bool = cmpSemver(a, b) == 0

# ---------------------------------------------------------------------------
# Range parsing
# ---------------------------------------------------------------------------

proc bumpForCaret(v: SemverVersion): SemverVersion =
  ## npm/cargo caret bump. ``^1.5.0`` => ``<2.0.0``. ``^0.5.0`` =>
  ## ``<0.6.0``. ``^0.0.3`` => ``<0.0.4``. The rule preserves the
  ## leading non-zero component.
  if v.major > 0:
    return semver(v.major + 1, 0, 0)
  if v.minor > 0:
    return semver(0, v.minor + 1, 0)
  semver(0, 0, v.patch + 1)

proc bumpForTilde(v: SemverVersion; minorPresent: bool): SemverVersion =
  ## npm tilde bump. ``~2.1.0`` and ``~2.1`` both => ``<2.2.0``; ``~2``
  ## => ``<3.0.0``. ``minorPresent`` distinguishes ``~2`` from ``~2.0``.
  if minorPresent:
    return semver(v.major, v.minor + 1, 0)
  semver(v.major + 1, 0, 0)

proc bumpForExact(v: SemverVersion): SemverVersion =
  ## Exact-pin upper bound: smallest version strictly greater than ``v``.
  ## Used so ``==1.2.3`` encodes as ``[1.2.3, 1.2.4)``. The patch bump
  ## is conservative — it cannot collide with a sibling release because
  ## semver triples are dense at the integer level.
  semver(v.major, v.minor, v.patch + 1)

proc intersectLower(a, b: Option[SemverVersion]): Option[SemverVersion] =
  ## Pick the GREATER of two inclusive lower bounds; ``none`` means
  ## "unbounded below" and loses to any bound.
  if a.isNone: return b
  if b.isNone: return a
  if a.get < b.get: return b
  a

proc intersectUpper(a, b: Option[SemverVersion]): Option[SemverVersion] =
  ## Pick the LESSER of two exclusive upper bounds; ``none`` means
  ## "unbounded above" and loses to any bound.
  if a.isNone: return b
  if b.isNone: return a
  if b.get < a.get: return b
  a

proc countDotComponents(s: string): int =
  ## Count dot-separated numeric components in a version-ish prefix.
  ## Stops at the first non-digit-dot character so caret bodies like
  ## ``1.5.0-rc1`` count three components.
  var count = 1
  for c in s:
    if c == '.': inc count
    elif c notin {'0'..'9'}: break
  count

proc parseSingleConstraint(token: string): SemverRange =
  ## Parse one operator+version token (no combinator). Returns a range
  ## with either / both bounds set.
  let t = token.strip()
  if t.len == 0:
    raise newException(ESemverParse, "empty constraint token")

  # Strip leading 'v' that appears on some tags (``v1.5.0``).
  proc stripVPrefix(s: string): string =
    if s.len > 0 and (s[0] == 'v' or s[0] == 'V'): s[1 .. ^1] else: s

  if t.startsWith(">="):
    let v = parseSemver(stripVPrefix(t[2 .. ^1].strip()))
    return SemverRange(lower: some(v), upper: none(SemverVersion))
  if t.startsWith("<="):
    let v = parseSemver(stripVPrefix(t[2 .. ^1].strip()))
    # ``<= V`` is equivalent to ``< bumpForExact(V)`` so we keep the
    # half-open invariant.
    return SemverRange(lower: none(SemverVersion),
                       upper: some(bumpForExact(v)))
  if t.startsWith("=="):
    let v = parseSemver(stripVPrefix(t[2 .. ^1].strip()))
    return SemverRange(lower: some(v), upper: some(bumpForExact(v)))
  if t.startsWith("="):
    let v = parseSemver(stripVPrefix(t[1 .. ^1].strip()))
    return SemverRange(lower: some(v), upper: some(bumpForExact(v)))
  if t.startsWith(">"):
    let body = stripVPrefix(t[1 .. ^1].strip())
    let v = parseSemver(body)
    # ``> V`` ≡ ``>= bumpForExact(V)``. We bump to keep the lower bound
    # inclusive, which is what the encoder expects.
    return SemverRange(lower: some(bumpForExact(v)),
                       upper: none(SemverVersion))
  if t.startsWith("<"):
    let v = parseSemver(stripVPrefix(t[1 .. ^1].strip()))
    return SemverRange(lower: none(SemverVersion), upper: some(v))
  if t.startsWith("^"):
    let body = stripVPrefix(t[1 .. ^1].strip())
    let v = parseSemver(body)
    return SemverRange(lower: some(v), upper: some(bumpForCaret(v)))
  if t.startsWith("~"):
    let body = stripVPrefix(t[1 .. ^1].strip())
    let v = parseSemver(body)
    # The tilde rule depends on whether the user wrote a minor; we
    # detect that off the leading numeric prefix BEFORE any pre-release.
    let dotComponents = countDotComponents(body)
    let minorPresent = dotComponents >= 2
    return SemverRange(lower: some(v),
                       upper: some(bumpForTilde(v, minorPresent)))
  # Bare version literal — treat as exact pin.
  let v = parseSemver(stripVPrefix(t))
  SemverRange(lower: some(v), upper: some(bumpForExact(v)))

proc parseSemverRange*(s: string): SemverRange =
  ## Parse a range expression. Multiple tokens combine via intersection.
  ## Tokens are split on commas; whitespace-separated operator-prefixed
  ## tokens are also recognized so ``>=2.2 <3.0`` parses without
  ## requiring a comma.
  ##
  ## Raises ``ESemverParse`` on empty input or malformed token bodies.
  let raw = s.strip()
  if raw.len == 0:
    raise newException(ESemverParse, "empty semver range string")

  # Build a token list. Comma always splits. A space splits ONLY when
  # the following non-space character is one of the operator prefixes
  # ('>', '<', '=', '^', '~') — otherwise the space is whitespace
  # inside a single token (rare but possible after the operator).
  var tokens: seq[string] = @[]
  var current = newStringOfCap(raw.len)
  proc flush() =
    let t = current.strip()
    if t.len > 0:
      tokens.add(t)
    current.setLen(0)

  var i = 0
  while i < raw.len:
    let c = raw[i]
    if c == ',':
      flush()
    elif c == ' ' or c == '\t':
      # Peek the next non-space character — if it starts a new token,
      # flush. Otherwise just absorb the space as separator within the
      # current token (which we trim anyway).
      var j = i + 1
      while j < raw.len and (raw[j] == ' ' or raw[j] == '\t'):
        inc j
      if j < raw.len and raw[j] in {'>', '<', '=', '^', '~'}:
        flush()
        i = j
        continue
      # Skip the space — but keep the current token intact across the
      # remaining whitespace.
      i = j
      continue
    else:
      current.add(c)
    inc i
  flush()

  if tokens.len == 0:
    raise newException(ESemverParse,
      "no constraint tokens in range '" & s & "'")

  result = unboundedRange()
  for t in tokens:
    let r = parseSingleConstraint(t)
    result.lower = intersectLower(result.lower, r.lower)
    result.upper = intersectUpper(result.upper, r.upper)

# ---------------------------------------------------------------------------
# Range membership
# ---------------------------------------------------------------------------

proc satisfies*(v: SemverVersion; r: SemverRange): bool =
  ## True iff ``v`` lies in the half-open range ``[r.lower, r.upper)``.
  ## An empty range (``lower`` strictly greater than the smallest version
  ## NOT exceeding ``upper``) always returns false — but the parser
  ## never constructs such a range from a single operator. Intersection
  ## can produce one (e.g. ``>=3.0 <2.0``); we let the caller observe
  ## the emptiness by getting ``false`` on every probe.
  if r.lower.isSome and v < r.lower.get:
    return false
  if r.upper.isSome and not (v < r.upper.get):
    return false
  true

proc satisfies*(versionStr, rangeStr: string): bool =
  ## Convenience overload for callers that have only the raw strings.
  ## Re-parses on each call; tight loops should pre-parse the range.
  satisfies(parseSemver(versionStr), parseSemverRange(rangeStr))

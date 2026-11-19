## Nimble requirement strings, and their translation into the solver's
## constraint language (NPC-AREQ6).
##
## Resolution never sees Nimble syntax: each `requires` string is read here,
## once, into a typed `Requirement` whose version part is either a range in
## the grammar `repro_solver/version_constraints.parseSemverRange` reads
## (`>= 1.2.2, < 2.0.0`) or one of Nimble's pseudo-versions (`#head`, a
## commit, a named ref). Anything that cannot be translated is a typed
## `RequirementError` that names the input; nothing is approximated.
##
## The acceptance rules are Nimble 0.20.1's `version.parseRequires` and
## `version.parseVersionRange` (https://github.com/nim-lang/nimble, tag
## `v0.20.1`, `src/nimblepkg/version.nim`), ported rather than reinvented:
##
## * `name`, `name op version`, `name op version & op version`, `name#ref`;
##   operators `==` (or none), `>`, `<`, `>=`, `<=`, `^=`, `~=`; at most one
##   `&`; no space inside a version; `name>=1.0` (no space) names a package
##   called `name>=1.0`, which no registry has, so it is refused here.
## * `^=` and `~=` use Nimble's `getNextIncompatibleVersion`: `^=` bumps the
##   first non-zero of the first two components (the third when both are
##   zero; the first for a one-component version), `~=` bumps the
##   second-to-last component given. So `~= 0.4` is `< 1.0.0`, unlike npm.
## * A string holds a comma- or newline-separated list (Nimble's
##   `multiSplit`).
## * A feature list `name[f1, f2]` may come before or after the range.
##   Commas inside the brackets do not split the list. (Nimble 0.20.1's own
##   splitting breaks a multi-feature list apart, and its `parseRequires`
##   drops a range written after a feature list; the text is unambiguous, so
##   it is read as written, which is the narrower constraint.)
## * A name containing `://`, or of the form `user@host:path`, is a URL; a
##   `?subdir=` query names a subdirectory of the repository. A name of the
##   form `<forge>:<user>/<repo>` is a forge alias and is expanded as Nimble
##   expands it (`gh:`, `gitlab:`, `srht:`, `codeberg:` and their short
##   forms).
##
## The solver's versions have three numeric components. Nimble versions may
## have more; a fourth component that is zero is dropped (Nimble compares
## missing components as zero), and any other is an error, because the
## solver cannot represent the version.

{.push raises: [].}

import std/[options, strutils]

import repro_solver/version_constraints

import ./lexer

type
  TargetKind* = enum
    tkPackage ## a package name, resolved through the catalog
    tkUrl     ## an origin given directly

  Target* = object
    case kind*: TargetKind
    of tkPackage:
      name*: string       ## as written
    of tkUrl:
      url*: string        ## without the query, forge aliases expanded
      subdir*: string     ## from `?subdir=`, or ""
      forgeAlias*: string ## the alias as written, when one was expanded

  VersionKind* = enum
    vkAny    ## a bare name: any version
    vkRange  ## a range in the solver's grammar
    vkHead   ## `#head`: the origin's default branch (a pseudo-version)
    vkCommit ## `#<hex>`: an exact commit
    vkRef    ## `#<branch or tag>`: a named ref (a pseudo-version)

  VersionRequirement* = object
    written*: string      ## the version part as written, after the name
    case kind*: VersionKind
    of vkAny, vkHead:
      discard
    of vkRange:
      normalized*: string ## `>= 1.2.2, < 2.0.0`
      range*: SemverRange
    of vkCommit:
      commit*: string     ## lower-case hex
      abbreviated*: bool  ## shorter than a full object id; NOT resolved here
    of vkRef:
      refName*: string

  Requirement* = object
    source*: string        ## this one requirement as written
    target*: Target
    version*: VersionRequirement
    features*: seq[string] ## features the requirer activates

  RequirementErrorKind* = enum
    reMalformed = "malformed"
      ## Nimble itself rejects it (or reads it as a name no package can have)
    reUntranslatable = "untranslatable"
      ## Nimble accepts it, the solver's language cannot express it

  RequirementError* = object
    kind*: RequirementErrorKind
    input*: string ## the requirement as written
    reason*: string

  RequirementReading* = object
    requirements*: seq[Requirement]
    errors*: seq[RequirementError]

const
  NimbleNamespace* = "nimble"

proc nameKey*(name: string): string =
  ## The registry's uniqueness key (NPC-AREQ3): case folded, underscores
  ## removed.
  styleKey(name)

proc identity*(canonicalName: string): string =
  ## The package's identity in `uses:` and the lock: `nimble:<canonical
  ## name>`. The canonical name is the registry's; mapping a name as written
  ## (or an alias) to it is the generator's job, against the registry.
  NimbleNamespace & ":" & canonicalName

proc isNimTarget*(r: Requirement): bool =
  ## `requires "nim ..."` constrains the toolchain, not a package.
  r.target.kind == tkPackage and nameKey(r.target.name) == "nim"

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

type
  RangeError = object of CatchableError
  Op = enum opEq, opGt, opLt, opGe, opLe, opCaret, opTilde

proc parseOp(op: string): Op {.raises: [RangeError].} =
  case op
  of "", "==": opEq
  of ">": opGt
  of "<": opLt
  of ">=": opGe
  of "<=": opLe
  of "^=": opCaret
  of "~=": opTilde
  else: raise newException(RangeError, "invalid operator '" & op & "'")

proc components(version: string): seq[int] {.raises: [RangeError].} =
  if version.len == 0:
    raise newException(RangeError, "an operator needs a version")
  for part in version.split('.'):
    if part.len == 0:
      raise newException(RangeError, "empty component in version '" & version & "'")
    try:
      result.add parseInt(part)
    except ValueError:
      raise newException(RangeError, "version component '" & part & "' is not a number")

proc nextIncompatible(version: string; semver: bool): seq[int] {.raises: [RangeError].} =
  ## Nimble 0.20.1 `version.getNextIncompatibleVersion`, component for
  ## component. Note that it compares the *text* of a component with "0".
  var numbers = version.split('.')
  let originalLen = numbers.len
  while numbers.len < 3:
    numbers.add "0"
  var zeros = 0
  for n in 0 ..< 2:
    if numbers[n] == "0":
      inc zeros
    else:
      break
  var position = 0
  if semver:
    if originalLen > 1:
      position = case zeros
        of 0: 0
        of 1: 1
        else: 2
  else:
    position = max(0, originalLen - 2)
  for n in numbers:
    if n.len == 0:
      raise newException(RangeError, "empty component in version '" & version & "'")
  try:
    numbers[position] = $(parseInt(numbers[position]) + 1)
  except ValueError:
    raise newException(RangeError, "version component '" & numbers[position] &
                       "' is not a number")
  for z in position + 1 ..< numbers.len:
    numbers[z] = "0"
  components(numbers.join("."))

proc solverVersion(parts: seq[int]; written: string): string {.raises: [RangeError].} =
  ## Three components for the solver: pad with zeros, drop zero extras.
  var p = parts
  while p.len < 3:
    p.add 0
  for extra in p[3 .. ^1]:
    if extra != 0:
      raise newException(RangeError, "version '" & written &
        "' has more than three components; the solver's versions have three")
  $p[0] & "." & $p[1] & "." & $p[2]

proc boundsText(op: Op; version: string): string {.raises: [RangeError].} =
  let v = solverVersion(components(version), version)
  case op
  of opEq: "== " & v
  of opGt: "> " & v
  of opLt: "< " & v
  of opGe: ">= " & v
  of opLe: "<= " & v
  of opCaret, opTilde:
    let upper = solverVersion(nextIncompatible(version, op == opCaret), version)
    ">= " & v & ", < " & upper

type NimbleRangeError = object of CatchableError
  ## Nimble's own `parseVersionRange` would refuse the text.

proc rangeText(s: string): string {.raises: [RangeError, NimbleRangeError].} =
  ## Nimble 0.20.1 `version.parseVersionRange`, producing the normalized
  ## solver text instead of Nimble's tree. `s` is the text after the name.
  var op = ""
  var version = ""
  var i = 0
  while i < s.len:
    case s[i]
    of '>', '<', '=', '~', '^':
      op.add s[i]
    of '&':
      if version.startsWith("."):
        raise newException(NimbleRangeError, "wrong version '" & version & "'")
      let left =
        try: boundsText(parseOp(op), version)
        except RangeError as e:
          if e.msg.startsWith("invalid operator"):
            raise newException(NimbleRangeError, e.msg)
          raise
      let rest = s.substr(i + 1)
      if '&' in rest:
        raise newException(NimbleRangeError,
          "more than one '&' in a version range")
      return left & ", " & rangeText(rest)
    of '0'..'9', '.':
      version.add s[i]
    of ' ':
      if version.len > 0 and i < s.len - 1 and s[i + 1] in {'0'..'9', '.'}:
        raise newException(NimbleRangeError,
          "whitespace is not allowed in a version literal")
    else:
      raise newException(NimbleRangeError,
        "unexpected character '" & s[i] & "' in version range")
    inc i
  let parsedOp =
    try: parseOp(op)
    except RangeError as e: raise newException(NimbleRangeError, e.msg)
  if version.startsWith("."):
    # Nimble's `newVersion` refuses a version that does not start with a digit.
    raise newException(NimbleRangeError, "wrong version '" & version & "'")
  # An empty version (`x >`) is accepted by Nimble and compares as zero; the
  # solver has no such version, so `boundsText` refuses it as untranslatable.
  boundsText(parsedOp, version)

proc isHexObjectId(s: string): bool =
  s.len >= 7 and s.len <= 64 and s.allCharsInSet(HexDigits)

proc readSpecial(written: string): VersionRequirement =
  ## `#head`, `#<commit>`, `#<ref>`. Nimble compares `#head` ignoring case.
  let body = written[1 .. ^1]
  if body.toLowerAscii == "head":
    return VersionRequirement(kind: vkHead, written: written)
  if isHexObjectId(body):
    let lower = body.toLowerAscii
    return VersionRequirement(kind: vkCommit, written: written, commit: lower,
                              abbreviated: body.len notin [40, 64])
  VersionRequirement(kind: vkRef, written: written, refName: body)

# ---------------------------------------------------------------------------
# Names and URLs
# ---------------------------------------------------------------------------

proc isUrl(name: string): bool =
  ## Nimble's `urls.isURL`: contains `://`, or `ident@host:path`.
  if "://" in name:
    return true
  let at = name.find('@')
  if at > 0:
    for c in name[0 ..< at]:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}:
        return false
    let colon = name.find(':', at + 1)
    return colon > at + 1 and colon < name.len - 1
  false

proc expandForge(alias: string; err: var string): string =
  ## Nimble's `forge_aliases`: `<forge>:<user>/<repo>`.
  let parts = alias.split(':')
  let host = case parts[0].toLowerAscii
    of "github", "gh": "github.com/"
    of "gitlab", "gl": "gitlab.com/"
    of "sourcehut", "srht", "shart": "git.sr.ht/"
    of "codeberg", "cb", "cberg": "codeberg.org/"
    else: ""
  if host.len == 0:
    err = "unknown forge alias '" & parts[0] & "'"
    return
  let path = parts[1].split('/')
  if path.len < 2 or path[0].len == 0:
    err = "a forge alias is <forge>:<user>/<repository>"
    return
  var user = path[0]
  if host == "git.sr.ht/" and not user.startsWith('~'):
    user = "~" & user
  "https://" & host & user & "/" & path[1]

proc readTarget(name: string; err: var string): Target =
  if name.len == 0:
    err = "no package name"
    return
  var url = name
  var alias = ""
  if not isUrl(name) and name.count(':') == 1:
    alias = name
    url = expandForge(name, err)
    if err.len > 0:
      return
  if isUrl(url):
    var subdir = ""
    let q = url.find('?')
    if q >= 0:
      let query = url[q + 1 .. ^1]
      if not query.startsWith("subdir="):
        err = "URL query '" & query & "' is not '?subdir=...'"
        return
      subdir = query["subdir=".len .. ^1]
      if subdir.len == 0:
        err = "empty '?subdir='"
        return
      url = url[0 ..< q]
    return Target(kind: tkUrl, url: url, subdir: subdir, forgeAlias: alias)
  for c in name:
    if c in {'<', '>', '=', '~', '^', '&', '#', '[', ']', ' ', '\t', '"'}:
      err = "'" & name & "' is not a package name (is a space missing " &
            "before the operator?)"
      return
  Target(kind: tkPackage, name: name)

# ---------------------------------------------------------------------------
# One requirement, and a list of them
# ---------------------------------------------------------------------------

proc readOne(item: string; reading: var RequirementReading) =
  var req = item.strip
  var features: seq[string]
  let lb = req.find('[')
  if lb >= 0:
    let rb = req.find(']', lb)
    if rb < 0 or req.find('[', lb + 1) in lb + 1 .. rb or
        req.find('[', rb) >= 0 or req.find(']', rb + 1) >= 0:
      reading.errors.add RequirementError(kind: reMalformed, input: item,
        reason: "a feature list is one '[...]' after the name")
      return
    for f in req[lb + 1 ..< rb].split(','):
      let name = f.strip
      if name.len == 0:
        reading.errors.add RequirementError(kind: reMalformed, input: item,
          reason: "empty feature name")
        return
      features.add name
    # `name[f]#ref` keeps the ref attached to the name, as `name#ref` is
    # written; a range is separated from the name by a space.
    let tail = req[rb + 1 .. ^1].strip
    req = (req[0 ..< lb].strip & (if tail.startsWith('#'): "" else: " ") &
           tail).strip
  elif ']' in req:
    reading.errors.add RequirementError(kind: reMalformed, input: item,
      reason: "unbalanced ']'")
    return
  var name, rest: string
  # Nimble splits at the first space if there is one, else at the first '#'.
  if ' ' in req:
    var i = 0
    while i < req.len and req[i] notin Whitespace:
      inc i
    name = req[0 ..< i]
    rest = req[i .. ^1]
  elif '#' in req:
    let i = req.find('#')
    name = req[0 ..< i]
    rest = req[i .. ^1]
  else:
    name = req
  var err = ""
  let target = readTarget(name, err)
  if err.len > 0:
    reading.errors.add RequirementError(kind: reMalformed, input: item, reason: err)
    return
  if target.kind == tkPackage and name.contains({':', '.', '/'}):
    # Nimble accepts such a name; the `uses:` grammar cannot spell it after
    # the namespace (a package name has no dot or colon).
    reading.errors.add RequirementError(kind: reUntranslatable, input: item,
      reason: "'" & name & "' cannot be spelled as a `nimble:` identity")
    return
  var version: VersionRequirement
  if rest.len == 0:
    version = VersionRequirement(kind: vkAny)
  elif rest[0] == '#':
    if rest.len == 1:
      reading.errors.add RequirementError(kind: reMalformed, input: item,
        reason: "'#' with no ref")
      return
    version = readSpecial(rest)
  else:
    try:
      let text = rangeText(rest)
      let parsed = parseSemverRange(text)
      version = VersionRequirement(kind: vkRange, written: rest.strip,
                                   normalized: text, range: parsed)
    except NimbleRangeError as e:
      reading.errors.add RequirementError(kind: reMalformed, input: item,
                                          reason: e.msg)
      return
    except RangeError as e:
      reading.errors.add RequirementError(kind: reUntranslatable, input: item,
                                          reason: e.msg)
      return
    except ESemverParse as e:
      reading.errors.add RequirementError(kind: reUntranslatable, input: item,
        reason: "the solver cannot parse the translation: " & e.msg)
      return
  reading.requirements.add Requirement(source: item.strip, target: target,
                                       version: version, features: features)

proc splitList*(s: string): seq[string] =
  ## Nimble's `multiSplit`: split on commas and line breaks, strip, drop
  ## empty items. Commas inside a feature list `[...]` do not split.
  var depth = 0
  var cur = ""
  for c in s:
    if c == '[':
      inc depth
    elif c == ']':
      dec depth
    if depth <= 0 and c in {',', '\n', '\r'}:
      if cur.strip.len > 0:
        result.add cur.strip
      cur = ""
    else:
      cur.add c
  if cur.strip.len > 0:
    result.add cur.strip

proc readRequirements*(text: string): RequirementReading =
  ## Read one `requires` string argument (which may hold a list).
  for item in splitList(text):
    readOne(item, result)

proc readRequirement*(text: string): Option[Requirement] =
  ## Convenience for a single requirement: `none` on any error.
  let r = readRequirements(text)
  if r.errors.len == 0 and r.requirements.len == 1:
    return some(r.requirements[0])
  none(Requirement)

proc `$`*(r: Requirement): string =
  ## A deterministic text view: identity or origin, then the version.
  result = case r.target.kind
    of tkPackage: identity(r.target.name)
    of tkUrl:
      r.target.url & (if r.target.subdir.len > 0: "?subdir=" & r.target.subdir
        else: "")
  case r.version.kind
  of vkAny: discard
  of vkRange: result.add " " & r.version.normalized
  of vkHead: result.add " #head"
  of vkCommit:
    result.add " #" & r.version.commit
    if r.version.abbreviated:
      result.add " (abbreviated)"
  of vkRef: result.add " #" & r.version.refName
  if r.features.len > 0:
    result.add " [" & r.features.join(", ") & "]"

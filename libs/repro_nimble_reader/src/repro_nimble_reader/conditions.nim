## `when` conditions as data (NPC-AREQ7).
##
## A `when` around `requires` is stored as a typed condition over a closed set
## of terms, and the solver evaluates it for the platform pair and the Nim
## version it solves for, so one record serves every platform and every Nim.
## The closed set is exactly:
##
##   * `defined(<os>)` and `defined(<cpu>)` for the Nim target names, and the
##     OS-family symbols `defined(posix)`, `defined(unix)` and `defined(bsd)`,
##   * `hostOS == "<os>"` and `hostCPU == "<cpu>"`,
##   * comparisons of the Nim version: `NimMajor`, `NimMinor` or `NimPatch`
##     with a decimal integer literal, `NimVersion` with a string literal, or
##     a tuple of `NimMajor`, `NimMinor` and `NimPatch` (a prefix of them, in
##     that order) with a tuple of as many integer literals, by `==`, `!=`,
##     `<`, `<=`, `>` or `>=`, the literal on either side,
##   * `and`, `or`, `not`, and parentheses.
##
## Every other condition is *undecidable* here: the requirement it guards is
## not offered to the solver, and the reader says which kind of condition it
## was (`UndecidableKind`) so an override author knows what to replace. Other
## uses of the version names (arithmetic, a non-literal operand, a literal
## that is not a plain decimal integer, a qualified `system.NimMajor`, a
## `NimVersion` string that is not printable ASCII of at most 64 bytes) and
## `declared(...)` / `compiles(...)` stay undecidable. The reader never evaluates a condition
## and never assumes one is false.
##
## Evaluation (``decide``) is the solver's. A `defined()` term holds for a
## target exactly when Nim's own `isDefined` holds it there (Nim 2.2.4
## `compiler/options.nim`). A Nim-version term is evaluated as Nim evaluates
## it: the three fields are integers, a tuple compares element by element
## from the left, and `NimVersion` is the string `"<major>.<minor>.<patch>"`
## compared as a string, so `NimVersion >= "1.6.0"` is false for 1.10.0.
## Without a Nim version, a condition whose value depends on one is
## `tUnknown`, never true or false.

{.push raises: [].}

import std/[options, strutils]

import ./lexer
import ./syntax

const
  ## The target names of Nim's `compiler/platform.nim` (Nim 2.2), lower-cased:
  ## what `defined(...)` and `hostOS`/`hostCPU` compare against. `js` and
  ## `nimvm` are both an OS and a CPU there.
  NimOsNames* = ["dos", "windows", "os2", "linux", "morphos", "skyos",
    "solaris", "irix", "netbsd", "freebsd", "openbsd", "dragonfly", "crossos",
    "aix", "palmos", "qnx", "amiga", "atari", "netware", "macos", "macosx",
    "ios", "haiku", "android", "vxworks", "genode", "js", "nimvm",
    "standalone", "nintendoswitch", "freertos", "zephyr", "nuttx", "any"]
  NimCpuNames* = ["i386", "m68k", "alpha", "powerpc", "powerpc64",
    "powerpc64el", "sparc", "vm", "hppa", "ia64", "amd64", "mips", "mipsel",
    "arm", "arm64", "js", "nimvm", "avr", "msp430", "sparc64", "mips64",
    "mips64el", "riscv32", "riscv64", "esp", "wasm32", "e2k", "loongarch64"]
  MaxNimVersionLiteralBytes* = 64
    ## the longest string a `NimVersion` comparison is read with (the
    ## version record's bound); a longer one is outside the set
  OsFamilyTerms* = ["posix", "unix", "bsd"]
    ## The OS-family symbols in the closed set (NPC-AREQ7, A3): terms of
    ## their own, evaluated from the target OS as Nim's `isDefined` does.
  PosixOses* = ["linux", "morphos", "skyos", "irix", "palmos", "qnx",
    "atari", "aix", "haiku", "vxworks", "solaris", "netbsd", "freebsd",
    "openbsd", "dragonfly", "macosx", "ios", "android", "nintendoswitch",
    "freertos", "crossos", "zephyr", "nuttx"]
    ## The target OSes for which Nim 2.2.4's `isDefined` (`compiler/
    ## options.nim`) answers `posix` and `unix`: the same set for both.
  BsdOses* = ["netbsd", "freebsd", "openbsd", "dragonfly", "crossos"]
    ## The target OSes for which Nim 2.2.4's `isDefined` answers `bsd`.
  ## Symbols the compiler defines from the target OS's family or CPU rather
  ## than its name, outside the closed set; recognised only to name them
  ## precisely.
  OtherFamilySymbols = ["osx", "x86", "emscripten", "wasm"]
  ## Calls that read the file system, the environment or run a process.
  EnvironmentCalls = ["fileexists", "direxists", "existsfile", "existsdir",
    "existsenv", "getenv", "gorge", "gorgeex", "staticexec", "exists",
    "findexe", "paramstr", "paramcount", "staticread", "thisdir", "getpkgdir"]
  ## Toolchain introspection.
  ToolchainNames = ["nimmajor", "nimminor", "nimpatch", "nimversion"]
  ToolchainCalls = ["declared", "compiles", "compileoption", "declaredinscope"]

type
  ConditionKind* = enum
    ckDefinedOs  ## `defined(<os>)`
    ckDefinedCpu ## `defined(<cpu>)`
    ckHostOsIs   ## `hostOS == "<os>"`
    ckHostCpuIs  ## `hostCPU == "<cpu>"`
    ckAnd
    ckOr
    ckNot
    ckOsFamily   ## `defined(posix)`, `defined(unix)`, `defined(bsd)`
    ckNimVersion ## a comparison of the Nim version with a literal

  NimVersionField* = enum
    ## The left-hand side of a Nim-version comparison, after normalisation.
    nfMajor = "NimMajor"
    nfMinor = "NimMinor"
    nfPatch = "NimPatch"
    nfVersion = "NimVersion"
    nfMajorMinor = "(NimMajor, NimMinor)"
    nfMajorMinorPatch = "(NimMajor, NimMinor, NimPatch)"

  CompareOp* = enum
    coEq = "=="
    coNe = "!="
    coLt = "<"
    coLe = "<="
    coGt = ">"
    coGe = ">="

  Condition* = ref object
    ## A condition over the closed term set. `nil` means "unconditional".
    case kind*: ConditionKind
    of ckDefinedOs, ckDefinedCpu, ckHostOsIs, ckHostCpuIs, ckOsFamily:
      name*: string ## the lower-case target name, or the family symbol
    of ckAnd, ckOr:
      left*, right*: Condition
    of ckNot:
      operand*: Condition
    of ckNimVersion:
      field*: NimVersionField
      op*: CompareOp
      ints*: seq[int64]
        ## the integer literal (one), or the tuple's literals (two or
        ## three); empty for `NimVersion`
      text*: string ## the string literal `NimVersion` is compared with

  NimVersionValue* = object
    ## A Nim version as the compiler's `NimMajor`, `NimMinor` and
    ## `NimPatch` (`intdefine`s) hold it.
    major*, minor*, patch*: int64

  Truth* = enum
    ## A condition's value, three-valued: ``tUnknown`` when it depends on a
    ## Nim version and none is given.
    tFalse, tTrue, tUnknown

  UndecidableKind* = enum
    ## Why a condition is outside the closed set.
    ukToolchain = "toolchain"
      ## `NimMajor` outside a literal comparison, `declared(...)`,
      ## `defined(nimXxx)`
    ukOsFamily = "os-family"              ## `defined(osx)` and the like
    ukOtherDefine = "other-define"        ## `defined(release)`, any non-target symbol
    ukEnvironment = "environment"         ## `fileExists`, `getEnv`, ...
    ukLiteral = "literal"                 ## `true` / `false`
    ukUnknownName = "unknown-target-name" ## `hostOS == "osx"`
    ukRuntimeIf = "runtime-if"            ## a runtime `if`, not a `when`
    ukOther = "other"                     ## anything else

  ConditionReading* = object
    ## The result of reading one `when` condition.
    case decidable*: bool
    of true:
      condition*: Condition
    of false:
      why*: UndecidableKind
      text*: string ## the condition as written

const
  ClosedTermKinds* = {ckDefinedOs, ckDefinedCpu, ckHostOsIs, ckHostCpuIs,
                      ckOsFamily, ckNimVersion}

proc definedOs*(name: string): Condition = Condition(kind: ckDefinedOs, name: name)
proc definedCpu*(name: string): Condition = Condition(kind: ckDefinedCpu, name: name)
proc hostOsIs*(name: string): Condition = Condition(kind: ckHostOsIs, name: name)
proc hostCpuIs*(name: string): Condition = Condition(kind: ckHostCpuIs, name: name)
proc osFamily*(name: string): Condition = Condition(kind: ckOsFamily, name: name)

proc nimVersionIs*(field: NimVersionField; op: CompareOp; ints: seq[int64];
                   text = ""): Condition =
  ## A Nim-version comparison with the field on the left.
  Condition(kind: ckNimVersion, field: field, op: op, ints: ints, text: text)

proc conjoin*(a, b: Condition): Condition =
  ## `a and b`, where `nil` is "true".
  if a.isNil: return b
  if b.isNil: return a
  Condition(kind: ckAnd, left: a, right: b)

proc negate*(a: Condition): Condition =
  Condition(kind: ckNot, operand: a)

proc nimLiteralText(c: Condition): string =
  case c.field
  of nfVersion: c.text.escape()
  of nfMajor, nfMinor, nfPatch: (if c.ints.len > 0: $c.ints[0] else: "?")
  of nfMajorMinor, nfMajorMinorPatch:
    var parts: seq[string]
    for i in c.ints: parts.add $i
    "(" & parts.join(", ") & ")"

proc `$`*(c: Condition): string =
  ## A deterministic rendering in Nim syntax, fully parenthesised.
  if c.isNil:
    return "true"
  case c.kind
  of ckDefinedOs, ckDefinedCpu, ckOsFamily: "defined(" & c.name & ")"
  of ckHostOsIs: "hostOS == \"" & c.name & "\""
  of ckHostCpuIs: "hostCPU == \"" & c.name & "\""
  of ckNimVersion: $c.field & " " & $c.op & " " & nimLiteralText(c)
  of ckAnd: "(" & $c.left & " and " & $c.right & ")"
  of ckOr: "(" & $c.left & " or " & $c.right & ")"
  of ckNot: "not (" & $c.operand & ")"

proc `==`*(a, b: Condition): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  case a.kind
  of ckDefinedOs, ckDefinedCpu, ckHostOsIs, ckHostCpuIs, ckOsFamily:
    a.name == b.name
  of ckNimVersion:
    a.field == b.field and a.op == b.op and a.ints == b.ints and
      a.text == b.text
  of ckAnd, ckOr: a.left == b.left and a.right == b.right
  of ckNot: a.operand == b.operand

proc mentionsNimVersion*(c: Condition): bool =
  ## Whether ``c`` has a Nim-version term anywhere.
  if c.isNil:
    return false
  case c.kind
  of ckNimVersion: true
  of ckAnd, ckOr: mentionsNimVersion(c.left) or mentionsNimVersion(c.right)
  of ckNot: mentionsNimVersion(c.operand)
  else: false

proc definedForOs(symbol, targetOs: string): bool =
  ## Nim's `defined(<os>)` for a target OS name, as `compiler/options.nim`
  ## `isDefined` answers it (Nim 2.2): the target's own name, and three names
  ## that also hold on a derived target — `linux` on Android, `macosx` on iOS
  ## and `freebsd` on CROSSOS. `hostOS` has no such aliases: it is the
  ## target's own name, compared as a string.
  if symbol == targetOs:
    return true
  case symbol
  of "linux": targetOs == "android"
  of "macosx": targetOs == "ios"
  of "freebsd": targetOs == "crossos"
  else: false

proc definedFamily*(symbol, targetOs: string): bool =
  ## Nim 2.2.4's `isDefined` for an OS-family symbol on a target OS:
  ## `posix` and `unix` hold for ``PosixOses``, `bsd` for ``BsdOses``.
  case symbol
  of "posix", "unix": targetOs in PosixOses
  of "bsd": targetOs in BsdOses
  else: false

proc nimVersionText*(v: NimVersionValue): string =
  ## `NimVersion` as the compiler defines it: `$NimMajor & "." & $NimMinor
  ## & "." & $NimPatch`.
  $v.major & "." & $v.minor & "." & $v.patch

proc parseNimVersionValue*(text: string; v: var NimVersionValue): bool =
  ## A Nim toolchain version (`2.2.4`; missing components are 0) as the
  ## three integer fields. False for anything else.
  let parts = text.strip().split('.')
  if parts.len == 0 or parts.len > 3:
    return false
  var vals = [0'i64, 0, 0]
  for i, p in parts:
    if p.len == 0 or p.len > 18:
      return false
    for c in p:
      if c notin {'0'..'9'}:
        return false
    try:
      vals[i] = parseBiggestInt(p)
    except ValueError:
      return false
  v = NimVersionValue(major: vals[0], minor: vals[1], patch: vals[2])
  true

proc compareWith(cmpResult: int; op: CompareOp): bool =
  case op
  of coEq: cmpResult == 0
  of coNe: cmpResult != 0
  of coLt: cmpResult < 0
  of coLe: cmpResult <= 0
  of coGt: cmpResult > 0
  of coGe: cmpResult >= 0

proc evaluateNim*(c: Condition; v: NimVersionValue): bool =
  ## A Nim-version term at Nim ``v``, exactly as Nim evaluates it: integers
  ## for the fields, element-wise from the left for a tuple (`system`'s
  ## tuple `<`/`<=`/`==`), and a string comparison for `NimVersion`
  ## (`system.cmp` on strings, byte by byte).
  let fields = [v.major, v.minor, v.patch]
  var r = 0
  case c.field
  of nfVersion:
    r = cmp(nimVersionText(v), c.text)
  of nfMajor, nfMinor, nfPatch:
    let mine = fields[ord(c.field) - ord(nfMajor)]
    r = cmp(mine, c.ints[0])
  of nfMajorMinor, nfMajorMinorPatch:
    let n = if c.field == nfMajorMinor: 2 else: 3
    for i in 0 ..< n:
      r = cmp(fields[i], c.ints[i])
      if r != 0: break
  compareWith(r, c.op)

proc toTruth(b: bool): Truth = (if b: tTrue else: tFalse)

proc decide*(c: Condition; targetOs, targetCpu, hostOs, hostCpu: string;
             nim = none(NimVersionValue)): Truth =
  ## Evaluate for one platform pair (lower-case Nim target names) and, when
  ## given, one Nim version. This is what the solver does; the reader itself
  ## never calls it. Without ``nim`` a Nim-version term is ``tUnknown`` and
  ## the connectives follow Kleene's logic, so a condition the platform
  ## alone decides (`defined(windows) and NimMajor >= 2` on Linux) is still
  ## decided.
  if c.isNil:
    return tTrue
  case c.kind
  of ckDefinedOs: toTruth(definedForOs(c.name, targetOs))
  of ckDefinedCpu: toTruth(c.name == targetCpu)
  of ckHostOsIs: toTruth(c.name == hostOs)
  of ckHostCpuIs: toTruth(c.name == hostCpu)
  of ckOsFamily: toTruth(definedFamily(c.name, targetOs))
  of ckNimVersion:
    if nim.isNone: tUnknown else: toTruth(evaluateNim(c, nim.get))
  of ckAnd:
    let l = decide(c.left, targetOs, targetCpu, hostOs, hostCpu, nim)
    if l == tFalse: return tFalse
    let r = decide(c.right, targetOs, targetCpu, hostOs, hostCpu, nim)
    if r == tFalse: tFalse
    elif l == tTrue and r == tTrue: tTrue
    else: tUnknown
  of ckOr:
    let l = decide(c.left, targetOs, targetCpu, hostOs, hostCpu, nim)
    if l == tTrue: return tTrue
    let r = decide(c.right, targetOs, targetCpu, hostOs, hostCpu, nim)
    if r == tTrue: tTrue
    elif l == tFalse and r == tFalse: tFalse
    else: tUnknown
  of ckNot:
    case decide(c.operand, targetOs, targetCpu, hostOs, hostCpu, nim)
    of tTrue: tFalse
    of tFalse: tTrue
    of tUnknown: tUnknown

proc evaluate*(c: Condition; targetOs, targetCpu, hostOs,
    hostCpu: string): bool =
  ## ``decide`` for a platform pair with no Nim version: true only when the
  ## condition holds whatever the Nim version (a condition that depends on
  ## one is not true without it).
  decide(c, targetOs, targetCpu, hostOs, hostCpu) == tTrue

proc evaluate*(c: Condition; targetOs, targetCpu, hostOs, hostCpu: string;
               nim: NimVersionValue): bool =
  ## ``decide`` for a platform pair and a Nim version: always decided.
  decide(c, targetOs, targetCpu, hostOs, hostCpu, some(nim)) == tTrue

proc undecidable(why: UndecidableKind): ConditionReading =
  ConditionReading(decidable: false, why: why)

proc calleeName(e: Expr): string =
  if e.kind in {ekCall, ekCommand} and e.kids.len > 0 and
      e.kids[0].kind == ekIdent:
    return e.kids[0].text
  ""

proc mentionsAny(e: Expr; names: openArray[string]): bool =
  if e.isNil:
    return false
  if e.kind == ekIdent and styleKey(e.text) in names:
    return true
  for k in e.kids:
    if mentionsAny(k, names):
      return true
  false

proc classifyOutside(e: Expr): UndecidableKind =
  ## Name the kind of a condition already known to be outside the set.
  if mentionsAny(e, ToolchainNames) or mentionsAny(e, ToolchainCalls):
    return ukToolchain
  if mentionsAny(e, EnvironmentCalls):
    return ukEnvironment
  ukOther

proc readTerm(e: Expr): ConditionReading

proc readCondition*(e: Expr): ConditionReading =
  ## Read a parsed `when` condition into the closed set, or say why not.
  if e.isNil or e.kind == ekOther:
    return undecidable(ukOther)
  case e.kind
  of ekPar:
    if e.kids.len == 1:
      return readCondition(e.kids[0])
    return undecidable(if mentionsAny(e,
        ToolchainNames): ukToolchain else: ukOther)
  of ekInfix:
    if e.text in ["and", "or"]:
      let l = readCondition(e.kids[0])
      let r = readCondition(e.kids[1])
      if not l.decidable:
        return l
      if not r.decidable:
        return r
      let combined =
        if e.text == "and": Condition(kind: ckAnd, left: l.condition,
                                      right: r.condition)
        else: Condition(kind: ckOr, left: l.condition, right: r.condition)
      return ConditionReading(decidable: true, condition: combined)
    return readTerm(e)
  of ekPrefix:
    if e.text == "not":
      let inner = readCondition(e.kids[0])
      if not inner.decidable:
        return inner
      return ConditionReading(decidable: true, condition: negate(
          inner.condition))
    return undecidable(classifyOutside(e))
  else:
    return readTerm(e)

const ComparisonOps = ["==", "!=", "<", "<=", ">", ">="]

proc flipped(op: CompareOp): CompareOp =
  ## The operator with its operands swapped: `2 <= NimMajor` is
  ## `NimMajor >= 2`.
  case op
  of coEq, coNe: op
  of coLt: coGt
  of coLe: coGe
  of coGt: coLt
  of coGe: coLe

proc unwrapPar(e: Expr): Expr =
  ## `(x)` is `x`. (A one-element tuple `(x,)` reads the same here; Nim
  ## compares it with a one-element tuple as it compares `x` with a value.)
  result = e
  while result.kind == ekPar and result.kids.len == 1:
    result = result.kids[0]

proc versionFieldOf(e: Expr; field: var NimVersionField): bool =
  ## The version name an operand is: one of the four identifiers, or a
  ## tuple of a prefix of `NimMajor`, `NimMinor`, `NimPatch` of length two
  ## or three. Nim identifiers: first character exact, the rest style
  ## insensitive (``nimIdentEq``).
  let x = unwrapPar(e)
  if x.kind == ekIdent:
    for f in [nfMajor, nfMinor, nfPatch, nfVersion]:
      if nimIdentEq(x.text, $f):
        field = f
        return true
    return false
  if x.kind == ekPar and x.kids.len in 2..3:
    for i, k in x.kids:
      if k.kind != ekIdent or not nimIdentEq(k.text, $[nfMajor, nfMinor,
          nfPatch][i]):
        return false
    field = if x.kids.len == 2: nfMajorMinor else: nfMajorMinorPatch
    return true
  false

proc decimalLiteral(e: Expr; v: var int64): bool =
  ## A plain decimal integer literal (digits only, fitting in 63 bits).
  let x = unwrapPar(e)
  if x.kind != ekNumber or x.text.len == 0 or x.text.len > 18:
    return false
  for c in x.text:
    if c notin {'0'..'9'}:
      return false
  try:
    v = parseBiggestInt(x.text)
  except ValueError:
    return false
  true

proc literalFor(field: NimVersionField; e: Expr; ints: var seq[int64];
                text: var string): bool =
  ## The literal a version name is compared with, of the shape Nim's types
  ## require: an integer for a field, a string for `NimVersion`, a tuple of
  ## as many integers for a tuple.
  ints = @[]
  text = ""
  let x = unwrapPar(e)
  case field
  of nfVersion:
    # A literal the version record can hold: printable ASCII, at most
    # ``MaxNimVersionLiteralBytes`` (the record's bound; spec § 4.4).
    if x.kind != ekString or x.text.len > MaxNimVersionLiteralBytes:
      return false
    for ch in x.text:
      if ord(ch) < 0x20 or ord(ch) > 0x7e:
        return false
    text = x.text
    true
  of nfMajor, nfMinor, nfPatch:
    var v = 0'i64
    if not decimalLiteral(x, v):
      return false
    ints = @[v]
    true
  of nfMajorMinor, nfMajorMinorPatch:
    let n = if field == nfMajorMinor: 2 else: 3
    if x.kind != ekPar or x.kids.len != n:
      return false
    for k in x.kids:
      var v = 0'i64
      if not decimalLiteral(k, v):
        return false
      ints.add v
    true

proc readNimVersionTerm(e: Expr): ConditionReading =
  ## A comparison of a version name with a literal of its type, on either
  ## side, normalised so the name is on the left (NPC-AREQ7, A3). Anything
  ## else is not decidable here (the caller names it).
  if e.kind != ekInfix or e.kids.len != 2 or e.text notin ComparisonOps:
    return undecidable(ukToolchain)
  var op = coEq
  for o in CompareOp:
    if $o == e.text:
      op = o
  for (name, lit, swapped) in [(e.kids[0], e.kids[1], false),
                               (e.kids[1], e.kids[0], true)]:
    var field = nfMajor
    if not versionFieldOf(name, field):
      continue
    var ints: seq[int64]
    var text = ""
    if literalFor(field, lit, ints, text):
      return ConditionReading(decidable: true, condition: nimVersionIs(field,
        (if swapped: flipped(op) else: op), ints, text))
  undecidable(ukToolchain)

proc readTerm(e: Expr): ConditionReading =
  case e.kind
  of ekCall, ekCommand:
    let callee = calleeName(e)
    if nimIdentEq(callee, "not") and e.kids.len == 2:
      let inner = readCondition(e.kids[1])
      if not inner.decidable:
        return inner
      return ConditionReading(decidable: true, condition: negate(
          inner.condition))
    if nimIdentEq(callee, "defined") and e.kids.len == 2 and
        e.kids[1].kind == ekIdent:
      # `defined` looks symbols up case- and underscore-insensitively.
      let sym = styleKey(e.kids[1].text)
      if sym in NimOsNames:
        return ConditionReading(decidable: true, condition: definedOs(sym))
      if sym in NimCpuNames:
        return ConditionReading(decidable: true, condition: definedCpu(sym))
      if sym in OsFamilyTerms:
        return ConditionReading(decidable: true, condition: osFamily(sym))
      if sym in OtherFamilySymbols:
        return undecidable(ukOsFamily)
      if sym.startsWith("nim") and sym notin ["nimdistros", "nimble"]:
        return undecidable(ukToolchain)
      return undecidable(ukOtherDefine)
    return undecidable(classifyOutside(e))
  of ekInfix:
    let nimTerm = readNimVersionTerm(e)
    if nimTerm.decidable:
      return nimTerm
    if e.text == "==":
      for (a, b) in [(e.kids[0], e.kids[1]), (e.kids[1], e.kids[0])]:
        if a.kind == ekIdent and b.kind == ekString:
          # `hostOS` is a constant: its value is compared exactly.
          if nimIdentEq(a.text, "hostOS"):
            if b.text in NimOsNames:
              return ConditionReading(decidable: true, condition: hostOsIs(b.text))
            return undecidable(ukUnknownName)
          if nimIdentEq(a.text, "hostCPU"):
            if b.text in NimCpuNames:
              return ConditionReading(decidable: true, condition: hostCpuIs(b.text))
            return undecidable(ukUnknownName)
    return undecidable(classifyOutside(e))
  of ekIdent:
    if e.text in ["true", "false"]:
      return undecidable(ukLiteral)
    return undecidable(classifyOutside(e))
  else:
    return undecidable(classifyOutside(e))

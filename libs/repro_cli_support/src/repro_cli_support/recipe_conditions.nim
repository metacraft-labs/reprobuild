## Deciding, for one lock, whether a `uses:` entry written under a `when` /
## `if` / `case` arm applies to it.
##
## A lock is resolved for ONE platform and one variant assignment, and it
## records both: `[lock] platform` (`hostCPU & "-" & hostOS`, e.g.
## `amd64-linux`) and `[lock] variants`. The arms a recipe's dependency block
## is compiled with for that lock are therefore facts about the lock, and the
## recipe/lock consistency check (H1, Unified-Locking-And-Hooks.md §16.3)
## holds the lock to every constraint whose arm applies to it. Before this, an
## entry under any arm was listed as "not checked" and the gate passed, so the
## usual way to state a toolchain floor — per platform — was never checked.
##
## Two kinds of arm, decided the way the DSL decides them
## (`lowerUsesBody` in `repro_project_dsl/macros_a.nim`):
##
## * **`when`** is a compile-time question; the compiler answers it when it
##   compiles the provider for the lock's platform. This module answers the
##   part of it that the platform alone decides: `defined(<symbol>)` for the
##   symbols Nim derives from the target OS and CPU, `hostOS` / `hostCPU`
##   compared with a string literal, `true`, `false`, combined with `not`,
##   `and`, `or` and parentheses. ``nimDefinedForTarget`` mirrors the Nim
##   compiler's own `isDefined` (`compiler/options.nim`, Nim 2.2) for those
##   symbols. Any other operand — a `-d:` define, a `const`, a call — is
##   UNDECIDABLE, and the logic is three-valued (Kleene), so
##   `defined(linux) or defined(foo)` is still true on Linux and
##   `defined(macosx) and defined(foo)` still false there.
## * **`if` / `case`** inside a dependency block is a variant gate when the DSL
##   lowers it as one: an `if` with exactly one condition arm whose condition
##   is `<variant>.value` or a bare `<variant>`, or a `case <variant>.value` /
##   `case <variant>`, its `of` arms each labelled by ONE literal. Such an arm
##   applies when the lock's recorded value of that variant equals the arm's
##   value (`true` / `false` for an `if`). Every other `if` / `case` arm the
##   DSL lowers UNGATED — every arm contributes its entries — and so does an
##   arm nested inside a gated arm (the DSL keeps the outer gate); those apply.
##   An `if` / `case` written around the dependency block is not lowered by
##   the DSL at all, and is undecidable here.
##
## Every answer that is not "applies" or "does not apply" is undecidable, with
## a reason, and the callers list it (`notChecked`) rather than pass or refuse
## it. The module is pure: it reads the guards the text scan recorded
## (``ReproGuard``) and the two facts of the lock, and nothing else.

import std/[strutils, tables]

import repro_cli_support/recipe_constraints

type
  Tri* = enum
    ## A three-valued truth: Kleene's strong logic.
    triFalse
    triTrue
    triUnknown

  LockArmFacts* = object
    ## What a lock records that decides an arm.
    platform*: string
      ## `[lock] platform` as written (`amd64-linux`), "" when absent.
    os*, cpu*: string
      ## Its two halves, lowercase; "" when the platform is absent or not a
      ## Nim target this module knows.
    variants*: Table[string, string]
      ## `[lock] variants`: variant name -> the value the solve chose.

  ArmApplicability* = enum
    aaApplies      ## every arm the entry is under applies to the lock
    aaExcluded     ## some arm the entry is under does not apply
    aaUndecidable  ## neither can be established from the lock's facts

  ArmVerdict* = object
    applicability*: ArmApplicability
    reason*: string
      ## For ``aaUndecidable``, why — naming the arm and its line. For
      ## ``aaExcluded``, which arm excludes it. "" for ``aaApplies``.

# ---------------------------------------------------------------------------
# Nim's platform symbols (compiler/platform.nim, compiler/options.nim)
# ---------------------------------------------------------------------------

const
  NimOsNames = ["dos", "windows", "os2", "linux", "morphos", "skyos",
    "solaris", "irix", "netbsd", "freebsd", "openbsd", "dragonfly",
    "crossos", "aix", "palmos", "qnx", "amiga", "atari", "netware", "macos",
    "macosx", "ios", "haiku", "android", "vxworks", "genode", "js", "nimvm",
    "standalone", "nintendoswitch", "freertos", "zephyr", "nuttx", "any"]
    ## `platform.OS[*].name`, normalized. `hostOS` is one of these.
  NimCpus: array[29, tuple[name: string; bits: int; little: bool]] = [
    ("i386", 32, true), ("m68k", 32, false), ("alpha", 64, true),
    ("powerpc", 32, false), ("powerpc64", 64, false),
    ("powerpc64el", 64, true), ("sparc", 32, false), ("vm", 32, true),
    ("hppa", 32, false), ("ia64", 64, true), ("amd64", 64, true),
    ("mips", 32, false), ("mipsel", 32, true), ("arm", 32, true),
    ("arm64", 64, true), ("js", 32, true), ("nimvm", 32, false),
    ("avr", 16, true), ("msp430", 16, true), ("sparc64", 64, false),
    ("s390x", 64, false), ("mips64", 64, false), ("mips64el", 64, true),
    ("riscv32", 32, true), ("riscv64", 64, true), ("esp", 32, true),
    ("wasm32", 32, true), ("e2k", 64, true), ("loongarch64", 64, true)]
    ## `platform.CPU[*]`: name, bit width, little-endian. `hostCPU` is one
    ## of these names.
  NimPosixOses = ["linux", "morphos", "skyos", "irix", "palmos", "qnx",
    "atari", "aix", "haiku", "vxworks", "solaris", "netbsd", "freebsd",
    "openbsd", "dragonfly", "macosx", "ios", "android", "nintendoswitch",
    "freertos", "crossos", "zephyr", "nuttx"]
    ## The targets `defined(posix)` / `defined(unix)` is true for.

proc cpuIndex(cpu: string): int =
  for i, c in NimCpus:
    if c.name == cpu: return i
  -1

proc lockArmFacts*(platform: string;
    variants: openArray[tuple[name, value: string]]): LockArmFacts =
  ## The facts a lock records, from its `platform` and `variants`.
  result.platform = platform
  let p = platform.strip().toLowerAscii()
  let dash = p.find('-')
  if dash > 0:
    let cpu = p[0 ..< dash]
    let os = p[dash + 1 .. ^1]
    if cpuIndex(cpu) >= 0 and os in NimOsNames:
      result.cpu = cpu
      result.os = os
  for v in variants:
    result.variants[v.name] = v.value

proc toTri(b: bool): Tri {.inline.} = (if b: triTrue else: triFalse)

proc nimDefinedForTarget*(symbol, os, cpu: string): Tri =
  ## `defined(symbol)` for a provider compiled for ``os`` / ``cpu`` (Nim's
  ## `hostOS` / `hostCPU` names), as `compiler/options.nim` `isDefined`
  ## answers it — for the symbols that function derives from the target.
  ## Any other symbol is a `-d:` define or a compiler-version symbol, which
  ## the lock does not record: ``triUnknown``.
  if os.len == 0 or cpu.len == 0: return triUnknown
  let s = symbol.normalize()   # Nim compares defines style-insensitively
  if s == cpu or s == os: return triTrue
  let c = NimCpus[cpuIndex(cpu)]
  case s
  of "x86": toTri(cpu == "i386")
  of "itanium": toTri(cpu == "ia64")
  of "x8664": toTri(cpu == "amd64")
  of "posix", "unix": toTri(os in NimPosixOses)
  of "linux": toTri(os in ["linux", "android"])
  of "bsd": toTri(os in ["netbsd", "freebsd", "openbsd", "dragonfly",
    "crossos"])
  of "freebsd": toTri(os in ["freebsd", "crossos"])
  of "msdos": toTri(os == "dos")
  of "mswindows", "win32": toTri(os == "windows")
  of "macintosh": toTri(os in ["macos", "macosx", "ios"])
  of "osx", "macosx": toTri(os in ["macosx", "ios"])
  of "sunos": toTri(os == "solaris")
  of "nintendoswitch": toTri(os == "nintendoswitch")
  of "freertos", "lwip": toTri(os == "freertos")
  of "zephyr": toTri(os == "zephyr")
  of "nuttx": toTri(os == "nuttx")
  of "littleendian": toTri(c.little)
  of "bigendian": toTri(not c.little)
  of "cpu8": toTri(c.bits == 8)
  of "cpu16": toTri(c.bits == 16)
  of "cpu32": toTri(c.bits == 32)
  of "cpu64": toTri(c.bits == 64)
  else:
    # Another OS or CPU name is false for this target; anything else is not
    # a platform symbol.
    if s in NimOsNames or cpuIndex(s) >= 0: triFalse
    else: triUnknown

# ---------------------------------------------------------------------------
# A `when` condition
# ---------------------------------------------------------------------------

type
  TokKind = enum tkIdent, tkString, tkLParen, tkRParen, tkEq, tkNe, tkEnd,
    tkBad
  Tok = object
    kind: TokKind
    text: string

proc tokenize(s: string): seq[Tok] =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in Whitespace:
      inc i
    elif c in IdentStartChars:
      var j = i
      while j < s.len and s[j] in IdentChars: inc j
      result.add(Tok(kind: tkIdent, text: s[i ..< j]))
      i = j
    elif c == '"':
      var j = i + 1
      var value = ""
      while j < s.len and s[j] != '"':
        if s[j] == '\\':
          return @[Tok(kind: tkBad)]   # escapes: not a platform name
        value.add(s[j])
        inc j
      if j >= s.len: return @[Tok(kind: tkBad)]
      result.add(Tok(kind: tkString, text: value))
      i = j + 1
    elif c == '(':
      result.add(Tok(kind: tkLParen)); inc i
    elif c == ')':
      result.add(Tok(kind: tkRParen)); inc i
    elif s.continuesWith("==", i):
      result.add(Tok(kind: tkEq)); i += 2
    elif s.continuesWith("!=", i):
      result.add(Tok(kind: tkNe)); i += 2
    else:
      return @[Tok(kind: tkBad)]
  result.add(Tok(kind: tkEnd))

proc evalWhenCondition*(condition: string; facts: LockArmFacts): Tri =
  ## A `when` condition for the lock's platform. The grammar is the part of
  ## Nim's expression grammar a platform question is written in, with Nim's
  ## precedence (`not` binds tighter than `and`, `and` than `or`, a
  ## comparison tighter than both):
  ##
  ##   expr    = andExpr ("or" andExpr)*
  ##   andExpr = unary ("and" unary)*
  ##   unary   = "not" unary | primary
  ##   primary = "(" expr ")" | "defined" "(" ident ")" | "true" | "false"
  ##           | ("hostOS" | "hostCPU") ("==" | "!=") string
  ##           | string ("==" | "!=") ("hostOS" | "hostCPU")
  ##
  ## Text outside it does not parse, and is ``triUnknown`` as a whole.
  let toks = tokenize(condition)
  if toks.len == 0 or toks[0].kind == tkBad: return triUnknown
  var pos = 0
  var failed = false
  proc peekIdent(word: string): bool =
    toks[pos].kind == tkIdent and toks[pos].text.normalize == word
  proc hostValue(name: string): string =
    case name.normalize
    of "hostos": facts.os
    of "hostcpu": facts.cpu
    else: "\0"
  proc compare(name, literal: string; equal: bool): Tri =
    let have = hostValue(name)
    if have == "\0":
      failed = true
      return triUnknown
    if have.len == 0: return triUnknown
    toTri((have == literal) == equal)
  proc parseOr(): Tri
  proc parsePrimary(): Tri =
    let t = toks[pos]
    case t.kind
    of tkLParen:
      inc pos
      result = parseOr()
      if toks[pos].kind != tkRParen:
        failed = true
        return triUnknown
      inc pos
    of tkString:
      inc pos
      let op = toks[pos].kind
      if op notin {tkEq, tkNe} or toks[pos + 1].kind != tkIdent:
        failed = true
        return triUnknown
      let name = toks[pos + 1].text
      pos += 2
      result = compare(name, t.text, op == tkEq)
    of tkIdent:
      case t.text.normalize
      of "true":
        inc pos
        result = triTrue
      of "false":
        inc pos
        result = triFalse
      of "defined":
        if toks[pos + 1].kind != tkLParen or toks[pos + 2].kind != tkIdent or
            toks[pos + 3].kind != tkRParen:
          failed = true
          return triUnknown
        let symbol = toks[pos + 2].text
        pos += 4
        result = nimDefinedForTarget(symbol, facts.os, facts.cpu)
      else:
        let op = toks[pos + 1].kind
        if op in {tkEq, tkNe} and toks[pos + 2].kind == tkString:
          result = compare(t.text, toks[pos + 2].text, op == tkEq)
          pos += 3
        else:
          failed = true
          return triUnknown
    else:
      failed = true
      return triUnknown
  proc parseUnary(): Tri =
    if peekIdent("not"):
      inc pos
      let v = parseUnary()
      return case v
        of triTrue: triFalse
        of triFalse: triTrue
        of triUnknown: triUnknown
    parsePrimary()
  proc parseAnd(): Tri =
    result = parseUnary()
    while not failed and peekIdent("and"):
      inc pos
      let r = parseUnary()
      if result == triFalse or r == triFalse: result = triFalse
      elif result == triUnknown or r == triUnknown: result = triUnknown
      else: result = triTrue
  proc parseOr(): Tri =
    result = parseAnd()
    while not failed and peekIdent("or"):
      inc pos
      let r = parseAnd()
      if result == triTrue or r == triTrue: result = triTrue
      elif result == triUnknown or r == triUnknown: result = triUnknown
      else: result = triFalse
  let v = parseOr()
  if failed or toks[pos].kind != tkEnd: triUnknown else: v

# ---------------------------------------------------------------------------
# Variant gates, as the DSL lowers them
# ---------------------------------------------------------------------------

proc variantSelectorName*(expr: string): string =
  ## `<variant>.value` or a bare `<variant>` — the DSL's
  ## `variantSelectorName` (`macros_a.nim`), read from text. "" otherwise.
  let e = expr.strip()
  var name = e
  let dot = e.find('.')
  if dot >= 0:
    if e[dot + 1 .. ^1].strip().normalize != "value": return ""
    name = e[0 ..< dot].strip()
  if name.len == 0 or name[0] notin IdentStartChars: return ""
  for ch in name:
    if ch notin IdentChars: return ""
  name

proc caseLabelValue*(label: string): string =
  ## One `of` label as the DSL's `literalCaseLabel` lowers it: a string
  ## literal's value, `true` / `false`, an integer's decimal spelling; ""
  ## for anything else (several labels, a range, a name), which the DSL
  ## lowers ungated.
  let l = label.strip()
  if l.len >= 2 and l[0] == '"' and l[^1] == '"':
    let inner = l[1 .. ^2]
    if '"' in inner or '\\' in inner: return ""
    return inner
  case l.normalize
  of "true": return "true"
  of "false": return "false"
  else: discard
  var digits = l.replace("_", "")
  if digits.len > 0 and digits[0] == '-': digits = digits[1 .. ^1]
  if digits.len > 0 and digits.allCharsInSet(Digits):
    try: return $parseBiggestInt(l.replace("_", ""))
    except ValueError: return ""
  ""

proc describeArm(g: ReproGuard): string =
  let kw = g.keywords[g.arm]
  let cond = g.conditions[g.arm]
  "`" & (if g.kind == rgkCase and kw == "of": "case " & g.subject & " of " &
           cond
         elif cond.len > 0: kw & " " & cond
         else: kw) & "` (line " & $g.line & ")"

# ---------------------------------------------------------------------------
# The verdict for one entry
# ---------------------------------------------------------------------------

proc armApplicability*(decl: ReproUsesDeclaration;
    facts: LockArmFacts): ArmVerdict =
  ## Does the lock described by ``facts`` carry ``decl``'s constraint? An
  ## unconditional entry always applies. Each guard is decided in turn,
  ## outermost first; a guard that does not apply excludes the entry whatever
  ## the others say, and an undecidable guard leaves it undecidable otherwise.
  result.applicability = aaApplies
  var gated = false
    ## An enclosing in-block `if` / `case` arm is already a variant gate: the
    ## DSL then lowers every nested `if` / `case` arm under that gate.
  var undecided = ""
  for g in decl.guards:
    var v = triTrue
    var why = ""
    case g.kind
    of rgkUnpaired:
      v = triUnknown
      why = "under " & describeArm(g) & ", whose statement the text scan " &
        "could not pair it with"
    of rgkWhen:
      for j in 0 .. g.arm:
        let c =
          if g.keywords[j] == "else": triTrue
          else: evalWhenCondition(g.conditions[j], facts)
        # Arm j < arm applies only if its condition is false; the entry's
        # own arm needs its condition true.
        let term =
          if j < g.arm:
            (case c
             of triTrue: triFalse
             of triFalse: triTrue
             of triUnknown: triUnknown)
          else: c
        if term == triFalse:
          v = triFalse
          break
        if term == triUnknown: v = triUnknown
      if v == triUnknown:
        why = "under " & describeArm(g) & ", a `when` whose conditions do " &
          "not depend only on the lock's platform" &
          (if facts.platform.len > 0: " (" & facts.platform & ")"
           else: " (the lock records none)")
      elif v == triFalse:
        why = "under " & describeArm(g) & ", which does not apply to " &
          "the lock's platform " & facts.platform
    of rgkIf, rgkCase:
      if not g.insideBlock:
        v = triUnknown
        why = "under " & describeArm(g) & ", an `" & $g.kind & "` around " &
          "the dependency block, which only running the recipe decides"
      elif gated:
        v = triTrue
      else:
        var variant = ""
        var wanted = ""
        if g.kind == rgkIf:
          var condArms = 0
          for kw in g.keywords:
            if kw in ["if", "elif"]: inc condArms
          if condArms == 1:
            variant = variantSelectorName(g.conditions[0])
            wanted = if g.keywords[g.arm] == "else": "false" else: "true"
        else:
          variant = variantSelectorName(g.subject)
          if variant.len > 0 and g.keywords[g.arm] == "of":
            wanted = caseLabelValue(g.conditions[g.arm])
          if wanted.len == 0: variant = ""
        if variant.len == 0:
          # Not a gate: the DSL lowers every arm of it, ungated.
          v = triTrue
        else:
          gated = true
          if variant notin facts.variants:
            v = triUnknown
            why = "under " & describeArm(g) & ", a gate on variant '" &
              variant & "', for which the lock records no value"
          elif facts.variants[variant] == wanted:
            v = triTrue
          else:
            v = triFalse
            why = "under " & describeArm(g) & ", which selects variant '" &
              variant & "' = " & wanted & "; the lock records " &
              facts.variants[variant]
    case v
    of triFalse:
      return ArmVerdict(applicability: aaExcluded, reason: why)
    of triUnknown:
      if undecided.len == 0: undecided = why
    of triTrue:
      discard
  if undecided.len > 0:
    result = ArmVerdict(applicability: aaUndecidable, reason: undecided)

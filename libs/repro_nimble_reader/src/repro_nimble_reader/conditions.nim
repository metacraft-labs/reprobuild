## `when` conditions as data (NPC-AREQ7).
##
## A `when` around `requires` is stored as a typed condition over a closed set
## of terms, and the solver evaluates it for the platform pair it solves for,
## so one record serves every platform. The closed set is exactly:
##
##   * `defined(<os>)` and `defined(<cpu>)` for the Nim target names,
##   * `hostOS == "<os>"` and `hostCPU == "<cpu>"`,
##   * `and`, `or`, `not`, and parentheses.
##
## Every other condition is *undecidable* here: the requirement it guards is
## not offered to the solver, and the reader says which kind of condition it
## was (`UndecidableKind`) so an override author knows what to replace. The
## reader never evaluates a condition and never assumes one is false.
##
## The term kinds are an enum and the admitted set is the constant
## `ClosedTermKinds`, so admitting another term (the Nim-version comparisons
## or the OS-family symbols that are proposed for the set) is a new enum
## member, a recogniser branch and an evaluator, not a new representation.

{.push raises: [].}

import std/strutils

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
  ## Symbols the compiler defines from the target OS's family rather than its
  ## name. Not in the closed set; recognised only to name them precisely.
  OsFamilySymbols = ["posix", "unix", "bsd", "osx", "x86", "emscripten",
                     "wasm"]
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

  Condition* = ref object
    ## A condition over the closed term set. `nil` means "unconditional".
    case kind*: ConditionKind
    of ckDefinedOs, ckDefinedCpu, ckHostOsIs, ckHostCpuIs:
      name*: string ## the lower-case target name
    of ckAnd, ckOr:
      left*, right*: Condition
    of ckNot:
      operand*: Condition

  UndecidableKind* = enum
    ## Why a condition is outside the closed set.
    ukToolchain = "toolchain"             ## `NimMajor`, `declared(...)`, `defined(nimXxx)`
    ukOsFamily = "os-family"              ## `defined(posix)` and the like
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
  ClosedTermKinds* = {ckDefinedOs, ckDefinedCpu, ckHostOsIs, ckHostCpuIs}

proc definedOs*(name: string): Condition = Condition(kind: ckDefinedOs, name: name)
proc definedCpu*(name: string): Condition = Condition(kind: ckDefinedCpu, name: name)
proc hostOsIs*(name: string): Condition = Condition(kind: ckHostOsIs, name: name)
proc hostCpuIs*(name: string): Condition = Condition(kind: ckHostCpuIs, name: name)

proc conjoin*(a, b: Condition): Condition =
  ## `a and b`, where `nil` is "true".
  if a.isNil: return b
  if b.isNil: return a
  Condition(kind: ckAnd, left: a, right: b)

proc negate*(a: Condition): Condition =
  Condition(kind: ckNot, operand: a)

proc `$`*(c: Condition): string =
  ## A deterministic rendering in Nim syntax, fully parenthesised.
  if c.isNil:
    return "true"
  case c.kind
  of ckDefinedOs, ckDefinedCpu: "defined(" & c.name & ")"
  of ckHostOsIs: "hostOS == \"" & c.name & "\""
  of ckHostCpuIs: "hostCPU == \"" & c.name & "\""
  of ckAnd: "(" & $c.left & " and " & $c.right & ")"
  of ckOr: "(" & $c.left & " or " & $c.right & ")"
  of ckNot: "not (" & $c.operand & ")"

proc `==`*(a, b: Condition): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  case a.kind
  of ckDefinedOs, ckDefinedCpu, ckHostOsIs, ckHostCpuIs: a.name == b.name
  of ckAnd, ckOr: a.left == b.left and a.right == b.right
  of ckNot: a.operand == b.operand

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

proc evaluate*(c: Condition; targetOs, targetCpu, hostOs,
    hostCpu: string): bool =
  ## Evaluate for one platform pair (lower-case Nim target names). This is
  ## what the solver does; the reader itself never calls it.
  if c.isNil:
    return true
  case c.kind
  of ckDefinedOs: definedForOs(c.name, targetOs)
  of ckDefinedCpu: c.name == targetCpu
  of ckHostOsIs: c.name == hostOs
  of ckHostCpuIs: c.name == hostCpu
  of ckAnd: evaluate(c.left, targetOs, targetCpu, hostOs, hostCpu) and
            evaluate(c.right, targetOs, targetCpu, hostOs, hostCpu)
  of ckOr: evaluate(c.left, targetOs, targetCpu, hostOs, hostCpu) or
           evaluate(c.right, targetOs, targetCpu, hostOs, hostCpu)
  of ckNot: not evaluate(c.operand, targetOs, targetCpu, hostOs, hostCpu)

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
      if sym in OsFamilySymbols:
        return undecidable(ukOsFamily)
      if sym.startsWith("nim") and sym notin ["nimdistros", "nimble"]:
        return undecidable(ukToolchain)
      return undecidable(ukOtherDefine)
    return undecidable(classifyOutside(e))
  of ekInfix:
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

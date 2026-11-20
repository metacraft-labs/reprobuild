## Why two actions' portable cache keys differ.
##
## Two builds of a library may substitute for each other exactly when their
## edges have the same portable key: the same static description (the
## portable weak fingerprint, `PortableKeyDescription`) and the same input
## identities (the portable strong fingerprint). This module takes the
## engine's own evidence for two actions and names, component by component,
## what makes their keys differ: an input, a compile flag, a preprocessor
## define, the toolchain, a dependency (an input another action produces,
## whose own key differs), the environment, the outputs, the working
## directory or the action's shape.
##
## The evidence for one action (`ActionKeyEvidence`) is in two parts:
##
## * PLANNED, known before the action has ever run: the static description
##   the weak fingerprint is the digest of, and the identity of every
##   declared input that is a source (a file nothing in the graph produces).
##   A declared input another action produces is identified by that
##   producer's own evidence, recursively.
## * RECORDED, known only after an execution: the portable record the
##   engine stored for the action (`PortableMemoRecord`), whose observed
##   inputs are what the action really read -- headers, the compiler's own
##   files, environment variables.
##
## A difference in the recorded observed inputs is reported as a cause only
## when the planned evidence finds none. When the static description or a
## declared input already differs, what the action then reads is a
## CONSEQUENCE of that difference (another compiler reads other files), so
## those differences are listed apart (`alsoObserved`) rather than as further
## causes. The classification rules are in
## Caching-Architecture.md "Configuration divergence" and in
## the public `docs/users/content/guides/building/find-why-two-library-builds-differ.md`.
##
## Pure over the evidence values: the CLI (`repro cache key`,
## `repro cache explain`) gathers the evidence from a planned graph and the
## local portable-memo store; this module only compares.

import std/[algorithm, json, options, sequtils, sets, strutils, tables]

import ./portable_fingerprint
import ./portable_memo

const
  ActionKeySchema* = "reprobuild.action-key.v1"
    ## The JSON document `repro cache key --json` prints for one action.
  KeyExplanationSchema* = "reprobuild.key-explanation.v1"
    ## The JSON document `repro cache explain --json` prints for a pair.

type
  RecordedKeyEvidence* = object
    ## What an execution recorded for the action, or what the record of
    ## another checkout evaluates to here (`source`).
    source*: string
      ## `recorded`: this checkout's own record (the engine's lookup finds it
      ## from what is on disk now). `evaluated`: the other action's record,
      ## its path set evaluated against this action's roots, which is what
      ## the engine's lookup computes before it decides a hit.
    strongHex*: string
    inputs*: seq[PortableInput]
      ## Declared and observed, each with its role.

  InputEvidence* = object
    ## One declared input of the action.
    path*: string
      ## The logicalized path, as `PortableKeyDescription.declaredInputs`
      ## spells it (`${project}/src/a.c`).
    identity*: string
      ## The input's identity (`readIdentity`) when it is a source; "" when
      ## another action produces it, or when it cannot be identified now.
    producer*: seq[ActionKeyEvidence]
      ## The evidence of the action that produces the input, when one in the
      ## graph does (at most one entry: a `seq` only so the type can be
      ## recursive).

  ActionKeyEvidence* = object
    actionId*: string
    project*: string
      ## The physical project root the action was planned in (informational:
      ## it is not part of any key).
    eligible*: bool
      ## Whether the engine gives the action a portable identity at all.
    refusal*: string
      ## Why not, when it does not.
    description*: PortableKeyDescription
    weakHex*: string
      ## `portableWeakFingerprint(description)`.
    inputs*: seq[InputEvidence]
    recorded*: Option[RecordedKeyEvidence]
    recordedNote*: string
      ## Why there is no recorded evidence, when there is none.

  KeyCauseKind* = enum
    kcInput = "input"
      ## A file the action reads (declared, or observed by a recorded
      ## execution) has other content, or is present on one side only.
    kcFlag = "flag"
      ## A command-line option other than a define.
    kcDefine = "define"
      ## A preprocessor or compile-time define (`-D`, `-U`, Nim's `-d:`).
    kcToolchain = "toolchain"
      ## The program run, or an environment value naming a tool
      ## installation, or (recorded) a file read from a realized tool.
    kcDependency = "dependency"
      ## A declared input produced by another action whose key differs.
    kcEnvironment = "environment"
      ## A declared or observed environment variable, or the passthrough set.
    kcArgument = "argument"
      ## A positional command-line argument that is not an option's value.
    kcOutputs = "outputs"
      ## The declared outputs, scratch directories or removed paths.
    kcWorkingDirectory = "working-directory"
    kcAction = "action"
      ## The action's kind or builtin payload.

  KeyCause* = object
    kind*: KeyCauseKind
    component*: string
      ## Where in the key: `argv`, `cwd`, `env`, `declared-input`, `static`,
      ## `observed-input`.
    subject*: string
      ## What differs: a define's name, an option, a variable's name, a path.
    a*, b*: string
      ## The value on each side; "" when absent there (see `inA`, `inB`).
    inA*, inB*: bool
    toolA*, toolB*: string
      ## For a `toolchain` cause: the tool each side names, when it can be
      ## read from the path (`gcc 15.3.0`), else "".
    evidence*: string
      ## `planned` or `recorded`.
    because*: seq[KeyCause]
      ## For a `dependency` cause: why the producer's keys differ.

  KeyVerdict* = enum
    kvSameKey = "same-key"
    kvDifferentKey = "different-key"
    kvUndetermined = "undetermined"

  KeyExplanation* = object
    verdict*: KeyVerdict
    substitutable*: bool
      ## Same key and both actions eligible for a portable identity.
    causes*: seq[KeyCause]
    alsoObserved*: seq[KeyCause]
      ## Recorded differences that follow from `causes`.
    unanswered*: seq[string]
      ## What could not be compared, and what would answer it.

# ---------------------------------------------------------------------------
# Command-line tokens
# ---------------------------------------------------------------------------

const
  SeparateValueOptions = ["-I", "-o", "-MF", "-MT", "-MQ", "-include",
    "-imacros", "-isystem", "-iquote", "-idirafter", "-iprefix",
    "-iwithprefix", "-isysroot", "-L", "-l", "-x", "-Xlinker",
    "-Xassembler", "-Xpreprocessor", "-T", "-u", "-e", "-z", "-arch",
    "-target", "-framework", "--sysroot", "-B"]
    ## GCC/Clang options whose value is the NEXT argument
    ## (https://gcc.gnu.org/onlinedocs/gcc/Option-Summary.html). Anything
    ## else that starts with `-` is an option on its own.

type
  ArgvItem = object
    kind: KeyCauseKind
    subject: string
    value: string
    index: int
      ## Where in its argv the item starts.

proc isDefineSpelling(token: string; name, value: var string): bool =
  ## `-DNAME`, `-DNAME=V`, `-UNAME` (GCC/Clang), `-d:NAME[=V]` and
  ## `--define:NAME[=V]` (Nim, https://nim-lang.org/docs/nimc.html).
  var body = ""
  var separators = {'='}
  if token.len > 2 and (token.startsWith("-D") or token.startsWith("-U")):
    body = token[2 .. ^1]
  elif token.startsWith("-d:") or token.startsWith("-d="):
    body = token[3 .. ^1]
    separators = {'=', ':'}
  elif token.startsWith("--define:") or token.startsWith("--define="):
    body = token[9 .. ^1]
    separators = {'=', ':'}
  else:
    return false
  let eq = body.find(separators)
  name = if eq >= 0: body[0 ..< eq] else: body
  value = token
  name.len > 0

proc flagFamily(token: string): string =
  ## The name two spellings of one option share, so `-O1` and `-O2` pair as
  ## one changed flag instead of one removed and one added.
  let eq = token.find('=')
  if eq > 0:
    return token[0 ..< eq]
  if token.len >= 2 and token[0] == '-' and token[1] in {'O', 'g'} and
      (token.len == 2 or token[2] notin {'a' .. 'z', 'A' .. 'Z'} or
       token[1] == 'O'):
    return token[0 .. 1]
  token

proc classifyArgv(argv: openArray[string]; index: int;
                  consumed: var HashSet[int]): ArgvItem =
  ## What the token at `index` is, read in the context of its own argv.
  let token = argv[index]
  if index == 0:
    return ArgvItem(kind: kcToolchain, subject: "program", value: token)
  var name, value: string
  if isDefineSpelling(token, name, value):
    return ArgvItem(kind: kcDefine, subject: name, value: value)
  if token in ["-D", "-U"] and index + 1 < argv.len:
    consumed.incl(index + 1)
    let next = argv[index + 1]
    let eq = next.find('=')
    return ArgvItem(kind: kcDefine,
      subject: (if eq >= 0: next[0 ..< eq] else: next),
      value: token & " " & next)
  let prev = argv[index - 1]
  if prev in ["-D", "-U"]:
    let eq = token.find('=')
    return ArgvItem(kind: kcDefine,
      subject: (if eq >= 0: token[0 ..< eq] else: token),
      value: prev & " " & token)
  if token in SeparateValueOptions and index + 1 < argv.len:
    consumed.incl(index + 1)
    return ArgvItem(kind: kcFlag, subject: token,
      value: token & " " & argv[index + 1])
  if prev in SeparateValueOptions:
    return ArgvItem(kind: kcFlag, subject: prev, value: prev & " " & token)
  if token.startsWith("-"):
    return ArgvItem(kind: kcFlag, subject: flagFamily(token), value: token)
  ArgvItem(kind: kcArgument, subject: token, value: token)

proc lcsDiff(a, b: openArray[string]): (seq[int], seq[int]) =
  ## The indices of `a` and of `b` that are NOT in their longest common
  ## subsequence: what one side has that the other lacks, in order. Falls
  ## back to a positional comparison past a size bound (a link line of
  ## thousands of objects), which over-reports but never under-reports.
  const Bound = 4_000_000
  if a.len * b.len > Bound:
    for i in 0 ..< max(a.len, b.len):
      if i >= a.len: result[1].add(i)
      elif i >= b.len: result[0].add(i)
      elif a[i] != b[i]:
        result[0].add(i)
        result[1].add(i)
    return
  var table = newSeq[seq[int]](a.len + 1)
  for i in 0 .. a.len:
    table[i] = newSeq[int](b.len + 1)
  for i in countdown(a.len - 1, 0):
    for j in countdown(b.len - 1, 0):
      table[i][j] =
        if a[i] == b[j]: table[i + 1][j + 1] + 1
        else: max(table[i + 1][j], table[i][j + 1])
  var i = 0
  var j = 0
  while i < a.len and j < b.len:
    if a[i] == b[j]:
      inc i
      inc j
    elif table[i + 1][j] >= table[i][j + 1]:
      result[0].add(i)
      inc i
    else:
      result[1].add(j)
      inc j
  while i < a.len:
    result[0].add(i)
    inc i
  while j < b.len:
    result[1].add(j)
    inc j

proc toolOf(value: string): string =
  ## The tool a path names, when its spelling says: a realized tool-store
  ## prefix `…/tool-store/prefixes/<name>/<version>-<hash>/…` gives
  ## `<name> <version>`; a Nix store path `/nix/store/<hash>-<name>/…` gives
  ## `<name>`. "" otherwise.
  for element in value.split(':'):
    let marker = "/tool-store/prefixes/"
    let at = element.find(marker)
    if at >= 0:
      let parts = element[at + marker.len .. ^1].split('/')
      if parts.len >= 2:
        let dash = parts[1].rfind('-')
        let version = if dash > 0: parts[1][0 ..< dash] else: parts[1]
        return parts[0] & " " & version
    let nix = element.find("/nix/store/")
    if nix >= 0:
      let name = element[nix + "/nix/store/".len .. ^1].split('/')[0]
      let dash = name.find('-')
      return if dash > 0: name[dash + 1 .. ^1] else: name
  ""

proc namesToolInstallation(value: string): bool =
  ## Whether an environment value names a tool installation directory: a
  ## realized tool-store prefix or a Nix store path.
  for element in value.split(':'):
    if "/tool-store/" in element or element.startsWith("/nix/store/") or
        element.startsWith("${store}/"):
      return true
  false

const ReceiptDirectory = "/tool-store/provisioning/receipts/"
  ## Where a provisioned tool's receipt lives; the engine declares it as an
  ## input of every edge that names the tool (its content names the
  ## realization).

proc receiptTool(path: string): string =
  ## The tool a provisioning receipt is for (`<mode>-provision.<tool>.<hash>
  ## .receipt`), or "" when `path` is not a receipt.
  let at = path.find(ReceiptDirectory)
  if at < 0:
    return ""
  let parts = path[at + ReceiptDirectory.len .. ^1].split('.')
  if parts.len >= 4 and parts[^1] == "receipt": parts[1] else: ""

proc receiptCauses(onlyA, onlyB: openArray[(string, string)]): seq[KeyCause] =
  ## Receipts declared on one side only, paired by tool: one `toolchain`
  ## cause per tool whose realization differs.
  var usedB = newSeq[bool](onlyB.len)
  for (path, identity) in onlyA:
    let tool = receiptTool(path)
    var cause = KeyCause(kind: kcToolchain, component: "declared-input",
      subject: tool, a: path, inA: true, evidence: "planned")
    for k, (pathB, _) in onlyB:
      if not usedB[k] and receiptTool(pathB) == tool:
        usedB[k] = true
        cause.b = pathB
        cause.inB = true
        break
    result.add(cause)
  for k, (path, identity) in onlyB:
    if not usedB[k]:
      result.add(KeyCause(kind: kcToolchain, component: "declared-input",
        subject: receiptTool(path), b: path, inB: true, evidence: "planned"))

proc valuesBySubject(argv: openArray[string]):
    Table[(KeyCauseKind, string), seq[string]] =
  ## Every item of a whole argv, grouped by (kind, subject), in argv order.
  var consumed: HashSet[int]
  for i in 0 ..< argv.len:
    if i notin consumed:
      let item = classifyArgv(argv, i, consumed)
      result.mgetOrPut((item.kind, item.subject), @[]).add(item.value)

proc argvCauses(a, b: openArray[string]): seq[KeyCause] =
  let (onlyA, onlyB) = lcsDiff(a, b)
  var consumedA, consumedB: HashSet[int]
  var itemsA, itemsB: seq[ArgvItem]
  for i in onlyA:
    if i notin consumedA:
      itemsA.add(classifyArgv(a, i, consumedA))
      itemsA[^1].index = i
  for j in onlyB:
    if j notin consumedB:
      itemsB.add(classifyArgv(b, j, consumedB))
      itemsB[^1].index = j
  # A subject whose values are the same on both sides in another ORDER
  # (`-I x -I y` against `-I y -I x`: the search order changed) is one
  # change of order. The common subsequence keeps some of its values in
  # place and reports the rest as removed on one side and added on the
  # other, which would read as `-I y` against `-I y` plus an `-I x` that
  # both sides in fact have.
  let allA = valuesBySubject(a)
  let allB = valuesBySubject(b)
  var reordered: HashSet[(KeyCauseKind, string)]
  for item in itemsA & itemsB:
    let key = (item.kind, item.subject)
    if key in reordered:
      continue
    let valuesA = allA.getOrDefault(key)
    let valuesB = allB.getOrDefault(key)
    if valuesA != valuesB and valuesA.sorted() == valuesB.sorted():
      reordered.incl(key)
      result.add(KeyCause(kind: item.kind, component: "argv",
        subject: item.subject, a: valuesA.join(" "), b: valuesB.join(" "),
        inA: true, inB: true, evidence: "planned"))
  if reordered.len > 0:
    itemsA.keepItIf((it.kind, it.subject) notin reordered)
    itemsB.keepItIf((it.kind, it.subject) notin reordered)
  # A changed value under an unchanged option (`-I X` vs `-I Y`) is one
  # changed token whose option is in the common subsequence; its context
  # gives both sides the same subject, so they pair below.
  var usedB = newSeq[bool](itemsB.len)
  for itemA in itemsA:
    var paired = -1
    for k, itemB in itemsB:
      if not usedB[k] and itemB.kind == itemA.kind and
          itemB.subject == itemA.subject:
        paired = k
        break
    var cause = KeyCause(kind: itemA.kind, component: "argv",
      subject: itemA.subject, a: itemA.value, inA: true, evidence: "planned")
    if paired >= 0:
      usedB[paired] = true
      cause.b = itemsB[paired].value
      cause.inB = true
      if cause.a == cause.b:
        # The same item at another place among the others (a positional
        # argument moved): say where, or the cause reads as no change.
        cause.a.add(" (argument " & $itemA.index & ")")
        cause.b.add(" (argument " & $itemsB[paired].index & ")")
    if cause.kind == kcToolchain:
      cause.toolA = toolOf(cause.a)
      cause.toolB = toolOf(cause.b)
    result.add(cause)
  for k, itemB in itemsB:
    if not usedB[k]:
      var cause = KeyCause(kind: itemB.kind, component: "argv",
        subject: itemB.subject, b: itemB.value, inB: true,
        evidence: "planned")
      if cause.kind == kcToolchain:
        cause.toolB = toolOf(cause.b)
      result.add(cause)

proc envCauses(a, b: openArray[(string, string)]): seq[KeyCause] =
  var mapA, mapB: OrderedTable[string, string]
  for (name, value) in a: mapA[name] = value
  for (name, value) in b: mapB[name] = value
  var names: seq[string] = @[]
  for name in mapA.keys: names.add(name)
  for name in mapB.keys:
    if name notin mapA: names.add(name)
  names.sort()
  for name in names:
    let inA = name in mapA
    let inB = name in mapB
    let va = mapA.getOrDefault(name)
    let vb = mapB.getOrDefault(name)
    if inA and inB and va == vb:
      continue
    var cause = KeyCause(kind: kcEnvironment, component: "env",
      subject: name, a: va, b: vb, inA: inA, inB: inB, evidence: "planned")
    if namesToolInstallation(va) or namesToolInstallation(vb):
      cause.kind = kcToolchain
      cause.toolA = toolOf(va)
      cause.toolB = toolOf(vb)
    result.add(cause)

proc staticKind(key: string): KeyCauseKind =
  case key
  of "output", "optionalOutput", "declaredOutput", "scratch",
     "removeBeforeRun":
    kcOutputs
  of "passthrough", "env":
    kcEnvironment
  of "canonicalWorkKey":
    kcWorkingDirectory
  else:
    kcAction

proc staticCauses(a, b: openArray[string]): seq[KeyCause] =
  ## The static fields compared as a multiset of `key=value` entries; a key
  ## with one value on each side pairs into one changed cause.
  proc split(field: string): (string, string) =
    let eq = field.find('=')
    if eq > 0: (field[0 ..< eq], field[eq + 1 .. ^1]) else: (field, "")
  var countA, countB: CountTable[string]
  for field in a: countA.inc(field)
  for field in b: countB.inc(field)
  var onlyA, onlyB: seq[(string, string)]
  for field, n in countA.pairs:
    for _ in 0 ..< max(0, n - countB.getOrDefault(field)):
      onlyA.add(split(field))
  for field, n in countB.pairs:
    for _ in 0 ..< max(0, n - countA.getOrDefault(field)):
      onlyB.add(split(field))
  onlyA.sort()
  onlyB.sort()
  var usedB = newSeq[bool](onlyB.len)
  for (key, value) in onlyA:
    var cause = KeyCause(kind: staticKind(key), component: "static",
      subject: key, a: value, inA: true, evidence: "planned")
    # Pair only single-valued keys: two different output sets are two
    # removed and two added outputs, not "output X became Y".
    if key in ["kind", "builtinText", "canonicalWorkKey", "env"]:
      for k, (keyB, valueB) in onlyB:
        if not usedB[k] and keyB == key:
          usedB[k] = true
          cause.b = valueB
          cause.inB = true
          break
    result.add(cause)
  for k, (key, value) in onlyB:
    if not usedB[k]:
      result.add(KeyCause(kind: staticKind(key), component: "static",
        subject: key, b: value, inB: true, evidence: "planned"))

proc findInput(evidence: ActionKeyEvidence; path: string):
    Option[InputEvidence] =
  for input in evidence.inputs:
    if input.path == path:
      return some(input)
  none(InputEvidence)

proc logicalRecordPath(path: string): string =
  ## A record's `<label>:<rel>` as the description spells it
  ## (`${<label>}/<rel>`), so a recorded path and a declared one compare.
  let colon = path.find(':')
  if colon <= 0 or path.startsWith(AncestorPrefix):
    return path
  let rel = path[colon + 1 .. ^1]
  "${" & path[0 ..< colon] & "}" & (if rel.len > 0: "/" & rel else: "")

proc recordedCauses(a, b: RecordedKeyEvidence): seq[KeyCause] =
  ## Every observed input whose identity differs, or which one side alone
  ## read, as the two executions (or evaluations) state them.
  var mapA, mapB: OrderedTable[string, PortableInput]
  for input in a.inputs:
    if input.role == irObserved:
      mapA[$input.kind & " " & input.path] = input
  for input in b.inputs:
    if input.role == irObserved:
      mapB[$input.kind & " " & input.path] = input
  var keys: seq[string] = @[]
  for key in mapA.keys: keys.add(key)
  for key in mapB.keys:
    if key notin mapA: keys.add(key)
  keys.sort()
  for key in keys:
    let inA = key in mapA
    let inB = key in mapB
    let input = if inA: mapA[key] else: mapB[key]
    let va = if inA: mapA[key].digest else: ""
    let vb = if inB: mapB[key].digest else: ""
    if inA and inB and va == vb:
      continue
    var cause = KeyCause(kind: kcInput, component: "observed-input",
      subject: logicalRecordPath(input.path), a: va, b: vb, inA: inA,
      inB: inB, evidence: "recorded")
    if input.kind == pikEnvironment:
      cause.kind = kcEnvironment
      cause.subject = input.path
    elif input.path.startsWith("store:tool-store/"):
      cause.kind = kcToolchain
      cause.toolA = if inA: toolOf("/" & input.path) else: ""
      cause.toolB = if inB: toolOf("/" & input.path) else: ""
    result.add(cause)

proc explainKeyDifference*(a, b: ActionKeyEvidence): KeyExplanation =
  ## Why `a` and `b` have different portable keys, or that they have the
  ## same one. See the module documentation for what each cause means and
  ## when a recorded difference is a cause.
  var causes: seq[KeyCause] = @[]
  if a.weakHex != b.weakHex:
    causes.add(argvCauses(a.description.argv, b.description.argv))
    if a.description.cwd != b.description.cwd:
      causes.add(KeyCause(kind: kcWorkingDirectory, component: "cwd",
        subject: "cwd", a: a.description.cwd, b: b.description.cwd,
        inA: true, inB: true, evidence: "planned"))
    causes.add(envCauses(a.description.env, b.description.env))
    causes.add(staticCauses(a.description.staticFields,
      b.description.staticFields))
    # The static fields are compared as a multiset, but their order is part
    # of the digest (a builtin's entries, say). Different weak keys with the
    # same declared input set and no difference found above can only be
    # that order: say so rather than fall through to "the keys agree".
    if causes.len == 0 and a.description.declaredInputs ==
        b.description.declaredInputs:
      causes.add(KeyCause(kind: kcAction, component: "static",
        subject: "order", a: a.description.staticFields.join(" "),
        b: b.description.staticFields.join(" "), inA: true, inB: true,
        evidence: "planned"))
  # The declared inputs: the set is in the weak fingerprint, their
  # identities in the strong one.
  let setA = toHashSet(a.description.declaredInputs)
  let setB = toHashSet(b.description.declaredInputs)
  # A provisioned tool's receipt is the tool's realization: a receipt on one
  # side only is a toolchain difference, paired by tool.
  var receiptsA, receiptsB: seq[(string, string)]
  for path in a.description.declaredInputs:
    if path notin setB:
      let identity = a.findInput(path).get(InputEvidence()).identity
      if receiptTool(path).len > 0:
        receiptsA.add((path, identity))
      else:
        causes.add(KeyCause(kind: kcInput, component: "declared-input",
          subject: path, a: identity, inA: true, evidence: "planned"))
  for path in b.description.declaredInputs:
    if path notin setA:
      let identity = b.findInput(path).get(InputEvidence()).identity
      if receiptTool(path).len > 0:
        receiptsB.add((path, identity))
      else:
        causes.add(KeyCause(kind: kcInput, component: "declared-input",
          subject: path, b: identity, inB: true, evidence: "planned"))
  var toolCauses = receiptCauses(receiptsA, receiptsB)
  var undetermined: seq[string] = @[]
  for path in a.description.declaredInputs:
    if path notin setB:
      continue
    let ia = a.findInput(path)
    let ib = b.findInput(path)
    if ia.isNone or ib.isNone:
      undetermined.add("declared input " & path & " has no evidence on " &
        (if ia.isNone: "the first" else: "the second") & " side")
      continue
    let inA = ia.get()
    let inB = ib.get()
    if inA.producer.len > 0 and inB.producer.len > 0:
      let sub = explainKeyDifference(inA.producer[0], inB.producer[0])
      case sub.verdict
      of kvSameKey:
        discard
      of kvDifferentKey:
        causes.add(KeyCause(kind: kcDependency, component: "declared-input",
          subject: path,
          a: inA.producer[0].actionId & " weak=" & inA.producer[0].weakHex,
          b: inB.producer[0].actionId & " weak=" & inB.producer[0].weakHex,
          inA: true, inB: true, evidence: "planned", because: sub.causes))
      of kvUndetermined:
        for item in sub.unanswered:
          undetermined.add("dependency " & path & ": " & item)
    elif inA.producer.len > 0 or inB.producer.len > 0:
      causes.add(KeyCause(kind: kcInput, component: "declared-input",
        subject: path,
        a: (if inA.producer.len > 0: "produced by " & inA.producer[0].actionId
            else: inA.identity),
        b: (if inB.producer.len > 0: "produced by " & inB.producer[0].actionId
            else: inB.identity),
        inA: true, inB: true, evidence: "planned"))
    elif inA.identity.len == 0 or inB.identity.len == 0:
      undetermined.add("declared input " & path & " cannot be identified " &
        "on " & (if inA.identity.len == 0: "the first" else: "the second") &
        " side")
    elif inA.identity != inB.identity:
      if receiptTool(path).len > 0:
        toolCauses.add(KeyCause(kind: kcToolchain,
          component: "declared-input", subject: receiptTool(path),
          a: inA.identity, b: inB.identity, inA: true, inB: true,
          evidence: "planned"))
      else:
        causes.add(KeyCause(kind: kcInput, component: "declared-input",
          subject: path, a: inA.identity, b: inB.identity, inA: true,
          inB: true, evidence: "planned"))
  # A receipt moves only with the tool's realization, which the program or
  # the declared `PATH` already names when they differ: the receipt is then
  # the same difference again, not a second cause. Alone, it is the cause.
  var namedByDescription = false
  for cause in causes:
    if cause.kind == kcToolchain and cause.component in ["argv", "env"]:
      namedByDescription = true
  if not namedByDescription:
    causes.add(toolCauses)
  # The recorded half: what the actions read when they ran.
  if a.recorded.isSome and b.recorded.isSome:
    let observed = recordedCauses(a.recorded.get(), b.recorded.get())
    if causes.len == 0 and undetermined.len == 0:
      causes = observed
      if observed.len == 0 and
          a.recorded.get().strongHex != b.recorded.get().strongHex:
        result.unanswered.add("the recorded strong keys differ (" &
          a.recorded.get().strongHex & ", " & b.recorded.get().strongHex &
          ") but no recorded input does")
    else:
      result.alsoObserved = observed
  elif causes.len == 0 and undetermined.len == 0:
    undetermined.add("the planned keys agree; what each action reads " &
      "(headers, the toolchain's own files) is known only from a recorded " &
      "execution, and " &
      (if a.recorded.isNone and b.recorded.isNone: "neither side has one"
       elif a.recorded.isNone: "the first side has none (" &
         a.recordedNote & ")"
       else: "the second side has none (" & b.recordedNote & ")"))
  result.causes = causes
  if causes.len > 0:
    result.verdict = kvDifferentKey
  elif undetermined.len > 0 or result.unanswered.len > 0:
    result.verdict = kvUndetermined
  else:
    result.verdict = kvSameKey
  result.unanswered.add(undetermined)
  result.substitutable = result.verdict == kvSameKey and a.eligible and
    b.eligible

# ---------------------------------------------------------------------------
# JSON (inspection output, and the input `repro cache explain` accepts back)
# ---------------------------------------------------------------------------

proc toJson(description: PortableKeyDescription): JsonNode =
  var env = newJArray()
  for (name, value) in description.env:
    env.add(%*{"name": name, "value": value})
  %*{"argv": description.argv, "cwd": description.cwd, "env": env,
    "declaredInputs": description.declaredInputs,
    "staticFields": description.staticFields}

const AccessNames: array[PortableInputKind, string] =
  ["read", "probe", "enumeration", "environment"]
  ## How a document spells an input's access kind.

proc toJson(input: PortableInput): JsonNode =
  %*{"kind": AccessNames[input.kind], "path": input.path,
    "identity": input.digest, "role": $input.role}

proc toJson*(evidence: ActionKeyEvidence; schema = true): JsonNode =
  ## The `reprobuild.action-key.v1` document (`schema` false for a nested
  ## producer, which carries no schema field of its own).
  result = newJObject()
  if schema:
    result["schema"] = %ActionKeySchema
  result["actionId"] = %evidence.actionId
  result["project"] = %evidence.project
  result["eligible"] = %evidence.eligible
  result["refusal"] = %evidence.refusal
  result["weak"] = %evidence.weakHex
  result["description"] = toJson(evidence.description)
  var inputs = newJArray()
  for input in evidence.inputs:
    var item = %*{"path": input.path, "identity": input.identity}
    if input.producer.len > 0:
      item["producer"] = toJson(input.producer[0], schema = false)
    inputs.add(item)
  result["inputs"] = inputs
  if evidence.recorded.isSome:
    let recorded = evidence.recorded.get()
    var items = newJArray()
    for input in recorded.inputs:
      items.add(toJson(input))
    result["recorded"] = %*{"source": recorded.source,
      "strong": recorded.strongHex, "inputs": items}
  else:
    result["recorded"] = newJNull()
    result["recordedNote"] = %evidence.recordedNote

proc toJson*(cause: KeyCause): JsonNode =
  result = %*{"kind": $cause.kind, "component": cause.component,
    "subject": cause.subject, "a": (if cause.inA: %cause.a else: newJNull()),
    "b": (if cause.inB: %cause.b else: newJNull()),
    "evidence": cause.evidence}
  if cause.kind == kcToolchain:
    result["toolA"] = %cause.toolA
    result["toolB"] = %cause.toolB
  if cause.because.len > 0:
    var because = newJArray()
    for item in cause.because:
      because.add(toJson(item))
    result["because"] = because

proc toJson*(explanation: KeyExplanation;
             a, b: ActionKeyEvidence): JsonNode =
  ## The `reprobuild.key-explanation.v1` document.
  proc side(evidence: ActionKeyEvidence): JsonNode =
    %*{"actionId": evidence.actionId, "project": evidence.project,
      "eligible": evidence.eligible, "refusal": evidence.refusal,
      "weak": evidence.weakHex,
      "strong": (if evidence.recorded.isSome:
                   %evidence.recorded.get().strongHex
                 else: newJNull()),
      "strongSource": (if evidence.recorded.isSome:
                         %evidence.recorded.get().source
                       else: newJNull())}
  var causes = newJArray()
  for cause in explanation.causes:
    causes.add(toJson(cause))
  var observed = newJArray()
  for cause in explanation.alsoObserved:
    observed.add(toJson(cause))
  %*{"schema": KeyExplanationSchema, "verdict": $explanation.verdict,
    "substitutable": explanation.substitutable, "a": side(a), "b": side(b),
    "causes": causes, "alsoObserved": observed,
    "unanswered": explanation.unanswered}

proc requireField(node: JsonNode; name: string; kind: JsonNodeKind):
    JsonNode =
  if node.kind != JObject or not node.hasKey(name) or
      node[name].kind != kind:
    raise newException(ValueError, "malformed " & ActionKeySchema &
      " document: field `" & name & "` is missing or not a " & $kind)
  node[name]

proc stringsOf(node: JsonNode; what: string): seq[string] =
  for item in node:
    if item.kind != JString:
      raise newException(ValueError, "malformed " & ActionKeySchema &
        " document: `" & what & "` holds a non-string")
    result.add(item.getStr())

proc evidenceFromJson(node: JsonNode; nested: bool): ActionKeyEvidence =
  if not nested:
    let schema = requireField(node, "schema", JString).getStr()
    if schema != ActionKeySchema:
      raise newException(ValueError, "not a " & ActionKeySchema &
        " document (its schema is `" & schema & "`)")
  result.actionId = requireField(node, "actionId", JString).getStr()
  result.project = requireField(node, "project", JString).getStr()
  result.eligible = requireField(node, "eligible", JBool).getBool()
  result.refusal = requireField(node, "refusal", JString).getStr()
  result.weakHex = requireField(node, "weak", JString).getStr()
  let d = requireField(node, "description", JObject)
  result.description.argv = stringsOf(requireField(d, "argv", JArray),
    "argv")
  result.description.cwd = requireField(d, "cwd", JString).getStr()
  for item in requireField(d, "env", JArray):
    result.description.env.add((requireField(item, "name", JString).getStr(),
      requireField(item, "value", JString).getStr()))
  result.description.declaredInputs = stringsOf(
    requireField(d, "declaredInputs", JArray), "declaredInputs")
  result.description.staticFields = stringsOf(
    requireField(d, "staticFields", JArray), "staticFields")
  # The document must describe the key it names: a hand-edited description
  # whose digest is not `weak` would be explained as a key it is not.
  if portableWeakFingerprint(result.description) != result.weakHex:
    raise newException(ValueError, "malformed " & ActionKeySchema &
      " document for " & result.actionId & ": its description does not " &
      "digest to its `weak` key")
  for item in requireField(node, "inputs", JArray):
    var input = InputEvidence(
      path: requireField(item, "path", JString).getStr(),
      identity: requireField(item, "identity", JString).getStr())
    if item.hasKey("producer"):
      input.producer.add(evidenceFromJson(item["producer"], nested = true))
    result.inputs.add(input)
  let recorded = node{"recorded"}
  if recorded != nil and recorded.kind == JObject:
    var r = RecordedKeyEvidence(
      source: requireField(recorded, "source", JString).getStr(),
      strongHex: requireField(recorded, "strong", JString).getStr())
    for item in requireField(recorded, "inputs", JArray):
      var input = PortableInput(
        path: requireField(item, "path", JString).getStr(),
        digest: requireField(item, "identity", JString).getStr())
      let kind = requireField(item, "kind", JString).getStr()
      let role = requireField(item, "role", JString).getStr()
      var known = false
      for access, name in AccessNames:
        if name == kind:
          input.kind = access
          known = true
      try:
        input.role = parseEnum[InputRole](role)
      except ValueError:
        known = false
      if not known:
        raise newException(ValueError, "malformed " & ActionKeySchema &
          " document: recorded input kind `" & kind & "` or role `" & role &
          "` is unknown")
      r.inputs.add(input)
    # The recorded half must describe the key it names, as the store's own
    # reader requires of a memo record: a hand-edited input list whose
    # strong key is not `strong` would be compared as an execution that
    # never happened.
    if portableStrongFingerprint(result.weakHex, r.inputs) != r.strongHex:
      raise newException(ValueError, "malformed " & ActionKeySchema &
        " document for " & result.actionId & ": its recorded inputs do " &
        "not give its recorded `strong` key")
    result.recorded = some(r)
  else:
    result.recordedNote = node{"recordedNote"}.getStr()

proc actionKeyEvidenceFromJson*(text: string): ActionKeyEvidence =
  ## Parse a `reprobuild.action-key.v1` document. Raises `ValueError` for
  ## anything that is not one, including a description that does not digest
  ## to the key the document names.
  let node =
    try: parseJson(text)
    except JsonParsingError as err:
      raise newException(ValueError, "not JSON: " & err.msg)
  evidenceFromJson(node, nested = false)

proc evaluateRecordAgainst*(roots: openArray[LogicalRoot]; weakHex: string;
                            record: RecordedKeyEvidence;
                            resolve: IdentityResolver = nil):
    Option[RecordedKeyEvidence] =
  ## The record of another action, its path set evaluated against `roots`:
  ## the identity each input it names has HERE, and the strong key those
  ## give. This is the engine's lookup (`strongForPathSet`) before it
  ## decides a hit, so `weak` must be the weak key both actions share.
  ## `none` when an input cannot be identified here (an environment
  ## variable, which only an execution knows, or a path under no root).
  var inputs: seq[PortableInput] = @[]
  for input in record.inputs:
    let entry = PathSetEntry(kind: input.kind, path: input.path,
      role: input.role)
    let here = currentIdentity(roots, entry, resolve)
    if here.isNone:
      return none(RecordedKeyEvidence)
    inputs.add(PortableInput(kind: input.kind, path: input.path,
      digest: here.get(), role: input.role))
  some(RecordedKeyEvidence(source: "evaluated",
    strongHex: portableStrongFingerprint(weakHex, inputs), inputs: inputs))

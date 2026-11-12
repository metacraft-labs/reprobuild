## The source check of the adopt gate
## (``t_e2e_addon_adopt_hand_configured_service.nim``; A13 review round 7,
## finding 4, and the review of 2026-11-12): under the add-on build
## ``adopt-without-profile`` the gate's decision-61 refusal step is red,
## and the verdict that matters is the next one, the silent revert decision
## 61 rules out. Nothing between the two may end the run, or the cell would
## be judged on the refused adopt alone.
##
## The check reads the gate's source with Nim's own parser
## (``macros.parseStmt``) while the gate compiles. A list of stopping words
## proved unsound in every form tried: it misses what it does not spell
## (``raiseAssert``, a helper that raises, a raw string or ``#[ ]#`` comment
## hiding code, a call allowed elsewhere). So the check freezes what
## matters instead: the statements from the refused adopt through the
## revert step, the step procs, the gate's tests and the imports must be
## exactly as recorded here, and nothing in the gate file may rebind the
## names that code calls or the variables it reads, define C code, filter
## the source or rewrite code with a template, macro or converter. Changing
## any of that code means changing its record here, on purpose.
##
## The gate's top-level definitions are frozen by name and kind, and
## ``runBase`` may define no routine but its step procs and no type, so the
## frozen text resolves to what it resolves to now.
##
## Out of its reach, by design: what the modules the gate already imports
## define; a runtime failure of the frozen calls, including one caused by
## code that changes a variable's or the guest's state earlier (a call, or
## a write through an alias: ``let r = record; r[] = ...``); a stop before
## the refusal step; and code in the gate that runs while it compiles and
## rewrites the gate file before this module reads it (the compiler keeps
## the bytes it read first, this module reads the rewritten ones; review of
## 2026-11-12). The last is tampering with this check's input, like an edit
## of this module: no check that reads the source while the gate compiles
## can see past code that runs before it, and the tampering code stands in
## the committed gate, plain in a diff. The record classifier
## (``scripts/addon_a13_classify.py``) requires ``revertStepReached`` and a
## red revert step in a ``mutadoptprofile`` cell, which catches those.
##
## It exports two verdicts, computed at compile time: ``GateFindings``
## (empty when the gate cannot stop between the steps) and
## ``ControlFailures`` (empty when every negative control is refused for
## its reason and the comment-only control is not).
##
## *Mocking.* None: the gate's real source, and copies of it with one
## change each.

import std/[macros, os, strutils]

const
  FrozenStmts = """
let refusedAdopt = g.adoptResource(repro, "skeleton", skeleton, amAddress)
let raOut = refusedAdopt.stdout & refusedAdopt.stderr
stepNoStop("`repro system adopt` refuses while the profile declares the old " &
     "bytes, printing the resource with the edit (decision 61)",
     refusedAdopt.exitCode != 0 and "decision 61" in raOut and
     expectedStanza.len > 0 and expectedStanza in raOut, raOut &
     "\n--- expected:\n" & expectedStanza)
let oldSwitch = g.applyProfile(repro, "skeleton", skeleton)
record["revertStepReached"] = %true
step("a switch of the old profile does not revert the edit",
     g.run("tail -1 /etc/default/alertmanager").strip() ==
       "# edited by the operator",
     oldSwitch.stdout & oldSwitch.stderr)
"""
    ## ``runBase``'s statements from the refused adopt through the
    ## silent-revert step, compared whole (as parsed: comments and layout
    ## aside) with what it holds. Not a list of stopping words nor of
    ## allowed names: a word list misses what it does not spell
    ## (``raiseAssert``, a helper of this file that raises), and the revert
    ## itself needs ``step`` and ``g.run``, either of which, called once
    ## more in between, stops the run (A13 review of 2026-11-12). Changing
    ## these lines means changing this text with them, on purpose.
  FrozenDefs = """
type MutationStop = object of CatchableError
proc gateMutation*(): string = getEnv("REPRO_A13_MUTATION")
proc stepNoStop(name: string; ok: bool; detail: string) =
  steps.add(%*{"step": name, "ok": ok, "detail": detail})
  if not ok:
    fails.add(b.name & ": " & name & ": " & detail)
proc step(name: string; ok: bool; detail: string) =
  stepNoStop(name, ok, detail)
  if not ok and (mutation().len > 0 or gateMutation().len > 0):
    raise newException(MutationStop, name)
"""
    ## The definitions of this file those statements call, compared whole:
    ## ``stepNoStop`` records and never stops; ``step`` records before it
    ## stops, so the revert step's verdict is in the record either way.
  TrackedData = ["refusedAdopt", "raOut", "oldSwitch", "g", "repro",
    "skeleton", "amAddress", "expectedStanza", "record", "steps", "fails",
    "b"]
    ## The variables of ``runBase`` those statements and definitions read.
    ## Shadowing one (``let record = newJArray()`` makes the revert mark
    ## raise an ``AssertionDefect``; review of 2026-11-12) or assigning it
    ## changes the frozen code without changing its text, so each is bound
    ## only as ``DataBindings`` binds it and assigned only as
    ## ``DataAssignments`` assigns it.
  DataNames = @TrackedData & @["name", "ok", "detail"]
    ## Those and the step procs' parameters. Every other name there is a
    ## callable or a type (operators, fields read through a call, ``true``),
    ## and is ``guardedNames``.
  DataBindings = """
var b: BaseImage
var record: JsonNode
var g: Guest
let steps = newJArray()
var fails: seq[string]
let (repro, sha) = g.installArtefact()
let skeleton = mergeSkeletons([skAm.stdout, skVw.stdout, skPk.stdout])
var amAddress = ""
var expectedStanza = ""
"""
    ## How ``runBase`` binds the ``TrackedData`` names outside
    ## ``FrozenStmts``, each once (``b`` and ``record`` are its parameters,
    ## written here as the declarations they parse as).
  DataAssignments = """
g = newMirroredGuest(b, m, diskGiB = 10)
amAddress = e.resource
expectedStanza = renderStanza(x).join("\n")
"""
    ## How ``runBase`` assigns them, each once. An assignment of a field of
    ## ``record`` by a string key (``record["log"] = ...``) is not in this
    ## list and is allowed: it sets a key and leaves ``record`` the
    ## ``JObject`` the revert mark needs. What a call does to a variable's
    ## state (``g.destroy()``, ``reset(record[])``) is not judged here: a
    ## stop it causes is a runtime failure of the frozen calls, which the
    ## record classifier sees (no ``revertStepReached``, no red revert
    ## step).
  ImpliedCallees = ["contains", "<", "<=", "not", "==", "$", "items"]
    ## What the operators used there expand to (``in`` is ``contains``,
    ## ``!=`` is ``not ==``, ``>`` is ``<``): an overload of one of these
    ## changes the code without changing its text (review of 2026-11-12).
  HookNames = [".", ".=", ".()", "()", "[]", "[]=", "{}", "{}=", "=copy",
    "=sink", "=dup", "=destroy", "=wasMoved", "=trace"]
    ## Names that change what a dot, a call, an index or an assignment does
    ## without being written there.
  RoutineKinds = {nnkProcDef, nnkFuncDef, nnkTemplateDef, nnkMacroDef,
    nnkIteratorDef, nnkConverterDef, nnkMethodDef}
  AllowedPragmas = ["compileTime", "closure"]
    ## The only pragmas this file may use, anywhere. Not a list of the
    ## dangerous ones: ``emit``, ``exportc``, ``codegenDecl``, ``compile``,
    ## ``link``, ``passL`` and others define or wrap a C symbol a frozen
    ## call reaches (an emitted ``memmem`` aborts inside ``in``; review of
    ## 2026-11-12), and ``push``, ``pragma`` and custom pragmas can spell
    ## them indirectly. An ``asm`` statement is refused for the same reason.
  FrozenImports = """
import std/[json, os, sets, strutils, times, unittest]
import repro_test_support/reasoned_skip
import repro_infra
import repro_addon/[fingerprint, ledger]
import repro_dsl_stdlib/packages/apt_closure
import ./addon_testbed
import ./deb_fixture_support
import ./reference_services
import ./snapshot_mirror
import ./upgrade_support
import ./adopt_gate_source
"""
    ## This file's imports, compared whole: another module brought in could
    ## carry the C symbol or the overload this file may not define itself.
    ## What the modules already imported define is theirs to keep.
  FrozenGate = """
suite Gate:
  test "a hand-configured service is adopted with no write and converged " &
       "with its state untouched":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 and REPRO_A12_PACKAGES")
    else:
      let m = startSnapshotMirror(MirrorStamp)
      defer: m.stop()
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(),
          "gateMutation": gateMutation(), "snapshot": MirrorStamp,
          "reprobuild": gitHead(), "gosti": gostiHead(),
          "started": $now().utc}
        let f = runBase(m, b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
"""
    ## The test that runs ``runBase`` for each base, compared whole: the gate
    ## must run the ``runBase`` this check reads, not a copy defined or
    ## called beside it (review of 2026-11-12).
  FrozenGateSource = """
suite "gate source":
  test "under adopt-without-profile the gate reaches the silent-revert step":
    # A structural control on this gate's own source (A13 review round 7,
    # finding 4; the review of 2026-11-12), made by ``adopt_gate_source``
    # while this file compiles: the decision-61 refusal step must not stop
    # the run (under the mutation it is red), the silent-revert step must
    # come after it, and nothing from one to the other can end the run. The
    # cell's record also carries ``revertStepReached``, set when the gate
    # reaches that step, and the committed classifier
    # (``scripts/addon_a13_classify.py``) requires it.
    checkpoint $GateFindings
    check GateFindings.len == 0

  test "the structural check finds every way to stop (negative controls)":
    checkpoint $ControlFailures
    check ControlFailures.len == 0
"""
    ## The gate's tests of this module's verdicts, compared whole. The names
    ## they call are guarded like the frozen code's: the verdicts cannot be
    ## read through a ``check`` or a ``len`` the gate file defines.
  TopLevelNames = [
    ("Gate", nnkConstSection),
    ("MirrorStamp", nnkConstSection),
    ("AmUnit", nnkConstSection),
    ("AmDefault", nnkConstSection),
    ("AmConfig", nnkConstSection),
    ("AmState", nnkConstSection),
    ("VwUnit", nnkConstSection),
    ("VwEnvBase", nnkConstSection),
    ("VwTmpfiles", nnkConstSection),
    ("AmDropInDir", nnkConstSection),
    ("AmDropIn", nnkConstSection),
    ("VwState", nnkConstSection),
    ("MutationStop", nnkTypeSection),
    ("gateMutation", nnkProcDef),
    ("buildAlertmanager", nnkProcDef),
    ("buildVaultwarden", nnkProcDef),
    ("mergeSkeletons", nnkProcDef),
    ("planVerdicts", nnkProcDef),
    ("stateDigest", nnkProcDef),
    ("invocation", nnkProcDef),
    ("healthy", nnkProcDef),
    ("q", nnkProcDef),
    ("convergedProfile", nnkProcDef),
    ("vaultwardenDeb", nnkProcDef),
    ("runBase", nnkProcDef)]
    ## Every name the gate file binds at its top level, in order, with the
    ## kind of its definition. The frozen text resolves its calls and types
    ## where the gate compiles; a new top-level definition can change what
    ## it resolves to without changing a word of it (a ``BaseImage`` of the
    ## gate's own, with a ``name`` proc that stops, behind the recorded
    ## ``var b: BaseImage``; review of 2026-11-12). Adding, removing or
    ## renaming one means changing this list, on purpose.
  LocalRoutines = ["stepNoStop", "step", "depProfile"]
    ## The routines ``runBase`` defines in its body. A name here that the
    ## frozen code calls must be in ``FrozenDefs`` (the guard on bindings
    ## holds it there); ``depProfile`` is not called by it.
  SourceStart = "## Gate ``e2e_addon_adopt_hand_configured_service``"
    ## How the file begins.
  CompileTimeRunners = ["staticExec", "gorge", "gorgeEx"]
    ## Calls that run a program while this file compiles: one could change
    ## what is built without changing this file's text.
  NoParse = "the source does not parse: "
    ## A control that does not parse proves nothing: the controls require
    ## that their findings do not start with this.

proc normName(s: string): string {.compileTime.} =
  ## ``s`` as Nim compares identifiers: the first character as written, the
  ## rest without case or underscores, so ``sTep`` and ``st_ep`` are
  ## ``step`` (https://nim-lang.org/docs/manual.html#lexical-analysis-identifier-equality;
  ## review of 2026-11-12).
  if s.len == 0: return s
  result = $s[0]
  for c in s[1 .. ^1]:
    if c != '_': result.add(c.toLowerAscii)

proc normNames(names: openArray[string]): seq[string] {.compileTime.} =
  for n in names: result.add(normName(n))

proc bindingName(n: NimNode): string {.compileTime.} =
  ## The name a definition's name node binds (exported, quoted or with
  ## pragmas).
  var x = n
  if x.kind == nnkPragmaExpr: x = x[0]
  if x.kind == nnkPostfix: x = x[1]
  if x.kind == nnkAccQuoted:
    for c in x:
      if c.kind == nnkIdent: result.add(c.strVal)
    return normName(result)
  if x.kind == nnkIdent: normName(x.strVal) else: ""

proc routineName(n: NimNode): string {.compileTime.} = bindingName(n[0])

proc namesIn(n: NimNode; found: var seq[string]): seq[string] {.compileTime.} =
  ## Every name a binding position binds, through tuples nested to any
  ## depth (``let (a, (record, b)) = ...``, ``for (record, x) in ...``;
  ## review of 2026-11-12). A position of any other shape is a finding: a
  ## name this check cannot see could shadow one it guards.
  case n.kind
  of nnkVarTuple, nnkPar, nnkTupleConstr:
    for c in n:
      if c.kind != nnkEmpty: result.add(namesIn(c, found))
  of nnkIdent, nnkPostfix, nnkPragmaExpr, nnkAccQuoted:
    let name = bindingName(n)
    if name.len == 0: found.add("a binding of unknown shape `" & n.repr & "`")
    result.add(name)
  else:
    found.add("a binding of unknown shape `" & n.repr & "`")

proc collectBindings(n, runBase: NimNode; bound: var seq[(string, NimNode)];
                     found: var seq[string]) {.compileTime.} =
  ## Every name bound where ``runBase``'s code can see it: at the module's
  ## top level, in ``runBase``'s parameters and anywhere in its body, by a
  ## routine, a ``let``/``var``/``const`` (a lambda bound to a name is a
  ## helper as much as a proc is), a ``for`` loop or a type. Other
  ## routines' parameters and locals are out of its scope. Term-rewriting
  ## patterns, converters, macros, templates and includes of this file are
  ## findings of their own: each changes code it is not written in.
  case n.kind
  of RoutineKinds:
    let name = routineName(n)
    bound.add((name, n))
    if n[1].kind != nnkEmpty:
      found.add("`" & name & "` has a term-rewriting pattern")
    if n.kind in {nnkConverterDef, nnkMacroDef, nnkTemplateDef}:
      found.add("this file defines the " & $n.kind & " `" & name &
        "`, which rewrites or converts code it is not written in")
    if runBase != nil and n == runBase:
      collectBindings(n.params, runBase, bound, found)
      collectBindings(n.body, runBase, bound, found)
  of nnkIdentDefs, nnkVarTuple, nnkConstDef, nnkForStmt:
    for c in n[0 ..< n.len - 2]:
      for name in namesIn(c, found): bound.add((name, n))
    for c in n[n.len - 2 .. ^1]: collectBindings(c, runBase, bound, found)
  of nnkTypeDef:
    bound.add((bindingName(n[0]), n))
  of nnkIncludeStmt:
    found.add("this file includes another: its code is not checked")
  else:
    for c in n: collectBindings(c, runBase, bound, found)

proc uncommented(n: NimNode): NimNode {.compileTime.} =
  ## ``n`` without its ``##`` comments, which run nothing: definitions and
  ## statements are compared without them. A doc comment on an object type
  ## with no fields parses as an empty field list where none is otherwise
  ## (``RecList`` for ``Empty``); both are the same type.
  if n.kind == nnkRecList and n.len == 0: return newEmptyNode()
  result = copyNimNode(n)
  for c in n:
    if c.kind != nnkCommentStmt: result.add(uncommented(c))

proc scopedBindings(n, runBase: NimNode; bound: var seq[(string, NimNode)])
    {.compileTime.} =
  ## The bindings ``runBase`` really sees: the module's own top-level
  ## declarations (not those inside a block or a ``suite``), and every one
  ## in ``runBase``'s parameters and body. ``collectBindings`` is broader on
  ## purpose for callables; for variables a block's own ``record`` is not
  ## ``runBase``'s.
  var ignored: seq[string]
  for c in n:
    case c.kind
    of RoutineKinds:
      if c == runBase:
        collectBindings(c.params, runBase, bound, ignored)
        collectBindings(c.body, runBase, bound, ignored)
    of nnkLetSection, nnkVarSection, nnkConstSection, nnkTypeSection:
      collectBindings(c, nil, bound, ignored)
    of nnkWhenStmt:
      for br in c: scopedBindings(br[^1], runBase, bound)
    of nnkStmtList:
      scopedBindings(c, runBase, bound)
    else: discard

proc identsOf(n: NimNode; into: var seq[string]) {.compileTime.} =
  if n.kind == nnkIdent and n.strVal notin into: into.add(n.strVal)
  for c in n: identsOf(c, into)

proc guardedNames(): seq[string] {.compileTime.} =
  ## The callables and types ``FrozenStmts`` and ``FrozenDefs`` name, what
  ## their operators expand to, and the hook names: none may be bound where
  ## ``runBase`` sees it except by ``FrozenDefs`` itself.
  var named: seq[string]
  identsOf(parseStmt(FrozenStmts), named)
  identsOf(parseStmt(FrozenDefs), named)
  identsOf(parseStmt(FrozenGateSource), named)
  let data = normNames(DataNames)
  for n in named:
    if normName(n) notin data: result.add(normName(n))
  result.add(normNames(ImpliedCallees))
  result.add(normNames(HookNames))

proc assignedRoots(n: NimNode): seq[string] {.compileTime.} =
  ## The variables an assignment's left side writes into (through fields,
  ## indexes and dereferences, and each element of a tuple: ``(g, spare) =
  ## (spare, g)``).
  if n.kind in {nnkTupleConstr, nnkPar} and n.len != 1:
    for c in n: result.add(assignedRoots(c))
    return
  var x = n
  while x.kind in {nnkDotExpr, nnkBracketExpr, nnkDerefExpr, nnkPar} and x.len > 0:
    x = x[0]
  result.add(if x.kind == nnkIdent: normName(x.strVal) else: "")

proc walk(n: NimNode; visit: proc (n: NimNode) {.closure.}) {.compileTime.} =
  visit(n)
  for c in n: walk(c, visit)

proc foreignCodeFindings(tree: NimNode): seq[string] {.compileTime.} =
  ## The pragmas outside ``AllowedPragmas``, the ``asm`` statements and the
  ## ``CompileTimeRunners`` calls anywhere in ``tree``.
  let allowed = normNames(AllowedPragmas)
  let runners = normNames(CompileTimeRunners)
  var found: seq[string]
  var imports: seq[NimNode]
  walk(tree) do (n: NimNode):
    case n.kind
    of nnkPragma:
      for c in n:
        var x = c
        while x.kind in {nnkExprColonExpr, nnkCall, nnkCommand} and x.len > 0:
          x = x[0]
        let name = if x.kind == nnkIdent: normName(x.strVal) else: ""
        if name notin allowed:
          found.add("the pragma `" & c.repr & "`: only " & $AllowedPragmas &
            " may be used in this file")
    of nnkAsmStmt:
      found.add("an asm statement")
    of nnkImportStmt, nnkFromStmt, nnkImportExceptStmt, nnkExportStmt,
       nnkIncludeStmt:
      imports.add(n)
    of nnkIdent:
      if normName(n.strVal) in runners:
        found.add("`" & n.strVal & "` runs a program while this file compiles")
    else: discard
  let frozen = parseStmt(FrozenImports)
  if imports.len != frozen.len:
    found.add("this file has " & $imports.len & " import statements, not " &
      "the " & $frozen.len & " FrozenImports records")
  else:
    for k in 0 ..< frozen.len:
      if imports[k] != frozen[k]:
        found.add("import `" & imports[k].repr & "` is not FrozenImports' `" &
          frozen[k].repr & "`")
  found

proc gateSourceFindings(src: string): seq[string] {.compileTime.} =
  ## Why ``src`` (this gate's source) could end a run of a base between the
  ## decision-61 refusal step and the silent-revert step; empty when it
  ## cannot. Read through Nim's own parser, so comments and string literals
  ## of every form are what the compiler takes them to be.
  ##
  ## ``runBase`` must hold ``FrozenStmts``, exactly and once, in one
  ## statement list, and define what ``FrozenDefs`` defines exactly as it
  ## does. No other binding of a ``guardedNames`` name is visible to
  ## ``runBase``, so no call in those statements can resolve to anything
  ## else of this file. What other modules define is theirs to keep, and a
  ## stop before the refusal step leaves that step unreached as well (the
  ## record classifier requires ``revertStepReached``).
  # The compiler applies a ``#?`` source filter on the first line (after a
  # BOM or a ``#!`` line) before it parses; ``parseStmt`` reads it as a
  # comment, so the file must begin with its own doc comment (review of
  # 2026-11-12; https://nim-lang.org/docs/filters.html).
  if not src.startsWith(SourceStart):
    result.add("the file does not begin with `" & SourceStart & "`: a " &
      "source filter there would change what is compiled, not what is read")
  var tree: NimNode
  try:
    tree = parseStmt(src)
  except ValueError as e:
    return @[NoParse & e.msg]
  result.add(foreignCodeFindings(tree))
  var topLevel: seq[(string, NimNodeKind)]
  for n in tree:
    case n.kind
    of RoutineKinds: topLevel.add((routineName(n), n.kind))
    of nnkLetSection, nnkVarSection, nnkConstSection:
      var ignoredShape: seq[string]
      for d in n:
        for c in d[0 ..< d.len - 2]:
          for name in namesIn(c, ignoredShape): topLevel.add((name, n.kind))
    of nnkTypeSection:
      for d in n: topLevel.add((bindingName(d[0]), n.kind))
    of nnkWhenStmt, nnkStmtList, nnkBlockStmt, nnkStaticStmt:
      result.add("a top-level `" & $n.kind & "`: its definitions are not " &
        "in TopLevelNames")
    else: discard
  var recorded: seq[(string, NimNodeKind)]
  for (name, kind) in TopLevelNames: recorded.add((normName(name), kind))
  if topLevel != recorded:
    result.add("the gate's top-level definitions are " & $topLevel &
      ", not TopLevelNames")
  let gate = parseStmt(FrozenGate)[0]
  var gates = 0
  for n in tree:
    if uncommented(n) == uncommented(gate): inc gates
  if gates != 1:
    result.add("the gate test is not FrozenGate (" & $gates & " found)")
  let sourceTests = parseStmt(FrozenGateSource)[0]
  var sourceSuites = 0
  for n in tree:
    if uncommented(n) == uncommented(sourceTests): inc sourceSuites
  if sourceSuites != 1:
    result.add("the gate-source tests are not FrozenGateSource (" &
      $sourceSuites & " found)")
  var runBase: NimNode
  for n in tree:
    if n.kind == nnkProcDef and routineName(n) == normName("runBase"):
      if runBase != nil: result.add("two procs runBase")
      runBase = n
  if runBase == nil: return @["no top-level proc runBase"]
  # The definitions.
  var bound, frozenBound: seq[(string, NimNode)]
  collectBindings(tree, runBase, bound, result)
  var ignored: seq[string]
  collectBindings(parseStmt(FrozenDefs), nil, frozenBound, ignored)
  let guarded = guardedNames()
  var runBases = 0
  for (name, d) in bound:
    if name == normName("runBase"): inc runBases
  # Inside runBase, as at the top level, nothing may be defined that the
  # frozen text could resolve to: no routine but ``LocalRoutines``, no
  # type.
  var localDefs: seq[string]
  let localRoutines = normNames(LocalRoutines)
  walk(runBase.body) do (n: NimNode):
    if n.kind in RoutineKinds and routineName(n) notin localRoutines:
      localDefs.add("runBase defines the routine `" & routineName(n) & "`")
    elif n.kind == nnkTypeSection:
      localDefs.add("runBase defines a type: `" & n.repr & "`")
  result.add(localDefs)
  if runBases != 1:
    result.add("runBase is bound " & $runBases & " times, not once")
  var seen = newSeq[int](frozenBound.len)
  for (name, d) in bound:
    if name notin guarded: continue
    var k = -1
    for i, (fname, fd) in frozenBound:
      if fname == name and uncommented(fd) == uncommented(d): k = i
    if k < 0:
      result.add("`" & name & "` is bound where runBase can see it, not " &
        "as FrozenDefs binds it: a call of it could stop the run")
    else: inc seen[k]
  for i, (fname, fd) in frozenBound:
    if seen[i] != 1:
      result.add("FrozenDefs' `" & fname & "` is bound " & $seen[i] &
        " times as recorded, not once")
  # The variables those statements read.
  let tracked = normNames(TrackedData)
  var dataBound: seq[(string, NimNode)]
  collectBindings(parseStmt(DataBindings), nil, dataBound, ignored)
  collectBindings(parseStmt(FrozenStmts), nil, dataBound, ignored)
  var dataSeen = newSeq[int](dataBound.len)
  var seenBound: seq[(string, NimNode)]
  scopedBindings(tree, runBase, seenBound)
  for (name, d) in seenBound:
    if name notin tracked: continue
    var k = -1
    for i, (fname, fd) in dataBound:
      if fname == name and uncommented(fd) == uncommented(d): k = i
    if k < 0:
      result.add("`" & name & "` is bound where runBase can see it, not " &
        "as DataBindings or FrozenStmts bind it: the frozen code would read " &
        "another value")
    else: inc dataSeen[k]
  for i, (fname, fd) in dataBound:
    if fname in tracked and dataSeen[i] != 1:
      result.add("`" & fname & "` is bound " & $dataSeen[i] &
        " times as recorded, not once")
  let assigns = parseStmt(DataAssignments)
  var assignSeen = newSeq[int](assigns.len)
  var asgns: seq[NimNode]
  walk(runBase.body) do (n: NimNode):
    if n.kind in {nnkAsgn, nnkFastAsgn}: asgns.add(n)
  for a in asgns:
    var touches = false
    for r in assignedRoots(a[0]):
      if r in tracked: touches = true
    if not touches: continue
    if a[0].kind == nnkBracketExpr and a[0].len == 2 and
        a[0][0].kind == nnkIdent and normName(a[0][0].strVal) == "record" and
        a[0][1].kind in {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
      continue
    var k = -1
    for i, e in assigns:
      if uncommented(a) == uncommented(e): k = i
    if k < 0:
      result.add("runBase assigns `" & a.repr & "`, which DataAssignments " &
        "does not record: the frozen code would read another value")
    else: inc assignSeen[k]
  for i, e in assigns:
    if assignSeen[i] != 1:
      result.add("`" & e.repr & "` is assigned " & $assignSeen[i] &
        " times, not once")
  # The statements.
  let frozen = parseStmt(FrozenStmts)
  var lists: seq[NimNode]
  walk(runBase.body) do (n: NimNode):
    if n.kind == nnkStmtList: lists.add(n)
  var at: seq[(NimNode, int)]
  for n in lists:
    for k, c in n:
      if c == frozen[0]: at.add((n, k))
  if at.len != 1:
    return result & @["runBase holds `" & frozen[0].repr & "` " & $at.len &
      " times, not once"]
  let (list, start) = at[0]
  # Straight-line in ``runBase``'s ``try`` body: not under a branch or a
  # loop that could skip it or run it with other bindings.
  var tryBody: NimNode
  for c in runBase.body:
    if c.kind == nnkTryStmt:
      if tryBody != nil: result.add("runBase has two try statements")
      tryBody = c[0]
  if tryBody == nil or list != tryBody:
    result.add("FrozenStmts is not in the body of runBase's try statement")
  # A ``##`` comment parses as a statement; it runs nothing.
  var held: seq[NimNode]
  for k in start ..< list.len:
    if list[k].kind != nnkCommentStmt: held.add(list[k])
  if held.len < frozen.len:
    return result & @["fewer statements from the refused adopt on than " &
      "FrozenStmts holds"]
  for k in 0 ..< frozen.len:
    if uncommented(held[k]) != uncommented(frozen[k]):
      result.add("from the refused adopt, statement " & $(k + 1) & " is `" &
        held[k].repr & "`, not `" & frozen[k].repr & "`")

const
  GateFile = "t_e2e_addon_adopt_hand_configured_service.nim"
  GateSource = staticRead(currentSourcePath().parentDir / GateFile)
    ## The gate's source as it is on disk, read here: this module is
    ## compiled before any definition of the gate's own, so no definition
    ## in the gate file can change how this module's calls resolve (a
    ## ``staticRead`` defined in the gate file shadowed the system's when
    ## the check lived there; review of 2026-11-12). Code that rewrites the
    ## file while the gate compiles is out of reach (see the module doc).

proc replacedOnce(src, old, by: string): string {.compileTime.} =
  ## ``src`` with the first ``old`` replaced: the anchor's first occurrence
  ## is the gate's own code, later ones are inside these controls' literals.
  let at = src.find(old)
  doAssert at >= 0, old
  src[0 ..< at] & by & src[at + old.len .. ^1]

proc replacedLast(src, old, by: string): string {.compileTime.} =
  ## ``src`` with the last ``old`` replaced: for the gate test, whose text
  ## ``FrozenGate`` repeats earlier in the file.
  let at = src.rfind(old)
  doAssert at >= 0, old
  src[0 ..< at] & by & src[at + old.len .. ^1]

proc underBranch(src: string): string {.compileTime.} =
  ## ``src`` with the statements from the refused adopt through the revert
  ## step moved under an ``if``: the same text, no longer straight-line.
  const First = "    let refusedAdopt = g.adoptResource("
  const After = "    let readopt = g.adoptResource("
  let a = src.find(First)
  let b = src.find(After)
  doAssert a >= 0 and b > a
  var region = ""
  for line in src[a ..< b].splitLines(keepEol = true):
    region.add(if line.strip.len > 0: "  " & line else: line)
  src[0 ..< a] & "    if gateMutation().len == 0:\n" & region & src[b .. ^1]

proc withInserted(src, code: string): string {.compileTime.} =
  ## ``src`` with ``code`` inserted just before the statement between the
  ## two steps (the old profile's switch).
  const At = "    let oldSwitch = g.applyProfile(repro, \"skeleton\", skeleton)\n"
  src.replacedOnce(At, code & At)

const
  StoppingInserts = [
    "    if fails.len > 0: return fails\n",
    "    return fails\n",
    "    if refusedAdopt.exitCode == 0: raise newException(MutationStop, \"x\")\n",
    "    if refusedAdopt.exitCode != 0: raiseAssert \"stop\"\n",
    "    quit(1)\n",
    "    doAssert refusedAdopt.exitCode == 0\n",
    "    if r\"\\\" != \"\" and fails.len > 0: return fails\n",
    "    if refusedAdopt.exitCode != 0: #[ c ]# return @[\"stop\"]\n",
    "    step(\"t\", false, \"\")\n",
    "    step \"t\", false, \"\"\n",
    "    let y = block:\n      return fails\n",
    "    defer: discard\n",
    "    while true: discard\n",
    "    let x = (proc (): int = raise newException(MutationStop, \"x\"))()\n",
    "    g.destroy()\n",
    "    step(\"t\", refusedAdopt.exitCode != 0, \"\")\n",
    "    stepNoStop(\"t\", g.run(\"exit 1\") == \"\", \"\")\n",
    "    record[\"revertStepReached\"] = record[\"absent\"]\n",
    "    record[\"revertStepReached\"] = %(raOut[100000000] == raOut[0])\n",
    "    let strip = proc (s: string): string = raise newException(MutationStop, \"x\")\n",
    "    record[] = newJArray()[]\n"]
    ## Each a way to end, divert or hang the run, inserted between the two
    ## steps: every one must be found, in a source that parses. The
    ## ``raiseAssert``, raw string, ``#[ ]#``, indexing, ``step`` and
    ## ``g.run`` forms are ones earlier versions of this check missed
    ## (review of 2026-11-12).
  GateMutants = [
    GateSource.withInserted("    endRun()\n").replacedOnce(
      "proc runBase(", "proc endRun() = raise newException(MutationStop, \"x\")\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "template applyProfile(g: Guest; r, n, s: string): auto = raise newException(MutationStop, \"x\")\n\nproc runBase("),
    GateSource.replacedOnce("      fails.add(b.name & \": \" & name & \": \" & detail)\n",
      "      fails.add(b.name & \": \" & name & \": \" & detail)\n      raise newException(MutationStop, name)\n"),
    GateSource.replacedOnce("  var fails: seq[string]\n",
      "  var fails: seq[string]\n  let strip = proc (s: string): string = raise newException(MutationStop, \"x\")\n"),
    GateSource.replacedOnce("proc runBase(",
      "let applyProfile = proc (g: Guest; r, n, s: string): int = raise newException(MutationStop, \"x\")\n\nproc runBase("),
    GateSource.replacedOnce("      fails.add(b.name & \": \" & name & \": \" & detail)\n",
      "      fails.add(b.name & \": \" & name & \": \" & detail)\n      step(name, ok, detail)\n"),
    GateSource.replacedOnce("proc runBase(",
      "template t{strip(x)}(x: string): string = raise newException(MutationStop, \"x\")\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "converter toBool(s: string): bool = raise newException(MutationStop, \"x\")\n\nproc runBase("),
    GateSource.replacedOnce("  var fails: seq[string]\n",
      "  var fails: seq[string]\n  proc step(name: string; ok: bool; detail: string)\n"),
    GateSource.replacedOnce("         refusedAdopt.exitCode != 0 and",
      "         g.run(\"exit 1\").len == 0 and refusedAdopt.exitCode != 0 and"),
    GateSource.replacedOnce("         g.run(\"tail -1 /etc/default/alertmanager\").strip() ==",
      "         g.run(\"exit 1; tail -1 /etc/default/alertmanager\").strip() =="),
    GateSource.replacedOnce("    stepNoStop(\"`repro system adopt` refuses",
      "    step(\"`repro system adopt` refuses"),
    GateSource.replacedOnce("    stepNoStop(\"`repro system adopt` refuses",
      "    step((\"`repro system adopt` \" & \"refuses\"), false, \"\")\n    stepNoStop(\"`repro system adopt` refuses"),
    GateSource.replacedOnce("    stepNoStop(name, ok, detail)\n    # Under",
      "    if not ok and mutation().len > 0: raise newException(MutationStop, name)\n    stepNoStop(name, ok, detail)\n    # Under"),
    GateSource.replacedOnce("proc runBase(",
      "type Poison = object\nproc contains(p: string; sub: string): bool = raise newException(MutationStop, \"x\")\n\nproc runBase("),
    GateSource.replacedOnce("proc gateMutation*(): string = getEnv(\"REPRO_A13_MUTATION\")",
      "proc gateMutation*(): string = getEnv(\"REPRO_A13_MUTATION\") & \"x\""),
    GateSource.replacedOnce("type MutationStop = object of CatchableError",
      "type MutationStop = object of Defect"),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    proc sTep(name: string; ok: bool; detail: string) = raise newException(MutationStop, name)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let apply_Profile = proc (g: Guest; r, n, s: string): int = raise newException(MutationStop, \"x\")\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let record = newJArray()\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    expectedStanza = \"\"\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    g = newMirroredGuest(b, m, diskGiB = 10)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    block:\n      let steps = newJArray()\n      discard steps\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("proc runBase(",
      "{.emit: \"\"\"void *memmem(const void *h, unsigned long hl, const void *n, unsigned long nl) { return 0; }\"\"\".}\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "proc myMemmem(h: pointer; hl: int; n: pointer; nl: int): pointer {.exportc: \"memmem\".} = quit(1)\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "{.push exportc.}\nproc memmem(h: pointer; hl: int; n: pointer; nl: int): pointer = quit(1)\n{.pop.}\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "{.compile: \"memmem.c\".}\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "{.passL: \"-Wl,--wrap=memmem\".}\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "proc evil() =\n  asm \"\"\"\n    int3\n  \"\"\"\n\nproc runBase("),
    GateSource.replacedOnce("proc runBase(",
      "const evil = staticExec(\"true\")\n\nproc runBase("),
    GateSource.replacedOnce("import ./upgrade_support\n",
      "import ./upgrade_support\nimport ./evil_memmem\n"),
    GateSource.replacedOnce("proc runBase(",
      "proc evil() =\n  import std/strformat\n\nproc runBase("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let (unused0, (record, unused1)) = (0, (newJArray(), 0))\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    for (record, unused) in [(newJArray(), 0)]: discard record\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedLast("        let f = runBase(m, b, record)",
      "        proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] = quit(1)\n        let f = runBase(m, b, record)"),
    GateSource.replacedLast("        let f = runBase(m, b, record)",
      "        let f = runCopy(m, b, record)"),
    GateSource.underBranch(),
    GateSource.replacedOnce("proc runBase(",
      "type BaseImage = object\n  base: addon_testbed.BaseImage\n\nproc name(b: BaseImage): string = quit(1)\n\nproc runBase("),
    GateSource.replacedOnce("  var g: Guest\n",
      "  var g: Guest\n  proc name(b: BaseImage): string = quit(1)\n"),
    GateSource.replacedOnce("  var g: Guest\n",
      "  type Spare = object\n  var g: Guest\n"),
    GateSource.replacedOnce("proc runBase(",
      "when true:\n  proc evil() = discard\n\nproc runBase("),
    "#? replace(sub = \"x\", by = \"y\")\n" & GateSource,
    "\xEF\xBB\xBF#? replace(sub = \"x\", by = \"y\")\n" & GateSource,
    "#!/usr/bin/env nim\n#? stdtmpl\n" & GateSource,
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    var spare: Guest\n    (g, spare) = (spare, g)\n    let refusedAdopt = g.adoptResource(")]
    ## A stopping helper of this file called between the steps; a template
    ## and a top-level lambda shadowing an allowed call; a ``stepNoStop``
    ## that raises or calls ``step``; a lambda bound to an allowed name in
    ## ``runBase``; a term-rewriting template; a converter; a second
    ## ``step`` declared; a command run in the refusal's arguments and in
    ## the revert's before it records; the refusal recorded with ``step``;
    ## a stopping step with a split title before the refusal; a ``step``
    ## that stops before it records; an overload of what ``in`` expands
    ## to; a ``gateMutation`` that always reports a mutation; a
    ## ``MutationStop`` that ``runBase``'s ``except CatchableError`` no
    ## longer catches; a ``step`` and an ``applyProfile`` spelled in
    ## another style; ``record`` shadowed; a tracked variable assigned
    ## again, one recorded assignment repeated, and ``steps`` bound twice;
    ## a C symbol emitted, exported, exported through ``push``, compiled
    ## in or wrapped at link time; an ``asm`` statement; a program run at
    ## compile time; a module imported that the file does not import now,
    ## at the top level and inside a proc; ``record`` shadowed through a
    ## nested tuple and a tuple loop variable; a second ``runBase`` the
    ## gate calls, and the gate calling another proc; the region under a
    ## branch; a source filter on the first line, after a BOM and after a
    ## shebang; ``g`` swapped through a tuple assignment; a ``BaseImage``
    ## of the gate's own with a ``name`` that stops, a ``name`` proc and a
    ## type defined in ``runBase``, a definition under a top-level ``when``
    ## (review of 2026-11-12).

proc controlFailures(controls: openArray[string]; what: string):
    seq[string] {.compileTime.} =
  ## The ``controls`` (whole sources) the check does not refuse, or refuses
  ## only because they do not parse: a control that does not parse proves
  ## nothing.
  for k, c in controls:
    let f = gateSourceFindings(c)
    if f.len == 0:
      result.add(what & " " & $k & " is not refused")
    elif f[0].startsWith(NoParse):
      result.add(what & " " & $k & " does not parse: " & f[0])

proc insertedSources(): seq[string] {.compileTime.} =
  for s in StoppingInserts: result.add(GateSource.withInserted(s))

const
  GateFindings* = gateSourceFindings(GateSource)
    ## Why the gate's source could end a run between the decision-61
    ## refusal step and the silent-revert step; empty when it cannot.
  CommentFindings = gateSourceFindings(GateSource.withInserted(
    "    # return fails; raise; quit\n    ## raiseAssert endRun\n"))
  InsertFailures = controlFailures(insertedSources(), "insert")
  MutantFailuresA = controlFailures(GateMutants[0 ..< 20], "mutant")
  MutantFailuresB = controlFailures(GateMutants[20 .. ^1], "mutant (from 20)")
    ## Evaluated in parts: each constant expression has its own budget of
    ## compile-time loop iterations.
  ControlFailures* = (if CommentFindings.len > 0:
      @["comments alone are refused: " & $CommentFindings] else: @[]) &
    InsertFailures & MutantFailuresA & MutantFailuresB
    ## The negative controls the check gets wrong: a comment-only insert it
    ## refuses, or a stopping form it lets through; empty when it gets all
    ## of them right.

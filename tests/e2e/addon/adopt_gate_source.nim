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
## The variables the frozen code reads, which a call, an address or a
## second name can change without an assignment (``let r = record; r[] =
## ...``, ``amAddress.setLen(0)``, ``let p = addr skeleton``), are used in
## ``runBase`` only as recorded: each use, by its access path and where it
## stands, is in ``RecordedUses``, and every name ``runBase`` writes is in
## ``RunBaseNames``, so nothing new can reach them unnamed (``locals()``).
## Nim's unsafe features (``cast``, ``ptr``, ``addr``, ``rawEnv``) are
## refused anywhere in the file, and the revert mark and ``steps.add`` are
## written only where the frozen code writes them, so the record classifier
## cannot be handed a revert step the run never reached.
##
## Each of those checks freezes one part of the gate, and the reviews of
## 2026-11-12 each found a part left open (the last: a helper that wraps
## ``ssh`` on ``PATH`` and fails the old profile's switch). So the whole
## gate's code, comments aside, is pinned as well, by ``GateDigest``: a
## change anywhere in it fails until it is reviewed against these checks
## and the new digest recorded, on purpose. No Nim configuration file
## besides the repository's ``config.nims`` may apply to the gate's
## compile (``configFindings``), and no module beside the gate or a helper
## it imports relatively may take over one of their non-relative imports
## (``importFindings``). The structural checks state
## why the reviewed gate cannot stop between the steps, and each keeps its
## own negative controls.
##
## Out of its reach, by design: what the modules the gate imports define,
## and what the gate's recorded calls do to the guest (a ``g.run`` of the
## reviewed gate). Code that runs while the gate compiles and rewrites the
## file before this module reads it is tampering with this check's input,
## like an edit of this module: it stands in the committed gate, plain in
## a diff, and changes its digest. The record classifier
## (``scripts/addon_a13_classify.py``) requires ``revertStepReached`` and a
## red revert step in a ``mutadoptprofile`` cell, which catches a runtime
## failure of the frozen calls.
##
## It exports two verdicts, computed at compile time: ``GateFindings``
## (empty when the gate is the reviewed one and cannot stop between the
## steps) and ``ControlFailures`` (empty when every negative control is
## refused, the comment-only control is not, and the digest ignores
## comments but not code).
##
## *Mocking.* None: the gate's real source, and copies of it with one
## change each.

import std/[compilesettings, macros, os, sets, strutils]

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
    ##
    ## A value can also change with no assignment of its name: through a
    ## second name for a reference (``let r = record; r[] =
    ## newJArray()[]`` makes the revert mark raise; so does ``let r =
    ## record.JsonNode``, a conversion in dot form), through a call that
    ## writes it in place (``amAddress.setLen(0)``, ``amAddress &= "x"``,
    ## ``reset(g)``), or through an address, which ``addr`` takes of a
    ## ``let`` too (``let p = addr skeleton; p[] = skeleton2`` has the
    ## frozen switch apply the edited profile; reviews of 2026-11-12).
    ## Which call writes its argument, and which dotted name is a type,
    ## cannot be read from the source alone, so a list of the forms to
    ## refuse would miss what it does not spell, as the stopping words did.
    ## Every use of these names is recorded instead, in ``RecordedUses``.
  RecordedUses = [
    "amaddress as argument 2 of &",
    "amaddress as argument 2 of ==",
    "amaddress as argument 4 of adoptresource",
    "amaddress in nnkAsgn 0",
    "amaddress in nnkIdentDefs 0",
    "amaddress.len as argument 1 of >",
    "b as argument 1 of newmirroredguest",
    "b as argument 2 of aptclosurefixture",
    "b.name as argument 1 of &",
    "b.osid as argument 1 of ==",
    "expectedstanza as argument 1 of in",
    "expectedstanza as argument 2 of &",
    "expectedstanza in nnkAsgn 0",
    "expectedstanza in nnkIdentDefs 0",
    "expectedstanza.len as argument 1 of >",
    "expectedstanza.split called",
    "fails in nnkIdentDefs 0",
    "fails in nnkReturnStmt 0",
    "fails in nnkStmtList 6",
    "fails.add called",
    "fails.len as argument 1 of >",
    "g in nnkAsgn 0",
    "g in nnkIdentDefs 0",
    "g.adoptresource called",
    "g.applyprofile called",
    "g.boot called",
    "g.bootstrapaddon called",
    "g.buildalertmanager called",
    "g.buildvaultwarden called",
    "g.closurebinding called",
    "g.exec called",
    "g.healthy called",
    "g.installartefact called",
    "g.invocation called",
    "g.ledgerof called",
    "g.planprofile called",
    "g.preparemirroredbase called",
    "g.run called",
    "g.rundir as argument 1 of /",
    "g.seedclosurecache called",
    "g.sha256inguest called",
    "g.statedigest called",
    "g.takefingerprint called",
    "oldswitch in nnkIdentDefs 0",
    "oldswitch.stderr as argument 2 of &",
    "oldswitch.stdout as argument 1 of &",
    "raout as argument 1 of &",
    "raout as argument 2 of in",
    "raout in nnkIdentDefs 0",
    "record[] in nnkAsgn 0",
    "refusedadopt in nnkIdentDefs 0",
    "refusedadopt.exitcode as argument 1 of !=",
    "refusedadopt.stderr as argument 2 of &",
    "refusedadopt.stdout as argument 1 of &",
    "repro as argument 1 of &",
    "repro as argument 1 of adoptresource",
    "repro as argument 1 of applyprofile",
    "repro as argument 1 of bootstrapaddon",
    "repro as argument 1 of planprofile",
    "repro as argument 1 of statedigest",
    "repro as argument 1 of takefingerprint",
    "repro as argument 2 of &",
    "repro in nnkVarTuple 0",
    "skeleton as argument 1 of parsesystemprofile",
    "skeleton as argument 2 of writefile",
    "skeleton as argument 3 of adoptresource",
    "skeleton as argument 3 of applyprofile",
    "skeleton as argument 3 of planprofile",
    "skeleton in nnkIdentDefs 0",
    "steps in nnkIdentDefs 0",
    "steps.add called"]
    ## Every ``useSignature`` of a ``TrackedData`` name in ``runBase``, up to
    ## the end of the ``try`` body that holds the frozen statements (its
    ## ``except`` and ``finally`` branches run after them: ``record["steps"]
    ## = steps`` and ``g != nil`` there are the gate's own). Bindings and
    ## assignments of the names are judged by ``DataBindings`` and
    ## ``DataAssignments``; ``record[] in nnkAsgn 0`` is a keyed write, which
    ## the assignment check allows only with a string key. A new use means
    ## changing this list, on purpose.
  RunBaseNames = """
!= $ % %* & + .. ..< / == > @ Amdropindir Amstate Closurefixture Guest
Mutationstop Vwstate ^ a a0am a0vw ad add address admintoken adopted
adoptresource after after2 all amaddress ambind amclosure and
applyprofile aptclosurefixture b back bool boot bootstrapaddon
buildalertmanager buildvaultwarden ca closurebinding collision content
conv convergedprofile createdir d0am d0vw d1 d1am d1vw d2 d2out debs
declared depfile depprofile depunit detail diskgib doc e edited
editedbytes endline endswith entries epochtime exec exitcode
expectedstanza f f0 f1 f2 fails false g gatemutation healthy i
identityreport in incl inithashset installartefact int64 inv1 inv2 invam
invocation invvw join journal journalfailedafterstart journalstarted la
laout led ledgerbefore ledgerof len line lines liveprofile liveunit
loadeduser loadsystemintent lock locktext m mergeskeletons missing mode
mutation n name needles newdigest newexception newjarray
newmirroredguest nonadopt not notin ok oldswitch or origunits osid
parseledger parsesystemprofile path plan planprofile planverdicts
preparemirroredbase put r raout rb re0 re1 readopt record refusedadopt
renderaptclosurelock renderstanza reout repro resource resources run
rundir same seedclosurecache seq serialize sfcontent sha sha256
sha256inguest shas sk skam skeleton skeleton2 skpk skvw sp split
splitlines splitwhitespace stanzaspans startline startswith statedigest
stderr stdout step stepnostop steps string strip takefingerprint text
timeoutsec true uid uids1 uids2 unmatched v vaultwardendeb verdicts vw
vwbind wantadopted work writefile x zero
"""
    ## Every name ``runBase`` writes up to the end of the ``try`` body that
    ## holds the frozen statements, as ``normName`` compares them. A value
    ## can be reached without naming it: ``locals()`` lists every local and
    ## parameter, so ``for k, v in fieldPairs(locals()): when k == "record":
    ## v[] = newJArray()[]`` makes the revert mark raise with no use of
    ## ``record`` to record, and ``rawEnv`` reaches the step procs'
    ## closure (review of 2026-11-12). Which call reflects on what cannot
    ## be listed either, so the names are recorded: one new to ``runBase``
    ## means changing this list, on purpose.
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
  GateDigest =
    "0f910d580c38a718dd96416615383490ba068ed2f603a45e931ddfbe3c312128"
    ## ``codeDigest`` of the gate as reviewed. The structural checks above
    ## are each a freeze of one part of the gate, and seven reviews of
    ## 2026-11-12 each found a part left open: a helper of the gate that
    ## puts a wrapper of ``ssh`` on ``PATH`` stops the run at the old
    ## profile's switch, with no code between the steps, no tracked name
    ## and no unsafe feature. So the whole gate is pinned: any change to
    ## its code, wherever it is, fails until it is reviewed against these
    ## checks and its digest recorded here, on purpose. Comments and layout
    ## do not change the digest, and it is SHA-256, so no crafted change
    ## keeps it (a 64-bit FNV-1a was matched by a crafted string literal;
    ## review of 2026-11-12).
  RevertMark = "revertStepReached"
    ## The record key the frozen statements set when the run reaches the
    ## silent-revert step, which the record classifier requires.
  UnsafeNames = ["addr", "unsafeAddr", "pointer", "cstring",
    "UncheckedArray", "copyMem", "moveMem", "zeroMem", "equalMem", "cmpMem",
    "alloc", "alloc0", "allocShared", "allocShared0", "realloc", "realloc0",
    "reallocShared", "dealloc", "deallocShared", "rawEnv", "rawProc",
    "locals", "byaddr", "offsetOf"]
    ## With ``cast`` and ``ptr`` (node kinds, refused as such), Nim's unsafe
    ## features: raw addresses and memory, a closure's environment, a
    ## frame's locals (https://nim-lang.org/docs/manual.html#statements-and-expressions-the-addr-operator,
    ## https://nim-lang.org/docs/system.html#rawEnv%2CT). The gate uses
    ## none. One anywhere in the file writes what the frozen code reads
    ## with no name the other checks see: a ``cast`` of ``stepNoStop`` to a
    ## pair of ints reaches the step procs' closure, and a write at an
    ## offset of it corrupts ``b.name`` so the red refusal step aborts the
    ## run; ``rawEnv(step)`` in a helper the step proc is passed to does the
    ## same (review of 2026-11-12).
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

proc unknownIdents(n: NimNode; known: HashSet[string];
    into: var seq[string]) {.compileTime.} =
  ## The identifiers in ``n`` that ``known`` (``normName``s) does not hold.
  ## A set, not a list: this runs once per negative control, inside the
  ## compile-time iteration budget.
  if n.kind == nnkIdent and normName(n.strVal) notin known and
      n.strVal notin into:
    into.add(n.strVal)
  for c in n: unknownIdents(c, known, into)

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

proc useSignature(name: string; up: seq[(NimNode, int)]): string
    {.compileTime.} =
  ## How the use of ``name`` whose ancestors are ``up`` (each node with the
  ## index of the child on the way down, innermost last) reads it: the
  ## access path (``g.run``, ``record[]``: members and keyed indexes), then
  ## where that path stands: the callee of a call, argument ``k`` of a
  ## named call, or a node kind and child index. Names are compared as Nim
  ## compares them (``normName``).
  result = name
  var j = up.len - 1
  while j >= 0:
    let (p, i) = up[j]
    if p.kind == nnkDotExpr and i == 0 and p[1].kind == nnkIdent:
      result.add("." & normName(p[1].strVal))
    elif p.kind == nnkBracketExpr and i == 0 and p.len >= 2:
      result.add("[]")
    else: break
    dec j
  if j < 0: return result & " at the top"
  let (p, i) = up[j]
  if p.kind in {nnkCall, nnkCommand, nnkCallStrLit} and i == 0:
    result.add(" called")
  elif p.kind in {nnkCall, nnkCommand, nnkCallStrLit, nnkInfix, nnkPrefix,
      nnkPostfix}:
    var callee = p[0]
    if callee.kind == nnkDotExpr: callee = callee[1]
    let named = if callee.kind == nnkIdent: normName(callee.strVal)
                else: $callee.kind
    result.add(" as argument " & $i & " of " & named)
  else:
    result.add(" in " & $p.kind & " " & $i)

proc collectUses(n: NimNode; names: seq[string]; up: var seq[(NimNode, int)];
    into: var seq[(string, NimNode)]) {.compileTime.} =
  ## The ``useSignature`` of each use of ``names`` in ``n``, with the node
  ## it stands in (for the message).
  if n.kind == nnkIdent and normName(n.strVal) in names:
    let parent = if up.len > 0: up[^1][0] else: n
    into.add((useSignature(normName(n.strVal), up), parent))
  for i, c in n:
    up.add((n, i))
    collectUses(c, names, up, into)
    discard up.pop()

proc walk(n: NimNode; visit: proc (n: NimNode) {.closure.}) {.compileTime.} =
  visit(n)
  for c in n: walk(c, visit)

proc foreignCodeFindings(tree: NimNode): seq[string] {.compileTime.} =
  ## The pragmas outside ``AllowedPragmas``, the ``asm`` statements, the
  ## ``CompileTimeRunners`` calls, the casts, raw pointer types and
  ## ``UnsafeNames`` anywhere in ``tree``, and imports other than
  ## ``FrozenImports``.
  let allowed = normNames(AllowedPragmas)
  let runners = normNames(CompileTimeRunners)
  let unsafe = normNames(UnsafeNames)
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
    of nnkCast:
      found.add("a cast: `" & n.repr & "`")
    of nnkPtrTy:
      found.add("a raw pointer type: `" & n.repr & "`")
    of nnkIdent:
      if normName(n.strVal) in runners:
        found.add("`" & n.strVal & "` runs a program while this file compiles")
      elif normName(n.strVal) in unsafe:
        found.add("`" & n.strVal & "` is an unsafe feature: it reaches " &
          "memory the frozen code reads without naming it")
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
  var revertMarks = 0
  for a in asgns:
    var touches = false
    for r in assignedRoots(a[0]):
      if r in tracked: touches = true
    if not touches: continue
    if a[0].kind == nnkBracketExpr and a[0].len == 2 and
        a[0][0].kind == nnkIdent and normName(a[0][0].strVal) == "record" and
        a[0][1].kind in {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
      if a[0][1].strVal == RevertMark: inc revertMarks
      continue
    var k = -1
    for i, e in assigns:
      if uncommented(a) == uncommented(e): k = i
    if k < 0:
      result.add("runBase assigns `" & a.repr & "`, which DataAssignments " &
        "does not record: the frozen code would read another value")
    else: inc assignSeen[k]
  # The evidence the record classifier reads: ``revertStepReached`` is set
  # only by the frozen statement, and a step enters ``steps`` only through
  # ``stepNoStop``. Another write of either forges a revert step the run
  # never reached (review of 2026-11-12).
  if revertMarks != 1:
    result.add("runBase sets record[\"" & RevertMark & "\"] " & $revertMarks &
      " times, not once (by FrozenStmts)")
  for i, e in assigns:
    if assignSeen[i] != 1:
      result.add("`" & e.repr & "` is assigned " & $assignSeen[i] &
        " times, not once")
  # The uses of the variables a call or a second name can change, up to the
  # end of the ``try`` body that holds the frozen statements.
  let mutable = normNames(TrackedData)
  var uses: seq[(string, NimNode)]
  for i, c in runBase.body:
    var up: seq[(NimNode, int)]
    if c.kind == nnkTryStmt:
      up.add((c, 0))
      collectUses(c[0], mutable, up, uses)
    else:
      up.add((runBase.body, i))
      collectUses(c, mutable, up, uses)
  let known = toHashSet(RunBaseNames.splitWhitespace())
  var unknown: seq[string]
  for c in runBase.body:
    unknownIdents(if c.kind == nnkTryStmt: c[0] else: c, known, unknown)
  for x in unknown:
    result.add("runBase names `" & x & "`, which RunBaseNames does not " &
      "record: it could reach what the frozen code reads without naming it")
  let recordedUses = toHashSet(RecordedUses)
  var stepAdds = 0
  for (sig, at) in uses:
    if sig == "steps.add called": inc stepAdds
  if stepAdds != 1:
    result.add("runBase calls steps.add " & $stepAdds & " times, not once " &
      "(by stepNoStop)")
  for (sig, at) in uses:
    if sig notin recordedUses:
      result.add("runBase uses " & sig & " (in `" & at.repr & "`), which " &
        "RecordedUses does not record: it could change what the frozen " &
        "code reads without an assignment of it")
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
      "    var spare: Guest\n    (g, spare) = (spare, g)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let r = record\n    r[] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    var r: JsonNode\n    r = steps\n    r[] = newJObject()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let (r, unused) = (record, 0)\n    r[] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    for r in [record]: r[] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    record[\"self\"] = record\n    record[\"self\"][] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let p = addr g\n    p[] = nil\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    g.reset()\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    reset(amAddress)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    record[] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let r = record.JsonNode\n    r[] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let r = steps.JsonNode()\n    r[] = newJObject()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let h = g.Guest\n    h[] = default(typeof(h[]))\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    amAddress.setLen(0)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    amAddress &= \"x\"\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    inc expectedStanza[0]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    g.runDir.setLen(0)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    g.destroy()\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let p = addr skeleton\n    p[] = skeleton2\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let p = unsafeAddr repro\n    p[] = \"true\"\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    copyMem(skeleton.cstring, skeleton2.cstring, skeleton.len)\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    for k, v in fieldPairs(locals()):\n      when k == \"record\": v[] = newJArray()[]\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let envp = rawEnv(stepNoStop)\n    discard envp\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    let x = cast[(int64, int64)](stepNoStop)\n    cast[ptr int64](x[1] + 32)[] = 1125899906842624\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("  ## alertmanager, configured by hand from apt's package.\n",
      "  ## alertmanager, configured by hand from apt's package.\n  let envp = rawEnv(step)\n  cast[ptr int](cast[int](envp) + 32)[] = 1 shl 50\n"),
    GateSource.replacedOnce("  ## alertmanager, configured by hand from apt's package.\n",
      "  ## alertmanager, configured by hand from apt's package.\n  var q: ptr int\n  discard q\n"),
    GateSource.replacedOnce("    let refusedAdopt = g.adoptResource(",
      "    record[\"revertStepReached\"] = %true\n    let refusedAdopt = g.adoptResource("),
    GateSource.replacedOnce("      fails.add(b.name & \": \" & name & \": \" & detail)\n",
      "      fails.add(b.name & \": \" & name & \": \" & detail)\n      steps.add(%*{\"step\": name, \"ok\": false})\n")]
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
    ## type defined in ``runBase``, a definition under a top-level ``when``;
    ## before the refusal step, ``record`` and ``steps`` aliased through a
    ## binding, an assignment, a tuple, a loop and a key of ``record``
    ## itself, then overwritten through the alias; ``g``'s address taken;
    ## ``g`` and ``amAddress`` reset; ``record`` overwritten through a
    ## dereference; ``record``, ``steps`` and ``g`` aliased through a
    ## conversion in dot form; ``amAddress`` and ``expectedStanza`` changed
    ## in place by calls, a field of ``g`` truncated, and ``g`` destroyed;
    ## the ``let``s ``skeleton`` and ``repro`` written through an address and
    ## a ``copyMem``; ``record`` reached through ``locals()``, and the step
    ## procs' closure through ``rawEnv``; that closure written through a
    ## ``cast`` in ``runBase`` and through ``rawEnv`` in a helper the step
    ## proc is passed to, and a raw pointer declared there (reviews of
    ## 2026-11-12); and the revert mark and a red step written outside the
    ## frozen statements and ``stepNoStop``, which the record classifier
    ## would take for a reached revert step (review of 2026-11-12).

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

proc treeText(n: NimNode; into: var string) {.compileTime.} =
  ## ``n`` as text that depends only on what the compiler takes from the
  ## source: each node's kind and literal, comments left out. Not
  ## ``repr``, whose layout can change with the compiler.
  if n.kind == nnkCommentStmt: return
  into.add("(" & $n.kind)
  case n.kind
  of nnkCharLit .. nnkUInt64Lit: into.add(" " & $n.intVal)
  of nnkFloatLit .. nnkFloat64Lit: into.add(" " & $n.floatVal)
  of nnkStrLit .. nnkTripleStrLit, nnkIdent, nnkSym:
    into.add(" " & $n.strVal.len & ":" & n.strVal)
  else: discard
  for c in n: treeText(c, into)
  into.add(")")

const Sha256K = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]
  ## SHA-256's round constants (FIPS 180-4, 4.2.2).

proc sha256Hex*(msg: string): string {.compileTime.} =
  ## SHA-256 of ``msg`` in hex (FIPS 180-4,
  ## https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf), written
  ## here because the standard library's runs only at run time. A
  ## collision-resistant hash: a 64-bit FNV-1a of the same text was
  ## matched by a crafted string literal in a few minutes (review of
  ## 2026-11-12).
  proc rotr(x: uint32; n: int): uint32 = (x shr n) or (x shl (32 - n))
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var data = msg
  let bits = uint64(msg.len) * 8
  data.add('\x80')
  while data.len mod 64 != 56: data.add('\0')
  for i in countdown(7, 0): data.add(char((bits shr (8 * i)) and 0xff))
  var w: array[64, uint32]
  var at = 0
  while at < data.len:
    for t in 0 ..< 16:
      let j = at + 4 * t
      w[t] = (uint32(ord(data[j])) shl 24) or (uint32(ord(data[j + 1])) shl 16) or
        (uint32(ord(data[j + 2])) shl 8) or uint32(ord(data[j + 3]))
    for t in 16 ..< 64:
      let s0 = rotr(w[t - 15], 7) xor rotr(w[t - 15], 18) xor (w[t - 15] shr 3)
      let s1 = rotr(w[t - 2], 17) xor rotr(w[t - 2], 19) xor (w[t - 2] shr 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5],
      h[6], h[7])
    for t in 0 ..< 64:
      let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + s1 + ch + Sha256K[t] + w[t]
      let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      hh = g; g = f; f = e; e = d + t1
      d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    at += 64
  for x in h: result.add(toHex(x).toLowerAscii)

const
  Sha256Abc =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  Sha256TwoBlocks =
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  Sha256TwoBlocksDigest =
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

proc configFindings(): seq[string] {.compileTime.} =
  ## The Nim configuration files that would apply to the gate's compile
  ## besides the repository's own ``config.nims``: one could add an
  ## ``--import``, a define or a link flag that the gate's text does not
  ## show. Nim reads the project's ``<stem>.nimcfg``, ``<stem>.nim.cfg`` and
  ## ``<stem>.nims``, ``nim.cfg`` and ``config.nims`` in every directory
  ## from the root down to the project's, and the user's under
  ## ``$XDG_CONFIG_HOME/nim`` (https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files;
  ## ``loadConfigs`` in the compiler's ``nimconf.nim``; review of
  ## 2026-11-12). None exists. The toolchain's own ``config/nim.cfg`` is
  ## the compiler's, like the modules the gate imports.
  let here = currentSourcePath().parentDir
  let repoRoot = here.parentDir.parentDir.parentDir
  let stem = GateFile.changeFileExt("")
  var paths = @[here / stem & ".nimcfg", here / stem & ".nim.cfg",
    here / stem & ".nims"]
  var dir = here
  while true:
    paths.add(dir / "nim.cfg")
    if dir != repoRoot: paths.add(dir / "config.nims")
    let up = dir.parentDir
    if up == dir or up.len == 0: break
    dir = up
  let home = getEnv("HOME")
  let xdg = getEnv("XDG_CONFIG_HOME",
    if home.len > 0: home / ".config" else: "")
  if xdg.len > 0:
    paths.add(xdg / "nim" / "nim.cfg")
    paths.add(xdg / "nim" / "config.nims")
  for p in paths:
    if fileExists(p):
      result.add("`" & p & "` would configure the gate's compile")

proc importPaths(n: NimNode): seq[string] {.compileTime.} =
  ## The module paths one item of an import statement names:
  ## ``./a`` -> ``./a``, ``x/[a, b]`` -> ``x/a`` and ``x/b``, ``x/a as y``
  ## -> ``x/a``.
  case n.kind
  of nnkIdent: @[n.strVal]
  of nnkStrLit .. nnkTripleStrLit: @[n.strVal]
  of nnkPrefix:
    var r: seq[string]
    for p in importPaths(n[1]): r.add(n[0].strVal & p)
    r
  of nnkInfix:
    if n[0].strVal == "as": return importPaths(n[1])
    var r: seq[string]
    for a in importPaths(n[1]):
      for b in importPaths(n[2]): r.add(a & n[0].strVal & b)
    r
  of nnkBracket, nnkPar:
    var r: seq[string]
    for c in n: r.add(importPaths(c))
    r
  of nnkImportAs: importPaths(n[0])
  else: @[]

proc importStmts(n: NimNode; into: var seq[NimNode]) {.compileTime.} =
  ## The import and include statements in ``n``, at any depth. A plain
  ## recursion: a ``walk`` closure made in a loop shares its captured
  ## variables across iterations when the compiler evaluates it.
  if n.kind in {nnkImportStmt, nnkFromStmt, nnkImportExceptStmt,
      nnkIncludeStmt}:
    into.add(n)
  for c in n: importStmts(c, into)

proc importFindings(): seq[string] {.compileTime.} =
  ## A module or package beside a module of the gate that takes over one
  ## of its non-relative imports. Nim looks for ``import repro_infra`` in
  ## the importing module's own directory before its search path, so a new
  ## ``repro_infra.nim`` beside the gate replaces the library without a
  ## change to any import (https://nim-lang.org/docs/manual.html#modules-module-names-in-imports;
  ## review of 2026-11-12). Followed from the gate through every relative
  ## import; what is found through the search path is the modules the gate
  ## imports, out of this check's reach.
  # Nim takes the first match over its search path, so a second copy of an
  # imported module anywhere on it may be the one compiled: a
  # ``repro_infra.nim`` added to ``libs/stint/src``, which comes earlier,
  # replaced the library's (review of 2026-11-12). Each non-relative import
  # must name exactly one file there. ``std/`` imports are looked up in the
  # standard library's own directories only.
  let searchDirs = querySettingSeq(searchPaths) & querySettingSeq(lazyPaths)
  var todo = @[currentSourcePath().parentDir / GateFile]
  var seen: seq[string]
  while todo.len > 0:
    let file = todo.pop()
    if file in seen or not fileExists(file): continue
    seen.add(file)
    let dir = file.parentDir
    var imports: seq[NimNode]
    importStmts(parseStmt(staticRead(file)), imports)
    for st in imports:
      var items: seq[NimNode]
      if st.kind in {nnkFromStmt, nnkImportExceptStmt}: items.add(st[0])
      else:
        for c in st: items.add(c)
      for item in items:
        for path in importPaths(item):
          if path.startsWith("."):
            todo.add(normalizedPath(dir / path & ".nim"))
          else:
            let first = path.split('/')[0]
            for shadow in [dir / first & ".nim", dir / first]:
              if fileExists(shadow) or dirExists(shadow):
                result.add("`" & shadow & "` takes over `import " & path &
                  "` in " & file.extractFilename)
            if first != "std":
              var hits: seq[string]
              for sp in searchDirs:
                if fileExists(sp / path & ".nim"): hits.add(sp / path & ".nim")
              if hits.len != 1:
                result.add("`import " & path & "` in " & file.extractFilename &
                  " resolves to " & $hits.len & " files on the search path, " &
                  "not one: " & $hits)

proc codeDigest*(src: string): string {.compileTime.} =
  ## SHA-256 of ``src``'s ``treeText``: the same for the same code whatever
  ## its comments and layout.
  var text = ""
  treeText(parseStmt(src), text)
  sha256Hex(text)

proc insertedSources(): seq[string] {.compileTime.} =
  for s in StoppingInserts: result.add(GateSource.withInserted(s))

const
  GateCodeDigest = codeDigest(GateSource)
    ## Each digest is its own constant: each has its own budget of
    ## compile-time loop iterations.
  ImportFindings = importFindings()
  GateFindings* = gateSourceFindings(GateSource) & configFindings() &
    ImportFindings &
    (if GateCodeDigest == GateDigest: @[]
     else: @["the gate's code (comments aside) has digest " &
       GateCodeDigest & ", not the reviewed GateDigest " &
       GateDigest & ": review the change against this module's checks " &
       "and record the new digest"])
    ## Why the gate's source could end a run between the decision-61
    ## refusal step and the silent-revert step, or is not the gate reviewed
    ## as unable to; empty when it is the reviewed gate and cannot.
  CommentFindings = gateSourceFindings(GateSource.withInserted(
    "    # return fails; raise; quit\n    ## raiseAssert endRun\n"))
  InsertFailures = controlFailures(insertedSources(), "insert")
  MutantFailuresA = controlFailures(GateMutants[0 ..< 12], "mutant")
  MutantFailuresB = controlFailures(GateMutants[12 ..< 24], "mutant (from 12)")
  MutantFailuresC = controlFailures(GateMutants[24 ..< 36], "mutant (from 24)")
  MutantFailuresD = controlFailures(GateMutants[36 ..< 48], "mutant (from 36)")
  MutantFailuresE = controlFailures(GateMutants[48 ..< 60], "mutant (from 48)")
  MutantFailuresF = controlFailures(GateMutants[60 .. ^1], "mutant (from 60)")
    ## Evaluated in parts: each constant expression has its own budget of
    ## compile-time loop iterations.
  WrapperSource = GateSource.replacedOnce(
    "  ## vaultwarden, installed by hand from a downloaded binary.\n",
    "  ## vaultwarden, installed by hand from a downloaded binary.\n" &
    "  putEnv(\"PATH\", g.runDir & \":\" & getEnv(\"PATH\"))\n")
  CommentedDigest = codeDigest(GateSource.withInserted("    # c\n    ## d\n"))
  WrapperDigest = codeDigest(WrapperSource)
  DigestFailures =
    (if CommentedDigest != GateCodeDigest: @["a comment changes the digest"]
     else: @[]) &
    (if WrapperDigest == GateCodeDigest:
       @["a helper that wraps ssh on PATH keeps the digest"] else: @[]) &
    (if sha256Hex("abc") != Sha256Abc: @["sha256Hex(\"abc\") is not " &
       "FIPS 180-2's test vector"] else: @[]) &
    (if sha256Hex(Sha256TwoBlocks) != Sha256TwoBlocksDigest:
       @["sha256Hex of the two-block test message is not FIPS 180-2's " &
         "test vector"] else: @[])
    ## The digest ignores comments, changes with code the structural
    ## checks do not read (a helper's body), and is SHA-256: it gives the
    ## published digests of FIPS 180-2's examples
    ## (https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Standards-and-Guidelines/documents/examples/SHA256.pdf).
  ControlFailures* = DigestFailures & (if CommentFindings.len > 0:
      @["comments alone are refused: " & $CommentFindings] else: @[]) &
    InsertFailures & MutantFailuresA & MutantFailuresB & MutantFailuresC &
    MutantFailuresD & MutantFailuresE & MutantFailuresF
    ## The negative controls the check gets wrong: a comment-only insert it
    ## refuses, or a stopping form it lets through; empty when it gets all
    ## of them right.

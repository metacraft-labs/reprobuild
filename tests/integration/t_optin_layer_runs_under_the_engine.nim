## An opt-in test layer must be something ``repro build`` can actually
## RUN, and asking for it must not be answerable from the other setting's
## cache entry.
##
## ## The defect, as measured rather than as assumed
##
## ``tests/integration/t_pcr_composite_matches_tpm.nim`` carries a second
## layer that starts a real software TPM. It was switched on by an
## environment variable that appeared in no recipe, and the two things that
## followed from that are not the two things one would guess.
##
## What did NOT happen is the variable being dropped. An action's
## environment is layered OVER the environment the build was launched with,
## so an undeclared name is inherited. Driven through the engine with the
## layer requested and its tools pointed at a path that does not exist, the
## build FAILED — and it failed with the layer's own diagnostic, which is
## only reachable by executing the layer.
##
## What DID happen is worse and quieter. The same invocation without
## ``--force-rebuild``, after one ordinary green run, returned **exit 0**:
## the engine replayed a result recorded with the layer OFF, because the
## variable reached the process but never reached the action's cache key.
## A green ``repro build`` therefore said nothing whatever about the layer.
##
## ## What this gate holds shut, and how it avoids being satisfied by an honest absence
##
## The obvious check — "run it with the layer on and see that the suite is
## green" — is worthless here, because a layer that is absent and SAYS SO
## also produces a green suite, and a cache hit produces a green suite
## without running anything at all. Reading the summary line is how this
## defect survived being looked at.
##
## So the evidence is an ARTIFACT instead. The layer's first act, before it
## can be refused for any reason, is to write a file containing a nonce
## drawn from the running process. Nothing else in the graph writes it, no
## cached result can contain a fresh one, and a skipped layer leaves it
## absent. The three arms below are:
##
##   1. the ON edge writes it — so ``repro build`` executed the layer;
##   2. a second build of the ON edge writes a DIFFERENT nonce — so the
##      first was not a replay, and the ON edge is genuinely re-executed;
##   3. the ORDINARY edge, forced to re-run with the variable exported in
##      the caller's environment, leaves the file untouched — so the
##      action's declared setting beats the inherited one. That arm is the
##      one that would have been red before this change, and it is the
##      reason the declaration exists.
##
## Arms 1 and 2 do NOT require the layer to succeed, and must not: swtpm
## and tpm2-tools are not in this host's profile, so the layer normally
## fails after writing its evidence. The claim being made is "the engine
## executed this body", not "this host can run a TPM" — tying the two
## together would make the check unrunnable exactly where the defect lives.
##
## ## The other half of the contract: a whole-suite sweep must not schedule it
##
## Arms 1–3 make the ON edge runnable and honest when it is ASKED for. The
## reciprocal claim — that nobody who did not ask for it ever gets it — was
## for a while only a comment in the recipe. That is the weaker half and the
## easier one to break by accident: adding the ON edge to either suite
## collection is a one-line change that no arm above notices, and the symptom
## it produces is a whole-suite failure blamed on a missing system package.
##
## Arms 4–6 close it, and they are deliberately arranged so that none of them
## can pass vacuously:
##
##   4. the ON edge IS in its own target's closure, declaring the variable ON
##      and declaring itself non-cacheable — the positive control. Rename or
##      delete the edge and this arm goes red, so arms 5 and 6 cannot be
##      satisfied by the thing they look for having ceased to exist;
##   5. the compile-only collection's closure declares the variable at no
##      setting at all, while still containing the test's own compile edge —
##      so the closure being examined is the real, populated one;
##   6. the execute collection's closure contains exactly one action
##      declaring the variable, at the OFF setting, and none at the ON
##      setting.
##
## Each arm asserts the declared VALUE rather than the mere presence of the
## name, and each reads the graph the engine itself lowers rather than the
## recipe's text — a comment claiming the edge is excluded cannot satisfy it.
##
## ## Mocking
##
## None. Every arm drives the real ``./build/bin/repro`` against this
## repository's real graph, and reads a real file off disk.

import std/[json, os, osproc, strtabs, strutils, unittest]

import repro_test_support

const
  RepoMarker = "repro.nim"
  OrdinarySelector = ".#test#t_pcr_composite_matches_tpm"
  LiveTarget = "test-live-tpm-quote"
  LayerEnv = "REPROOS_TPM_QUOTE_GATE"
  EvidenceRel = "build/test-evidence/live-tpm-quote.txt"
  # The three closures arms 4–6 compare: the ON edge's own target, and the
  # two collections a whole-suite run materialises.
  LiveSelector = ".#" & LiveTarget
  SuiteCompileSelector = ".#test-builds"
  SuiteExecuteSelector = ".#test"
  TestBinaryRel = "build/test-bin/t_pcr_composite_matches_tpm"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runBuild(repoRoot, reproBin, selector: string;
              extraArgs: openArray[string] = [];
              layerRequested = false): tuple[output: string; exitCode: int] =
  ## Drive the real CLI. ``layerRequested`` exports the opt-in variable in
  ## the CALLER's environment, which is the channel arm 3 exists to close.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let runquotaBin = requireRunQuotaDaemonBin(repoRoot).parentDir
  env["PATH"] = runquotaBin & $PathSep & env.getOrDefault("PATH")
  if layerRequested: env[LayerEnv] = "1"
  elif env.hasKey(LayerEnv): env.del(LayerEnv)
  var args = @[reproBin.quoteShell, "build", selector,
    "--tool-provisioning=path", "--daemon=off", "--measure=none",
    "--progress=quiet"]
  for a in extraArgs: args.add(a)
  execCmdEx(args.join(" "), env = env, workingDir = repoRoot)

proc evidence(path: string): string =
  if fileExists(path): readFile(path).strip() else: ""

proc runGraph(repoRoot, reproBin, selector: string): JsonNode =
  ## Ask the engine for the ACTIONS it would schedule for ``selector``. This
  ## is the lowered graph, not the recipe's source, so a comment asserting an
  ## exclusion cannot answer it.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let runquotaBin = requireRunQuotaDaemonBin(repoRoot).parentDir
  env["PATH"] = runquotaBin & $PathSep & env.getOrDefault("PATH")
  if env.hasKey(LayerEnv): env.del(LayerEnv)
  let args = @[reproBin.quoteShell, "graph", selector,
    "--view=actions", "--format=json", "--tool-provisioning=path"]
  let res = execCmdEx(args.join(" "), env = env, workingDir = repoRoot)
  if res.exitCode != 0:
    raise newException(IOError,
      "repro graph " & selector & " exited " & $res.exitCode & ":\n" &
      res.output)
  # ``execCmdEx`` merges stderr into stdout, so skip whatever preamble a
  # diagnostic may have printed and parse from the document itself.
  let start = res.output.find('{')
  if start < 0:
    raise newException(IOError,
      "repro graph " & selector & " printed no JSON document:\n" & res.output)
  parseJson(res.output[start .. ^1])

type LayerDeclarations = object
  ## How the actions of one closure declare the opt-in variable.
  on: seq[string]   ## action ids declaring it ON
  off: seq[string]  ## action ids declaring it OFF
  nonCacheableOn: seq[string]

proc layerDeclarations(graph: JsonNode): LayerDeclarations =
  ## Read the DECLARED VALUE, not the presence of the name: an edge that
  ## merely mentions the variable is not an edge that switches the layer on.
  for action in graph{"actions"}:
    let id = action{"id"}.getStr()
    for entry in action{"env"}:
      let pair = entry.getStr()
      if pair == LayerEnv & "=1":
        result.on.add(id)
        if not action{"cacheable"}.getBool(true):
          result.nonCacheableOn.add(id)
      elif pair == LayerEnv & "=0":
        result.off.add(id)

proc producesTestBinary(graph: JsonNode; binaryPath: string): bool =
  for action in graph{"actions"}:
    for output in action{"outputs"}:
      if output.getStr() == binaryPath:
        return true

suite "an opt-in layer is something repro build can run, and its setting is in the key":

  test "t_optin_layer_runs_under_the_engine":
    let repoRoot = findRepoRoot()
    # Presence is not the property: ``build/`` is gitignored and shared
    # across platforms on some hosts, so a bare extension-less join can name
    # an artefact this kernel cannot load while ``fileExists`` still says
    # yes. This case EXECUTES the CLI, so it proves the machine format first.
    let reproBin = requireHostBinary(reproBinaryPath(repoRoot))
    let evidencePath = repoRoot / EvidenceRel
    removeFile(evidencePath)
    check not fileExists(evidencePath)

    # ARM 1 — the ON edge executes the layer.
    let first = runBuild(repoRoot, reproBin, LiveTarget)
    let firstEvidence = evidence(evidencePath)
    checkpoint("first build of " & LiveTarget & " exited " & $first.exitCode &
      " (a non-zero exit here is expected on a host without swtpm; the " &
      "claim is that the layer RAN, not that it succeeded)")
    check firstEvidence.len > 0
    check "live-layer-entered" in firstEvidence

    # ARM 2 — a second build genuinely re-executes it rather than replaying.
    let second = runBuild(repoRoot, reproBin, LiveTarget)
    let secondEvidence = evidence(evidencePath)
    checkpoint("second build exited " & $second.exitCode)
    check secondEvidence.len > 0
    check secondEvidence != firstEvidence

    # ARM 3 — THE ONE THAT WAS RED BEFORE THIS CHANGE. The ordinary edge is
    # forced to re-run, with the layer requested in the CALLER's
    # environment. Its declared setting must win: the evidence file must
    # still hold arm 2's nonce, because this edge never entered the layer.
    let ordinary = runBuild(repoRoot, reproBin, OrdinarySelector,
      extraArgs = ["--force-rebuild"], layerRequested = true)
    checkpoint("ordinary edge forced to re-run with " & LayerEnv &
      "=1 exported; exited " & $ordinary.exitCode)
    check ordinary.exitCode == 0
    check evidence(evidencePath) == secondEvidence

    # ARM 4 — POSITIVE CONTROL. The ON edge is in its own target's closure,
    # declares the layer ON, and declares itself non-cacheable. Arms 5 and 6
    # assert an ABSENCE, and an absence is satisfied for free once the thing
    # looked for no longer exists under the name looked for; this arm is what
    # stops a rename or a deletion from turning them green.
    let liveGraph = runGraph(repoRoot, reproBin, LiveSelector)
    let liveDecl = layerDeclarations(liveGraph)
    checkpoint(LiveSelector & " closure declares " & LayerEnv & "=1 on " &
      $liveDecl.on)
    check liveDecl.on.len == 1
    check liveDecl.nonCacheableOn == liveDecl.on
    check liveDecl.off.len == 0

    # ARM 5 — the compile-only collection. It holds the test's own compile
    # edge (so this is a real, populated closure and not an empty answer) and
    # declares the layer at NO setting: a compile edge has no opinion on it.
    let compileGraph = runGraph(repoRoot, reproBin, SuiteCompileSelector)
    let compileDecl = layerDeclarations(compileGraph)
    checkpoint(SuiteCompileSelector & " closure has " &
      $compileGraph{"actions"}.len & " actions; " & LayerEnv &
      " on=" & $compileDecl.on & " off=" & $compileDecl.off)
    check producesTestBinary(compileGraph, TestBinaryRel)
    check compileDecl.on.len == 0
    check compileDecl.off.len == 0

    # ARM 6 — the execute collection, which is what a whole-suite run runs.
    # Exactly one action declares the variable, and it declares it OFF. A
    # suite run therefore cannot schedule the ON edge, and cannot be failed
    # by a host that lacks the tools the ON edge needs.
    let executeGraph = runGraph(repoRoot, reproBin, SuiteExecuteSelector)
    let executeDecl = layerDeclarations(executeGraph)
    checkpoint(SuiteExecuteSelector & " closure has " &
      $executeGraph{"actions"}.len & " actions; " & LayerEnv &
      " on=" & $executeDecl.on & " off=" & $executeDecl.off)
    check executeDecl.off.len == 1
    check executeDecl.on.len == 0

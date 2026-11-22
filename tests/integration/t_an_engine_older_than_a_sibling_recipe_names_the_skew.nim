## A recipe compile that would include a sibling reprobuild recipe NEWER than
## the compile's DSL refuses before compiling it, naming the skew, both builds
## and the remedy; the pre-push gate's dependency-set stage then names the
## same remedy instead of `repro lock refresh`
## (Cross-Repo-Source-Consumption.md §9.2a; Unified-Locking-And-Hooks.md
## §13.5, "the dependency set is current").
##
## THE DEFECT. codetracer's recipe says `uses: "reprobuild"`, and the workspace's
## `reprobuild` checkout sits beside it, so the recipe compile includes
## reprobuild's own `repro.nim` (`usesImportCode`, §9.2). The managed pre-push
## hook ran reprobuild 0.2.27 while the checkout was 0.2.31, whose recipe
## calls `c(nim, source = …, binary = …, actionId = …)`, parameters the 0.2.27
## DSL does not have. The gate refused `committed_lock_dependency_set_unverified`
## with a Nim `type mismatch` deep inside the sibling's recipe as evidence and
## `repro lock refresh` as the remedy, which runs the same old engine and
## fails the same way.
##
## Fixture (built `./build/bin/repro`, black-box; real git, real recipes, real
## provider compiles):
##
##   <scratch>/ws/consumer     a git checkout with a bare origin; repro.nim
##                             says `uses: "newer-dsl"`; for the gate case it
##                             also commits a repro.lock pinning newer-dsl,
##                             refreshed while newer-dsl was a plain library
##   <scratch>/ws/newer-dsl    a reprobuild-SHAPED tree (the DSL marker
##                             module, `repro_core.nim` and `reprobuild.nimble`
##                             stating its version) whose recipe calls the DSL
##                             with a parameter no DSL has, the way a newer
##                             recipe calls an older DSL
##
## The sibling is not named `reprobuild`: a `../reprobuild` checkout is also
## where the engine looks for an SDK to compile against
## (`siblingReprobuildLibsRoot`), and this fixture's tree is not a working
## SDK. The rule identifies a reprobuild tree by its marker module, not by
## its name, so the name does not change what is tested. The scratch
## reproduction against the real `reprobuild` checkout is in the fix's report.
##
## Cases:
##
##   1. `t_a_newer_sibling_recipe_is_refused_before_it_is_compiled` — the
##      sibling states 999.0.0. `repro lock refresh` fails with the skew
##      message: both versions, the sibling's revision, the engine path and
##      revision, the sibling's path, the remedy (`direnv reload` /
##      `nix develop`, `nix build .#default`, `hooks ensure --vcs
##      --re-anchor`), and no `repro lock refresh` advice. No compile of the
##      sibling's recipe happened: no `type mismatch`, and no compiler location
##      inside the sibling's `repro.nim`.
##   2. `t_the_gate_names_the_skew_and_its_remedy` — the same fixture's
##      pre-push gate refuses `committed_lock_dependency_set_unverified` whose
##      evidence names the skew and whose remedy is the one above, not "make
##      the recipe readable — `repro lock refresh` …".
##   3. `t_a_sibling_that_is_not_newer_is_not_refused` (control) — the sibling
##      states 0.0.1. The check lets it through, so the compile reaches the
##      sibling's recipe and fails exactly the way an unguarded compile does:
##      the raw `type mismatch` at the call, and no skew message.
##
## Falsifiability: against reprobuild `98a3006d24` (unfixed; binary built from
## a clean worktree of that commit) cases 1 and 2 fail — `repro lock refresh`
## prints `newer-dsl/repro.nim(…) Error: type mismatch … unknown named
## parameter: parameterFromANewerDsl` and no skew, and the gate's remedy is
## "make the recipe readable — `repro lock refresh` …". Case 3 passes there,
## which is what makes it the control.
##
## NO MOCKS. Every repository is a real local git repository; every recipe is
## compiled by the real provider path `repro lock refresh` and the gate use.
## Nothing touches the network.
##
## Skip rule: `git` missing on PATH.

import std/[json, os, strutils, tempfiles, unittest]

import repro_core
import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/recipe_dependencies

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const
  SiblingName = "newer-dsl"
  UnknownParameter = "parameterFromANewerDsl"

type Fixture = object
  scratch, ws, consumer, sibling, siblingRevision, reproBin, gitBin: string

proc git(fx: Fixture; cwd: string; args: varargs[string]): string =
  var argv = @[fx.gitBin, "-c", "user.email=tester@example.invalid", "-c",
    "user.name=Skew Tester", "-c", "commit.gpgsign=false"]
  for a in args: argv.add(a)
  let res = runShell(shellCommand(argv), cwd = cwd)
  if res.code != 0:
    raise newException(OSError, argv.join(" ") & " (in " & cwd &
      ") exited " & $res.code & ":\n" & res.output)
  res.output.strip()

proc writeReprobuildShapedSibling(dir, version: string) =
  ## The files the rule reads, and a recipe written against a newer DSL: a
  ## library declaration (so the consumer can `uses:` it) followed by a call
  ## the compile's DSL has no parameter for.
  createDir(dir / "libs" / "repro_project_dsl" / "src")
  writeFile(dir / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim", "## The DSL marker module.\n")
  createDir(dir / "libs" / "repro_core" / "src")
  writeFile(dir / "libs" / "repro_core" / "src" / "repro_core.nim",
    "const ReprobuildVersion* {.strdefine.} = \"" & version & "\"\n")
  writeFile(dir / "reprobuild.nimble", "version       = \"" & version & "\"\n")
  writeFile(dir / "repro.nim", dependencyRecipe(SiblingName, [],
    library = true) & "\ndiscard aggregate(\"newer-dsl-probe\", " &
    "actions = @[], " & UnknownParameter & " = true)\n")

proc buildFixture(siblingVersion: string; committedLock = false): Fixture =
  ## With ``committedLock`` the consumer also commits a ``repro.lock``, as a
  ## repository that pins its siblings does: without one (and without
  ## workspace manifests) the gate has nothing to enforce. The lock is
  ## refreshed while the sibling is still a plain library recipe -- the
  ## state before the sibling moved to a newer reprobuild -- and the sibling
  ## then moves, exactly as a workspace checkout does when it is synced
  ## ahead of the `repro` that runs the hooks.
  result.gitBin = findExe("git")
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-engine-recipe-skew-", "")
  result.ws = result.scratch / "ws"
  result.consumer = result.ws / "consumer"
  result.sibling = result.ws / SiblingName
  createDir(result.ws)
  # The sibling: a git checkout with an origin, so the refusal can name its
  # revision and a lock can pin it.
  let siblingOrigin = result.scratch / ("origin-" & SiblingName & ".git")
  discard result.git(result.scratch, "init", "-q", "--bare", "-b", "main",
    siblingOrigin)
  discard result.git(result.scratch, "clone", "-q", fileUrl(siblingOrigin),
    result.sibling)
  discard result.git(result.sibling, "symbolic-ref", "HEAD",
    "refs/heads/main")
  if committedLock:
    writeDependencyRecipe(result.sibling, [], library = true)
    discard result.git(result.sibling, "add", "-A")
    discard result.git(result.sibling, "commit", "-q", "-m", "plain library")
    discard result.git(result.sibling, "push", "-q", "origin", "HEAD:main")
  # The consumer: a clone of a bare origin, its recipe committed and pushed.
  let origin = result.scratch / "origin-consumer.git"
  discard result.git(result.scratch, "init", "-q", "--bare", "-b", "main",
    origin)
  discard result.git(result.scratch, "clone", "-q", fileUrl(origin),
    result.consumer)
  discard result.git(result.consumer, "symbolic-ref", "HEAD",
    "refs/heads/main")
  writeDependencyRecipe(result.consumer, [SiblingName], library = false)
  if committedLock:
    let refresh = refreshCommittedLock(result.reproBin, result.consumer)
    if refresh.code != 0:
      raise newException(OSError, "repro lock refresh in " &
        result.consumer & " exited " & $refresh.code & ":\n" & refresh.output)
  discard result.git(result.consumer, "add", "-A")
  discard result.git(result.consumer, "commit", "-q", "-m", "seed consumer")
  discard result.git(result.consumer, "push", "-q", "origin", "HEAD:main")
  # The sibling becomes a reprobuild tree at `siblingVersion`.
  writeReprobuildShapedSibling(result.sibling, siblingVersion)
  discard result.git(result.sibling, "add", "-A")
  discard result.git(result.sibling, "commit", "-q", "-m",
    "reprobuild " & siblingVersion)
  discard result.git(result.sibling, "push", "-q", "origin", "HEAD:main")
  result.siblingRevision = result.git(result.sibling, "rev-parse", "HEAD")

proc runGate(fx: Fixture): tuple[code: int; report: JsonNode; output: string] =
  let head = fx.git(fx.consumer, "rev-parse", "HEAD")
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeFile(refsFile, "refs/heads/main " & head &
    " refs/heads/main 0000000000000000000000000000000000000000\n")
  let res = runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.consumer,
    "--current-repo=" & fx.consumer,
    "--pushed-refs=" & refsFile,
    "--json",
  ], @[("REPROBUILD_NO_RUNQUOTA", "1")]), cwd = fx.consumer)
  checkpoint("gate exited " & $res.code & ":\n" & res.output)
  let start = res.output.find('{')
  if start < 0:
    return (res.code, newJObject(), res.output)
  (res.code, parseJson(res.output[start .. ^1]), res.output)

proc failureOf(report: JsonNode; property: string): JsonNode =
  if report.hasKey("failures"):
    for f in report["failures"]:
      if f["property"].getStr() == property: return f
  newJNull()

proc siblingCompileLocation(fx: Fixture): string =
  ## How the compiler names a position inside the sibling's recipe.
  fx.sibling / "repro.nim("

template checkNamesTheSkew(fx: Fixture; text: string) =
  check "older than the sibling recipe it imports" in text
  check ReprobuildVersion in text
  check "999.0.0" in text
  check fx.siblingRevision in text
  check (fx.sibling / "repro.nim") in text
  check (repoRoot() / "build" / "bin") in text
  check "direnv reload" in text
  check "nix develop" in text
  check "nix build .#default" in text
  check ("hooks ensure --vcs --re-anchor " & fx.ws) in text

suite "an engine older than a sibling recipe names the skew":

  test "t_a_newer_sibling_recipe_is_refused_before_it_is_compiled":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture("999.0.0")
      defer: removeDir(fx.scratch)
      let refresh = refreshCommittedLock(fx.reproBin, fx.consumer)
      checkpoint("repro lock refresh exited " & $refresh.code & ":\n" &
        refresh.output)
      check refresh.code != 0
      checkNamesTheSkew(fx, refresh.output)
      check "lock refresh" notin refresh.output.split(
        "older than the sibling recipe")[^1].split("[engine-recipe-skew")[0]
      # Refused before the sibling's recipe was compiled.
      check "type mismatch" notin refresh.output
      check UnknownParameter notin refresh.output
      check fx.siblingCompileLocation notin refresh.output

  test "t_the_gate_names_the_skew_and_its_remedy":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture("999.0.0", committedLock = true)
      defer: removeDir(fx.scratch)
      let gate = fx.runGate()
      check gate.code == 2
      let f = gate.report.failureOf("committed_lock_dependency_set_unverified")
      check f.kind == JObject
      let evidence = if f.kind == JObject: f["evidence"].getStr() else: ""
      let remedy = if f.kind == JObject: f["remediation"].getStr() else: ""
      check "older than the sibling recipe the recipe imports" in evidence
      check ReprobuildVersion in evidence
      check "999.0.0" in evidence
      check fx.siblingRevision in evidence
      check (fx.sibling / "repro.nim") in evidence
      check (repoRoot() / "build" / "bin") in evidence
      check "direnv reload" in remedy
      check "nix build .#default" in remedy
      check ("hooks ensure --vcs --re-anchor " & fx.ws) in remedy
      check "repro lock refresh" notin remedy
      check "make the recipe readable" notin remedy
      check "type mismatch" notin gate.output

  test "t_a_sibling_that_is_not_newer_is_not_refused":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture("0.0.1")
      defer: removeDir(fx.scratch)
      let refresh = refreshCommittedLock(fx.reproBin, fx.consumer)
      checkpoint("repro lock refresh exited " & $refresh.code & ":\n" &
        refresh.output)
      check refresh.code != 0
      check "older than the sibling recipe" notin refresh.output
      # The check let the sibling through, so the compile reached its recipe.
      check "type mismatch" in refresh.output
      check UnknownParameter in refresh.output
      check fx.siblingCompileLocation in refresh.output

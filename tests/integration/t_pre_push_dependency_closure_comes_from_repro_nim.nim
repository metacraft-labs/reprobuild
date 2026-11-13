## The pre-push gate's dependency closure, and the lock it holds current, come
## only from `repro.nim` (owner decision 2026-11-05,
## Unified-Locking-And-Hooks.md §13.5 / §14.9):
##
## > "the list of dependencies should be tracked only in the repro.nim file of
## > the particular repo. There should not be a secondary mechanism that may
## > specify an alternative set of dependencies or additional dependencies.
## > The goal of the gate is to ensure that we have an up-to-date lock file
## > before pushing and the lock file includes only the transitive set of
## > dependencies derived from repro.nim files."
##
## THE DEFECT THIS REPLACES. Workspace fragments carried `depends` edges. The
## gate walked them for its scope, refused any edge to a repo outside the
## active project (`dependency-not-declared`), the lock writer folded the
## manifest closure into every committed `repro.lock`, and the mutual-pin
## deferral asked the manifest whether two repos formed a cycle. Two pushes
## were refused for a repo the recipe never used (`ngx-isonim`, not in the
## `codetracer` project), and a cycle the two locks recorded (`isonim` /
## `isonim-render-serve`) was invisible because neither fragment restated it.
##
## Fixture (built `./build/bin/repro`, black-box; real git, real recipes,
## real provider compiles):
##
##   <scratch>/workspace/                 a manifest workspace; project `app`
##     projects/app.toml, repos/*.toml    whose members are `app` and `lib-c`
##     app/    repro.nim: `uses: "lib-b"`
##     lib-b/  repro.nim (a library)      checked out beside app, NOT a member
##                                        of any project
##     lib-c/  repro.nim (a library)      a member nothing uses
##
## Cases, each a test of its own:
##
##   1. `t_a_dependency_outside_the_project_passes_when_the_lock_is_current` —
##      `repro lock refresh` pins lib-b; the gate passes (exit 0, no failures,
##      no `dependency-not-declared`). lib-b IS in the closure although no
##      project lists it: a dirty lib-b refuses (`dirty`, naming lib-b), and
##      the out-of-closure member lib-c, dirty, does not.
##   2. `t_the_same_push_is_refused_when_the_lock_is_stale` — app's recipe now
##      also uses lib-c, committed without a refresh: refused
##      `committed_lock_dependency_set_stale`, naming lib-c as missing. Then
##      the recipe uses neither, with the lock still pinning lib-b: refused,
##      naming lib-b as a pin no repro.nim declares. A refresh clears both.
##   3. `t_fragment_depends_changes_no_outcome` — app's fragment declares
##      `depends = ["lib-c", "no-such-repo"]` with lib-c dirty: the gate still
##      passes, prints the "ignored" notice and refuses nothing (the removed
##      `dependency-not-declared` and the removed manifest-widened scope);
##      `repro lock refresh` does not record lib-c (the removed §14.2 item 4),
##      and drops a lib-c pin a hand edit added, naming the reason.
##   4. `t_a_mutual_pin_recorded_only_in_the_locks_is_deferred` — app and
##      lib-b use each other; lib-b's lock pins app, app's lock pins an older,
##      published lib-b; both have newer unpublished HEADs. The `repro.lock`
##      stage defers the lib-b row (notice, no `committed_lock_sibling_pin_
##      stale`) although no fragment declares any edge and lib-b is in no
##      project. Control: with lib-b's recipe and lock NOT naming app, the
##      same row is refused; adding `depends = ["app"]` to a lib-b FRAGMENT
##      does not turn it back into a deferral. The deferral is not a pass: the
##      raw push is still refused `unpublished` over lib-b's HEAD (lib-b is in
##      app's lock-edge closure), as §13.5 decides for cycles.
##   5. `t_a_dependency_set_that_cannot_be_derived_is_refused_as_unverified` —
##      with lib-b's checkout gone, the derivation cannot read lib-b's recipe:
##      refused `committed_lock_dependency_set_unverified` and nothing else
##      (the refresh it names exits 5); with the checkout back, it passes.
##
## Falsifiability (reasoned, against the pre-change gate at reprobuild
## `01f362f1`): (1) passes there too but lib-b is outside the manifest
## closure, so the dirty-lib-b assertion fails (exit 0); (2) passes there
## (no set check), so both stale assertions fail; (3) fails on
## `dependency-not-declared` (exit 2) and on lib-c being recorded; (4) the
## manifest-edge cycle rule finds no cycle, so the deferral assertion fails.
##
## NO MOCKS. Every repository is a real local git repository with a real bare
## origin, every recipe is compiled by the real provider path `repro lock
## refresh` uses, and the manifest is read by the production resolver.
## Nothing touches the network.
##
## Skip rule: `git` missing on PATH.

import std/[json, os, strutils, tempfiles, unittest]

import repro_lock
import repro_test_support
import repro_test_support/[reasoned_skip, recipe_dependencies]

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "app"

[[remote]]
name = "app-origin"
fetch = "$1"

[[remote]]
name = "lib-c-origin"
fetch = "$2"

[[remote]]
name = "lib-b-origin"
fetch = "$3"

includes = [
  "repos/app.toml",
  "repos/lib-c.toml",$4
]
"""

const workspaceLocalToml = """
schema = "reprobuild.workspace.state.v1"

[workspace]
project = "app"
branch = "main"
"""

proc fragmentToml(name: string; depends: seq[string] = @[]): string =
  result = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, d in depends:
      if i > 0: result.add(", ")
      result.add("\"" & d & "\"")
    result.add("]\n")

proc appRecipe(uses: openArray[string]): string =
  dependencyRecipe("app", uses, library = false)

type Fixture = object
  scratch, ws, reproBin, gitBin: string

proc git(fx: Fixture; repo: string; args: varargs[string]): CmdResult =
  var argv = @[fx.gitBin, "-C", fx.ws / repo]
  for a in args: argv.add(a)
  runShell(shellCommand(argv))

proc requireGit(fx: Fixture; repo: string; args: varargs[string]): string =
  let res = fx.git(repo, args)
  if res.code != 0:
    checkpoint("git -C " & repo & " " & args.join(" ") & " failed:\n" &
      res.output)
    quit 1
  res.output.strip()

proc head(fx: Fixture; repo: string): string = fx.requireGit(repo, "rev-parse",
  "HEAD")

proc commitAll(fx: Fixture; repo, message: string) =
  discard fx.requireGit(repo, "add", "-A")
  discard fx.requireGit(repo, "commit", "-q", "-m", message)

proc publish(fx: Fixture; repo: string) =
  discard fx.requireGit(repo, "push", "-q", "origin", "HEAD:main")

proc seedRepo(fx: Fixture; name, recipe: string): string =
  ## A clone of a fresh bare origin, carrying ``recipe`` as its repro.nim,
  ## committed and published. Returns the origin's file URL.
  let origin = fx.scratch / ("origin-" & name & ".git")
  discard runShell(shellCommand(@[fx.gitBin, "init", "-q", "--bare", "-b",
    "main", origin]))
  discard runShell(shellCommand(@[fx.gitBin, "clone", "-q", fileUrl(origin),
    fx.ws / name]))
  discard fx.requireGit(name, "config", "user.email", "tester@example.invalid")
  discard fx.requireGit(name, "config", "user.name", "Gate Tester")
  discard fx.requireGit(name, "config", "commit.gpgsign", "false")
  # The clone of an empty origin is unborn on the host's default branch name;
  # every ref this file names is `main`.
  discard fx.requireGit(name, "symbolic-ref", "HEAD", "refs/heads/main")
  writeFile(fx.ws / name / "repro.nim", recipe)
  # Lock refresh and the gate's derivation compile the recipe under `.repro/`.
  writeFile(fx.ws / name / ".gitignore", ".repro/\n")
  fx.commitAll(name, "seed " & name)
  fx.publish(name)
  fileUrl(origin)

proc buildFixture(label: string; appUses: openArray[string] = ["lib-b"];
    libBUses: seq[string] = @[]; libBIsMember = false): Fixture =
  result.gitBin = findExe("git")
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-recipe-closure-" & label & "-", "")
  result.ws = result.scratch / "workspace"
  createDir(result.ws / "projects")
  createDir(result.ws / "repos")
  createDir(result.ws / ".repro")
  writeFile(result.ws / ".repro" / "workspace-state.toml", workspaceLocalToml)
  let appUrl = result.seedRepo("app", appRecipe(appUses))
  let libBUrl = result.seedRepo("lib-b", dependencyRecipe("lib-b", libBUses))
  let libCUrl = result.seedRepo("lib-c", dependencyRecipe("lib-c", []))
  # lib-b is checked out beside app either way; only `libBIsMember` makes the
  # project include it.
  writeFile(result.ws / "projects" / "app.toml", projectToml % [appUrl,
    libCUrl, libBUrl, (if libBIsMember: "\n  \"repos/lib-b.toml\"," else: "")])
  writeFile(result.ws / "repos" / "app.toml", fragmentToml("app"))
  writeFile(result.ws / "repos" / "lib-c.toml", fragmentToml("lib-c"))
  if libBIsMember:
    writeFile(result.ws / "repos" / "lib-b.toml", fragmentToml("lib-b"))

proc refreshLock(fx: Fixture; repo: string): CmdResult =
  result = refreshCommittedLock(fx.reproBin, fx.ws / repo)
  if result.code != 0:
    checkpoint("repro lock refresh in " & repo & " exited " & $result.code &
      ":\n" & result.output)

proc lockNames(fx: Fixture; repo: string): seq[string] =
  ## The non-root VCS names the committed lock of ``repo`` pins, in lock order.
  let path = fx.ws / repo / "repro.lock"
  if not fileExists(path): return
  for d in parseLockedDependencies(readFile(path)).deps:
    if not isSelfLockedDep(d) and d.coordinates.kind == ckVcs:
      result.add(d.name)

proc runGate(fx: Fixture; repo = "app"): tuple[code: int; report: JsonNode] =
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeFile(refsFile, "refs/heads/main " & fx.head(repo) &
    " refs/heads/main 0000000000000000000000000000000000000000\n")
  let res = runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.ws,
    "--current-repo=" & fx.ws / repo,
    "--pushed-refs=" & refsFile,
    "--json",
  ], [("REPROBUILD_NO_RUNQUOTA", "1")]))
  let start = res.output.find('{')
  if start < 0:
    checkpoint("gate printed no JSON:\n" & res.output)
    return (res.code, newJObject())
  checkpoint("gate exit " & $res.code & ":\n" & res.output)
  (res.code, parseJson(res.output[start .. ^1]))

proc properties(report: JsonNode): seq[string] =
  if report.hasKey("failures"):
    for f in report["failures"]: result.add(f["property"].getStr())

proc failureOf(report: JsonNode; property: string): JsonNode =
  if report.hasKey("failures"):
    for f in report["failures"]:
      if f["property"].getStr() == property: return f
  newJNull()

proc noticesText(report: JsonNode): string =
  if report.hasKey("notices"):
    for n in report["notices"]: result.add(n.getStr() & "\n")

proc dirty(fx: Fixture; repo: string) =
  writeFile(fx.ws / repo / "WIP.txt", "uncommitted\n")

proc clean(fx: Fixture; repo: string) =
  removeFile(fx.ws / repo / "WIP.txt")

suite "the pre-push closure and lock currency come from repro.nim":

  test "t_a_dependency_outside_the_project_passes_when_the_lock_is_current":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture("current")
      defer: removeDir(fx.scratch)
      require fx.refreshLock("app").code == 0
      # The recipe-derived set: lib-b, which no project declares.
      check fx.lockNames("app") == @["lib-b"]
      fx.commitAll("app", "pin lib-b")
      fx.publish("app")

      let green = fx.runGate()
      check green.code == 0
      check green.report.properties.len == 0
      check "dependency-not-declared" notin green.report.properties

      # lib-b is IN the closure although the project does not list it ...
      fx.dirty("lib-b")
      let dirtyDep = fx.runGate()
      check dirtyDep.code == 2
      let refusal = dirtyDep.report.failureOf("dirty")
      require refusal.kind == JObject
      check refusal["repo"].getStr().contains("lib-b")
      fx.clean("lib-b")

      # ... and lib-c, a member nothing uses, is outside it.
      fx.dirty("lib-c")
      let dirtyMember = fx.runGate()
      check dirtyMember.code == 0
      check dirtyMember.report.properties.len == 0

  test "t_the_same_push_is_refused_when_the_lock_is_stale":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture("stale")
      defer: removeDir(fx.scratch)
      require fx.refreshLock("app").code == 0
      fx.commitAll("app", "pin lib-b")
      fx.publish("app")
      check fx.runGate().code == 0

      # A dependency the recipe gained without a refresh is MISSING.
      writeFile(fx.ws / "app" / "repro.nim", appRecipe(["lib-b", "lib-c"]))
      fx.commitAll("app", "use lib-c, no refresh")
      fx.publish("app")
      let missing = fx.runGate()
      check missing.code == 2
      let m = missing.report.failureOf("committed_lock_dependency_set_stale")
      require m.kind == JObject
      check m["evidence"].getStr().contains("missing=lib-c ")
      check m["evidence"].getStr().contains("extra=]")
      check m["remediation"].getStr().contains("repro lock refresh")

      # A dependency the recipe dropped, still pinned, is EXTRA.
      writeFile(fx.ws / "app" / "repro.nim", appRecipe([]))
      fx.commitAll("app", "use nothing, no refresh")
      fx.publish("app")
      let extra = fx.runGate()
      check extra.code == 2
      let e = extra.report.failureOf("committed_lock_dependency_set_stale")
      require e.kind == JObject
      check e["evidence"].getStr().contains("missing= extra=lib-b]")

      # The remedy the refusal names clears it.
      require fx.refreshLock("app").code == 0
      check fx.lockNames("app").len == 0
      fx.commitAll("app", "refresh")
      fx.publish("app")
      let fixed = fx.runGate()
      check fixed.code == 0
      check fixed.report.properties.len == 0

  test "t_fragment_depends_changes_no_outcome":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture("fragment")
      defer: removeDir(fx.scratch)
      # Declared BEFORE the refresh: the writer must not fold it in.
      writeFile(fx.ws / "repos" / "app.toml",
        fragmentToml("app", @["lib-c", "no-such-repo"]))
      require fx.refreshLock("app").code == 0
      check fx.lockNames("app") == @["lib-b"]
      fx.commitAll("app", "pin lib-b")
      fx.publish("app")

      fx.dirty("lib-c")
      let gate = fx.runGate()
      # Neither edge refuses: not the undeclared name (the removed
      # `dependency-not-declared`), not the dirty member it names (the removed
      # manifest-widened scope), not the unpinned member (the removed
      # "declared in the develop set but not pinned" row).
      check gate.code == 0
      check gate.report.properties.len == 0
      check gate.report.noticesText.contains("ignored: dependencies come " &
        "only from repro.nim")
      fx.clean("lib-c")

      # A pin no recipe derives is dropped by the next refresh, and named.
      let lockPath = fx.ws / "app" / "repro.lock"
      let before = readFile(lockPath)
      let pinned = before.replace("depends = \"lib-b\"",
        "depends = \"lib-b,lib-c\"")
      check pinned != before
      let libCHead = fx.head("lib-c")
      let libCEntry = "{ name = \"lib-c\", coord_kind = \"vcs\", url = \"" &
        fileUrl(fx.scratch / "origin-lib-c.git") & "\", revision = \"" &
        libCHead & "\", integrity = \"git-sha1:" & libCHead & "\", version = " &
        "\"\", visibility = \"public\", participation = \"\", depends = \"\", " &
        "tags = \"\" }"
      writeFile(lockPath, pinned.replace("deps = [", "deps = [" & libCEntry &
        ", "))
      check "lib-c" in fx.lockNames("app")
      fx.commitAll("app", "hand-pin lib-c")
      fx.publish("app")
      let handPinned = fx.runGate()
      check handPinned.code == 2
      check "committed_lock_dependency_set_stale" in
        handPinned.report.properties
      let dropped = fx.refreshLock("app")
      require dropped.code == 0
      check dropped.output.contains("dropping sibling 'lib-c'")
      check dropped.output.contains("no repro.nim")
      check fx.lockNames("app") == @["lib-b"]

  test "t_a_mutual_pin_recorded_only_in_the_locks_is_deferred":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      proc scenario(label: string; libBUsesApp: bool;
          libBFragmentDepends = false): JsonNode =
        ## app and lib-b with newer unpublished HEADs, app's lock pinning an
        ## older PUBLISHED lib-b, and lib-b's lock pinning app or not. lib-b is
        ## in no project, except in the manifest-only control, where it is a
        ## member whose fragment declares an edge to app.
        let fx = buildFixture(label, ["lib-b"],
          if libBUsesApp: @["app"] else: newSeq[string](),
          libBIsMember = libBFragmentDepends)
        defer: removeDir(fx.scratch)
        if libBFragmentDepends:
          writeFile(fx.ws / "repos" / "lib-b.toml",
            fragmentToml("lib-b", @["app"]))
        require fx.refreshLock("lib-b").code == 0
        check ("app" in fx.lockNames("lib-b")) == libBUsesApp
        fx.commitAll("lib-b", "lock")
        fx.publish("lib-b")
        require fx.refreshLock("app").code == 0
        fx.commitAll("app", "pin lib-b")          # unpublished
        writeFile(fx.ws / "lib-b" / "NEXT.md", "next\n")
        fx.commitAll("lib-b", "newer, unpublished")
        fx.runGate().report

      let cycle = scenario("cycle", libBUsesApp = true)
      check "committed_lock_sibling_pin_stale" notin cycle.properties
      check cycle.noticesText.contains("repro.lock pin DEFERRED")
      check cycle.noticesText.contains("deferred=mutual-pin")
      # The deferral is not a pass: lib-b is IN app's lock-edge closure, so a
      # raw push of app is still refused over lib-b's unpublished HEAD (§13.5
      # amendment 2026-11-07). A cycle with new commits on both sides lands
      # through `repro push`, never through the deferral alone.
      # (app's own HEAD is reported unpublished too: this gate is run without
      # a real outgoing push. Every refusal is `unpublished`, and one names
      # lib-b.)
      check cycle.properties.len > 0
      var libBUnpublished = false
      for f in cycle["failures"]:
        check f["property"].getStr() == "unpublished"
        if f["repo"].getStr().contains("lib-b"): libBUnpublished = true
      check libBUnpublished

      let acyclic = scenario("acyclic", libBUsesApp = false)
      check "committed_lock_sibling_pin_stale" in acyclic.properties
      check not acyclic.noticesText.contains("repro.lock pin DEFERRED")

      let manifestOnly = scenario("manifest-only", libBUsesApp = false,
        libBFragmentDepends = true)
      check "committed_lock_sibling_pin_stale" in manifestOnly.properties
      check not manifestOnly.noticesText.contains("repro.lock pin DEFERRED")

  test "t_a_dependency_set_that_cannot_be_derived_is_refused_as_unverified":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      # app's recipe uses lib-b, and the committed lock pins it. With lib-b's
      # checkout gone, the derivation cannot read lib-b's recipe, so the
      # dependencies it would contribute are unknown: the gate must refuse
      # rather than report a set it did not compute as current. Nothing else
      # refuses here — an absent sibling is not dirty, unpublished or a stale
      # pin (its committed pin is what CI builds), so this property is the
      # gate's only defence against verifying a smaller set than the recipes
      # declare.
      let fx = buildFixture("unverified")
      defer: removeDir(fx.scratch)
      require fx.refreshLock("app").code == 0
      check fx.lockNames("app") == @["lib-b"]
      fx.commitAll("app", "pin lib-b")
      fx.publish("app")
      check fx.runGate().code == 0

      let away = fx.scratch / "lib-b-away"
      moveDir(fx.ws / "lib-b", away)
      let unverified = fx.runGate()
      check unverified.code == 2
      check unverified.report.properties ==
        @["committed_lock_dependency_set_unverified"]
      let u = unverified.report.failureOf(
        "committed_lock_dependency_set_unverified")
      require u.kind == JObject
      check u["evidence"].getStr().contains("lib-b")
      check u["remediation"].getStr().contains("repro lock refresh")
      # The refresh the remedy names reports the same condition (exit 5).
      let refresh = refreshCommittedLock(fx.reproBin, fx.ws / "app")
      check refresh.code == 5

      # Control: with the checkout back, the same push passes.
      moveDir(away, fx.ws / "lib-b")
      let restored = fx.runGate()
      check restored.code == 0
      check restored.report.properties.len == 0

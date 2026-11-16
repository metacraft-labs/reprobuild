## A workspace repository whose name equals a tool selector is not that tool's
## producer because a committed lock pins it by that name.
##
## Issue: reprobuild-pm/issues/2026-11-15-a-workspace-repo-named-like-a-tool-
## is-taken-as-that-tools-producer.md.
##
## THE DEFECT. The metacraft workspace declares a repo named ``nim`` kept at
## ``codetracer-nim``, and codetracer-trace-format declares the Nim *tool*
## with ``uses: "nim"``. Once trace-format's committed ``repro.lock`` pinned a
## sibling called ``nim`` (it got there through a fragment ``depends`` edge,
## before Unified-Locking-And-Hooks.md §14.9), every reader matched the
## ``uses:`` selector to that pin BY NAME:
##
##   * ``repro lock refresh`` counted ``nim`` as a develop-set sibling whatever
##     its path (``declaredDevelopSet``'s ``lockRecorded``), found its recipe
##     where ``uses:`` discovery cannot look, and refused for good (exit 5,
##     "could not reach it"): no checkout can clear that refusal. Where it did
##     not refuse, it carried the pin forward by name
##     (``usesProducerLockedDep``), so the stale pin never left the lock and
##     the pre-push set check, which derives through the same writer, called
##     the lock current.
##   * ``repro build`` took the pin as a lock-pinned cross-repo producer
##     (``resolveProducerBinding``) and tried to splice the repository onto
##     the tool's channels ("cross-repo producer \"nim\" … declares no
##     materialized executable, library, or Nim source output").
##
## The fixture recreates that shape with the selector ``mkdir``: a workspace
## repo ``mkdir`` and a consumer whose recipe declares the tool
## ``uses: "mkdir >=1"``. The lock pin is produced by the real writer, not
## hand-edited: the repo is first checked out at ``<workspace>/mkdir``, where
## discovery reaches it, so a refresh pins it; it is then kept at
## ``<workspace>/mkdir-fork`` (the ``codetracer-nim`` shape) with the pin
## committed.
##
## Asserts:
##   1. Setup: with the repo at ``mkdir/`` the refresh pins ``mkdir``.
##  2a. Repo at ``mkdir-fork/``, pin committed and published: the pre-push
##      gate refuses the lock as ``committed_lock_dependency_set_stale`` with
##      ``mkdir`` extra (unfixed: ``…_unverified``, because the derivation
##      itself refused over ``mkdir``).
##   2. Repo at ``mkdir-fork/``, pin committed: ``repro lock refresh`` exits 0
##      (unfixed: exit 5, "could not reach it"), the new lock pins no ``mkdir``
##      (unfixed, when it did not refuse: the pin carried forward by name), and
##      the refresh names the dropped pin.
##   3. Same state, ``repro build``: does not treat ``mkdir`` as a cross-repo
##      producer (unfixed: "cross-repo producer \"mkdir\" … declares no
##      materialized …", exit 1).
##   4. Control: the repo checked out again where discovery reaches it
##      (``mkdir/``), the same committed pin: the refresh keeps the pin and the
##      build still routes ``mkdir`` through the producer seam. Without it, a
##      "fix" that ignored every lock pin named like a selector would pass
##      (2) and (3).
##
## Test-double policy: NO mocks, doubles, or fakes — real git repositories,
## the real built ``repro`` binary, real provider compiles and real solves.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, repro unbuilt, or no
## ``reprobuild-packages`` checkout to resolve the plain ``mkdir`` tool use
## against.

import std/[os, osproc, strutils, unittest]
import repro_lock
import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const consumerRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"
  uses:
    "sh"
    "mkdir >=1"
  build:
    let made = shell(
      command = "mkdir -p build && printf 'made\\n' > build/made.txt",
      actionId = "consumer.build.made",
      extraOutputs = @["build/made.txt"])
    appendRegisteredActionToolIdentityRefs(made.id, ["mkdir"])
    defaultTarget(target("made", [made]))
"""
  ## The consumer RUNS the tool, as codetracer-trace-format's actions run
  ## ``nim``: the selector is in the build's selected closure, so a lock pin
  ## mistaken for its producer is admitted, built and spliced.

const namesakeRecipe = """
import repro_project_dsl

package mkdir_fork:
  defaultToolProvisioning "path"
  build:
    discard aggregate("mkdir-fork-aggregate", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initRepoWith(gitBin, dir, recipe, origin: string) =
  ## A git repo at ``dir`` whose single commit carries ``recipe``, pushed to a
  ## bare ``origin`` (a lockable VCS dependency needs a fetch URL).
  createDir(dir)
  check git(gitBin, "", "init -q -b main " & q(dir)).code == 0
  check git(gitBin, "", "init -q --bare -b main " & q(origin)).code == 0
  check git(gitBin, dir, "remote add origin " & q(fileUrl(origin))).code == 0
  check git(gitBin, dir, "config user.email t@example.invalid").code == 0
  check git(gitBin, dir, "config user.name Tester").code == 0
  writeFile(dir / "repro.nim", recipe)
  check git(gitBin, dir, "add -A").code == 0
  check git(gitBin, dir, "commit -q -m init").code == 0
  check git(gitBin, dir, "push -q -u origin main").code == 0

proc fragment(name, path: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & path & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"

proc packagesRoot(): string =
  let fromEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
  if fromEnv.len > 0 and dirExists(fromEnv): return fromEnv
  let sibling = ReprobuildRepoRoot.parentDir() / "reprobuild-packages"
  if dirExists(sibling): return sibling
  ""

proc pinsSibling(lockPath, name: string): bool =
  ## Whether the lock at ``lockPath`` pins a sibling REPOSITORY called
  ## ``name`` — a non-root VCS ``deps`` entry. A text search would also match
  ## the solved tool PACKAGE of the same name in ``packages``, which every
  ## lock of a recipe using ``mkdir`` carries.
  for d in parseLockedDependencies(readFile(lockPath)).deps:
    if d.name == name and not isSelfLockedDep(d) and
        d.coordinates.kind == ckVcs:
      return true

suite "a lock pin named like a tool is not that tool's producer":

  test "t_a_lock_pin_named_like_a_tool_is_not_its_producer":
    let gitBin = findExe("git")
    let catalog = packagesRoot()
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real sibling repositories")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    elif catalog.len == 0:
      skip("no reprobuild-packages checkout (set REPROBUILD_PACKAGES_ROOT); " &
        "the refresh resolves the plain `mkdir` tool use against it")
    else:
      let hadCatalogEnv = existsEnv("REPROBUILD_PACKAGES_ROOT")
      let oldCatalogEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
      putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
      defer:
        if hadCatalogEnv: putEnv("REPROBUILD_PACKAGES_ROOT", oldCatalogEnv)
        else: delEnv("REPROBUILD_PACKAGES_ROOT")
      let scratch = getTempDir() / ("lock-pin-named-like-a-tool-" &
        $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      createDir(workspace)
      let consumer = workspace / "consumer"
      let reachable = workspace / "mkdir"
      let kept = workspace / "mkdir-fork"
      initRepoWith(gitBin, consumer, consumerRecipe,
        scratch / "origin-consumer.git")
      initRepoWith(gitBin, reachable, namesakeRecipe,
        scratch / "origin-mkdir.git")
      createDir(workspace / "projects")
      createDir(workspace / "repos")
      var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\n\n"
      for name in ["consumer", "mkdir"]:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(scratch / ("origin-" & name & ".git")) & "\"\n\n")
      project.add("includes = [\n  \"repos/consumer.toml\",\n" &
        "  \"repos/mkdir.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      writeFile(workspace / "repos" / "consumer.toml",
        fragment("consumer", "consumer"))
      writeFile(workspace / "repos" / "mkdir.toml", fragment("mkdir", "mkdir"))
      writeWorkspaceBranch(workspace, project = "app", branch = "main")
      let lockPath = consumer / "repro.lock"

      # ---- (1) setup: reachable namesake, the writer pins it. ---------------
      let pinned = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("reachable refresh exit=" & $pinned.code)
      checkpoint(pinned.output)
      require pinned.code == 0
      let pinnedLock = readFile(lockPath)
      require pinsSibling(lockPath, "mkdir")
      check git(gitBin, consumer, "add repro.lock").code == 0
      check git(gitBin, consumer, "commit -q -m lock").code == 0

      # The repository is now kept where `uses: "mkdir"` cannot mean it.
      moveDir(reachable, kept)
      writeFile(workspace / "repos" / "mkdir.toml",
        fragment("mkdir", "mkdir-fork"))

      # ---- (2a) the pre-push set check calls the committed pin stale. ------
      # It derives through the refresh's writer, so it is the same rule seen
      # from the gate: a pin no recipe derives is `extra`. Unfixed, the
      # derivation refused over `mkdir` and the gate could only say
      # `committed_lock_dependency_set_unverified`.
      check git(gitBin, consumer, "push -q origin HEAD:main").code == 0
      let headSha = git(gitBin, consumer, "rev-parse HEAD").output.strip()
      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & headSha &
        " refs/heads/main 0000000000000000000000000000000000000000\n")
      let gate = run("REPROBUILD_NO_RUNQUOTA=1 " & q(reproBinary) &
        " check --mode=pre-push --workspace-root=" & q(workspace) &
        " --current-repo=" & q(consumer) & " --pushed-refs=" & q(refsFile) &
        " --json")
      checkpoint("gate exit=" & $gate.code)
      checkpoint(gate.output)
      check gate.code == 2
      check "committed_lock_dependency_set_stale" in gate.output
      check "committed_lock_dependency_set_unverified" notin gate.output
      check "extra=mkdir" in gate.output
      check readFile(lockPath) == pinnedLock

      # ---- (2) refresh: the pin is not the tool's, it is dropped. -----------
      let refresh = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("namesake kept at mkdir-fork: refresh exit=" & $refresh.code)
      checkpoint(refresh.output)
      check refresh.code == 0
      check "could not reach" notin refresh.output
      check "develop-set sibling 'mkdir'" notin refresh.output
      check not pinsSibling(lockPath, "mkdir")
      check "dropping sibling 'mkdir'" in refresh.output

      # ---- (3) build with the committed pin: no producer splice. ------------
      writeFile(lockPath, pinnedLock)
      # Hermetic action cache: a fresh one under this case's scratch, so the
      # shared developer cache neither feeds nor records this build.
      let buildCmd = q(reproBinary) & " build --tool-provisioning=path" &
        " --daemon=off --progress=quiet --measure=none --action-cache-root=" &
        q(scratch / "action-cache")
      let build = run(buildCmd, cwd = consumer)
      checkpoint("namesake kept at mkdir-fork: build exit=" & $build.code)
      checkpoint(build.output)
      check build.code == 0
      check "cross-repo producer \"mkdir\"" notin build.output
      # The action ran the host `mkdir`, which is what `uses: "mkdir"` means.
      check fileExists(consumer / "build" / "made.txt")

      # ---- (4) control: reachable again, the pin is a producer. -------------
      moveDir(kept, reachable)
      writeFile(workspace / "repos" / "mkdir.toml", fragment("mkdir", "mkdir"))
      let keep = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("reachable again: refresh exit=" & $keep.code)
      checkpoint(keep.output)
      check keep.code == 0
      check pinsSibling(lockPath, "mkdir")
      removeDir(consumer / "build")
      let producerBuild = run(buildCmd, cwd = consumer)
      checkpoint("reachable again: build exit=" & $producerBuild.code)
      checkpoint(producerBuild.output)
      check "cross-repo producer \"mkdir\"" in producerBuild.output

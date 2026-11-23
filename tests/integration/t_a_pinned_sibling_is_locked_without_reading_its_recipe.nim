## A recipe can pin a sibling it only CLONES, without folding that sibling's
## recipe into its own compile or its lock.
##
## The locking rules this exercises are in Unified-Locking-And-Hooks.md
## (§14.2 item 4 and §14.9, "pinned:").
##
## THE DEFECT. A CI job that clones a sibling beside the checkout (the
## ``setup-dev-env`` / ``clone-siblings`` actions clone at the revision the
## committed ``repro.lock`` pins, and refuse one it does not pin) could only
## get the sibling pinned by declaring ``uses: "<sibling>"``. That made the
## sibling a build dependency: its whole ``repro.nim`` was imported into the
## consumer's interface compile and folded into lock generation
## (``foldProviderSolverInputs``), and the lock recorded the sibling's whole
## dependency closure (54 entries for a recorder whose own edges read two
## siblings).
##
## THE DECLARATION. ``pinned:`` in the ``package`` body lists repository names.
## Each becomes an ordinary ``deps`` entry (commit + VCS-native integrity) and
## a direct dependency of the root, and nothing more: the sibling's recipe is
## not compiled, its own dependencies are not in the lock.
##
## HOW "NOT COMPILED" IS OBSERVED, not assumed. Two siblings whose recipes
## make a compile visible:
##
##   * ``poison``: a recipe that cannot compile (``static: doAssert false``).
##     Any compile of it, by the consumer's interface compile or by the lock
##     fold, fails the command.
##   * ``wide``: a valid recipe that ``uses: "deep"`` and, when compiled,
##     writes ``<marker>`` at compile time (``static: writeFile``). The marker
##     proves a compile; ``deep`` in the lock proves a fold.
##
## Each is run both ways. The ``uses:`` run is the CONTROL: it shows the
## fixture really would be compiled and folded (the defect), so the
## ``pinned:`` run's silence means the recipe was not read and not merely that
## the fixture could not observe it. On the unfixed engine ``pinned:`` is not
## a declaration at all, so every ``pinned:`` case fails at its first
## assertion (the recipe does not compile).
##
## Asserts:
##   1. ``uses: "poison"`` refuses the refresh (control); ``pinned: "poison"``
##      writes a lock whose ``poison`` entry carries the sibling's HEAD and
##      ``git-sha1:<HEAD>`` integrity, listed in the root's ``depends``.
##   2. ``uses: "wide"`` compiles it (marker) and records ``deep`` (control);
##      ``pinned: "wide"`` leaves no marker and records exactly ``wide``.
##   3. A sibling that is pinned by the consumer and ``uses:`` by another
##      sibling's recipe is recorded once; the root and the sibling both
##      depend on it.
##   4. A pinned name no checkout and no committed pin can place is refused
##      by name and writes no lock; a pinned sibling that is not checked out
##      keeps the pin the committed lock carries.
##   5. The pre-push gate derives the same set: a lock carrying the pin is not
##      stale; the same lock after the recipe drops the pin is
##      ``committed_lock_dependency_set_stale`` with the pin ``extra``.
##
## Test-double policy: NO mocks, doubles, or fakes. Real git repositories with
## real bare origins, the real built ``repro``, real recipe compiles.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[algorithm, os, osproc, strutils, unittest]
import repro_lock
import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const poisonRecipe = """
import repro_project_dsl

static:
  doAssert false, "THE PINNED SIBLING'S RECIPE WAS COMPILED"

package poison:
  library poison
  defaultToolProvisioning "path"
"""

proc wideRecipe(marker: string): string =
  ## A valid recipe that records its own compilation at ``marker`` and uses
  ## the sibling ``deep``.
  "import repro_project_dsl\n\n" &
  "static:\n  writeFile(" & escape(marker) & ", \"compiled\")\n\n" &
  "package wide:\n  library wide\n  defaultToolProvisioning \"path\"\n" &
  "  uses:\n    \"deep\"\n"

const deepRecipe = """
import repro_project_dsl

package deep:
  library deep
  defaultToolProvisioning "path"
"""

proc midRecipe(): string =
  ## A sibling that uses ``deep``: the route by which a sibling's recipe
  ## reaches a name the consumer also pins.
  "import repro_project_dsl\n\n" &
  "package mid:\n  library mid\n  defaultToolProvisioning \"path\"\n" &
  "  uses:\n    \"deep\"\n"

proc consumerRecipe(usesBlock = ""; pinnedBlock = ""): string =
  ## A minimal recipe (no ``build:`` block), as a repository that is only
  ## tested against its siblings carries.
  result = "import repro_project_dsl\n\npackage consumer:\n" &
    "  defaultToolProvisioning \"path\"\n"
  if usesBlock.len > 0:
    result.add("  uses:\n")
    for name in usesBlock.split(','):
      result.add("    \"" & name & "\"\n")
  if pinnedBlock.len > 0:
    result.add("  pinned:\n")
    for name in pinnedBlock.split(','):
      result.add("    \"" & name & "\"\n")

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
  require git(gitBin, "", "init -q -b main " & q(dir)).code == 0
  require git(gitBin, "", "init -q --bare -b main " & q(origin)).code == 0
  require git(gitBin, dir, "remote add origin " & q(fileUrl(origin))).code == 0
  require git(gitBin, dir, "config user.email t@example.invalid").code == 0
  require git(gitBin, dir, "config user.name Tester").code == 0
  writeFile(dir / "repro.nim", recipe)
  # A refresh compiles under `.repro/`; ignored so the checkout stays clean.
  writeFile(dir / ".gitignore", ".repro/\n")
  require git(gitBin, dir, "add -A").code == 0
  require git(gitBin, dir, "commit -q -m init").code == 0
  require git(gitBin, dir, "push -q -u origin main").code == 0

proc headOf(gitBin, repo: string): string =
  git(gitBin, repo, "rev-parse HEAD").output.strip()

proc refresh(consumer: string): tuple[code: int; output: string] =
  let res = run(q(reproBinary) & " lock refresh " & q(consumer))
  checkpoint("refresh exit=" & $res.code)
  checkpoint(res.output)
  res

proc lockedDeps(consumer: string): LockedDependencies =
  parseLockedDependencies(readFile(consumer / "repro.lock"))

proc siblingNames(consumer: string): seq[string] =
  ## The non-root VCS entries of the consumer's lock, sorted.
  for d in lockedDeps(consumer).deps:
    if not isSelfLockedDep(d) and d.coordinates.kind == ckVcs:
      result.add(d.name)
  result.sort()

proc rootDepends(consumer: string): seq[string] =
  for d in lockedDeps(consumer).deps:
    if isSelfLockedDep(d):
      result = d.depends
      result.sort()
      return

proc entry(consumer, name: string): LockedDep =
  for d in lockedDeps(consumer).deps:
    if d.name == name and not isSelfLockedDep(d):
      return d
  doAssert false, "the lock has no entry named " & name

proc commitRecipe(gitBin, repo, recipe: string) =
  writeFile(repo / "repro.nim", recipe)
  require git(gitBin, repo, "add -A").code == 0
  require git(gitBin, repo, "commit -q -m recipe").code == 0

template withScratch(label: string; body: untyped) =
  let gitBin {.inject.} = findExe("git")
  if gitBin.len == 0:
    skip("git not on PATH; the case builds real repositories")
  elif not fileExists(reproBinary):
    skip("build/bin/repro is not built; the case runs the real engine")
  else:
    let scratch {.inject.} = getTempDir() / (label & "-" &
      $getCurrentProcessId())
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)
    body

suite "a pinned sibling is locked without reading its recipe":

  test "a sibling whose recipe cannot compile is pinned, not compiled":
    withScratch("pinned-poison"):
      initRepoWith(gitBin, scratch / "poison", poisonRecipe,
        scratch / "origin-poison.git")
      let consumer = scratch / "consumer"
      initRepoWith(gitBin, consumer, consumerRecipe(usesBlock = "poison"),
        scratch / "origin-consumer.git")

      # Control: through `uses:` the sibling's recipe IS compiled, and the
      # refresh dies on it. Without this the case below proves nothing.
      let folded = refresh(consumer)
      check folded.code != 0
      check "poison" in folded.output.toLowerAscii()
      check not fileExists(consumer / "repro.lock")

      commitRecipe(gitBin, consumer, consumerRecipe(pinnedBlock = "poison"))
      let pinned = refresh(consumer)
      require pinned.code == 0
      check siblingNames(consumer) == @["poison"]
      let poison = entry(consumer, "poison")
      let sha = headOf(gitBin, scratch / "poison")
      check poison.coordinates.revision == sha
      check poison.integrity == "git-sha1:" & sha
      check rootDepends(consumer) == @["poison"]
      check "THE PINNED SIBLING'S RECIPE WAS COMPILED" notin pinned.output

  test "a pinned sibling's own dependencies stay out of the lock":
    withScratch("pinned-wide"):
      let marker = scratch / "wide-was-compiled"
      initRepoWith(gitBin, scratch / "deep", deepRecipe,
        scratch / "origin-deep.git")
      initRepoWith(gitBin, scratch / "wide", wideRecipe(marker),
        scratch / "origin-wide.git")
      let consumer = scratch / "consumer"
      initRepoWith(gitBin, consumer, consumerRecipe(usesBlock = "wide"),
        scratch / "origin-consumer.git")

      # Control: `uses:` compiles `wide` (the marker) and records `deep`.
      require refresh(consumer).code == 0
      check fileExists(marker)
      check siblingNames(consumer) == @["deep", "wide"]
      removeFile(marker)
      removeFile(consumer / "repro.lock")

      commitRecipe(gitBin, consumer, consumerRecipe(pinnedBlock = "wide"))
      require refresh(consumer).code == 0
      check not fileExists(marker)
      check siblingNames(consumer) == @["wide"]
      check rootDepends(consumer) == @["wide"]
      check entry(consumer, "wide").depends.len == 0
      check entry(consumer, "wide").integrity ==
        "git-sha1:" & headOf(gitBin, scratch / "wide")

  test "a name pinned and also used by another sibling is recorded once":
    withScratch("pinned-and-used"):
      initRepoWith(gitBin, scratch / "deep", deepRecipe,
        scratch / "origin-deep.git")
      initRepoWith(gitBin, scratch / "mid", midRecipe(),
        scratch / "origin-mid.git")
      let consumer = scratch / "consumer"
      initRepoWith(gitBin, consumer,
        consumerRecipe(usesBlock = "mid", pinnedBlock = "deep"),
        scratch / "origin-consumer.git")
      require refresh(consumer).code == 0
      check siblingNames(consumer) == @["deep", "mid"]
      # `deep` is the consumer's own statement as well as `mid`'s.
      check rootDepends(consumer) == @["deep", "mid"]
      check entry(consumer, "mid").depends == @["deep"]
      check entry(consumer, "deep").depends.len == 0

  test "a name no checkout and no committed pin can place is refused":
    withScratch("pinned-ghost"):
      let consumer = scratch / "consumer"
      initRepoWith(gitBin, consumer, consumerRecipe(pinnedBlock = "ghost"),
        scratch / "origin-consumer.git")
      let res = refresh(consumer)
      check res.code != 0
      check "ghost" in res.output
      check "pinned:" in res.output
      check not fileExists(consumer / "repro.lock")

  test "a pinned sibling that is not checked out keeps its committed pin":
    withScratch("pinned-carried"):
      initRepoWith(gitBin, scratch / "poison", poisonRecipe,
        scratch / "origin-poison.git")
      let consumer = scratch / "consumer"
      initRepoWith(gitBin, consumer, consumerRecipe(pinnedBlock = "poison"),
        scratch / "origin-consumer.git")
      require refresh(consumer).code == 0
      let before = readFile(consumer / "repro.lock")
      moveDir(scratch / "poison", scratch / "poison-away")
      let again = refresh(consumer)
      require again.code == 0
      check siblingNames(consumer) == @["poison"]
      check entry(consumer, "poison").coordinates.revision ==
        headOf(gitBin, scratch / "poison-away")
      check readFile(consumer / "repro.lock") == before

  test "the pre-push gate derives the pinned set as the refresh does":
    withScratch("pinned-gate"):
      let workspace = scratch / "workspace"
      createDir(workspace)
      let consumer = workspace / "consumer"
      initRepoWith(gitBin, workspace / "poison", poisonRecipe,
        scratch / "origin-poison.git")
      initRepoWith(gitBin, consumer, consumerRecipe(pinnedBlock = "poison"),
        scratch / "origin-consumer.git")
      createDir(workspace / "projects")
      createDir(workspace / "repos")
      var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\n\n"
      for name in ["consumer", "poison"]:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(scratch / ("origin-" & name & ".git")) & "\"\n\n")
        writeFile(workspace / "repos" / (name & ".toml"),
          "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" &
          name & "\"\npath = \"" & name & "\"\nremote = \"" & name &
          "-origin\"\nmainline = \"main\"\n")
      project.add("includes = [\n  \"repos/consumer.toml\",\n" &
        "  \"repos/poison.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      writeWorkspaceBranch(workspace, project = "app", branch = "main")

      proc gate(): tuple[code: int; output: string] =
        let headSha = headOf(gitBin, consumer)
        let refsFile = scratch / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & headSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")
        let res = run("REPROBUILD_NO_RUNQUOTA=1 " & q(reproBinary) &
          " check --mode=pre-push --workspace-root=" & q(workspace) &
          " --current-repo=" & q(consumer) & " --pushed-refs=" & q(refsFile) &
          " --json")
        checkpoint("gate exit=" & $res.code)
        checkpoint(res.output)
        res

      require refresh(consumer).code == 0
      require git(gitBin, consumer, "add repro.lock").code == 0
      require git(gitBin, consumer, "commit -q -m lock").code == 0
      require git(gitBin, consumer, "push -q origin HEAD:main").code == 0
      let current = gate()
      check "committed_lock_dependency_set_stale" notin current.output
      check "committed_lock_dependency_set_unverified" notin current.output

      # The recipe stops pinning `poison`; the committed lock still does.
      commitRecipe(gitBin, consumer, consumerRecipe())
      require git(gitBin, consumer, "push -q origin HEAD:main").code == 0
      let stale = gate()
      check stale.code == 2
      check "committed_lock_dependency_set_stale" in stale.output
      check "extra=poison" in stale.output

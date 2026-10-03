## A committed `repro.lock` refreshed from a linked worktree records the same
## dependencies, at the same paths, as one refreshed at the repository root.
##
## WHY THIS EXISTS. `repro lock refresh` computed each dep's `path` as the
## sibling's location relative to the INVOKING tree. Run in
## `reprobuild/.claude/worktrees/agent-<id>` — four levels below the repo root,
## which is where agent sessions work by default — it wrote
##
##     path = "../../../../nim-shm-queue"
##
## and reported nothing unusual. `repro.lock` is COMMITTED, so that string has
## to mean the same thing to every reader, and it does not:
##
##     from the worktree    ../../../../nim-shm-queue -> <workspace>/nim-shm-queue
##     from the repo root   ../../../../nim-shm-queue -> /home/nim-shm-queue
##
## Committed and pushed, such a lock sends every clone — including CI — four
## levels above the workspace. The verifier cannot catch it either: the lock is
## self-consistent for the tree that wrote it. `Unified-Locking-And-Hooks.md`
## §14.2 states the frame of reference as "the checkout relative to the repo,
## e.g. `../codetracer-trace-format`".
##
## The second case covers the SAME cause in the membership dimension, found
## while fixing the first: the manifest-declared develop set is matched to the
## repository BY PATH (`<workspace>/<declared path>` against the invoking
## directory), so from a worktree no declared repo matched, the develop set
## resolved as "nothing declared", and the refresh wrote a lock carrying NO
## siblings at all. That is worse than a wrong path, and equally silent.
##
## ASSERTS, case 1 (`uses:` producer siblings — the reported symptom):
##   1. Refreshed at the repository root, the lock records `../producer`. The
##      baseline the worktree refresh has to reproduce.
##   2. The fixture is deep enough for the two computations to differ, and the
##      deep form is exactly the one that was observed: `producer` relative to
##      the worktree IS `../../../../producer`. Without this the next
##      assertion could pass on a one-level fixture and prove nothing.
##   3. Refreshed FROM the worktree, the lock records `../producer`, and the
##      worktree-relative form appears nowhere in it.
##   4. The producer's whole `deps` ENTRY is byte-identical between the two
##      refreshes, so the committed record of the sibling does not depend on
##      which tree wrote it. Stronger than checking only the one path that was
##      observed to break.
##   5. The root entry's `ref` is the branch checked out in the tree that
##      refreshed — `feature` from the worktree. DELIBERATE, and not the same
##      kind of defect: §14.2 makes each entry "an observation of the
##      checkout", with `ref` the checked-out ref and `revision` the pin ("a
##      branch name is never recorded as a pin"). Recording the branch one is
##      on is conformant, and is not worktree-specific either — a refresh on a
##      feature branch in the main checkout records that branch too. Pinned
##      here so the decision is visible rather than implicit.
##
## ASSERTS, case 2 (manifest develop-set siblings):
##   6. Refreshed at the root, the lock records the manifest-declared sibling
##      at `../lib-b`, pinned at its HEAD.
##   7. Refreshed from a worktree, it records the SAME entry — present, at the
##      same path, at the same revision — rather than dropping it.
##
## FALSIFIABILITY (observed against the engine built from `origin/agents`
## 11831068): case 1 (3) fails with `path = "../../../../producer"` in the
## worktree-written lock and no `../producer` entry, and (4) fails with the
## entry text differing in that field. Case 2 (7) fails with the lock carrying
## one dep — the root — and no `lib-b` at all. (1), (2), (5) and (6) pass
## before and after, which is what makes them controls.
##
## NO MOCKS. Every repository is a real local git repository; the worktrees are
## created by `git worktree add`; the manifest in case 2 is a real on-disk
## manifest the production resolver reads; the locks are written by the real
## `repro`. Nothing touches $HOME or the network.
##
## Skip rule: `git` missing from PATH, or `repro` not built.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import repro_workspace_manifests

const ReprobuildRepoRoot =
  currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const producerRecipe = """
import repro_project_dsl

package producer:
  library producer
  build:
    discard aggregate("producer-aggregate", actions = @[])
"""

const consumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "producer"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc configureIdentity(gitBin, work: string) =
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"Lock Tester\"")

proc initRepo(gitBin, dir: string) =
  discard requireGit(q(gitBin) & " init -q -b main " & q(dir))
  configureIdentity(gitBin, dir)

proc headOf(gitBin, work: string): string =
  requireGit(q(gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc depEntryFor(lockBody, path: string): string =
  ## The inline-table text of the ``deps`` entry whose ``path`` is ``path``,
  ## or "" when there is none.
  let key = "path = \"" & path & "\""
  let at = lockBody.find(key)
  if at < 0: return ""
  let open = lockBody.rfind('{', 0, at)
  let close = lockBody.find('}', at)
  if open < 0 or close < 0: return ""
  lockBody[open .. close]

proc addDeepWorktree(gitBin, repo, branch: string): string =
  ## A real linked worktree three directories below ``repo`` — the same depth,
  ## and the same relative form, as the session layout that produced the
  ## defect.
  result = repo / ".claude" / "worktrees" / "agent-fixture"
  createDir(repo / ".claude" / "worktrees")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " worktree add -b " &
    branch & " " & q(result))
  configureIdentity(gitBin, result)

suite "a committed lock does not depend on which worktree refreshed it":

  test "t_uses_sibling_paths_do_not_depend_on_the_invoking_worktree":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    else:
      let scratch = createTempDir("repro-lock-worktree-uses-", "")
      defer: removeDir(scratch)

      # The sibling producer, one level up from the consumer.
      let producer = scratch / "producer"
      createDir(producer)
      initRepo(gitBin, producer)
      writeFile(producer / "repro.nim", producerRecipe)
      discard requireGit(q(gitBin) & " -C " & q(producer) & " add repro.nim")
      discard requireGit(q(gitBin) & " -C " & q(producer) &
        " commit -q -m producer")
      let producerHead = headOf(gitBin, producer)

      # The consumer. Its ONLY edge to the sibling is `uses: "producer"`.
      let consumer = scratch / "consumer"
      createDir(consumer)
      initRepo(gitBin, consumer)
      discard requireGit(q(gitBin) & " -C " & q(consumer) &
        " remote add origin https://example.invalid/acme/consumer.git")
      writeFile(consumer / ".gitignore", ".repro/\n.claude/\n")
      writeFile(consumer / "repro.nim", consumerRecipe)
      discard requireGit(q(gitBin) & " -C " & q(consumer) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(consumer) &
        " commit -q -m consumer")
      check not fileExists(consumer / ".repro" / "develop-overrides.toml")

      # ---- (1) the baseline, refreshed at the repository root. ----
      let atRoot = runCmd(reproBinary & " lock refresh " & q(consumer))
      checkpoint(atRoot.output)
      check atRoot.code == 0
      let rootBody = readFile(consumer / "repro.lock")
      let rootEntry = depEntryFor(rootBody, "../producer")
      check rootEntry.len > 0
      check ("revision = \"" & producerHead & "\"") in rootEntry
      removeFile(consumer / "repro.lock")

      let worktree = addDeepWorktree(gitBin, consumer, "feature")
      check fileExists(worktree / "repro.nim")

      # ---- (2) the fixture distinguishes the two computations. ----
      let deepForm = relativePath(producer, worktree).replace('\\', '/')
      checkpoint("producer relative to the worktree: " & deepForm)
      check deepForm == "../../../../producer"

      # ---- (3) refreshed FROM the worktree. ----
      let inWorktree = runCmd(reproBinary & " lock refresh " & q(worktree))
      checkpoint(inWorktree.output)
      check inWorktree.code == 0
      let wtBody = readFile(worktree / "repro.lock")
      checkpoint(wtBody)
      let wtEntry = depEntryFor(wtBody, "../producer")
      check wtEntry.len > 0
      let carriesTheDeepForm = deepForm in wtBody
      check not carriesTheDeepForm

      # ---- (4) the sibling's committed record is writer-independent. ----
      check wtEntry == rootEntry

      # ---- (5) the root entry's ref names a PUBLISHED branch. ----
      # `feature` is the worktree's local branch and the consumer's remote has
      # never been fetched, so no published branch contains the commit: the
      # lock records no ref rather than a name no other checkout can resolve
      # (Unified-Locking-And-Hooks.md §14.2).
      let wtRootEntry = depEntryFor(wtBody, ".")
      check wtRootEntry.len > 0
      check "ref = \"\"" in wtRootEntry
      check "feature" notin wtRootEntry

  test "t_manifest_develop_set_survives_a_worktree_refresh":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    else:
      let scratch = createTempDir("repro-lock-worktree-manifest-", "")
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      createDir(workspace)

      proc seedPublished(name: string): string =
        let origin = scratch / ("origin-" & name & ".git")
        let work = workspace / name
        discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
        discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
          q(work))
        configureIdentity(gitBin, work)
        writeFile(work / "README.md", name & " fixture\n")
        if name == "app":
          writeFile(work / "repro.solver", solverInputs)
          writeFile(work / ".gitignore", ".repro/\n.claude/\n")
        discard requireGit(q(gitBin) & " -C " & q(work) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
        discard requireGit(q(gitBin) & " -C " & q(work) &
          " push origin main")
        origin

      proc fragment(name: string; depends: seq[string]): string =
        result = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
          "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
          "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"
        if depends.len > 0:
          result.add("depends = [")
          for i, d in depends:
            if i > 0: result.add(", ")
            result.add("\"" & d & "\"")
          result.add("]\n")

      var origins: seq[(string, string)] = @[]
      for name in ["app", "lib-b"]:
        origins.add((name, seedPublished(name)))

      createDir(workspace / "projects")
      createDir(workspace / "repos")
      var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n"
      for (name, origin) in origins:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(origin) & "\"\n\n")
      project.add("includes = [\n  \"repos/app.toml\",\n" &
        "  \"repos/lib-b.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      writeFile(workspace / "repos" / "app.toml", fragment("app", @["lib-b"]))
      writeFile(workspace / "repos" / "lib-b.toml", fragment("lib-b", @[]))
      writeWorkspaceBranch(workspace, project = "app", branch = "main")

      let app = workspace / "app"
      let libBHead = headOf(gitBin, workspace / "lib-b")

      # ---- (6) the baseline: the declared sibling is recorded. ----
      let atRoot = runCmd(q(reproBinary) & " lock refresh " & q(app))
      checkpoint(atRoot.output)
      check atRoot.code == 0
      let rootBody = readFile(app / "repro.lock")
      let rootEntry = depEntryFor(rootBody, "../lib-b")
      check rootEntry.len > 0
      check ("revision = \"" & libBHead & "\"") in rootEntry
      removeFile(app / "repro.lock")

      # ---- (7) and it is still recorded when the refresh runs in a
      # worktree, rather than the develop set resolving as "nothing
      # declared" because no manifest repo path matched the worktree.
      let worktree = addDeepWorktree(gitBin, app, "feature")
      let inWorktree = runCmd(q(reproBinary) & " lock refresh " & q(worktree))
      checkpoint(inWorktree.output)
      check inWorktree.code == 0
      let wtBody = readFile(worktree / "repro.lock")
      checkpoint(wtBody)
      let wtEntry = depEntryFor(wtBody, "../lib-b")
      check wtEntry.len > 0
      check ("revision = \"" & libBHead & "\"") in wtEntry
      let carriesTheDeepForm = "../../../../lib-b" in wtBody
      check not carriesTheDeepForm

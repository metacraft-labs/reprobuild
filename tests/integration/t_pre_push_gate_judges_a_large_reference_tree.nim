## The pre-push gate's ``unpublished`` stage on a large reference tree.
##
## ``repro check --mode=pre-push`` requires a published HEAD in every repo of
## the pushed repo's develop-set closure, and it asks the same "is HEAD on a
## remote-tracking branch" predicate that hung `repro health` on the
## llvm-project reference tree for seven minutes on a 154-repository
## workspace (observed 2026-11-22). The predicate is now computed as one history walk instead of
## one walk per remote-tracking ref; a FALSE PASS is the dangerous direction
## for this gate, so this test holds its verdicts on exactly the shape that
## made the old form expensive: a dependency with 4,000 remote-tracking
## branches, no commit-graph, and a HEAD on an old base.
##
##   * HEAD on no remote branch → the gate refuses, property ``unpublished``,
##     naming the dependency (and only it);
##   * the same commit pushed → the gate passes;
##   * the same commit as a DETACHED HEAD → still published, still passes.
##
## The cost itself is measured in
## ``t_publication_probe_is_one_walk_on_a_large_reference_tree.nim``; each
## gate run's duration is recorded here as a checkpoint.
##
## No mocks: real repositories, the real git and the production binary.
## Skip rule: ``git`` missing on PATH.

import std/[json, monotimes, os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_test_support/[large_reference_tree, recipe_dependencies]
import repro_test_support/reasoned_skip
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc git(gitBin, args: string; cwd = ""): string =
  let res = execCmdEx(q(gitBin) & " " & args, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(OSError, "git " & args & " (in " & cwd & ") exited " &
      $res.exitCode & ":\n" & res.output)
  res.output.strip()

const largeTree = LargeReferenceTree(commits: 100_000, branches: 4_000,
  mainRef: "refs/heads/main", branchPrefix: "refs/heads/")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"

[[remote]]
name = "lib-a-origin"
fetch = "LIBA"

[[remote]]
name = "refs-tree-origin"
fetch = "REFS"

includes = [
  "repos/lib-a.toml",
  "repos/refs-tree.toml",
]
"""

proc fragment(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"" & name &
    "-origin\"\nmainline = \"main\"\n"

suite "pre-push gate on a large reference tree":

  test "refuses an unpublished HEAD there, passes it once pushed, and detached":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; the fixture is git repositories")
    else:
      let scratch = createTempDir("repro-gate-large-", "")
      defer: removeDir(scratch)
      let reproBin = requireBinary(currentSourcePath().parentDir.parentDir.
        parentDir / "build" / "bin" / addFileExt("repro", ExeExt),
        "reprobuild.apps.repro")
      let ws = scratch / "workspace"
      createDir(ws / "projects")
      createDir(ws / "repos")

      # Origins: a one-commit lib-a, and the large tree.
      let libAOrigin = scratch / "lib-a.git"
      let refsOrigin = scratch / "refs-tree.git"
      discard git(gitBin, "init -q --bare -b main " & q(libAOrigin))
      let seed = scratch / "seed"
      discard git(gitBin, "init -q -b main " & q(seed))
      writeFile(seed / "README.md", "lib-a\n")
      discard git(gitBin, "add README.md", seed)
      discard git(gitBin, "-c user.email=t@example.invalid -c user.name=T " &
        "commit -q -m seed", seed)
      discard git(gitBin, "push -q " & q(libAOrigin) & " main", seed)
      discard git(gitBin, "init -q --bare -b main " & q(refsOrigin))
      buildLargeReferenceTree(gitBin, refsOrigin, largeTree)

      writeFile(ws / "projects" / "lib-a.toml", projectToml.
        replace("LIBA", fileUrl(libAOrigin)).
        replace("REFS", fileUrl(refsOrigin)))
      for name in ["lib-a", "refs-tree"]:
        writeFile(ws / "repos" / (name & ".toml"), fragment(name))
        let origin = if name == "lib-a": libAOrigin else: refsOrigin
        discard git(gitBin, "clone -q " & q(fileUrl(origin)) & " " &
          q(ws / name))
        discard git(gitBin, "config user.email tester@example.invalid",
          ws / name)
        discard git(gitBin, "config user.name Tester", ws / name)
      let refsTree = ws / "refs-tree"
      discard git(gitBin, "config core.commitGraph false", refsTree)
      check git(gitBin, "for-each-ref refs/remotes", refsTree).
        splitLines().len > largeTree.branches

      # lib-a uses refs-tree; both recipes committed and published.
      discard declareDependenciesInRecipes(gitBin, reproBin, ws,
        [("refs-tree", newSeq[string]()), ("lib-a", @["refs-tree"])])
      writeWorkspaceBranch(ws, project = "lib-a", branch = "main")

      # refs-tree moves to a commit on an OLD base that no remote branch
      # holds: the recipe files of `main`, committed on top of a commit near
      # the root of the 100,000-commit history.
      discard git(gitBin, "checkout -q -b pinned main~99900", refsTree)
      discard git(gitBin, "checkout -q main -- .", refsTree)
      discard git(gitBin, "commit -q -m pinned-on-an-old-base", refsTree)
      let pinned = git(gitBin, "rev-parse HEAD", refsTree)
      check git(gitBin, "branch -r --contains HEAD", refsTree) == ""

      # lib-a's lock pins it, and lib-a itself is published. The new pin is
      # "behind" the old one (it is on another branch of the sibling, off an
      # old base), which the refresh refuses unless told the downgrade is
      # deliberate — it is: that old base is the shape under test.
      let libA = ws / "lib-a"
      let refresh = runShell(shellCommand(@[reproBin, "lock", "refresh"],
        [("REPROBUILD_NO_RUNQUOTA", "1"),
         ("REPRO_ALLOW_PIN_REGRESSION", "refs-tree")]), cwd = libA)
      checkpoint(refresh.output)
      require refresh.code == 0
      check ("revision = \"" & pinned & "\"") in readFile(libA / "repro.lock")
      discard git(gitBin, "commit -qam repin", libA)
      discard git(gitBin, "push -q origin main", libA)
      let libAHead = git(gitBin, "rev-parse HEAD", libA)
      let refsFile = scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/main " & libAHead &
        " refs/heads/main 0000000000000000000000000000000000000000\n")

      proc gate(label: string): JsonNode =
        let started = getMonoTime()
        let res = runShell(shellCommand(@[reproBin, "check",
          "--mode=pre-push", "--write-report", "--workspace-root=" & ws,
          "--current-repo=" & libA, "--pushed-refs=" & refsFile, "--json"]))
        checkpoint(label & ": exit " & $res.code & " after " &
          $(getMonoTime() - started).inMilliseconds & " ms\n" & res.output)
        result = parseFile(ws / ".repro" / "build" / "reports" /
          "check-report.json")
        check result["exitCode"].getInt() == res.code

      # Unpublished: refused, naming refs-tree and nothing else.
      var report = gate("unpublished")
      check report["exitCode"].getInt() == 2
      check report["failures"].len == 1
      if report["failures"].len == 1:
        let failure = report["failures"][0]
        check failure["property"].getStr() == "unpublished"
        check failure["repo"].getStr() == "refs-tree"
        check "git push" in failure["remediation"].getStr()

      # Published: the same commit, now on refs-tree-origin's `pinned`.
      discard git(gitBin, "push -q origin pinned", refsTree)
      check git(gitBin, "branch -r --contains HEAD", refsTree) ==
        "origin/pinned"
      report = gate("published")
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0

      # Detached on that commit: still published.
      discard git(gitBin, "checkout -q --detach " & pinned, refsTree)
      report = gate("detached")
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0

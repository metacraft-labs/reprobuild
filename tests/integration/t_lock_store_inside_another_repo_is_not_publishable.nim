## A lock store path that merely lives INSIDE another repo's checkout is not a
## publishable store, and the pre-push gate must not treat it as one.
##
## The default git-checkout lock store is `<workspace>/.repro/manifests`. In a
## workspace whose membership lives at the root (the native layout), that path
## sits inside the workspace repo's OWN checkout, and `.repro/` is normally
## gitignored there. `git rev-parse` inside it answers for the ENCLOSING repo,
## so a publishability check that only asks "is this a git worktree?" says yes
## for what is really just a local-state directory. The publish then stages
## `locks/` in the enclosing repo, `git add` refuses an ignored path, and the
## gate reports `lock-publish-failure` — which refuses EVERY push from EVERY
## repo in that workspace, over a lock store the workspace never had.
##
## A store DB is its own checkout by construction (that is what gives it a
## remote to publish to), so the check requires the path to be the worktree
## ROOT and a nested path takes the pre-existing benign not-publishable skip.
##
## Fixture (hermetic, local git only): a native-layout workspace repo — root
## `projects/` + `repos/`, `.gitignore` carrying `.repro/`, `.repro/workspace.toml`
## recording the project — with one participating repo cloned from a local bare
## origin, which is what gives the gate a lock to write.
##
## Asserted: `repro check --mode=pre-push` reports the store as SKIPPED rather
## than failed, exits 0, stages nothing into the enclosing repo, and still
## writes its lock to disk.
##
## Falsifiability: confirmed against the packaged pre-fix binary
## (reprobuild 92dc648d) on this exact fixture — it reports
## `lock-publish-failure` with git's "paths are ignored by one of your
## .gitignore files" text, which is the state that blocked every push in the
## metacraft workspace.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "a nested lock store is not publishable":

  test "t_lock_store_inside_another_repo_is_not_publishable":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-nested-store-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- a participating repo with a local bare origin ----------------
      let origin = scratch / "origin-lib.git"
      let seed = scratch / "seed-lib"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.name \"Store Tester\"")
      writeFile(seed / "README.md", "nested store fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
        q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

      # ---- the workspace repo whose `.repro/manifests` is the store ------
      # Membership lives in `.repro/manifests/` (declared as the workspace's
      # manifest layer) and `.repro/` is gitignored by the enclosing workspace
      # repo — exactly the shape that makes the store a nested, non-publishable
      # directory rather than its own checkout.
      #
      # Since Unified-Locking-And-Hooks.md §10 ("No implicit team route") the
      # gate no longer synthesizes `<workspace>/.repro/manifests` from the bare
      # path, so the layer has to be DECLARED — which is also the only way an
      # operator can now reach this scenario.
      let workspaceRoot = scratch / "workspace"
      let manifestsRoot = workspaceRoot / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "repos" / "lib.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
        "revision = \"main\"\n")
      writeFile(manifestsRoot / "projects" / "demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"demo\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & fileUrl(scratch) &
        "\"\n\nincludes = [\n  \"repos/lib.toml\",\n]\n")
      writeFile(workspaceRoot / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\n\n" &
        "[[manifest]]\nlocal_path = \".repro/manifests\"\n" &
        "visibility = \"team\"\n")
      # `.repro/` is local state in this layout — exactly the ignore rule that
      # makes the nested store unpublishable.
      writeFile(workspaceRoot / ".gitignore", ".repro/\n")
      writeFile(workspaceRoot / "README.md", "nested store workspace\n")

      discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " config user.name \"Store Tester\"")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " commit -m workspace")

      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(workspaceRoot / "lib"))

      let res = runShell(shellCommand(@[reproBin, "check", "--mode=pre-push",
        "--workspace-root=" & workspaceRoot,
        "--current-repo=" & workspaceRoot]))
      if res.code != 0:
        checkpoint("check output: " & res.output)

      # The nested store is a benign skip, not a failure that refuses a push.
      check res.code == 0
      check res.output.contains("lock publish skipped")
      # The store is a plain directory nested inside the workspace checkout —
      # the diagnostic has to name that, not merely "no repository here".
      check res.output.contains("is a plain directory inside the Git worktree")
      check not res.output.contains("lock-publish-failure")
      check not res.output.contains("git add locks failed")

      # Nothing was staged into the enclosing repo...
      let staged = execCmdEx(q(gitBin) & " -C " & q(workspaceRoot) &
        " diff --cached --name-only").output.strip()
      check staged.len == 0

      # ...and the gate still recorded its lock on disk (the skip is about
      # PUBLISHING it, not about writing it).
      var lockCount = 0
      for path in walkDirRec(manifestsRoot):
        if path.endsWith(".toml"): inc lockCount
      check lockCount > 0

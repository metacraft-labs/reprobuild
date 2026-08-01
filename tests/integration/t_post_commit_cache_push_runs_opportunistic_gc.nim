## Regression — the post-commit cache-ref push runs the OPPORTUNISTIC shared-bare
## maintenance pass the spec mandates.
##
## `Workspace-And-Develop-Mode.md` §"Cache maintenance: gc / repack" requires the
## shared bare cache maintenance (git gc/repack + pruning of dead
## `refs/cache/<workspace>/*`) to run **opportunistically (never blocking a
## clone/commit)**, not only via the manual `shared-clones gc` verb. The
## post-commit cache-ref push (`runCachePushCommand`) is the detached process
## that accumulates loose objects, so it is where the budget-gated pass fires.
##
## Scenario: a workspace with one repo wired to its shared bare; a DEAD
## workspace's cache ref (`refs/cache/deadws/main`) pre-seeded into the bare;
## the maintenance stamp removed so the pass is due. After
## `repro hooks cache-push`, the dead ref MUST be pruned and the maintenance
## stamp MUST exist — both only happen if the opportunistic pass actually ran.
##
## Falsifiability: against a build without the opportunistic wiring, the
## cache-push pushes the ref but never maintains, so `refs/cache/deadws/main`
## survives and no `reprobuild-last-gc` stamp is written. (`rewire` populates
## the bare but does NOT prune — only `maintainSharedBare` does — so the pruned
## dead ref is unambiguous proof the pass ran from the cache-push path.)
##
## Hermetic local upstream; skip when git / the binary is missing.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "regression — post-commit cache-push runs opportunistic maintenance":

  test "t_post_commit_cache_push_runs_opportunistic_gc":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-oppgc-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # Upstream bare (name ends in .git → the remote fetch is the full repo URL).
      let origin = scratch / "r.git"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      let seed = scratch / "seed"
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email t@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " config user.name T")
      writeFile(seed / "a.txt", "1\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add a.txt")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m base")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

      let ws = scratch / "ws"
      let manifestsRoot = ws
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "p.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"p\"\ndefault_revision = \"main\"\n\n" &
        "[[remote]]\nname = \"o\"\nfetch = \"file://" & origin & "\"\n\n" &
        "includes = [\n  \"repos/r.toml\",\n]\n")
      writeFile(manifestsRoot / "repos" / "r.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"r\"\npath = \"r\"\nremote = \"o\"\n" &
        "revision = \"main\"\n")
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n[workspace]\n" &
        "project = \"p\"\n")
      discard requireGit(q(gitBin) & " clone " & q("file://" & origin) & " " &
        q(ws / "r"))
      discard requireGit(q(gitBin) & " -C " & q(ws / "r") &
        " config user.email t@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(ws / "r") & " config user.name T")

      let cacheDir = scratch / "cache"
      putEnv("REPRO_WORKSPACE_CLONES", cacheDir)
      defer: delEnv("REPRO_WORKSPACE_CLONES")

      # Create + wire the shared bare (the fixed rewire), then locate it.
      let rewire = runCmd(q(reproBin) & " workspace shared-clones rewire" &
        " --workspace-root=" & q(ws) & " --json")
      if rewire.code != 0:
        checkpoint("rewire output: " & rewire.output)
      check rewire.code == 0
      var bare = ""
      for entry in parseJson(rewire.output)["repos"]:
        if entry["path"].getStr() == "r":
          bare = entry["sharedBarePath"].getStr()
      check bare.len > 0
      check dirExists(bare / "objects")

      # Pre-seed a DEAD workspace's cache ref, and remove the maintenance stamp
      # so the opportunistic pass is due when the cache-push fires.
      let headSha = requireGit(q(gitBin) & " -C " & q(ws / "r") &
        " rev-parse HEAD").strip()
      discard requireGit(q(gitBin) & " -C " & q(bare) &
        " update-ref refs/cache/deadws/main " & headSha)
      removeFile(bare / "reprobuild-last-gc")
      check runCmd(q(gitBin) & " -C " & q(bare) &
        " show-ref refs/cache/deadws/main").code == 0   # present before

      # A fresh commit gives the cache-push something to propagate.
      writeFile(ws / "r" / "b.txt", "2\n")
      discard requireGit(q(gitBin) & " -C " & q(ws / "r") & " add b.txt")
      discard requireGit(q(gitBin) & " -C " & q(ws / "r") & " commit -m more")

      let push = runCmd(q(reproBin) & " hooks cache-push" &
        " --repo-root=" & q(ws / "r") & " --workspace-name=ws")
      if push.code != 0:
        checkpoint("cache-push output: " & push.output)
      check push.code == 0

      # Opportunistic maintenance ran: the dead ref is pruned and the stamp
      # was written — neither happens without the post-commit gc wiring.
      check runCmd(q(gitBin) & " -C " & q(bare) &
        " show-ref refs/cache/deadws/main").code != 0
      check fileExists(bare / "reprobuild-last-gc")

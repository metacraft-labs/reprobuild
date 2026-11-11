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
## Cases:
##
##   - `t_post_commit_cache_push_runs_opportunistic_gc` -- a workspace with one
##     repo wired to its shared bare; a DEAD workspace's cache ref
##     (`refs/cache/deadws/main`) pre-seeded into the bare; the maintenance
##     stamp removed so the pass is due. After `repro hooks cache-push`, the
##     dead ref MUST be pruned and the maintenance stamp MUST exist — both only
##     happen if the opportunistic pass actually ran. Against a build without
##     the opportunistic wiring, the cache-push pushes the ref but never
##     maintains, so `refs/cache/deadws/main` survives and no
##     `reprobuild-last-gc` stamp is written. (`rewire` populates the bare but
##     does NOT prune — only `maintainSharedBare` does — so the pruned dead ref
##     is unambiguous proof the pass ran from the cache-push path.)
##   - `t_post_commit_cache_push_maintains_other_due_bares` -- a second bare in
##     the cache is borrowed only by checkouts that never commit, so no
##     cache-push ever targets it, and it has never been maintained. The
##     commit's pass reaches it too: it is stamped, and its `refs/cache/*`,
##     whose owners this workspace cannot know, are kept.
##   - `t_post_commit_cache_push_keeps_refs_of_an_unreadable_sibling` -- a
##     sibling directory records its state only under the retired file name.
##     The pass still runs: that sibling's cache refs are kept as live, and a
##     dead workspace's are pruned.
##
## Hermetic local upstream; skip when git / the binary is missing.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

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

type Fixture = object
  origin, ws, bare: string

proc wiredWorkspace(gitBin, reproBin, scratch: string): Fixture =
  ## A workspace `scratch/ws` with one repo, `r`, wired to its shared bare in
  ## the cache `REPRO_WORKSPACE_CLONES` names (the caller sets it).
  # Upstream bare (name ends in .git → the remote fetch is the full repo URL).
  result.origin = scratch / "r.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(result.origin))
  let seed = scratch / "seed"
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.email t@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " config user.name T")
  writeFile(seed / "a.txt", "1\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add a.txt")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m base")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " remote add origin " & q(result.origin))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

  let ws = scratch / "ws"
  result.ws = ws
  createDir(ws / "projects")
  createDir(ws / "repos")
  writeFile(ws / "projects" / "p.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"p\"\n\n" &
    "[[remote]]\nname = \"o\"\nfetch = \"file://" & result.origin & "\"\n\n" &
    "includes = [\n  \"repos/r.toml\",\n]\n")
  writeFile(ws / "repos" / "r.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"r\"\npath = \"r\"\nremote = \"o\"\n" &
    "mainline = \"main\"\n")
  createDir(ws / ".repro")
  writeFile(ws / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
    "project = \"p\"\n")
  discard requireGit(q(gitBin) & " clone " & q("file://" & result.origin) &
    " " & q(ws / "r"))
  discard requireGit(q(gitBin) & " -C " & q(ws / "r") &
    " config user.email t@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(ws / "r") & " config user.name T")

  # Create + wire the shared bare (the fixed rewire), then locate it.
  let rewire = runCmd(q(reproBin) & " workspace shared-clones rewire" &
    " --workspace-root=" & q(ws) & " --json")
  if rewire.code != 0:
    checkpoint("rewire output: " & rewire.output)
  doAssert rewire.code == 0, "rewire failed"
  for entry in parseJson(rewire.output)["repos"]:
    if entry["path"].getStr() == "r":
      result.bare = entry["sharedBarePath"].getStr()
  doAssert result.bare.len > 0 and dirExists(result.bare / "objects"),
    "rewire did not create the shared bare"

proc headOf(gitBin, repo: string): string =
  requireGit(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc hasRef(gitBin, repo, refName: string): bool =
  runCmd(q(gitBin) & " -C " & q(repo) & " show-ref --verify --quiet " &
    q(refName)).code == 0

proc commitAndCachePush(gitBin, reproBin: string; f: Fixture): int =
  ## A fresh commit in `r`, then the post-commit process, run in the
  ## foreground: `repro hooks cache-push`.
  writeFile(f.ws / "r" / "b.txt", "2\n")
  discard requireGit(q(gitBin) & " -C " & q(f.ws / "r") & " add b.txt")
  discard requireGit(q(gitBin) & " -C " & q(f.ws / "r") & " commit -m more")
  let push = runCmd(q(reproBin) & " hooks cache-push" &
    " --repo-root=" & q(f.ws / "r") & " --workspace-name=ws")
  if push.code != 0:
    checkpoint("cache-push output: " & push.output)
  push.code

suite "regression — post-commit cache-push runs opportunistic maintenance":

  test "t_post_commit_cache_push_runs_opportunistic_gc":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs a repository")
    else:
      let scratch = createTempDir("repro-oppgc-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      putEnv("REPRO_WORKSPACE_CLONES", scratch / "cache")
      defer: delEnv("REPRO_WORKSPACE_CLONES")
      let f = wiredWorkspace(gitBin, reproBin, scratch)

      # Pre-seed a DEAD workspace's cache ref, and remove the maintenance stamp
      # so the opportunistic pass is due when the cache-push fires.
      discard requireGit(q(gitBin) & " -C " & q(f.bare) &
        " update-ref refs/cache/deadws/main " & headOf(gitBin, f.ws / "r"))
      removeFile(f.bare / "reprobuild-last-gc")
      check hasRef(gitBin, f.bare, "refs/cache/deadws/main")   # present before

      check commitAndCachePush(gitBin, reproBin, f) == 0

      # Opportunistic maintenance ran: the dead ref is pruned and the stamp
      # was written — neither happens without the post-commit gc wiring.
      check not hasRef(gitBin, f.bare, "refs/cache/deadws/main")
      check fileExists(f.bare / "reprobuild-last-gc")

  test "t_post_commit_cache_push_maintains_other_due_bares":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs a repository")
    else:
      let scratch = createTempDir("repro-oppgc-other-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let cache = scratch / "cache"
      putEnv("REPRO_WORKSPACE_CLONES", cache)
      defer: delEnv("REPRO_WORKSPACE_CLONES")
      let f = wiredWorkspace(gitBin, reproBin, scratch)

      # A bare no commit ever pushes into, never maintained, holding a cache
      # ref of a workspace this one knows nothing about.
      let other = cache / "example.invalid" / "org" / "other.git"
      createDir(other.parentDir)
      discard requireGit(q(gitBin) & " clone -q --bare " & q(f.origin) & " " &
        q(other))
      discard requireGit(q(gitBin) & " -C " & q(other) &
        " update-ref refs/cache/elsewhere/main " & headOf(gitBin, other))
      check not fileExists(other / "reprobuild-last-gc")

      check commitAndCachePush(gitBin, reproBin, f) == 0

      check fileExists(other / "reprobuild-last-gc")
      check hasRef(gitBin, other, "refs/cache/elsewhere/main")

  test "t_post_commit_cache_push_keeps_refs_of_an_unreadable_sibling":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case needs a repository")
    else:
      let scratch = createTempDir("repro-oppgc-sibling-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      putEnv("REPRO_WORKSPACE_CLONES", scratch / "cache")
      defer: delEnv("REPRO_WORKSPACE_CLONES")
      let f = wiredWorkspace(gitBin, reproBin, scratch)

      # A sibling that records its state only under the retired file name.
      let old = scratch / "oldws"
      createDir(old / ".repro")
      writeFile(old / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
        "project = \"p\"\n")
      let head = headOf(gitBin, f.ws / "r")
      for owner in ["oldws", "deadws"]:
        discard requireGit(q(gitBin) & " -C " & q(f.bare) &
          " update-ref refs/cache/" & owner & "/main " & head)
      removeFile(f.bare / "reprobuild-last-gc")

      check commitAndCachePush(gitBin, reproBin, f) == 0

      check fileExists(f.bare / "reprobuild-last-gc")
      check hasRef(gitBin, f.bare, "refs/cache/oldws/main")
      check not hasRef(gitBin, f.bare, "refs/cache/deadws/main")

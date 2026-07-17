## Regression — the shared object cache must key/populate the bare by the FULL
## repo URL (`cloneUrlFor`), not the bare remote **base** (`ResolvedRepo.fetchUrl`).
##
## For the common one-remote-many-repos manifest layout (a `[[remote]]` whose
## `fetch` is an org/base URL that does NOT end in `.git`, e.g.
## `https://github.com/agent-harbor`, with the repo name appended per
## `getFetchUrl`), `repo.fetchUrl` is the base and is NOT cloneable. `sync`,
## `cache-push`, and `shared-clones list/rewire` used that base for the shared
## bare, so `git clone --bare <base>` always failed → the cache stayed a
## permanent miss and no checkout was ever wired to reprobuild's cache.
## (`init`/`pull` already used `cloneUrlFor` and were unaffected.)
##
## Here the remote `fetch` is `file://<scratch>/remote` (no `.git`) and the repo
## `name` is `proj`, so the resolved URL is `file://<scratch>/remote/proj` (the
## real bare) while `repo.fetchUrl` is `file://<scratch>/remote` (the base dir).
## `shared-clones rewire` must create the bare and wire the checkout.
##
## Falsifiability: against the pre-fix build, `rewire` reports `wired=false`
## with a `git clone --bare … does not appear to be a git repository`
## diagnostic (the base dir isn't a repo), and no `objects/info/alternates` is
## written. Confirmed failing on the unpatched build. The existing
## `t_workspace_shared_clones_list_and_rewire` used a `.git` remote (base ==
## full URL) and so never exercised this path.
##
## Hermetic local upstream; skip only when `git` / the binary is missing.

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

suite "regression — shared cache keys the bare by the full repo URL":

  test "t_shared_clone_uses_full_repo_url_for_base_remote":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sc-baseurl-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # Upstream bare at <scratch>/remote/proj (NO .git suffix), so the base
      # remote URL is a plain directory that is NOT itself a git repo.
      let remoteDir = scratch / "remote"
      createDir(remoteDir)
      let origin = remoteDir / "proj"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      let seed = scratch / "seed"
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.email t@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " config user.name Tester")
      writeFile(seed / "f.txt", "hi\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add f.txt")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m seed")
      discard requireGit(q(gitBin) & " -C " & q(seed) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

      let baseUrl = "file://" & remoteDir            # base, not .git
      let ws = scratch / "ws"
      let manifestsRoot = ws / ".repo" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "p.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"p\"\ndefault_revision = \"main\"\n\n" &
        "[[remote]]\nname = \"o\"\nfetch = \"" & baseUrl & "\"\n\n" &
        "includes = [\n  \"repos/proj.toml\",\n]\n")
      writeFile(manifestsRoot / "repos" / "proj.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"proj\"\npath = \"proj\"\nremote = \"o\"\n" &
        "revision = \"main\"\n")
      writeFile(ws / ".repo" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n[workspace]\n" &
        "project = \"p\"\n")
      # Existing checkout, not yet wired to any shared bare.
      discard requireGit(q(gitBin) & " clone " & q(baseUrl & "/proj") & " " &
        q(ws / "proj"))

      let cacheDir = scratch / "clones-cache"
      putEnv("REPRO_WORKSPACE_CLONES", cacheDir)
      defer: delEnv("REPRO_WORKSPACE_CLONES")

      let res = runCmd(q(reproBin) & " workspace shared-clones rewire" &
        " --workspace-root=" & q(ws) & " --json")
      if res.code != 0:
        checkpoint("rewire output: " & res.output)
      check res.code == 0

      # Parse the per-repo entry and assert the bare was created + wired — the
      # exact thing the base-URL bug made impossible.
      let report = parseJson(res.output)
      var entry: JsonNode = nil
      for r in report["repos"]:
        if r["path"].getStr() == "proj":
          entry = r
      check entry != nil
      check entry["barePresent"].getBool()
      check entry["wired"].getBool()
      # The alternates file physically points the checkout at the shared bare.
      let alternates = ws / "proj" / ".git" / "objects" / "info" / "alternates"
      check fileExists(alternates)
      check readFile(alternates).contains(cacheDir)

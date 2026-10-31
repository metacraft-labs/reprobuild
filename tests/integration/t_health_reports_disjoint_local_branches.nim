## Real Git fixture and production CLI; no mocked executables or responses.
## A non-HEAD orphan branch models history retained after a remote rewrite.
## Published imports and ordinary unpublished work are negative controls.
import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support

proc run(args: string; cwd = ""): string =
  let r = execCmdEx(args, workingDir = cwd)
  doAssert r.exitCode == 0, args & "\n" & r.output
  r.output.strip()

suite "health disjoint local branches":
  test "non-HEAD rewritten history is visible and never automatically retired":
    let root = createTempDir("health-disjoint-", "")
    defer: removeDir(root)
    let ws = root / "workspace"
    let repo = ws / "lib-a"
    createDir(ws / "projects")
    createDir(ws / "repos")
    createDir(ws / ".repro")
    discard run("git init --bare -b main " & quoteShell(root / "origin.git"))
    discard run("git clone " & quoteShell(root / "origin.git") & " " & quoteShell(repo))
    discard run("git config user.email tester@example.invalid", repo)
    discard run("git config user.name Tester", repo)
    writeFile(repo / "file", "new history")
    discard run("git add file", repo)
    discard run("git commit -m shared-subject", repo)
    discard run("git push -u origin main", repo)
    writeFile(ws / "projects/lib-a.toml", """schema = "reprobuild.workspace.project.v1"
[project]
name = "lib-a"
[[remote]]
name = "origin"
fetch = "ORIGIN"
includes = ["repos/lib-a.toml"]
""".replace("ORIGIN", root / "origin.git"))
    writeFile(ws / "repos/lib-a.toml", """schema = "reprobuild.workspace.repo.v2"
[repo]
mainline = "main"
name = "lib-a"
path = "lib-a"
remote = "origin"
revision = "main"
""")
    discard run("git switch --orphan old-history", repo)
    writeFile(repo / "old", "old history")
    discard run("git add old", repo)
    discard run("git commit -m shared-subject", repo)
    discard run("git branch --set-upstream-to=origin/main", repo)
    let oldTip = run("git rev-parse HEAD", repo)
    discard run("git branch no-upstream", repo)
    discard run("git switch main", repo)
    discard run("git switch -c ordinary-work", repo)
    writeFile(repo / "ordinary", "ordinary work")
    discard run("git add ordinary", repo)
    discard run("git commit -m ordinary-unpublished", repo)
    discard run("git switch main", repo)
    # Allows the same regression to be run against a preserved pre-fix image.
    let bin = requireBinary(getEnv("REPRO_HEALTH_TEST_BINARY",
      currentSourcePath().parentDir.parentDir.parentDir / "build/bin/repro"),
      "reprobuild.apps.repro")
    proc invoke(extra = ""; jsonMode = true): string =
      let isolated = "env HOME=" & quoteShell(root / "home") &
        " XDG_DATA_HOME=" & quoteShell(root / "data") &
        " XDG_CONFIG_HOME=" & quoteShell(root / "config") &
        " XDG_CACHE_HOME=" & quoteShell(root / "cache") &
        " XDG_STATE_HOME=" & quoteShell(root / "state") &
        " REPRO_DAEMON_ENDPOINT=" & quoteShell(root / "absent.sock") &
        " REPRO_DAEMON_STATE_DIR=" & quoteShell(root / "daemon") &
        " REPRO_WORKSPACE_CLONES=" & quoteShell(root / "clones") &
        " REPROBUILD_REPRO=" & quoteShell(bin) & " "
      let r = execCmdEx(isolated & quoteShell(bin) & " health lib-a " & (if jsonMode: "--json " else: "") & "--workspace-root=" &
        quoteShell(ws) & " " & extra)
      r.output
    proc health(extra = ""): JsonNode =
      let output = invoke(extra)
      let start = output.find('{')
      doAssert start >= 0, "health did not emit JSON: " & output
      parseJson(output[start .. ^1])
    proc row(report: JsonNode; name = "disjoint-local-branches"): JsonNode =
      for c in report["checks"]:
        if c["name"].getStr == name: return c
      return newJNull()
    let unrelated = execCmdEx("git merge-base old-history origin/main", workingDir = repo)
    require unrelated.exitCode == 1
    require unrelated.output.strip().len == 0
    require run("git branch -r --contains old-history", repo).len == 0
    require "origin/main" in run("git branch -r --contains HEAD", repo)
    require run("git branch -r --contains ordinary-work", repo).len == 0
    require run("git merge-base ordinary-work origin/main", repo).len > 0
    let initialReport = health()
    require row(initialReport, "manifest")["status"].getStr == "ok"
    require row(initialReport, "unpublished-heads")["status"].getStr == "ok"
    let before = row(initialReport)
    require before.kind != JNull
    check before["status"].getStr == "warn"
    check "old-history" in before["detail"].getStr
    check "no-upstream'" in before["detail"].getStr
    check "unconfirmed" notin before["detail"].getStr.replace("disjoint or unconfirmed local branch finding(s)", "")
    check "ordinary-work" notin before["detail"].getStr
    check "all subjects" in before["detail"].getStr
    check "heuristic" in before["detail"].getStr
    check "do not push" in before["remedy"].getStr
    let fragment = ws / "repos/lib-a.toml"
    let originalFragment = readFile(fragment)
    writeFile(fragment, originalFragment.replace("revision = \"main\"",
      "revision = \"" & run("git rev-parse main", repo) & "\""))
    let pinned = row(health())
    check pinned["status"].getStr == "warn"
    check "no-upstream'" in pinned["detail"].getStr
    check "no upstream or declared mainline" notin pinned["detail"].getStr
    writeFile(fragment, originalFragment)
    discard health("--fix")
    check run("git rev-parse old-history", repo) == oldTip
    check run("git symbolic-ref --short HEAD", repo) == "main"
    check run("git branch -r --contains old-history", repo).len == 0
    # --fix may install hooks in this throwaway repository. Subsequent fixture
    # publications do not test hook dispatch or the host's installed repro.
    if dirExists(repo / ".git/hooks"):
      removeDir(repo / ".git/hooks")
      createDir(repo / ".git/hooks")
    discard run("git push origin old-history:imported-root", repo)
    let published = row(health())
    check published["status"].getStr == "ok"
    discard run("git init --bare " & quoteShell(root / "secondary.git"))
    discard run("git remote add secondary " & quoteShell(root / "secondary.git"), repo)
    discard run("git push secondary old-history:imported-root", repo)
    discard run("git push origin --delete imported-root", repo)
    discard run("git switch old-history", repo)
    let secondaryImport = health()
    check row(secondaryImport)["status"].getStr == "ok"
    check "do not push" notin row(secondaryImport, "unpublished-heads")["remedy"].getStr
    writeFile(repo / "unique", "work to keep")
    discard run("git add unique", repo)
    discard run("git commit -m unique-work-to-keep", repo)
    discard run("git switch main", repo)
    let unique = row(health())
    check unique["status"].getStr == "warn"
    check "unique-work-to-keep" in unique["detail"].getStr
    check "missing" in unique["detail"].getStr
    discard run("git switch old-history", repo)
    let hazardousHead = health()
    check "do not push" in row(hazardousHead, "unpublished-heads")["remedy"].getStr
    discard run("git switch main", repo)
    discard run("git config branch.old-history.merge refs/heads/missing", repo)
    let absent = row(health())
    check absent["status"].getStr == "warn"
    check "unconfirmed" in absent["detail"].getStr
    discard run("git branch --set-upstream-to=origin/main old-history", repo)
    # A configured upstream takes precedence over the manifest mainline.
    discard run("git branch --set-upstream-to=secondary/imported-root old-history", repo)
    check row(health())["status"].getStr == "ok"
    discard run("git branch --set-upstream-to=origin/main old-history", repo)
    for n in 0 .. 6:
      discard run("git branch stale-" & $n & " old-history", repo)
    let many = row(health())
    check "stale-6" in many["detail"].getStr
    let digest = invoke(jsonMode = false)
    check "(+" in digest
    check "stale-6" notin digest
    check "stale-6" in invoke("--verbose", jsonMode = false)
    # Publication unknown locally but present remotely must clear on fetch.
    let publisher = root / "publisher"
    discard run("git clone " & quoteShell(root / "origin.git") & " " & quoteShell(publisher))
    discard run("git -C " & quoteShell(publisher) & " fetch " & quoteShell(repo) &
      " old-history:old-history")
    discard run("git -C " & quoteShell(publisher) & " push origin old-history:externally-published")
    check row(health())["status"].getStr == "ok"
    # Replace the participating checkout with a linked worktree (.git file).
    let primary = root / "primary"
    moveDir(repo, primary)
    discard run("git switch --detach", primary)
    discard run("git worktree add " & quoteShell(repo) & " main", primary)
    discard run("git switch --orphan another-old-root", repo)
    writeFile(repo / "fresh-orphan", "not published")
    discard run("git add fresh-orphan", repo)
    discard run("git commit -m linked-orphan", repo)
    discard run("git switch main", repo)
    check row(health())["status"].getStr == "warn"
    check "another-old-root" in row(health())["detail"].getStr
    # Shallow boundaries cannot establish unrelated roots.
    writeFile(primary / ".git/shallow", run("git rev-parse main", repo) & "\n")
    let shallow = row(health())
    check shallow["status"].getStr == "warn"
    check "deepen shallow history" in shallow["detail"].getStr
    removeFile(primary / ".git/shallow")
    discard run("git remote set-url origin " & quoteShell(root / "absent.git"), repo)
    let offline = row(health())
    check offline["status"].getStr == "warn"
    check "fetch failed" in offline["detail"].getStr

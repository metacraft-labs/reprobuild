## Unified-Locking-And-Hooks HL-3 (§6 Decision 2) — warn-for-personal on an
## unreachable backend, driven through the REAL pre-push hook (``repro check
## --mode=pre-push`` + its post-gate per-backend publish).
##
## Case A (warn + allow). A PERSONAL-tier repo is routed to a git-checkout lock
## backend on its OWN private remote. The backend's upstream bare is removed
## after its tracking branch is configured, so the pre-push publish push FAILS.
## Because the tier is PERSONAL (the user's own durable backend), Decision 2 says
## WARN but ALLOW: the gate stays exit 0 and adds a ``notices`` warning naming
## the personal backend + ``repro lock refresh`` — the push proceeds.
##
## Case B (manifest-LESS publish — carries deliverable 3). A workspace with NO
## ``.repro/manifests`` checkout at all, routing its personal repo to a HEALTHY
## git-checkout backend on its own remote, must STILL publish that personal
## backend at pre-push. This proves HL-3 lifted HL-2's ``manifestLayerRoot.len >
## 0`` gate on the per-backend publish: the routed personal backend's bare
## receives the ``locks/`` records even though there is no manifest checkout.
##
## Falsifiability:
##   - Case A: applying the refuse policy to a personal repo (or flipping the
##     tier test) makes the gate exit 2 and drops the warning → the ``exit 0`` +
##     notice assertions trip.
##   - Case B (deliverable 3): restoring the ``manifestLayerRoot.len > 0`` gate
##     around the per-backend publish loop skips the publish in a manifest-less
##     workspace → the personal backend's bare receives NO ``locks/`` objects →
##     the ``ls-tree`` assertion trips.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.
## Config layers are silenced with env overrides. Skip: ``git`` missing or
## ``./build/bin/repro`` absent.

import std/[json, os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl

import repro_workspace_manifests

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any
  ## `test` body. `unittest.check` there cannot see the `testStatusIMPL`
  ## the `test` template injects, so it prints "Check failed" and the case
  ## still reports `[OK]`; `quit 1` tears the process down mid-case, so
  ## `unittest` emits no `[FAILED]` marker and every later case in the file
  ## silently never runs. `doAssert` raises an `AssertionDefect`, which the
  ## `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc gitConfig(gitBin, repo: string) =
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repo) &
    " config user.name \"HL-3 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "HL-3 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  gitConfig(gitBin, targetPath)

proc seedGitCheckoutBackend(gitBin, checkoutRoot, bare: string) =
  ## A git-checkout lock backend that TRACKS a bare upstream — so the pre-push
  ## per-backend publish genuinely attempts a push.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))
  discard requireGit(q(gitBin) & " init -b main " & q(checkoutRoot))
  gitConfig(gitBin, checkoutRoot)
  writeFile(checkoutRoot / ".keep", "personal lock backend\n")
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) & " add .keep")
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) &
    " commit -m \"seed personal backend\"")
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(checkoutRoot) &
    " push -u origin main")

proc projectToml(coreUrl, projName: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"" & projName & "\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc seedManifestGitLayer(gitBin, manifestsRoot, bare: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(bare))
  discard requireGit(q(gitBin) & " init -b main " & q(manifestsRoot))
  gitConfig(gitBin, manifestsRoot)
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " push -u origin main")

proc personalRoute(): string =
  "[locking]\n" &
  "route = [" &
  "{ visibility = \"personal\", backend = \"git-checkout\", " &
  "path = \"personal-lockrepo\", repos = [\"core\"] }]\n"

proc silenceLayers(scratch: string) =
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")

proc unsilenceLayers() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc backendUnreachableFailure(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "lock-backend-unreachable":
      return f
  return nil

proc noticeMentioning(report: JsonNode; needle: string): bool =
  for n in report["notices"]:
    if n.getStr().contains(needle):
      return true
  false

proc noticeText(report: JsonNode; needle: string): string =
  for n in report["notices"]:
    if n.getStr().contains(needle):
      return n.getStr()
  ""

proc namedReproCommands(message: string): seq[string] =
  ## The ``repro …`` invocations a message tells the operator to run, parsed
  ## out of its backticks. Naming a command is a promise that it runs; the
  ## caller keeps that promise honest by running it.
  var i = 0
  while true:
    let a = message.find('`', i)
    if a < 0: break
    let b = message.find('`', a + 1)
    if b < 0: break
    let cmd = message[(a + 1) ..< b].strip()
    if cmd.startsWith("repro ") and cmd notin result: result.add(cmd)
    i = b + 1

suite "HL-3 — pre-push warns and allows on an unreachable personal backend":

  test "t_pre_push_warns_and_allows_on_unreachable_personal_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      # =================================================================
      # Case A — unreachable personal backend ⇒ WARN + ALLOW (exit 0).
      # =================================================================
      block caseA:
        let scratch = createTempDir("hl3-personal-warn-", "")
        defer: removeDir(scratch)

        let coreOrigin = scratch / "origin-core.git"
        let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")

        let ws = scratch / "workspace"
        createDir(ws)
        let manifestsRoot = ws / ".repro" / "manifests"
        createDir(manifestsRoot / "projects")
        createDir(manifestsRoot / "repos")
        writeFile(manifestsRoot / "projects" / "solo.toml",
          projectToml(fileUrl(coreOrigin), "solo"))
        writeFile(manifestsRoot / "repos" / "core.toml",
          repoFragment("core", "core-origin"))
        seedManifestGitLayer(gitBin, manifestsRoot, scratch / "manifest.git")

        cloneInto(gitBin, coreOrigin, ws / "core")
        writeWorkspaceBranch(ws, project = "solo", branch = "main")

        let personalBackend = ws / "personal-lockrepo"
        let personalBare = scratch / "personal-backend.git"
        seedGitCheckoutBackend(gitBin, personalBackend, personalBare)

        writeFile(ws / ".repro-workspace.toml",
          "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
          "[manifest]\n" &
          "url = \"https://example.invalid/manifests.git\"\n\n" &
          personalRoute())

        silenceLayers(scratch)
        defer: unsilenceLayers()

        let lockRes = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
        if lockRes.code != 0:
          checkpoint("workspace lock output: " & lockRes.output)
        check lockRes.code == 0

        # Make the personal backend push FAIL: remove its bare upstream.
        removeDir(personalBare)

        let refsFile = scratch / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & coreSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")
        let gateRes = run(reproBinary & " check --mode=pre-push --write-report" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / "core") &
          " --pushed-refs=" & q(refsFile) & " --json")
        checkpoint("gate output: " & gateRes.output)

        # ALLOW: the push proceeds (exit 0) even though the personal backend
        # is unreachable.
        check gateRes.code == 0
        let reportPath = ws / ".repro" / "build" / "reports" / "check-report.json"
        check fileExists(reportPath)
        let report = parseFile(reportPath)
        check report["exitCode"].getInt() == 0

        # A personal-backend failure must NOT become a refuse failure.
        check backendUnreachableFailure(report) == nil

        # WARN: a notice names the personal backend + ``repro lock refresh``.
        check noticeMentioning(report, "personal lock backend")

        # The notice tells the operator to run something "when it is
        # reachable". Pin the property rather than the wording: whatever
        # command the notice names must EXIST and RUN — from the directory the
        # pre-push hook speaks from (the pushed repo), once the backend is
        # back. This used to name `repro lock refresh`, which re-pins the
        # committed solved-graph `repro.lock` and exits 1 with "no solver
        # inputs found" here; the record that went unrecorded is a WORKSPACE
        # lock entry in the personal backend.
        let named = namedReproCommands(noticeText(report, "personal lock backend"))
        checkpoint("notice names: " & named.join(" | "))
        check named.len >= 1
        # Make the personal backend reachable again — the precondition the
        # notice itself states.
        discard requireGit(q(gitBin) & " init -q --bare -b main " &
          q(personalBare))
        for cmd in named:
          let res = run(absolutePath(reproBinary) & cmd["repro".len .. ^1],
            cwd = ws / "core")
          checkpoint("ran `" & cmd & "` -> exit " & $res.code & "\n" & res.output)
          check res.code == 0
          check not res.output.contains("no solver inputs found")

      # =================================================================
      # Case B — manifest-LESS workspace publishes its routed personal
      # backend (deliverable 3: the lifted ``manifestLayerRoot`` gate).
      # =================================================================
      block caseB:
        let scratch = createTempDir("hl3-manifestless-publish-", "")
        defer: removeDir(scratch)

        # A GENUINELY manifest-LESS workspace: a single committed-lock git repo
        # (its ``repro.lock`` is the reproducibility artifact) with NO
        # ``.repro/manifests`` directory at all — so the gate's
        # ``manifestLayerRoot`` resolves EMPTY and the manifest publish path is
        # skipped entirely. The ONLY way the routed personal backend can be
        # published is the per-backend publish loop, whose ``manifestLayerRoot >
        # 0`` gate HL-3 lifted.
        # The bare is named ``work.git`` deliberately. A committed-lock repo's
        # LOCK IDENTITY is the leaf of its remote URL, not its checkout
        # directory name (`repositoryNameFromUrl`, so a repo cloned into a
        # differently named directory keeps one identity). The route below
        # names ``work`` and the assertion at the end of this block expects
        # ``locks/work/work/``; with the bare called ``origin.git`` the repo
        # locked as ``origin``, the route matched nothing, the personal
        # backend was never selected, and the assertion could not hold.
        let origin = scratch / "work.git"
        discard requireGit(q(gitBin) & " init -q --bare -b main " & q(origin))
        let ws = scratch / "work"
        discard requireGit(q(gitBin) & " init -q -b main " & q(ws))
        gitConfig(gitBin, ws)
        writeFile(ws / "README.md", "manifest-less\n")
        writeFile(ws / "repro.solver", "package app\nversions: 0.1.0\n")
        # Ignore the CLI work tree and the personal backend checkout so neither
        # dirties the workspace tree (the gate's cleanliness stage would
        # otherwise refuse before reaching the publish).
        writeFile(ws / ".gitignore", "/.repro/\n/personal-lockrepo/\n")

        # A HEALTHY personal git-checkout backend on its own remote, living
        # inside (but git-ignored by) the workspace.
        let personalBackend = ws / "personal-lockrepo"
        let personalBare = scratch / "personal-backend.git"
        seedGitCheckoutBackend(gitBin, personalBackend, personalBare)

        # The route names the committed-lock dep by NAME (``work`` — the repo's
        # own coordinates in its ``repro.lock``) at the personal tier.
        writeFile(ws / ".repro-workspace.toml",
          "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
          "[manifest]\n" &
          "url = \"https://example.invalid/manifests.git\"\n\n" &
          "[locking]\n" &
          "route = [" &
          "{ visibility = \"personal\", backend = \"git-checkout\", " &
          "path = \"personal-lockrepo\", repos = [\"work\"] }]\n")

        discard requireGit(q(gitBin) & " -C " & q(ws) &
          " add README.md repro.solver .gitignore .repro-workspace.toml")
        discard requireGit(q(gitBin) & " -C " & q(ws) & " commit -qm seed")
        discard requireGit(q(gitBin) & " -C " & q(ws) &
          " remote add origin " & q(origin))
        discard requireGit(q(gitBin) & " -C " & q(ws) & " push -q origin main")

        silenceLayers(scratch)
        defer: unsilenceLayers()

        # Refresh + commit the committed lock (the reproducibility artifact).
        let refresh = run(reproBinary & " lock refresh " & q(ws))
        if refresh.code != 0:
          checkpoint("lock refresh output: " & refresh.output)
        check refresh.code == 0
        check fileExists(ws / "repro.lock")
        discard requireGit(q(gitBin) & " -C " & q(ws) & " add repro.lock")
        discard requireGit(q(gitBin) & " -C " & q(ws) & " commit -qm lock")
        discard requireGit(q(gitBin) & " -C " & q(ws) & " push -q origin main")

        let headSha = requireGit(q(gitBin) & " -C " & q(ws) &
          " rev-parse HEAD").strip()
        let refsFile = scratch / "pushed-refs.txt"
        writeFile(refsFile, "refs/heads/main " & headSha &
          " refs/heads/main 0000000000000000000000000000000000000000\n")
        let gateRes = run(reproBinary & " check --mode=pre-push --write-report" &
          " --workspace-root=" & q(ws) &
          " --pushed-refs=" & q(refsFile) & " --json")
        checkpoint("manifest-less gate output: " & gateRes.output)

        # The clean gate passes (exit 0).
        check gateRes.code == 0
        let reportPath = ws / ".repro" / "build" / "reports" / "check-report.json"
        check fileExists(reportPath)
        let report = parseFile(reportPath)
        check report["exitCode"].getInt() == 0
        # Confirm the workspace really is manifest-LESS (empty layer root) —
        # otherwise this case would not exercise the lifted gate.
        check report["manifestLayerRoot"].getStr() == ""

        # deliverable 3: the routed personal backend's bare received the
        # ``locks/`` records EVEN THOUGH there is no manifest checkout. With the
        # old ``manifestLayerRoot.len > 0`` gate restored, the per-backend
        # publish loop would be skipped and this bare would stay empty of
        # ``locks/`` objects.
        let ls = run(q(gitBin) & " -C " & q(personalBare) &
          " ls-tree -r --name-only refs/heads/main")
        check ls.code == 0
        check ls.output.contains("locks/work/work/")

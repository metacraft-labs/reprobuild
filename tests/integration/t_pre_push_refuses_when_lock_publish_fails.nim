## RA-21 — loud-on-failure lock publication in the pre-push gate.
##
## The lock *write/refresh* is best-effort, but the *publication the push
## depends on* is part of the publication boundary: if the pre-push gate
## cannot publish the lock (network / non-fast-forward / manifest dirty
## outside ``locks/``), the push is REFUSED with a clear diagnostic, not
## silently allowed (Workspace-And-Develop-Mode.md §"Lock publication is
## loud on failure"). A teammate must never pull a commit whose lock never
## reached the manifest repo.
##
## This test sets up a single-repo workspace whose manifest layer
## (``.repo/manifests``) IS a real git checkout WITH an upstream (so the
## gate genuinely attempts to publish), then makes the publish PUSH fail by
## removing the upstream bare after the tracking branch is configured.
## ``@{u}`` still resolves from local config, the lock is written and
## committed, but ``git push`` errors — driving ``publishWorkspaceLock`` to
## ``lpoFailed``.
##
## Assertions:
##   - The pre-push gate exits NON-ZERO (the push is refused).
##   - The report carries a ``lock-publish-failure`` failure whose evidence
##     names the publish cause (the failed ``git push``).
##   - The underlying gate checks themselves PASSED (the sibling was clean
##     and published and the lock current/created) — proving the refusal is
##     specifically the publish failure, not an ordinary gate refusal.
##
## Falsifiable: if the publish failure were left best-effort (the pre-RA-21
## behavior), the gate would exit 0 with no ``lock-publish-failure``
## failure. A control at the end confirms that with a WORKING upstream the
## same gate PASSES (exit 0) and publishes — so the refusal is caused by the
## publish failure, not the fixture.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no
## network. Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA21 Tester\"")
  writeFile(workPath / "README.md", "RA21 publish-fail fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA21 Tester\"")

proc projectTomlWith1Remote(libAUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    manifestsRoot: string
    manifestBare: string
    libAOrigin: string
    libASha: string

proc seedManifestGitLayer(gitBin, manifestsRoot, bare, projectToml: string;
                          branch = "main") =
  ## Make ``.repo/manifests`` a real git checkout that TRACKS a bare
  ## upstream — so the pre-push gate genuinely attempts a publish push.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.name \"RA21 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  # ``-u`` configures the tracking branch so ``@{u}`` resolves later even
  # if the bare goes away.
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin " & branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra21-pubfail-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  let seedPath = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith1Remote(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.manifestsRoot = manifestsRoot
  result.manifestBare = result.scratch / "manifest.git"
  seedManifestGitLayer(gitBin, manifestsRoot, result.manifestBare,
    projectTomlWith1Remote(fileUrl(result.libAOrigin)))
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  result.workspaceRoot = workspaceRoot
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc writeRefsFile(path: string; localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeCheckPrePush(fx: Fixture; refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a"),
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc publishFailureFailure(report: JsonNode): JsonNode =
  for f in report["failures"]:
    if f["property"].getStr() == "lock-publish-failure":
      return f
  return nil

suite "RA-21 — pre-push refuses when lock publication fails":

  test "t_pre_push_refuses_when_lock_publish_fails":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "fail")
      defer: removeDir(fx.scratch)

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)

      # ---- Force the publish PUSH to fail -------------------------------
      # The manifest checkout still has its tracking branch configured, so
      # ``@{u}`` resolves and the lock is written + committed; but removing
      # the bare upstream makes the publish ``git push`` error out.
      removeDir(fx.manifestBare)

      let res = invokeCheckPrePush(fx, refsFile)
      checkpoint("publish-fail output: " & res.output)
      # The push is REFUSED (non-zero). Falsifiable: best-effort publish
      # would let this exit 0.
      check res.code != 0

      let report = readReport(fx)
      check report["exitCode"].getInt() != 0
      let pubFail = publishFailureFailure(report)
      check pubFail != nil
      # The diagnostic names the publish cause (the failed push).
      check pubFail["evidence"].getStr().toLowerAscii().contains("push")
      # Exactly the publish failure gates it: the sibling-cleanliness /
      # publication / lock stages all PASSED, so lib-a is NOT named as a
      # dirty/unpublished offender — the only failure is the publish one.
      for f in report["failures"]:
        check f["property"].getStr() notin
          ["dirty", "unpublished", "lock-failure"]
      # The lock itself was successfully created/refreshed before publish.
      check report["lockUpdate"]["kind"].getStr() in
        ["created", "refreshed", "already-current"]

      # ---- Control: a WORKING upstream PASSES and publishes -------------
      # Re-create the bare and re-point/re-push so the upstream is healthy,
      # proving the refusal above was the publish failure, not the fixture.
      let fx2 = setupFixture(gitBin, "ok")
      defer: removeDir(fx2.scratch)
      let refsFile2 = fx2.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile2, fx2.libASha)

      let ok = invokeCheckPrePush(fx2, refsFile2)
      checkpoint("publish-ok output: " & ok.output)
      check ok.code == 0
      let okReport = readReport(fx2)
      check okReport["exitCode"].getInt() == 0
      check publishFailureFailure(okReport) == nil
      # The publish actually landed in the bare upstream.
      let ls = runCmd(q(gitBin) & " -C " & q(fx2.manifestBare) &
        " ls-tree -r --name-only refs/heads/main")
      check ls.code == 0
      check ls.output.contains("locks/lib-a/lib-a/")

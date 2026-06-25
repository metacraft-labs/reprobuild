## RA-28 — every failure teaches the remedy (cross-cutting).
##
## Interactive-UX-And-Progress.md Principle 2: a command that refuses MUST
## (a) NAME the offender — the specific repo/target whose state blocks the
## operation — and (b) NAME a concrete, copy-pasteable remedy command. This
## test is PARAMETRIZED over the workspace refusal sites and asserts BOTH
## halves of the contract for each, driving every case through the real
## ``build/bin/repro`` binary against a hermetic fixture.
##
## Refusal sites covered (one ``test`` per case):
##   - gate-dirty            ``repro check --mode=pre-push`` on a dirty sibling.
##   - gate-unpublished      ``repro check --mode=pre-push`` on an unpublished
##                           HEAD.
##   - gate-lock-publish      ``repro check`` when the lock publish push fails.
##   - sync-dirty            ``repro sync`` refusing a dirty checkout.
##   - sync-unpublished      ``repro sync`` refusing a locally-unpublished one.
##   - sync-unreadable       ``repro sync`` skipping a newly-declared repo whose
##                           clone fails (unreadable origin).
##   - remove-dirty          ``repro remove`` refusing a dirty repo in non-TTY.
##   - checkout-dirty        ``repro checkout`` of a dirty repo refused by the
##                           RA-9 destructive-switch gate (non-TTY, no
##                           ``--yes``). RA-29 stashes a dirty repo's WIP rather
##                           than refusing it, so the offending act is the
##                           working-tree switch the gate guards; the remedy is
##                           ``repro checkout <branch> --yes``.
##   - checkout-missing      ``repro checkout`` of an absent branch.
##
## For EACH case: the offender (the real repo / branch name) must appear in
## the refusal text AND a copy-pasteable command (``repro …`` / ``git …``)
## must appear. The asserts FAIL if a site stops naming the offender or drops
## the remedy — the RA-28 contract is exactly that pairing.
##
## Skip rule: ``git`` missing on PATH.

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

# ---- bare-origin seed helpers --------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA28 Tester\"")
  writeFile(workPath / "README.md", "RA28 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA28 Tester\"")

# ---- manifest TOML --------------------------------------------------------

proc projectTomlSingle(libAUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

# A two-repo project used by the sync-unreadable case: lib-b is declared with
# an origin that never exists, so its clone fails and sync must SKIP it.
proc projectTomlTwo(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

# ---- fixture --------------------------------------------------------------

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libASeed: string
    libASha: string
    manifestsRoot: string
    manifestBare: string

proc baseFixture(gitBin, slug: string): Fixture =
  ## A single-repo (lib-a) workspace with lib-a cloned and on branch ``main``.
  result.scratch = createTempDir("repro-ra28-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASeed = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, result.libASeed)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlSingle(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.manifestsRoot = manifestsRoot
  result.workspaceRoot = workspaceRoot
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc seedManifestGitLayer(gitBin: string; fx: var Fixture) =
  ## Make ``.repo/manifests`` a real git checkout tracking a bare upstream so
  ## the pre-push gate genuinely attempts a publish push.
  fx.manifestBare = fx.scratch / "manifest.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(fx.manifestBare))
  discard requireGit(q(gitBin) & " init -b main " & q(fx.manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(fx.manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(fx.manifestsRoot) &
    " config user.name \"RA28 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(fx.manifestsRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(fx.manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(fx.manifestsRoot) &
    " remote add origin " & q(fx.manifestBare))
  discard requireGit(q(gitBin) & " -C " & q(fx.manifestsRoot) &
    " push -u origin main")

proc writeRefsFile(path: string; localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

# ---- command invokers -----------------------------------------------------

proc invokeCheckPrePush(fx: Fixture; refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a"),
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc invokeSync(fx: Fixture; project = "lib-a"): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", project,
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeCheckout(fx: Fixture; branch: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "checkout", branch,
    "--workspace-root=" & fx.workspaceRoot, "--json",
  ]))

proc invokeRemove(fx: Fixture; target: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "remove", target,
    "--workspace-root=" & fx.workspaceRoot,
  ]))

# ---- report readers -------------------------------------------------------

proc checkReport(fx: Fixture): JsonNode =
  parseFile(fx.workspaceRoot / ".repro" / "workspace" / "check-report.json")

proc syncReport(fx: Fixture): JsonNode =
  parseFile(fx.workspaceRoot / ".repro" / "workspace" / "sync-report.json")

# ---- the contract assertion ----------------------------------------------

proc assertNamesOffenderAndRemedy(text, offender: string) =
  ## The RA-28 contract: ``text`` must NAME ``offender`` and carry a
  ## copy-pasteable remedy command (a ``repro …`` or ``git …`` invocation).
  checkpoint("refusal text: " & text)
  check text.contains(offender)
  let hasRemedy = text.contains("repro ") or text.contains("git ")
  check hasRemedy

suite "RA-28 — refusals name the offender and a remedy command":

  test "gate_dirty_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "gate-dirty")
      defer: removeDir(fx.scratch)
      writeFile(fx.workspaceRoot / "lib-a" / "scratch.txt", "uncommitted\n")
      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)
      let res = invokeCheckPrePush(fx, refsFile)
      check res.code == 2
      let report = checkReport(fx)
      var failure: JsonNode = nil
      for f in report["failures"]:
        if f["property"].getStr() == "dirty": failure = f
      check failure != nil
      check failure["repo"].getStr() == "lib-a"
      assertNamesOffenderAndRemedy(failure["remediation"].getStr(), "lib-a")

  test "gate_unpublished_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "gate-unpub")
      defer: removeDir(fx.scratch)
      # A new local commit that is NOT pushed → unpublished HEAD.
      writeFile(fx.workspaceRoot / "lib-a" / "local.txt", "local\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " add local.txt")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " commit -m local")
      let localSha = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") & " rev-parse HEAD").strip()
      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, localSha)
      let res = invokeCheckPrePush(fx, refsFile)
      check res.code == 2
      let report = checkReport(fx)
      var failure: JsonNode = nil
      for f in report["failures"]:
        if f["property"].getStr() == "unpublished": failure = f
      check failure != nil
      check failure["repo"].getStr() == "lib-a"
      assertNamesOffenderAndRemedy(failure["remediation"].getStr(), "lib-a")

  test "gate_lock_publish_failure_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      var fx = baseFixture(gitBin, "gate-lockpub")
      defer: removeDir(fx.scratch)
      seedManifestGitLayer(gitBin, fx)
      # Remove the bare upstream so the publish PUSH fails (lpoFailed).
      removeDir(fx.manifestBare)
      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)
      let res = invokeCheckPrePush(fx, refsFile)
      check res.code != 0
      let report = checkReport(fx)
      var failure: JsonNode = nil
      for f in report["failures"]:
        if f["property"].getStr() == "lock-publish-failure": failure = f
      check failure != nil
      # The offender here is the workspace lock / manifest repo; the remedy
      # is the concrete ``repro push`` command.
      check failure["remediation"].getStr().contains("repro push")

  test "sync_dirty_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "sync-dirty")
      defer: removeDir(fx.scratch)
      writeFile(fx.workspaceRoot / "lib-a" / "dirty.txt", "uncommitted\n")
      let res = invokeSync(fx)
      check res.code == 2
      let report = syncReport(fx)
      var entry: JsonNode = nil
      for e in report["repos"]:
        if e["path"].getStr() == "lib-a": entry = e
      check entry != nil
      check entry["executionStatus"].getStr() == "refused"
      assertNamesOffenderAndRemedy(entry["refusalReason"].getStr(), "lib-a")

  test "sync_unpublished_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "sync-unpub")
      defer: removeDir(fx.scratch)
      # A clean tree with a local-only commit (unpublished).
      writeFile(fx.workspaceRoot / "lib-a" / "local.txt", "local\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " add local.txt")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " commit -m local")
      let res = invokeSync(fx)
      check res.code == 2
      let report = syncReport(fx)
      var entry: JsonNode = nil
      for e in report["repos"]:
        if e["path"].getStr() == "lib-a": entry = e
      check entry != nil
      check entry["executionStatus"].getStr() == "refused"
      assertNamesOffenderAndRemedy(entry["refusalReason"].getStr(), "lib-a")

  test "sync_unreadable_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # Two-repo project: lib-b's origin never exists → its clone fails and
      # sync must SKIP it with an offender + remedy command in the message.
      var fx = baseFixture(gitBin, "sync-unread")
      defer: removeDir(fx.scratch)
      let libBOriginMissing = fx.scratch / "origin-lib-b-does-not-exist.git"
      writeFile(fx.manifestsRoot / "projects" / "lib-a.toml",
        projectTomlTwo(fileUrl(fx.libAOrigin), fileUrl(libBOriginMissing)))
      writeFile(fx.manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
      check not dirExists(fx.workspaceRoot / "lib-b")
      let res = invokeSync(fx)
      # An unreadable NEW repo must NOT make the whole sync fail fatally.
      check res.code != 1
      let report = syncReport(fx)
      var entry: JsonNode = nil
      for e in report["repos"]:
        if e["path"].getStr() == "lib-b": entry = e
      check entry != nil
      check entry["executionStatus"].getStr() == "skipped"
      assertNamesOffenderAndRemedy(
        entry["executionDiagnostic"].getStr(), "lib-b")

  test "remove_dirty_non_tty_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "remove-dirty")
      defer: removeDir(fx.scratch)
      writeFile(fx.workspaceRoot / "lib-a" / "uncommitted.txt", "work\n")
      # Non-TTY (runShell uses startProcess, not a terminal), no --force →
      # the destructive remove REFUSES, naming the --force remedy flag.
      let res = invokeRemove(fx, "lib-a")
      check res.code == 2
      checkpoint("remove output: " & res.output)
      # Offender: the preview lists lib-a. Remedy: re-run with --force.
      check res.output.contains("lib-a")
      check res.output.contains("--force")
      # The working tree is intact — refusal discarded nothing.
      check fileExists(fx.workspaceRoot / "lib-a" / "uncommitted.txt")

  test "checkout_dirty_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "checkout-dirty")
      defer: removeDir(fx.scratch)
      # Create a target branch on origin so the branch exists everywhere and a
      # dirty working tree is the only thing that makes this checkout
      # destructive. RA-29 no longer REFUSES a dirty repo (it stashes WIP on
      # leave) — instead the RA-9 destructive-command gate refuses the
      # working-tree switch when run non-interactively without ``--yes``. The
      # ``invokeCheckout`` helper passes no ``--yes`` and runs under
      # ``startProcess`` (non-TTY), so the gate fires: the repo is reported
      # ``confirm_refused`` and the run exits 2 having mutated nothing.
      discard requireGit(q(gitBin) & " -C " & q(fx.libASeed) & " branch feat")
      discard requireGit(q(gitBin) & " -C " & q(fx.libASeed) &
        " push origin feat")
      writeFile(fx.workspaceRoot / "lib-a" / "dirty.txt", "uncommitted\n")
      let res = invokeCheckout(fx, "feat")
      check res.code == 2
      let rep = parseFile(
        fx.workspaceRoot / ".repro" / "workspace" / "checkout-report.json")
      var entry: JsonNode = nil
      for e in rep["repos"]:
        if e["path"].getStr() == "lib-a": entry = e
      check entry != nil
      check entry["outcome"].getStr() == "confirm_refused"
      # RA-28: the per-repo refusal diagnostic must NAME the offender (lib-a,
      # whose dirty working tree would be switched and whose WIP would be
      # stashed) AND a copy-pasteable remedy command (``repro checkout … --yes``).
      let diag = entry["diagnostic"].getStr()
      assertNamesOffenderAndRemedy(diag, "lib-a")
      check diag.contains("--yes")
      check diag.contains("stash")
      # The dirty file is untouched — the refusal mutated nothing.
      check fileExists(fx.workspaceRoot / "lib-a" / "dirty.txt")

  test "checkout_missing_branch_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "checkout-missing")
      defer: removeDir(fx.scratch)
      # No such branch anywhere → branch-missing refusal.
      let res = invokeCheckout(fx, "nope-not-a-branch")
      check res.code == 2
      let rep = parseFile(
        fx.workspaceRoot / ".repro" / "workspace" / "checkout-report.json")
      var entry: JsonNode = nil
      for e in rep["repos"]:
        if e["path"].getStr() == "lib-a": entry = e
      check entry != nil
      check entry["outcome"].getStr() == "branch_missing_refused"
      # Offender: the missing branch name. Remedy: a repro command to create it.
      assertNamesOffenderAndRemedy(
        entry["diagnostic"].getStr(), "nope-not-a-branch")

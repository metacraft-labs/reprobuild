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
##   - switch-dirty          ``repro switch`` of a dirty repo refused by the
##                           RA-9 destructive-switch gate (non-TTY, no
##                           ``--yes``). RA-29 stashes a dirty repo's WIP rather
##                           than refusing it, so the offending act is the
##                           working-tree switch the gate guards; the remedy is
##                           ``repro switch <branch> --yes``.
##   - switch-missing        ``repro switch`` of an absent branch.
##   - remove-workspace-root ``repro remove`` of a repo declared at
##                           ``path = "."``. Both routes in — NAMED as the
##                           target, and swept into the RA-22 GC set through
##                           another target's ``depends`` closure.
##   - remove-workspace-root-remedy  the same refusal on the FLAT membership
##                           layout, where the remedy is a real command
##                           (``repro workspace repos remove <fragment>``).
##                           The case RUNS what the refusal printed and
##                           asserts the declaration went and the tree
##                           stayed — a quoted remedy that does not work is
##                           worse than none. On the ``.repro/manifests``
##                           layout the verb cannot reach the file, so the
##                           refusal falls back to naming the file, the key
##                           and the entry, which the case above asserts.
##   - disable-workspace-root ``repro workspace disable`` of a project that
##                           declares the workspace root repo.
##   - develop-lock-path     ``repro develop --all`` against a committed
##                           ``repro.lock`` whose dependency ``path``
##                           resolves to the workspace root.
##
## The last three arrived with W5 and are the reason this file grew: each
## stands in front of a recursive delete that would have taken the workspace,
## and the first shape of all three said only that something "is not beneath
## the workspace root" — in one case printing the SAME PATH TWICE either side
## of that phrase, with no repo named and no remedy. A guard whose refusal
## teaches nothing sends the operator looking for a way around it.
##
## ``repro sync --force-sync`` on the workspace root is deliberately NOT in
## this list. It is no longer a refusal: ``git reset --hard`` is bounded by
## git's tracked set and is in bounds there, so the reset runs and only the
## ``git clean -ffdx`` half is skipped. It reports a PARTIAL success with the
## same offender+remedy pairing, asserted in
## ``t_checkout_path_cannot_escape_the_workspace_root`` where the surviving
## files are asserted alongside it.
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
  ## `doAssert`, not `quit`: this is a HELPER, called from fixture builders
  ## outside any `test` body. `quit 1` tears the whole binary down and takes
  ## every case after it with it, reporting nothing about which one was
  ## running. `doAssert` raises, and the `test` template's own
  ## `except Exception` attributes the failure to the case that caused it,
  ## from any call depth.
  let res = runCmd(command, cwd)
  doAssert res.code == 0,
    "command failed: " & command & "\nexit=" & $res.code & "\n" & res.output
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
  let manifestsRoot = workspaceRoot / ".repro" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlSingle(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.manifestsRoot = manifestsRoot
  result.workspaceRoot = workspaceRoot
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

const wsRootFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "ws-root"
path = "."
remote = "lib-a-origin"
revision = "main"
"""

proc projectTomlWithWorkspaceRoot(libAUrl: string): string =
  ## A project that declares the workspace ROOT repo (``path = "."``) beside
  ## an ordinary checkout. ``lib-a`` depends on ``ws-root``, which is what
  ## sweeps the root into ``repro remove lib-a``'s RA-22 GC candidate set
  ## without anyone naming it.
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/ws-root.toml\",\n  \"repos/lib-a.toml\",\n]\n"

const libADependsOnRootToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
depends = ["ws-root"]
"""

proc declareWorkspaceRootRepo(fx: Fixture) =
  writeFile(fx.manifestsRoot / "repos" / "ws-root.toml", wsRootFragmentToml)
  writeFile(fx.manifestsRoot / "repos" / "lib-a.toml", libADependsOnRootToml)
  writeFile(fx.manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWithWorkspaceRoot(fileUrl(fx.libAOrigin)))

proc nativeLayoutFixture(gitBin, slug: string): Fixture =
  ## The OTHER workspace layout, and the reason it is worth a fixture of its
  ## own here: membership lives FLAT at the workspace root
  ## (`<ws>/projects/*.toml` + `<ws>/repos/*.toml`, the `<org>/repro-workspace`
  ## repo), not in a materialized checkout under `.repro/manifests`.
  ## `manifestsRoot` accepts both; `repro workspace repos remove` reads
  ## `manifestRepoRootFor`, which is the workspace root ONLY — so the
  ## authoring verb can reach this layout and not the other one. That
  ## difference is exactly what the `repro remove` remedy has to be honest
  ## about, so both layouts are exercised.
  ##
  ## The root is a real git checkout because `repro workspace repos remove`
  ## COMMITS the membership edit it makes; a plain directory would refuse.
  result.scratch = createTempDir("repro-ra28-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASeed = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, result.libASeed)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "lib-a.toml",
    projectTomlWithWorkspaceRoot(fileUrl(result.libAOrigin)))
  writeFile(workspaceRoot / "repos" / "ws-root.toml", wsRootFragmentToml)
  writeFile(workspaceRoot / "repos" / "lib-a.toml", libADependsOnRootToml)
  writeFile(workspaceRoot / "PRECIOUS.txt", "must survive\n")
  result.manifestsRoot = workspaceRoot
  result.workspaceRoot = workspaceRoot
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

  discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.name \"RA28 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " add projects repos PRECIOUS.txt")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m \"seed native membership\"")

proc seedManifestGitLayer(gitBin: string; fx: var Fixture) =
  ## Make ``.repro/manifests`` a real git checkout tracking a bare upstream so
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
    fx.reproBin, "check", "--mode=pre-push", "--write-report",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a"),
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc invokeSync(fx: Fixture; project = "lib-a"): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "--write-report", project,
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeCheckout(fx: Fixture; branch: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "switch", "--write-report", branch,
    "--workspace-root=" & fx.workspaceRoot, "--json",
  ]))

proc invokeRemove(fx: Fixture; target: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "remove", target,
    "--workspace-root=" & fx.workspaceRoot,
  ]))

# ---- report readers -------------------------------------------------------

proc checkReport(fx: Fixture): JsonNode =
  parseFile(fx.workspaceRoot / ".repro" / "build" / "reports" / "check-report.json")

proc syncReport(fx: Fixture): JsonNode =
  parseFile(fx.workspaceRoot / ".repro" / "build" / "reports" / "sync-report.json")

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
      # An unreadable NEW repo does not ABORT the run, but it does FAIL it —
      # the workspace is missing a declared repo (CLI/sync.md exit `1`).
      check res.code == 1
      let report = syncReport(fx)
      var entry: JsonNode = nil
      for e in report["repos"]:
        if e["path"].getStr() == "lib-b": entry = e
      check entry != nil
      check entry["executionStatus"].getStr() == "clone_failed"
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
        fx.workspaceRoot / ".repro" / "build" / "reports" / "switch-report.json")
      var entry: JsonNode = nil
      for e in rep["repos"]:
        if e["path"].getStr() == "lib-a": entry = e
      check entry != nil
      check entry["outcome"].getStr() == "confirm_refused"
      # RA-28: the per-repo refusal diagnostic must NAME the offender (lib-a,
      # whose dirty working tree would be switched and whose WIP would be
      # stashed) AND a copy-pasteable remedy command (``repro switch … --yes``).
      let diag = entry["diagnostic"].getStr()
      assertNamesOffenderAndRemedy(diag, "lib-a")
      check diag.contains("--yes")
      check diag.contains("stash")
      # The dirty file is untouched — the refusal mutated nothing.
      check fileExists(fx.workspaceRoot / "lib-a" / "dirty.txt")

  test "remove_workspace_root_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "remove-wsroot")
      defer: removeDir(fx.scratch)
      declareWorkspaceRootRepo(fx)

      # Route 1: NAMED as the target. The whole verb refuses and nothing is
      # mutated — a GC that silently skipped the delete would still drop the
      # include and still print a removal line, telling the operator a repo
      # was removed while its tree stayed.
      let named = runShell(shellCommand(@[
        fx.reproBin, "remove", "ws-root", "--force",
        "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("repro remove ws-root: " & named.output)
      check named.code == 1
      # RA-28: the offender is the REPO the operator named, not the string
      # `.`; the remedy is the one that exists — the declaration can be
      # dropped without the delete.
      assertNamesOffenderAndRemedy(named.output, "ws-root")
      check named.output.contains("Remedy:")
      check named.output.contains("repro sync")
      check named.output.contains("IS the workspace root")
      # This fixture's membership lives in a materialized manifest CHECKOUT
      # (`.repro/manifests`), which `repro workspace repos remove` cannot
      # reach — it reads `manifestRepoRootFor`, the workspace root itself. So
      # the remedy here is the fallback, and the whole point of the fallback
      # is that it is EXACT: the file, the key, and the entry to delete from
      # it. "Edit the manifest" is what this replaced.
      check named.output.contains(
        fx.manifestsRoot / "projects" / "lib-a.toml")
      check named.output.contains("`includes`")
      check named.output.contains("\"repos/ws-root.toml\"")
      # ...and it says WHY the command is not offered, rather than leaving
      # the operator to discover that it no-ops.
      check named.output.contains("repro workspace repos remove")
      # Nothing was mutated.
      check dirExists(fx.workspaceRoot / "lib-a" / ".git")
      check fileExists(fx.manifestsRoot / "projects" / "lib-a.toml")

      # Route 2: SWEPT INTO the GC set through ``lib-a``'s ``depends``
      # closure. Only the root's own delete is skipped; the removal the
      # operator actually asked for still happens.
      let swept = runShell(shellCommand(@[
        fx.reproBin, "remove", "lib-a", "--force",
        "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("repro remove lib-a: " & swept.output)
      check swept.code == 1
      assertNamesOffenderAndRemedy(swept.output, "ws-root")
      check swept.output.contains("Remedy:")
      # The targeted removal went through, so the refusal is proven targeted
      # rather than the command merely failing early.
      check not dirExists(fx.workspaceRoot / "lib-a")
      # ...and the workspace itself is intact.
      check dirExists(fx.manifestsRoot / "repos")

  test "remove_workspace_root_remedy_is_a_runnable_command":
    ## RA-28's second half, taken literally: the remedy has to be a COMMAND.
    ##
    ## `repro remove <root-repo>` refuses, correctly — the delete would take
    ## the workspace. What it then tells the operator to do used to be "delete
    ## the `includes` entry for ws-root.toml in <projectFile> and run `repro
    ## sync`", which is an instruction to hand-edit a TOML array. That is not
    ## a remedy command, it is a work item; Interactive-UX-And-Progress.md
    ## Principle 2 asks for something the operator can paste.
    ##
    ## One exists — `repro workspace repos remove <fragment>` drops the
    ## include edge from every membership that declares the fragment and
    ## states, in its own words, that "any existing checkout was left on
    ## disk", which is precisely the half of `repro remove` that is in bounds
    ## here. This case does not merely assert that the string is printed: it
    ## RUNS what the refusal printed and asserts the outcome, because a
    ## remedy that is quoted but does not work is worse than none.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = nativeLayoutFixture(gitBin, "remove-wsroot-cmd")
      defer: removeDir(fx.scratch)

      let refused = runShell(shellCommand(@[
        fx.reproBin, "remove", "ws-root", "--force",
        "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("repro remove ws-root: " & refused.output)
      check refused.code == 1
      assertNamesOffenderAndRemedy(refused.output, "ws-root")
      check refused.output.contains("IS the workspace root")
      # The remedy, verbatim and copy-pasteable.
      check refused.output.contains("repro workspace repos remove ws-root")
      check refused.output.contains("leaves the checkout on disk")
      check refused.output.contains("repro sync")
      # Nothing was mutated by the refusal itself.
      check fileExists(fx.workspaceRoot / "repos" / "ws-root.toml")
      check fileExists(fx.workspaceRoot / "PRECIOUS.txt")

      # Now RUN it. This is the assertion that separates a remedy from a
      # sentence.
      let remedy = runShell(shellCommand(@[
        fx.reproBin, "workspace", "repos", "remove", "ws-root",
        "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("repro workspace repos remove ws-root: " & remedy.output)
      check remedy.code == 0
      # The DECLARATION is gone...
      let projectAfter = readFile(fx.workspaceRoot / "projects" / "lib-a.toml")
      checkpoint("project after: " & projectAfter)
      check not projectAfter.contains("repos/ws-root.toml")
      check projectAfter.contains("repos/lib-a.toml")
      # ...and the TREE is not. That is the whole reason this command is the
      # right remedy and `repro remove` is not.
      check fileExists(fx.workspaceRoot / "PRECIOUS.txt")
      check readFile(fx.workspaceRoot / "PRECIOUS.txt") == "must survive\n"
      check dirExists(fx.workspaceRoot / ".git")
      check dirExists(fx.workspaceRoot / "lib-a" / ".git")

  test "disable_workspace_root_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "disable-wsroot")
      defer: removeDir(fx.scratch)
      declareWorkspaceRootRepo(fx)
      # ``disable`` refuses to record an EMPTY active set, so a second
      # project has to stay enabled for the removal loop to be reached at
      # all — and the removal loop is what is under test.
      writeFile(fx.manifestsRoot / "projects" / "keeper.toml",
        projectTomlSingle(fileUrl(fx.libAOrigin)).replace(
          "name = \"lib-a\"", "name = \"keeper\""))
      writeWorkspaceProjects(fx.workspaceRoot, @["lib-a", "keeper"])

      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "disable", "lib-a", "--force",
        "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("repro workspace disable lib-a: " & res.output)
      check res.code == 1
      # The offender here is the resolved DIRECTORY: `.` on its own says
      # nothing, and the operator needs to know which tree survived. The
      # remedy is the command that shows what is in it before anyone deletes
      # it by hand.
      assertNamesOffenderAndRemedy(res.output, fx.workspaceRoot)
      check res.output.contains("IS the workspace root")
      check res.output.contains("git -C ")
      check res.output.contains("left in place")
      check dirExists(fx.manifestsRoot / "projects")

  test "develop_degenerate_lock_path_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # A committed-lock-only workspace: no manifest checkout, so
      # ``resolveWorkspaceLockedDeps`` routes it to the committed lock — the
      # plane that had no boundary at all before W5.
      let scratch = createTempDir("repro-ra28-developlock-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let depOrigin = scratch / "origin-dep.git"
      let depSha = seedGitOrigin(gitBin, depOrigin, scratch / "seed-dep")
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      writeFile(workspaceRoot / "repro.lock",
        "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
        "[lock]\nplatform = \"amd64-linux\"\noptimal = false\n" &
        "inputs_digest = \"fnv1a64:0000000000000000\"\n" &
        "variants = []\npackages = []\n" &
        "deps = [{ name = \"dep\", path = \"./.\", coord_kind = \"vcs\", " &
        "url = \"" & fileUrl(depOrigin) & "\", ref = \"main\", " &
        "revision = \"" & depSha & "\", integrity = \"git-sha1:" & depSha &
        "\", version = \"\", visibility = \"public\", " &
        "participation = \"\", depends = \"\", groups = \"\" }]\n")

      let res = runShell(shellCommand(@[
        reproBin, "develop", "--all", "--reset",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("repro develop --all --reset: " & res.output)
      check res.code == 1
      # The offender is the dependency AND the value that made it
      # undeliverable; the remedy is the command that rewrites the lock,
      # because a lock is machine-written and "edit it" is not an
      # instruction.
      assertNamesOffenderAndRemedy(res.output, "dep")
      check res.output.contains("'./.'")
      check res.output.contains("repro lock refresh")

  test "checkout_missing_branch_names_offender_and_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = baseFixture(gitBin, "switch-missing  ")
      defer: removeDir(fx.scratch)
      # No such branch anywhere → branch-missing refusal.
      let res = invokeCheckout(fx, "nope-not-a-branch")
      check res.code == 2
      let rep = parseFile(
        fx.workspaceRoot / ".repro" / "build" / "reports" / "switch-report.json")
      var entry: JsonNode = nil
      for e in rep["repos"]:
        if e["path"].getStr() == "lib-a": entry = e
      check entry != nil
      check entry["outcome"].getStr() == "branch_missing_refused"
      # Offender: the missing branch name. Remedy: a repro command to create it.
      assertNamesOffenderAndRemedy(
        entry["diagnostic"].getStr(), "nope-not-a-branch")

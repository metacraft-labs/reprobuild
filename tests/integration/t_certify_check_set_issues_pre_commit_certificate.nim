## Agents-Push-Gate.md §3.2 / §4.4 (Sovereign-CI-Fleet P6.e) —
## `repro certify --check-set` runs a repository's pre-commit check set as the
## certifiable target `pre-commit`, through the ordinary issuance path, and
## delivers the result to the local certificate store. It writes no git note:
## the managed pre-push hook publishes one when the content is pushed.
##
##   1. A FAILING check set issues nothing and exits 2.
##   2. A PASSING check set on a clean, committed, UNPUBLISHED head issues a
##      signed certificate covering `pre-commit` into the local certificate
##      store, under the content id of the TREE it names, and leaves the
##      repository CLEAN (the run's files go to a scratch directory, never the
##      repo), with no notes ref.
##   3. Re-running is idempotent: no second certificate is stored for the
##      content.
##   4. TC-8d: a MODIFIED, uncommitted working tree is certified by its
##      content (no clean, committed state is needed) and stored under the
##      content id that state has.
##
## Falsifiability: a certify that ignored the run's result would issue in (1);
## a certify that wrote its fixture or logs into the repo would fail the
## cleanliness check in (2); a certify that stored by something other than the
## content would leave two certificates in (3); one that wrote a note fails the
## notes-ref check in (2), (3) and (4).
##
## The check-set command is passed with `--check-set-command`, so the test
## does not depend on prek being installed; the default (`prek run
## --all-files` over the committed `.pre-commit-config.yaml`) differs only in
## the argv the certificate records.
## Hermetic: local repos, the built `repro`; no network, no mocks.
## Skip rule: `git` or `ssh-keygen` missing on PATH.

import repro_test_support/reasoned_skip
import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

include tc5_cert_signing_helpers

const tc6KeyId = "tc6-daemon-key"

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

proc seedGitUpstream(gitBin, upstreamPath, workPath: string;
                     branch = "main"): string =
  ## Seed the REAL upstream bare with an initial commit, then return its SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(upstreamPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"TC6 Seeder\"")
  writeFile(workPath / "README.md", "TC-6 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(upstreamPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, upstreamPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(upstreamPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"TC6 Tester\"")

proc projectToml(libAUrl, certificatesTable: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "\n" &
  certificatesTable &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    upstreamBare: string   ## the REAL upstream (stands in for GitHub)
    gatewayBare: string    ## the daemon-managed gateway bare
    libAPath: string       ## the developer's clone
    seedSha: string
    daemonKey: string
    certStore: string

proc setupFixture(gitBin, certificatesTable: string): Fixture =
  result.scratch = createTempDir("repro-tc6-", "")
  result.certStore = isolateCertificateStore(result.scratch)
  result.reproBin = reproBinary()
  result.upstreamBare = result.scratch / "upstream-lib-a.git"
  result.gatewayBare = result.scratch / "gateway-lib-a.git"
  result.seedSha = seedGitUpstream(gitBin, result.upstreamBare,
    result.scratch / "seed-lib-a")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(result.upstreamBare), certificatesTable))
  result.workspaceRoot = workspaceRoot
  seedManifestLockStore(gitBin, workspaceRoot)
  result.libAPath = workspaceRoot / "lib-a"
  cloneInto(gitBin, result.upstreamBare, result.libAPath)
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

  let key = genEd25519Key(result.scratch / "daemon-keys", "tc6-key", tc6KeyId)
  result.daemonKey = key.priv
  writeRegistry(workspaceRoot,
    @[RegisteredKey(keyId: tc6KeyId, publicKey: key.pub, status: rksActive)])

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0:
    checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc writeTestFixtureJson(path, selector, scriptCmd: string) =
  var obj = newJObject()
  obj["fallbackBuildCostNs"] = %1
  obj["fallbackTestCostNs"] = %1
  var edges = newJArray()
  var e = newJObject()
  e["id"] = %1
  e["selector"] = %selector
  e["historyKey"] = %selector
  e["buildDeps"] = newJArray()
  var cmd = newJArray()
  cmd.add(%"sh"); cmd.add(%"-c"); cmd.add(%scriptCmd)
  e["runCmd"] = cmd
  e["testName"] = %selector
  edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc makeNewCommit(gitBin: string; fx: Fixture; content: string): string =
  ## Make a NEW commit in the developer clone (so HEAD differs from the seed
  ## already on the upstream). This is the commit the developer tries to push.
  writeFile(fx.libAPath / "feature.txt", content)
  discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) & " add feature.txt")
  discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
    " commit -m feature")
  result = requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
    " rev-parse HEAD").strip()

proc publishDirectly(gitBin: string; fx: Fixture) =
  ## Publish the clone's current HEAD directly to the upstream bare (bypassing
  ## the gateway). TC-1 issuance refuses to certify an UNPUBLISHED commit (it
  ## reuses the pre-push gate's published check against ``origin`` = the
  ## fetch/upstream URL), so the cert can only be minted once HEAD is on
  ## upstream. We publish here, mint the cert, then REWIND the upstream back to
  ## the seed (``rewindUpstreamToSeed``) so the gateway forward in (b)
  ## genuinely ADVANCES the upstream from seed → the covered commit — a faithful
  ## "covered push lands on the upstream" assertion rather than a no-op.
  let res = runCmd(q(gitBin) & " -C " & q(fx.libAPath) &
    " push " & q(fileUrl(fx.upstreamBare)) & " main")
  if res.code != 0:
    checkpoint("direct publish failed: " & res.output)
  check res.code == 0
  # Update the ``origin/main`` remote-tracking ref so issuance's published
  # check (``git branch -r --contains HEAD`` → ``origin/...``) sees HEAD as
  # published. ``origin``'s FETCH url is the upstream, so a fetch advances the
  # tracking ref to the just-published commit.
  let fetched = runCmd(q(gitBin) & " -C " & q(fx.libAPath) & " fetch origin")
  if fetched.code != 0:
    checkpoint("fetch origin failed: " & fetched.output)
  check fetched.code == 0

proc rewindUpstreamToSeed(gitBin: string; fx: Fixture) =
  discard requireGit(q(gitBin) & " -C " & q(fx.upstreamBare) &
    " update-ref refs/heads/main " & q(fx.seedSha))

proc upstreamHasCommit(gitBin, upstreamBare, sha: string): bool =
  ## True iff the REAL upstream bare contains ``sha`` as a reachable object on
  ## its branch (``git cat-file -e`` + the branch actually points there).
  let exists = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " cat-file -e " & q(sha & "^{commit}"))
  if exists.code != 0:
    return false
  let tip = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " rev-parse refs/heads/main")
  tip.code == 0 and tip.output.strip() == sha


proc certifyCheckSet(fx: Fixture; command: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "certify", "--check-set",
    "--check-set-command=" & command,
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath],
    daemonKeyEnv(fx.daemonKey, tc6KeyId)), fx.libAPath)

proc hasLocalNotes(gitBin: string; fx: Fixture): bool =
  ## Whether the clone has a certificate notes ref: issuance must not make one.
  runCmd(q(gitBin) & " -C " & q(fx.libAPath) & " rev-parse --verify --quiet " &
    q(certificateNotesRef)).code == 0

suite "P6.e — repro certify --check-set":

  test "t_certify_check_set_issues_pre_commit_certificate":
    let gitBin = findExe("git")
    if gitBin.len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this case signs a certificate in a repository")
    else:
      let fx = setupFixture(gitBin, "")
      defer: removeDir(fx.scratch)
      let head = makeNewCommit(gitBin, fx, "change under check\n")
      seedLock(fx)
      let content = treeContentId(gitBin, fx.libAPath, head)

      # ---- 1. a failing check set issues nothing --------------------------
      let failing = certifyCheckSet(fx, "echo 'lint: bad file' >&2; exit 3")
      checkpoint("failing: " & failing.output)
      check failing.code == 2
      check storedCertificateFiles(fx.certStore, content).len == 0
      check not hasLocalNotes(gitBin, fx)

      # ---- 2. a passing check set issues, signs, stores --------------------
      let passing = certifyCheckSet(fx, "true")
      checkpoint("passing: " & passing.output)
      check passing.code == 0
      let files = storedCertificateFiles(fx.certStore, content)
      check files.len == 1
      if files.len == 1:
        let cert = readCertificateFile(files[0])
        check cert.vcs.base == head
        check cert.vcs.content == content
        check cert.targets == @["pre-commit"]
        check cert.isSigned
        check cert.commands.len == 1
      check not hasLocalNotes(gitBin, fx)
      let status = runCmd(q(gitBin) & " -C " & q(fx.libAPath) &
        " status --porcelain --untracked-files=all")
      check status.code == 0
      check status.output.strip() == ""
      # Certifying published nothing.
      check not upstreamHasCommit(gitBin, fx.upstreamBare, head)

      # ---- 3. idempotent ----------------------------------------------------
      let again = certifyCheckSet(fx, "true")
      check again.code == 0
      check storedCertificateFiles(fx.certStore, content).len == 1
      check not hasLocalNotes(gitBin, fx)

      # ---- 4. TC-8d: an uncommitted working tree is certified ---------------
      # No clean, committed state is needed: the modified tree is certified by
      # its content, before any commit records it.
      writeFile(fx.libAPath / "feature.txt", "edited, not committed\n")
      let modified = workingTreeContentIdOf(gitBin, fx.libAPath,
        fx.scratch / "expected-index")
      check modified != content
      let uncommitted = certifyCheckSet(fx, "true")
      checkpoint("uncommitted: " & uncommitted.output)
      check uncommitted.code == 0
      let modifiedFiles = storedCertificateFiles(fx.certStore, modified)
      check modifiedFiles.len == 1
      if modifiedFiles.len == 1:
        let cert = readCertificateFile(modifiedFiles[0])
        check cert.vcs.content == modified
        check cert.vcs.base == head
        check cert.targets == @["pre-commit"]
      check not hasLocalNotes(gitBin, fx)

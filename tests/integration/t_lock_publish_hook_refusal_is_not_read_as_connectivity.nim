## D2 — a LOCAL HOOK REFUSAL of the lock-publication push must not be reported
## as a connectivity/credentials fault, and its evidence must not be withheld.
##
## ``publishVerifiedLockState`` pushes the lock-record backend repository
## (``.repro/manifests``) to its upstream. That repository carries hooks of its
## own, so the push can be refused LOCALLY, before a byte of transport happens.
## When it was, the publisher printed one sentence over every non-fast-forward-
## shaped failure there is:
##
##   git push origin HEAD:latest failed; verified local lock-only commit
##   retained; check backend connectivity, credentials, and branch policy
##
## and DISCARDED the child's transcript, on the stated grounds that "remotes
## may contain credentials". In the field the cause was the backend repo's own
## managed ``pre-push`` hook refusing; it had printed
## ``repro check: error: ...`` and ``repro hooks: ...`` lines naming the reason
## exactly, and they were thrown away. Hours went into a network that was never
## down.
##
## Required behaviour (Interactive-UX-And-Progress.md Principle 2 — every
## failure teaches the remedy; Workspace-And-Develop-Mode.md attribution — no
## diagnostic may be read as coming from a cause that did not produce it):
##
##   1. Classify before composing. A transcript carrying ``repro check:`` /
##      ``repro hooks:`` lines came from the backend repo's own managed hook;
##      say so and quote those lines verbatim as the cause.
##   2. Reserve the connectivity/credentials wording for a transcript that is
##      neither non-fast-forward-shaped nor a hook refusal.
##   3. Do not drop the stream to protect credentials. The credential concern
##      is about URLs: redact URL userinfo (``https://user:token@host/...``)
##      and pass the rest through.
##
## HOW THIS DRIVES IT — REAL BOUNDARIES ONLY. The fixture is the RA-21 /
## RA-29 one: real ``git init`` / ``git init --bare`` repos, a real workspace
## whose ``.repro/manifests`` layer is a real git checkout tracking a real bare
## upstream, and the real ``repro`` binary invoked as the real pre-push gate,
## which genuinely attempts the publication push. Nothing is mocked: no
## filesystem shim, no git shim, no injected push result.
##
## The one stand-in, and why it is not a mock of a boundary under test: the
## refusing hook is a REAL executable ``pre-push`` hook installed in the
## backend repository's own ``.git/hooks`` (the same vehicle
## ``t_concurrent_lock_publishes_retry_without_user_visible_failure`` uses to
## stage a real push race), which writes the exact prefixed lines Reprobuild's
## managed hook writes and exits non-zero. Git runs it, the push genuinely
## fails, and the publisher sees exactly the bytes the field failure produced.
## Installing the managed bundle itself instead would change nothing on the
## code path under test — the branch reads only the push transcript, never the
## hook's identity — while additionally requiring the manifest store to be a
## workspace with a gate of its own.
##
## Cases:
##   A. Hook refuses with ``repro check:`` / ``repro hooks:`` lines. The
##      ``lock-publish-failure`` evidence must name the HOOK refusal, quote the
##      refusal text, and must NOT carry the connectivity/credentials sentence.
##      A credential-bearing URL in the hook's own output must survive as its
##      host+path with the userinfo redacted — proving the stream is passed
##      through rather than dropped, and that the secret still does not leak.
##   B. Control for clause 2: the same real refusal with NON-Reprobuild output.
##      The connectivity/credentials wording is retained (it is a cause this
##      publisher genuinely cannot attribute) and the diagnostic must NOT claim
##      a managed-hook refusal.
##   C. Control for the fixture: with NO hook the same gate PASSES and
##      publishes, so the refusals above are caused by the hook, not the
##      fixture.
##
## Falsifiable: against the pre-fix publisher, case A's evidence is the
## connectivity sentence with no hook attribution and no refusal text, so its
## assertions fail.
##
## Hermetic: only local repos; no network. Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

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
    " config user.name \"D2 Tester\"")
  writeFile(workPath / "README.md", "D2 hook-refusal fixture\n")
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
    " config user.name \"D2 Tester\"")

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

proc seedManifestGitLayer(gitBin, manifestsRoot, bare: string;
                          branch = "main") =
  ## Make ``.repro/manifests`` a real git checkout that TRACKS a bare upstream,
  ## so the pre-push gate genuinely attempts a publication push.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.name \"D2 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin " & branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-d2-hookrefusal-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  let seedPath = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repro" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith1Remote(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.manifestsRoot = manifestsRoot
  result.manifestBare = result.scratch / "manifest.git"
  seedManifestGitLayer(gitBin, manifestsRoot, result.manifestBare)
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  result.workspaceRoot = workspaceRoot
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
  # MO-14 — central lock publication is opt-in, and this test asserts on the
  # PUBLICATION push, so the workspace opts in.
  writeFile(workspaceRoot / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\n" &
    "url = \"" & fileUrl(result.manifestBare) & "\"\n" &
    "branch = \"main\"\n" &
    "publish_locks = true\n")

# The credential-bearing remote a forge's CI helper writes into a git config.
# It appears in the REFUSING HOOK's own output, which is where the pre-fix
# code's "remotes may contain credentials" rationale pointed — so the fix has
# to keep the secret out while still teaching the host and path.
const
  secretToken = "ghp_D2EXAMPLESECRETTOKEN0000"
  credentialUrl = "https://x-access-token:" & secretToken &
    "@forge.example.invalid/acme/manifests.git"
  refusalReason = "repo cairo has unpublished commits"

proc installRefusingPrePushHook(fx: Fixture; lines: seq[string]) =
  ## A REAL executable ``pre-push`` hook in the backend repository. Git runs
  ## it, it writes ``lines`` to stderr, and it exits non-zero — so the
  ## publication push genuinely fails with exactly those bytes in its
  ## transcript (``gitRunPlainEnv`` folds stderr into stdout).
  let hookDir = fx.manifestsRoot / ".git" / "hooks"
  createDir(hookDir)
  let hook = hookDir / "pre-push"
  var body = "#!/bin/sh\n"
  for line in lines:
    body.add("echo " & q(line) & " >&2\n")
  body.add("exit 1\n")
  writeFile(hook, body)
  setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})

proc writeRefsFile(path: string; localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeCheckPrePush(fx: Fixture; refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push", "--write-report",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a"),
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc publishFailureEvidence(report: JsonNode): string =
  for f in report["failures"]:
    if f["property"].getStr() == "lock-publish-failure":
      return f["evidence"].getStr()
  ""

const connectivitySentence =
  "check backend connectivity, credentials, and branch policy"

suite "D2 — a lock-publish hook refusal is not read as connectivity":

  test "t_lock_publish_hook_refusal_is_not_read_as_connectivity":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — this case builds real repositories, a real " &
        "backend checkout with a real pre-push hook, and a real push")
    else:
      # ---- Case A: the backend repo's own managed hook refuses ----------
      let fx = setupFixture(gitBin, "managed")
      defer: removeDir(fx.scratch)
      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)
      installRefusingPrePushHook(fx, @[
        "repro check: error: " & refusalReason,
        "repro check: error: the record would be filed against " &
          credentialUrl,
        "repro hooks: refusal produced by /usr/bin/repro (resolved via PATH)",
      ])

      let res = invokeCheckPrePush(fx, refsFile)
      checkpoint("hook-refusal output: " & res.output)
      # RA-21 stays intact: a publication that could not happen refuses the
      # push.
      check res.code != 0
      let report = readReport(fx)
      check report["exitCode"].getInt() != 0
      let evidence = publishFailureEvidence(report)
      checkpoint("lock-publish-failure evidence: " & evidence)
      check evidence.len > 0

      # 1. The cause is attributed to the HOOK, and the hook's own words are
      #    the evidence — not paraphrased, not withheld.
      check evidence.toLowerAscii().contains("managed hooks")
      check evidence.contains(refusalReason)
      check evidence.contains("repro hooks: refusal produced by")

      # 2. The connectivity/credentials wording is NOT applied to a cause that
      #    did not produce it. This is the assertion the pre-fix publisher
      #    fails: it emitted exactly this sentence here.
      check not evidence.contains(connectivitySentence)

      # 3. The stream is passed through, and the credential concern is handled
      #    where it actually lives — the URL's userinfo.
      check not evidence.contains(secretToken)
      check not evidence.contains("x-access-token")
      check evidence.contains("<redacted>@forge.example.invalid/acme/" &
        "manifests.git")

      # ---- Case B: a refusal this publisher genuinely cannot attribute ---
      # Control for clause 2: the SAME real boundary, refusing with output
      # that is neither non-fast-forward-shaped nor Reprobuild's. The
      # connectivity/credentials wording is correct here and must survive.
      let fxB = setupFixture(gitBin, "opaque")
      defer: removeDir(fxB.scratch)
      let refsFileB = fxB.scratch / "pushed-refs.txt"
      writeRefsFile(refsFileB, fxB.libASha)
      installRefusingPrePushHook(fxB, @[
        "corporate-policy-hook: pushes are disabled on this host",
      ])

      let resB = invokeCheckPrePush(fxB, refsFileB)
      checkpoint("opaque-refusal output: " & resB.output)
      check resB.code != 0
      let evidenceB = publishFailureEvidence(readReport(fxB))
      checkpoint("opaque evidence: " & evidenceB)
      check evidenceB.contains(connectivitySentence)
      check not evidenceB.toLowerAscii().contains("managed hooks")
      # Clause 3 applies here too: the transcript teaches, rather than being
      # replaced by a guess.
      check evidenceB.contains(
        "corporate-policy-hook: pushes are disabled on this host")

      # ---- Case C: control for the fixture ------------------------------
      # With NO hook the identical gate PASSES and publishes, so the two
      # refusals above are caused by the hook, not by the fixture.
      let fxC = setupFixture(gitBin, "clean")
      defer: removeDir(fxC.scratch)
      let refsFileC = fxC.scratch / "pushed-refs.txt"
      writeRefsFile(refsFileC, fxC.libASha)
      let resC = invokeCheckPrePush(fxC, refsFileC)
      checkpoint("no-hook output: " & resC.output)
      check resC.code == 0
      let reportC = readReport(fxC)
      check reportC["exitCode"].getInt() == 0
      check publishFailureEvidence(reportC).len == 0
      let ls = runCmd(q(gitBin) & " -C " & q(fxC.manifestBare) &
        " ls-tree -r --name-only refs/heads/main")
      check ls.code == 0
      check ls.output.contains("locks/lib-a/lib-a/")

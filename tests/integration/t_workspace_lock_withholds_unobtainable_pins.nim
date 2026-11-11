## An explicit ``repro workspace lock`` publishes only records whose pins
## other people can obtain.
##
## The command commits and pushes its lock record to the record store's
## upstream, and CI sibling resolution then fetches every revision that record
## pins. A pin on a commit that exists only in this workspace makes that fetch
## fail on someone else's machine. So a record pinning a revision that no
## remote-tracking ref reaches -- the predicate the pre-push gate's
## ``unpublished`` stage applies -- is withheld from publication: it stays in
## the store as a local draft, the command names the repo and the push that
## fixes it, and it never claims to have published it.
##
##   (a) the trigger repo has a commit that was never pushed → the record is
##       written locally, is NOT in the store's upstream, and the output names
##       the repo and the remedy instead of "published verified";
##   (b) a non-trigger sibling has a commit that was never pushed → same;
##   (c) once the commit is pushed, the next ``repro workspace lock``
##       publishes the record.
##
## Falsifiability: drop the withholding in ``runWorkspaceLockCommand`` and (a)
## and (b) fail, because the record reaches the store's upstream.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no network.

import std/[os, osproc, strutils, tempfiles, unittest]

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configureIdentity(gitBin, path: string) =
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Lock Pin Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  configureIdentity(gitBin, workPath)
  writeFile(workPath / "README.md", "fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

proc commitLocally(gitBin, repoPath, fileName: string): string =
  ## One commit that is never pushed; returns its SHA.
  writeFile(repoPath / fileName, "local only\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add " & q(fileName))
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"local only\"")
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc projectToml(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
mainline = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    storeRoot: string
    storeOrigin: string
    libAPath: string
    libBPath: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-lock-pins-" & slug & "-", "")
  result.reproBin = reproBinary()
  let libAOrigin = result.scratch / "origin-lib-a.git"
  let libBOrigin = result.scratch / "origin-lib-b.git"
  seedGitOrigin(gitBin, libAOrigin, result.scratch / "seed-lib-a")
  seedGitOrigin(gitBin, libBOrigin, result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  result.workspaceRoot = workspaceRoot
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(libAOrigin), fileUrl(libBOrigin)))
  writeFile(workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(workspaceRoot / "repos" / "lib-b.toml", libBFragmentToml)

  # The record store: a git checkout whose upstream is a local bare repo, so
  # the explicit lock has somewhere to publish and nothing leaves the machine.
  result.storeOrigin = result.scratch / "store-origin.git"
  discard requireGit(q(gitBin) & " init --bare -b main " &
    q(result.storeOrigin))
  result.storeRoot = workspaceRoot / ".repro" / "manifests"
  createDir(result.storeRoot)
  discard requireGit(q(gitBin) & " init -b main " & q(result.storeRoot))
  configureIdentity(gitBin, result.storeRoot)
  writeFile(result.storeRoot / ".gitkeep", "")
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " commit -m \"seed lock store\"")
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " remote add origin " & q(result.storeOrigin))
  discard requireGit(q(gitBin) & " -C " & q(result.storeRoot) &
    " push -u origin main")

  result.libAPath = workspaceRoot / "lib-a"
  result.libBPath = workspaceRoot / "lib-b"
  for (origin, path) in [(libAOrigin, result.libAPath),
                         (libBOrigin, result.libBPath)]:
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
      q(path))
    configureIdentity(gitBin, path)

proc invokeLock(fx: Fixture): CmdResult =
  runShell(shellCommand(@[fx.reproBin, "workspace", "lock", "lib-a",
    "--workspace-root=" & fx.workspaceRoot]))

proc recordRel(sha: string): string =
  "locks/lib-a/lib-a/" & sha & ".toml"

proc publishedUpstream(gitBin: string; fx: Fixture; rel: string): bool =
  ## Is ``rel`` in the store upstream's ``main``?
  runCmd(q(gitBin) & " --git-dir=" & q(fx.storeOrigin) &
    " cat-file -e main:" & rel).code == 0

suite "repro workspace lock withholds records pinning unobtainable commits":

  test "test_lock_withholds_record_when_trigger_head_is_unpushed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "trigger")
      defer: removeDir(fx.scratch)
      let localSha = commitLocally(gitBin, fx.libAPath, "local.txt")

      let res = invokeLock(fx)
      checkpoint("output: " & res.output)
      # The lock is still written; publication is what is withheld.
      check res.code == 0
      check fileExists(fx.storeRoot / "locks" / "lib-a" / "lib-a" /
        (localSha & ".toml"))
      check not publishedUpstream(gitBin, fx, recordRel(localSha))
      check "published verified" notin res.output
      check ("not publishing '" & recordRel(localSha) & "'") in res.output
      check ("lib-a @ " & localSha) in res.output
      check ("git -C " & fx.libAPath & " push") in res.output

  test "test_lock_withholds_record_when_sibling_head_is_unpushed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "sibling")
      defer: removeDir(fx.scratch)
      let triggerSha = requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
        " rev-parse HEAD").strip()
      let siblingSha = commitLocally(gitBin, fx.libBPath, "local.txt")

      let res = invokeLock(fx)
      checkpoint("output: " & res.output)
      check res.code == 0
      check fileExists(fx.storeRoot / "locks" / "lib-a" / "lib-a" /
        (triggerSha & ".toml"))
      check not publishedUpstream(gitBin, fx, recordRel(triggerSha))
      check "published verified" notin res.output
      check ("lib-b @ " & siblingSha) in res.output
      check ("git -C " & fx.libBPath & " push") in res.output

  test "test_lock_publishes_record_once_the_pinned_commit_is_pushed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setupFixture(gitBin, "pushed")
      defer: removeDir(fx.scratch)
      let localSha = commitLocally(gitBin, fx.libAPath, "local.txt")

      let withheld = invokeLock(fx)
      checkpoint("first output: " & withheld.output)
      check withheld.code == 0
      check not publishedUpstream(gitBin, fx, recordRel(localSha))

      discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
        " push origin main")
      let published = invokeLock(fx)
      checkpoint("second output: " & published.output)
      check published.code == 0
      check "not publishing" notin published.output
      check "published verified lock records" in published.output
      check publishedUpstream(gitBin, fx, recordRel(localSha))

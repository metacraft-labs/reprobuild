## Pre-push identity of a nested submodule checkout of a declared repository.
##
## A workspace may declare a repository at one path (``platform``) while
## another declared repository (``parent``) also carries it as a Git
## submodule (``parent/platform``). A submodule's object store lives under the
## parent's ``.git/modules/``, so the gate can never identify that checkout by
## path or by Git common directory; only the configured-remote fallback, which
## is consulted while the declared checkout is absent, can. Two defects made
## the gate refuse such a push with a remedy that cannot work:
##
## * the remote fallback compared remotes literally apart from credentials and
##   host case, so the submodule's ``…/platform.git`` (the spelling
##   ``.gitmodules`` and ``git clone`` produce) never matched the declared
##   ``…/platform``, although both name one repository
##   (Unified-Locking-And-Hooks.md §16.3 H2: the canonical repository URL);
## * while the declared checkout exists, the refusal told the operator to run
##   ``repro hooks ensure --vcs`` on the submodule, which cannot make it a
##   declared checkout, instead of naming the declared checkout to push from.
##
## The suite drives the real ``repro`` binary through ``hooks dispatch
## pre-push`` against real Git repositories and a real ``git submodule add``.
## Nothing is mocked. The declared URL is an ``https://`` URL on a reserved
## ``.invalid`` host, because the ``.git`` fold applies to network remotes
## only; the gate never contacts it (publication is judged from the
## submodule's remote-tracking refs, which the file-URL clone populated).
## The canonicalisation is additionally pinned at the function level, where
## its local-path and credential rules can be exercised exactly.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests
import repro_cli_support/push_hook_protocol

type
  Fixture = object
    scratch, workspace, parent, nested, declared: string
    platformOrigin, parentOrigin, lockStore: string
    gitBin, reproBin, platformSha: string

const
  ForgeBase = "https://git.example.invalid/org"
    ## A `[[remote]]` fetch base: the declared URL is `<base>/<repo name>`,
    ## with no `.git`, as agent-harbor's `url_prefix` declares `platform`.
  ForgeUrl = ForgeBase & "/platform"
  ForgeUrlWithSuffix = ForgeUrl & ".git"

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    raise newException(IOError, "command failed: " & command &
      "\nexit=" & $res.code & "\n" & res.output)
  res.output

proc sourceRoot(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc runProcess(binary: string; args: openArray[string]):
    tuple[code: int; output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  let process = startProcess(binary, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()

proc configureUser(gitBin, work: string) =
  discard require(q(gitBin) & " -C " & q(work) &
    " config user.email submodule@example.invalid")
  discard require(q(gitBin) & " -C " & q(work) &
    " config user.name 'Submodule Identity Tester'")

proc initOrigin(gitBin, origin, work, content: string): string =
  discard require(q(gitBin) & " init --bare -b main " & q(origin))
  discard require(q(gitBin) & " init -b main " & q(work))
  configureUser(gitBin, work)
  writeFile(work / "README.md", content & "\n")
  discard require(q(gitBin) & " -C " & q(work) & " add README.md")
  discard require(q(gitBin) & " -C " & q(work) &
    " commit -m " & q("seed " & content))
  discard require(q(gitBin) & " -C " & q(work) &
    " remote add origin " & q(fileUrl(origin)))
  discard require(q(gitBin) & " -C " & q(work) & " push -u origin main")
  require(q(gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc projectToml(remoteUrl, parentUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"ah\"\n\n" &
    "[[remote]]\nname = \"platform-origin\"\nfetch = \"" & remoteUrl &
      "\"\n\n" &
    "[[remote]]\nname = \"parent-origin\"\nfetch = \"" & parentUrl &
      "\"\n\n" &
    "includes = [\"repos/platform.toml\", \"repos/parent.toml\"]\n"

const
  PlatformToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "platform"
path = "platform"
remote = "platform-origin"
mainline = "main"
"""
  ParentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "parent"
path = "parent"
remote = "parent-origin"
mainline = "main"
"""

proc setup(): Fixture =
  result.gitBin = findExe("git")
  doAssert result.gitBin.len > 0, "git is required"
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-pre-push-submodule-identity-", "")
  var complete = false
  defer:
    if not complete and dirExists(result.scratch):
      removeDir(result.scratch)
  let gitBin = result.gitBin
  result.workspace = result.scratch / "workspace"
  result.parent = result.workspace / "parent"
  result.nested = result.parent / "platform"
  result.declared = result.workspace / "platform"
  result.platformOrigin = result.scratch / "platform-origin.git"
  result.parentOrigin = result.scratch / "parent-origin.git"
  result.lockStore = result.workspace / ".repro" / "manifests"
  createDir(result.workspace)
  result.platformSha = initOrigin(gitBin, result.platformOrigin,
    result.scratch / "platform-seed", "platform")
  discard initOrigin(gitBin, result.parentOrigin,
    result.scratch / "parent-seed", "parent")

  discard require(q(gitBin) & " clone " & q(fileUrl(result.parentOrigin)) &
    " " & q(result.parent))
  configureUser(gitBin, result.parent)
  # The real layout: the parent carries the declared repository as a
  # submodule. File transport is opt-in for submodules since Git 2.38.3.
  discard require(q(gitBin) & " -C " & q(result.parent) &
    " -c protocol.file.allow=always submodule add " &
    q(fileUrl(result.platformOrigin)) & " platform")
  discard require(q(gitBin) & " -C " & q(result.parent) &
    " commit -m 'carry platform as a submodule'")
  discard require(q(gitBin) & " -C " & q(result.parent) & " push origin main")
  configureUser(gitBin, result.nested)
  # `.gitmodules` spells the URL with `.git`; the manifest does not. The
  # remote-tracking refs from the file clone stay, so the HEAD is published.
  discard require(q(gitBin) & " -C " & q(result.nested) &
    " remote set-url origin " & q(ForgeUrlWithSuffix))
  discard require(q(gitBin) & " -C " & q(result.nested) &
    " checkout -q -B main origin/main")

  createDir(result.workspace / "projects")
  createDir(result.workspace / "repos")
  writeFile(result.workspace / "projects" / "ah.toml",
    projectToml(ForgeBase, fileUrl(result.parentOrigin)))
  writeFile(result.workspace / "repos" / "platform.toml", PlatformToml)
  writeFile(result.workspace / "repos" / "parent.toml", ParentToml)
  writeWorkspaceProjects(result.workspace, @["ah"])

  createDir(result.lockStore)
  discard require(q(gitBin) & " init -b main " & q(result.lockStore))
  configureUser(gitBin, result.lockStore)
  writeFile(result.lockStore / ".gitkeep", "")
  discard require(q(gitBin) & " -C " & q(result.lockStore) & " add .gitkeep")
  discard require(q(gitBin) & " -C " & q(result.lockStore) &
    " commit -m 'seed lock store'")
  complete = true

proc report(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "build" / "reports" /
    "check-report.json")

proc dispatchNested(fx: Fixture): tuple[code: int; output: string] =
  ## The hook invocation Git makes for `git push origin main` from the
  ## submodule: protocol 2, the pushed root, and the remote as configured.
  let refs = fx.scratch / "nested-refs.bin"
  writeFile(refs, "refs/heads/main " & fx.platformSha & " refs/heads/main " &
    fx.platformSha & "\n")
  runProcess(fx.reproBin,
    ["hooks", "dispatch", "pre-push", "--protocol=2",
     "--repo-root", fx.nested, "--refs-file", refs, "--",
     "origin", ForgeUrlWithSuffix])

suite "pre-push identity of a nested submodule checkout":
  test "remote identity is the canonical repository URL":
    # H2's canonical repository URL: a trailing `.git` or `/`, the transport
    # spelling, userinfo, host case, a query and a fragment do not name a
    # different repository.
    let declared = remoteRepositoryIdentityDigest(ForgeUrl)
    check declared.len == 64
    for spelling in [ForgeUrlWithSuffix, ForgeUrl & "/", ForgeUrl & ".git/",
        "https://GIT.example.invalid/org/platform.git",
        "https://user:secret@git.example.invalid/org/platform.git",
        "https://git.example.invalid/org/platform.git?token=x#frag",
        "ssh://git@git.example.invalid/org/platform.git",
        "git@git.example.invalid:org/platform.git"]:
      checkpoint(spelling)
      check remoteRepositoryIdentityDigest(spelling) == declared
    # Path case and a different repository stay distinct.
    check remoteRepositoryIdentityDigest(
      "https://git.example.invalid/org/Platform") != declared
    check remoteRepositoryIdentityDigest(
      "https://git.example.invalid/org/platform-tools.git") != declared
    check remoteRepositoryIdentityDigest(
      "https://git.example.invalid:8443/org/platform") != declared
    # A local remote is a directory, and `x` and `x.git` are two directories.
    let local = createTempDir("repro-remote-identity-local-", "")
    defer: removeDir(local)
    createDir(local / "repo")
    createDir(local / "repo.git")
    check remoteRepositoryIdentityDigest(local / "repo") !=
      remoteRepositoryIdentityDigest(local / "repo.git")
    check remoteRepositoryIdentityDigest(fileUrl(local / "repo.git")) ==
      remoteRepositoryIdentityDigest(local / "repo.git")
    # A relative local path is a directory too, and a colon after a slash is
    # part of a path, not an scp host (git-clone(1) "GIT URLS"), so neither
    # can take on a network repository's identity.
    check remoteRepositoryIdentityDigest("repo") !=
      remoteRepositoryIdentityDigest("repo.git")
    check remoteRepositoryIdentityDigest(
      "git.example.invalid/org/platform") != declared
    check remoteRepositoryIdentityDigest(
      "git.example.invalid/org:platform") != declared
    check remoteRepositoryIdentityDigest("") == ""

  test "nested submodule is its declared repo while the declared checkout is absent":
    let fx = setup()
    defer: removeDir(fx.scratch)
    check not dirExists(fx.declared)
    let dispatched = fx.dispatchNested()
    checkpoint(dispatched.output)
    check dispatched.code == 0
    let document = fx.report()
    checkpoint($document["failures"])
    check document["exitCode"].getInt() == 0
    check document["failures"].len == 0
    check expandFilename(document["currentRepo"].getStr()) ==
      expandFilename(fx.nested)
    # The passing gate records the pushed HEAD of the declared repository.
    var recorded = false
    for path in walkDirRec(fx.lockStore / "locks"):
      if path.endsWith(fx.platformSha & ".toml") and
          "path = \"platform\"" in readFile(path):
        recorded = true
    check recorded

  test "a remote that names another repository is still refused":
    let fx = setup()
    defer: removeDir(fx.scratch)
    discard require(q(fx.gitBin) & " -C " & q(fx.nested) &
      " remote set-url origin " &
      q("https://git.example.invalid/org/platform-tools.git"))
    let refs = fx.scratch / "other-refs.bin"
    writeFile(refs, "refs/heads/main " & fx.platformSha & " refs/heads/main " &
      fx.platformSha & "\n")
    let dispatched = runProcess(fx.reproBin,
      ["hooks", "dispatch", "pre-push", "--protocol=2",
       "--repo-root", fx.nested, "--refs-file", refs, "--",
       "origin", "https://git.example.invalid/org/platform-tools.git"])
    checkpoint(dispatched.output)
    check dispatched.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["property"].getStr() ==
      "current-repo-identity"
    check "does not match a declared repo" in
      document["failures"][0]["evidence"].getStr()
    # The diagnostics never carry a remote URL (credentials can live there).
    check "git.example.invalid" notin $document["failures"]
    check not dirExists(fx.lockStore / "locks")

  test "with the declared checkout present the refusal names it":
    let fx = setup()
    defer: removeDir(fx.scratch)
    discard require(q(fx.gitBin) & " clone -q " &
      q(fileUrl(fx.platformOrigin)) & " " & q(fx.declared))
    discard require(q(fx.gitBin) & " -C " & q(fx.declared) &
      " remote set-url origin " & q(ForgeUrl))
    let dispatched = fx.dispatchNested()
    checkpoint(dispatched.output)
    # Still a refusal: the submodule has its own object store, and the
    # workspace gates and locks its declared checkout.
    check dispatched.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    let failure = document["failures"][0]
    check failure["property"].getStr() == "current-repo-identity"
    let remediation = failure["remediation"].getStr()
    let evidence = failure["evidence"].getStr()
    checkpoint(remediation & "\n" & evidence)
    # The remedy names the checkout to push from, and does not suggest
    # installing hooks in a checkout that hooks cannot make declared.
    check ("push from the declared checkout of 'platform' at " &
      expandFilename(fx.declared)) in remediation
    check "hooks ensure" notin remediation
    check "submodule of " & expandFilename(fx.parent) in evidence
    check "'platform'" in evidence
    check "git.example.invalid" notin remediation & evidence
    check not dirExists(fx.lockStore / "locks")
    check "repro hooks ensure" notin dispatched.output
    check expandFilename(fx.declared) in dispatched.output

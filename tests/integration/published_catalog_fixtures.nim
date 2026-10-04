## Test support (not a test): real git catalog repositories that PUBLISH
## interface artifacts, and the workspace shared clones federated catalog
## discovery reads them from (``reprobuild-specs/Federated-Catalog-Imports.md``).
##
## A ``CatalogRepo`` is a real publisher repository with a working tree
## (``upstream``), committed with ordinary ``git commit`` -- its provider
## source (``repro.nim``) and its generated ``published-interfaces/*.rbsz``
## -- plus the shared bare clone of it that discovery reads, at
## ``shared_clones.sharedBarePath(<clones root>, remote)``, whose
## ``remote.origin.url`` is the catalog's logical remote (a lock never
## records a local path, so the remote is an identity such as
## ``https://example.invalid/...`` and the objects are fetched from the local
## upstream). Plumbing helpers build trees and commits directly in a bare,
## for tree shapes a working tree cannot express.
##
## Nothing here is a double: the repositories, commits, object stores and
## artifacts are real, produced by git and by the production artifact codec.

import std/[os, osproc, sequtils, strtabs, strutils]

import repro_interface_artifacts
import shared_clones

proc fixtureGitEnv(): StringTableRef =
  ## The ambient environment without ``GIT_*``, plus a fixed identity and
  ## dates so commits do not depend on the host's git configuration.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii().startsWith("GIT_"): continue
    result[key] = value
  result["GIT_AUTHOR_NAME"] = "Catalog Publisher"
  result["GIT_AUTHOR_EMAIL"] = "publisher@example.invalid"
  result["GIT_COMMITTER_NAME"] = "Catalog Publisher"
  result["GIT_COMMITTER_EMAIL"] = "publisher@example.invalid"
  result["GIT_AUTHOR_DATE"] = "2026-10-01T00:00:00Z"
  result["GIT_COMMITTER_DATE"] = "2026-10-01T00:00:00Z"
  result["GIT_CONFIG_NOSYSTEM"] = "1"

proc git*(args: openArray[string]; dir = ""; input = ""): string =
  ## Run ``git`` (argv-structured, no shell) and return its stdout; fails
  ## the test process on a non-zero exit.
  var cmd = "git -c core.autocrlf=false -c init.defaultBranch=main " &
    "-c advice.detachedHead=false"
  for a in args:
    cmd.add(" " & quoteShell(a))
  let r = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut},
    env = fixtureGitEnv(), workingDir = dir, input = input)
  doAssert r.exitCode == 0, "git " & args.join(" ") & " failed: " & r.output
  r.output

proc lastLine(output: string): string =
  output.strip().splitLines()[^1].strip()

type CatalogRepo* = object
  name*: string
  remote*: string
  upstream*: string

proc initCatalogRepo*(root, name, remote: string;
                      providerSource = ""): CatalogRepo =
  ## A publisher repository at ``<root>/upstream/<name>`` whose provider
  ## source is ``providerSource`` (committed with the first publication).
  result = CatalogRepo(name: name, remote: remote,
    upstream: root / "upstream" / name)
  createDir(result.upstream)
  discard git(["init", "-q", result.upstream])
  writeFile(result.upstream / "repro.nim",
    if providerSource.len > 0: providerSource
    else: "# catalog provider for " & name & "\n")

proc publishCommit*(repo: CatalogRepo;
                    artifacts: openArray[(string, ProjectInterfaceArtifact)];
                    message: string; branch = "main";
                    extraFiles: openArray[(string, string)] = []): string =
  ## Replace ``published-interfaces/`` with ``artifacts`` (file name ->
  ## artifact, written by the production codec), commit everything on
  ## ``branch`` -- created from ``main`` when it does not exist yet -- and
  ## return the new commit id. ``main`` itself only ever moves forward.
  let hasMain = execCmdEx("git -C " & quoteShell(repo.upstream) &
    " rev-parse --verify -q refs/heads/main", env = fixtureGitEnv()).
    exitCode == 0
  let hasBranch = execCmdEx("git -C " & quoteShell(repo.upstream) &
    " rev-parse --verify -q refs/heads/" & branch, env = fixtureGitEnv()).
    exitCode == 0
  if not hasMain:
    # The first publication is on the unborn ``main`` (init.defaultBranch).
    doAssert branch == "main", "the first publication goes on main"
  elif hasBranch:
    discard git(["checkout", "-q", "-f", branch], repo.upstream)
  else:
    discard git(["checkout", "-q", "-f", "-b", branch, "main"], repo.upstream)
  let pub = repo.upstream / "published-interfaces"
  if dirExists(pub):
    removeDir(pub)
  if artifacts.len > 0:
    createDir(pub)
  for (fileName, artifact) in artifacts:
    writeInterfaceArtifact(pub / fileName, artifact)
  for (rel, content) in extraFiles:
    createDir(parentDir(repo.upstream / rel))
    writeFile(repo.upstream / rel, content)
  discard git(["add", "-A"], repo.upstream)
  discard git(["commit", "-q", "--allow-empty", "-m", message], repo.upstream)
  lastLine(git(["rev-parse", "HEAD"], repo.upstream))

proc sharedCloneOf*(clonesRoot, remote: string): string =
  sharedBarePath(clonesRoot, remote)

proc syncSharedClone*(repo: CatalogRepo; clonesRoot: string;
                      loose = false): string =
  ## Create or update the shared bare clone of ``repo`` under
  ## ``clonesRoot`` (what ``repro ws sync`` maintains): every branch and tag
  ## of the upstream, ``remote.origin.url`` = the logical remote.
  ## ``loose`` unpacks every fetched object into a loose file (so a test can
  ## substitute one). Returns the bare's path.
  result = sharedCloneOf(clonesRoot, repo.remote)
  if not dirExists(result / "objects"):
    createDir(result)
    discard git(["init", "-q", "--bare", result])
    discard git(["--git-dir=" & result, "config", "remote.origin.url",
      repo.remote])
  var args = @["--git-dir=" & result]
  if loose:
    args.add(["-c", "fetch.unpackLimit=1000000", "-c",
      "transfer.unpackLimit=1000000"])
  args.add(["fetch", "-q", "--no-tags", "--force", repo.upstream,
    "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"])
  discard git(args)

proc writeBlob*(gitDir, content: string): string =
  lastLine(git(["--git-dir=" & gitDir, "hash-object", "-w", "--stdin"],
    input = content))

type TreeEntrySpec* = object
  mode*: string        ## "100644", "100755", "120000", "160000", "040000"
  kind*: string        ## "blob", "tree", "commit"
  oid*: string
  name*: string

proc writeTree*(gitDir: string; entries: openArray[TreeEntrySpec]): string =
  var input = ""
  for e in entries:
    input.add(e.mode & " " & e.kind & " " & e.oid & "\t" & e.name & "\n")
  lastLine(git(["--git-dir=" & gitDir, "mktree", "--missing"], input = input))

proc writeRawObject*(gitDir, kind, content: string): string =
  ## An object of type ``kind`` written byte for byte with no validation
  ## (``hash-object --literally``).
  lastLine(git(["--git-dir=" & gitDir, "hash-object", "-t", kind, "-w",
    "--literally", "--stdin"], input = content))

proc writeRawTree*(gitDir: string; entries: openArray[TreeEntrySpec]): string =
  ## A tree object written byte for byte, IN THE ORDER GIVEN and with no
  ## validation (``hash-object --literally``) -- for shapes ``mktree``
  ## refuses to build, such as two entries of one name.
  var raw = ""
  for e in entries:
    raw.add(e.mode.strip(leading = true, trailing = false, chars = {'0'}) &
      " " & e.name & "\0")
    for i in countup(0, e.oid.len - 2, 2):
      raw.add(char(parseHexInt(e.oid[i .. i + 1])))
  lastLine(git(["--git-dir=" & gitDir, "hash-object", "-t", "tree", "-w",
    "--literally", "--stdin"], input = raw))

proc commitTree*(gitDir, tree, message: string; parent = ""): string =
  var args = @["--git-dir=" & gitDir, "commit-tree", tree, "-m", message]
  if parent.len > 0:
    args.add(["-p", parent])
  lastLine(git(args))

proc setRef*(gitDir, refName, oid: string) =
  discard git(["--git-dir=" & gitDir, "update-ref", refName, oid])

proc rootTreeOf*(gitDir, commit: string): string =
  lastLine(git(["--git-dir=" & gitDir, "rev-parse", commit & "^{tree}"]))

proc blobIdAt*(gitDir, commit, path: string): string =
  lastLine(git(["--git-dir=" & gitDir, "rev-parse", commit & ":" & path]))

type ImportSpec* = object
  repo*: string
  remote*: string
  commit*: string
  gitRef*: string
  interfaceArtifact*: string

proc declarationText*(imports: openArray[ImportSpec];
                      policy: openArray[(string, string)] = []): string =
  ## A ``repro-catalogs.toml`` with ``imports`` and ``policy`` IN THE ORDER
  ## GIVEN.
  result = "schema = \"reprobuild.catalog-imports.v1\"\n"
  for i in imports:
    result.add("\n[[import]]\nrepo = \"" & i.repo & "\"\nremote = \"" &
      i.remote & "\"\n")
    if i.commit.len > 0: result.add("commit = \"" & i.commit & "\"\n")
    if i.gitRef.len > 0: result.add("ref = \"" & i.gitRef & "\"\n")
    if i.interfaceArtifact.len > 0:
      result.add("interface_artifact = \"" & i.interfaceArtifact & "\"\n")
  for (package, contributor) in policy:
    result.add("\n[[policy]]\npackage = \"" & package & "\"\ncontributor = \"" &
      contributor & "\"\n")

proc writeDeclaration*(projectRoot: string; imports: openArray[ImportSpec];
                       policy: openArray[(string, string)] = []) =
  createDir(projectRoot)
  writeFile(projectRoot / "repro-catalogs.toml",
    declarationText(imports, policy))

proc makeJunction*(link, target: string) =
  ## A directory junction (Windows) or symbolic link (elsewhere) at ``link``
  ## pointing at ``target``.
  when defined(windows):
    let r = execCmdEx("cmd /c mklink /J " & quoteShell(link.replace('/', '\\')) &
      " " & quoteShell(target.replace('/', '\\')))
    doAssert r.exitCode == 0, "mklink /J failed: " & r.output
  else:
    createSymlink(target, link)

proc removeLink*(link: string) =
  when defined(windows):
    discard execCmdEx("cmd /c rmdir " & quoteShell(link.replace('/', '\\')))
  else:
    removeFile(link)

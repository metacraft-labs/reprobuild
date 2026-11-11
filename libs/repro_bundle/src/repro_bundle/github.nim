## Publishing a workspace bundle to, and reading it from, a GitHub repository
## as plain files on orphan branches (Workspace-Bundles.md §6.1).
##
## The layout is a function of the bundle alone, so `create` can bake every
## file's branch into `restore.sh` before anything is published: a half
## directory `<rel>` becomes the branches `<bundle>/<rel>/bNN`, where branch
## `bNN` holds the files at indexes `[NN*20, NN*20+20)` of the half's sorted
## file list. The branch `latest` holds `<bundle>/<system>/latest.json` and
## `restore.sh`, and is pushed last.
##
## Three environment variables point the transport elsewhere, for tests:
## `REPRO_BUNDLE_GITHUB_REMOTE` (default `https://github.com`), the base the
## repository's git URL is formed from; `REPRO_BUNDLE_GITHUB_RAW` (default
## `https://raw.githubusercontent.com`); `REPRO_BUNDLE_GITHUB_API` (default
## `https://api.github.com`).

import std/[algorithm, os, strutils, tempfiles]
import repro_local_store/store_bundle
import ./exec

const
  GithubBatch* = 20
    ## Files per branch: 20 parts of 64 MiB keep each push well under
    ## GitHub's 2 GB push limit.
  GithubMaxFileBytes* = 100'i64 * 1024 * 1024
    ## GitHub refuses a file of 100 MiB or more.
  LatestBranch* = "latest"

proc githubRemoteBase*(): string =
  getEnv("REPRO_BUNDLE_GITHUB_REMOTE", "https://github.com").strip(
    chars = {'/'}, leading = false)

proc githubRawBase*(): string =
  getEnv("REPRO_BUNDLE_GITHUB_RAW", "https://raw.githubusercontent.com").strip(
    chars = {'/'}, leading = false)

proc githubApiBase*(): string =
  getEnv("REPRO_BUNDLE_GITHUB_API", "https://api.github.com").strip(
    chars = {'/'}, leading = false)

proc githubRemote*(repo: string): string =
  githubRemoteBase() & "/" & repo

proc halfFiles*(manifestName: string; parts: seq[BundlePart];
                extra: seq[string] = @[]): seq[string] =
  ## Every file of a half directory, sorted: what publish pushes and what the
  ## branch index is computed over.
  for p in parts: result.add(p.file)
  for e in extra: result.add(e)
  result.add(manifestName)
  result.sort()

proc githubBranch*(bundle, halfRel: string; batch: int): string =
  bundle & "/" & halfRel & "/b" & align($batch, 2, '0')

proc githubRefOf*(bundle, halfRel: string; files: seq[string];
                  file: string): string =
  ## The branch that holds `file` of the half `halfRel`.
  let i = files.find(file)
  if i < 0:
    bundleFail("file " & file & " is not part of half " & halfRel)
  githubBranch(bundle, halfRel, i div GithubBatch)

type GithubSource* = object
  repo*: string     ## owner/name
  gitRef*: string   ## commit (or branch) `latest` is read at
  bundle*: string

proc isGithubSource*(s: string): bool = s.startsWith("github:")

proc lsRemoteHead*(repo, branch: string): string =
  ## The commit `branch` points at, or "" when it does not exist.
  let r = runTool(requireExe("git"), ["ls-remote", githubRemote(repo),
    "refs/heads/" & branch])
  if r.code != 0:
    bundleFail("cannot reach " & githubRemote(repo) & ": " & r.errors.strip())
  for line in r.output.splitLines():
    let fields = line.split('\t')
    if fields.len == 2: return fields[0]
  ""

proc parseGithubSource*(s: string): GithubSource =
  ## `github:OWNER/REPO[@REF]/BUNDLE`. Without `@REF`, `latest` is pinned to
  ## its current commit: raw.githubusercontent.com caches branch URLs.
  var rest = s["github:".len .. ^1].strip(chars = {'/'})
  let parts = rest.split('/')
  if parts.len < 3:
    bundleFail("expected github:OWNER/REPO[@REF]/BUNDLE, got " & s)
  var repoName = parts[1]
  let at = repoName.find('@')
  if at >= 0:
    result.gitRef = repoName[at + 1 .. ^1]
    repoName = repoName[0 ..< at]
  result.repo = parts[0] & "/" & repoName
  result.bundle = parts[2 .. ^1].join("/")
  if result.gitRef.len == 0:
    result.gitRef = lsRemoteHead(result.repo, LatestBranch)
    if result.gitRef.len == 0:
      bundleFail("no `" & LatestBranch & "` branch in " & githubRemote(result.repo) &
        ": nothing has been published there")

proc githubDownload*(repo: string;
                     jobs: seq[tuple[path, gitRef, dest: string]];
                     parallel: int) =
  ## Each file from raw.githubusercontent.com (which serves a public
  ## repository to anyone, including a setup script), falling back to the
  ## contents API (a private repository attached to a running session).
  if jobs.len == 0: return
  var list = ""
  for (path, gitRef, dest) in jobs:
    list.add(dest & "\0" & path & "\0" & gitRef & "\0")
  let script = "get() { curl -fsSL --retry 3 -o \"$1\" " &
    quoteShell(githubRawBase() & "/" & repo) & "/\"$3/$2\" 2>/dev/null || " &
    "curl -fsSL --retry 3 -H 'Accept: application/vnd.github.raw' -o \"$1\" " &
    quoteShell(githubApiBase() & "/repos/" & repo & "/contents") &
    "/\"$2?ref=${3//\\//%2F}\"; }; export -f get; xargs -0 -n3 -P " & $max(1, parallel) &
    " bash -c 'get \"$0\" \"$1\" \"$2\"'"
  discard mustRunShell(script, "downloading from " & repo, stdinData = list)

type GithubPublishReport* = object
  pushed*: seq[string]
  skipped*: seq[string]

proc gitIdentity(): seq[string] =
  @["-c", "user.name=" & getEnv("GIT_AUTHOR_NAME", "repro-bundle"),
    "-c", "user.email=" & getEnv("GIT_AUTHOR_EMAIL",
      "repro-bundle@users.noreply.github.com"),
    "-c", "core.compression=0", "-c", "pack.compression=0"]

proc pushDirAsBranch(repo, dir: string; files: seq[string]; branch: string) =
  ## One orphan branch holding `files` of `dir` at its root, built in a
  ## throwaway repository the files are hard-linked into.
  let git = requireExe("git")
  let work = createTempDir("repro-bundle-push-", "")
  defer: removeDir(work)
  discard mustRun(git, gitIdentity() & @["init", "-q", "-b", "pub", work])
  for f in files:
    try: createHardlink(dir / f, work / f)
    except OSError: copyFile(dir / f, work / f)
  discard mustRun(git, gitIdentity() & @["-C", work, "add", "-A"])
  discard mustRun(git, gitIdentity() & @["-C", work, "commit", "-q", "-m",
    branch])
  discard mustRun(git, gitIdentity() & @["-C", work, "push", "-q",
    githubRemote(repo), "HEAD:refs/heads/" & branch])

proc remoteHeads(repo: string): seq[string] =
  let r = runTool(requireExe("git"), ["ls-remote", "--heads",
    githubRemote(repo)])
  if r.code != 0:
    bundleFail("cannot reach " & githubRemote(repo) & ": " & r.errors.strip())
  for line in r.output.splitLines():
    let fields = line.split('\t')
    if fields.len == 2 and fields[1].startsWith("refs/heads/"):
      result.add(fields[1]["refs/heads/".len .. ^1])

proc publishGithub*(bundleDir, bundle, repo: string;
                    halves: seq[tuple[rel, manifest: string]];
                    latestFiles: seq[tuple[path, rel: string]]):
    GithubPublishReport =
  ## Every half not yet there, batch by batch; then `latest`.
  let heads = remoteHeads(repo)
  for (rel, manifest) in halves:
    let dir = bundleDir / rel
    var files: seq[string]
    for kind, f in walkDir(dir):
      let n = extractFilename(f)
      if kind == pcFile and not n.startsWith("."):
        if getFileSize(f) >= GithubMaxFileBytes:
          bundleFail(f & " is " & $(getFileSize(f) shr 20) & " MiB; GitHub " &
            "refuses files of 100 MiB or more (create with --part-size=64M)")
        files.add(n)
    files.sort()
    let batches = (files.len + GithubBatch - 1) div GithubBatch
    var missing = false
    for b in 0 ..< batches:
      let branch = githubBranch(bundle, rel, b)
      if branch in heads: continue
      missing = true
      pushDirAsBranch(repo, dir,
        files[b * GithubBatch ..< min(files.len, (b + 1) * GithubBatch)], branch)
    if missing: result.pushed.add(rel) else: result.skipped.add(rel)
  # `latest` last: a reader sees a bundle only once all of it is there.
  let git = requireExe("git")
  let work = createTempDir("repro-bundle-latest-", "")
  defer: removeDir(work)
  if LatestBranch in heads:
    discard mustRun(git, gitIdentity() & @["clone", "-q", "--depth", "1",
      "--branch", LatestBranch, githubRemote(repo), work])
  else:
    discard mustRun(git, gitIdentity() & @["init", "-q", "-b", LatestBranch,
      work])
  for (path, rel) in latestFiles:
    createDir((work / rel).parentDir)
    copyFile(path, work / rel)
  discard mustRun(git, gitIdentity() & @["-C", work, "add", "-A"])
  if runTool(git, ["-C", work, "diff", "--cached", "--quiet"]).code != 0:
    discard mustRun(git, gitIdentity() & @["-C", work, "commit", "-q", "-m",
      bundle & ": " & $result.pushed.len & " half(s) published"])
    discard mustRun(git, gitIdentity() & @["-C", work, "push", "-q",
      githubRemote(repo), "HEAD:refs/heads/" & LatestBranch])

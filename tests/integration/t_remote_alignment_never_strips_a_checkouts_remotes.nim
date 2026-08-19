## Remote alignment must never leave a checkout with fewer ways back to its
## upstream than it started with.
##
## This is a regression test for real data loss, not a hypothetical. The
## alignment pass converged a checkout's remotes in two steps — add every
## remote the manifest declares, then remove every remote it does not — and
## the second step had no guard for the declared set being EMPTY. "Remove
## every remote not in the expected set" applied to an empty expected set
## means "remove every remote", so any resolution that yielded no remotes at
## all silently stripped `origin`, its URL, and every `refs/remotes/origin/*`
## from a real working tree. That is unrecoverable local state destroyed by a
## routine `sync`, and it was reachable from ordinary in-progress work on the
## resolver: a repo record that momentarily resolves with no bindings is a bug
## to see in a report, never a licence to disconnect somebody's checkout.
##
## The second defect is quieter but has the same shape — converging by
## add-then-prune rather than by RENAME. A checkout whose primary remote is
## named after the hosting organisation (the arrangement the predecessor tool
## produced) comes out with a remote called `origin` at the right URL, and
## with its remote-tracking refs deleted and every `branch.<b>.remote`
## pointing at a remote that no longer exists. Every surface a script checks
## says the remote is correct; the developer's tracking configuration is gone.
## So the assertions below are deliberately not "the right name at the right
## URL" — that passes against the destructive implementation too — but the
## tracking ref and the branch upstream that only a rename carries across.
##
## Asserted:
##   1. A repo that resolves with NO declared remotes leaves the checkout's
##      existing remotes, URLs, and remote-tracking refs exactly as they were.
##   2. A primary remote carrying the URL-prefix name is RENAMED to `origin`:
##      the tracking ref survives under the new name and the local branch
##      still has an upstream.
##   3. Pruning a genuinely undeclared remote still happens when the manifest
##      does declare something — the guard narrows the destructive step to the
##      degenerate case, it does not disable it.
##
## No mocks: a real `git init --bare` upstream reached over `file://`, a real
## clone, and the real `alignWorkspaceRemotes`. Skipped only when `git` is
## missing from PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support
import repro_workspace_manifests
import git_tool

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc requireCmd(command: string): string =
  let res = run(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    fail()
  res.output

proc seedBare(gitBin, bareDir, branch, marker: string) =
  let work = bareDir & "-seed"
  createDir(work)
  discard requireCmd(quoteShellCommand([gitBin, "init", "--quiet",
    "--initial-branch", branch, work]))
  writeFile(work / "README.md", marker & "\n")
  discard requireCmd(quoteShellCommand([gitBin, "-C", work, "add", "."]))
  discard requireCmd(quoteShellCommand([gitBin, "-C", work, "-c",
    "user.email=t@example.invalid", "-c", "user.name=t", "commit", "--quiet",
    "-m", "seed " & marker]))
  discard requireCmd(quoteShellCommand([gitBin, "clone", "--quiet", "--bare",
    work, bareDir]))
  removeDir(work)

proc remoteNames(gitBin, checkout: string): seq[string] =
  for line in requireCmd(quoteShellCommand(
      [gitBin, "-C", checkout, "remote"])).strip().splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

proc remoteUrl(gitBin, checkout, name: string): string =
  let res = run(quoteShellCommand(
    [gitBin, "-C", checkout, "remote", "get-url", name]))
  if res.code != 0: "" else: res.output.strip()

proc refSha(gitBin, checkout, refName: string): string =
  let res = run(quoteShellCommand(
    [gitBin, "-C", checkout, "rev-parse", "--verify", "--quiet", refName]))
  if res.code != 0: "" else: res.output.strip()

proc configValue(gitBin, checkout, key: string): string =
  let res = run(quoteShellCommand(
    [gitBin, "-C", checkout, "config", "--get", key]))
  if res.code != 0: "" else: res.output.strip()

suite "remote alignment never strips a checkout's remotes":

  test "t_alignment_leaves_a_checkout_alone_when_no_remote_is_declared":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-align-empty-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      let orgDir = scratch / "remotes"
      createDir(orgDir)
      seedBare(gitBin, orgDir / "lib-a", "dev", "lib-a")
      let prefix = "file://" & orgDir.replace('\\', '/')

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let checkout = workspaceRoot / "lib-a"
      discard requireCmd(quoteShellCommand([gitBin, "clone", "--quiet",
        prefix & "/lib-a", checkout]))
      let trackedBefore = refSha(gitBin, checkout, "refs/remotes/origin/dev")
      check trackedBefore.len > 0

      # The degenerate resolution. Constructed directly rather than through a
      # manifest precisely because no manifest can express it: it is what a
      # resolver DEFECT produces, and the defect is the input this has to
      # survive. `fetchUrl` is populated so the record is not empty in every
      # respect — the only thing missing is the bindings list.
      let degenerate = @[ResolvedRepo(
        name: "lib-a", path: "lib-a", projectRemote: "metacraft-labs",
        fetchUrl: prefix & "/lib-a", revision: "dev", branch: "dev",
        remotes: @[])]

      alignWorkspaceRemotes(workspaceRoot, degenerate, identity)

      # Nothing was taken away. Before the guard this left the checkout with
      # zero remotes and no remote-tracking refs at all.
      check remoteNames(gitBin, checkout) == @["origin"]
      check remoteUrl(gitBin, checkout, "origin") == prefix & "/lib-a"
      check refSha(gitBin, checkout, "refs/remotes/origin/dev") ==
        trackedBefore
      check configValue(gitBin, checkout, "branch.dev.remote") == "origin"

  test "t_alignment_renames_the_primary_remote_and_still_prunes_a_stale_one":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-align-rename-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      let orgDir = scratch / "remotes"
      createDir(orgDir)
      seedBare(gitBin, orgDir / "lib-a", "dev", "lib-a")
      let prefix = "file://" & orgDir.replace('\\', '/')

      let manifestRoot = scratch / "manifests"
      createDir(manifestRoot / "url-prefixes")
      createDir(manifestRoot / "repos")
      createDir(manifestRoot / "repo-sets")
      writeFile(manifestRoot / "url-prefixes" / "metacraft-labs.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\nname = \"metacraft-labs\"\nurl = \"" & prefix & "\"\n")
      writeFile(manifestRoot / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "branch = \"dev\"\nurl_prefix = \"metacraft-labs\"\n")
      writeFile(manifestRoot / "repo-sets" / "demo.toml",
        "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
        "[repo-set]\nname = \"demo\"\n\nmember_repos = [\"lib-a\"]\n")
      let resolved = resolveRepoSet(manifestRoot / "repo-sets" / "demo.toml")

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let checkout = workspaceRoot / "lib-a"
      # The predecessor tool's arrangement: the primary remote is named after
      # the organisation, not `origin`.
      discard requireCmd(quoteShellCommand([gitBin, "clone", "--quiet",
        "--origin", "metacraft-labs", prefix & "/lib-a", checkout]))
      let trackedBefore = refSha(gitBin, checkout,
        "refs/remotes/metacraft-labs/dev")
      check trackedBefore.len > 0
      check configValue(gitBin, checkout, "branch.dev.remote") ==
        "metacraft-labs"
      # ...plus a remote nobody declares any more.
      discard requireCmd(quoteShellCommand([gitBin, "-C", checkout, "remote",
        "add", "stale", "https://git.example.invalid/gone"]))

      alignWorkspaceRemotes(workspaceRoot, resolved.repos, identity)

      let names = remoteNames(gitBin, checkout)
      check "origin" in names
      check "metacraft-labs" notin names
      # The guard narrowed the prune to the degenerate case; it did not turn
      # pruning off.
      check "stale" notin names
      check remoteUrl(gitBin, checkout, "origin") == prefix & "/lib-a"

      # What only a rename carries across, and what the add-then-prune
      # implementation silently destroyed.
      check refSha(gitBin, checkout, "refs/remotes/origin/dev") ==
        trackedBefore
      check configValue(gitBin, checkout, "branch.dev.remote") == "origin"
      check configValue(gitBin, checkout, "branch.dev.merge") ==
        "refs/heads/dev"

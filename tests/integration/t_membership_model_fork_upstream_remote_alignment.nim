## Workspace-Membership-Model.md — a fork's `upstream` reaches the CHECKOUT,
## at a different path than its `origin`, end to end.
##
## The resolver test next door proves the two bindings resolve to different
## URLs. This one proves the rest of the way: that `alignWorkspaceRemotes`
## writes both into a real `.git/config`, with the primary named `origin` and
## the secondary named whatever the fragment called it. That is the half the
## model actually promises the user — "all 139 checked-out repos have `origin`"
## is a statement about checkouts, not about a resolver record.
##
## Why this case and not any two remotes: `reprobuild-cmake` forks
## `Kitware/CMake`, and before per-binding `url_suffix` existed the second
## binding could only compose `<other-prefix>/<same-name>`, i.e.
## `Kitware/reprobuild-cmake`. So the assertion that `upstream` lands on a
## DIFFERENT path is the assertion that the fix is real; a same-path upstream
## would have passed under the old scheme too.
##
## Asserted:
##   1. `origin` is configured from the repo-level `url_prefix` / `url_suffix`.
##   2. `upstream` is configured from the BINDING's own `url_prefix` /
##      `url_suffix`, at a different path — and it really is a fetchable
##      repository, proven by fetching from it.
##   3. A stale remote nobody declares is pruned (pre-existing behaviour that
##      must survive the new binding shape).
##   4. A checkout whose remotes match nothing in the manifest and whose HEAD
##      is not at the pinned revision is SKIPPED, not rewritten (the
##      "observe, don't auto-modify an unrecognized checkout" contract).
##
## No mocks: real `git init --bare` upstreams reached over `file://`, a real
## clone, and the real `alignWorkspaceRemotes`. Skipped only when `git` is
## missing from PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support
import repro_workspace_manifests
import git_tool

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireCmd(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    fail()
  res.output

proc seedBare(gitBin, bareDir, marker: string) =
  ## A bare repo with one real commit, so a clone of it has a HEAD.
  let work = bareDir & "-seed"
  createDir(work)
  discard requireCmd(quoteShellCommand([gitBin, "init", "--quiet",
    "--initial-branch", "reprobuild", work]))
  writeFile(work / "README.md", marker & "\n")
  discard requireCmd(quoteShellCommand([gitBin, "-C", work, "add", "."]))
  discard requireCmd(quoteShellCommand([gitBin, "-C", work, "-c",
    "user.email=t@example.invalid", "-c", "user.name=t", "commit", "--quiet",
    "-m", "seed " & marker]))
  discard requireCmd(quoteShellCommand([gitBin, "clone", "--quiet", "--bare",
    work, bareDir]))
  removeDir(work)

proc remoteUrl(gitBin, checkout, name: string): string =
  let res = run(quoteShellCommand(
    [gitBin, "-C", checkout, "remote", "get-url", name]))
  if res.code != 0: "" else: res.output.strip()

proc remoteNames(gitBin, checkout: string): seq[string] =
  for line in requireCmd(quoteShellCommand(
      [gitBin, "-C", checkout, "remote"])).strip().splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

suite "membership model — fork upstream reaches the checkout":

  test "t_fork_upstream_is_configured_at_its_own_path":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-mm-align-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # ---- two upstream orgs, each serving one repo ----------------------
      let orgDir = scratch / "remotes" / "metacraft-labs"
      let kitwareDir = scratch / "remotes" / "kitware"
      createDir(orgDir)
      createDir(kitwareDir)
      seedBare(gitBin, orgDir / "reprobuild-cmake", "the fork")
      # NOT `kitware/reprobuild-cmake` — that is exactly the URL the old
      # shared-`name` scheme would have composed, and it does not exist here.
      seedBare(gitBin, kitwareDir / "CMake", "the upstream")

      let orgPrefix = "file://" & orgDir.replace('\\', '/')
      let kitwarePrefix = "file://" & kitwareDir.replace('\\', '/')

      # ---- the manifest repo ---------------------------------------------
      let manifestRoot = scratch / "manifests"
      createDir(manifestRoot / "url-prefixes")
      createDir(manifestRoot / "repos")
      createDir(manifestRoot / "repo-sets")
      writeFile(manifestRoot / "url-prefixes" / "metacraft-labs.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\nname = \"metacraft-labs\"\nurl = \"" & orgPrefix &
        "\"\n")
      writeFile(manifestRoot / "url-prefixes" / "kitware.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\nname = \"kitware\"\nurl = \"" & kitwarePrefix & "\"\n")
      writeFile(manifestRoot / "repos" / "reprobuild-cmake.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"reprobuild-cmake\"\npath = \"reprobuild-cmake\"\n" &
        "branch = \"reprobuild\"\n" &
        "url_prefix = \"metacraft-labs\"\n" &
        "remotes = [{ name = \"upstream\", url_prefix = \"kitware\", " &
          "url_suffix = \"CMake\" }]\n")
      writeFile(manifestRoot / "repo-sets" / "cmake.toml",
        "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
        "[repo-set]\nname = \"cmake\"\n\nmembers = [\"reprobuild-cmake\"]\n")

      let resolved = resolveRepoSet(manifestRoot / "repo-sets" / "cmake.toml")
      check resolved.repos.len == 1

      # ---- a real checkout of the fork ------------------------------------
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      let checkout = workspaceRoot / "reprobuild-cmake"
      discard requireCmd(quoteShellCommand([gitBin, "clone", "--quiet",
        orgPrefix & "/reprobuild-cmake", checkout]))
      # Drift the checkout the way a real one drifts: a remote left over from
      # an earlier manifest that no longer declares it.
      discard requireCmd(quoteShellCommand([gitBin, "-C", checkout, "remote",
        "add", "stale", "https://git.example.invalid/gone"]))

      alignWorkspaceRemotes(workspaceRoot, resolved.repos, identity)

      let names = remoteNames(gitBin, checkout)
      check "origin" in names
      check "upstream" in names
      check "stale" notin names          # pruned
      check remoteUrl(gitBin, checkout, "origin") ==
        orgPrefix & "/reprobuild-cmake"
      let upstreamUrl = remoteUrl(gitBin, checkout, "upstream")
      check upstreamUrl == kitwarePrefix & "/CMake"
      check upstreamUrl != kitwarePrefix & "/reprobuild-cmake"
      # The upstream is not merely a string: fetching from it succeeds, which
      # it would not against the path the old scheme composed.
      discard requireCmd(quoteShellCommand(
        [gitBin, "-C", checkout, "fetch", "--quiet", "upstream"]))

  test "t_unrecognized_checkout_is_left_untouched":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-mm-align-skip-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      let orgDir = scratch / "remotes" / "metacraft-labs"
      createDir(orgDir)
      seedBare(gitBin, orgDir / "reprobuild-cmake", "the fork")
      let orgPrefix = "file://" & orgDir.replace('\\', '/')

      let manifestRoot = scratch / "manifests"
      createDir(manifestRoot / "url-prefixes")
      createDir(manifestRoot / "repos")
      createDir(manifestRoot / "repo-sets")
      writeFile(manifestRoot / "url-prefixes" / "metacraft-labs.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\nname = \"metacraft-labs\"\nurl = \"" & orgPrefix &
        "\"\n")
      writeFile(manifestRoot / "repos" / "reprobuild-cmake.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"reprobuild-cmake\"\npath = \"reprobuild-cmake\"\n" &
        "branch = \"reprobuild\"\nurl_prefix = \"metacraft-labs\"\n")
      writeFile(manifestRoot / "repo-sets" / "cmake.toml",
        "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
        "[repo-set]\nname = \"cmake\"\n\nmembers = [\"reprobuild-cmake\"]\n")
      let resolved = resolveRepoSet(manifestRoot / "repo-sets" / "cmake.toml")

      # A FOREIGN checkout occupying the repo's path: its own remote, its own
      # history. Rewriting its remotes would silently re-point somebody's
      # unrelated repository.
      let workspaceRoot = scratch / "workspace"
      let squatter = workspaceRoot / "reprobuild-cmake"
      createDir(squatter)
      discard requireCmd(quoteShellCommand([gitBin, "init", "--quiet",
        "--initial-branch", "main", squatter]))
      writeFile(squatter / "unrelated.txt", "not ours\n")
      discard requireCmd(quoteShellCommand([gitBin, "-C", squatter, "add", "."]))
      discard requireCmd(quoteShellCommand([gitBin, "-C", squatter, "-c",
        "user.email=t@example.invalid", "-c", "user.name=t", "commit",
        "--quiet", "-m", "unrelated"]))
      discard requireCmd(quoteShellCommand([gitBin, "-C", squatter, "remote",
        "add", "origin", "https://git.example.invalid/somebody-else"]))

      alignWorkspaceRemotes(workspaceRoot, resolved.repos, identity)

      check remoteUrl(gitBin, squatter, "origin") ==
        "https://git.example.invalid/somebody-else"

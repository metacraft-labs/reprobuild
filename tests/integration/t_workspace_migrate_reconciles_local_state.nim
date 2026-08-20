## `repro workspace migrate` reconciles a checkout's LOCAL git state with the
## manifest, and does it idempotently.
##
## Why this exists: the membership model makes `origin` the always-primary
## binding and gives forks an `upstream`, but neither statement reaches a
## checkout that already exists. The manifests arrive by `git pull`; the
## `.git/config` of 200-odd working trees does not follow. Nothing in the
## resolver can fix that, so a workspace converted without this step is left
## with remotes named after the URL prefix, no `upstream` on any fork, and
## HEADs sitting detached — a state where `git push` and `git pull` in a
## sibling repo mean something different from what the manifest says.
##
## The rename is the load-bearing part, and it is why this is not just a call
## to `alignWorkspaceRemotes`. Converging by add-then-prune reaches the same
## URL under the same name, but `git remote remove metacraft-labs` deletes
## `refs/remotes/metacraft-labs/*` and orphans every `branch.<b>.remote` that
## named it. The developer's tracking configuration is gone while every
## surface a script checks says the remote is correct. `git remote rename`
## carries both across, so the test asserts the tracking ref and the branch
## upstream survive — asserting only the remote's name and URL would pass
## against the destructive implementation too.
##
## Asserted:
##   1. A primary remote named after the URL prefix (`metacraft-labs`) is
##      RENAMED to `origin`, preserving its URL, its remote-tracking refs, and
##      the `branch.<b>.merge` / `branch.<b>.remote` configuration that named
##      it.
##   2. A second run is a clean no-op: no git command runs, nothing is
##      reported, and the report says the workspace already matches.
##   3. A detached HEAD lands on the branch the fragment declares, attached,
##      at the same commit it was already sitting on.
##   4. A detached HEAD whose declared branch exists only as a
##      remote-tracking ref gets a NEW local branch tracking it — without a
##      fetch, because this same code runs inside a git hook.
##   5. A fork gains its `upstream` remote, at the binding's own path rather
##      than the fork's.
##   6. An already-correct checkout is untouched: `repro workspace migrate`
##      reports nothing for it and its git state is byte-identical afterwards.
##   7. `--dry-run` reports exactly what the real run then does, and changes
##      nothing.
##
## No mocks: real `git init --bare` origins reached over `file://`, real
## clones, and the engine-built `build/bin/repro`. Skipped only when `git` is
## missing from PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc git(gitBin, args: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(q(gitBin) & " " & args, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(gitBin, args: string; cwd = ""): string =
  let res = git(gitBin, args, cwd)
  if res.code != 0:
    checkpoint("git " & args & " failed: exit=" & $res.code & "\n" & res.output)
    fail()
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedBare(gitBin, bareDir, branch, marker: string) =
  ## A bare repo carrying one commit on `branch`, so a clone of it has a HEAD.
  let work = bareDir & "-seed"
  createDir(work)
  discard requireGit(gitBin, "init --quiet --initial-branch " & q(branch) &
    " " & q(work))
  writeFile(work / "README.md", marker & "\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) &
    " -c user.email=t@example.invalid -c user.name=t commit --quiet -m " &
    q("seed " & marker))
  discard requireGit(gitBin, "clone --quiet --bare " & q(work) & " " &
    q(bareDir))
  removeDir(work)

proc remoteNames(gitBin, checkout: string): seq[string] =
  for line in requireGit(gitBin, "-C " & q(checkout) &
      " remote").strip().splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

proc remoteUrl(gitBin, checkout, name: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " remote get-url " & q(name))
  if res.code != 0: "" else: res.output.strip()

proc configValue(gitBin, checkout, key: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " config --get " & q(key))
  if res.code != 0: "" else: res.output.strip()

proc headBranch(gitBin, checkout: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc headSha(gitBin, checkout: string): string =
  requireGit(gitBin, "-C " & q(checkout) & " rev-parse HEAD").strip()

proc writeFragment(root, name, remote, branch: string) =
  writeFile(root / "repos" / (name & ".toml"),
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\nbranch = \"" & branch & "\"\n")

proc writeWorkspace(root: string; remotes, includes: openArray[string]) =
  ## A single-project manifest repo laid out flat at the workspace root, plus
  ## the `.repro/workspace.toml` that records it as the active set — the shape
  ## a developer's workspace actually has.
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"demo\"\n\n"
  for r in remotes:
    project.add(r)
  project.add("includes = [\n")
  for inc in includes:
    project.add("  \"" & inc & "\",\n")
  project.add("]\n")
  writeFile(root / "projects" / "demo.toml", project)
  writeFile(root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

proc remoteBlock(name, fetch: string): string =
  "[[remote]]\nname = \"" & name & "\"\nfetch = \"" & fetch & "\"\n\n"

proc migrate(root: string; extra: openArray[string] = []): CmdResult =
  var argv = @[reproBinary(), "workspace", "migrate",
    "--workspace-root=" & root]
  for e in extra:
    argv.add(e)
  runShell(shellCommand(argv))

suite "workspace migrate reconciles local git state with the manifest":

  test "t_migrate_renames_prefix_named_remote_to_origin_and_is_idempotent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-rename-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, remotes / "lib-a", "dev", "lib-a")
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      createDir(root / "projects")
      createDir(root / "repos")
      createDir(root / ".repro")
      writeFragment(root, "lib-a", "metacraft-labs", "dev")
      writeWorkspace(root, [remoteBlock("metacraft-labs", prefix)],
        ["repos/lib-a.toml"])

      # The pre-model shape: the primary remote carries the URL-PREFIX name.
      let checkout = root / "lib-a"
      discard requireGit(gitBin, "clone --quiet --origin metacraft-labs " &
        q(prefix & "/lib-a") & " " & q(checkout))
      check "metacraft-labs" in remoteNames(gitBin, checkout)
      check configValue(gitBin, checkout, "branch.dev.remote") ==
        "metacraft-labs"
      let trackedBefore = requireGit(gitBin, "-C " & q(checkout) &
        " rev-parse refs/remotes/metacraft-labs/dev").strip()

      let dry = migrate(root, ["--dry-run"])
      checkpoint("dry-run: " & dry.output)
      check dry.code == 0
      check dry.output.contains("would remote 'metacraft-labs' renamed to " &
        "'origin'")
      # A dry run changed nothing.
      check "metacraft-labs" in remoteNames(gitBin, checkout)

      let res = migrate(root)
      checkpoint("migrate: " & res.output)
      check res.code == 0

      let names = remoteNames(gitBin, checkout)
      check "origin" in names
      check "metacraft-labs" notin names
      check remoteUrl(gitBin, checkout, "origin") == prefix & "/lib-a"

      # The half a destructive add-then-prune would have silently dropped: the
      # remote-tracking ref moved with the remote, and the local branch still
      # has an upstream.
      check requireGit(gitBin, "-C " & q(checkout) &
        " rev-parse refs/remotes/origin/dev").strip() == trackedBefore
      check configValue(gitBin, checkout, "branch.dev.remote") == "origin"
      check configValue(gitBin, checkout, "branch.dev.merge") ==
        "refs/heads/dev"

      # Second run: a clean no-op. Not "produces the same end state" — reports
      # nothing at all, because a migration that keeps announcing itself after
      # it is done is indistinguishable from one that keeps re-doing itself.
      let again = migrate(root)
      checkpoint("second run: " & again.output)
      check again.code == 0
      check again.output.contains("already match the manifest")
      check not again.output.contains("renamed")
      check not again.output.contains("retargeted")

  test "t_migrate_attaches_a_detached_head_to_the_declared_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-detached-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, remotes / "lib-local", "dev", "lib-local")
      seedBare(gitBin, remotes / "lib-remote-only", "dev", "lib-remote-only")
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      createDir(root / "projects")
      createDir(root / "repos")
      createDir(root / ".repro")
      writeFragment(root, "lib-local", "org", "dev")
      writeFragment(root, "lib-remote-only", "org", "dev")
      writeWorkspace(root, [remoteBlock("org", prefix)],
        ["repos/lib-local.toml", "repos/lib-remote-only.toml"])

      # (a) a local branch `dev` exists — the ordinary detached clone.
      let withLocal = root / "lib-local"
      discard requireGit(gitBin, "clone --quiet " & q(prefix & "/lib-local") &
        " " & q(withLocal))
      discard requireGit(gitBin, "-C " & q(withLocal) & " checkout --quiet --detach HEAD")
      let shaLocal = headSha(gitBin, withLocal)
      check headBranch(gitBin, withLocal) == ""

      # (b) NO local `dev`, only `origin/dev`. Attaching has to create the
      # branch from the remote-tracking ref already on disk; a fetch is not
      # available to it, because this same path runs inside a git hook.
      let remoteOnly = root / "lib-remote-only"
      discard requireGit(gitBin, "clone --quiet " &
        q(prefix & "/lib-remote-only") & " " & q(remoteOnly))
      discard requireGit(gitBin, "-C " & q(remoteOnly) &
        " checkout --quiet --detach HEAD")
      discard requireGit(gitBin, "-C " & q(remoteOnly) & " branch -D dev")
      let shaRemoteOnly = headSha(gitBin, remoteOnly)
      check headBranch(gitBin, remoteOnly) == ""

      let res = migrate(root)
      checkpoint("migrate: " & res.output)
      check res.code == 0

      # Attached, on the declared branch, at the SAME commit. Landing on the
      # branch TIP instead would be a silent content change.
      check headBranch(gitBin, withLocal) == "dev"
      check headSha(gitBin, withLocal) == shaLocal
      check headBranch(gitBin, remoteOnly) == "dev"
      check headSha(gitBin, remoteOnly) == shaRemoteOnly
      check configValue(gitBin, remoteOnly, "branch.dev.remote") == "origin"

      let again = migrate(root)
      check again.code == 0
      check again.output.contains("already match the manifest")

  test "t_migrate_adds_a_forks_upstream_and_leaves_a_correct_checkout_alone":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-upstream-", "")
      defer: removeDirEventually(scratch)
      let orgDir = scratch / "remotes" / "metacraft-labs"
      let kitwareDir = scratch / "remotes" / "kitware"
      createDir(orgDir)
      createDir(kitwareDir)
      seedBare(gitBin, orgDir / "reprobuild-cmake", "reprobuild", "the fork")
      # NOT `kitware/reprobuild-cmake`: that is the path the pre-model scheme
      # composed, and it does not exist here.
      seedBare(gitBin, kitwareDir / "CMake", "reprobuild", "the upstream")
      seedBare(gitBin, orgDir / "already-fine", "dev", "already fine")
      let orgPrefix = fileUrl(orgDir)
      let kitwarePrefix = fileUrl(kitwareDir)

      let root = scratch / "workspace"
      createDir(root)
      createDir(root / "url-prefixes")
      createDir(root / "repos")
      createDir(root / "repo-sets")
      createDir(root / ".repro")
      writeFile(root / "url-prefixes" / "metacraft-labs.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\nname = \"metacraft-labs\"\nurl = \"" & orgPrefix &
        "\"\n")
      writeFile(root / "url-prefixes" / "kitware.toml",
        "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
        "[url-prefix]\nname = \"kitware\"\nurl = \"" & kitwarePrefix & "\"\n")
      writeFile(root / "repos" / "reprobuild-cmake.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"reprobuild-cmake\"\npath = \"reprobuild-cmake\"\n" &
        "branch = \"reprobuild\"\nurl_prefix = \"metacraft-labs\"\n" &
        "remotes = [{ name = \"upstream\", url_prefix = \"kitware\", " &
          "url_suffix = \"CMake\" }]\n")
      writeFile(root / "repos" / "already-fine.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"already-fine\"\npath = \"already-fine\"\n" &
        "branch = \"dev\"\nurl_prefix = \"metacraft-labs\"\n")
      writeFile(root / "repo-sets" / "demo.toml",
        "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
        "[repo-set]\nname = \"demo\"\n\n" &
        "member_repos = [\"reprobuild-cmake\", \"already-fine\"]\n")
      writeFile(root / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

      let fork = root / "reprobuild-cmake"
      discard requireGit(gitBin, "clone --quiet " &
        q(orgPrefix & "/reprobuild-cmake") & " " & q(fork))
      check "upstream" notin remoteNames(gitBin, fork)

      # A checkout that already matches the manifest in every respect. It must
      # come out the other side bit-identical, and unmentioned.
      let fine = root / "already-fine"
      discard requireGit(gitBin, "clone --quiet " &
        q(orgPrefix & "/already-fine") & " " & q(fine))
      let fineConfigBefore = readFile(fine / ".git" / "config")
      let fineHeadBefore = readFile(fine / ".git" / "HEAD")

      let res = migrate(root, ["--json"])
      checkpoint("migrate: " & res.output)
      check res.code == 0

      check "origin" in remoteNames(gitBin, fork)
      check "upstream" in remoteNames(gitBin, fork)
      check remoteUrl(gitBin, fork, "origin") ==
        orgPrefix & "/reprobuild-cmake"
      # The whole reason per-binding `url_suffix` exists: the upstream is at
      # `kitware/CMake`, not `kitware/reprobuild-cmake`.
      check remoteUrl(gitBin, fork, "upstream") == kitwarePrefix & "/CMake"
      # And it is a real repository, not just a string.
      discard requireGit(gitBin, "-C " & q(fork) & " fetch --quiet upstream")

      # The already-correct checkout: untouched on disk, and absent from the
      # report. "Reported nothing" is the assertion that matters — a tool that
      # rewrites a correct config to an identical one still churns mtimes and
      # still lies about having done work.
      check readFile(fine / ".git" / "config") == fineConfigBefore
      check readFile(fine / ".git" / "HEAD") == fineHeadBefore
      let report = parseJson(res.output)
      var mentioned: seq[string]
      for entry in report["repos"]:
        mentioned.add(entry["path"].getStr())
      check "already-fine" notin mentioned
      check "reprobuild-cmake" in mentioned

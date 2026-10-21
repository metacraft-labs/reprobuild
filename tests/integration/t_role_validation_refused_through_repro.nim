## Branch-role validation through the real `repro` binary
## (Workspace-Branch-Roles.md §3.3–§3.5).
##
## The unit tests prove the resolver's rules; this test proves a COMMAND
## loading a workspace whose manifests violate them is refused, and that the
## refusal names the file and the key — §3.5: "Each failure names the file and
## key, and the workspace does not resolve", reported when the manifest is
## loaded rather than as a per-command refusal.
##
## Leg 1 — manifest load (`repro workspace list demo --json`, a verb that only
## resolves the manifest). A workspace root whose `repro-workspace.toml`
## declares profiles and a custom role, and whose `core` fragment follows the
## `product` profile:
##   a. positive control: it lists `core`, exit 0;
##   b. `core` names a profile nobody declares -> exit != 0, stderr names
##      `repos/core.toml` and `repo.profile`;
##   c. `core` is a `repo.v2` fragment with no mainline, naming no profile,
##      in a workspace with no default profile -> `repo.mainline`;
##   d. `core`'s mainline is a commit id -> `repo.mainline`;
##   e. the settings file's custom roles fall back in a cycle -> stderr names
##      `repro-workspace.toml`, `branch-roles.alpha.fallback` and the chain;
##   f. a profile uses a custom role the workspace does not declare ->
##      `profiles.product.branch-roles.beta`.
##
## Leg 2 — the ROOT repository (§3.4), through `repro branch
## --from-mainlines`, which needs the root's mainline. The root repo is a real
## clone, so it HAS an `origin/HEAD` (`main`):
##   a. a `repro-workspace.toml` whose `[workspace]` declares no mainline:
##      the fork is refused (exit 2, nothing created) and the report's root
##      entry names the settings file and `workspace.mainline` — `origin/HEAD`
##      is NOT read, which is the behaviour this leg exists to pin (before,
##      the root was cut from `origin/HEAD` and the fork succeeded);
##   b. positive control: the same workspace with `[workspace] mainline =
##      "main"` forks, and the root lands on the new branch.
##
## No mocks: real git repositories behind `file://` remotes, the real `repro`
## binary as a subprocess. Skip rule: `git` missing from PATH.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  ## The real binary's exit code, stdout and stderr, read separately. The
  ## fixture's settings file must be found by discovery, not by an inherited
  ## `REPRO_WORKSPACE_CONFIG` pointing elsewhere.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc requireOk(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc gitIdentity(gitBin, path: string) =
  requireOk(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  requireOk(q(gitBin) & " -C " & q(path) & " config user.name Tester")

proc seedBare(gitBin, scratch, barePath: string;
              files: openArray[(string, string)]) =
  ## A bare repository whose one commit on `main` carries `files`.
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireOk(q(gitBin) & " init -q -b main " & q(work))
  gitIdentity(gitBin, work)
  for (rel, content) in files:
    createDir(parentDir(work / rel))
    writeFile(work / rel, content)
  requireOk(q(gitBin) & " -C " & q(work) & " add -A")
  requireOk(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  requireOk(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

const
  settingsHeader = "schema = \"reprobuild.workspace.settings.v1\"\n\n"
  validSettings = settingsHeader &
    "[profiles.product]\nmainline = \"main\"\nunstable = \"agents\"\n\n" &
    "[branch-roles.partner]\nfallback = \"staging\"\n"

proc projectToml(): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "member_repos = [\"core\"]\n\n[project]\nname = \"demo\"\n"

proc prefixToml(remotes: string): string =
  "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
    "name = \"acme\"\nurl = \"" & fileUrl(remotes) & "\"\n"

proc fragmentToml(repoKeys: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"core\"\n" &
    "path = \"core\"\nurl_prefix = \"acme\"\n" & repoKeys & "\n"

proc checkRefused(label: string; res: tuple[code: int; stdout, stderr: string];
                  needles: openArray[string]) =
  checkpoint(label & " exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  check res.code != 0
  for needle in needles:
    check needle in res.stderr

suite "branch-role validation through repro":

  test "t_role_validation_refused_through_repro":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the member and root repositories are real " &
        "repositories behind file:// remotes")
    else:
      let scratch = createTempDir("repro-role-validation-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBare(gitBin, scratch, remotes / "core",
        [("README", "core\n")])

      # ---- Leg 1: manifest load -----------------------------------------
      let root = scratch / "ws"
      createDir(root / "projects")
      createDir(root / "repos")
      createDir(root / "url-prefixes")
      writeFile(root / "projects" / "demo.toml", projectToml())
      writeFile(root / "url-prefixes" / "acme.toml", prefixToml(remotes))
      let settings = root / "repro-workspace.toml"
      let fragment = root / "repos" / "core.toml"
      proc list(): tuple[code: int; stdout, stderr: string] =
        runRepro(["workspace", "list", "demo", "--json",
          "--workspace-root=" & root])

      # a. Positive control.
      writeFile(settings, validSettings)
      writeFile(fragment, fragmentToml("profile = \"product\""))
      let ok = list()
      checkpoint("control exit=" & $ok.code & "\nstdout: " & ok.stdout &
        "\nstderr: " & ok.stderr)
      check ok.code == 0
      check "\"core\"" in ok.stdout

      # b. An undeclared profile.
      writeFile(fragment, fragmentToml("profile = \"prodcut\""))
      checkRefused("unknown profile", list(),
        [fragment, "repo.profile", "prodcut"])

      # c. No mainline anywhere.
      writeFile(fragment, fragmentToml("unstable = \"agents\""))
      checkRefused("no mainline", list(),
        [fragment, "repo.mainline", "has no mainline"])

      # d. A commit id where a branch belongs.
      writeFile(fragment, fragmentToml(
        "mainline = \"0123456789abcdef0123456789abcdef01234567\""))
      checkRefused("sha mainline", list(), [fragment, "repo.mainline"])

      # e. A custom-role fallback cycle in the settings file.
      writeFile(fragment, fragmentToml("profile = \"product\""))
      writeFile(settings, validSettings &
        "\n[branch-roles.alpha]\nfallback = \"omega\"\n\n" &
        "[branch-roles.omega]\nfallback = \"alpha\"\n")
      checkRefused("fallback cycle", list(),
        [settings, "branch-roles.alpha.fallback", "alpha -> omega -> alpha"])

      # f. A profile using an undeclared custom role.
      writeFile(settings, validSettings &
        "\n[profiles.product.branch-roles]\nbeta = \"beta\"\n")
      checkRefused("undeclared custom role", list(),
        [settings, "profiles.product.branch-roles.beta"])

      # ---- Leg 2: the root repository's mainline -------------------------
      proc forkCase(slug, workspaceTable: string):
          tuple[source, fork: string;
                res: tuple[code: int; stdout, stderr: string]] =
        ## A source workspace cloned from a root repo whose committed
        ## settings file carries `workspaceTable`, with `core` checked out.
        let rootBare = scratch / ("root-" & slug & ".git")
        seedBare(gitBin, scratch, rootBare, [
          ("projects/demo.toml", projectToml()),
          ("url-prefixes/acme.toml", prefixToml(remotes)),
          ("repos/core.toml", fragmentToml("profile = \"product\"")),
          ("repro-workspace.toml", validSettings & workspaceTable)])
        result.source = scratch / ("source-" & slug)
        requireOk(q(gitBin) & " clone -q " & q(fileUrl(rootBare)) & " " &
          q(result.source))
        gitIdentity(gitBin, result.source)
        requireOk(q(gitBin) & " clone -q " & q(fileUrl(remotes / "core")) &
          " " & q(result.source / "core"))
        gitIdentity(gitBin, result.source / "core")
        writeWorkspaceBranch(result.source, project = "demo", branch = "main")
        # The inference §3.4 forbids is available: the root HAS origin/HEAD.
        let head = execCmdEx(q(gitBin) & " -C " & q(result.source) &
          " symbolic-ref -q refs/remotes/origin/HEAD")
        check head.exitCode == 0
        check head.output.strip() == "refs/remotes/origin/main"
        result.fork = scratch / ("fork-" & slug)
        result.res = runRepro(["branch", "--write-report", result.fork,
          "--branch=feature-roles", "--from-mainlines",
          "--workspace-root=" & result.source])

      # a. No root mainline declared: refused, origin/HEAD not read.
      let undeclared = forkCase("undeclared", "")
      checkpoint("undeclared fork exit=" & $undeclared.res.code &
        "\nstdout: " & undeclared.res.stdout & "\nstderr: " &
        undeclared.res.stderr)
      check undeclared.res.code == 2
      check not dirExists(undeclared.fork)
      let reportPath = undeclared.source / ".repro" / "build" / "reports" /
        "branch-report.json"
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        var rootEntry = newJNull()
        for entry in report["repos"]:
          if entry["path"].getStr() == ".":
            rootEntry = entry
        check rootEntry.kind == JObject
        if rootEntry.kind == JObject:
          let diagnostic = rootEntry["diagnostic"].getStr()
          checkpoint("root diagnostic: " & diagnostic)
          check rootEntry["outcome"].getStr() == "mainline_undeclared"
          check (undeclared.source / "repro-workspace.toml") in diagnostic
          check "workspace.mainline" in diagnostic

      # b. Positive control: a declared root mainline forks.
      let declared = forkCase("declared",
        "\n[workspace]\nmainline = \"main\"\n")
      checkpoint("declared fork exit=" & $declared.res.code & "\nstdout: " &
        declared.res.stdout & "\nstderr: " & declared.res.stderr)
      check declared.res.code == 0
      check dirExists(declared.fork / ".git")
      let forkBranch = execCmdEx(q(gitBin) & " -C " & q(declared.fork) &
        " symbolic-ref --short -q HEAD")
      check forkBranch.output.strip() == "feature-roles"

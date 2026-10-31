## `repro workspace init <url>` cold-starts a workspace whose root repository
## IS its manifest repository (the flat layout: `projects/`, `repos/` and
## `repro-workspace.toml` side by side), joining the settings file's
## `[projects] default` set.
##
## The cold start clones the root repository and then runs the in-workspace
## `init` there. That `init` read the settings file only to find a separate
## manifest repository, and skipped it entirely once `projects/` existed —
## which, after cloning a flat-layout root, it always does. So it never read
## `[projects] default`, had no project to initialize, and failed with
## "requires a <project-or-variant> name": no flat-layout workspace could be
## joined with the one-command join (CLI/workspace.md, `repro workspace
## init`; Workspace-Settings-Files.md §3, `[projects] default`). The metacraft
## root is such a workspace.
##
## Legs (a real bare git remote holding the root repository, real bare
## origins for the member repos, the built `repro`):
##   1. PRIMARY — a `settings.v1` root (`repro-workspace.toml`) with
##      `[projects] default = ["alpha", "beta"]`: `init <url> <dest>` exits 0,
##      clones the repos of BOTH default projects, and records both as the
##      active project set; the recorded workspace branch is the root's
##      declared `[workspace] mainline`, since neither project declares
##      `trunk`;
##   2. the same root carrying the old `.repro-workspace.toml`
##      (`bootstrap.v1`) instead, which is still read until it is retired:
##      the default project is joined too.
##
## Mutation-checked: restoring the early return in `resolveBootstrapConfig`
## for a root holding `projects/` fails leg 1 on the exit code ("requires a
## <project-or-variant> name").
##
## No mocks. Hermetic: every repository lives in a fresh temp dir and the
## manifest cache is redirected into it.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc git(args: string; cwd = ""): string =
  let res = execCmdEx("git " & args, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint("git " & args & "\n" & res.output)
    raise newException(OSError, "git failed: " & args)
  res.output.strip()

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedBare(scratch, name, branch: string;
              files: openArray[(string, string)]): string =
  ## A bare repository whose `branch` holds `files` in one commit.
  result = scratch / "remotes" / (name & ".git")
  let work = scratch / ("seed-" & name)
  discard git("init -q -b " & branch & " " & q(work))
  discard git("config user.email t@example.invalid", work)
  discard git("config user.name Tester", work)
  for (rel, body) in files:
    createDir((work / rel).parentDir)
    writeFile(work / rel, body)
  discard git("add -A", work)
  discard git("commit -q -m seed", work)
  createDir(result.parentDir)
  discard git("clone -q --bare " & q(work) & " " & q(result))

proc fragment(name, url: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"" & name & "-origin\"\n" &
    "mainline = \"dev\"\n"

proc project(name, repo, url: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "includes = [\"repos/" & repo & ".toml\"]\n\n" &
    "[project]\nname = \"" & name & "\"\n\n" &
    "[[remote]]\nname = \"" & repo & "-origin\"\nfetch = \"" & url & "\"\n"

const settingsV1 = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
  "[workspace]\nmainline = \"dev\"\nunstable = \"agents\"\n\n" &
  "[projects]\ndefault = [\"alpha\", \"beta\"]\n"

proc legacySettings(rootUrl: string): string =
  ## The old file's shape in a flat-layout root: `[manifest]` names the root
  ## repository itself (the metacraft root carried exactly this), which a
  ## root that already holds `projects/` never clones.
  "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[records]\nurl = \"" & rootUrl & "\"\nbranch = \"dev\"\n" &
    "publish_locks = false\n\n" &
    "[projects]\ndefault = [\"alpha\"]\n"

proc rootFiles(settingsName, settingsBody, libAUrl, libBUrl: string):
    seq[(string, string)] =
  @[(settingsName, settingsBody),
    ("projects/alpha.toml", project("alpha", "lib-a", libAUrl)),
    ("projects/beta.toml", project("beta", "lib-b", libBUrl)),
    ("repos/lib-a.toml", fragment("lib-a", libAUrl)),
    ("repos/lib-b.toml", fragment("lib-b", libBUrl))]

proc coldStart(scratch, rootUrl, dest: string): CmdResult =
  runShell(shellCommand(@[reproBinary(), "workspace", "init", rootUrl, dest],
    env = @[(name: "REPRO_MANIFEST_CACHE", value: scratch / "manifest-cache")]),
    cwd = scratch / "run")

suite "workspace init cold-starts a flat-layout settings root":

  test "t_workspace_init_cold_starts_a_flat_settings_root":
    if findExe("git").len == 0:
      skip("git is not on PATH; the remotes are real git repositories")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      delEnv("REPRO_DEFAULT_PROJECTS")
      let scratch = createTempDir("repro-cold-start-flat-", "")
      defer: removeDir(scratch)
      createDir(scratch / "run")
      let libA = fileUrl(seedBare(scratch, "lib-a", "dev",
        [("README.md", "a\n")]))
      let libB = fileUrl(seedBare(scratch, "lib-b", "dev",
        [("README.md", "b\n")]))

      # ---- leg 1 (PRIMARY): settings.v1 ------------------------------------
      let rootV1 = seedBare(scratch, "root-v1", "dev",
        rootFiles("repro-workspace.toml", settingsV1, libA, libB))
      let dest = scratch / "run" / "joined"
      let init = coldStart(scratch, fileUrl(rootV1), dest)
      checkpoint(init.output)
      check init.code == 0
      check fileExists(dest / "repro-workspace.toml")
      check dirExists(dest / "lib-a" / ".git")
      check dirExists(dest / "lib-b" / ".git")
      let statePath = dest / ".repro" / "workspace-state.toml"
      check fileExists(statePath)
      if fileExists(statePath):
        let state = readFile(statePath)
        checkpoint(state)
        check "\"alpha\"" in state
        check "\"beta\"" in state
        check "branch = \"dev\"" in state

      # ---- leg 2: the old bootstrap.v1 file --------------------------------
      let rootLegacyPath = scratch / "remotes" / "root-legacy.git"
      let rootLegacy = seedBare(scratch, "root-legacy", "dev",
        rootFiles("repro-workspace.toml",
          legacySettings(fileUrl(rootLegacyPath)), libA, libB))
      check rootLegacy == rootLegacyPath
      let legacyDest = scratch / "run" / "joined-legacy"
      let legacy = coldStart(scratch, fileUrl(rootLegacy), legacyDest)
      checkpoint(legacy.output)
      check legacy.code == 0
      check dirExists(legacyDest / "lib-a" / ".git")
      check not dirExists(legacyDest / "lib-b")

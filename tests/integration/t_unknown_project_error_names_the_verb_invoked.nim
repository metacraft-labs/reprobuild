## A project selector that names no project is refused in the words of the
## verb the operator actually ran, with that verb's own remedy.
##
## Every verb that takes `<project>` arguments scopes its repo set through one
## shared selector (`scopeRepoPathSet` -> `resolveNamedProjectOrVariant`).
## Its refusals were written when `sync` was its only caller, so `repro
## workspace branch-roles nosuchproject` said the name was "passed to `repro
## workspace sync`" and told the operator to run `sync`
## (Interactive-UX-And-Progress.md Principle 2: name the specific thing at
## fault). The same held for a repo name passed where a project belongs.
##
## Legs (a real manifest tree and the built `repro`):
##   1. PRIMARY — `repro workspace branch-roles nosuchproject` names
##      `repro workspace branch-roles` as the verb the name was passed to and
##      in its remedy, and names no other verb;
##   2. `repro workspace branch-roles lib-b` (a repo, not a project) names
##      `repro workspace branch-roles --only=lib-b` as the spelling that
##      selects it;
## The workspace has an active project set (`repro workspace enable app
## --no-sync`), which is the case where a positional scopes that set.
##
##   3. control: `repro sync nosuchproject` names the sync verb (in its
##      canonical spelling, `repro workspace sync`) and not `branch-roles`,
##      so the verb in the text is the one invoked rather than a new fixed
##      literal.
##
## Mutation-checked: restoring the literal `repro workspace sync` in the
## unknown-project message fails leg 1 on "passed to `repro workspace
## branch-roles`".
##
## No mocks: the manifests are real files read by the real binary, which
## refuses before any repository is fetched.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc fragment(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"origin\"\nmainline = \"dev\"\n"

proc run(root: string; args: openArray[string]): CmdResult =
  var argv = @[reproBinary()]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & root)
  runShell(shellCommand(argv))

suite "an unknown project is reported against the verb invoked":

  test "t_unknown_project_error_names_the_verb_invoked":
    delEnv("REPRO_WORKSPACE_CONFIG")
    let scratch = createTempDir("repro-unknown-project-verb-", "")
    defer: removeDir(scratch)
    let root = scratch / "workspace"
    createDir(root / "projects")
    createDir(root / "repos")
    writeFile(root / "repro-workspace.toml",
      "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
      "[workspace]\nmainline = \"dev\"\n")
    writeFile(root / "repos" / "lib-a.toml", fragment("lib-a"))
    writeFile(root / "repos" / "lib-b.toml", fragment("lib-b"))
    writeFile(root / "projects" / "app.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "includes = [\"repos/lib-a.toml\", \"repos/lib-b.toml\"]\n\n" &
      "[project]\nname = \"app\"\n\n" &
      "[[remote]]\nname = \"origin\"\nfetch = \"https://example.invalid/acme\"\n")
    # An enabled project, recorded by the real verb: the operator's case, in
    # which a positional SCOPES the active set (a workspace with no recorded
    # set instead resolves the positional as its whole project).
    let enabled = run(root, ["workspace", "enable", "app", "--no-sync"])
    checkpoint(enabled.output)
    require enabled.code == 0

    # ---- leg 1 (PRIMARY) -----------------------------------------------------
    let unknown = run(root, ["workspace", "branch-roles", "nosuchproject"])
    checkpoint(unknown.output)
    check unknown.code != 0
    check "unknown project 'nosuchproject'" in unknown.output
    check "passed to `repro workspace branch-roles`" in unknown.output
    check "run `repro workspace branch-roles` with no project" in
      unknown.output
    check "workspace sync" notin unknown.output
    check "repro sync" notin unknown.output

    # ---- leg 2: a repo where a project belongs ---------------------------
    let repoName = run(root, ["workspace", "branch-roles", "lib-b"])
    checkpoint(repoName.output)
    check repoName.code != 0
    check "'lib-b' is a repo, not a project" in repoName.output
    check "`repro workspace branch-roles --only=lib-b`" in repoName.output
    check "repro sync" notin repoName.output

    # ---- leg 3: control — sync names itself --------------------------------
    let viaSync = run(root, ["sync", "nosuchproject", "--dry-run"])
    checkpoint(viaSync.output)
    check viaSync.code != 0
    check "unknown project 'nosuchproject'" in viaSync.output
    check "passed to `repro workspace sync`" in viaSync.output
    check "branch-roles" notin viaSync.output

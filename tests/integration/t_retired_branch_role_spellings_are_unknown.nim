## Every spelling the branch-roles model and the workspace settings files
## retired is refused as unknown — through the real `repro` — and the refusal
## names what replaced it.
##
## Workspace-Branch-Roles.md §6 step 3 and Workspace-Settings-Files.md §8 step
## 4 remove the old spellings once every workspace has migrated. A retired
## spelling is never read as what it used to mean: it fails, because only a
## failure reliably tells an operator or a script that it is out of date. The
## failure carries the replacement, so the operator does not have to search
## for it. One table-driven case per spelling:
##
## * `repo_v1_fragment` — a `reprobuild.workspace.repo.v1` fragment (its
##   mainline spelled `[repo] branch`) does not load: refused naming the
##   fragment, `reprobuild.workspace.repo.v2` and `mainline`;
## * `repo_branch_key` — `[repo] branch` in a `repo.v2` fragment: refused
##   naming `mainline`;
## * `settings_file_old_name` — a workspace root whose settings file is
##   `.repro-workspace.toml`: refused naming `repro-workspace.toml` and the
##   `[records]` rewrite, both when named with `--workspace-root` and when
##   found by root discovery from a directory inside it (not walked past);
## * `settings_private_url` — the old `[manifest] private_url` in the current
##   settings file: refused naming the key;
## * `state_file_old_name` — a root whose state file is `.repro/workspace.toml`:
##   refused naming `repro health --fix`, likewise also through discovery;
## * `project_trunk` / `project_default_revision` — `[project] trunk` and
##   `[project] default_revision`: refused naming the key and its replacement;
## * `from_mainlines_flag` — `repro branch <path> --from-mainlines`: an
##   unsupported flag (exit 1, like every unknown flag) naming `--from=mainline`.
##
## Each case is also checked to leave the workspace untouched, and a positive
## control runs the same command on the current spelling of the same content,
## so a refusal cannot pass because the fixture itself is broken.
##
## No mocks: real files in temporary directories and the real `repro` binary.
## Hermetic: no network, no clone — the commands only read manifests.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc repro(args: openArray[string]): CmdResult =
  ## The binary with no inherited settings override, so discovery is tested.
  runShell(shellCommand(@[reproBinary()] & @args,
    [("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", "")]))

const currentSettings = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
  "[workspace]\nmainline = \"main\"\n"

const currentState = "schema = \"reprobuild.workspace.state.v1\"\n\n" &
  "[workspace]\nproject = \"demo\"\n"

proc projectToml(extra = ""): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "includes = [\"repos/w.toml\"]\n\n[project]\nname = \"demo\"\n" & extra &
    "\n[[remote]]\nname = \"acme\"\nfetch = \"https://git.example.invalid/acme\"\n"

const currentFragment = "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
  "[repo]\nname = \"w\"\npath = \"w\"\nremote = \"acme\"\nmainline = \"dev\"\n"

type
  Shape = object
    ## One workspace root, as files relative to it.
    files: seq[(string, string)]

  RetiredCase = object
    name: string
    retired: Shape        ## the workspace carrying the retired spelling
    current: Shape        ## the same content in the current spelling
    command: seq[string]  ## run with `--workspace-root=<root>` appended
    code: int             ## the refusal's exit code; -1 = any non-zero
    needles: seq[string]  ## what the refusal must name ("{root}" expands)
    currentOk: bool       ## whether the current spelling must exit 0

proc materialize(scratch, name: string; shape: Shape): string =
  result = scratch / name
  createDir(result)
  for (rel, text) in shape.files:
    createDir(parentDir(result / rel))
    writeFile(result / rel, text)

proc snapshot(root: string): seq[(string, string)] =
  ## Every file under `root` and its bytes — to prove a refusal wrote nothing.
  for path in walkDirRec(root):
    result.add((relativePath(path, root), readFile(path)))

proc baseFiles(): seq[(string, string)] =
  @[("repro-workspace.toml", currentSettings),
    (".repro/workspace-state.toml", currentState),
    ("projects/demo.toml", projectToml()),
    ("repos/w.toml", currentFragment)]

proc replaced(files: seq[(string, string)]; rel, text: string;
              newRel = ""): seq[(string, string)] =
  ## `files` with `rel` replaced by `text` (under `newRel` when given), or
  ## dropped when `text` is empty.
  for (r, t) in files:
    if r == rel:
      if text.len > 0:
        let target = if newRel.len > 0: newRel else: r
        result.add((target, text))
    else:
      result.add((r, t))

proc cases(): seq[RetiredCase] =
  let base = baseFiles()
  let listRoles = @["workspace", "branch-roles", "demo"]
  let listEnabled = @["workspace", "projects", "list", "--enabled"]
  result.add(RetiredCase(name: "repo_v1_fragment",
    retired: Shape(files: base.replaced("repos/w.toml",
      currentFragment.replace("repo.v2", "repo.v1")
        .replace("mainline = ", "branch = "))),
    current: Shape(files: base),
    command: listRoles, code: -1, currentOk: true,
    needles: @["{root}/repos/w.toml", "reprobuild.workspace.repo.v1",
               "reprobuild.workspace.repo.v2", "`mainline`"]))
  result.add(RetiredCase(name: "repo_branch_key",
    retired: Shape(files: base.replaced("repos/w.toml",
      currentFragment.replace("mainline = ", "branch = "))),
    current: Shape(files: base),
    command: listRoles, code: -1, currentOk: true,
    needles: @["{root}/repos/w.toml", "repo.branch", "`mainline`"]))
  result.add(RetiredCase(name: "settings_file_old_name",
    retired: Shape(files: base.replaced("repro-workspace.toml",
      "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n[manifest]\n" &
        "url = \"https://git.example.invalid/acme/records.git\"\n",
      newRel = ".repro-workspace.toml")),
    current: Shape(files: base),
    command: listRoles, code: -1, currentOk: true,
    needles: @["{root}/.repro-workspace.toml", "repro-workspace.toml",
               "reprobuild.workspace.settings.v1", "[records]"]))
  result.add(RetiredCase(name: "settings_private_url",
    retired: Shape(files: base.replaced("repro-workspace.toml",
      currentSettings & "\n[manifest]\n" &
        "private_url = \"git@git.example.invalid:acme/internal\"\n")),
    current: Shape(files: base),
    command: listRoles, code: -1, currentOk: true,
    needles: @["{root}/repro-workspace.toml", "`[manifest]`", "`[records]",
               "`private_url` is a named `[[manifest]]` layer"]))
  result.add(RetiredCase(name: "state_file_old_name",
    retired: Shape(files: base.replaced(".repro/workspace-state.toml",
      currentState.replace("state.v1", "local.v1"),
      newRel = ".repro/workspace.toml")),
    current: Shape(files: base),
    command: listEnabled, code: -1, currentOk: true,
    needles: @["{root}/.repro/workspace.toml", "repro health --fix",
               ".repro/workspace-state.toml"]))
  result.add(RetiredCase(name: "project_trunk",
    retired: Shape(files: base.replaced("projects/demo.toml",
      projectToml("trunk = \"main\"\n"))),
    current: Shape(files: base),
    command: listRoles, code: -1, currentOk: true,
    needles: @["{root}/projects/demo.toml", "project.trunk",
               "`[workspace] mainline`"]))
  result.add(RetiredCase(name: "project_default_revision",
    retired: Shape(files: base.replaced("projects/demo.toml",
      projectToml("default_revision = \"main\"\n"))),
    current: Shape(files: base),
    command: listRoles, code: -1, currentOk: true,
    needles: @["{root}/projects/demo.toml", "project.default_revision",
               "`mainline`"]))
  result.add(RetiredCase(name: "from_mainlines_flag",
    retired: Shape(files: base), current: Shape(files: base),
    command: @["branch", "{scratch}/fork-from-mainlines", "--from-mainlines"],
    code: 1, currentOk: false,
    needles: @["unsupported `repro branch` flag: --from-mainlines",
               "`--from=mainline`", "`--mainline`"]))

proc expand(s, root, scratch: string): string =
  s.replace("{root}", root).replace("{scratch}", scratch)

suite "retired branch-role spellings are unknown":

  for c in cases():
    test "t_retired_branch_role_spellings_are_unknown: " & c.name:
      let scratch = createTempDir("repro-retired-" & c.name & "-", "")
      defer: removeDir(scratch)
      let root = materialize(scratch, "retired", c.retired)
      let before = snapshot(root)
      var argv: seq[string]
      for a in c.command:
        argv.add(expand(a, root, scratch))
      argv.add("--workspace-root=" & root)
      let res = repro(argv)
      checkpoint(c.name & " exit=" & $res.code & "\n" & res.output)
      # PRIMARY: refused, naming the retired spelling's replacement.
      if c.code < 0:
        check res.code != 0
      else:
        check res.code == c.code
      for needle in c.needles:
        let n = expand(needle, root, scratch)
        if n notin res.output:
          checkpoint("missing from the refusal: " & n)
        check n in res.output
      # Nothing was written: no state, no settings, no fork.
      check snapshot(root) == before
      check not dirExists(scratch / "fork-from-mainlines")

      # A retired settings or state file name is found by root DISCOVERY
      # too: run from a directory inside the root with no
      # `--workspace-root`, the command still refuses there naming the file
      # and the remedy, rather than walking past it as "no workspace".
      if c.name in ["settings_file_old_name", "state_file_old_name"]:
        let inside = root / "inside"
        createDir(inside)
        let discovered = runShell(shellCommand(@[reproBinary()] & c.command,
          [("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", "")]),
          cwd = inside)
        checkpoint("discovered from " & inside & " exit=" &
          $discovered.code & "\n" & discovered.output)
        check discovered.code != 0
        let retiredName =
          if c.name == "settings_file_old_name": ".repro-workspace.toml"
          else: ".repro/workspace.toml"
        check retiredName in discovered.output
        check c.needles[^1] in discovered.output
        removeDir(inside)
        check snapshot(root) == before

      # Positive control: the current spelling of the same content is read.
      if c.currentOk:
        let ok = materialize(scratch, "current", c.current)
        var okArgv: seq[string]
        for a in c.command:
          okArgv.add(expand(a, ok, scratch))
        okArgv.add("--workspace-root=" & ok)
        let good = repro(okArgv)
        checkpoint("current spelling exit=" & $good.code & "\n" & good.output)
        check good.code == 0

## ``repro workspace sync`` — ``--only`` / ``--except`` / ``--filter`` are
## honoured on the DEFAULT sync path, not just under ``--mainline``.
##
## WHY THIS TEST EXISTS
##
## The three selectors parsed, validated their arguments, and were then
## dropped. ``applyRepoSelectors`` was called from exactly one place —
## ``executeMainlineSync`` — and ``executeWorkspaceSync``, the executor an
## operator reaches by typing ``repro workspace sync``, applied the scope
## filter and the RA-18 tag filter and never called it. Measured against a
## real 112-repo workspace at ca49246a:
##
##   repro workspace sync codetracer --only=codetracer-miden-recorder \
##     --dry-run --json   ->  exit 0, plan = 112 repos
##   ... --filter=codetracer-*-recorder                ->  exit 0, plan = 112
##   ... --except=codetracer                           ->  exit 0, plan = 112
##   ... --only=no-such-repo-xyz  (a typo)             ->  exit 0, plan = 112
##
## Nothing on stdout, stderr or the exit code distinguished "the selector
## worked" from "the selector was ignored". That is what made it impossible
## to scope a recovery to one repo after eleven remotes were force-pushed:
## the narrowest operation the CLI advertises silently became the widest one
## available.
##
## A silently-ignored selector is worse than an unsupported one. An
## unsupported flag is refused at the parser and the operator learns at once;
## an ignored one is indistinguishable from a working one until the blast
## radius arrives. So the last case below is as load-bearing as the first
## three: a name that matches nothing must REFUSE, never expand to
## everything.
##
## The assertions are COUNTS and NAMES, not "fewer than before". A selector
## that dropped every repo would also be "narrower", and would pass a
## looser check while being a different defect.
##
## Skip rule: ``git`` missing on PATH (the convention this suite follows).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Selector Tester\"")
  writeFile(workPath / "README.md", "selector fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc repoFragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & name & "\"\n" &
  "revision = \"main\"\n"

proc projectToml(project: string; remotes: seq[(string, string)]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"" & project & "\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, url) in remotes:
    result.add("[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url &
      "\"\n\n")
  result.add("includes = [\n")
  for (name, _) in remotes:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

const
  FixtureRepoNames = ["alpha-recorder", "beta-recorder", "gamma-tool"]
    ## ``selproject``'s repos -- the set every selector below narrows.
  OtherProjectRepoNames = ["delta-tool"]
    ## A SECOND project's repos. They exist so the positional form has
    ## something to exclude: ``repro workspace sync selproject`` must plan
    ## three repos, not four. Positional project scoping already worked
    ## before this change and must keep working after it -- the selectors are
    ## being folded into the same narrowing step, and a regression there
    ## would widen every scoped sync in the workspace.

type SelectorFixture = object
  scratch: string
  reproBin: string
  workspaceRoot: string

proc setupFixture(gitBin: string): SelectorFixture =
  let scratch = createTempDir("repro-sync-selectors-", "")
  result.scratch = scratch
  result.reproBin = reproBinary()
  let workspaceRoot = scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  # ``scratch`` is read through the local, not through ``result``: the
  # nested proc has a ``result`` of its own.
  proc materialize(names: openArray[string]): seq[(string, string)] =
    for name in names:
      let origin = scratch / ("origin-" & name & ".git")
      discard seedOrigin(gitBin, origin, scratch / ("seed-" & name))
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
        q(workspaceRoot / name))
      writeFile(workspaceRoot / "repos" / (name & ".toml"),
        repoFragmentToml(name))
      result.add((name, fileUrl(origin)))

  writeFile(workspaceRoot / "projects" / "selproject.toml",
    projectToml("selproject", materialize(FixtureRepoNames)))
  writeFile(workspaceRoot / "projects" / "otherproject.toml",
    projectToml("otherproject", materialize(OtherProjectRepoNames)))
  result.workspaceRoot = workspaceRoot

proc plannedNames(fixture: SelectorFixture;
                  extra: seq[string];
                  projects: seq[string] = @["selproject"]):
                 tuple[code: int; names: seq[string]; output: string] =
  ## Run a DRY-RUN sync and return the planned repo names. ``--dry-run`` is
  ## the right surface here: the plan is computed from the final
  ## participating set, so it answers "which repos would this touch" without
  ## touching any.
  var argv = @[fixture.reproBin, "workspace", "sync"]
  argv.add(projects)
  argv.add(@["--dry-run", "--json",
    "--workspace-root=" & fixture.workspaceRoot])
  argv.add(extra)
  let res = runShell(shellCommand(argv))
  var names: seq[string]
  if res.code == 0:
    try:
      let doc = parseJson(res.output)
      for entry in doc["plan"]:
        names.add(entry["name"].getStr())
    except JsonParsingError, KeyError:
      checkpoint("could not read the plan out of: " & res.output)
  (code: res.code, names: names, output: res.output)

suite "repro workspace sync — repo selectors on the default path":

  test "t_workspace_sync_selectors_narrow_the_default_path":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fixture = setupFixture(gitBin)
      defer: removeDir(fixture.scratch)

      # POSITIONAL SCOPING -- asserted FIRST and on its own, because it
      # already worked and the selectors are being folded into the same
      # narrowing step. A regression here would widen every scoped sync in
      # the workspace: the defect this change removes, reintroduced one
      # layer up.
      let scoped = plannedNames(fixture, @[])
      check scoped.code == 0
      check scoped.names.len == FixtureRepoNames.len
      for name in FixtureRepoNames:
        check name in scoped.names
      for name in OtherProjectRepoNames:
        check name notin scoped.names

      let otherScoped = plannedNames(fixture, @[], @["otherproject"])
      check otherScoped.code == 0
      check otherScoped.names == @OtherProjectRepoNames

      # The baseline the selectors below narrow: ``selproject``'s own set,
      # three repos. Stated explicitly so a narrowing assertion cannot pass
      # against a workspace that only ever had one repo.
      let all = scoped
      check all.names.len == 3

      # ``--only`` names one repo EXACTLY. Against the unfixed executor this
      # planned all three.
      let only = plannedNames(fixture, @["--only=beta-recorder"])
      check only.code == 0
      check only.names == @["beta-recorder"]

      # ``--only`` with several names.
      let onlyTwo = plannedNames(fixture,
        @["--only=alpha-recorder,gamma-tool"])
      check onlyTwo.code == 0
      check onlyTwo.names.len == 2
      check "alpha-recorder" in onlyTwo.names
      check "gamma-tool" in onlyTwo.names
      check "beta-recorder" notin onlyTwo.names

      # ``--filter`` globs the repo NAME.
      let filtered = plannedNames(fixture, @["--filter=*-recorder"])
      check filtered.code == 0
      check filtered.names.len == 2
      check "alpha-recorder" in filtered.names
      check "beta-recorder" in filtered.names
      check "gamma-tool" notin filtered.names

      # ``--except`` drops, and exclusion wins over inclusion.
      let excepted = plannedNames(fixture, @["--except=gamma-tool"])
      check excepted.code == 0
      check excepted.names.len == 2
      check "gamma-tool" notin excepted.names

      let both = plannedNames(fixture,
        @["--only=alpha-recorder,beta-recorder", "--except=beta-recorder"])
      check both.code == 0
      check both.names == @["alpha-recorder"]

      # A name that matches nothing REFUSES. This is the case that makes the
      # others meaningful: a selector that cannot be applied must fail
      # loudly rather than widen to the whole workspace, which is precisely
      # what the unfixed path did — exit 0 and all three repos planned.
      let typo = plannedNames(fixture, @["--only=no-such-repo"])
      check typo.code != 0
      check typo.names.len == 0
      check "no-such-repo" in typo.output
      # The refusal must also not be a bare non-zero: it names the flag and
      # says how to see the real set.
      check "--only=no-such-repo" in typo.output
      check "repos list" in typo.output

      let typoExcept = plannedNames(fixture, @["--except=no-such-repo"])
      check typoExcept.code != 0
      check typoExcept.names.len == 0

      # POSITIONAL SCOPE AND SELECTOR COMPOSE, scope first. ``delta-tool``
      # is a real repo in this workspace but not in ``selproject``'s scope,
      # so naming it must REFUSE rather than reach outside the scope and
      # pull it in -- and must still be accepted when the scope includes it.
      let outOfScope = plannedNames(fixture, @["--only=delta-tool"])
      check outOfScope.code != 0
      check outOfScope.names.len == 0

      let inScope = plannedNames(fixture, @["--only=delta-tool"],
        @["otherproject"])
      check inScope.code == 0
      check inScope.names == @["delta-tool"]

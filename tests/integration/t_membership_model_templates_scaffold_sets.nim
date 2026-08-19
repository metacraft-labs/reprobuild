## Workspace-Membership-Model.md §"Templates" — `repro ws sets add` scaffolds
## from a template, and a configured default is REPORTED rather than applied
## silently.
##
## Why templates exist: with an empty stub, every new repo-set hand-lists
## whatever the last one had, so a set added minutes after its siblings can
## silently lack something all of them carry. Why the reporting matters as much
## as the seeding: a mechanism introduced because membership was invisibly
## hand-copied would reproduce that defect one level up if the default applied
## invisibly — the operator would again not know what their set contains or
## why. So the org default is policy in the host config, and every application
## of it names the template AND where the choice came from.
##
## Asserted:
##   1. `--template=<t>` seeds the new set's `member_sets` / `member_repos`
##      from `templates/<t>.toml`, the result is accepted by the REAL strict
##      repo-set reader, and the run REPORTS which template it applied.
##   2. `[projects] default_template` in the host bootstrap config applies with
##      no flag at all — and the report names both the template and the config
##      as its source. A silently-applied default is the failure mode this
##      whole mechanism exists to avoid, so "it was reported" is asserted as
##      strictly as "it was applied".
##   3. `--no-template` opts out: the file is the empty stub, and NOTHING is
##      reported as applied.
##   4. `--template=<missing>` FAILS with a nonzero exit naming the template.
##   5. A configured default naming a template that does not exist ALSO fails,
##      rather than falling back to the empty stub — the dangerous direction,
##      because a silent fallback is indistinguishable from the template having
##      been applied.
##   6. `--template=<t> --no-template` is a contradiction and is refused; one
##      of the two flags would otherwise be a no-op the operator never sees.
##   7. The retained `projects add` spelling takes templates too, and the
##      seeded `projects/<name>.toml` PARSES. This is the ordering trap: a
##      membership key written after `[project]` is standard-TOML-bound to that
##      table and the strict decode rejects the file, so the assertion is made
##      through the real reader rather than by string match.
##   8. A template may not carry a fixed set name: `[repo-set] name` inside a
##      template file is refused by the strict decode. `[template] name` is the
##      TEMPLATE's identity; the scaffolded set's name always comes from the
##      `add` argument.
##
## Falsifiability: each case checks the resolved membership through the real
## readers AND the process exit code, so a template that was located but not
## seeded, seeded but not reported, or reported but not written all fail
## distinct assertions.
##
## No mocks: a real git manifest repo on disk, the real `repro` binary, and the
## real strict readers. Skip rule: only when `git` is missing from PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const serviceTemplate = """
schema = "reprobuild.workspace.template.v1"

[template]
name = "service"

member_sets = ["shared-infrastructure"]
member_repos = ["service-scaffolding"]
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin, slug: string; defaultTemplate = ""): Fixture =
  ## A manifest repo carrying one template, plus the two member names it seeds
  ## so the seeded entries name things that exist. `defaultTemplate`, when
  ## given, is written into the host bootstrap config's `[projects]` table —
  ## the ONLY place the default may come from, since policy lives in org config
  ## and never in the binary.
  result.scratch = createTempDir("repro-mm-tpl-" & slug & "-", "")
  result.reproBin = reproBinary()
  let root = result.scratch / "workspace"
  createDir(root / "templates")
  createDir(root / "repo-sets")
  createDir(root / "repos")
  createDir(root / "projects")
  writeFile(root / "templates" / "service.toml", serviceTemplate)
  writeFile(root / "repo-sets" / "shared-infrastructure.toml",
    "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
    "[repo-set]\nname = \"shared-infrastructure\"\n\n" &
    "member_sets = [\n]\n\nmember_repos = [\n]\n")
  writeFile(root / "repos" / "service-scaffolding.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"service-scaffolding\"\npath = \"service-scaffolding\"\n" &
    "branch = \"main\"\nurl_prefix = \"acme\"\n")
  var bootstrap =
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\nurl = \"https://git.example.invalid/acme/manifests\"\n"
  if defaultTemplate.len > 0:
    bootstrap.add("\n[projects]\ndefault_template = \"" &
      defaultTemplate & "\"\n")
  writeFile(root / ".repro-workspace.toml", bootstrap)
  discard requireGit(q(gitBin) & " init -b main " & q(root))
  discard requireGit(q(gitBin) & " -C " & q(root) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(root) &
    " config user.name \"Template Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(root) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(root) & " commit -m fixture")
  result.workspaceRoot = root

proc runRepro(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

suite "membership model — repo-set templates":

  test "t_template_seeds_membership_and_is_reported":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "explicit")
      defer: removeDir(fx.scratch)

      let added = runRepro(fx, ["ws", "sets", "add", "billing",
        "--template=service"])
      if added.code != 0:
        checkpoint("output: " & added.output)
      check added.code == 0

      # (1) SEEDED — read back through the real strict reader, so a file that
      # was written but does not parse fails here rather than downstream.
      let setFile = fx.workspaceRoot / "repo-sets" / "billing.toml"
      check fileExists(setFile)
      let m = readRepoSet(setFile)
      check m.`repo-set`.name == "billing"
      check m.member_sets == @["shared-infrastructure"]
      check m.member_repos == @["service-scaffolding"]

      # (1) REPORTED — naming the template, not merely "a template".
      check added.output.contains("applied template 'service'")

  test "t_default_template_from_host_config_is_applied_and_reported":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "default", defaultTemplate = "service")
      defer: removeDir(fx.scratch)

      # No flag at all: the org default is the whole point of the config key.
      let added = runRepro(fx, ["ws", "sets", "add", "payments"])
      if added.code != 0:
        checkpoint("output: " & added.output)
      check added.code == 0

      let m = readRepoSet(fx.workspaceRoot / "repo-sets" / "payments.toml")
      check m.member_sets == @["shared-infrastructure"]
      check m.member_repos == @["service-scaffolding"]

      # The report names the template AND its source. "Which template did this
      # come from, and who decided" has to be answerable from the transcript;
      # if it is only answerable by reading the org config, the default is
      # effectively silent.
      check added.output.contains("applied template 'service'")
      check added.output.contains(".repro-workspace.toml")
      check added.output.contains("default_template")

  test "t_no_template_opts_out_of_the_configured_default":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "optout", defaultTemplate = "service")
      defer: removeDir(fx.scratch)

      let added = runRepro(fx, ["ws", "sets", "add", "scratchpad",
        "--no-template"])
      if added.code != 0:
        checkpoint("output: " & added.output)
      check added.code == 0

      let m = readRepoSet(fx.workspaceRoot / "repo-sets" / "scratchpad.toml")
      check m.member_sets.len == 0
      check m.member_repos.len == 0
      # Nothing was applied, so nothing is reported as applied. The absence
      # assertion is what stops the report from becoming noise that is printed
      # whether or not a template ran.
      check "applied template" notin added.output

  test "t_missing_template_fails_loudly_from_either_source":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # (4) An explicit `--template=` naming nothing.
      let fx = setupFixture(gitBin, "missing")
      defer: removeDir(fx.scratch)
      let explicitMiss = runRepro(fx, ["ws", "sets", "add", "ghosted",
        "--template=nosuch"])
      check explicitMiss.code != 0
      check explicitMiss.output.contains("nosuch")
      check not fileExists(fx.workspaceRoot / "repo-sets" / "ghosted.toml")

      # (5) A CONFIGURED default naming nothing. This is the dangerous
      # direction: falling back to the empty stub here is indistinguishable
      # from the template having been applied, so it must fail instead.
      let fx2 = setupFixture(gitBin, "missing-default",
        defaultTemplate = "nosuch")
      defer: removeDir(fx2.scratch)
      let defaultMiss = runRepro(fx2, ["ws", "sets", "add", "ghosted2"])
      check defaultMiss.code != 0
      check defaultMiss.output.contains("nosuch")
      check defaultMiss.output.contains("--no-template")
      check not fileExists(fx2.workspaceRoot / "repo-sets" / "ghosted2.toml")

  test "t_template_and_no_template_together_are_refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "contradiction")
      defer: removeDir(fx.scratch)
      let res = runRepro(fx, ["ws", "sets", "add", "confused",
        "--template=service", "--no-template"])
      check res.code == 2
      check res.output.contains("contradict")
      check not fileExists(fx.workspaceRoot / "repo-sets" / "confused.toml")

  test "t_project_spelling_takes_templates_and_the_result_parses":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "project")
      defer: removeDir(fx.scratch)
      let added = runRepro(fx, ["ws", "projects", "add", "legacy-service",
        "--template=service"])
      if added.code != 0:
        checkpoint("output: " & added.output)
      check added.code == 0
      check added.output.contains("applied template 'service'")

      # The ordering trap, asserted through the reader rather than by string
      # match: a membership key written AFTER `[project]` binds to that table
      # under standard TOML, the strict decode rejects `project.member_sets`,
      # and the file stops parsing. A passing read is the only proof the stub
      # put the arrays where they parse.
      let projectFile = fx.workspaceRoot / "projects" / "legacy-service.toml"
      let m = readProjectManifest(projectFile)
      check m.project.name == "legacy-service"
      check m.member_sets == @["shared-infrastructure"]
      check m.member_repos == @["service-scaffolding"]

  test "t_template_may_not_carry_a_fixed_set_name":
    # (8) A distinct schema exists precisely so this is unrepresentable. If a
    # template could carry the scaffolded set's name, it would be a repo-set
    # that scaffolds a copy of itself, and `add <name>` would have a second,
    # silent source of the name it was given.
    let d = createTempDir("repro-mm-tpl-schema-", "")
    defer: removeDir(d)
    let f = d / "bad.toml"
    writeFile(f, """
schema = "reprobuild.workspace.template.v1"

[template]
name = "bad"

[repo-set]
name = "hardcoded"
""")
    var refused = false
    try:
      discard readTemplate(f)
    except WorkspaceManifestParseError:
      refused = true
    check refused

    # The positive control on the same reader, so the refusal above is about
    # the extra table and not about the schema failing to read at all.
    let ok = d / "good.toml"
    writeFile(ok, serviceTemplate)
    let good = readTemplate(ok)
    check good.`template`.name == "service"
    check good.member_sets == @["shared-infrastructure"]

## DS-7 (CLI/develop.md §"Membership axis") — **exact-name selectors are
## LOUD**.
##
##   > `--only` and `--except` name repos **exactly**; a name matching nothing
##   > is a loud error, never a silent no-op. `--filter` is a glob and may
##   > legitimately match nothing, which is reported as an empty selection
##   > rather than an error.
##
## Why this is not cosmetic. A typo in `--except` is the dangerous direction:
## `--all --except=llvm-projet` that silently matches nothing does not narrow
## anything — it clones the heavyweight repo the user was explicitly excluding,
## which is exactly the outcome the flag was typed to prevent. The symmetric
## `--only` typo selects nothing and looks like a workspace with no lock set.
## Before this milestone `--except`, `--project` and `--group` did not exist,
## and `--only` was the only selector with the check.
##
## The same rule binds `--project` and `--group`, which also name things
## exactly. Only `--filter` is a glob.
##
## Names are validated against the WHOLE lock set (and the whole active project
## / declared group universe), never against whatever an earlier stage left:
## `--direct --except=X` for an X that exists but is not a direct edge is a
## legitimate no-op, and validating against a stage's input would additionally
## make the ERROR depend on argv order — the very thing the fixed composition
## order exists to prevent. This test asserts that too.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline): the same
## multi-project, grouped workspace shape the fixed-order test uses, reduced to
## what the loudness rule needs — two projects, three repos, two groups.
##
## Asserts:
##   1. `--only=<unknown>` refuses (exit 2) and names the flag and the name;
##   2. `--except=<unknown>` refuses identically — the case that did not exist;
##   3. `--project=<unknown>` refuses and NAMES the workspace's active set;
##   4. `--group=<unknown>` refuses and NAMES the declared groups;
##   5. a typo among good names still refuses (one bad name is enough), and
##      NOTHING is mutated by the refusal;
##   6. `--filter=<glob matching nothing>` is NOT an error: exit 0, empty
##      selection, reported as such;
##   7. the refusal is argv-order independent and stage-independent: an
##      `--except` naming a repo that a preceding `--group` already removed is
##      accepted (it names a real repo), while an `--except` naming a repo that
##      does not exist at all is refused regardless of which other selectors
##      are present;
##   8. `--list --json` carries the same diagnostics in an `errors` array —
##      the form the spec tells machine consumers to prefer must not be the
##      one that says nothing about why it refused.
##   9. a SELF-CANCELLING selection refuses: `--only=X --except=X` names X
##      twice, once to keep it and once to drop it, and used to exit 0 having
##      selected nothing. Both names are real, so (1) and (2) have nothing to
##      say about it — but the outcome is the silent no-op the whole section
##      exists to forbid. The rule is over the NAMES, so `--only=a,b
##      --except=b` refuses too, and it is reported after the unknown-name
##      check so a typo is still diagnosed as a typo.
##  10. the same refusal reaches `--list --json`'s `errors` array, for the
##      same reason as (8).
##
## Falsifiability / pre-fix failure: against ``391a892a`` this test fails at
## (2) with
##
##   repro develop: error: unsupported `repro develop --all` argument:
##   --except=nope
##
## Mutation check: dropping the `--except` arm of the exact-name block makes
## (2) exit 0 with the repo still selected; validating `--except` against the
## post-`--group` stage input instead of the lock set makes (7) refuse a name
## that names a real repo; deleting the `contradictorySelection` block makes
## (9) exit 0 with an empty selection, and ordering it BEFORE the exact-name
## block makes (9)'s typo arm report a contradiction instead of the unknown
## name it actually contains.
##
## Mocks: NONE. Real git repositories, a real manifest checkout, the real
## ``repro`` binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir; every configuration layer except the fixture's own
## layer 4 is silenced. Skip: ``git`` missing or ``repro`` unbuilt.

import std/[json, os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"DS7 Loud Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc repoFragment(name, remote: string; groups: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\n" &
    "revision = \"main\"\n"
  if groups.len > 0:
    result.add("groups = [\"" & groups.join("\", \"") & "\"]\n")

proc selectedRepos(output: string): seq[string] =
  var inTable = false
  for line in output.splitLines():
    if line.startsWith("REPO "):
      inTable = true
      continue
    if not inTable: continue
    if line.startsWith("repro develop"): continue
    let name = line.split(' ')[0].strip()
    if name.len > 0: result.add(name)

suite "DS-7: exact-name selectors refuse a name that matches nothing":

  test "t_develop_only_except_refuse_unknown_names":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds7-loud-", "")
      defer: removeDir(scratch)

      let repos = ["lib-core", "tool-a", "tool-b"]
      for name in repos:
        discard seedGitOrigin(gitBin, scratch / ("origin-" & name & ".git"),
          scratch / ("seed-" & name))

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")

      var remoteBlock = ""
      for name in repos:
        remoteBlock.add("[[remote]]\nname = \"" & name & "-origin\"\n" &
          "fetch = \"file://" & scratch / ("origin-" & name & ".git") &
          "\"\n\n")

      writeFile(manifestsRoot / "repos" / "lib-core.toml",
        repoFragment("lib-core", "lib-core-origin", @["libs"]))
      writeFile(manifestsRoot / "repos" / "tool-a.toml",
        repoFragment("tool-a", "tool-a-origin", @["tools"]))
      writeFile(manifestsRoot / "repos" / "tool-b.toml",
        repoFragment("tool-b", "tool-b-origin", @["tools"]))

      proc projectToml(name: string; includes: seq[string]): string =
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\n" &
        "name = \"" & name & "\"\n" &
        "default_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        remoteBlock &
        "includes = [\n  \"repos/" & includes.join(".toml\",\n  \"repos/") &
        ".toml\",\n]\n"

      writeFile(manifestsRoot / "projects" / "alpha.toml",
        projectToml("alpha", @["lib-core", "tool-a"]))
      writeFile(manifestsRoot / "projects" / "beta.toml",
        projectToml("beta", @["tool-b"]))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      for name in repos:
        discard requireGit(q(gitBin) & " clone " &
          q("file://" & scratch / ("origin-" & name & ".git")) & " " &
          q(ws / name))

      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"alpha\"\n" &
        "projects = [\"alpha\", \"beta\"]\n" &
        "branch = \"main\"\n")
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"lib-core\", \"tool-a\", " &
        "\"tool-b\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws),
        cwd = ws)
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      let deps = scratch / "deps"
      proc develop(flags: string): tuple[code: int; output: string] =
        run(repro & " develop --tool-provisioning=path --into=" & q(deps) &
          " " & flags, cwd = ws)
      proc list(flags: string): tuple[code: int; output: string] =
        run(repro & " develop --list --tool-provisioning=path " & flags,
          cwd = ws)

      # ---- (1) --only=<unknown> refuses. ---------------------------------
      let badOnly = develop("--only=lib-cor")
      check badOnly.code == 2
      check "'--only=lib-cor' names no repo in this workspace's lock set" in
        badOnly.output
      check "matched EXACTLY" in badOnly.output
      check not dirExists(deps)

      # ---- (2) --except=<unknown> refuses identically. -------------------
      let badExcept = develop("--all --except=nope")
      check badExcept.code == 2
      check "'--except=nope' names no repo in this workspace's lock set" in
        badExcept.output
      check not dirExists(deps)

      # ---- (3) --project=<unknown> refuses and names the active set. -----
      let badProject = develop("--project=gamma")
      check badProject.code == 2
      check "'--project=gamma' names no project in this workspace's active " &
        "project set" in badProject.output
      check "alpha, beta" in badProject.output
      check not dirExists(deps)

      # ---- (4) --group=<unknown> refuses and names the declared groups. --
      let badGroup = develop("--group=toolz")
      check badGroup.code == 2
      check "'--group=toolz' names no manifest group in this workspace" in
        badGroup.output
      # Every repo here DECLARES groups, so no repo falls into the implicit
      # `default` group and `default` is correctly not among the declared ones.
      check "the declared groups are: libs, tools" in badGroup.output
      check not dirExists(deps)

      # ---- (5) one bad name among good ones is still a refusal. ----------
      let mixed = develop("--all --except=tool-a,typo-here")
      check mixed.code == 2
      check "'--except=typo-here'" in mixed.output
      check "'--except=tool-a'" notin mixed.output
      check not dirExists(deps)

      # ---- (6) --filter matching nothing is NOT an error. ----------------
      let emptyFilter = list("--filter='zzz-*'")
      check emptyFilter.code == 0
      check selectedRepos(emptyFilter.output).len == 0
      check "the selection is empty" in emptyFilter.output
      let emptyFilterRun = develop("--all --filter='zzz-*'")
      check emptyFilterRun.code == 0
      check not dirExists(deps)

      # ---- (7) validated against the LOCK SET, not against a stage. ------
      # `tool-b` is a real repo that `--group=libs` has already removed by the
      # time `--except` runs. Naming it is a legitimate no-op, NOT a typo.
      let laterStage = list("--group=libs --except=tool-b")
      check laterStage.code == 0
      check selectedRepos(laterStage.output) == @["lib-core"]
      # …while a name that exists nowhere is refused whatever else is present,
      # and in whatever argv order.
      for flags in ["--group=libs --except=ghost",
                    "--except=ghost --group=libs",
                    "--all --filter='lib-*' --except=ghost"]:
        let refused = list(flags)
        check refused.code == 2
        check "'--except=ghost' names no repo" in refused.output

      # ---- (8) the MACHINE-READABLE form says why, too. -------------------
      #
      # "Machine consumers should use `--json`" (CLI/develop.md §"Action
      # axis"). A refusal on the query path produces no rows and a non-zero
      # exit; if the diagnostic is only written to the text form's stderr, the
      # machine consumer that was told to prefer `--json` gets exit 2, an empty
      # repo list, and nothing saying why. The `errors` array carries the same
      # diagnostics the text form prints.
      let refusedJson = list("--json --only=lib-cor")
      check refusedJson.code == 2
      let report = parseJson(refusedJson.output)
      check report["schemaId"].getStr() == "reprobuild.develop-list.v1"
      check report["exitCode"].getInt() == 2
      check report["repos"].len == 0
      check report["errors"].len == 1
      check report["errors"][0]["node"].getStr() == "lib-cor"
      check "names no repo in this workspace's lock set" in
        report["errors"][0]["diagnostic"].getStr()
      # A SUCCESSFUL query carries an empty `errors`, so a consumer can read
      # the field unconditionally.
      let okJson = list("--json --all")
      check okJson.code == 0
      check parseJson(okJson.output)["errors"].len == 0

      # ---- (9) a SELF-CANCELLING selection is a loud refusal. -------------
      #
      # `--only=X --except=X` asks for exactly X and simultaneously for not-X.
      # Both names resolve, so (1) and (2) pass it through; before this rule
      # the run exited 0 with an empty selection and did nothing — the
      # silent-no-op outcome this whole section exists to forbid. The
      # dangerous shape is the scripted one: an `--only` list and an
      # `--except` list assembled by different callers that happen to
      # overlap, where "did nothing" is indistinguishable from "nothing to
      # do".
      let selfCancel = develop("--only=tool-a --except=tool-a")
      check selfCancel.code == 2
      check "'tool-a' is named by BOTH --only and --except" in
        selfCancel.output
      check "never be selected" in selfCancel.output
      check not dirExists(deps)

      # Stated over the NAMES, not over the resulting set: this one leaves a
      # NON-EMPTY selection (`lib-core` survives) and still refuses, because
      # it is `--only=lib-core` written in a way that also says "not tool-a".
      # A rule that fired only on an empty result would depend on which other
      # repos happen to exist rather than on what was typed.
      let partialCancel = develop("--only=lib-core,tool-a --except=tool-a")
      check partialCancel.code == 2
      check "'tool-a' is named by BOTH --only and --except" in
        partialCancel.output
      check "'lib-core' is named by BOTH" notin partialCancel.output
      check not dirExists(deps)

      # Every contradicted name is reported, not just the first.
      let twoCancel = develop("--only=lib-core,tool-a --except=tool-a,lib-core")
      check twoCancel.code == 2
      check "'lib-core' is named by BOTH --only and --except" in
        twoCancel.output
      check "'tool-a' is named by BOTH --only and --except" in twoCancel.output

      # A disjoint pair is NOT a contradiction and still works: `--only`
      # keeps two, `--except` drops one of the others.
      let disjoint = list("--only=lib-core,tool-a --except=tool-b")
      check disjoint.code == 0
      check selectedRepos(disjoint.output) == @["lib-core", "tool-a"]

      # Ordering: an UNKNOWN name is the more basic error, so a selection
      # that is both contradictory and misspelled reports the typo. This is
      # what pins the contradiction check to run AFTER the exact-name block.
      let typoWins = develop("--only=tool-a,ghost --except=tool-a")
      check typoWins.code == 2
      check "'--only=ghost' names no repo in this workspace's lock set" in
        typoWins.output
      check "named by BOTH" notin typoWins.output

      # ---- (10) and the machine-readable form says so too. ----------------
      let cancelJson = list("--json --only=tool-a --except=tool-a")
      check cancelJson.code == 2
      let cancelReport = parseJson(cancelJson.output)
      check cancelReport["exitCode"].getInt() == 2
      check cancelReport["repos"].len == 0
      check cancelReport["errors"].len == 1
      check cancelReport["errors"][0]["node"].getStr() == "tool-a"
      check "named by BOTH --only and --except" in
        cancelReport["errors"][0]["diagnostic"].getStr()

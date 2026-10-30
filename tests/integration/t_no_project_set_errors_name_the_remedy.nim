## "No project set recorded" refusals name the command that records one.
##
## THE DEFECT (reprobuild-pm issue
## ``2026-09-20-workspace-toml-errors-do-not-name-remedy.md``). On a workspace
## whose active project set has never been recorded, a family of verbs refused
## with one shape of sentence:
##
##   repro workspace lock: error: `repro workspace lock` requires either
##   `.repro/workspace-state.toml` (or the older `.repro/workspace.toml`) or a
##   <project> argument; neither was present at <root>
##
## and stopped there. Nothing said what WRITES that file. The answer is
## ``repro workspace enable <project>`` (``reprobuild-pm/spec/CLI/workspace.md``,
## "The Two Axes: Membership and Definition"), and in the field it took
## reading a migration note in another repo to find it. That breaks
## ``Interactive-UX-And-Progress.md`` Principle 2, "Every failure teaches the
## remedy": a refusal must name "the concrete remedial command". The stakes
## are the ones that principle names — the observed failure was the pre-push
## gate, and the tempting workaround was ``git push --no-verify``.
##
## WHAT THIS SUITE PINS, and why it drives so many verbs. The sentence was
## raised from five separate places (the shared MO-9 ladder behind
## ``sync`` / ``pull`` / ``status`` / ``check --mode=pre-push``, ``workspace
## lock``'s own copy of that ladder, ``workspace list``, and the branch /
## switch resolvers behind ``branch`` / ``workspace new`` / ``switch``). A fix
## that reached four of the five would pass any one-verb test, so every verb
## that can reach a refusal here is driven through the real binary and must:
##
##   1. still refuse, and still carry the ORIGINAL first sentence — the fix
##      ADDS a remedy, it does not reword the diagnosis other suites match on;
##   2. name ``repro workspace enable <project>`` and say how to find project
##      names (``repro workspace projects list``);
##   3. offer the one-off ``<project>`` argument ONLY on the verbs that accept
##      one — ``branch`` and ``switch`` take no project, so advising one there
##      would be a remedy that fails.
##
## ``repro health``'s ``manifest`` check is pinned too: its remedy line used to
## be ``repro workspace sync``, which on this root fails with the very refusal
## the check is reporting.
##
## THE ARM THAT MUST NOT CHANGE. A bare clone of the manifests repo — the lock
## record store — reaches the same raise site by a different road and gets a
## deliberately different diagnostic (``noNameableProjectError``'s second
## branch; ``t_workspace_resolution_names_the_manifest_data_it_found.nim``).
## There, recording a project set is exactly the WRONG advice: it would make
## the store claim to be the workspace it describes
## (``Unified-Locking-And-Hooks.md`` §10). This suite asserts the store
## refusal still says the command "does not apply" and does NOT advise
## ``workspace enable``.
##
## POSITIVE CONTROL. Advice can be present and still wrong. On the
## real-workspace arm the suite RUNS the advised command
## (``repro workspace enable app --no-sync``) and then re-runs a verb that
## refused — it must now succeed. If ``enable`` did not record the set, the
## remedy this suite demands would be a lie and the control fails.
##
## NO MOCKS. Every root is a real git repo built with real ``git`` in a fresh
## tempdir, and every assertion is made on the real ``repro`` binary's real
## output. ``REPROBUILD_REPRO`` is pinned and the binary invoked by absolute
## path for the reason ``t_hooks_noop_outside_initialized_workspace.nim``'s
## header records: a fixture that leaves it unset silently exercises whatever
## ``repro`` is on PATH instead of the build under test.
##
## Every refusal fires in the resolver before any mutation; ``sync``
## additionally runs under ``--dry-run`` (``pull`` has no such flag).
##
## Skip rule: ``git`` missing on PATH (same convention as the RA-10 suite).

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

# ---- helpers --------------------------------------------------------------

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

proc requireGit(gitBin: string; args: openArray[string]): string =
  var argv = @[gitBin]
  argv.add(args)
  let res = runShell(shellCommand(argv))
  if res.code != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & res.output)
    quit 1
  res.output

const MinimalSettings = "schema = \"reprobuild.workspace.settings.v1\"\n"
  ## The smallest valid committed settings file: it marks the workspace root
  ## and records nothing else, in particular no project set. It declares its
  ## schema because every TOML file repro reads must, and a settings file
  ## that does not is refused, naming the file and the `schema` key, before
  ## any verb gets as far as the project-set question this suite is about.

proc seedRepo(gitBin, path: string) =
  ## A real git repo with one real commit, and nothing else.
  createDir(path)
  discard requireGit(gitBin, ["init", "-b", "main", path])
  discard requireGit(gitBin,
    ["-C", path, "config", "user.email", "tester@example.invalid"])
  discard requireGit(gitBin,
    ["-C", path, "config", "user.name", "No Project Set Tester"])
  writeFile(path / "README.md", "fixture\n")
  discard requireGit(gitBin, ["-C", path, "add", "-A"])
  discard requireGit(gitBin, ["-C", path, "commit", "-m", "fixture"])

proc commitAll(gitBin, path, message: string) =
  discard requireGit(gitBin, ["-C", path, "add", "-A"])
  discard requireGit(gitBin, ["-C", path, "commit", "-m", message])

proc writeMembershipManifests(root: string) =
  ## The flat native membership layout: one project and the repo fragment it
  ## includes. ``app`` is the name the positive control enables.
  createDir(root / "projects")
  createDir(root / "repos")
  writeFile(root / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n" &
    "\n" &
    "[[remote]]\nname = \"origin\"\n" &
    "fetch = \"https://example.invalid/app.git\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(root / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"origin\"\nmainline = \"main\"\n")

proc runRepro(reproBin, cwd: string; args: openArray[string]):
    tuple[code: int; output: string] =
  ## Run the binary under test FROM the fixture root, with no
  ## ``--workspace-root``: the reproduction in the issue is a bare verb typed
  ## in the workspace, so the cwd walk is part of what is being exercised.
  var argv = @[reproBin]
  argv.add(args)
  runShell(shellCommand(argv,
    @[(name: "REPROBUILD_REPRO", value: reproBin)]), cwd)

const
  # The diagnosis every refusal must still carry (1). Matched by other suites
  # too, which is why the fix must not reword it.
  originalRefusal = "requires either `.repro/workspace-state.toml`"
  # The remedy (2): the command that records the set, and where names come
  # from.
  enableRemedy = "repro workspace enable <project>"
  projectsListHint = "repro workspace projects list"
  # The one-off route (3), offered only where a <project> is accepted.
  oneOffHint = "pass <project>"

type Verb = object
  label: string
  args: seq[string]
  acceptsProject: bool

proc checkRefusalTeachesRemedy(label: string;
                               res: tuple[code: int; output: string];
                               root: string; acceptsProject: bool) =
  if res.code == 0:
    checkpoint(label & ": expected a refusal, got exit 0\n" & res.output)
  check res.code != 0
  if originalRefusal notin res.output:
    checkpoint(label & ": original diagnosis gone\n" & res.output)
  check originalRefusal in res.output
  # Principle 2 — still names the specific root at fault.
  check root in res.output
  if enableRemedy notin res.output:
    checkpoint(label & ": refusal never names `" & enableRemedy & "`\n" &
      res.output)
  check enableRemedy in res.output
  check projectsListHint in res.output
  if acceptsProject:
    check oneOffHint in res.output
  else:
    # branch / switch take no project: advising one would be a remedy that
    # fails when followed.
    if oneOffHint in res.output:
      checkpoint(label & ": advises a <project> this verb rejects\n" &
        res.output)
    check oneOffHint notin res.output

# ---- the suite ------------------------------------------------------------

suite "no-project-set refusals name the remedy":

  test "t_no_project_set_errors_name_the_remedy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repo")
    else:
      let reproBin = reproBinary()
      putEnv("REPROBUILD_REPRO", reproBin)
      let scratch = createTempDir("repro-no-project-set-", "-fixture")
      defer: removeDir(scratch)

      let verbs = @[
        Verb(label: "workspace lock", args: @["workspace", "lock"],
          acceptsProject: true),
        Verb(label: "workspace list", args: @["workspace", "list"],
          acceptsProject: true),
        Verb(label: "workspace status", args: @["workspace", "status"],
          acceptsProject: true),
        Verb(label: "sync", args: @["sync", "--dry-run"],
          acceptsProject: true),
        Verb(label: "workspace pull", args: @["workspace", "pull"],
          acceptsProject: true),
        Verb(label: "switch", args: @["switch", "other"],
          acceptsProject: false),
        Verb(label: "switch --mainline", args: @["switch", "--mainline"],
          acceptsProject: false),
      ]

      # ========================================================
      # Arm 1 — the issue's reproduction: a git repo carrying only an empty
      # settings file. Nothing records a project set.
      # ========================================================
      let empty = scratch / "empty-workspace"
      seedRepo(gitBin, empty)
      writeFile(empty / "repro-workspace.toml", MinimalSettings)
      commitAll(gitBin, empty, "settings file")
      check not fileExists(empty / ".repro" / "workspace-state.toml")
      check not fileExists(empty / ".repro" / "workspace-state.toml")

      for verb in verbs:
        checkRefusalTeachesRemedy(verb.label & "(empty)",
          runRepro(reproBin, empty, verb.args), empty, verb.acceptsProject)
      let emptyFork = scratch / "empty-fork"
      checkRefusalTeachesRemedy("branch(empty)",
        runRepro(reproBin, empty, ["branch", emptyFork]), empty,
        acceptsProject = false)
      check not dirExists(emptyFork)

      # ========================================================
      # Arm 2 — a REAL workspace whose project set was never recorded:
      # membership manifests beside a ``.repro/`` shell. This is the shape the
      # pre-push gate refuses on (an empty root is "not a workspace" to the
      # gate, which no-ops), and the shape the remedy genuinely fixes.
      # ========================================================
      let workspace = scratch / "real-workspace"
      seedRepo(gitBin, workspace)
      writeMembershipManifests(workspace)
      writeFile(workspace / "repro-workspace.toml", MinimalSettings)
      commitAll(gitBin, workspace, "membership")
      createDir(workspace / ".repro")
      check not fileExists(workspace / ".repro" / "workspace-state.toml")
      check not fileExists(workspace / ".repro" / "workspace-state.toml")

      for verb in verbs:
        checkRefusalTeachesRemedy(verb.label & "(workspace)",
          runRepro(reproBin, workspace, verb.args), workspace,
          verb.acceptsProject)
      checkRefusalTeachesRemedy("check --mode=pre-push(workspace)",
        runRepro(reproBin, workspace, ["check", "--mode=pre-push"]),
        workspace, acceptsProject = true)
      let workspaceFork = scratch / "workspace-fork"
      checkRefusalTeachesRemedy("branch(workspace)",
        runRepro(reproBin, workspace, ["branch", workspaceFork]), workspace,
        acceptsProject = false)
      check not dirExists(workspaceFork)

      # ``repro health``: the manifest check's remedy line must be the command
      # that records the set — not ``workspace sync``, which refuses here with
      # the very error the check is reporting.
      let health = runRepro(reproBin, workspace, ["health"])
      checkpoint("health(workspace) output:\n" & health.output)
      let healthLines = health.output.splitLines()
      var manifestRemedy = ""
      for i, line in healthLines:
        if line.startsWith("manifest ") and i + 1 < healthLines.len:
          manifestRemedy = healthLines[i + 1]
          break
      check manifestRemedy.strip().startsWith("remedy:")
      check "workspace enable <project>" in manifestRemedy
      check "workspace sync" notin manifestRemedy

      # POSITIVE CONTROL — follow the advice and the refusal goes away.
      let enabled = runRepro(reproBin, workspace,
        ["workspace", "enable", "app", "--no-sync"])
      if enabled.code != 0:
        checkpoint("workspace enable output: " & enabled.output)
      check enabled.code == 0
      check fileExists(workspace / ".repro" / "workspace-state.toml") or
        fileExists(workspace / ".repro" / "workspace-state.toml")
      let listed = runRepro(reproBin, workspace, ["workspace", "list"])
      if listed.code != 0:
        checkpoint("workspace list after enable: " & listed.output)
      check listed.code == 0
      check originalRefusal notin listed.output

      # ========================================================
      # Arm 3 — a bare manifests clone (the lock record store). Its refusal
      # is deliberately different and must stay so: recording a project set
      # here is the forbidden route inference, not a remedy.
      # ========================================================
      let store = scratch / "manifests-store"
      seedRepo(gitBin, store)
      writeMembershipManifests(store)
      createDir(store / "locks")
      writeFile(store / "locks" / ".keep", "")
      commitAll(gitBin, store, "membership + records")
      check not dirExists(store / ".repro")
      check not fileExists(store / "repro.lock")

      for args in [@["workspace", "lock", "--workspace-root=" & store],
                   @["workspace", "sync", "--workspace-root=" & store,
                     "--dry-run"]]:
        let res = runRepro(reproBin, store, args)
        let label = args[0 .. 1].join(" ") & "(store)"
        if res.code == 0:
          checkpoint(label & ": expected a refusal\n" & res.output)
        check res.code != 0
        check "lock record store" in res.output
        check "does not apply" in res.output
        if "workspace enable" in res.output:
          checkpoint(label & ": advises recording a project set in the " &
            "record store\n" & res.output)
        check "workspace enable" notin res.output
        check originalRefusal notin res.output
      check not dirExists(store / ".repro")

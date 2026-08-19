## Linked-worktree pre-push repository-local environment isolation.
##
## Git deliberately exports repository-local variables to hooks.  In a linked
## worktree those values name the pushed worktree's per-worktree gitdir.  Every
## nested Git command that explicitly selects another workspace repository must
## therefore remove that ambient repository binding first; otherwise `git -C`
## silently continues to observe the pushed repository.
##
## This suite uses real Git repositories, a real linked worktree, the generated
## protocol-2 hooks, and the built `repro` executable.  No VCS or hook boundary
## is mocked.  The two tests are independently falsifiable: removing the scrub
## from Workspace-VCS queries makes the first test report repo A's SHA for repo
## B, while removing it from the CLI rev-parse/lock-coherence path makes the
## second test emit a false coherence notice even if the Workspace-VCS queries
## remain correct.  The second test additionally proves that a preserved user
## hook receives Git's original argv, stdin bytes, and repository environment,
## while the managed Reprobuild child receives the scrubbed environment and all
## unrelated environment values unchanged.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import git_actions
import git_tool
import repro_test_support
import repro_workspace_manifests

type
  EnvSnapshot = object
    existed: bool
    value: string

  Fixture = object
    scratch, workspace, app, dep, linked, appOrigin, depOrigin: string
    lockStore, hookDir, userLog, userRefs, wrapperLog, wrapper: string
    gitBin, reproBin, appSha, depSha, linkedGitDir: string

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    raise newException(IOError, "command failed: " & command &
      "\nexit=" & $res.code & "\n" & res.output)
  res.output

proc sourceRoot(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc executable(path, body: string) =
  writeFile(path, body)
  var permissions = getFilePermissions(path)
  permissions.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, permissions)

proc snapshot(name: string): EnvSnapshot =
  EnvSnapshot(existed: existsEnv(name), value: getEnv(name))

proc restore(name: string; prior: EnvSnapshot) =
  if prior.existed: putEnv(name, prior.value)
  else: delEnv(name)

proc childEnvironment(overrides: openArray[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): result[key] = value
  for entry in overrides: result[entry[0]] = entry[1]

proc runProcess(binary: string; args: openArray[string];
    env: StringTableRef): tuple[code: int; output: string] =
  let process = startProcess(binary, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()

proc initOrigin(gitBin, origin, work, content: string): string =
  discard require(q(gitBin) & " init --bare -b main " & q(origin))
  discard require(q(gitBin) & " init -b main " & q(work))
  discard require(q(gitBin) & " -C " & q(work) &
    " config user.email linked@example.invalid")
  discard require(q(gitBin) & " -C " & q(work) &
    " config user.name 'Linked Worktree Tester'")
  writeFile(work / "README.md", content & "\n")
  discard require(q(gitBin) & " -C " & q(work) & " add README.md")
  discard require(q(gitBin) & " -C " & q(work) &
    " commit -m " & q("seed " & content))
  discard require(q(gitBin) & " -C " & q(work) &
    " remote add origin " & q(fileUrl(origin)))
  discard require(q(gitBin) & " -C " & q(work) &
    " push -u origin main")
  require(q(gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc cloneRepo(gitBin, origin, target: string) =
  discard require(q(gitBin) & " clone " & q(fileUrl(origin)) & " " & q(target))
  discard require(q(gitBin) & " -C " & q(target) &
    " config user.email linked@example.invalid")
  discard require(q(gitBin) & " -C " & q(target) &
    " config user.name 'Linked Worktree Tester'")

proc projectToml(appUrl, depUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
    "[[remote]]\nname = \"dep-origin\"\nfetch = \"" & depUrl & "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/dep.toml\"]\n"

const
  AppToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "app"
path = "app"
remote = "app-origin"
revision = "main"
depends = ["dep"]
"""
  DepToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "dep"
path = "dep"
remote = "dep-origin"
revision = "main"
"""

proc setup(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-linked-pre-push-env-", "")
  var complete = false
  defer:
    # The caller cannot register its fixture cleanup until setup returns. Keep
    # failures during repository construction from leaking a partial tree.
    if not complete and dirExists(result.scratch):
      removeDir(result.scratch)
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.dep = result.workspace / "dep"
  result.linked = result.workspace / "worktrees" / "app-linked"
  result.appOrigin = result.scratch / "app-origin.git"
  result.depOrigin = result.scratch / "dep-origin.git"
  result.lockStore = result.workspace / ".repro" / "manifests"
  result.userLog = result.scratch / "user-hook-env.log"
  result.userRefs = result.scratch / "user-hook-refs.bin"
  result.wrapperLog = result.scratch / "managed-wrapper-env.log"
  result.wrapper = result.scratch / "repro-wrapper"
  result.gitBin = gitBin
  result.reproBin = reproBinary()

  createDir(result.workspace)
  result.appSha = initOrigin(gitBin, result.appOrigin,
    result.scratch / "app-seed", "app")
  result.depSha = initOrigin(gitBin, result.depOrigin,
    result.scratch / "dep-seed", "dependency with a distinct commit")
  doAssert result.appSha != result.depSha
  cloneRepo(gitBin, result.appOrigin, result.app)
  cloneRepo(gitBin, result.depOrigin, result.dep)

  createDir(result.workspace / "projects")
  createDir(result.workspace / "repos")
  writeFile(result.workspace / "projects" / "app.toml",
    projectToml(fileUrl(result.appOrigin), fileUrl(result.depOrigin)))
  writeFile(result.workspace / "repos" / "app.toml", AppToml)
  writeFile(result.workspace / "repos" / "dep.toml", DepToml)
  writeWorkspaceBranch(result.workspace, project = "app", branch = "main")

  createDir(result.lockStore)
  discard require(q(gitBin) & " init -b main " & q(result.lockStore))
  discard require(q(gitBin) & " -C " & q(result.lockStore) &
    " config user.email linked@example.invalid")
  discard require(q(gitBin) & " -C " & q(result.lockStore) &
    " config user.name 'Linked Worktree Tester'")
  writeFile(result.lockStore / ".gitkeep", "")
  discard require(q(gitBin) & " -C " & q(result.lockStore) & " add .gitkeep")
  discard require(q(gitBin) & " -C " & q(result.lockStore) &
    " commit -m 'seed lock store'")

  let locked = run(q(result.reproBin) & " workspace lock " &
    "--workspace-root=" & q(result.workspace))
  if locked.code != 0:
    raise newException(IOError,
      "initial workspace lock failed:\n" & locked.output)

  createDir(result.linked.parentDir())
  discard require(q(gitBin) & " -C " & q(result.app) &
    " worktree add -b linked " & q(result.linked) & " HEAD")
  result.linkedGitDir = require(q(gitBin) & " -C " & q(result.linked) &
    " rev-parse --path-format=absolute --absolute-git-dir").strip()
  result.hookDir = require(q(gitBin) & " -C " & q(result.linked) &
    " rev-parse --path-format=absolute --git-path hooks").strip()
  complete = true

proc latestLock(fx: Fixture): string =
  let path = fx.lockStore / "locks" / "app" / "app" /
    (fx.appSha & ".toml")
  doAssert fileExists(path)
  path

proc poison(identityRepo, gitDir: string): seq[(string, string)] =
  @[
    ("GIT_DIR", gitDir),
    ("GIT_WORK_TREE", identityRepo),
    ("GIT_IMPLICIT_WORK_TREE", "0"),
    ("GIT_CONFIG", "/dev/null"),
    ("GIT_CONFIG_PARAMETERS", "'remote.origin.url=file:///poisoned'"),
    ("GIT_CONFIG_COUNT", "1"),
    ("GIT_CONFIG_KEY_0", "remote.origin.url"),
    ("GIT_CONFIG_VALUE_0", "file:///poisoned"),
    ("GIT_NO_REPLACE_OBJECTS", "1"),
    ("GIT_REPLACE_REF_BASE", "refs/reprobuild-poison"),
    ("GIT_PREFIX", "poisoned-prefix/"),
  ]

proc report(fx: Fixture): JsonNode =
  parseFile(fx.workspace / ".repro" / "build" / "reports" /
    "check-report.json")

proc refsRecord(localRef, localSha, remoteRef, remoteSha: string): string =
  localRef & " " & localSha & " " & remoteRef & " " & remoteSha & "\n"

suite "linked-worktree pre-push repository-local environment isolation":
  test "canonical scrub removes the complete repository namespace only":
    const ExpectedLocal = [
      "GIT_ALTERNATE_OBJECT_DIRECTORIES",
      "GIT_CONFIG",
      "GIT_CONFIG_PARAMETERS",
      "GIT_CONFIG_COUNT",
      "GIT_OBJECT_DIRECTORY",
      "GIT_DIR",
      "GIT_WORK_TREE",
      "GIT_IMPLICIT_WORK_TREE",
      "GIT_GRAFT_FILE",
      "GIT_INDEX_FILE",
      "GIT_NO_REPLACE_OBJECTS",
      "GIT_REPLACE_REF_BASE",
      "GIT_PREFIX",
      "GIT_SHALLOW_FILE",
      "GIT_COMMON_DIR",
      "GIT_NAMESPACE",
      "GIT_QUARANTINE_PATH",
      "GIT_INTERNAL_SUPER_PREFIX",
    ]
    const ExpectedPrefixes = ["GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"]
    check GitRepositoryLocalEnv.len == ExpectedLocal.len
    for expected in ExpectedLocal:
      check expected in GitRepositoryLocalEnv
    for actual in GitRepositoryLocalEnv:
      check actual in ExpectedLocal
    check GitRepositoryLocalEnvPrefixes.len == ExpectedPrefixes.len
    for expected in ExpectedPrefixes:
      check expected in GitRepositoryLocalEnvPrefixes
    for actual in GitRepositoryLocalEnvPrefixes:
      check actual in ExpectedPrefixes

    let indexed = [
      "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0",
      "GIT_CONFIG_KEY_9", "GIT_CONFIG_VALUE_9",
      "GIT_CONFIG_KEY_stale", "GIT_CONFIG_VALUE_stale",
    ]
    let unrelatedName = "REPRO_TEST_UNRELATED_SCRUB_VALUE"
    let unrelatedValue = " preserve exactly: spaces = tabs\tand punctuation ! "
    var priors: seq[(string, EnvSnapshot)]
    for name in ExpectedLocal:
      priors.add((name, snapshot(name)))
      putEnv(name, "poisoned:" & name)
    for name in indexed:
      priors.add((name, snapshot(name)))
      putEnv(name, "poisoned:" & name)
    priors.add((unrelatedName, snapshot(unrelatedName)))
    putEnv(unrelatedName, unrelatedValue)
    defer:
      for entry in priors:
        restore(entry[0], entry[1])

    let cleaned = scrubbedGitRepositoryEnv()
    for name in ExpectedLocal:
      check not cleaned.hasKey(name)
    for name in indexed:
      check not cleaned.hasKey(name)
    check cleaned.hasKey(unrelatedName)
    check cleaned[unrelatedName] == unrelatedValue

  test "Workspace-VCS queries select the named sibling under poisoned hook env":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      check gitBin.len > 0
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      let names = poison(fx.linked, fx.linkedGitDir)
      var priors: seq[(string, EnvSnapshot)]
      for entry in names:
        priors.add((entry[0], snapshot(entry[0])))
        putEnv(entry[0], entry[1])
      defer:
        for entry in priors: restore(entry[0], entry[1])

      let identity = ensureGitToolResolvable(tpmPathOnly, getEnv("PATH"))
      let head = queryGitState(headShaQuery(fx.dep), identity)
      let clean = queryGitState(isCleanQuery(fx.dep), identity)
      let published = queryGitState(isPublishedQuery(fx.dep, "origin"), identity)
      check head.status == gqsOk
      check head.headSha == fx.depSha
      check head.headSha != fx.appSha
      check clean.status == gqsOk
      check clean.isClean
      check published.status == gqsOk
      check published.isPublished

  test "real linked push preserves user boundary and scrubs managed protocol":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      check gitBin.len > 0
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      let zero = repeat('0', 40)
      let expectedRefs = refsRecord("refs/heads/linked", fx.appSha,
        "refs/heads/linked", zero)

      executable(fx.hookDir / "pre-push",
        "#!/usr/bin/env sh\nset -eu\n" &
        "{\n" &
        "  printf 'argv1=%s\\nargv2=%s\\n' \"$1\" \"$2\"\n" &
        "  printf 'GIT_DIR=%s\\n' \"${GIT_DIR-<unset>}\"\n" &
        "  printf 'GIT_WORK_TREE=%s\\n' \"${GIT_WORK_TREE-<unset>}\"\n" &
        "  printf 'GIT_CONFIG=%s\\n' \"${GIT_CONFIG-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_PARAMETERS=%s\\n' \"${GIT_CONFIG_PARAMETERS-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_COUNT=%s\\n' \"${GIT_CONFIG_COUNT-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_KEY_0=%s\\n' \"${GIT_CONFIG_KEY_0-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_VALUE_0=%s\\n' \"${GIT_CONFIG_VALUE_0-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_KEY_9=%s\\n' \"${GIT_CONFIG_KEY_9-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_VALUE_9=%s\\n' \"${GIT_CONFIG_VALUE_9-<unset>}\"\n" &
        "  printf 'GIT_NO_REPLACE_OBJECTS=%s\\n' \"${GIT_NO_REPLACE_OBJECTS-<unset>}\"\n" &
        "  printf 'unrelated=%s\\n' \"${REPRO_TEST_UNRELATED-<unset>}\"\n" &
        "} > " & q(fx.userLog) & "\n" &
        "cat > " & q(fx.userRefs) & "\n")
      let ensured = run(q(fx.reproBin) & " hooks ensure --vcs " & q(fx.linked))
      if ensured.code != 0: checkpoint(ensured.output)
      check ensured.code == 0

      executable(fx.wrapper,
        "#!/usr/bin/env sh\nset -eu\n" &
        "{\n" &
        "  printf '%s\\n' begin\n" &
        "  printf 'GIT_DIR=%s\\n' \"${GIT_DIR-<unset>}\"\n" &
        "  printf 'GIT_WORK_TREE=%s\\n' \"${GIT_WORK_TREE-<unset>}\"\n" &
        "  printf 'GIT_CONFIG=%s\\n' \"${GIT_CONFIG-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_PARAMETERS=%s\\n' \"${GIT_CONFIG_PARAMETERS-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_COUNT=%s\\n' \"${GIT_CONFIG_COUNT-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_KEY_0=%s\\n' \"${GIT_CONFIG_KEY_0-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_VALUE_0=%s\\n' \"${GIT_CONFIG_VALUE_0-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_KEY_9=%s\\n' \"${GIT_CONFIG_KEY_9-<unset>}\"\n" &
        "  printf 'GIT_CONFIG_VALUE_9=%s\\n' \"${GIT_CONFIG_VALUE_9-<unset>}\"\n" &
        "  printf 'GIT_NO_REPLACE_OBJECTS=%s\\n' \"${GIT_NO_REPLACE_OBJECTS-<unset>}\"\n" &
        "  printf 'unrelated=%s\\n' \"${REPRO_TEST_UNRELATED-<unset>}\"\n" &
        "  printf '%s\\n' end\n" &
        "} >> " & q(fx.wrapperLog) & "\n" &
        "exec " & q(fx.reproBin) & " \"$@\"\n")

      let pushEnv = childEnvironment([
        ("REPROBUILD_REPRO", fx.wrapper),
        ("REPRO_TEST_UNRELATED", "preserve-this-value"),
        ("GIT_DIR", fx.linkedGitDir),
        ("GIT_WORK_TREE", fx.linked),
        ("GIT_IMPLICIT_WORK_TREE", "0"),
        ("GIT_CONFIG", "/dev/null"),
        ("GIT_CONFIG_PARAMETERS", "'reprobuild.test=poisoned'"),
        ("GIT_CONFIG_COUNT", "1"),
        ("GIT_CONFIG_KEY_0", "reprobuild.test-indexed"),
        ("GIT_CONFIG_VALUE_0", "poisoned"),
        # Deliberately outside GIT_CONFIG_COUNT: the managed boundary must
        # scrub the complete indexed namespace instead of trusting the count.
        ("GIT_CONFIG_KEY_9", "reprobuild.test-stale-indexed"),
        ("GIT_CONFIG_VALUE_9", "stale-poisoned"),
        ("GIT_NO_REPLACE_OBJECTS", "1"),
      ])
      let pushed = runProcess(gitBin,
        ["-C", fx.linked, "push", "origin",
         "refs/heads/linked:refs/heads/linked"], pushEnv)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check readFile(fx.userRefs) == expectedRefs
      let user = readFile(fx.userLog)
      check "argv1=origin\nargv2=" & fileUrl(fx.appOrigin) & "\n" in user
      check "GIT_DIR=" & fx.linkedGitDir & "\n" in user
      check "GIT_WORK_TREE=" & fx.linked & "\n" in user
      check "GIT_CONFIG=/dev/null\n" in user
      check "GIT_CONFIG_PARAMETERS='reprobuild.test=poisoned'\n" in user
      check "GIT_CONFIG_COUNT=1\n" in user
      check "GIT_CONFIG_KEY_0=reprobuild.test-indexed\n" in user
      check "GIT_CONFIG_VALUE_0=poisoned\n" in user
      check "GIT_CONFIG_KEY_9=reprobuild.test-stale-indexed\n" in user
      check "GIT_CONFIG_VALUE_9=stale-poisoned\n" in user
      check "GIT_NO_REPLACE_OBJECTS=1\n" in user
      check "unrelated=preserve-this-value\n" in user

      let managed = readFile(fx.wrapperLog)
      check managed.count("begin\n") == 2
      check managed.count("GIT_DIR=<unset>\n") == 2
      check managed.count("GIT_WORK_TREE=<unset>\n") == 2
      check managed.count("GIT_CONFIG=<unset>\n") == 2
      check managed.count("GIT_CONFIG_PARAMETERS=<unset>\n") == 2
      check managed.count("GIT_CONFIG_COUNT=<unset>\n") == 2
      check managed.count("GIT_CONFIG_KEY_0=<unset>\n") == 2
      check managed.count("GIT_CONFIG_VALUE_0=<unset>\n") == 2
      check managed.count("GIT_CONFIG_KEY_9=<unset>\n") == 2
      check managed.count("GIT_CONFIG_VALUE_9=<unset>\n") == 2
      check managed.count("GIT_NO_REPLACE_OBJECTS=<unset>\n") == 2
      check managed.count("unrelated=preserve-this-value\n") == 2

      let firstReport = fx.report()
      check firstReport["exitCode"].getInt() == 0
      check firstReport["failures"].len == 0
      check firstReport["notices"].len == 0
      check firstReport["lockUpdate"]["kind"].getStr() == "already-current"
      let lockBefore = readFile(fx.latestLock())
      check fx.appSha in lockBefore
      check fx.depSha in lockBefore

      let directRefs = fx.scratch / "direct-refs.bin"
      writeFile(directRefs, refsRecord("refs/heads/linked", fx.appSha,
        "refs/heads/direct-protocol", zero))
      let directEnv = childEnvironment(poison(fx.linked, fx.linkedGitDir) & @[
        ("REPRO_TEST_UNRELATED", "direct-preserved")])
      let direct = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", fx.linked, "--refs-file", directRefs, "--",
         "origin", fileUrl(fx.appOrigin)], directEnv)
      if direct.code != 0: checkpoint(direct.output)
      check direct.code == 0
      let directReport = fx.report()
      check directReport["exitCode"].getInt() == 0
      check directReport["failures"].len == 0
      check directReport["notices"].len == 0
      check directReport["lockUpdate"]["kind"].getStr() == "already-current"
      check readFile(fx.latestLock()) == lockBefore

      # Ordinary checkouts use the same protocol and retain the pre-fix result.
      let standardRefs = fx.scratch / "standard-refs.bin"
      writeFile(standardRefs, refsRecord("refs/heads/main", fx.appSha,
        "refs/heads/standard-protocol", zero))
      let standard = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", fx.app, "--refs-file", standardRefs, "--",
         "origin", fileUrl(fx.appOrigin)], childEnvironment([]))
      if standard.code != 0: checkpoint(standard.output)
      check standard.code == 0
      check fx.report()["notices"].len == 0

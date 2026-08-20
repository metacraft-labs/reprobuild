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
## is mocked.  The tests are independently falsifiable: removing the scrub
## from Workspace-VCS queries makes the first test report repo A's SHA for repo
## B, while removing it from the CLI rev-parse/lock-coherence path makes the
## second test emit a false coherence notice even if the Workspace-VCS queries
## remain correct.  The second test additionally proves that a preserved user
## hook receives Git's original argv, stdin bytes, and repository environment,
## while the managed Reprobuild child receives the scrubbed environment and all
## unrelated environment values unchanged.

import std/[algorithm, json, os, osproc, streams, strtabs, strutils, tempfiles,
  unittest]

import git_actions
import git_tool
import repro_test_support
import repro_workspace_manifests

type
  EnvSnapshot = object
    existed: bool
    value: string

  Fixture = object
    scratch, workspace, app, dep, unrelated, linked: string
    appOrigin, depOrigin, unrelatedOrigin: string
    lockStore, hookDir, userLog, userRefs, wrapperLog, wrapper: string
    gitBin, reproBin, appSha, depSha, unrelatedSha, linkedGitDir: string

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

proc projectToml(appUrl, depUrl, unrelatedUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
    "[[remote]]\nname = \"dep-origin\"\nfetch = \"" & depUrl & "\"\n\n" &
    "[[remote]]\nname = \"unrelated-origin\"\nfetch = \"" &
      unrelatedUrl & "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/dep.toml\", " &
      "\"repos/unrelated.toml\"]\n"

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
  UnrelatedToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "unrelated"
path = "other/app-linked"
remote = "unrelated-origin"
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
  # Same leaf name as the linked worktree, but a distinct repository. A
  # basename-based resolver will select or scope this checkout incorrectly.
  result.unrelated = result.workspace / "other" / "app-linked"
  result.linked = result.workspace / "worktrees" / "app-linked"
  result.appOrigin = result.scratch / "app-origin.git"
  result.depOrigin = result.scratch / "dep-origin.git"
  result.unrelatedOrigin = result.scratch / "unrelated-origin.git"
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
  result.unrelatedSha = initOrigin(gitBin, result.unrelatedOrigin,
    result.scratch / "unrelated-seed", "unrelated same-basename checkout")
  doAssert result.appSha != result.depSha
  cloneRepo(gitBin, result.appOrigin, result.app)
  cloneRepo(gitBin, result.depOrigin, result.dep)
  createDir(result.unrelated.parentDir())
  cloneRepo(gitBin, result.unrelatedOrigin, result.unrelated)

  createDir(result.workspace / "projects")
  createDir(result.workspace / "repos")
  writeFile(result.workspace / "projects" / "app.toml",
    projectToml(fileUrl(result.appOrigin), fileUrl(result.depOrigin),
      fileUrl(result.unrelatedOrigin)))
  writeFile(result.workspace / "repos" / "app.toml", AppToml)
  writeFile(result.workspace / "repos" / "dep.toml", DepToml)
  writeFile(result.workspace / "repos" / "unrelated.toml", UnrelatedToml)
  writeWorkspaceProjects(result.workspace, @["app"])

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

proc latestLock(fx: Fixture; sha = ""): string =
  let triggerSha = if sha.len > 0: sha else: fx.appSha
  let path = fx.lockStore / "locks" / "app" / "app" /
    (triggerSha & ".toml")
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

proc stableLockBody(content: string): string =
  ## The local-directory lock backend rewrites ``created_at`` on each gate.
  ## Compare the durable repository observations, not wall-clock metadata.
  for line in content.splitLines():
    if not line.startsWith("created_at = "):
      result.add(line & "\n")

proc noticesText(document: JsonNode): string =
  for notice in document["notices"]:
    result.add(notice.getStr() & "\n")

proc appendTreeSnapshot(directory, prefix: string;
    entries: var seq[string]) =
  ## Capture every non-Git file and directory byte-for-byte. Identity
  ## refusals are required to happen before lock observation/publication; a
  ## status-only assertion would miss an overwrite that retained the same
  ## dirty/untracked shape.
  for kind, path in walkDir(directory):
    let name = path.lastPathPart()
    if name == ".git":
      continue
    let relative = if prefix.len > 0: prefix / name else: name
    case kind
    of pcFile:
      entries.add("file\0" & relative & "\0" & readFile(path))
    of pcDir:
      entries.add("dir\0" & relative)
      appendTreeSnapshot(path, relative, entries)
    of pcLinkToFile, pcLinkToDir:
      entries.add("link\0" & relative & "\0" & expandSymlink(path))

proc lockStoreSnapshot(fx: Fixture): string =
  var entries: seq[string]
  appendTreeSnapshot(fx.lockStore, "", entries)
  entries.sort()
  result = entries.join("\0")

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
      writeFile(fx.linked / "linked-only.txt", "linked worktree head\n")
      discard require(q(gitBin) & " -C " & q(fx.linked) &
        " add linked-only.txt")
      discard require(q(gitBin) & " -C " & q(fx.linked) &
        " commit -m 'linked-only head'")
      let linkedSha = require(q(gitBin) & " -C " & q(fx.linked) &
        " rev-parse HEAD").strip()
      check linkedSha != fx.appSha
      check require(q(gitBin) & " -C " & q(fx.app) &
        " rev-parse HEAD").strip() == fx.appSha
      # Unrelated and deliberately same-basename as the linked worktree. It is
      # outside app's declared dependency closure and must not block this push.
      writeFile(fx.unrelated / "unrelated-dirty.txt", "must remain dirty\n")
      let expectedRefs = refsRecord("refs/heads/linked", linkedSha,
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
      check firstReport["project"].getStr() == "app"
      # macOS reports a temporary directory below /private/var even when the
      # fixture was created through its /var symlink. Repository identity is
      # physical-path identity, so compare the two canonical spellings.
      check expandFilename(firstReport["currentRepo"].getStr()) ==
        expandFilename(fx.linked)
      check firstReport["activeBranch"].getStr() == "linked"
      check firstReport["pushedBranch"].getStr() == "linked"
      check firstReport["lockUpdate"]["triggerRepo"].getStr() == "app"
      check firstReport["lockUpdate"]["triggerSha"].getStr() == linkedSha
      check firstReport["lockUpdate"]["kind"].getStr() == "created"
      let lockBefore = readFile(fx.latestLock(linkedSha))
      check linkedSha in lockBefore
      check fx.appSha notin lockBefore
      check fx.depSha in lockBefore
      check fx.unrelatedSha in lockBefore
      check fileExists(fx.unrelated / "unrelated-dirty.txt")

      let directRefs = fx.scratch / "direct-refs.bin"
      writeFile(directRefs, refsRecord("HEAD", linkedSha,
        "refs/heads/linked", linkedSha))
      let directEnv = childEnvironment(poison(fx.linked, fx.linkedGitDir) & @[
        ("REPRO_TEST_UNRELATED", "direct-preserved")])
      let direct = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", fx.linked, "--refs-file", directRefs, "--",
         "origin", fileUrl(fx.appOrigin)], directEnv)
      if direct.code != 0: checkpoint(direct.output)
      check direct.code == 0
      let directReport = fx.report()
      if directReport["notices"].len != 0:
        checkpoint($directReport)
      check directReport["exitCode"].getInt() == 0
      check directReport["failures"].len == 0
      check directReport["notices"].len == 0
      check directReport["activeBranch"].getStr() == "linked"
      check directReport["pushedBranch"].getStr() == "linked"
      check directReport["lockUpdate"]["triggerSha"].getStr() == linkedSha
      check directReport["lockUpdate"]["kind"].getStr() == "created"
      check stableLockBody(readFile(fx.latestLock(linkedSha))) ==
        stableLockBody(lockBefore)

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
      if fx.report()["notices"].len != 0:
        checkpoint($fx.report())
      check fx.report()["notices"].len == 0

  test "a dirty declared dependency still blocks the linked push":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      check gitBin.len > 0
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      writeFile(fx.linked / "blocked-head.txt", "must not publish\n")
      discard require(q(gitBin) & " -C " & q(fx.linked) &
        " add blocked-head.txt")
      discard require(q(gitBin) & " -C " & q(fx.linked) &
        " commit -m 'linked head with dirty dependency'")
      writeFile(fx.dep / "dependency-dirty.txt", "legitimate blocker\n")

      let ensured = run(q(fx.reproBin) & " hooks ensure --vcs " & q(fx.linked))
      if ensured.code != 0: checkpoint(ensured.output)
      check ensured.code == 0
      let pushed = runProcess(gitBin,
        ["-C", fx.linked, "push", "origin",
         "refs/heads/linked:refs/heads/blocked-by-dependency"],
        childEnvironment([("REPROBUILD_REPRO", fx.reproBin)]))
      check pushed.code != 0
      let blocked = fx.report()
      check blocked["exitCode"].getInt() == 2
      check blocked["project"].getStr() == "app"
      check expandFilename(blocked["currentRepo"].getStr()) ==
        expandFilename(fx.linked)
      check blocked["activeBranch"].getStr() == "linked"
      check blocked["pushedBranch"].getStr() == "linked"
      check blocked["failures"].len == 1
      check blocked["failures"][0]["repo"].getStr() == "dep"
      check blocked["failures"][0]["property"].getStr() == "dirty"
      check fileExists(fx.dep / "dependency-dirty.txt")
      let advertised = require(q(gitBin) & " -C " & q(fx.linked) &
        " ls-remote --heads origin refs/heads/blocked-by-dependency")
      check advertised.strip().len == 0

  test "explicit linked root scopes a multi-project hook to its dependency closure":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      check gitBin.len > 0
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)

      # The ambient primary project owns only the unrelated checkout. The
      # pushed project owns app -> dep. Both participate in one workspace, so
      # selecting the workspace root is necessary but selecting its primary
      # project's repo set as the hook scope is wrong.
      writeFile(fx.workspace / "projects" / "ambient.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"ambient\"\ndefault_revision = \"main\"\n\n" &
        "[[remote]]\nname = \"unrelated-origin\"\nfetch = \"" &
          fileUrl(fx.unrelatedOrigin) & "\"\n\n" &
        "includes = [\"repos/unrelated.toml\"]\n")
      writeFile(fx.workspace / "projects" / "app.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\ndefault_revision = \"main\"\n\n" &
        "[[remote]]\nname = \"app-origin\"\nfetch = \"" &
          fileUrl(fx.appOrigin) & "\"\n\n" &
        "[[remote]]\nname = \"dep-origin\"\nfetch = \"" &
          fileUrl(fx.depOrigin) & "\"\n\n" &
        "includes = [\"repos/app.toml\", \"repos/dep.toml\"]\n")
      writeWorkspaceProjects(fx.workspace, @["ambient", "app"])
      let relocked = run(q(fx.reproBin) & " workspace lock " &
        "--workspace-root=" & q(fx.workspace))
      if relocked.code != 0: checkpoint(relocked.output)
      check relocked.code == 0

      # Make both a real dependency and an ambient-only checkout disagree with
      # the lock. The dependency's dirty file gives the gate a deterministic
      # refusal before any lock publication; the advisory pass must mention
      # dep but must not even observe unrelated.
      writeFile(fx.dep / "new-dep.txt", "new dependency revision\n")
      discard require(q(gitBin) & " -C " & q(fx.dep) & " add new-dep.txt")
      discard require(q(gitBin) & " -C " & q(fx.dep) &
        " commit -m 'advance dependency after lock'")
      writeFile(fx.dep / "dirty-dep.txt", "legitimate closure blocker\n")
      writeFile(fx.unrelated / "new-unrelated.txt", "ambient drift\n")
      discard require(q(gitBin) & " -C " & q(fx.unrelated) &
        " add new-unrelated.txt")
      discard require(q(gitBin) & " -C " & q(fx.unrelated) &
        " commit -m 'advance ambient repo after lock'")

      writeFile(fx.linked / "multi-project-head.txt", "outgoing head\n")
      discard require(q(gitBin) & " -C " & q(fx.linked) &
        " add multi-project-head.txt")
      discard require(q(gitBin) & " -C " & q(fx.linked) &
        " commit -m 'multi-project outgoing head'")
      let linkedSha = require(q(gitBin) & " -C " & q(fx.linked) &
        " rev-parse HEAD").strip()
      let refs = fx.scratch / "multi-project-refs.bin"
      writeFile(refs, refsRecord("refs/heads/linked", linkedSha,
        "refs/heads/multi-project", repeat('0', 40)))

      let dispatched = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", fx.linked, "--refs-file", refs, "--",
         "origin", fileUrl(fx.appOrigin)], childEnvironment([]))
      check dispatched.code == 2
      let checked = fx.report()
      check checked["exitCode"].getInt() == 2
      check checked["project"].getStr() == "ambient"
      check expandFilename(checked["currentRepo"].getStr()) ==
        expandFilename(fx.linked)
      check checked["failures"].len == 1
      check checked["failures"][0]["repo"].getStr() == "dep"
      check checked["failures"][0]["property"].getStr() == "dirty"
      let notices = noticesText(checked)
      check "dep: checked out" in notices
      check "unrelated: checked out" notin notices
      check fileExists(fx.dep / "dirty-dep.txt")

  test "same-remote second clone is not the explicit workspace repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      check gitBin.len > 0
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      let hostile = fx.workspace / "copies" / "app"
      createDir(hostile.parentDir)
      cloneRepo(gitBin, fx.appOrigin, hostile)
      let hostileSha = require(q(gitBin) & " -C " & q(hostile) &
        " rev-parse HEAD").strip()
      let refs = fx.scratch / "same-remote-hostile-refs.bin"
      writeFile(refs, refsRecord("refs/heads/main", hostileSha,
        "refs/heads/hostile", repeat('0', 40)))

      let lockBefore = lockStoreSnapshot(fx)

      let dispatched = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", hostile, "--refs-file", refs, "--",
         "origin", fileUrl(fx.appOrigin)], childEnvironment([]))
      if dispatched.code != 2: checkpoint(dispatched.output)
      check dispatched.code == 2
      let checked = fx.report()
      check checked["exitCode"].getInt() == 2
      check checked["failures"].len == 1
      check checked["failures"][0]["property"].getStr() ==
        "current-repo-identity"
      check "does not match a declared repo" in
        checked["failures"][0]["evidence"].getStr()
      check checked["notices"].len == 0
      check lockStoreSnapshot(fx) == lockBefore

      # A path that exists but is not a valid Git worktree is corruption, not
      # an absent checkout. Remote identity must remain disabled in this state
      # as well; otherwise the same hostile clone becomes authoritative merely
      # because the declared checkout broke.
      removeDir(fx.app)
      createDir(fx.app)
      writeFile(fx.app / "present-but-not-a-worktree", "corrupt checkout\n")
      let corrupted = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", hostile, "--refs-file", refs, "--",
         "origin", fileUrl(fx.appOrigin)], childEnvironment([]))
      if corrupted.code != 2: checkpoint(corrupted.output)
      check corrupted.code == 2
      let corruptedReport = fx.report()
      check corruptedReport["exitCode"].getInt() == 2
      check corruptedReport["failures"].len == 1
      check corruptedReport["failures"][0]["property"].getStr() ==
        "current-repo-identity"
      check corruptedReport["notices"].len == 0
      check lockStoreSnapshot(fx) == lockBefore

      # Remote identity remains available for its declared purpose: recovery
      # when the canonical checkout is genuinely absent. This positive arm
      # prevents the hardening above from silently deleting that behavior.
      removeDir(fx.app)
      let absent = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", hostile, "--refs-file", refs, "--",
         "origin", fileUrl(fx.appOrigin)], childEnvironment([]))
      if absent.code != 0: checkpoint(absent.output)
      check absent.code == 0
      let absentReport = fx.report()
      check absentReport["exitCode"].getInt() == 0
      check absentReport["failures"].len == 0
      check expandFilename(absentReport["currentRepo"].getStr()) ==
        expandFilename(hostile)

  test "ambiguous missing-checkout remote identity fails closed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      check gitBin.len > 0
    else:
      let fx = setup(gitBin)
      defer: removeDir(fx.scratch)
      writeFile(fx.workspace / "repos" / "ghost-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"ghost-a\"\npath = \"missing/a\"\n" &
        "remote = \"app-origin\"\nrevision = \"main\"\n")
      writeFile(fx.workspace / "repos" / "ghost-b.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"ghost-b\"\npath = \"missing/b\"\n" &
        "remote = \"app-origin\"\nrevision = \"main\"\n")
      let originalProject = readFile(fx.workspace / "projects" / "app.toml")
      writeFile(fx.workspace / "projects" / "app.toml",
        originalProject.replace(
          "includes = [\"repos/app.toml\", \"repos/dep.toml\", " &
            "\"repos/unrelated.toml\"]\n",
          "includes = [\"repos/app.toml\", \"repos/dep.toml\", " &
            "\"repos/unrelated.toml\", \"repos/ghost-a.toml\", " &
            "\"repos/ghost-b.toml\"]\n"))
      let hostile = fx.workspace / "copies" / "ambiguous"
      createDir(hostile.parentDir)
      cloneRepo(gitBin, fx.appOrigin, hostile)
      let hostileSha = require(q(gitBin) & " -C " & q(hostile) &
        " rev-parse HEAD").strip()
      let refs = fx.scratch / "ambiguous-hostile-refs.bin"
      writeFile(refs, refsRecord("refs/heads/main", hostileSha,
        "refs/heads/ambiguous", repeat('0', 40)))

      let lockBefore = lockStoreSnapshot(fx)

      let dispatched = runProcess(fx.reproBin,
        ["hooks", "dispatch", "pre-push", "--protocol=2",
         "--repo-root", hostile, "--refs-file", refs, "--",
         "origin", fileUrl(fx.appOrigin)], childEnvironment([]))
      if dispatched.code != 2: checkpoint(dispatched.output)
      check dispatched.code == 2
      let checked = fx.report()
      check checked["failures"].len == 1
      check checked["failures"][0]["property"].getStr() ==
        "current-repo-identity"
      check "more than one declared repo" in
        checked["failures"][0]["evidence"].getStr()
      check checked["notices"].len == 0
      check lockStoreSnapshot(fx) == lockBefore

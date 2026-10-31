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
## second test's coherence advisory observe the pushed worktree's HEAD instead
## of the declared ``app`` checkout, so the expected ``app`` finding (checkout
## at the seed commit, newest record ahead of it) vanishes even if the
## Workspace-VCS queries remain correct.  The second test additionally proves
## that a preserved user hook receives Git's original argv, stdin bytes, and
## repository environment, while the managed Reprobuild child receives the
## scrubbed environment and all unrelated environment values unchanged.

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
    "[project]\nname = \"app\"\n" &
    "\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
    "[[remote]]\nname = \"dep-origin\"\nfetch = \"" & depUrl & "\"\n\n" &
    "[[remote]]\nname = \"unrelated-origin\"\nfetch = \"" &
      unrelatedUrl & "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/dep.toml\", " &
      "\"repos/unrelated.toml\"]\n"

const
  AppToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "app"
path = "app"
remote = "app-origin"
mainline = "main"
depends = ["dep"]
"""
  DepToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "dep"
path = "dep"
remote = "dep-origin"
mainline = "main"
"""
  UnrelatedToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "unrelated"
path = "other/app-linked"
remote = "unrelated-origin"
mainline = "main"
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

proc checkAppBehindLinkedRecord(document: JsonNode;
    appSha, linkedSha: string) =
  ## After the linked push the record store holds two unpublished drafts: the
  ## fixture's initial ``workspace lock`` record (app at the seed commit) and
  ## the push's record (app at the linked commit). The push's is the newer, so
  ## it is the manifests-DB claim the advisory compares against. The advisory
  ## observes the DECLARED ``app`` checkout, which is still at the seed commit,
  ## so the honest output is one informational ``descendant`` finding — the
  ## lock is ahead of the checkout (CLI/README.md §"Lock Coherence": a branch
  ## that bumped a private revision reports a discrepancy no remedy clears).
  ##
  ## For the poisoned direct dispatch this is also the scrub witness: if the
  ## hook's ``GIT_DIR`` leaked into the advisory's ``rev-parse``, the ``app``
  ## checkout would read as the linked commit, match the claim, and the
  ## finding would disappear.
  let notices = noticesText(document)
  checkpoint(notices)
  check "lock coherence: 0 needing attention, 1 informational\n" in notices
  check "  app: checked out " & appSha & " on main\n" in notices
  check "    locks/app/app/" & linkedSha & ".toml claims " & linkedSha &
    " (descendant)\n" in notices
  check "lock coherence is ADVISORY: nothing was blocked or changed\n" in
    notices
  check linkedSha & " on " notin notices

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
      check directReport["exitCode"].getInt() == 0
      check directReport["failures"].len == 0
      checkAppBehindLinkedRecord(directReport, fx.appSha, linkedSha)
      check directReport["activeBranch"].getStr() == "linked"
      check directReport["pushedBranch"].getStr() == "linked"
      check directReport["lockUpdate"]["triggerSha"].getStr() == linkedSha
      # The push above already wrote the record anchored at this exact commit,
      # and this lock store has no upstream, so it is still an unpublished
      # draft on disk. A gate that finds its expected record on disk treats it
      # as current and does NOT rewrite it (73ffabdbe, "lock: anchor a push's
      # record at its own commit"): a rewrite changes only ``created_at``, and
      # that alone moves the lock's identity out from under any certificate
      # issued against the draft. So the second run reports "already-current"
      # and leaves the bytes untouched — which also proves the scrubbed direct
      # dispatch computed the same trigger and record path as the real push.
      check directReport["lockUpdate"]["kind"].getStr() == "already-current"
      check readFile(fx.latestLock(linkedSha)) == lockBefore

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
      let standardReport = fx.report()
      check standardReport["exitCode"].getInt() == 0
      check standardReport["failures"].len == 0
      check standardReport["lockUpdate"]["triggerSha"].getStr() == fx.appSha
      checkAppBehindLinkedRecord(standardReport, fx.appSha, linkedSha)

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
        "[project]\nname = \"ambient\"\n\n" &
        "[[remote]]\nname = \"unrelated-origin\"\nfetch = \"" &
          fileUrl(fx.unrelatedOrigin) & "\"\n\n" &
        "includes = [\"repos/unrelated.toml\"]\n")
      writeFile(fx.workspace / "projects" / "app.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\n\n" &
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
      # refusal before publication; its unpublished HEAD is a second blocker.
      # Both gate failures and advisory observations must include dep and
      # exclude unrelated.
      writeFile(fx.dep / "new-dep.txt", "new dependency revision\n")
      discard require(q(gitBin) & " -C " & q(fx.dep) & " add new-dep.txt")
      discard require(q(gitBin) & " -C " & q(fx.dep) &
        " commit -m 'advance dependency after lock'")
      let unpublishedDepSha = require(q(gitBin) & " -C " & q(fx.dep) &
        " rev-parse HEAD").strip()
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
      # Both independent blockers belong to the dependency closure. An
      # ambient-only checkout must contribute neither kind of refusal.
      check checked["failures"].len == 2
      if checked["failures"].len == 2:
        for i, property in ["dirty", "unpublished"]:
          check checked["failures"][i]["repo"].getStr() == "dep"
          check checked["failures"][i]["property"].getStr() == property
          check ("dep: " & property) in dispatched.output
        check unpublishedDepSha in checked["failures"][1]["evidence"].getStr()
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
        "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
        "[repo]\nname = \"ghost-a\"\npath = \"missing/a\"\n" &
        "remote = \"app-origin\"\nmainline = \"main\"\n")
      writeFile(fx.workspace / "repos" / "ghost-b.toml",
        "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
        "[repo]\nname = \"ghost-b\"\npath = \"missing/b\"\n" &
        "remote = \"app-origin\"\nmainline = \"main\"\n")
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


proc declarePreviousApp(fx: Fixture; priorPath: string) =
  # The old URL really serves the same objects; the new URL is deliberately
  # different, so path and prior-URL acceptance cannot borrow current URLs.
  createDir(fx.workspace / "url-prefixes")
  writeFile(fx.workspace / "url-prefixes" / "historical.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n" &
    "[url-prefix]\nname = \"historical\"\nurl = \"" &
      fileUrl(fx.scratch) & "\"\n")
  writeFile(fx.workspace / "repos" / "app.toml", AppToml &
    "\n[extensions]\npreviously = [{ path = \"" & priorPath &
      "\", url_prefix = \"historical\", url_suffix = \"app-origin.git\" }]\n")
  let project = fx.workspace / "projects" / "app.toml"
  writeFile(project, readFile(project).replace(fileUrl(fx.appOrigin),
    fileUrl(fx.scratch / "renamed-origin.git")))

proc dispatchApp(fx: Fixture; checkout: string): tuple[code: int; output: string] =
  let refs = fx.scratch / "previous-identity-refs.bin"
  writeFile(refs, refsRecord("refs/heads/main", fx.appSha,
    "refs/heads/main", fx.appSha))
  runProcess(fx.reproBin,
    ["hooks", "dispatch", "pre-push", "--protocol=2",
     "--repo-root", checkout, "--refs-file", refs, "--",
     "origin", fileUrl(fx.appOrigin)], childEnvironment([]))

suite "declared previous pre-push identity":
  test "previous path and its linked worktree select the real dependency closure":
    for linked in [false, true]:
      let fx = setup(findExe("git"))
      defer: removeDir(fx.scratch)
      # Remove the fixture's linked worktree before moving its primary; a new
      # linked checkout then proves the common-directory arm independently.
      discard require(q(fx.gitBin) & " -C " & q(fx.app) &
        " worktree remove " & q(fx.linked))
      let prior = fx.workspace / "old-app"
      moveDir(fx.app, prior)
      fx.declarePreviousApp("old-app")
      let checkout = if linked: fx.linked else: prior
      if linked:
        discard require(q(fx.gitBin) & " -C " & q(prior) &
          " worktree add -b previous-linked " & q(checkout) & " HEAD")
      # No remote match can rescue this test: it exercises only structure.
      discard require(q(fx.gitBin) & " -C " & q(prior) &
        " remote set-url origin " & q(fileUrl(fx.unrelatedOrigin)))
      writeFile(fx.dep / "dirty.txt", "closure must still be checked\n")
      let before = lockStoreSnapshot(fx)
      let checked = fx.dispatchApp(checkout)
      checkpoint(checked.output)
      check checked.code == 2
      let document = fx.report()
      check document["failures"].len == 1
      check document["failures"][0]["repo"].getStr() == "dep"
      check document["failures"][0]["property"].getStr() == "dirty"
      check "declared previous path" in noticesText(document)
      check "repro ws sync" in noticesText(document)
      check lockStoreSnapshot(fx) == before

  test "previous URL recovers only a genuinely absent canonical checkout":
    let fx = setup(findExe("git"))
    defer: removeDir(fx.scratch)
    let clone = fx.workspace / "copies" / "app"
    createDir(clone.parentDir)
    cloneRepo(fx.gitBin, fx.appOrigin, clone)
    fx.declarePreviousApp("old-app")
    writeFile(fx.dep / "dirty.txt", "closure blocker\n")
    # A live canonical checkout, a directory, a file and a dangling symlink
    # all forbid URL fallback, even though the old URL matches exactly.
    for occupancy in ["checkout", "directory", "file", "symlink", "absent"]:
      if occupancy == "directory":
        removeDir(fx.app)
        createDir(fx.app)
      elif occupancy == "file":
        removeDir(fx.app)
        writeFile(fx.app, "occupied\n")
      elif occupancy == "symlink":
        removeFile(fx.app)
        createSymlink(fx.scratch / "missing-target", fx.app)
      elif occupancy == "absent":
        removeFile(fx.app)
      let before = lockStoreSnapshot(fx)
      let checked = fx.dispatchApp(clone)
      checkpoint(occupancy & "\n" & checked.output)
      check checked.code == 2
      let document = fx.report()
      check document["failures"].len == 1
      if occupancy == "absent":
        check document["failures"][0]["repo"].getStr() == "dep"
        check document["failures"][0]["property"].getStr() == "dirty"
        check "declared previous URL" in noticesText(document)
      else:
        check document["failures"][0]["property"].getStr() == "current-repo-identity"
        check document["notices"].len == 0
      check lockStoreSnapshot(fx) == before

    # Two absent members claiming the same prior URL are ambiguous even
    # though each has a different current URL and checkout path.
    let ghost = "schema = \"reprobuild.workspace.repo.v2\"\n" &
      "[repo]\nname = \"ghost\"\npath = \"missing/ghost\"\n" &
      "remote = \"dep-origin\"\nmainline = \"main\"\n" &
      "[extensions]\npreviously = [{ path = \"missing/old-ghost\", " &
      "url_prefix = \"historical\", url_suffix = \"app-origin.git\" }]\n"
    writeFile(fx.workspace / "repos" / "ghost.toml", ghost)
    let project = fx.workspace / "projects" / "app.toml"
    writeFile(project, readFile(project).replace(
      "\"repos/unrelated.toml\"]", "\"repos/unrelated.toml\", \"repos/ghost.toml\"]"))
    let before = lockStoreSnapshot(fx)
    let ambiguous = fx.dispatchApp(clone)
    checkpoint(ambiguous.output)
    check ambiguous.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["property"].getStr() == "current-repo-identity"
    check "more than one declared repo" in document["failures"][0]["evidence"].getStr()
    check document["notices"].len == 0
    check lockStoreSnapshot(fx) == before

  test "previous path cannot replace an occupied canonical checkout":
    let fx = setup(findExe("git"))
    defer: removeDir(fx.scratch)
    let prior = fx.workspace / "old-app"
    cloneRepo(fx.gitBin, fx.appOrigin, prior)
    fx.declarePreviousApp("old-app")
    for occupancy in ["checkout", "corrupt"]:
      if occupancy == "corrupt":
        removeDir(fx.app)
        createDir(fx.app)
      let before = lockStoreSnapshot(fx)
      let checked = fx.dispatchApp(prior)
      checkpoint(checked.output)
      check checked.code == 2
      let document = fx.report()
      check document["failures"].len == 1
      check document["failures"][0]["property"].getStr() == "current-repo-identity"
      check document["notices"].len == 0
      check lockStoreSnapshot(fx) == before


suite "previous identity adversarial precedence":
  test "ambiguous prior structural identities refuse without lock writes":
    let fx = setup(findExe("git"))
    defer: removeDir(fx.scratch)
    let clone = fx.workspace / "copies" / "prior-shared"
    createDir(clone.parentDir)
    cloneRepo(fx.gitBin, fx.appOrigin, clone)
    # Different prior path declarations can resolve to one physical checkout.
    # Their names and prior paths are distinct; declaration order must never
    # select an authority when physical identity makes both claims match.
    for suffix in ["a", "b"]:
      let prior = "old-ghost-" & suffix
      createSymlink(clone, fx.workspace / prior)
      writeFile(fx.workspace / "repos" / ("ghost-" & suffix & ".toml"),
        "schema = \"reprobuild.workspace.repo.v2\"\n[repo]\n" &
        "name = \"ghost-" & suffix & "\"\npath = \"missing/" & suffix &
        "\"\nremote = \"dep-origin\"\nmainline = \"main\"\n" &
        "[extensions]\npreviously = [{ path = \"" & prior & "\" }]\n")
    let project = fx.workspace / "projects" / "app.toml"
    writeFile(project, readFile(project).replace("\"repos/unrelated.toml\"]",
      "\"repos/unrelated.toml\", \"repos/ghost-a.toml\", \"repos/ghost-b.toml\"]"))
    let before = lockStoreSnapshot(fx)
    let checked = fx.dispatchApp(clone)
    checkpoint(checked.output)
    check checked.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["property"].getStr() == "current-repo-identity"
    check "more than one declared repo" in document["failures"][0]["evidence"].getStr()
    check document["notices"].len == 0
    check lockStoreSnapshot(fx) == before

  test "current common directory wins over another repo previous path":
    let fx = setup(findExe("git"))
    defer: removeDir(fx.scratch)
    removeDir(fx.app)
    fx.declarePreviousApp("old-app")
    # The prior path is a physical alias to another live repo. A linked
    # worktree of that live repo must retain its current common-dir authority.
    createSymlink(fx.unrelated, fx.workspace / "old-app")
    let linked = fx.workspace / "worktrees" / "unrelated-linked"
    discard require(q(fx.gitBin) & " -C " & q(fx.unrelated) &
      " worktree add --detach " & q(linked) & " HEAD")
    writeFile(linked / "dirty.txt", "this is the pushed unrelated checkout\n")
    writeFile(fx.dep / "dirty.txt", "must stay outside the selected closure\n")
    let refs = fx.scratch / "precedence-refs.bin"
    writeFile(refs, refsRecord("HEAD", fx.unrelatedSha,
      "refs/heads/main", fx.unrelatedSha))
    let before = lockStoreSnapshot(fx)
    let checked = runProcess(fx.reproBin,
      ["hooks", "dispatch", "pre-push", "--protocol=2",
       "--repo-root", linked, "--refs-file", refs, "--",
       "origin", fileUrl(fx.unrelatedOrigin)], childEnvironment([]))
    checkpoint(checked.output)
    check checked.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["repo"].getStr() == "other/app-linked"
    check document["failures"][0]["property"].getStr() == "dirty"
    check "declared previous" notin noticesText(document)
    check lockStoreSnapshot(fx) == before

suite "declared previous identity publication":
  test "old path and URL can push a new HEAD through the real managed hook":
    for remote in ["origin", "renamed-alias"]:
      let fx = setup(findExe("git"))
      defer: removeDir(fx.scratch)
      discard require(q(fx.gitBin) & " -C " & q(fx.app) &
        " worktree remove " & q(fx.linked))
      let prior = fx.workspace / "old-app"
      moveDir(fx.app, prior)
      fx.declarePreviousApp("old-app")
      if remote != "origin":
        discard require(q(fx.gitBin) & " -C " & q(prior) &
          " remote rename origin " & q(remote))
      writeFile(prior / "outgoing.txt", "unpublished outgoing HEAD\n")
      discard require(q(fx.gitBin) & " -C " & q(prior) & " add outgoing.txt")
      discard require(q(fx.gitBin) & " -C " & q(prior) &
        " commit -m 'new outgoing commit before relocation'")
      let head = require(q(fx.gitBin) & " -C " & q(prior) &
        " rev-parse HEAD").strip()
      check head != fx.appSha
      discard require(q(fx.reproBin) & " hooks ensure --vcs " & q(prior))
      let pushed = runProcess(fx.gitBin,
        ["-C", prior, "push", remote, "main"],
        childEnvironment([("REPROBUILD_REPRO", fx.reproBin)]))
      checkpoint(remote & "\n" & pushed.output)
      check pushed.code == 0
      check require(q(fx.gitBin) & " --git-dir=" & q(fx.appOrigin) &
        " rev-parse refs/heads/main").strip() == head
      check not dirExists(fx.app)
      check dirExists(prior / ".git")
      let document = fx.report()
      check document["exitCode"].getInt() == 0
      check "declared previous path" in noticesText(document)
      # The immutable record must bind the actual pushed HEAD under the
      # canonical manifest coordinate, even though that directory is absent.
      let record = fx.latestLock(head)
      check head in readFile(record)
      check "path = \"app\"" in readFile(record)

  test "dirty old-path worktree remains a cleanliness refusal":
    let fx = setup(findExe("git"))
    defer: removeDir(fx.scratch)
    let prior = fx.workspace / "old-app"
    moveDir(fx.app, prior)
    fx.declarePreviousApp("old-app")
    writeFile(prior / "dirty.txt", "do not publish\n")
    let before = lockStoreSnapshot(fx)
    let checked = fx.dispatchApp(prior)
    checkpoint(checked.output)
    check checked.code == 2
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["repo"].getStr() == "app"
    check document["failures"][0]["property"].getStr() == "dirty"
    check lockStoreSnapshot(fx) == before

  test "prior URL alias cannot borrow authority for an unrelated pushURL":
    let fx = setup(findExe("git"))
    defer: removeDir(fx.scratch)
    discard require(q(fx.gitBin) & " -C " & q(fx.app) &
      " worktree remove " & q(fx.linked))
    let prior = fx.workspace / "old-app"
    moveDir(fx.app, prior)
    fx.declarePreviousApp("old-app")
    discard require(q(fx.gitBin) & " -C " & q(prior) &
      " remote rename origin renamed-alias")
    discard require(q(fx.gitBin) & " -C " & q(prior) &
      " remote set-url --push renamed-alias " & q(fileUrl(fx.unrelatedOrigin)))
    writeFile(prior / "outgoing.txt", "must not authorize this pushURL\n")
    discard require(q(fx.gitBin) & " -C " & q(prior) & " add outgoing.txt")
    discard require(q(fx.gitBin) & " -C " & q(prior) &
      " commit -m 'unpublished hostile pushURL head'")
    discard require(q(fx.reproBin) & " hooks ensure --vcs " & q(prior))
    let before = lockStoreSnapshot(fx)
    let pushed = runProcess(fx.gitBin,
      ["-C", prior, "push", "renamed-alias", "HEAD:refs/heads/hostile"],
      childEnvironment([("REPROBUILD_REPRO", fx.reproBin)]))
    checkpoint(pushed.output)
    check pushed.code != 0
    let document = fx.report()
    check document["failures"].len == 1
    check document["failures"][0]["property"].getStr() == "unpublished"
    check lockStoreSnapshot(fx) == before
    check require(q(fx.gitBin) & " --git-dir=" & q(fx.unrelatedOrigin) &
      " for-each-ref refs/heads/hostile").strip().len == 0
    check require(q(fx.gitBin) & " --git-dir=" & q(fx.appOrigin) &
      " rev-parse refs/heads/main").strip() == fx.appSha

## Shared fixture for the declared-repository-rename integration tests
## (`reprobuild-pm/spec/Declared-Repository-Renames.md`).
##
## NO MOCKS, and the reason is specific to this mechanism rather than a general
## preference. What is under test is a decision to MOVE A DIRECTORY that may
## hold the only copy of someone's work, taken on evidence read out of real git
## object stores. A fake git, a fake filesystem or a stubbed identity check
## would each remove exactly the thing that can be wrong:
##
##   * the identity check's object-presence fallback depends on `git filter-repo`
##     carrying blobs across a rewrite, which is a fact about git, not about our
##     code — so the rewritten-history case has to be produced by a real
##     rewrite-shaped force-push against a real bare repo;
##   * the move has to preserve local branches, stashes, reflogs and
##     uncommitted files, and "preserved" is only meaningful against a real
##     `.git`;
##   * the shared-bare evidence path reads through `objects/info/alternates`,
##     which only exists on a real object store.
##
## So: real `git init --bare` origins reached over `file://`, real clones, real
## TOML manifests, and the real `repro` binary driving a real
## `repro workspace sync`. The only injected value is `REPRO_WORKSPACE_CLONES`,
## pointed at the test's own scratch directory so the shared-clone cache a
## relocation refreshes is the test's and never the developer's.
##
## Every case skips (rather than fails) when `git` is absent from PATH, matching
## the convention of the sibling workspace-sync tests.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]
import repro_test_support

type
  RenameFixture* = object
    scratch*: string
    reproBin*: string
    workspaceRoot*: string
    originsDir*: string
      ## Directory holding one bare repo per server-side repo NAME. Reached as
      ## `file://<originsDir>` through a `url-prefixes/local.toml` prefix, so a
      ## fragment's `name` composes its URL and a declared PRIOR name composes
      ## a DIFFERENT one. That is what makes a URL-changing rename expressible
      ## at all; a `[[remote]]` fetch base ending in `.git` is used verbatim and
      ## would make every name resolve to one URL.
    clonesDir*: string

proc q*(value: string): string = quoteShell(value)

proc run*(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit*(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    fail()
  res.output

proc repoRoot*(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary*(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc clingoEnv*(): seq[tuple[name, value: string]] =
  ## The engine `dlopen`s libclingo/libzstd by leaf name. Mirrors the sibling
  ## workspace-sync tests rather than inventing a second way to do it.
  var clingoLib = getEnv("CLINGO_LIB")
  var zstdLib = getEnv("ZSTD_LIB")
  if (clingoLib.len == 0 or zstdLib.len == 0) and dirExists("/nix/store"):
    for kind, path in walkDir("/nix/store", relative = false):
      if kind == pcDir:
        let name = path.lastPathPart
        if name.contains("clingo-5."):
          clingoLib = path / "lib"
        elif name.contains("zstd-1."):
          zstdLib = path / "lib"
  if clingoLib.len > 0 and zstdLib.len > 0:
    let dyld = clingoLib & ":" & zstdLib
    result.add(("DYLD_LIBRARY_PATH", dyld))
    result.add(("DYLD_FALLBACK_LIBRARY_PATH", dyld))
    result.add(("LD_LIBRARY_PATH", dyld))

proc newRenameFixture*(gitBin, slug: string): RenameFixture =
  result.scratch = createTempDir("repro-rename-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.originsDir = result.scratch / "origins"
  result.clonesDir = result.scratch / "clones"
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.originsDir)
  createDir(result.clonesDir)
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  createDir(result.workspaceRoot / "url-prefixes")
  writeFile(result.workspaceRoot / "url-prefixes" / "local.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
    "[url-prefix]\nname = \"local\"\nurl = \"" &
    fileUrl(result.originsDir) & "\"\n")

proc originUrl*(fx: RenameFixture; name: string): string =
  fileUrl(fx.originsDir) & "/" & name

proc seedOrigin*(fx: RenameFixture; gitBin, name: string;
                 branch = "main"): tuple[initialSha, tipSha, seedPath: string] =
  ## A bare origin at `<originsDir>/<name>` with two commits, plus the working
  ## clone that produced it (kept, so a test can force-push a rewritten history
  ## through it later).
  let bare = fx.originsDir / name
  let work = fx.scratch / ("seed-" & name)
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(work))
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"Rename Tester\"")
  writeFile(work / "README.md", "seed " & name & "\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m initial")
  let initialSha = requireGit(q(gitBin) & " -C " & q(work) &
    " rev-parse HEAD").strip()
  # A second commit carrying a DISTINCTIVE BLOB. The object-presence half of
  # the identity check samples blobs from the remote's tip tree, so the fixture
  # has to contain blobs that are not the README every repo shares.
  createDir(work / "src")
  writeFile(work / "src" / "payload.txt",
    "payload for " & name & " — a blob no other fixture repo has\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add src/payload.txt")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m payload")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(work) & " push origin " & branch)
  let tipSha = requireGit(q(gitBin) & " -C " & q(work) &
    " rev-parse HEAD").strip()
  (initialSha: initialSha, tipSha: tipSha, seedPath: work)

proc rewriteOriginHistory*(fx: RenameFixture; gitBin, name, seedPath: string;
                           branch = "main"): string =
  ## Rewrite the origin's history so it shares NO COMMIT with anything already
  ## cloned from it, while CARRYING THE BLOBS ACROSS — the shape
  ## `git filter-repo` produces, and the shape §5's compound case needs.
  ##
  ## Built by replaying the same file contents onto a fresh root commit, so
  ## every blob id is identical and every commit id is different. Asserting
  ## that premise is each test's own job (a fixture that silently produced a
  ## shared commit would make the blob fallback untested).
  let orphan = fx.scratch / ("rewrite-" & branch & "-" & $epochTime().int)
  createDir(orphan)
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(orphan))
  discard requireGit(q(gitBin) & " -C " & q(orphan) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(orphan) &
    " config user.name \"Rename Tester\"")
  # Copy the seed's working files verbatim (same bytes => same blob ids).
  for kind, path in walkDir(seedPath):
    let base = path.lastPathPart
    if base == ".git": continue
    if kind == pcDir: copyDir(path, orphan / base)
    else: copyFile(path, orphan / base)
  discard requireGit(q(gitBin) & " -C " & q(orphan) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(orphan) &
    " commit -m \"rewritten history, identical trees\"")
  discard requireGit(q(gitBin) & " -C " & q(orphan) & " remote add origin " &
    q(fx.originsDir / name))
  discard requireGit(q(gitBin) & " -C " & q(orphan) &
    " push --force origin " & branch)
  requireGit(q(gitBin) & " -C " & q(orphan) & " rev-parse HEAD").strip()

proc cloneInto*(fx: RenameFixture; gitBin, name, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fx.originUrl(name)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Rename Tester\"")

proc writeFragment*(fx: RenameFixture; fragment, name, path: string;
                    previously = ""; branch = "main"; extra = "") =
  ## One `repos/<fragment>.toml`. `previously` is the raw inline-table-array
  ## body, so a test can write a malformed one on purpose.
  var body =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"" & name & "\"\npath = \"" & path & "\"\n" &
    "url_prefix = \"local\"\nbranch = \"" & branch & "\"\n" & extra
  if previously.len > 0:
    body.add("\n[extensions]\npreviously = " & previously & "\n")
  writeFile(fx.workspaceRoot / "repos" / (fragment & ".toml"), body)

proc writeProject*(fx: RenameFixture; members: openArray[string];
                   projectName = "myproject"; branch = "main") =
  var quoted: seq[string]
  for m in members:
    quoted.add("\"" & m & "\"")
  # `member_repos` is a TOP-LEVEL key, so it has to precede `[project]`: after
  # it, TOML reads it as `project.member_repos`, which the strict decoder
  # rejects as an unknown field under `[repo]`'s sibling table.
  writeFile(fx.workspaceRoot / "projects" / (projectName & ".toml"),
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "member_repos = [" & quoted.join(", ") & "]\n\n" &
    "[project]\nname = \"" & projectName & "\"\n" &
    "default_revision = \"" & branch & "\"\ntrunk = \"" & branch & "\"\n")

proc invokeSync*(fx: RenameFixture;
                 extraArgs: openArray[string] = [];
                 projectName = "myproject"): CmdResult =
  var cmdArgs = @[
    fx.reproBin, "workspace", "sync", "--write-report", projectName,
    "--workspace-root=" & fx.workspaceRoot]
  for arg in extraArgs:
    cmdArgs.add(arg)
  var env = clingoEnv()
  # Hermetic shared-clone cache. The relocation pre-flight refreshes the bare
  # for the NEW url to get independent identity evidence, so without this the
  # test would write into the developer's own `~/.cache/reprobuild/clones`.
  env.add(("REPRO_WORKSPACE_CLONES", fx.clonesDir))
  runShell(shellCommand(cmdArgs, env = env))

proc readReport*(fx: RenameFixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc entryFor*(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  checkpoint("no report entry for path '" & path & "' in " &
    pretty(report["repos"], indent = 2))
  fail()
  newJNull()

proc field*(entry: JsonNode; key: string): string =
  ## A report field as a string, or "" when the report does not carry the key
  ## at all.
  ##
  ## TOLERANT ON PURPOSE, and the purpose is the MUTATION CHECK. Every case
  ## here has to fail when the mechanism is reverted, and fail ON ITS PRIMARY
  ## ASSERTION — "break the property it names, confirm the test fails on its
  ## primary assertion". A bare `entry["relocation"]` against a `repro` that
  ## predates the field raises `KeyError` from inside the JSON library, which
  ## aborts the case before its own assertion is reached: the suite goes red,
  ## but it goes red for the wrong reason and says nothing about the property.
  ## Returning "" instead lets the assertion itself be the thing that fails,
  ## naming the field and the value it wanted.
  if entry.isNil or entry.kind != JObject or key notin entry:
    return ""
  let value = entry[key]
  if value.isNil or value.kind != JString:
    return ""
  value.getStr()

proc planFor*(report: JsonNode; path: string): JsonNode =
  for entry in report["plan"]:
    if entry["path"].getStr() == path:
      return entry
  checkpoint("no plan entry for path '" & path & "'")
  fail()
  newJNull()

proc localBranches*(gitBin, repoPath: string): seq[string] =
  # `%(refname:short)` has to be QUOTED: these helpers go through a shell, and
  # an unquoted `(` is a shell syntax error rather than a git format string.
  for line in requireGit(q(gitBin) & " -C " & q(repoPath) &
      " for-each-ref --format=" & q("%(refname:short)") &
      " refs/heads").splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)

proc stashCount*(gitBin, repoPath: string): int =
  let listed = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " stash list").strip()
  if listed.len == 0: 0 else: listed.splitLines().len

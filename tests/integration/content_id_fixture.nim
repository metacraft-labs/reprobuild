## Shared fixture for the ``t_content_id_*`` integration tests: hermetic git,
## real repositories, and the entry lists the content-id vectors use.
##
## Every repository here is a real one made by the real ``git``; nothing is
## mocked. The process environment is made hermetic once (``enterHermeticGit``):
## no system or user git configuration, no inherited repository variables, a
## private ``TMPDIR`` (so a test can assert the library left no temporary
## directory behind), fixed identities and dates.

import std/[os, osproc, streams, strutils, tempfiles]

import repro_cli_support/content_id

type
  GitRun* = object
    code*: int
    stdout*: string
    stderr*: string

proc runGitIn*(dir: string; args: openArray[string]; input = "";
               env: openArray[(string, string)] = []): GitRun =
  ## Run the real git with an argv (no shell) and keep the streams apart.
  var saved: seq[(string, bool, string)]
  for (key, value) in env:
    saved.add (key, existsEnv(key), getEnv(key))
    putEnv(key, value)
  try:
    var process = startProcess("git", workingDir = dir, args = args,
                               options = {poUsePath})
    try:
      if input.len > 0:
        process.inputStream.write(input)
      process.inputStream.close()
      result.stdout = process.outputStream.readAll()
      result.stderr = process.errorStream.readAll()
      result.code = process.waitForExit()
    finally:
      process.close()
  finally:
    for (key, existed, value) in saved:
      if existed: putEnv(key, value) else: delEnv(key)

proc git*(dir: string; args: varargs[string]): string =
  ## Run git and require success; its stdout.
  let run = runGitIn(dir, @args)
  if run.code != 0:
    raise newException(AssertionDefect, "git " & @args.join(" ") & " in " &
      dir & " failed (" & $run.code & "): " & run.stderr)
  run.stdout

proc gitLine*(dir: string; args: varargs[string]): string =
  result = git(dir, args)
  result.stripLineEnd()

proc enterHermeticGit*(): string =
  ## Make this process's git hermetic and return a fresh scratch directory.
  ## Called once per test case; each case runs in its own process.
  # The private TMPDIR set below must not become the parent of the next
  # case's scratch, so the outer one is remembered on first use.
  if not existsEnv("REPRO_T_CONTENT_ID_OUTER_TMPDIR"):
    putEnv("REPRO_T_CONTENT_ID_OUTER_TMPDIR", getTempDir())
  result = createTempDir("repro-t-content-id-", "",
                         getEnv("REPRO_T_CONTENT_ID_OUTER_TMPDIR"))
  let config = result / "gitconfig"
  writeFile(config, "[init]\n\tdefaultBranch = main\n" &
    "[core]\n\tprecomposeUnicode = false\n\tautocrlf = false\n" &
    "[advice]\n\taddEmbeddedRepo = false\n\tdetachedHead = false\n" &
    "[protocol \"file\"]\n\tallow = always\n")
  for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
              "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
              "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
              "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS",
              "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS", "GIT_CEILING_DIRECTORIES"]:
    delEnv(key)
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  putEnv("GIT_CONFIG_GLOBAL", config)
  putEnv("HOME", result)
  putEnv("XDG_CONFIG_HOME", result / "xdg")
  putEnv("GIT_AUTHOR_NAME", "Fixture")
  putEnv("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
  putEnv("GIT_COMMITTER_NAME", "Fixture")
  putEnv("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
  putEnv("GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z")
  putEnv("GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z")
  let tmp = result / "tmp"
  createDir(tmp)
  putEnv("TMPDIR", tmp)

proc libraryTempLeftovers*(scratch: string): seq[string] =
  ## Temporary directories the library left in the private ``TMPDIR``.
  for kind, path in walkDir(scratch / "tmp"):
    if path.extractFilename.startsWith("repro-content-id-"):
      result.add path

proc newRepo*(parent, name: string; objectFormat = "sha1"): string =
  result = parent / name
  discard git(parent, "init", "-q", "--object-format=" & objectFormat, name)

proc writeEntryFile*(root, path, content: string) =
  let full = root / path
  createDir(full.parentDir)
  writeFile(full, content)

proc commitAll*(repo, message: string) =
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "-q", "--allow-empty", "-m", message)

proc stageEntries*(repo: string; entries: openArray[ContentEntry]) =
  ## Put ``entries`` into ``repo``'s index exactly as the vectors README
  ## re-derives them: each content written as a blob object (a ``160000``
  ## entry is not an object; its revision is used as is), then the whole set
  ## staged with ``update-index -z --index-info``.
  var info = ""
  for entry in entries:
    let objectId =
      if entry.mode == "160000": entry.content
      else:
        var id = runGitIn(repo, ["hash-object", "-w", "--stdin"],
                          input = entry.content).stdout
        id.stripLineEnd()
        id
    info.add entry.mode & " " & objectId & "\t" & entry.path & "\0"
  let run = runGitIn(repo, ["update-index", "-z", "--index-info"], input = info)
  if run.code != 0:
    raise newException(AssertionDefect, "update-index failed: " & run.stderr)

proc materialiseEntries*(repo: string; entries: openArray[ContentEntry]) =
  ## Write ``entries`` into ``repo``'s WORKING TREE as real files, executable
  ## files, symbolic links and (for ``160000``) an unpopulated nested
  ## repository directory whose gitlink is staged directly, then stage them.
  for entry in entries:
    let full = repo / entry.path
    createDir(full.parentDir)
    case entry.mode
    of "100644":
      writeFile(full, entry.content)
    of "100755":
      writeFile(full, entry.content)
      setFilePermissions(full, getFilePermissions(full) +
        {fpUserExec, fpGroupExec, fpOthersExec})
    of "120000":
      createSymlink(entry.content, full)
    of "160000":
      createDir(full)
    else:
      raise newException(AssertionDefect, "unknown mode " & entry.mode)
  for entry in entries:
    if entry.mode == "160000":
      discard git(repo, "update-index", "--add", "--cacheinfo",
                  "160000," & entry.content & "," & entry.path)
    else:
      discard git(repo, "--literal-pathspecs", "add", "--", entry.path)

proc indexBytes*(repo: string): string =
  readFile(repo / ".git" / "index")

proc emptyTree*(algorithm: ContentAlgorithm): string =
  gitTreeIdOfEntries([], algorithm).id

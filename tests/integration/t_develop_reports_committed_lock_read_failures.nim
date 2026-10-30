## Real public-lock failures reach the source-matched exported command.
## No mocks or borrowed SDK: owned real files, Git repos, permissions and native
## Windows sharing denial are exercised by a self-child. POSIX FIFO/symlink
## assertions supplement the portable regular-file/directory controls.
import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_cli_support
import repro_test_support
import repro_workspace_manifests
when defined(posix):
  from std/posix import chmod, Mode, geteuid, mkfifo, EACCES, ENOTDIR
elif defined(windows):
  # Real Win32 sharing exclusion, not a fabricated ACL or mocked read error.
  # https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createfilew
  proc denyReadCreateFileW(path: WideCString; access, sharing: uint32;
      security: pointer; disposition, flags: uint32; templateFile: pointer): pointer
      {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}
  proc denyReadCloseHandle(handle: pointer): int32
      {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

if paramCount() > 0 and paramStr(1) == "--develop-child":
  for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
               "REPROBUILD_VCS_PRIVATE_CONFIG"]:
    putEnv(name, paramStr(2) / (name & ".absent"))
  quit(runDevelopCommand(@["--all", "--list", "--json",
    "--tool-provisioning=path", "--workspace-root=" & paramStr(2)]))

proc runDevelop(root: string): tuple[output: string, exitCode: int] =
  # A type-check regression must fail, not wedge the suite opening a FIFO.
  # Two minutes is a generous containment deadline for this local no-build
  # command, not a performance oracle. The shared helper terminates and reaps.
  let actual = runShell(shellCommand([getAppFilename(), "--develop-child", root]),
    timeoutMs = 120_000)
  doAssert actual.code != runShellTimedOutCode, actual.output
  (output: actual.output, exitCode: actual.code)

proc lockDoc(deps = ""): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n" &
  "[lock]\nplatform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"read-failure-control\"\nvariants = []\npackages = []\ndeps = [" & deps & "]\n"

proc depDoc(name, path, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", tags = \"\" }"

proc strictCause(root: string): string =
  try:
    discard populateLockedDeps(LockSource(kind: lskCommittedLock,
      workspaceRoot: root), strictCommittedRead = true)
  except CatchableError as error: return error.msg
  doAssert false, "fixture did not cause a real checked-read failure"

proc requireFailure(root, lockPath, cause: string) =
  let actual = runDevelop(root)
  doAssert actual.exitCode == 2, actual.output
  let report = parseJson(actual.output)
  doAssert report["exitCode"].getInt() == 2, actual.output
  doAssert report["repos"].len == 0, actual.output
  var found = 0
  for backend in report["backends"]:
    if backend["location"].getStr() != lockPath: continue
    inc found
    doAssert backend["tier"].getStr() == "public", actual.output
    doAssert backend["kind"].getStr() == "committed-lock", actual.output
    doAssert not backend["reachable"].getBool(), actual.output
    doAssert backend["diagnostic"].getStr() == cause, actual.output
  doAssert found == 1, actual.output
  doAssert report["errors"].len > 0, actual.output
  let diagnostic = report["errors"][0]["diagnostic"].getStr()
  doAssert lockPath in diagnostic and cause in diagnostic, actual.output
  doAssert "repro lock validate --lock=" in diagnostic, actual.output
  doAssert "readable, but it holds no lock record" notin actual.output, actual.output
  doAssert not fileExists(root / ".repro" / "develop-overrides.toml"), actual.output

proc requireEmpty(root: string; present: bool) =
  let actual = runDevelop(root)
  doAssert actual.exitCode == 1, actual.output # unchanged empty-union gate
  let report = parseJson(actual.output)
  doAssert report["exitCode"].getInt() == 1, actual.output
  doAssert report["repos"].len == 0, actual.output
  doAssert report["backends"].len == 1, actual.output
  let backend = report["backends"][0]
  doAssert backend["location"].getStr() == root / "repro.lock", actual.output
  doAssert backend["reachable"].getBool() == present, actual.output
  doAssert backend["records"].getInt() == 0, actual.output
  doAssert "could not be read" notin actual.output, actual.output

template withReadDenied(path: string; body: untyped) =
  when defined(posix):
    doAssert geteuid() != 0, "permission-denial control requires an unprivileged caller"
    doAssert chmod(path.cstring, Mode(0)) == 0
    try: body
    finally: doAssert chmod(path.cstring, Mode(0o600)) == 0
  elif defined(windows):
    let wide = newWideCString(path)
    let handle = denyReadCreateFileW(wide, 0x80000000'u32, 0'u32,
      nil, 3'u32, 0x80'u32, nil) # GENERIC_READ, no sharing, OPEN_EXISTING
    doAssert handle != cast[pointer](-1), "could not establish native sharing denial"
    try: body
    finally: doAssert denyReadCloseHandle(handle) != 0
  else:
    {.error: "A real native file-denial fixture is required on this platform".}

proc requireActualReadDenied(path: string) =
  var denied = false
  try: discard readFile(path)
  except CatchableError: denied = true
  doAssert denied, "fixture did not deny an actual file read"

proc fixtureGit(repo: string; args: string): string =
  let git = findExe("git")
  doAssert git.len > 0, "real Git fixture prerequisite is missing"
  let actual = execCmdEx(quoteShell(git) & " -C " & quoteShell(repo) & " " & args)
  doAssert actual.exitCode == 0, actual.output
  actual.output.strip()

proc initFixtureRepo(repo, hooks: string): string =
  createDir(repo)
  discard fixtureGit(repo, "-c init.templateDir= init -q --initial-branch=main")
  # Settings apply only to these fresh fixtures, not the product repository.
  for args in ["config user.email t@example.invalid", "config user.name Fixture",
               "config commit.gpgsign false", "config core.hooksPath " & quoteShell(hooks),
               "remote add origin " & quoteShell(fileUrl(repo))]:
    discard fixtureGit(repo, args)
  writeFile(repo / "seed.txt", repo.lastPathPart & "\n")
  discard fixtureGit(repo, "add -- seed.txt")
  discard fixtureGit(repo, "commit -qm fixture")
  doAssert fixtureGit(repo, "branch --show-current") == "main"
  doAssert fixtureGit(repo, "remote get-url origin") == fileUrl(repo)
  fixtureGit(repo, "rev-parse HEAD")

suite "develop reports present committed-lock failures":
  test "malformed root lock preserves parser diagnostic and best-effort callers":
    let root = createTempDir("develop-lock-malformed-", "")
    defer: removeDir(root)
    let lockPath = root / "repro.lock"
    for invalid in ["schema = [this is not TOML\n",
                    "schema = \"unsupported.lock.schema\"\n"]:
      writeFile(lockPath, invalid)
      let cause = strictCause(root)
      check populateLockedDeps(LockSource(kind: lskCommittedLock,
        workspaceRoot: root)).deps.len == 0
      requireFailure(root, lockPath, cause)

  test "absent and valid empty locks are not reported as read failures":
    let root = createTempDir("develop-lock-optional-", "")
    defer: removeDir(root)
    requireEmpty(root, false)
    writeFile(root / "repro.lock", lockDoc())
    requireEmpty(root, true)
    check populateLockedDeps(LockSource(kind: lskCommittedLock,
      workspaceRoot: root), strictCommittedRead = true).deps.len == 0

  test "real native file denial is not reported as readable empty":
    let root = createTempDir("develop-lock-denied-", "")
    defer: removeDir(root)
    let lockPath = root / "repro.lock"
    writeFile(lockPath, lockDoc())
    withReadDenied(lockPath):
      expect CatchableError:
        discard readFile(lockPath)
      requireActualReadDenied(lockPath)
      requireFailure(root, lockPath, strictCause(root))

  test "participating lock failure refuses despite a valid nonempty root lock":
    let root = createTempDir("develop-lock-participating-", "")
    defer: removeDir(root)
    let parent = root / "nested"
    let repo = parent / "producer"
    let core = root / "core"
    let hooks = root / "fixture-hooks"
    createDir(hooks)
    let sha = initFixtureRepo(repo, hooks)
    let coreSha = initFixtureRepo(core, hooks)
    let manifests = root / ".repro" / "manifests"
    createDir(manifests / "projects")
    createDir(manifests / "repos")
    writeFile(manifests / "projects" / "ws.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n" &
      "[project]\nname = \"ws\"\n" &
      "[[remote]]\nname = \"core-origin\"\nfetch = \"" & fileUrl(core) & "\"\n" &
      "[[remote]]\nname = \"producer-origin\"\nfetch = \"" & fileUrl(repo) & "\"\n" &
      "includes = [\"repos/core.toml\", \"repos/producer.toml\"]\n")
    for (name, path, remote) in [("core", "core", "core-origin"),
                                 ("producer", "nested/producer", "producer-origin")]:
      writeFile(manifests / "repos" / (name & ".toml"),
        "schema = \"reprobuild.workspace.repo.v2\"\n" &
        "[repo]\nname = \"" & name & "\"\npath = \"" & path &
        "\"\nremote = \"" & remote & "\"\nmainline = \"main\"\n")
    writeWorkspaceBranch(root, project = "ws", branch = "main")
    # The root's independent accessible record keeps the union nonempty even
    # when the other participating checkout cannot be traversed.
    writeFile(root / "repro.lock", lockDoc(depDoc("core", "core", fileUrl(core), coreSha)))
    let lockPath = repo / "repro.lock"
    writeFile(lockPath, "schema = [invalid TOML\n")
    requireFailure(root, lockPath, strictCause(repo))
    writeFile(lockPath, lockDoc(depDoc("producer", ".", fileUrl(repo), sha)))
    let repaired = runDevelop(root)
    checkpoint(repaired.output)
    require repaired.exitCode == 0
    let repairedReport = parseJson(repaired.output)
    var producerFound = false
    for row in repairedReport["repos"]:
      if row["name"].getStr() == "producer":
        producerFound = true
        check row["revision"].getStr() == sha
        check row["state"].getStr() == "at-lock"
    check producerFound
    withReadDenied(lockPath):
      requireActualReadDenied(lockPath)
      requireFailure(root, lockPath, strictCause(repo))
    when defined(posix):
      require geteuid() != 0
      let permissions = getFilePermissions(parent)
      setFilePermissions(parent, {})
      try:
        var actualErrno = 0'i32
        try: discard getFileInfo(lockPath)
        except OSError as error: actualErrno = error.errorCode
        require actualErrno == EACCES
        require not dirExists(repo) # the former soft gate silently skipped it
        requireFailure(root, lockPath, strictCause(repo))
      finally:
        setFilePermissions(parent, permissions)
    let parking = createTempDir("develop-lock-parking-", "")
    defer: removeDir(parking)
    let parked = parking / "producer"
    moveDir(repo, parked)
    try:
      # A genuinely absent checkout is still optional, not an unreadable medium.
      check populateLockedDeps(LockSource(kind: lskCommittedLock,
        workspaceRoot: repo), strictCommittedRead = true).deps.len == 0
      let absent = runDevelop(root)
      checkpoint(absent.output)
      require absent.exitCode == 0
      let absentReport = parseJson(absent.output)
      check absentReport["errors"].len == 0
      for row in absentReport["repos"]:
        check row["name"].getStr() != "producer"
      when defined(posix):
        # POSIX distinguishes ENOTDIR from ENOENT. It is now a malformed
        # declared medium refusal, not absence; Win32's 2/3 handling is unchanged.
        writeFile(repo, "not a checkout directory\n")
        try:
          var actualErrno = 0'i32
          try: discard getFileInfo(lockPath)
          except OSError as error: actualErrno = error.errorCode
          require actualErrno == ENOTDIR
          requireFailure(root, lockPath, strictCause(repo))
        finally:
          removeFile(repo)
    finally:
      moveDir(parked, repo)

  test "checked reads preserve unsafe checkout-path refusal independently":
    let root = createTempDir("develop-lock-unsafe-path-", "")
    defer: removeDir(root)
    writeFile(root / "repro.lock", lockDoc(depDoc("..", "producer",
      "https://example.invalid/producer.git", repeat('a', 40))))
    expect LockedCheckoutPathError:
      discard populateLockedDeps(LockSource(kind: lskCommittedLock, workspaceRoot: root))
    expect LockedCheckoutPathError:
      discard populateLockedDeps(LockSource(kind: lskCommittedLock,
        workspaceRoot: root), strictCommittedRead = true)

  test "special lock media refuse before any blocking read":
    let root = createTempDir("develop-lock-special-", "")
    defer: removeDir(root)
    let lockPath = root / "repro.lock"
    createDir(lockPath)
    requireFailure(root, lockPath, strictCause(root))
    removeDir(lockPath)
    when defined(posix):
      require mkfifo(lockPath.cstring, Mode(0o600)) == 0
      requireFailure(root, lockPath, "committed lock is not a regular file: " & lockPath)
      removeFile(lockPath)
      let target = root / "owned-fifo"
      require mkfifo(target.cstring, Mode(0o600)) == 0
      createSymlink(target, lockPath)
      requireFailure(root, lockPath, "committed lock is not a regular file: " & lockPath)

  test "regular lock stays readable; POSIX link reads preserve target semantics":
    let root = createTempDir("develop-lock-link-", "")
    defer: removeDir(root)
    let lockPath = root / "repro.lock"
    writeFile(lockPath, lockDoc())
    requireEmpty(root, true)
    check populateLockedDeps(LockSource(kind: lskCommittedLock,
      workspaceRoot: root), strictCommittedRead = true).deps.len == 0
    when defined(posix):
      removeFile(lockPath)
      let target = root / "owned.lock"
      writeFile(target, lockDoc())
      createSymlink(target, lockPath)
      requireEmpty(root, true)
      removeFile(target)
      requireFailure(root, lockPath, strictCause(root))

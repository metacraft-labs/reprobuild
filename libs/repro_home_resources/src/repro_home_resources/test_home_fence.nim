## Test home fence: a tripwire that stops a home-resource driver from
## writing into a home the test suite has declared off-limits.
##
## Why it exists. Between `b9d193fee` and `8d8418a1e` the M69 env-binding
## synthesis ignored the apply's explicit home (`--home-dir` /
## `ApplyOptions.homeDir`) and resolved `env.userPath` host files through
## `getHomeDir()`. The m71 cross-host and m83 apply tests, which pass an
## explicit temporary home but run with the operator's real `$HOME`,
## therefore wrote `home.package.<id>.bin` PATH blocks into the real
## `~/.bashrc` of every host that ran the suite — and passed. On a host
## whose `~/.bashrc` is a Home Manager store symlink the write replaced the
## symlink with a regular file. (reprobuild-pm issue
## `2026-10-20-home-apply-tests-wrote-path-blocks-into-the-real-users-bashrc.md`.)
##
## `1eac81d6b` confines the m71 and m83 fixtures (`withHomeApplyGuard` in
## `repro_test_support/home_apply_guard`): each points `HOME` at a disposable
## directory and fails when anything appears there. That protects the tests
## that use it. The fence is the suite-wide backstop for every other test:
## any test whose home-resource write resolves into the invoking user's real
## home fails instead of writing there, whether or not it adopted the guard.
## It is OFF unless `REPRO_TEST_HOME_FENCE` is set, so production applies are
## unaffected. `scripts/run_tests.sh` sets it to the invoking user's home
## (`$HOME`, plus the passwd home when it differs).
##
## Where it is checked. Every low-level writer that mutates a path under a
## home calls `enforceTestHomeFence` before its first side effect: the
## `fs.managedBlock`, `fs.userFile`, `systemd.userUnit`, `launchd.userAgent`
## and app-bundle drivers here, and `repro_home_apply`'s generated-file,
## managed-block, stow and launcher materialisers. A new writer of that
## kind must call it too, or the suite stops covering it.
##
## Rule. A write to `path` is refused when `path` lies inside a protected
## root `P` and is not inside an allowed carve-out `A` that itself lies
## strictly inside `P`. Allowed roots are the process temp dir
## (`getTempDir()`, i.e. `$TMPDIR`) and every entry of
## `REPRO_TEST_HOME_FENCE_ALLOW`. The carve-out has to sit inside the
## protected home because the suite's scratch normally does
## (`~/.cache/reprobuild-test-tmp/<slot>`); an allowed root that merely
## CONTAINS a protected root does not open it — that is what lets a test
## protect a sentinel "process home" created under its own temp dir.

import std/[os, strutils]

const
  TestHomeFenceEnvVar* = "REPRO_TEST_HOME_FENCE"
    ## `PathSep`-separated list of protected home directories.
  TestHomeFenceAllowEnvVar* = "REPRO_TEST_HOME_FENCE_ALLOW"
    ## `PathSep`-separated list of extra carve-outs (in addition to
    ## `getTempDir()`).

type
  TestHomeFenceError* = object of IOError
    ## Raised when a home-resource driver is about to write inside a
    ## fenced home. Deliberately an `IOError` so the apply pipeline's
    ## existing driver-failure handling aborts the apply.
    path*: string
    protectedRoot*: string

proc canonicalFencePath(p: string): string =
  ## Absolute, normalised, symlink-resolved form of `p`. Only the longest
  ## EXISTING ancestor can be resolved (the target file usually does not
  ## exist yet), so the remainder is re-joined lexically. Resolving the
  ## ancestor matters on hosts where `$HOME` reaches the same directory
  ## through a symlink (`/home` -> `/var/home`, macOS `/tmp` ->
  ## `/private/tmp`).
  if p.len == 0:
    return ""
  var raw = p
  when defined(windows):
    # A caller may pass the `\\?\` extended-length spelling produced by
    # `repro_core/paths.extendedPath`; it names the same file as the
    # ordinary form and has to compare equal to it.
    if raw.startsWith(r"\\?\"):
      raw = raw[4 .. ^1]
  var abs = normalizedPath(absolutePath(raw))
  var existing = abs
  var rest: seq[string]
  while existing.len > 0 and not (dirExists(existing) or
      fileExists(existing)):
    let parent = existing.parentDir()
    if parent.len == 0 or parent == existing:
      break
    rest.insert(existing.extractFilename(), 0)
    existing = parent
  if existing.len > 0 and (dirExists(existing) or fileExists(existing)):
    try:
      existing = expandFilename(existing)
    except OSError:
      discard
    result = existing
    for part in rest:
      result = result / part
    result = normalizedPath(result)
  else:
    result = abs
  when defined(windows):
    result = result.toLowerAscii()
  while result.len > 1 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc isWithin(path, root: string): bool =
  ## Both arguments already canonical. `root` itself counts as within.
  if root.len == 0:
    return false
  if path == root:
    return true
  # A POSIX filesystem root keeps its trailing `/` through
  # `canonicalFencePath`; adding another would never match.
  if root[^1] in {DirSep, AltSep}:
    return path.startsWith(root)
  path.startsWith(root & DirSep) or
    (DirSep != AltSep and path.startsWith(root & AltSep))

proc splitRoots(raw: string; dropFilesystemRoots = false): seq[string] =
  ## Canonical, de-duplicated entries of a `PathSep`-separated list.
  ## `dropFilesystemRoots` skips `/` and `C:\`: an account whose home is
  ## the filesystem root (`HOME=/` in minimal containers) cannot be fenced
  ## without fencing every path on the machine, so such a home is left
  ## unfenced rather than turning every driver write into a failure.
  for entry in raw.split(PathSep):
    let t = entry.strip()
    if t.len == 0:
      continue
    let c = canonicalFencePath(t)
    if c.len == 0 or c in result:
      continue
    if dropFilesystemRoots and (isRootDir(c) or isRootDir(c & DirSep)):
      continue
    result.add(c)

proc testHomeFenceActive*(): bool =
  getEnv(TestHomeFenceEnvVar).strip().len > 0

proc testHomeFenceViolation*(path: string): string =
  ## The protected root `path` would violate, or "" when the write is
  ## allowed (including whenever the fence is off).
  let protectedRoots = splitRoots(getEnv(TestHomeFenceEnvVar),
    dropFilesystemRoots = true)
  if protectedRoots.len == 0 or path.len == 0:
    return ""
  var allowed = splitRoots(getEnv(TestHomeFenceAllowEnvVar))
  let tmp = canonicalFencePath(getTempDir())
  if tmp.len > 0 and tmp notin allowed:
    allowed.add(tmp)
  let target = canonicalFencePath(path)
  for root in protectedRoots:
    if not isWithin(target, root):
      continue
    var carvedOut = false
    for a in allowed:
      if a != root and isWithin(a, root) and isWithin(target, a):
        carvedOut = true
        break
    if not carvedOut:
      return root
  ""

proc enforceTestHomeFence*(path, operation: string) =
  ## Raise `TestHomeFenceError` when `path` is inside a fenced home.
  ## `operation` names the driver action for the message.
  let root = testHomeFenceViolation(path)
  if root.len == 0:
    return
  var e = newException(TestHomeFenceError,
    operation & ": refusing to write '" & path & "': it is inside '" &
    root & "', which " & TestHomeFenceEnvVar & " protects. A test drove " &
    "a home apply whose resource resolved outside the apply's own home " &
    "(pass the test's temporary home through --home-dir / " &
    "ApplyOptions.homeDir, and make every host-file path derive from it).")
  e.path = path
  e.protectedRoot = root
  raise e

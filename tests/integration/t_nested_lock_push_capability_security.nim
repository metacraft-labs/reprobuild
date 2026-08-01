## Nested lock-push capability — one-use security and process races.
##
## This suite exercises the real capability files below a real Git common
## directory. It does not mock claim/rename or file metadata. Two independent
## OS processes race to claim one token and exactly one may authorize. Further
## cases prove replay refusal, the exact 30-second age and 2-second future-skew
## bounds, schema/token/repo/worktree/common-dir/user/object-format/HEAD/remote/
## URL/ref binding, copied-record rejection, linked-worktree isolation, POSIX
## mode/owner/link invariants, symlink and hardlink refusal, parent SIGTERM
## cleanup, concurrent directory-component substitution, and conservative
## expiry cleanup. The child process receives the token only through
## ``REPROBUILD_INTERNAL_HOOK_CAPABILITY``; it is never placed in argv.
##
## Symlink/hardlink metadata cases run on POSIX. Windows uses the same
## functional race/replay/binding cases; its ACL/reparse-point assertions are
## platform-specific and must fail closed in the implementation when Windows
## cannot enforce them. The race result (exactly one authorization) and each
## one-binding mutation make the claims independently falsifiable. No ignored
## tests, mocked filesystem boundaries, or network access are used.

import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
  times, unittest]

import repro_cli_support/push_hook_protocol
import repro_test_support

when defined(posix):
  import std/posix

proc q(value: string): string =
  when defined(windows):
    # Command strings are evaluated by Git-for-Windows sh (see run below).
    # Quote even space-free drive paths so backslashes remain literal.
    "'" & value.replace("'", "'\"'\"'") & "'"
  else:
    quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  when defined(windows):
    let shell = findExe("sh")
    if shell.len == 0:
      return (127, "Git hook shell is unavailable")
    let res = runShell(shellCommand(@[shell, "-c", command]))
    (res.code, res.output)
  else:
    let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
    (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    stderr.writeLine("required command failed: " & command & "\n" & res.output)
    quit 1
  res.output

proc requireNative(args: openArray[string]): string =
  let res = runShell(shellCommand(args))
  if res.code != 0:
    stderr.writeLine("required native command failed: " & args.join(" ") &
      "\n" & res.output)
    quit 1
  res.output

proc validateCapabilityScratchForCleanup(path: string):
    tuple[ok: bool; diagnostic: string] =
  ## Validate the adversarial fixture root without following its final path
  ## component. Only a direct, uniquely named child of the canonical process
  ## temp directory may reach the POSIX ``rm -rf --`` fallback below.
  const Prefix = "repro-capability-security-"
  if path.len == 0 or not path.isAbsolute:
    return (false, "scratch path must be a nonempty absolute path")
  let lexical =
    try: os.normalizedPath(path)
    except OSError: return (false, "scratch path cannot be normalized")
  if lexical != path or lexical == $DirSep or
      lexical == os.normalizedPath(getTempDir()):
    return (false, "scratch path is not a direct normalized child")
  let parent = parentDir(lexical)
  let canonicalParent =
    try: expandFilename(parent)
    except OSError: return (false, "scratch parent cannot be canonicalized")
  let canonicalTemp =
    try: expandFilename(os.normalizedPath(getTempDir()))
    except OSError: return (false, "temp root cannot be canonicalized")
  if canonicalParent != canonicalTemp:
    return (false, "scratch parent is outside the canonical temp root")
  let base = lexical.extractFilename()
  if not base.startsWith(Prefix):
    return (false, "scratch basename has the wrong prefix")
  let suffix =
    if base.len > Prefix.len: base[Prefix.len .. ^1]
    else: ""
  if suffix.len < 8 or
      suffix.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
    return (false, "scratch basename lacks a sufficiently unique suffix")
  when defined(posix):
    var info: Stat
    if lstat(lexical.cstring, info) != 0 or not S_ISDIR(info.st_mode):
      return (false, "scratch final component is not a real directory")
  else:
    if symlinkExists(lexical) or not dirExists(lexical) or
        getFileInfo(lexical, followSymlink = false).kind != pcDir:
      return (false, "scratch final component is not a real directory")
  (true, "")

proc removeCapabilityScratch(path: string) =
  let validated = validateCapabilityScratchForCleanup(path)
  if not validated.ok:
    raise newException(ValueError,
      "refusing unsafe capability fixture cleanup: " & validated.diagnostic)
  when defined(posix):
    let cleaned = run("rm -rf -- " & q(path))
    if cleaned.code != 0 or dirExists(path) or symlinkExists(path):
      raise newException(OSError,
        "could not clean validated POSIX capability fixture: " &
          cleaned.output)
  else:
    removeDir(path)

proc capabilityPath(gitBin, repo, token: string): string =
  commonGitDir(gitBin, repo) / "reprobuild" / "hook-capabilities" /
    (token & ".pending")

proc mutateIssuedAt(path: string; issuedAtUnixMs: int64) =
  var node = parseFile(path)
  node["issuedAtUnixMs"] = %issuedAtUnixMs
  writeFile(path, $node & "\n")

proc mutateString(path, field, value: string) =
  var node = parseFile(path)
  node[field] = %value
  writeFile(path, $node & "\n")

proc mutateInt(path, field: string; value: int) =
  var node = parseFile(path)
  node[field] = %value
  writeFile(path, $node & "\n")

proc inheritedEnv(token: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): result[key] = value
  result[HookCapabilityEnv] = token
  result.del(LegacyHookSentinelEnv)
  result.del(HookDispatcherProtocolEnv)

# Helper mode for the real two-process claim race. The token remains in the
# child environment and is captured/scrubbed before the typed consumer call.
if paramCount() == 6:
  case paramStr(1)
  of "--consume-capability":
    let token = getEnv(HookCapabilityEnv)
    delEnv(HookCapabilityEnv)
    let consumed = consumeHookCapability(
      paramStr(2), paramStr(3), token, "origin", paramStr(4), paramStr(5))
    quit(if consumed.authorized: 0 else: 2)
  of "--consume-capability-list":
    let tokens = getEnv("REPROBUILD_TEST_CAPABILITIES").splitLines()
      .filterIt(it.len > 0)
    delEnv("REPROBUILD_TEST_CAPABILITIES")
    var authorized = 0
    var refused = 0
    for token in tokens:
      let consumed = consumeHookCapability(
        paramStr(2), paramStr(3), token, "origin", paramStr(4), paramStr(5))
      if consumed.authorized: inc authorized else: inc refused
    writeFile(paramStr(6), $(%*{"authorized": authorized,
      "refused": refused}) & "\n")
    quit 0
  of "--issue-and-wait":
    let head = require(q(paramStr(2)) & " -C " & q(paramStr(3)) &
      " rev-parse HEAD").strip()
    let issued = issueHookCapability(paramStr(2), paramStr(3), "origin",
      paramStr(4), "HEAD", head, "refs/heads/main", head)
    if not issued.ok: quit 3
    writeFile(paramStr(6), issued.token & "\n")
    sleep(60_000)
    quit 4
  of "--wrong-owner-helper":
    when defined(posix):
      let head = require(q(paramStr(2)) & " -C " & q(paramStr(3)) &
        " rev-parse HEAD").strip()
      let issued = issueHookCapability(paramStr(2), paramStr(3), "origin",
        paramStr(4), "HEAD", head, "refs/heads/main", head)
      if not issued.ok: quit 5
      let pending = capabilityPath(paramStr(2), paramStr(3), issued.token)
      if chown(pending.cstring, Uid(65534), Gid(-1)) != 0: quit 6
      let consumed = consumeHookCapability(paramStr(2), paramStr(3),
        issued.token, "origin", paramStr(4), paramStr(5))
      quit(if not consumed.authorized and
        "security checks" in consumed.diagnostic: 0 else: 7)
    else:
      quit 8
  else:
    discard

type Fixture = object
  scratch: string
  gitBin: string
  repo: string
  origin: string
  head: string
  refs: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-capability-security-", "")
  result.gitBin = gitBin
  result.repo = result.scratch / "repo"
  result.origin = result.scratch / "origin.git"
  result.refs = result.scratch / "refs"
  discard require(q(gitBin) & " init --bare -b main " & q(result.origin))
  discard require(q(gitBin) & " init -b main " & q(result.repo))
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " config user.name 'Capability Tester'")
  writeFile(result.repo / "README.md", "seed\n")
  discard require(q(gitBin) & " -C " & q(result.repo) & " add README.md")
  discard require(q(gitBin) & " -C " & q(result.repo) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " remote add origin " & q(result.origin))
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " push --no-verify -u origin main")
  result.head = require(q(gitBin) & " -C " & q(result.repo) &
    " rev-parse HEAD").strip()
  writeFile(result.refs, "HEAD " & result.head & " refs/heads/main " &
    result.head & "\n")

proc initializeSingleRepoWorkspace(fx: var Fixture) =
  let manifests = fx.scratch / ".repro" / "manifests"
  let manifestBare = fx.scratch / "manifests.git"
  createDir(manifests / "projects")
  createDir(manifests / "repos")
  writeFile(fx.scratch / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
  writeFile(manifests / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n[[remote]]\nname = \"origin\"\n" &
    "fetch = \"" & fx.origin.replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(manifests / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"repo\"\nremote = \"origin\"\n" &
    "revision = \"main\"\n")
  discard require(q(fx.gitBin) & " init --bare -b main " & q(manifestBare))
  discard require(q(fx.gitBin) & " init -b main " & q(manifests))
  discard require(q(fx.gitBin) & " -C " & q(manifests) &
    " config user.email tester@example.invalid")
  discard require(q(fx.gitBin) & " -C " & q(manifests) &
    " config user.name 'Capability Tester'")
  discard require(q(fx.gitBin) & " -C " & q(manifests) & " add projects repos")
  discard require(q(fx.gitBin) & " -C " & q(manifests) &
    " commit -m 'initialize workspace manifests'")
  discard require(q(fx.gitBin) & " -C " & q(manifests) &
    " remote add origin " & q(manifestBare))
  discard require(q(fx.gitBin) & " -C " & q(manifests) &
    " push -u origin main")

proc issue(fx: Fixture): CapabilityIssueResult =
  issueHookCapability(fx.gitBin, fx.repo, "origin", fx.origin,
    "HEAD", fx.head, "refs/heads/main", fx.head)

proc consume(fx: Fixture; token: string; remoteName = "origin";
    remoteLocation = ""; refsPath = ""): CapabilityConsumeResult =
  consumeHookCapability(fx.gitBin, fx.repo, token, remoteName,
    if remoteLocation.len > 0: remoteLocation else: fx.origin,
    if refsPath.len > 0: refsPath else: fx.refs)

proc sourceRoot(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  result = if configured.len > 0: configured
    else: sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  if not fileExists(result):
    checkpoint("required exact repro CLI is missing: " & result)
    quit 1

proc executable(path, content: string) =
  writeFile(path, content)
  var permissions = getFilePermissions(path)
  permissions.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, permissions)

proc installHooks(fx: Fixture; target = "") =
  let repro = reproBinary()
  let root = if target.len > 0: target else: fx.repo
  let installedRaw = runShell(shellCommand(@[repro, "hooks", "ensure",
    "--vcs", "--workspace-root=" & root, root],
    @[(name: "REPROBUILD_REPRO", value: repro)]))
  let installed = (code: installedRaw.code, output: installedRaw.output)
  if installed.code != 0:
    checkpoint("hook ensure failed:\n" & installed.output)
    quit 1

suite "nested lock-push capability security":
  test "exactly one of two processes claims and replay always fails":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("Git is required for the native capability security suite")
      check false
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let issued = issue(fx)
      check issued.ok
      let args = @["--consume-capability", gitBin, fx.repo, fx.origin,
        fx.refs, "reserved"]
      let p1 = startProcess(getAppFilename(), args = args,
        env = inheritedEnv(issued.token),
        options = {poStdErrToStdOut})
      let p2 = startProcess(getAppFilename(), args = args,
        env = inheritedEnv(issued.token),
        options = {poStdErrToStdOut})
      let c1 = p1.waitForExit()
      let c2 = p2.waitForExit()
      p1.close()
      p2.close()
      check (c1 == 0 and c2 == 2) or (c1 == 2 and c2 == 0)
      let replay = fx.consume(issued.token)
      check not replay.authorized
      check replay.claimLost

  test "managed-hook claim loser runs the ordinary published-state gate":
    let gitBin = findExe("git")
    let shBin = findExe("sh")
    if gitBin.len == 0 or shBin.len == 0:
      checkpoint("Git and its hook shell are required for the native " &
        "capability security suite")
      check false
    else:
      var fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      fx.initializeSingleRepoWorkspace()
      let repro = reproBinary()
      for target in [fx.scratch, fx.scratch / ".repro" / "manifests"]:
        fx.installHooks(target)
      # This matrix exercises only the pre-push claim boundary. Avoid an
      # unrelated post-commit cache-push daemon retaining the Windows hook
      # process pipe while the fixture creates its unpublished commit.
      for repoRoot in [fx.repo, fx.scratch / ".repro" / "manifests"]:
        for name in ["post-commit", "post-merge", "post-checkout"]:
          for suffix in ["", ".repro-managed", ".repro-local"]:
            let path = repoRoot / ".git" / "hooks" / (name & suffix)
            if fileExists(path): removeFile(path)
      let dispatcher = require(q(gitBin) & " -C " & q(fx.repo) &
        " rev-parse --path-format=absolute --git-path hooks/pre-push").strip()

      proc race(token, refsPath: string):
          tuple[first, second: int; firstOutput, secondOutput: string] =
        var childEnv = newStringTable(modeCaseSensitive)
        for key, value in envPairs(): childEnv[key] = value
        childEnv["REPROBUILD_REPRO"] = repro
        childEnv[HookCapabilityEnv] = token
        childEnv.del(LegacyHookSentinelEnv)
        childEnv.del(HookDispatcherProtocolEnv)
        let command = "exec " & q(dispatcher) & " origin " & q(fx.origin) &
          " < " & q(refsPath)
        let p1 = startProcess(shBin, workingDir = fx.repo,
          args = @["-c", command], env = childEnv,
          options = {poStdErrToStdOut})
        let p2 = startProcess(shBin, workingDir = fx.repo,
          args = @["-c", command], env = childEnv,
          options = {poStdErrToStdOut})
        result.firstOutput = p1.outputStream.readAll()
        result.secondOutput = p2.outputStream.readAll()
        result.first = p1.waitForExit()
        result.second = p2.waitForExit()
        p1.close()
        p2.close()

      # One hook consumes the exemption. Its loser sees an already-published
      # HEAD and independently passes the ordinary policy gate.
      var issued = issue(fx)
      check issued.ok
      let published = race(issued.token, fx.refs)
      if published.first != 0 or published.second != 0:
        checkpoint("published claim race output:\nfirst=" &
          published.firstOutput & "\nsecond=" & published.secondOutput)
      check published.first == 0
      check published.second == 0

      # For an unpublished HEAD the winner remains exempt, but the loser must
      # run the normal gate and refuse. A claim race can never become a second
      # authorization.
      writeFile(fx.repo / "README.md", "unpublished race\n")
      discard require(q(gitBin) & " -C " & q(fx.repo) & " add README.md")
      discard require(q(gitBin) & " -C " & q(fx.repo) &
        " commit -m 'unpublished claim race'")
      let unpublishedHead = require(q(gitBin) & " -C " & q(fx.repo) &
        " rev-parse HEAD").strip()
      let unpublishedRefs = fx.scratch / "unpublished-refs"
      writeFile(unpublishedRefs, "HEAD " & unpublishedHead &
        " refs/tags/not-source " & repeat('0', fx.head.len) & "\n")
      issued = issueHookCapability(gitBin, fx.repo, "origin", fx.origin,
        "HEAD", unpublishedHead, "refs/tags/not-source",
        repeat('0', fx.head.len))
      check issued.ok
      let unpublished = race(issued.token, unpublishedRefs)
      if unpublished.first == unpublished.second:
        checkpoint("unpublished claim race output:\nfirst=" &
          unpublished.firstOutput & "\nsecond=" & unpublished.secondOutput)
      check (unpublished.first == 0 and unpublished.second != 0) or
        (unpublished.first != 0 and unpublished.second == 0)

  test "expiry future skew and every typed binding fail closed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("Git is required for the native capability security suite")
      check false
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      var issued = issue(fx)
      check issued.ok
      mutateIssuedAt(capabilityPath(gitBin, fx.repo, issued.token),
        int64(getTime().toUnixFloat() * 1000.0) -
          CapabilityTtlMilliseconds - 1000)
      check not fx.consume(issued.token).authorized

      issued = issue(fx)
      check issued.ok
      mutateIssuedAt(capabilityPath(gitBin, fx.repo, issued.token),
        int64(getTime().toUnixFloat() * 1000.0) +
          CapabilityFutureSkewMilliseconds + 1000)
      check not fx.consume(issued.token).authorized

      issued = issue(fx)
      check issued.ok
      check not fx.consume(issued.token, remoteName = "wrong").authorized

      issued = issue(fx)
      check issued.ok
      check not fx.consume(issued.token,
        remoteLocation = fx.scratch / "different.git").authorized

      issued = issue(fx)
      check issued.ok
      let wrongRefs = fx.scratch / "wrong-refs"
      writeFile(wrongRefs, "refs/heads/main " & fx.head &
        " refs/heads/other " & fx.head & "\n")
      check not fx.consume(issued.token, refsPath = wrongRefs).authorized

      for binding in [
          ("schema", "reprobuild.hook-capability.wrong"),
          ("purpose", "ordinary-user-push"),
          ("worktree", fx.scratch / "different-worktree"),
          ("commonDir", fx.scratch / "different-common-dir"),
          ("userIdentity", "different-user-identity"),
          ("objectFormat", "sha256"),
          ("headOid", repeat('f', fx.head.len))]:
        issued = issue(fx)
        check issued.ok
        let pending = capabilityPath(gitBin, fx.repo, issued.token)
        mutateString(pending, binding[0], binding[1])
        let rejected = fx.consume(issued.token)
        check not rejected.authorized
        check issued.token notin rejected.diagnostic
        check fx.origin notin rejected.diagnostic

      issued = issue(fx)
      check issued.ok
      mutateInt(capabilityPath(gitBin, fx.repo, issued.token), "protocol", 99)
      check not fx.consume(issued.token).authorized

      # A copied valid record cannot be transplanted under a second token.
      let original = issue(fx)
      let transplant = issue(fx)
      check original.ok and transplant.ok
      let transplantPath = capabilityPath(gitBin, fx.repo, transplant.token)
      removeFile(transplantPath)
      copyFile(capabilityPath(gitBin, fx.repo, original.token), transplantPath)
      setFilePermissions(transplantPath, {fpUserRead, fpUserWrite})
      check not fx.consume(transplant.token).authorized
      check fx.consume(original.token).authorized

      # Linked worktrees share the common Git directory, so the pending record
      # is visible there; canonical worktree binding must still reject replay.
      let linked = fx.scratch / "linked-worktree"
      discard require(q(gitBin) & " -C " & q(fx.repo) &
        " worktree add --detach " & q(linked) & " HEAD")
      issued = issue(fx)
      check issued.ok
      let linkedConsumed = consumeHookCapability(gitBin, linked, issued.token,
        "origin", fx.origin, fx.refs)
      check not linkedConsumed.authorized

      # An unrelated repository cannot claim the token from a different common
      # directory, even when it contains the same commit.
      let otherRepo = fx.scratch / "other-repo"
      discard require(q(gitBin) & " clone " & q(fx.origin) & " " & q(otherRepo))
      issued = issue(fx)
      check issued.ok
      let otherConsumed = consumeHookCapability(gitBin, otherRepo,
        issued.token, "origin", fx.origin, fx.refs)
      check not otherConsumed.authorized
      discardHookCapability(gitBin, fx.repo, issued.token)

      issued = issue(fx)
      check issued.ok
      writeFile(fx.repo / "README.md", "new head\n")
      discard require(q(gitBin) & " -C " & q(fx.repo) & " add README.md")
      discard require(q(gitBin) & " -C " & q(fx.repo) & " commit -m changed")
      check not fx.consume(issued.token).authorized

  test "native metadata substitution attacks are refused":
    when defined(posix):
      let gitBin = findExe("git")
      if gitBin.len == 0:
        checkpoint("Git is required for the native POSIX capability suite")
        check false
      else:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)

        var issued = issue(fx)
        check issued.ok
        let pending = capabilityPath(gitBin, fx.repo, issued.token)
        let copy = fx.scratch / "record-copy"
        copyFile(pending, copy)
        removeFile(pending)
        createSymlink(copy, pending)
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let hardlinked = capabilityPath(gitBin, fx.repo, issued.token)
        createHardlink(hardlinked, fx.scratch / "record-hardlink")
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let permissive = capabilityPath(gitBin, fx.repo, issued.token)
        setFilePermissions(permissive,
          {fpUserRead, fpUserWrite, fpGroupRead})
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let permissiveDir = capabilityPath(gitBin, fx.repo,
          issued.token).parentDir()
        setFilePermissions(permissiveDir,
          {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec})
        check not fx.consume(issued.token).authorized
        # Restore only so fixture cleanup and explicit pending cleanup can run;
        # authorization above must not have repaired the insecure directory.
        check fpGroupRead in getFilePermissions(permissiveDir)
        setFilePermissions(permissiveDir,
          {fpUserRead, fpUserWrite, fpUserExec})
        discardHookCapability(gitBin, fx.repo, issued.token)

        issued = issue(fx)
        check issued.ok
        let componentRecord = capabilityPath(gitBin, fx.repo, issued.token)
        let reproPrivate = componentRecord.parentDir().parentDir()
        let savedPrivate = fx.scratch / "saved-reprobuild-private"
        moveDir(reproPrivate, savedPrivate)
        createSymlink(savedPrivate, reproPrivate)
        check not fx.consume(issued.token).authorized
    elif defined(windows):
      let gitBin = findExe("git")
      if gitBin.len == 0:
        checkpoint("Git is required for the native Windows capability suite")
        check false
      else:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)

        var issued = issue(fx)
        check issued.ok
        let pending = capabilityPath(gitBin, fx.repo, issued.token)
        discard requireNative(["icacls", pending, "/inheritance:e"])
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let wrongOwner = capabilityPath(gitBin, fx.repo, issued.token)
        discard requireNative(
          ["icacls", wrongOwner, "/setowner", "*S-1-5-18"])
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let hardlinked = capabilityPath(gitBin, fx.repo, issued.token)
        createHardlink(hardlinked, fx.scratch / "record-hardlink")
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let withStream = capabilityPath(gitBin, fx.repo, issued.token)
        writeFile(withStream & ":unexpected", "alternate stream\n")
        check not fx.consume(issued.token).authorized

        issued = issue(fx)
        check issued.ok
        let reparse = capabilityPath(gitBin, fx.repo, issued.token)
        let copy = fx.scratch / "record-copy"
        copyFile(reparse, copy)
        removeFile(reparse)
        createSymlink(copy, reparse)
        check not fx.consume(issued.token).authorized


        issued = issue(fx)
        check issued.ok
        let junctionPending = capabilityPath(gitBin, fx.repo, issued.token)
        let reproPrivate = junctionPending.parentDir().parentDir()
        let savedPrivate = fx.scratch / "saved-windows-private"
        moveDir(reproPrivate, savedPrivate)
        discard requireNative(
          ["cmd", "/d", "/c", "mklink", "/J", reproPrivate, savedPrivate])
        check not fx.consume(issued.token).authorized
        discard requireNative(["cmd", "/d", "/c", "rmdir", reproPrivate])
        moveDir(savedPrivate, reproPrivate)
        discardHookCapability(gitBin, fx.repo, issued.token)
    else:
      check true

  test "native POSIX ownership mismatch is refused":
    when defined(posix):
      let gitBin = findExe("git")
      if gitBin.len == 0:
        checkpoint("Git is required for the native POSIX ownership test")
        check false
      else:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        let helperArgs = " " & q(getAppFilename()) &
          " --wrong-owner-helper " & q(gitBin) & " " & q(fx.repo) & " " &
          q(fx.origin) & " " & q(fx.refs) & " reserved"
        var ownerResult: tuple[code: int; output: string]
        if geteuid() == 0:
          ownerResult = run(helperArgs.strip())
        elif defined(linux):
          let unshare = findExe("unshare")
          let mapAutoProbe = if unshare.len > 0:
            run(q(unshare) & " --user --map-root-user --map-auto true")
          else:
            (code: 127, output: "unshare is unavailable")
          if mapAutoProbe.code != 0:
            checkpoint("native wrong-owner test requires root or unshare " &
              "with an enabled Linux user namespace, --map-auto support, " &
              "and configured subordinate UID/GID mappings:\n" &
              mapAutoProbe.output)
            check false
          else:
            ownerResult = run(q(unshare) &
              " --user --map-root-user --map-auto" & helperArgs)
        elif defined(macosx):
          # macOS permits a hard link to a root-owned regular file when both
          # paths are on the Data volume. Use only harmless, public system
          # metadata; never read or modify its contents. The disposable link
          # gives the real verifier a native uid mismatch without sudo or a
          # mocked lstat. It is removed by the failed consume, while the source
          # inode and link count must return byte-for-byte to their prior
          # metadata.
          var source = ""
          for candidate in ["/private/etc/hosts", "/private/etc/shells"]:
            if fileExists(candidate):
              source = candidate
              break
          check source.len > 0
          if source.len > 0:
            var before, linked, after: Stat
            check stat(source.cstring, before) == 0
            check before.st_uid == Uid(0)
            check before.st_uid != geteuid()
            let issued = issue(fx)
            check issued.ok
            if issued.ok:
              let pending = capabilityPath(gitBin, fx.repo, issued.token)
              removeFile(pending)
              var linkedOk = true
              try:
                createHardlink(source, pending)
              except OSError as err:
                linkedOk = false
                checkpoint("native macOS wrong-owner hardlink failed: " &
                  err.msg)
              check linkedOk
              if linkedOk:
                check lstat(pending.cstring, linked) == 0
                check linked.st_ino == before.st_ino
                check linked.st_uid == before.st_uid
                check linked.st_uid != geteuid()
                let refused = fx.consume(issued.token)
                check not refused.authorized
                check "security checks" in refused.diagnostic
                if fileExists(pending): removeFile(pending)
                check stat(source.cstring, after) == 0
                check after.st_ino == before.st_ino
                check after.st_uid == before.st_uid
                check after.st_nlink == before.st_nlink
          ownerResult = (code: 0, output: "")
        else:
          checkpoint("native wrong-owner test requires root on this POSIX OS")
          check false
        if ownerResult.code != 0: checkpoint(ownerResult.output)
        check ownerResult.code == 0
    else:
      check true

  test "parent normal and POSIX signal cleanup remove unclaimed pending files":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("Git is required for the native capability cleanup suite")
      check false
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let normal = issue(fx)
      check normal.ok
      let normalPath = capabilityPath(gitBin, fx.repo, normal.token)
      check fileExists(normalPath)
      discardHookCapability(gitBin, fx.repo, normal.token)
      check not fileExists(normalPath)
      # Idempotent error/finally cleanup cannot remove unrelated state.
      discardHookCapability(gitBin, fx.repo, normal.token)

      when defined(posix):
        let marker = fx.scratch / "signal-issued"
        let args = @["--issue-and-wait", gitBin, fx.repo, fx.origin,
          fx.refs, marker]
        let child = startProcess(getAppFilename(), args = args,
          options = {poStdErrToStdOut})
        var ready = false
        for _ in 0 ..< 500:
          if fileExists(marker):
            ready = true
            break
          sleep(10)
        check ready
        if ready:
          let token = readFile(marker).strip()
          let pending = capabilityPath(gitBin, fx.repo, token)
          check fileExists(pending)
          child.terminate()
          let exitCode = child.waitForExit()
          check exitCode != 4
          child.close()
          var removed = false
          for _ in 0 ..< 100:
            if not fileExists(pending):
              removed = true
              break
            sleep(10)
          check removed
        else:
          child.terminate()
          discard child.waitForExit()
          child.close()

  test "adversarial cleanup validator rejects every unsafe root shape":
    when defined(posix):
      let empty = validateCapabilityScratchForCleanup("")
      check not empty.ok
      let tempRoot = validateCapabilityScratchForCleanup(
        os.normalizedPath(getTempDir()))
      check not tempRoot.ok

      let outsideParent = createTempDir(
        "repro-capability-validator-parent-", "")
      defer:
        if dirExists(outsideParent): removeDir(outsideParent)
      let outside = outsideParent /
        "repro-capability-security-12345678"
      createDir(outside)
      check not validateCapabilityScratchForCleanup(outside).ok

      let symlinkTarget = createTempDir(
        "repro-capability-validator-target-", "")
      defer:
        if dirExists(symlinkTarget): removeDir(symlinkTarget)
      let symlinkPath = getTempDir() /
        "repro-capability-security-symlink12345678"
      if symlinkExists(symlinkPath): removeFile(symlinkPath)
      createSymlink(symlinkTarget, symlinkPath)
      defer:
        if symlinkExists(symlinkPath): removeFile(symlinkPath)
      check not validateCapabilityScratchForCleanup(symlinkPath).ok

      let wrongPrefix = createTempDir("wrong-capability-prefix-", "")
      defer:
        if dirExists(wrongPrefix): removeDir(wrongPrefix)
      check not validateCapabilityScratchForCleanup(wrongPrefix).ok

      let valid = createTempDir("repro-capability-security-", "")
      check validateCapabilityScratchForCleanup(valid).ok
      check not validateCapabilityScratchForCleanup(
        valid & $DirSep & ".").ok
      removeCapabilityScratch(valid)
      check not dirExists(valid)
    else:
      check true

  test "concurrent POSIX directory component swaps never authorize through a link":
    when defined(posix):
      let gitBin = findExe("git")
      if gitBin.len == 0:
        checkpoint("Git is required for the native POSIX capability race")
        check false
      else:
        let fx = setupFixture(gitBin)
        defer:
          # Nim's recursive removeDir descends through the symlink-shaped
          # component this adversarial fixture creates. The validated POSIX
          # fallback never follows that component and cannot be redirected to
          # the temp root or an attacker-selected path.
          removeCapabilityScratch(fx.scratch)
        var tokens: seq[string]
        for _ in 0 ..< 64:
          let issued = issue(fx)
          check issued.ok
          tokens.add(issued.token)
        let pending = capabilityPath(gitBin, fx.repo, tokens[0])
        let privateRoot = pending.parentDir().parentDir()
        let saved = fx.scratch / "component-held"
        let marker = fx.scratch / "component-swap-active"
        let markerTmp = fx.scratch / "component-swap-active.tmp"
        let acknowledged = fx.scratch / "component-swap-ack"
        let attackerScript = fx.scratch / "swap-components.sh"
        executable(attackerScript,
          "#!/usr/bin/env sh\nset -eu\ni=1\n" &
          "while [ \"$i\" -le " & $tokens.len & " ]; do\n" &
          "  mv " & q(privateRoot) & " " & q(saved) & "\n" &
          "  ln -s " & q(saved) & " " & q(privateRoot) & "\n" &
          "  printf '%s\\n' \"$i\" > " & q(markerTmp) & "\n" &
          "  mv " & q(markerTmp) & " " & q(marker) & "\n" &
          "  while [ ! -f " & q(acknowledged) &
            " ] || [ \"$(cat " & q(acknowledged) &
            " 2>/dev/null || true)\" != \"$i\" ]; do sleep 0.001; done\n" &
          "  rm -f " & q(marker) & " " & q(privateRoot) & "\n" &
          "  mv " & q(saved) & " " & q(privateRoot) & "\n" &
          "  i=$((i + 1))\n" &
          "done\n" &
          "test -d " & q(privateRoot) & "\n")
        let attacker = startProcess(attackerScript,
          options = {poStdErrToStdOut})
        defer:
          # Preserve the first assertion failure instead of letting the
          # adversary race the outer scratch cleanup and mask it.
          if attacker.running():
            attacker.terminate()
            discard attacker.waitForExit()
          attacker.close()
        var decisionsWhileActive = 0
        var authorizationsWhileActive = 0
        for index, token in tokens:
          let expected = $(index + 1)
          var active = false
          for _ in 0 ..< 5000:
            if fileExists(marker):
              try:
                if readFile(marker).strip() == expected:
                  active = true
                  break
              except IOError, OSError:
                # The attacker removes/replaces this marker between polls.
                # A failed read only means this sample missed that interval.
                discard
            sleep(1)
          check active
          check symlinkExists(privateRoot)
          if active and symlinkExists(privateRoot):
            let consumed = fx.consume(token)
            inc decisionsWhileActive
            if consumed.authorized: inc authorizationsWhileActive
            check not consumed.authorized
            check consumed.diagnostic ==
              "hook capability directory failed handle/ownership/mode checks"
            # The attacker cannot end the active interval until this exact
            # decision has completed and the acknowledgement is written.
            check symlinkExists(privateRoot)
          writeFile(acknowledged, expected & "\n")
        check attacker.waitForExit() == 0
        check dirExists(privateRoot)
        check not symlinkExists(privateRoot)
        check decisionsWhileActive == tokens.len
        check authorizationsWhileActive == 0
        for token in tokens:
          discardHookCapability(gitBin, fx.repo, token)
    else:
      check true

  test "real nested backend push scrubs preserved user-hook environment":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("Git is required for the real nested capability push")
      check false
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      writeFile(fx.repo / "README.md", "nested outgoing head\n")
      discard require(q(gitBin) & " -C " & q(fx.repo) & " add README.md")
      discard require(q(gitBin) & " -C " & q(fx.repo) &
        " commit -m 'nested outgoing head'")
      let outgoing = require(q(gitBin) & " -C " & q(fx.repo) &
        " rev-parse HEAD").strip()
      let userLog = fx.scratch / "user-hook.log"
      executable(fx.repo / ".git" / "hooks" / "pre-push",
        "#!/usr/bin/env sh\n" &
        "printf 'cap=%s legacy=%s dispatcher=%s\\n' " &
        "\"${" & HookCapabilityEnv & ":-}\" \"${" &
          LegacyHookSentinelEnv & ":-}\" \"${" &
          HookDispatcherProtocolEnv & ":-}\" >> " & q(userLog) &
          "\ncat >/dev/null\n")
      installHooks(fx)
      let repro = reproBinary()
      let issued = issueHookCapability(gitBin, fx.repo, "origin", fx.origin,
        "HEAD", outgoing, "refs/heads/main", fx.head)
      check issued.ok
      let pushedRaw = runShell(shellCommand(@[gitBin, "-C", fx.repo,
        "push", "origin", "HEAD:main"], @[
        (name: "REPROBUILD_REPRO", value: repro),
        (name: HookCapabilityEnv, value: issued.token),
        (name: LegacyHookSentinelEnv, value: "1")]))
      let pushed = (code: pushedRaw.code, output: pushedRaw.output)
      if pushed.code != 0: checkpoint(pushed.output)
      check pushed.code == 0
      check readFile(userLog).splitLines().allIt(
        it.len == 0 or it == "cap= legacy= dispatcher=")
      check issued.token notin pushed.output
      let capDir = commonGitDir(gitBin, fx.repo) / "reprobuild" /
        "hook-capabilities"
      if dirExists(capDir): check toSeq(walkDir(capDir)).len == 0

  test "cleanup removes only expired well-formed capability names":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("Git is required for the capability expiry cleanup suite")
      check false
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let issued = issue(fx)
      check issued.ok
      let pending = capabilityPath(gitBin, fx.repo, issued.token)
      let dir = pending.parentDir()
      let unrelated = dir / "operator-owned.txt"
      writeFile(unrelated, "keep\n")
      let claimedIssued = issue(fx)
      check claimedIssued.ok
      let claimedPending = capabilityPath(gitBin, fx.repo,
        claimedIssued.token)
      let claimed = dir / (claimedIssued.token & ".12345.claimed")
      moveFile(claimedPending, claimed)
      setLastModificationTime(claimed,
        fromUnix(getTime().toUnix() - CapabilityTtlSeconds - 1))
      let malformed = @[
        dir / (repeat('c', 64) & ".worker.claimed"),
        dir / (repeat('d', 64) & ".-1.claimed"),
        dir / (repeat('e', 64) & ".123.claimed.backup"),
        dir / ("x" & repeat('f', 64) & ".pending")]
      for path in malformed:
        writeFile(path, "operator data\n")
        setLastModificationTime(path,
          fromUnix(getTime().toUnix() - CapabilityTtlSeconds - 1))
      setLastModificationTime(pending,
        fromUnix(getTime().toUnix() - CapabilityTtlSeconds - 1))
      cleanupExpiredCapabilities(gitBin, fx.repo)
      check not fileExists(pending)
      check not fileExists(claimed)
      check fileExists(unrelated)
      for path in malformed: check fileExists(path)

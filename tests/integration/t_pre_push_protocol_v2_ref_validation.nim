## Pre-push publication protocol v2 — strict refs and provisional HEAD.
##
## This is a real-Git integration boundary, not a mocked gate.  A workspace
## repo and two bare remotes are created for each supported object format, the
## canonical hooks are installed by the built ``repro`` binary, and ordinary
## ``git push`` drives the generated dispatcher and managed body.  It proves:
##
## * one unpublished, clean current HEAD can be pushed to its manifest-agreed
##   remote, while the same HEAD is refused on a wrong remote;
## * batch, tag-only, deletion-batch, and non-fast-forward pushes cannot borrow
##   the provisional outgoing-current classification;
## * direct-URL and stale-branch pushes cannot impersonate the agreed outgoing
##   HEAD, while missing and non-commit remote-old objects fail closed;
## * once HEAD is genuinely published, valid tag/deletion/certificate-note
##   updates plus force and batch pushes retain the pre-existing allow policy;
## * only a proven readable byte-empty (zero-update) refs stream is a no-op;
##   omitted, nonexistent, unreadable, blank, and malformed streams fail closed;
## * the preserved user hook receives Git's exact two arguments and byte-exact
##   refs stream, but sees neither the legacy sentinel nor either internal v2
##   capability/dispatcher variable;
## * malformed blank/repeated-space/tab/control/field-count/OID-width records
##   fail closed, including when current HEAD is already published.
##
## Only malformed byte streams and impossible-to-advertise remote-old object
## types call the installed hook directly. Real receive-pack refuses to
## advertise a missing/non-commit branch tip, so real object-store identities
## plus the installed dispatcher are the only falsifiable boundary for those
## two semantic checks. Every other semantic ref case is produced by an actual
## ``git push`` against a local bare remote.
## SHA-256 is skipped only when the installed Git cannot initialize that object
## format. The same process boundary runs on every supported OS with Git; POSIX
## metadata security belongs to the dedicated capability suite. The semantic
## assertions are falsifiable by accepting any listed ineligible update or by
## changing one byte of malformed framing. There are no network dependencies.

import std/[os, strutils, tempfiles, unittest]

when not defined(windows):
    import std/osproc

import repro_cli_support/push_hook_protocol
import repro_test_support

type EnvSnapshot = object
    existed: bool
    value: string

proc overrideEnv(name, value: string): EnvSnapshot =
    result = EnvSnapshot(existed: existsEnv(name), value: getEnv(name))
    putEnv(name, value)

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
    if snapshot.existed:
        putEnv(name, snapshot.value)
    else:
        delEnv(name)

proc q(value: string): string =
    when defined(windows):
        # Command strings are evaluated by Git-for-Windows sh (see run below).
        # Quote even space-free drive paths so backslashes remain literal.
        "'" & value.replace("'", "'\"'\"'") & "'"
    else:
        quoteShell(value)

proc run(command: string; cwd = ""):
    tuple[code: int; output: string] =
    when defined(windows):
        let shell = findExe("sh")
        if shell.len == 0:
            return (127, "Git hook shell is unavailable")
        let res = runShell(shellCommand(@[shell, "-c", command]),
          if cwd.len > 0: cwd else: getCurrentDir())
        (res.code, res.output)
    else:
        let res = execCmdEx(command, workingDir = cwd,
          options = {poStdErrToStdOut, poUsePath})
        (res.exitCode, res.output)

proc require(command: string; cwd = ""): string =
    let res = run(command, cwd)
    if res.code != 0:
        checkpoint("command failed: " & command & "\nexit=" & $res.code &
          "\n" & res.output)
        quit 1
    res.output

proc sourceRoot(): string =
    currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
    let configured = getEnv("REPROBUILD_REPRO")
    let candidate =
        if configured.len > 0: configured
      else: sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
    requireBinary(candidate, "reprobuild.apps.repro")

proc gitSupportsFormat(gitBin, objectFormat: string): bool =
    let scratch = createTempDir("repro-git-format-probe-", "")
    defer: removeDir(scratch)
    run(q(gitBin) & " init --object-format=" & objectFormat & " " & q(scratch))
        .code == 0

type Fixture = object
    scratch: string
    workspace: string
    repo: string
    origin: string
    wrong: string
    capture: string
    gitBin: string
    reproBin: string
    oidLength: int

proc git(fx: Fixture; args: openArray[string]; required = true):
    tuple[code: int; output: string] =
    var argv = @[fx.gitBin, "-C", fx.repo]
    argv.add(args)
    let commandResult = runShell(shellCommand(argv))
    result = (commandResult.code, commandResult.output)
    if required and result.code != 0:
        checkpoint("git failed: " & argv.join(" ") & "\n" & result.output)
        quit 1

proc head(fx: Fixture): string =
    fx.git(["rev-parse", "HEAD"]).output.strip()

proc writeWorkspaceManifest(fx: Fixture) =
    let manifests = fx.workspace / ".repro" / "manifests"
    createDir(manifests / "projects")
    createDir(manifests / "repos")
    writeFile(fx.workspace / ".repro" / "workspace.toml",
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
    writeFile(manifests / "projects" / "app.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
      "trunk = \"main\"\n\n" &
      "[[remote]]\nname = \"origin\"\nfetch = \"" &
        fx.origin.replace('\\', '/') & "\"\n\n" &
      "includes = [\"repos/app.toml\"]\n")
    writeFile(manifests / "repos" / "app.toml",
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"app\"\npath = \"app\"\n" &
      "remote = \"origin\"\nrevision = \"main\"\n")

proc installPreservedHook(fx: Fixture) =
    let hooks = fx.repo / ".git" / "hooks"
    createDir(hooks)
    let hook = hooks / "pre-push"
    writeFile(hook,
      "#!/usr/bin/env sh\n" &
      "set -eu\n" &
      "{\n" &
      "  if [ \"$1\" = origin ]; then printf '%s\\n' arg1-exact; " &
        "else printf '%s\\n' arg1-other; fi\n" &
      "  if [ \"$2\" = " & q(fx.origin) &
        " ]; then printf '%s\\n' arg2-exact; " &
        "else printf '%s\\n' arg2-other; fi\n" &
      "  printf 'cap=%s\\n' \"${REPROBUILD_INTERNAL_HOOK_CAPABILITY:-}\"\n" &
      "  printf 'dispatcher=%s\\n' \"${REPROBUILD_HOOK_DISPATCH_PROTOCOL:-}\"\n" &
      "  printf 'legacy=%s\\n' \"${REPROBUILD_HOOK_ACTIVE:-}\"\n" &
      "  printf '%s\\n' refs-begin\n" &
      "  cat\n" &
      "  printf '%s\\n' refs-end\n" &
      "} >> " & q(fx.capture) & "\n")
    var perms = getFilePermissions(hook)
    perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
    setFilePermissions(hook, perms)

proc setupFixture(gitBin, objectFormat: string): Fixture =
    result.scratch = createTempDir("repro-pre-push-v2-" & objectFormat & "-", "")
    result.workspace = result.scratch / "workspace"
    result.repo = result.workspace / "app"
    result.origin = result.scratch / "origin.git"
    result.wrong = result.scratch / "wrong.git"
    result.capture = result.scratch / "user-hook.log"
    result.gitBin = gitBin
    result.reproBin = reproBinary()
    if objectFormat == "sha256":
        result.oidLength = 64
    else:
        result.oidLength = 40
    createDir(result.workspace)
    discard require(q(gitBin) & " init --bare --object-format=" & objectFormat &
      " -b main " & q(result.origin))
    discard require(q(gitBin) & " init --bare --object-format=" & objectFormat &
      " -b main " & q(result.wrong))
    discard require(q(gitBin) & " init --object-format=" & objectFormat &
      " -b main " & q(result.repo))
    discard result.git(["config", "user.email", "tester@example.invalid"])
    discard result.git(["config", "user.name", "Protocol V2 Tester"])
    discard result.git(["remote", "add", "origin", result.origin])
    discard result.git(["remote", "add", "wrong", result.wrong])
    writeFile(result.repo / "README.md", "seed\n")
    discard result.git(["add", "README.md"])
    discard result.git(["commit", "-m", "seed"])
    discard result.git(["push", "--no-verify", "-u", "origin", "main"])
    result.writeWorkspaceManifest()
    result.installPreservedHook()
    let ensured = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
      "--vcs", "--workspace-root=" & result.workspace, result.workspace]))
    if ensured.code != 0:
        checkpoint("hook ensure failed:\n" & ensured.output)
        quit 1
    # Post-commit refresh is orthogonal here and would add noise while this suite
    # manufactures histories. Keep only the pre-push pair under test.
    for name in ["post-commit", "post-merge", "post-checkout"]:
        for suffix in ["", ".repro-managed", ".repro-local"]:
            let path = result.repo / ".git" / "hooks" / (name & suffix)
            if fileExists(path): removeFile(path)

proc commit(fx: Fixture; label: string) =
    writeFile(fx.repo / "README.md", label & "\n")
    discard fx.git(["add", "README.md"])
    discard fx.git(["commit", "-m", label])

proc assertRefused(res: tuple[code: int; output: string]; needle: string) =
    if res.code == 0:
        checkpoint("push unexpectedly passed:\n" & res.output)
    check res.code != 0
    check needle in res.output

proc exerciseManifestRemoteAlias(gitBin: string) =
    ## Reproduce the production naming mismatch exactly: the manifest calls the
    ## repository remote ``origin``, while the checkout has only the local
    ## alias ``metacraft-labs``. All destinations remain real bare Git repos.
    var fx = setupFixture(gitBin, "sha1")
    defer: removeDir(fx.scratch)
    let priorRepro = overrideEnv("REPROBUILD_REPRO", fx.reproBin)
    let priorSystem = overrideEnv("REPROBUILD_SYSTEM_CONFIG",
      fx.scratch / "no-system.toml")
    let priorUser = overrideEnv("REPROBUILD_USER_CONFIG",
      fx.scratch / "no-user.toml")
    let priorVcsPrivate = overrideEnv("REPROBUILD_VCS_PRIVATE_CONFIG",
      fx.scratch / "no-vcs-private.toml")
    defer:
        restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", priorVcsPrivate)
        restoreEnv("REPROBUILD_USER_CONFIG", priorUser)
        restoreEnv("REPROBUILD_SYSTEM_CONFIG", priorSystem)
        restoreEnv("REPROBUILD_REPRO", priorRepro)

    discard fx.git(["remote", "rename", "origin", "metacraft-labs"])
    discard fx.git(["remote", "remove", "wrong"])
    check fx.git(["remote"]).output.strip() == "metacraft-labs"

    fx.commit("manifest-remote-alias")
    let oldHead = require(q(gitBin) & " --git-dir=" & q(fx.origin) &
      " rev-parse refs/heads/main").strip()
    let refs = fx.scratch / "alias-refs"
    writeFile(refs, "refs/heads/main " & fx.head() &
      " refs/heads/main " & oldHead & "\n")

    # Protocol helper: the different alias is eligible only because Git's hook
    # location matches both its configured push URL and the manifest resolver's
    # full repository URL.
    let exactAlias = evaluateOutgoingCurrent(gitBin, fx.repo, refs,
      "metacraft-labs", fx.origin, "origin", fx.origin)
    check exactAlias.protocolOk
    check exactAlias.outgoingCurrent

    # Repository-location agreement cannot substitute for a missing symbolic
    # remote declaration in the manifest.
    let missingAgreedName = evaluateOutgoingCurrent(gitBin, fx.repo, refs,
      "metacraft-labs", fx.origin, "", fx.origin)
    check missingAgreedName.protocolOk
    check not missingAgreedName.outgoingCurrent
    check missingAgreedName.diagnostic ==
      "push target is not the manifest-agreed remote"

    # A different repository bound as both fetch and push destination rejects.
    discard fx.git(["remote", "set-url", "metacraft-labs", fx.wrong])
    let differentRepo = evaluateOutgoingCurrent(gitBin, fx.repo, refs,
      "metacraft-labs", fx.wrong, "origin", fx.origin)
    check differentRepo.protocolOk
    check not differentRepo.outgoingCurrent
    check differentRepo.diagnostic == "push target is not the manifest-agreed remote"

    # Matching fetch identity is insufficient when this alias's pushURL points
    # elsewhere: the actual hook destination is the pushURL.
    discard fx.git(["remote", "set-url", "metacraft-labs", fx.origin])
    discard fx.git(["remote", "set-url", "--push", "metacraft-labs",
      fx.wrong])
    let splitDestination = evaluateOutgoingCurrent(gitBin, fx.repo, refs,
      "metacraft-labs", fx.wrong, "origin", fx.origin)
    check splitDestination.protocolOk
    check not splitDestination.outgoingCurrent
    check splitDestination.diagnostic ==
      "push target is not the manifest-agreed remote"

    # Scheme is part of repository identity. A lexical file URL is not treated
    # as equal to the manifest's local-path spelling.
    let fileUrl = "file://" & fx.origin.replace('\\', '/')
    discard fx.git(["remote", "set-url", "--push", "metacraft-labs",
      fileUrl])
    let schemeChanged = evaluateOutgoingCurrent(gitBin, fx.repo, refs,
      "metacraft-labs", fileUrl, "origin", fx.origin)
    check schemeChanged.protocolOk
    check not schemeChanged.outgoingCurrent

    # Credential-bearing aliases compare through the existing credential-free
    # normalized identity. Neither a successful comparison nor a rejected
    # installed-hook dispatch may disclose credential material.
    let cleanUrl = "https://example.invalid/metacraft-labs/nixos-modules"
    let secretUrl = "https://user:top-secret@example.invalid/" &
      "metacraft-labs/nixos-modules?access_token=rotate-me#fragment"
    discard fx.git(["remote", "set-url", "--push", "metacraft-labs",
      secretUrl])
    let credentialAlias = evaluateOutgoingCurrent(gitBin, fx.repo, refs,
      "metacraft-labs", secretUrl, "origin", cleanUrl)
    check credentialAlias.protocolOk
    check credentialAlias.outgoingCurrent
    check credentialAlias.diagnostic.len == 0
    let dispatcher = fx.repo / ".git" / "hooks" / "pre-push"
    writeFile(fx.capture, "")
    let credentialDispatch = run(q(dispatcher) & " metacraft-labs " &
      q(secretUrl) & " < " & q(refs), fx.repo)
    check credentialDispatch.code != 0
    var credentialSurfaces = @[credentialDispatch.output, readFile(fx.capture)]
    for reportName in ["check-report.json", "push-report.json",
        "hooks-report.json"]:
        let report = fx.workspace / ".repro" / "build" / "reports" / reportName
        if fileExists(report):
            credentialSurfaces.add(readFile(report))
    for surface in credentialSurfaces:
        for secret in ["user:top-secret", "top-secret", "access_token",
            "rotate-me", "fragment", secretUrl]:
            check secret notin surface

    # Restore the exact manifest repository destination and drive the complete
    # installed dispatcher + publication gate through real ``git push``.
    discard fx.git(["config", "--unset-all",
      "remote.metacraft-labs.pushurl"], required = false)
    discard fx.git(["remote", "set-url", "metacraft-labs", fx.origin])
    let exactPush = fx.git(["push", "metacraft-labs", "main"],
      required = false)
    if exactPush.code != 0: checkpoint(exactPush.output)
    check exactPush.code == 0

    # The full gate refuses both a wholly different alias destination and the
    # subtler fetch-match/pushURL-mismatch without updating either bare repo.
    fx.commit("alias-wrong-destination")
    let wrongBefore = run(q(gitBin) & " --git-dir=" & q(fx.wrong) &
      " rev-parse --verify refs/heads/main").code
    check wrongBefore != 0
    discard fx.git(["remote", "set-url", "metacraft-labs", fx.wrong])
    assertRefused(fx.git(["push", "metacraft-labs", "main"],
      required = false), "unpublished")
    check run(q(gitBin) & " --git-dir=" & q(fx.wrong) &
      " rev-parse --verify refs/heads/main").code != 0
    discard fx.git(["remote", "set-url", "metacraft-labs", fx.origin])
    discard fx.git(["remote", "set-url", "--push", "metacraft-labs",
      fx.wrong])
    assertRefused(fx.git(["push", "metacraft-labs", "main"],
      required = false), "unpublished")
    check run(q(gitBin) & " --git-dir=" & q(fx.wrong) &
      " rev-parse --verify refs/heads/main").code != 0
    discard fx.git(["config", "--unset-all",
      "remote.metacraft-labs.pushurl"], required = false)

    # A batch still cannot borrow the alias exception, and an exact retry
    # remains eligible.
    discard fx.git(["tag", "alias-batch"])
    assertRefused(fx.git(["push", "metacraft-labs", "main",
      "refs/tags/alias-batch"], required = false), "unpublished")
    discard fx.git(["push", "metacraft-labs", "main"])

    # A force/non-fast-forward update through the correct alias remains
    # ineligible and leaves the real destination unchanged.
    let published = fx.head()
    discard fx.git(["checkout", "--orphan", "alias-rewritten"])
    discard fx.git(["rm", "-rf", "."])
    writeFile(fx.repo / "README.md", "alias rewritten\n")
    discard fx.git(["add", "README.md"])
    discard fx.git(["commit", "-m", "alias rewritten"])
    discard fx.git(["branch", "-M", "main"])
    let aliasForce = fx.git(["push", "--force", "metacraft-labs", "main"],
      required = false)
    assertRefused(aliasForce, "unpublished")
    # RA-32 — the refusal must name the reason it actually declined. The
    # property is still `unpublished`, and the push is still refused; what
    # changes is that the operator is no longer told to run the very push
    # being refused. Before RA-32 the only remedy printed was
    # "run 'git push' in . first", while `evaluateOutgoing` had computed
    # "outgoing update is not a fast-forward" and discarded it.
    check "not a fast-forward" in aliasForce.output
    check "will not help" in aliasForce.output
    check require(q(gitBin) & " --git-dir=" & q(fx.origin) &
      " rev-parse refs/heads/main").strip() == published

proc exerciseFormat(gitBin, objectFormat: string) =
    var fx = setupFixture(gitBin, objectFormat)
    defer: removeDir(fx.scratch)
    let priorRepro = overrideEnv("REPROBUILD_REPRO", fx.reproBin)
    let priorSystem = overrideEnv("REPROBUILD_SYSTEM_CONFIG",
      fx.scratch / "no-system.toml")
    let priorUser = overrideEnv("REPROBUILD_USER_CONFIG",
      fx.scratch / "no-user.toml")
    let priorVcsPrivate = overrideEnv("REPROBUILD_VCS_PRIVATE_CONFIG",
      fx.scratch / "no-vcs-private.toml")
    defer:
        restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", priorVcsPrivate)
        restoreEnv("REPROBUILD_USER_CONFIG", priorUser)
        restoreEnv("REPROBUILD_SYSTEM_CONFIG", priorSystem)
        restoreEnv("REPROBUILD_REPRO", priorRepro)

    # One exact outgoing HEAD succeeds. A spoofed legacy sentinel neither skips
    # the preserved hook nor disables the managed gate.
    fx.commit("ordinary-outgoing")
    let outgoingHead = fx.head()
    let firstPush = run("env REPROBUILD_HOOK_ACTIVE=1 " & q(gitBin) & " -C " &
      q(fx.repo) & " push origin main")
    if firstPush.code != 0: checkpoint(firstPush.output)
    check firstPush.code == 0
    let captured = readFile(fx.capture)
    check "arg1-exact\n" in captured
    check "arg2-exact\n" in captured
    check "cap=\n" in captured
    check "dispatcher=\n" in captured
    check "legacy=\n" in captured
    check "refs/heads/main " & outgoingHead & " refs/heads/main " in captured

    # Wrong target cannot make an unpublished HEAD provisional.
    fx.commit("wrong-remote")
    assertRefused(fx.git(["push", "wrong", "main"], required = false),
      "unpublished")

    # A real stale local branch and a direct URL both remain ineligible. The
    # direct URL names the same repository bytes as origin, but not the agreed
    # symbolic remote name delivered to the hook.
    discard fx.git(["branch", "stale-local", "HEAD~1"])
    assertRefused(fx.git(["push", "origin",
      "stale-local:refs/heads/stale-local"], required = false),
      "unpublished")
    assertRefused(fx.git(["push", fx.origin, "main"], required = false),
      "unpublished")

    # receive-pack cannot advertise a branch whose old target is absent or a
    # non-commit, so drive those two semantic object checks through the exact
    # installed dispatcher with real Git object IDs and otherwise valid v2
    # framing.
    let dispatcher = fx.repo / ".git" / "hooks" / "pre-push"
    let directDispatch = @[fx.reproBin, "hooks", "dispatch", "pre-push",
      "--protocol=2", "--repo-root=" & fx.repo]
    let omittedResult = runShell(shellCommand(
      directDispatch & @["--", "origin", fx.origin]))
    check omittedResult.code != 0
    check "existing readable refs file" in omittedResult.output

    let nonexistentRefs = fx.scratch / "nonexistent-refs"
    let nonexistentResult = runShell(shellCommand(
      directDispatch & @["--refs-file=" & nonexistentRefs, "--", "origin",
        fx.origin]))
    check nonexistentResult.code != 0
    check "existing readable refs file" in nonexistentResult.output

    let directEmptyRefs = fx.scratch / "direct-empty-refs"
    writeFile(directEmptyRefs, "")
    let directEmptyResult = runShell(shellCommand(
      directDispatch & @["--refs-file=" & directEmptyRefs, "--", "origin",
        fx.origin]))
    if directEmptyResult.code != 0:
      checkpoint("direct exact-empty refs stream was refused:\n" &
        directEmptyResult.output)
    check directEmptyResult.code == 0

    when not defined(windows):
      let unreadableRefs = fx.scratch / "unreadable-refs"
      writeFile(unreadableRefs, "not read\n")
      setFilePermissions(unreadableRefs, {})
      let unreadableResult = runShell(shellCommand(
        directDispatch & @["--refs-file=" & unreadableRefs, "--", "origin",
          fx.origin]))
      check unreadableResult.code != 0
      check "existing readable refs file" in unreadableResult.output
      setFilePermissions(unreadableRefs, {fpUserRead, fpUserWrite})
    else:
      # Deny this process read-data access through the native Windows ACL.
      # Always restore inheritance before fixture cleanup, including when the
      # deny command, native read probe, dispatch, or an assertion fails.
      let unreadableRefs = fx.scratch / "unreadable-refs"
      writeFile(unreadableRefs, "not read\n")
      let whoResult = run("whoami")
      if whoResult.code != 0: checkpoint(whoResult.output)
      check whoResult.code == 0
      let who = whoResult.output.strip()
      check who.len > 0
      if who.len > 0:
        var aclCommandAttempted = false
        var restoreCode = -1
        var restoreOutput = ""
        try:
          aclCommandAttempted = true
          let denied = run("icacls " & q(unreadableRefs) & " /inheritance:r " &
            "/deny " & q(who & ":(R)"))
          if denied.code != 0: checkpoint(denied.output)
          check denied.code == 0
          if denied.code == 0:
            var nativeReadDenied = false
            try:
              discard readFile(unreadableRefs)
            except CatchableError:
              nativeReadDenied = true
            check nativeReadDenied
            let unreadableResult = runShell(shellCommand(
              directDispatch & @["--refs-file=" & unreadableRefs, "--",
                "origin", fx.origin]))
            if unreadableResult.code == 0:
              checkpoint("ACL-denied refs file was unexpectedly readable")
            check unreadableResult.code != 0
            check "existing readable refs file" in unreadableResult.output
        finally:
          if aclCommandAttempted:
            try:
              let restored = run("icacls " & q(unreadableRefs) &
                " /remove:d " & q(who) & " /inheritance:e")
              restoreCode = restored.code
              restoreOutput = restored.output
            except CatchableError as error:
              # A teardown failure is reported after the behavior assertions;
              # it never replaces an exception from the ACL-denied test body.
              restoreCode = -2
              restoreOutput = error.msg
        if restoreCode != 0: checkpoint(restoreOutput)
        check restoreCode == 0
    let missingOld = repeat('a', fx.oidLength)
    let missingRefs = fx.scratch / "missing-old-refs"
    writeFile(missingRefs, "refs/heads/main " & fx.head() &
      " refs/heads/main " & missingOld & "\n")
    let missingDecision = evaluateOutgoingCurrent(gitBin, fx.repo,
      missingRefs, "origin", fx.origin, "origin", fx.origin)
    check missingDecision.protocolOk
    check not missingDecision.outgoingCurrent
    check "remote old object" in missingDecision.diagnostic
    let missingResult = run(q(dispatcher) & " origin " & q(fx.origin) &
      " < " & q(missingRefs), fx.repo)
    assertRefused(missingResult, "unpublished")
    # `git hash-object --stdin` needs bytes on stdin; create a real blob from a
    # temporary file instead.
    let blobFile = fx.scratch / "remote-old-blob"
    let blobOidFile = fx.scratch / "remote-old-blob.oid"
    writeFile(blobFile, "not a commit\n")
    # Capture stdout in a file. Git-for-Windows may write unrelated process
    # diagnostics to the merged stdout/stderr pipe used by ``runShell``; those
    # bytes must never become part of the synthetic pre-push refs record.
    discard require(q(gitBin) & " -C " & q(fx.repo) &
      " hash-object -w " & q(blobFile) & " > " & q(blobOidFile))
    let realBlob = readFile(blobOidFile).strip()
    check realBlob.len == fx.oidLength
    let blobRefs = fx.scratch / "blob-old-refs"
    writeFile(blobRefs, "refs/heads/main " & fx.head() &
      " refs/heads/main " & realBlob & "\n")
    let blobDecision = evaluateOutgoingCurrent(gitBin, fx.repo, blobRefs,
      "origin", fx.origin, "origin", fx.origin)
    check blobDecision.protocolOk
    check not blobDecision.outgoingCurrent
    check "remote old object" in blobDecision.diagnostic
    let blobResult = run(q(dispatcher) & " origin " & q(fx.origin) &
      " < " & q(blobRefs), fx.repo)
    assertRefused(blobResult, "unpublished")

    # Tag-only and multi-ref pushes likewise cannot borrow the exception.
    discard fx.git(["tag", "candidate"])
    assertRefused(fx.git(["push", "origin", "refs/tags/candidate"],
      required = false), "unpublished")
    assertRefused(fx.git(["push", "origin", "main", "refs/tags/candidate"],
      required = false), "unpublished")

    # A deletion batched with the current branch is valid Git framing but not a
    # single outgoing-current update.
    discard fx.git(["branch", "scratch", "HEAD~1"])
    discard fx.git(["push", "--no-verify", "origin", "scratch"])
    assertRefused(fx.git(["push", "origin", "main", ":scratch"],
      required = false), "unpublished")
    discard fx.git(["push", "origin", "main"])

    # Rewrite history so the remote old commit is not an ancestor of local HEAD.
    let published = fx.head()
    discard fx.git(["checkout", "--orphan", "rewritten"])
    discard fx.git(["rm", "-rf", "."])
    writeFile(fx.repo / "README.md", "rewritten\n")
    discard fx.git(["add", "README.md"])
    discard fx.git(["commit", "-m", "rewritten"])
    discard fx.git(["branch", "-M", "main"])
    let originForce = fx.git(["push", "--force", "origin", "main"],
      required = false)
    assertRefused(originForce, "unpublished")
    # RA-32, same property through the plain `origin` remote.
    check "not a fast-forward" in originForce.output
    check "will not help" in originForce.output
    discard fx.git(["fetch", "origin", "main"])
    discard fx.git(["reset", "--hard", published])

    # Already-published HEAD retains valid non-branch behavior: tag, deletion,
    # and the certificate notes ref all pass the managed policy.
    discard fx.git(["tag", "published-tag"])
    check fx.git(["push", "origin", "refs/tags/published-tag"],
      required = false).code == 0
    check fx.git(["push", "origin", ":scratch"], required = false).code == 0
    discard fx.git(["notes", "--ref=refs/notes/reprobuild/certificates",
      "add", "-m", "certificate", "HEAD"])
    check fx.git(["push", "origin",
      "refs/notes/reprobuild/certificates"], required = false).code == 0

    # Already-published HEAD keeps the existing allow policy for valid force
    # and multi-ref updates; outgoing-current is not needed in this state.
    discard fx.git(["push", "--no-verify", "origin",
      "HEAD:refs/heads/force-target"])
    discard fx.git(["branch", "force-source", "HEAD~1"])
    check fx.git(["push", "--force", "origin",
      "force-source:refs/heads/force-target"], required = false).code == 0
    discard fx.git(["tag", "published-batch-one"])
    discard fx.git(["tag", "published-batch-two"])
    check fx.git(["push", "origin", "refs/tags/published-batch-one",
      "refs/tags/published-batch-two"], required = false).code == 0

    # Synthetic malformed bytes: Git cannot generate these. Even published HEAD
    # is refused before workspace policy. Invoke the installed dispatcher so the
    # temp-file forwarding and v2 handshake are both exercised.
    let zeros = repeat('0', fx.oidLength)
    let valid = "refs/heads/main " & fx.head() & " refs/heads/main " & zeros
    let emptyRefs = fx.scratch / "empty-refs"
    writeFile(emptyRefs, "")
    let emptyResult = run(q(dispatcher) & " origin " & q(fx.origin) &
      " < " & q(emptyRefs), fx.repo)
    if emptyResult.code != 0:
        checkpoint("zero-update refs stream was refused:\n" &
                emptyResult.output)
    check emptyResult.code == 0
    let malformed = @[
      "\n",
      valid & "\n\n",
      valid.replace(" ", "  ") & "\n",
      valid.replace(" ", "\t") & "\n",
      valid & " extra\n",
      "refs/heads/main deadbeef refs/heads/main " & zeros & "\n",
      valid & "\x01\n"
    ]
    for index, bytes in malformed:
        let refs = fx.scratch / ("malformed-" & $index)
        writeFile(refs, bytes)
        let command = q(dispatcher) & " origin " & q(fx.origin) & " < " & q(refs)
        let res = run(command, fx.repo)
        if res.code == 0:
            checkpoint("malformed case " & $index & " unexpectedly passed")
        check res.code != 0

    # Credential-bearing user-info/query/fragment material is stripped before
    # identity hashing and never reflected in hook diagnostics.
    let secretUrl = "https://user:top-secret@example.invalid/repo.git" &
      "?access_token=rotate-me#credential-fragment"
    check normalizedRemoteLocation(secretUrl) ==
      "https://example.invalid/repo.git"
    check normalizedRemoteLocation("file://build-host/srv/repo.git") ==
      "file://build-host/srv/repo.git"
    check normalizedRemoteLocation("ssh://User@example.invalid/repo.git") ==
      "ssh://example.invalid/repo.git"
    # Isolate this invocation's preserved-hook marker. The managed gate must
    # fail before chaining it, and no configured URL may be copied into any
    # human or machine-readable diagnostic surface.
    writeFile(fx.capture, "")
    fx.commit("credential-diagnostic-unpublished")
    let credentialRefs = fx.scratch / "credential-refs"
    writeFile(credentialRefs, "refs/heads/main " & fx.head() &
      " refs/heads/main " & zeros & "\n")
    let credentialResult = run(q(dispatcher) & " origin " & q(secretUrl) &
      " < " & q(credentialRefs), fx.repo)
    check credentialResult.code != 0
    var credentialSurfaces = @[credentialResult.output, readFile(fx.capture)]
    for reportName in ["check-report.json", "push-report.json"]:
        let report = fx.workspace / ".repro" / "build" / "reports" / reportName
        if fileExists(report): credentialSurfaces.add(readFile(report))
    let hooksReport = fx.workspace / ".repro" / "build" / "reports" /
      "hooks-report.json"
    if fileExists(hooksReport): credentialSurfaces.add(readFile(hooksReport))
    for surface in credentialSurfaces:
        for secret in ["user:top-secret", "top-secret", "access_token",
            "rotate-me", "credential-fragment", secretUrl]:
            check secret notin surface
    check "arg2-other\n" in readFile(fx.capture)

suite "pre-push protocol v2 — ref validation":
    test "manifest origin accepts only the exact metacraft-labs checkout alias":
        let gitBin = findExe("git")
        if gitBin.len == 0:
            skip()
        else:
            exerciseManifestRemoteAlias(gitBin)

    test "real SHA-1 pushes enforce strict outgoing-current semantics":
        let gitBin = findExe("git")
        if gitBin.len == 0:
            skip()
        else:
            exerciseFormat(gitBin, "sha1")

    test "real SHA-256 pushes enforce the same semantics when Git supports it":
        let gitBin = findExe("git")
        if gitBin.len == 0 or not gitSupportsFormat(gitBin, "sha256"):
            skip()
        else:
            exerciseFormat(gitBin, "sha256")

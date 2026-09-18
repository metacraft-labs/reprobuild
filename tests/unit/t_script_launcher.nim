## ``launcher`` — making a SCRIPT payload invocable as a command.
##
## A realized prefix reaches PATH as a DIRECTORY, so a command's name there
## is a file's own name and the OS has to be able to execute that file. That
## holds for a native binary and fails for everything npm publishes:
## ``@google/gemini-cli`` ships ``bundle/gemini.js``, ``@qwen-code/qwen-code``
## ships ``cli-entry.js``, and neither is a program. Declaring one as
## ``executablePath`` yields a prefix on PATH whose command cannot be run.
##
## npm's own answer is a launcher pair generated beside the bundle —
## ``gemini`` and ``gemini.cmd`` — and ``launcher`` asks realize to do the
## same thing, taking its NAME from ``executableAlias``. Without a launcher
## an alias stays what it was: a copy of the declared file under a second
## name. These cases pin both halves, because the field changes the meaning
## of a field that already existed.
##
## The fixture is a one-line script realized over ``file://`` through
## ``archiveType = "raw"``, so nothing here touches the network.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_interface_artifacts
import repro_tool_profiles

proc scriptUse(url, sha256, alias, launcher: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "launcherfixture",
    packageSelector: "launcherfixture",
    executableName: alias,
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "launcherfixture",
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "raw",
    executablePath: "hello.js",
    executableAlias: alias,
    launcher: launcher,
    stripComponents: 0,
    packageId: "launcherfixture@1",
    lockIdentity: "sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

proc fileUrl(path: string): string =
  "file:///" & path.replace('\\', '/').strip(leading = true, chars = {'/'})

suite "a script payload becomes a command":
  putEnv("REPRO_CACHE_DISABLE", "1")

  # The payload prints a token so an executed launcher can be told apart
  # from one that merely exists.
  const Script = "console.log('launcher-ok');\n"
  proc realizeFixture(alias, launcher: string;
                      root: string): PathOnlyToolProfile =
    let scriptPath = root / "hello.js"
    writeFile(scriptPath, Script)
    # The digest is computed from the fixture rather than pinned: the point
    # under test is the launcher, and `resolveTarballTool` still verifies
    # what it downloaded against this value, so the check is live.
    let digest = sha256Hex(readFile(scriptPath))
    resolveTarballTool(
      scriptUse(fileUrl(scriptPath), digest, alias, launcher),
      root / "store")

  test "an alias with a launcher yields a launcher pair, not a copy":
    let root = createTempDir("repro-launcher-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let profile = realizeFixture("hello", "node", root)
    let prefix = profile.selectedStorePath
    let posixLauncher = prefix / "hello"
    let windowsLauncher = prefix / "hello.cmd"
    check fileExists(prefix / "hello.js")
    check fileExists(posixLauncher)
    check fileExists(windowsLauncher)
    # A copy would be byte-identical to the script. A launcher is not.
    check readFile(posixLauncher) != Script
    # The script is referenced by its own NAME, never by the store path it
    # happened to land at — that is what keeps the prefix relocatable.
    check readFile(posixLauncher).contains("hello.js")
    check (not readFile(posixLauncher).contains(prefix))
    check readFile(windowsLauncher).contains("hello.js")
    check (not readFile(windowsLauncher).contains(prefix))
    # And each names the declared interpreter, resolved from PATH.
    check readFile(posixLauncher).contains("node")
    check readFile(windowsLauncher).contains("node")

  test "an alias without a launcher is still a copy":
    # The pre-existing behaviour, pinned because `launcher` changes what
    # `executableAlias` means and must not change it when absent.
    let root = createTempDir("repro-launcher-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let profile = realizeFixture("hello", "", root)
    let prefix = profile.selectedStorePath
    check fileExists(prefix / "hello")
    check readFile(prefix / "hello") == Script
    check (not fileExists(prefix / "hello.cmd"))

  test "the generated launcher actually runs the script":
    # Existence is not invocability. This is the case the whole field is
    # for, so it is executed rather than inspected — skipped only where the
    # interpreter is genuinely absent.
    if findExe("node").len == 0:
      skip()
    else:
      let root = createTempDir("repro-launcher-", "")
      defer:
        try: removeDir(root) except CatchableError: discard
      let profile = realizeFixture("hello", "node", root)
      let prefix = profile.selectedStorePath
      let command =
        when defined(windows): prefix / "hello.cmd"
        else: prefix / "hello"
      let res = execCmdEx(quoteShell(command))
      checkpoint("exit=" & $res.exitCode & " output=" & res.output)
      check res.exitCode == 0
      check res.output.contains("launcher-ok")

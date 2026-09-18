## ``closureManifest`` — a package whose entry point needs its dependencies.
##
## Most tarball packages are one archive. Two of the coding agents are not:
## ``@zed-industries/claude-code-acp`` is 174 KB with five runtime
## dependencies, and ``@sourcegraph/amp`` is an 895-byte wrapper whose
## ``bin`` points into ``node_modules/@ampcode/cli/bin/`` — a
## platform-specific native binary npm reaches through optional
## dependencies. Declaring either as a single tarball yields a prefix whose
## command cannot start.
##
## The alternative everybody reaches for first is a build step that runs
## ``npm install`` into the prefix. That is a version-range resolution at
## build time and a network fetch inside a build — the two things this
## whole provisioning system exists to remove. A manifest of PINNED
## archives keeps the fetch content-addressed, cached in the store's own
## download cache, and offline after the first time.
##
## The fixtures here are tarballs built on the spot and served over
## ``file://``, so nothing touches the network.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_interface_artifacts
import repro_tool_profiles

proc fileUrl(path: string): string =
  "file:///" & path.replace('\\', '/').strip(leading = true, chars = {'/'})

proc makeTarball(root, name, innerRelPath, contents: string): string =
  ## An npm-shaped archive: everything under a single ``package/`` root,
  ## which is why the realizer strips one component for closure entries.
  let stage = root / ("stage-" & name)
  let inner = stage / "package" / innerRelPath
  createDir(inner.parentDir)
  writeFile(inner, contents)
  result = root / (name & ".tgz")
  # No `--force-local`: the `tar` on a Windows PATH may be bsdtar, which
  # rejects the flag outright and handles a drive letter natively anyway.
  let res = execCmdEx("tar -czf " & quoteShell(result) &
    " -C " & quoteShell(stage) & " package")
  doAssert res.exitCode == 0, "tar failed: " & res.output

proc closureUse(rootUrl, rootSha, manifestPath: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "closurefixture",
    packageSelector: "closurefixture",
    executableName: "cli",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "closurefixture",
    url: rootUrl,
    sha256: "sha256:" & rootSha,
    archiveType: "tar.gz",
    stripComponents: 1,
    executablePath: "bin/cli.js",
    closureManifest: manifestPath,
    packageId: "closurefixture@1",
    lockIdentity: "tarball:closurefixture@1:sha256:" & rootSha,
    location: SourceLocation(file: "fixture", line: 2))]

suite "a declared closure lands beside the entry point":
  putEnv("REPRO_CACHE_DISABLE", "1")

  test "each manifest entry is unpacked at its declared path":
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js",
      "require('dep');\n")
    let depTgz = makeTarball(root, "dep", "index.js", "module.exports=1;\n")
    let manifest = root / "closure.manifest"
    writeFile(manifest,
      "# generated from package-lock.json\n" &
      "node_modules/dep " & sha256Hex(readFile(depTgz)) & " " &
      fileUrl(depTgz) & "\n")

    let profile = resolveTarballTool(
      closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)), manifest),
      root / "store")
    let prefix = profile.selectedStorePath
    # The entry point, and the dependency it resolves against — the whole
    # point being that the second is present without a build step.
    check fileExists(prefix / "bin" / "cli.js")
    check fileExists(prefix / "node_modules" / "dep" / "index.js")
    check readFile(prefix / "node_modules" / "dep" / "index.js") ==
      "module.exports=1;\n"

  test "a manifest entry that escapes the prefix is refused":
    # The one input here that is a path from a file, so the one that can
    # try to write outside the store.
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let depTgz = makeTarball(root, "dep", "index.js", "y\n")
    let manifest = root / "escape.manifest"
    writeFile(manifest,
      "../outside " & sha256Hex(readFile(depTgz)) & " " & fileUrl(depTgz) &
      "\n")
    var message = ""
    try:
      discard resolveTarballTool(
        closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)), manifest),
        root / "store")
    except CatchableError as err:
      message = err.msg
    check message.contains("inside the prefix")

  test "a malformed manifest line names the file and the line":
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let manifest = root / "bad.manifest"
    writeFile(manifest, "node_modules/dep only-two-fields\n")
    var message = ""
    try:
      discard resolveTarballTool(
        closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)), manifest),
        root / "store")
    except CatchableError as err:
      message = err.msg
    check message.contains("bad.manifest")
    check message.contains("only-two-fields")

  test "a missing manifest is an error, not an empty closure":
    # Silently realizing a prefix without its dependencies would produce a
    # command that fails at RUN time on a consumer's machine, which is the
    # failure this whole field exists to move earlier.
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    var message = ""
    try:
      discard resolveTarballTool(
        closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)),
          root / "absent.manifest"),
        root / "store")
    except CatchableError as err:
      message = err.msg
    check message.contains("closure manifest not found")

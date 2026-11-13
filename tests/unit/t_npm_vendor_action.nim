## The npm vendor action's populate program, run for real against a seeded
## download cache with `npm` and `sha256sum` replaced by logging stubs.
##
## What is checked, each of which has a way of being quietly wrong:
##
## * every archive is verified against the manifest's SHA-256 on every run,
##   and a batch is verified BEFORE `npm cache add` sees it, so a corrupted
##   archive never enters the private cache;
## * an archive already on disk costs no process: verification runs once per
##   `npm cache add` batch, not once per archive. A process per archive is
##   what made this step take hours on Windows (reprobuild-specs issue
##   "npm vendor populates a fresh private cache at a few archives a
##   minute");
## * the up-to-date token still skips a populated cache.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import repro_project_dsl
import repro_project_dsl/npm_vendor

const
  ArchiveCount = 150
    ## More than one `npm cache add` batch (100), so a batch boundary is
    ## exercised.
  ArchiveText = "x\n"
  ArchiveSha256 =
    "73cb3858a687a8494ca3323053016282f3dad39d42cf62ca4e79dda2aac7d9ac"
  BadSha256 =
    "0000000000000000000000000000000000000000000000000000000000000000"

proc archiveRel(i: int): string =
  if i mod 2 == 0: "@scope/pkg" & $i & "/-/pkg" & $i & "-1.0.0.tgz"
  else: "pkg" & $i & "/-/pkg" & $i & "-1.0.0.tgz"

proc writeFixture(root: string; badIndex = -1) =
  var manifest = "# fixture closure\n"
  for i in 0 ..< ArchiveCount:
    let sha = if i == badIndex: BadSha256 else: ArchiveSha256
    manifest.add("node_modules/pkg" & $i & " " & sha &
      " https://registry.npmjs.org/" & archiveRel(i) & "\n")
  writeFile(root / NpmBuildClosureManifestName, manifest)
  for i in 0 ..< ArchiveCount:
    let path = npmVendorCacheDir(root) / archiveRel(i)
    createDir(path.parentDir)
    writeFile(path, ArchiveText)

proc writeStubs(dir, log, realSha256sum: string) =
  ## `npm` records its arguments and writes one cacache index entry per
  ## `file:` spec, which is what the up-to-date check counts.
  createDir(dir)
  let logPath = log.replace("\\", "/")
  writeFile(dir / "npm",
    "#!/bin/sh\n" &
    "printf 'npm' >> '" & logPath & "'\n" &
    "cache=''; prev=''; n=0\n" &
    "for a in \"$@\"; do\n" &
    "  [ \"$prev\" = --cache ] && cache=\"$a\"\n" &
    "  case \"$a\" in file:*) n=$((n + 1)); printf ' %s' \"$a\" >> '" &
    logPath & "';; esac\n" &
    "  prev=\"$a\"\n" &
    "done\n" &
    "printf '\\n' >> '" & logPath & "'\n" &
    "mkdir -p \"$cache/_cacache/index-v5/00/00\"\n" &
    "i=0; while [ \"$i\" -lt \"$n\" ]; do\n" &
    "  : > \"$cache/_cacache/index-v5/00/00/$$-$i\"; i=$((i + 1)); done\n")
  writeFile(dir / "sha256sum",
    "#!/bin/sh\n" &
    "printf 'sha256sum\\n' >> '" & logPath & "'\n" &
    "exec '" & realSha256sum.replace("\\", "/") & "' \"$@\"\n")
  for name in ["npm", "sha256sum"]:
    setFilePermissions(dir / name, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc populateProgram(root: string): string =
  let act = emitNpmVendorAction(root, "fixturePkg", "", "")
  let argv = act.call.arguments[0].encodedValue.split('\x1f')
  check argv.len == 3
  check argv[0] == "sh"
  argv[^1]

proc runProgram(program, root, stubDir: string): int =
  let sh = findExe("sh")
  let sep = when defined(windows): ";" else: ":"
  putEnv("PATH", stubDir & sep & getEnv("PATH"))
  let p = startProcess(sh, workingDir = root, args = ["-c", program],
    options = {poParentStreams})
  result = p.waitForExit()
  p.close()

proc logLines(log, prefix: string): seq[string] =
  if not fileExists(log):
    return @[]
  for line in readFile(log).splitLines():
    if line.startsWith(prefix):
      result.add(line)

suite "npm vendor action":
  let sh = findExe("sh")
  let realSha256sum = findExe("sha256sum", followSymlinks = false)
  let savedPath = getEnv("PATH")

  test "a seeded cache is verified and loaded once per batch":
    if sh.len == 0 or realSha256sum.len == 0:
      skip("sh or sha256sum not on PATH; this case runs the populate " &
           "program against the real tools")
    else:
      let root = createTempDir("repro-npm-vendor-", "")
      defer:
        putEnv("PATH", savedPath)
        try: removeDir(root) except CatchableError: discard
      writeFixture(root)
      let stubDir = root / "stubs"
      let log = root / "calls.log"
      writeStubs(stubDir, log, realSha256sum)
      let program = populateProgram(root)
      check runProgram(program, root, stubDir) == 0
      let npmCalls = logLines(log, "npm")
      check npmCalls.len == 2
      var loaded: seq[string] = @[]
      for call in npmCalls:
        for word in call.splitWhitespace()[1 .. ^1]:
          loaded.add(word)
      check loaded.len == ArchiveCount
      for i in 0 ..< ArchiveCount:
        check ("file:" & archiveRel(i)) in loaded
      # One verification per batch, not one per archive.
      check logLines(log, "sha256sum").len == 2
      check fileExists(npmVendorStampPath(root))
      check dirExists(npmPrivateCacheDir(root) / "_logs")

      # A second run finds the cache up to date and starts nothing.
      removeFile(log)
      check runProgram(program, root, stubDir) == 0
      check logLines(log, "npm").len == 0
      check logLines(log, "sha256sum").len == 0

  test "a corrupted archive fails its batch before npm sees it":
    if sh.len == 0 or realSha256sum.len == 0:
      skip("sh or sha256sum not on PATH; this case runs the populate " &
           "program against the real tools")
    else:
      let root = createTempDir("repro-npm-vendor-", "")
      defer:
        putEnv("PATH", savedPath)
        try: removeDir(root) except CatchableError: discard
      # Index 120 is in the second batch: the first loads, the second must
      # stop at verification.
      writeFixture(root, badIndex = 120)
      let stubDir = root / "stubs"
      let log = root / "calls.log"
      writeStubs(stubDir, log, realSha256sum)
      check runProgram(populateProgram(root), root, stubDir) != 0
      let npmCalls = logLines(log, "npm")
      check npmCalls.len == 1
      check ("file:" & archiveRel(120)) notin npmCalls.join(" ")
      check not fileExists(npmVendorStampPath(root))

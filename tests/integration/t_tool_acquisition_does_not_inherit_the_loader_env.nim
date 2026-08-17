## Tool acquisition must not hand the caller's loader environment to the host
## binary it spawns.
##
## The class-2 PATH-only tier resolves tools BEFORE a store exists, so the
## `curl` it finds is whichever one the host provides, linked against the
## host's own libc and OpenSSL. Reprobuild's devshell exports an
## `LD_LIBRARY_PATH` full of nix-store libraries. Inheriting it forces
## nix-store `libssl.so.3` / `libcrypto.so.3` onto a binary never linked
## against them, and the loader kills the process before `main`:
##
##   /usr/bin/curl: /nix/store/.../libcrypto.so.3: version `GLIBC_2.38' not
##   found (required by /usr/bin/curl)
##
## `verifiedDownload` then reported `tool-resolution failed: all tarball
## archive URLs failed for nim` -- while the archive was sha256-pinned and
## content-addressed and the URL was never the problem.
##
## No mocking of the code under test. The only substitution is a fake `curl`
## placed first on `PATH`, which is what a host `curl` IS to this layer: an
## ambient binary found by `findExe`. It records the loader variables it was
## handed and serves the archive from disk, so the assertions are about the
## real `resolveTarballTool` -> `verifiedDownload` -> `downloadUrlToFile`
## path over a real `http://` URL, with no network.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_test_support
import repro_tool_profiles

proc q(value: string): string = quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

const PoisonLdPath = "/nonexistent/poison/lib"

proc buildArchive(tempRoot: string): tuple[path: string; sha256: string] =
  ## A minimal real `tar.gz` carrying `bin/acqtool`, so the adapter has
  ## something to verify and extract rather than a stubbed return value.
  let payloadRoot = tempRoot / "payload"
  let packageRoot = payloadRoot / "acqtool-1.0.0"
  let binDir = packageRoot / "bin"
  createDir(binDir)
  let toolPath = binDir / "acqtool"
  writeFile(toolPath, "#!/bin/sh\nset -eu\necho acqtool 1.0.0\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  let archivePath = tempRoot / "acqtool-1.0.0.tar.gz"
  let res = execCmdEx(shellCommand(["tar", "-czf", archivePath, "-C",
    payloadRoot, "acqtool-1.0.0"]))
  doAssert res.exitCode == 0, "tar failed: " & res.output
  result = (path: archivePath, sha256: fileSha256Hex(archivePath))

proc installFakeCurl(binDir, recordPath, archivePath: string;
                     failWith = "") =
  ## A `curl` that records the loader variables it inherited, then either
  ## serves the archive or fails the way a dynamic-link death does: a
  ## diagnostic on stderr and a non-zero exit.
  createDir(binDir)
  let curlPath = binDir / "curl"
  var body = "#!/bin/sh\n"
  body.add("{\n")
  body.add("  printf 'LD_LIBRARY_PATH=[%s]\\n' \"${LD_LIBRARY_PATH:-}\"\n")
  body.add("  printf 'LD_PRELOAD=[%s]\\n' \"${LD_PRELOAD:-}\"\n")
  body.add("  printf 'DYLD_LIBRARY_PATH=[%s]\\n' \"${DYLD_LIBRARY_PATH:-}\"\n")
  body.add("  printf 'PATH_SEEN=[%s]\\n' \"${PATH:-}\"\n")
  body.add("} >> " & q(recordPath) & "\n")
  if failWith.len > 0:
    body.add("echo " & q(failWith) & " >&2\n")
    body.add("exit 1\n")
  else:
    # Honour `-o <dest>`: the real invocation is
    # `curl -L --fail --silent --show-error -o <dest> <url>`.
    body.add("dest=\"\"\n")
    body.add("while [ $# -gt 0 ]; do\n")
    body.add("  if [ \"$1\" = \"-o\" ]; then dest=\"$2\"; shift 2; " &
      "else shift; fi\n")
    body.add("done\n")
    body.add("[ -n \"$dest\" ] || exit 3\n")
    body.add("cp " & q(archivePath) & " \"$dest\"\n")
    body.add("exit 0\n")
  writeFile(curlPath, body)
  setFilePermissions(curlPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc acqUseDef(url, sha256: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "acqtool",
    packageSelector: "acqtool@1.0.0",
    executableName: "acqtool",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "acqtool",
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "tar.gz",
    executablePath: "bin/acqtool",
    stripComponents: 1,
    packageId: "acqtool@1.0.0",
    lockIdentity: "sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

template withEnv(pathPrefix: string; body: untyped) =
  let priorPath = getEnv("PATH")
  let priorLd = getEnv("LD_LIBRARY_PATH")
  putEnv("PATH", pathPrefix & PathSep & priorPath)
  putEnv("LD_LIBRARY_PATH", PoisonLdPath)
  try:
    body
  finally:
    putEnv("PATH", priorPath)
    if priorLd.len > 0: putEnv("LD_LIBRARY_PATH", priorLd)
    else: delEnv("LD_LIBRARY_PATH")

proc toolingAvailable(): bool =
  ## Runtime, not `when`: `findExe` cannot run at compile time.
  findExe("tar").len > 0 and findExe("sh").len > 0

suite "tool acquisition does not inherit the caller's loader environment":

  test "the spawned downloader sees no LD_LIBRARY_PATH from its parent":
    if hostOS == "windows" or not toolingAvailable():
      skip()
    else:
      let tempRoot = createTempDir("acq-loader-", "")
      defer: removeDir(tempRoot)
      let archive = buildArchive(tempRoot)
      let fakeBin = tempRoot / "fakebin"
      let record = tempRoot / "curl-env.txt"
      installFakeCurl(fakeBin, record, archive.path)

      # An `http://` URL is what routes through the curl branch at all; a
      # `file://` URL would bypass the spawn entirely and prove nothing.
      let useDef = acqUseDef("http://tool-acquisition.invalid/acqtool.tar.gz",
        archive.sha256)
      withEnv(fakeBin):
        # Sanity: the poison really is in the parent's environment, so a
        # green assertion below cannot come from it never being set.
        check getEnv("LD_LIBRARY_PATH") == PoisonLdPath
        let profile = resolveTarballTool(useDef, tempRoot / "store")
        check profile.installMethod == "tarball"

      check fileExists(record)
      let seen = readFile(record)
      # The whole property, stated three ways. Before the fix the first of
      # these read `LD_LIBRARY_PATH=[/nonexistent/poison/lib]`.
      check seen.contains("LD_LIBRARY_PATH=[]")
      check not seen.contains(PoisonLdPath)
      check seen.contains("LD_PRELOAD=[]")
      check seen.contains("DYLD_LIBRARY_PATH=[]")
      # PATH is deliberately still inherited -- that is how the class-2 tier
      # finds the tool at all, and stripping it would break resolution.
      check seen.contains(fakeBin)

  test "a downloader that dies before main says so in the error":
    ## The second half of the same incident. With `poParentStreams` the
    ## loader's diagnostic went to the terminal and never reached the
    ## exception, so the only thing recorded was "all tarball archive URLs
    ## failed" -- pointing at the URL, which was fine, instead of at the
    ## dynamic link, which was not.
    if hostOS == "windows" or not toolingAvailable():
      skip()
    else:
      let tempRoot = createTempDir("acq-diag-", "")
      defer: removeDir(tempRoot)
      let archive = buildArchive(tempRoot)
      let fakeBin = tempRoot / "fakebin"
      let record = tempRoot / "curl-env.txt"
      const LoaderDeath =
        "curl: /nix/store/xxx/libcrypto.so.3: version `GLIBC_2.38' not found"
      installFakeCurl(fakeBin, record, archive.path, failWith = LoaderDeath)

      let useDef = acqUseDef("http://tool-acquisition.invalid/acqtool.tar.gz",
        archive.sha256)
      var raised = ""
      withEnv(fakeBin):
        try:
          discard resolveTarballTool(useDef, tempRoot / "store")
        except CatchableError as err:
          raised = err.msg
      check raised.len > 0
      # Still names the aggregate failure...
      check raised.contains("all tarball archive URLs failed")
      # ...but now also carries the cause, which is the point.
      check raised.contains("GLIBC_2.38")
      check raised.contains("libcrypto.so.3")

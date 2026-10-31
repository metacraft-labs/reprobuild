## A real `create_dmg` edge re-run over the `.dmg` its previous run wrote.
##
## create-dmg 1.2.2 finishes with `hdiutil convert ... -o <dmg>`, which
## refuses an existing file (`hdiutil: convert failed - File exists`). So the
## second build after any input change used to fail BECAUSE the first had
## succeeded. The typed tool now declares the image as an output the engine
## removes before the edge runs; this drives the real tool, the real
## `hdiutil` and the real engine through `repro build` twice with an input
## change in between, over a `.dmg` that is already there before the first.
##
## macOS only: `hdiutil` exists nowhere else, and the `create_dmg` typed tool
## is provisioned from nixpkgs, so the host must support Nix as well. Nothing
## is mocked.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = runquotaSocketEndpoint(
    "repro-dmg-rq-" & $getCurrentProcessId())
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184",
    # Test daemon: keep it out of the host-wide observation store.
    "--no-write-stats"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc build(reproBin, projectRoot, repoRoot: string): JsonNode =
  ## `--daemon=off` for the reason the m51 file gives: a resident daemon
  ## would couple the case to whatever environment it was started in.
  let output = requireSuccess(shellCommand([reproBin, "build", projectRoot,
    "--daemon=off", "--log=actions", "--write-report"]), repoRoot)
  for line in output.splitLines:
    if line.startsWith("buildReport:"):
      return parseFile(line["buildReport:".len .. ^1].strip())
  raise newException(ValueError, "no buildReport line in:\n" & output)

proc dmgAction(report: JsonNode): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == "macos-dmg":
      return item
  newJNull()

proc writeDmgProject(projectRoot: string) =
  createDir(projectRoot / "src" / "Hello.app" / "Contents")
  writeFile(projectRoot / "src" / "Hello.app" / "Contents" / "Info.plist",
    "<plist version=\"1.0\"><dict/></plist>\n")
  writeFile(projectRoot / "src" / "readme.txt", "first\n")
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_dsl_stdlib\n\n" &
    "package dmgRerun:\n" &
    "  defaultToolProvisioning \"nix\"\n" &
    "  uses:\n" &
    "    \"create-dmg >=1\"\n" &
    "  build:\n" &
    "    let dmg = create_dmg(\n" &
    "      volname = \"Hello\",\n" &
    "      sandboxSafe = true,\n" &
    "      dmg = \"out/Hello.dmg\",\n" &
    "      src = \"src\",\n" &
    "      actionId = \"macos-dmg\")\n" &
    "    defaultTarget(dmg)\n")

suite "create_dmg re-runs over its own image":
  test "two builds with an input change between both write the image":
    when not defined(macosx):
      skip("create-dmg drives hdiutil, which exists only on macOS")
    elif not isNixSupported:
      skip("the create_dmg typed tool is provisioned from nixpkgs, and " &
        "this host cannot realize it")
    else:
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-create-dmg-rerun", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = reproBinary(repoRoot)
      let projectRoot = tempRoot / "project"
      writeDmgProject(projectRoot)
      # An image from an earlier build is already there: the first build
      # must replace it too.
      createDir(projectRoot / "out")
      writeFile(projectRoot / "out" / "Hello.dmg", "stale image\n")

      let first = build(reproBin, projectRoot, repoRoot)
      check dmgAction(first){"status"}.getStr() == "asSucceeded"
      let firstImage = readFile(projectRoot / "out" / "Hello.dmg")
      check firstImage != "stale image\n"

      writeFile(projectRoot / "src" / "readme.txt", "second\n")
      let second = build(reproBin, projectRoot, repoRoot)
      let action = dmgAction(second)
      check action{"status"}.getStr() == "asSucceeded"
      check action{"launched"}.getBool()
      check fileExists(projectRoot / "out" / "Hello.dmg")
      check readFile(projectRoot / "out" / "Hello.dmg") != firstImage

## M83 step 13 — disposable-WSL gate for the POSIX arm of
## `shell.integration`.
##
## On POSIX `shell.integration` delegates to `fs.managedBlock` against
## the resolved shell rc file. The smoke targets an explicit host
## file under `/tmp/repro-vm-test/` so the test does not modify
## root's real shell rc.
##
## Gated by `defined(linux)` AND `REPRO_M69_SHELL_INTEGRATION_VM=1`.

import std/[os, strutils]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "shell.integration (POSIX)"

proc writeSentinel(gate: string) =
  let path = getEnv("REPRO_M69_VM_SENTINEL_FILE", SentinelDefault)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var f: File
  if open(f, path, fmAppend):
    try:
      f.writeLine("OK: " & gate)
    finally:
      close(f)

proc main() =
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_SHELL_INTEGRATION_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_SHELL_INTEGRATION_VM not set."
    quit(0)

  when defined(linux):
    let testRoot = "/tmp/repro-vm-test"
    if not dirExists(testRoot):
      createDir(testRoot)
    let hostFile = testRoot / "shell-rc-" &
      $getCurrentProcessId() & ".sh"
    if fileExists(hostFile):
      removeFile(hostFile)
    let blockId = "repro-m83-shell-integration"
    let content =
      "# Reprobuild M83 step 13 shell-integration smoke fragment\n" &
      "export REPRO_HOME_SHELL_INTEGRATION_SMOKE=1\n"

    # 1. Apply.
    discard applyShellIntegration(hostFile, blockId, content)
    doAssert fileExists(hostFile),
      "managed-block file not created"
    let after1 = readFile(hostFile)
    doAssert after1.contains("REPRO_HOME_SHELL_INTEGRATION_SMOKE"),
      "block body missing from on-disk file"
    doAssert after1.contains("repro-managed:" & blockId),
      "managed-block sentinel missing"

    # 2. Observe present.
    let obs = observeShellIntegration(hostFile, blockId)
    doAssert obs.present

    # 3. Destroy.
    destroyShellIntegration(hostFile, blockId)
    let after2 =
      if fileExists(hostFile): readFile(hostFile) else: ""
    doAssert not after2.contains("repro-managed:" & blockId),
      "managed-block sentinel still present after destroy"
    let obs2 = observeShellIntegration(hostFile, blockId)
    doAssert not obs2.present

    writeSentinel(GateName)
    echo "  [OK] shell.integration (POSIX) lifecycle"
  else:
    discard

main()

## M83 step 13 — disposable-WSL gate for the POSIX arm of
## `env.userPath`.
##
## On POSIX the driver writes a managed block to the resolved shell
## rc file (`~/.bashrc` / `~/.zshrc` / `~/.profile`), prepending the
## contributed entries to `$PATH` while preserving the host's
## pre-existing value. The smoke pins the host file via
## `REPRO_HOME_POSIX_PATH_RC` to `/tmp/repro-vm-test/path-rc-<pid>`
## so the test does not actually rewrite root's real `.bashrc`.
##
## Gated by `defined(linux)` AND `REPRO_M69_ENV_USER_PATH_VM=1`.

import std/[os, strutils]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "env.userPath (POSIX)"

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
    defined(linux) and getEnv("REPRO_M69_ENV_USER_PATH_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_ENV_USER_PATH_VM not set."
    quit(0)

  when defined(linux):
    let testRoot = "/tmp/repro-vm-test"
    if not dirExists(testRoot):
      createDir(testRoot)
    let hostFile = testRoot / "path-rc-" &
      $getCurrentProcessId() & ".sh"
    if fileExists(hostFile):
      removeFile(hostFile)

    let contribution = @["/opt/repro-m83-vm/bin"]

    # 1. Apply: write the managed block.
    discard applyUserPath(contribution, priorContribution = @[],
      hostFilePath = hostFile)
    doAssert fileExists(hostFile),
      "managed-block file not created"
    let after1 = readFile(hostFile)
    doAssert after1.contains("/opt/repro-m83-vm/bin"),
      "contribution entry missing from managed block"
    doAssert after1.contains("repro-managed:" & UserPathBlockId),
      "managed-block sentinel missing"

    # 2. Observe present (with the contribution).
    let obs = observeUserPath(contribution, hostFilePath = hostFile)
    doAssert obs.present

    # 3. Destroy: removeUserPathContribution should remove the block.
    removeUserPathContribution(contribution, hostFilePath = hostFile)
    let after2 =
      if fileExists(hostFile): readFile(hostFile) else: ""
    doAssert not after2.contains("repro-managed:" & UserPathBlockId),
      "managed-block sentinel still present after destroy"

    let obs2 = observeUserPath(contribution, hostFilePath = hostFile)
    doAssert not obs2.present

    writeSentinel(GateName)
    echo "  [OK] env.userPath (POSIX) lifecycle"
  else:
    discard

main()

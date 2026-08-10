## M83 step 13 — disposable-WSL gate for `linux.nixDaemonSetting`.
##
## Writes a `/etc/nix/nix.conf.d/` drop-in. Nix re-reads its config on
## each invocation; there is no daemon reload command, so the test
## is file-on-disk + drift + destroy.
##
## Gated by `defined(linux)` AND `REPRO_M69_NIX_VM=1`.

import std/[os, unittest]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.nixDaemonSetting"
const GateEnv = "REPRO_M69_NIX_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_NIX_VM not set."

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
  when defined(linux):
    let filename = "99-reprobuild-m83-vm-test-" &
      $getCurrentProcessId() & ".conf"
    let key = "max-jobs"
    let value = "auto"

    let op = PrivilegedOperation(kind: pokLinuxNixDaemonSetting,
      address: "nixDaemonSetting:" & key,
      nixKey: key,
      nixValue: value,
      nixFilename: filename,
      nixDestroy: false)
    let path = nixDaemonDropInPath(op)
    echo "  drop-in path: ", path

    discard applyLinuxNixDaemonSetting(op)
    doAssert fileExists(path),
      "expected nix drop-in " & path & " after apply"
    let liveBytes = readFile(path)
    doAssert liveBytes == nixDaemonDropInContent(key, value),
      "nix drop-in content mismatch: " & liveBytes

    let post = observeLinuxNixDaemonSetting(op)
    doAssert post.present
    doAssert post.digestHex ==
        posixDigestHexOfText(nixDaemonDropInContent(key, value)),
      "observe digest != desired digest"

    var destroyOp = op
    destroyOp.nixDestroy = true
    discard destroyLinuxNixDaemonSetting(destroyOp)
    doAssert not fileExists(path),
      "nix drop-in file still exists after destroy"

    writeSentinel(GateName)
    echo "  [OK] linux.nixDaemonSetting lifecycle"
  else:
    discard

suite "e2e_repro_infra_linux_nixdaemonsetting_vm":
  test "linux.nixDaemonSetting disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)

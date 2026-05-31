## M83 step 13 — disposable-WSL gate for `linux.tmpfilesRule`.
##
## Writes a `/etc/tmpfiles.d/` drop-in. `tmpfilesApplyNow` is set to
## `false` because `systemd-tmpfiles --create` requires the systemd
## machinery the disposable distro deliberately does not activate
## (same constraint as the M69 `systemd.systemUnit` `enable --now`
## scope — see that gate's header). The real `--create` exercise is
## deferred to a Hyper-V / real-Linux VM, consistent with the M69
## sandbox-deferred runtime paths.
##
## Gated by `defined(linux)` AND `REPRO_M69_TMPFILES_VM=1`.

import std/[os]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.tmpfilesRule"

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
    defined(linux) and getEnv("REPRO_M69_TMPFILES_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_TMPFILES_VM not set."
    quit(0)

  when defined(linux):
    let ruleName = "reprobuild-m83-vm-test-" &
      $getCurrentProcessId() & ".conf"
    # A benign tmpfiles entry under /tmp. Even if --create were run,
    # it would simply ensure a directory under /tmp exists with 0755.
    let ruleContent =
      "# Reprobuild M83 step 13 tmpfiles smoke entry\n" &
      "d /tmp/repro-vm-test-tmpfiles 0755 root root - -\n"

    let op = PrivilegedOperation(kind: pokLinuxTmpfilesRule,
      address: "tmpfilesRule:" & ruleName,
      tmpfilesName: ruleName,
      tmpfilesContent: ruleContent,
      tmpfilesApplyNow: false,
      tmpfilesDestroy: false)
    let path = tmpfilesRulePath(ruleName)
    echo "  rule path: ", path

    discard applyLinuxTmpfilesRule(op)
    doAssert fileExists(path),
      "expected tmpfiles fragment " & path & " after apply"
    doAssert readFile(path) == ruleContent,
      "tmpfiles content mismatch on disk"

    let post = observeLinuxTmpfilesRule(op)
    doAssert post.present
    doAssert post.digestHex == posixDigestHexOfText(ruleContent),
      "observe digest != desired digest"

    var destroyOp = op
    destroyOp.tmpfilesDestroy = true
    discard destroyLinuxTmpfilesRule(destroyOp)
    doAssert not fileExists(path),
      "tmpfiles fragment still exists after destroy"

    writeSentinel(GateName)
    echo "  [OK] linux.tmpfilesRule lifecycle"
  else:
    discard

main()

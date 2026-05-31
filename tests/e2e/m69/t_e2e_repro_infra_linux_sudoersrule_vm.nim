## M83 step 13 — disposable-WSL gate for `linux.sudoersRule`.
##
## Writes a sudoers fragment via the `.tmp` + `visudo -c` + atomic
## rename pattern; the driver's own apply path runs `visudo -c -f
## <tmp>` so this gate proves the validate-then-rename flow against
## the real `visudo` binary inside the disposable distro.
##
## Gated by `defined(linux)` AND `REPRO_M69_SUDOERS_VM=1`.

import std/[os]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.sudoersRule"

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
    defined(linux) and getEnv("REPRO_M69_SUDOERS_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_SUDOERS_VM not set."
    quit(0)

  when defined(linux):
    # sudoers.d basenames must NOT contain a '.' — the parser enforces
    # this. Use only letters/digits/dashes/underscores.
    let ruleName = "reprobuild-m83-vm-test-" & $getCurrentProcessId()
    # A benign sudoers fragment that visudo accepts. We grant a
    # non-existent user a no-op so we cannot actually break sudo.
    let ruleContent =
      "# Reprobuild M83 step 13 sudoers smoke fragment\n" &
      "Defaults:nobody !requiretty\n"

    let op = PrivilegedOperation(kind: pokLinuxSudoersRule,
      address: "sudoersRule:" & ruleName,
      sudoersName: ruleName,
      sudoersContent: ruleContent,
      sudoersDestroy: false)
    let path = sudoersRulePath(ruleName)
    echo "  rule path: ", path

    discard applyLinuxSudoersRule(op)
    doAssert fileExists(path),
      "expected sudoers fragment " & path & " after apply"
    doAssert readFile(path) == ruleContent,
      "sudoers content mismatch on disk"

    let post = observeLinuxSudoersRule(op)
    doAssert post.present
    doAssert post.digestHex == posixDigestHexOfText(ruleContent),
      "observe digest != desired digest"

    var destroyOp = op
    destroyOp.sudoersDestroy = true
    discard destroyLinuxSudoersRule(destroyOp)
    doAssert not fileExists(path),
      "sudoers fragment still exists after destroy"

    writeSentinel(GateName)
    echo "  [OK] linux.sudoersRule lifecycle"
  else:
    discard

main()

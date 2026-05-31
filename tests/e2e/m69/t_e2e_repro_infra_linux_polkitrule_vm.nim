## M83 step 13 — disposable-WSL gate for `linux.polkitRule`.
##
## Extends the M69 WSL harness with the post-M69 Linux drivers. The
## polkit driver writes a JS rule under `/etc/polkit-1/rules.d/` and
## relies on polkit's inotify watcher to reload — there is no
## reload command. We exercise file-on-disk + drift + destroy.
##
## ===========================================================================
## DESTRUCTIVE GATE — REQUIRES A LINUX SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## Gated by `defined(linux)` AND `REPRO_M69_POLKIT_VM=1`. Off-sandbox the
## program is a no-op smoke (exit 0).

import std/[os]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.polkitRule"

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
    defined(linux) and getEnv("REPRO_M69_POLKIT_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_POLKIT_VM not set."
    quit(0)

  when defined(linux):
    let ruleName = "99-reprobuild-m83-vm-test-" &
      $getCurrentProcessId() & ".rules"
    let ruleContent =
      "// Reprobuild M83 step 13 polkit smoke rule. No-op.\n" &
      "polkit.addRule(function(action, subject) {\n" &
      "  return polkit.Result.NOT_HANDLED;\n" &
      "});\n"

    let op = PrivilegedOperation(kind: pokLinuxPolkitRule,
      address: "polkitRule:" & ruleName,
      polkitName: ruleName,
      polkitContent: ruleContent,
      polkitDestroy: false)
    let path = polkitRulePath(ruleName)
    echo "  rule path: ", path

    discard applyLinuxPolkitRule(op)
    doAssert fileExists(path),
      "expected polkit rule file " & path & " after apply"
    doAssert readFile(path) == ruleContent,
      "polkit rule content mismatch on disk"

    let post = observeLinuxPolkitRule(op)
    doAssert post.present
    doAssert post.digestHex == posixDigestHexOfText(ruleContent),
      "observe digest != desired digest"

    var destroyOp = op
    destroyOp.polkitDestroy = true
    discard destroyLinuxPolkitRule(destroyOp)
    doAssert not fileExists(path),
      "polkit rule file still exists after destroy"

    writeSentinel(GateName)
    echo "  [OK] linux.polkitRule lifecycle"
  else:
    discard

main()

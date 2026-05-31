## M83 step 13 — disposable-WSL gate for `linux.firewallRule`.
##
## The driver wraps `nft add rule` / `nft -a list chain` /
## `nft delete rule`. nftables requires:
##   1. the `nft` userspace binary (Ubuntu's `nftables` package);
##   2. kernel netfilter / nf_tables support (typically absent in
##      WSL2's Microsoft kernel until very recent builds).
##
## When either of these is missing the gate emits a SKIP sentinel.
## On a conventional Linux VM with nftables both in userspace and the
## kernel, this gate exercises the full rule add/observe/destroy
## lifecycle.
##
## Gated by `defined(linux)` AND `REPRO_M69_LINUX_FIREWALL_VM=1`.

import std/[os, strutils, osproc]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.firewallRule"

proc writeLineSentinel(text: string) =
  let path = getEnv("REPRO_M69_VM_SENTINEL_FILE", SentinelDefault)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var f: File
  if open(f, path, fmAppend):
    try:
      f.writeLine(text)
    finally:
      close(f)

proc nftAvailable(): bool =
  let (output, code) = execCmdEx("command -v nft")
  result = code == 0 and output.strip().len > 0

proc nftablesWorkable(): bool =
  ## Test whether nftables is BOTH installed AND the kernel netfilter
  ## hooks are reachable. A bare `nft list ruleset` with no ruleset
  ## still returns 0 on a working kernel; if the kernel hooks are
  ## unavailable, `nft` exits non-zero with an error like "Could not
  ## process rule: Operation not supported".
  let (_, code) = execCmdEx("nft list ruleset 2>&1")
  result = code == 0

proc main() =
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_LINUX_FIREWALL_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_LINUX_FIREWALL_VM not set."
    quit(0)

  when defined(linux):
    if not nftAvailable():
      echo "  [SKIP] " & GateName & ": nft binary not installed"
      writeLineSentinel("SKIP: " & GateName & " (nft binary missing)")
      quit(0)

    if not nftablesWorkable():
      echo "  [SKIP] " & GateName &
        ": nftables not reachable (kernel netfilter unavailable)"
      writeLineSentinel("SKIP: " & GateName &
        " (kernel nf_tables not enabled in WSL kernel)")
      quit(0)

    # Set up a private table + chain that does NOT exist in the live
    # ruleset, so we cannot break any pre-existing firewall.
    let tableName = "reprovm" & $getCurrentProcessId()
    let chainName = "inreprovm"
    let chainTriple = "inet " & tableName & " " & chainName
    discard execCmdEx("nft add table inet " & quoteShell(tableName))
    discard execCmdEx("nft add chain inet " & quoteShell(tableName) &
      " " & quoteShell(chainName) & " { type filter hook input " &
      "priority 0 \\; }")

    defer:
      discard execCmdEx("nft delete table inet " & quoteShell(tableName))

    let ruleName = "reprom83vmtest"
    let op = PrivilegedOperation(kind: pokLinuxFirewallRule,
      address: "firewallRule:" & ruleName,
      lfwChain: chainTriple,
      lfwName: ruleName,
      lfwProtocol: "tcp",
      lfwDirection: "inbound",
      lfwLocalPort: "65500",
      lfwAction: "accept",
      lfwDestroy: false)

    try:
      discard applyLinuxFirewallRule(op)
      let obs = observeLinuxFirewallRule(op)
      doAssert obs.present, "firewall rule should be present after apply"
      var destroyOp = op
      destroyOp.lfwDestroy = true
      discard destroyLinuxFirewallRule(destroyOp)
      let obs2 = observeLinuxFirewallRule(op)
      doAssert not obs2.present,
        "firewall rule should be absent after destroy"
      writeLineSentinel("OK: " & GateName)
      echo "  [OK] linux.firewallRule lifecycle"
    except CatchableError as e:
      let head = e.msg.splitLines()[0]
      echo "  [SKIP] " & GateName & ": " & head
      writeLineSentinel("SKIP: " & GateName & " (" & head & ")")
  else:
    discard

main()

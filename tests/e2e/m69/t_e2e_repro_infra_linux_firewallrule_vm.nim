## M83 step 13 — disposable-WSL gate for `linux.firewallRule`.
##
## The driver wraps `nft add rule` / `nft -a list chain` /
## `nft delete rule`. As of the M83 step-13 bug-fix bundle:
##   1. the `nft` userspace binary ships in Ubuntu's `nftables`
##      package (the harness installs it in stage A);
##   2. WSL2's Microsoft kernel exposes the netfilter / nf_tables
##      hooks the driver needs (verified against Ubuntu 22.04 +
##      modern WSL2 kernels).
##
## Missing-binary is a HARD FAIL — the apt-get installed it. A
## missing kernel hook is also a HARD FAIL — every supported WSL
## kernel ships nftables. A driver exception is a HARD FAIL — the
## previous `SKIP on CatchableError` swept real bugs (the
## `:`-in-comment quoting bug fixed in this bundle) under the rug.
##
## Gated by `defined(linux)` AND `REPRO_M69_LINUX_FIREWALL_VM=1`.

import std/[os, strutils, osproc, unittest]

import repro_elevation

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.firewallRule"
const GateEnv = "REPRO_M69_LINUX_FIREWALL_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_LINUX_FIREWALL_VM not set."

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
  when defined(linux):
    if not nftAvailable():
      echo "  [FAIL] " & GateName & ": nft binary not installed"
      writeLineSentinel("FAIL: " & GateName &
        " (nft binary missing — install nftables)")
      quit(1)

    if not nftablesWorkable():
      echo "  [FAIL] " & GateName &
        ": nftables not reachable (kernel netfilter unavailable)"
      writeLineSentinel("FAIL: " & GateName &
        " (kernel nf_tables hooks unavailable in this WSL kernel)")
      quit(1)

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
      # A driver exception is a real bug — fail HARD instead of
      # SKIPping. Sweeping driver bugs under the rug as SKIPs is
      # exactly what the M83 step-13 bug-fix bundle existed to
      # undo (the `:`-in-comment bug pretended to be an
      # environment limitation for months).
      let head = e.msg.splitLines()[0]
      echo "  [FAIL] " & GateName & ": " & head
      writeLineSentinel("FAIL: " & GateName & " (" & head & ")")
      # `raise`, not `quit(1)`. A bare `quit` from inside a test body
      # tears the process down before `testEnded` writes the protocol
      # result document, so the runner has nothing to read and has to
      # fall back to the exit code — which loses the message, the
      # checkpoints and the case's identity. Re-raising lets `unittest`
      # record a FAILED case carrying the driver's own diagnostic.
      raise
  else:
    discard

suite "e2e_repro_infra_linux_firewallrule_vm":
  test "linux.firewallRule disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)

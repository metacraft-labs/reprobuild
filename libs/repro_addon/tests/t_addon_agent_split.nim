## The deploy agent's fetch/apply split on an add-on host (spec §9.1), the
## parts that need no guest: the staging hand-off by descriptor, the apply
## unit's refusals, the configuration, and the units generation 0 renders.
## The units' confinement itself (egress, no network, no compiler as root)
## is the VM gates' (``tests/e2e/addon/t_e2e_addon_agent_*``).
##
## Mocks: none. The fetch runs the real selection over real signed
## manifests read from plain-path sources; the copy runs over a real
## directory tree with real symbolic links planted in it.

import std/[os, strutils, times, unittest]

import repro_infra/profile
import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import repro_addon/agent_split
import repro_addon/generation0

let root = getTempDir() / ("addon-agent-split-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc signed(kp: PeerKeypair; seq: uint64; text: string): seq[byte] =
  var m = DeployManifest(target: "h1", sequence: seq, deploymentId: "d" & $seq,
    profileText: text, issuedAt: uint64(getTime().toUnix()),
    maxAgeSeconds: 3600)
  signManifest(kp, m)
  encodeManifest(m)

suite "agent split: configuration and units":
  test "agent.conf round-trips and refuses an unknown key":
    let a = AgentUnitsInputs(target: "h1", sources: @["http://10.0.2.2:8080/h1/latest.rdm"],
      allowedAddresses: @["10.0.2.2"])
    let c = parseAgentConf(renderAgentConf(a))
    check c.target == "h1"
    check c.sources == a.sources
    expect ValueError:
      discard parseAgentConf("target = x\nsource = y\nbogus = 1\n")
    expect ValueError:
      discard parseAgentConf("target = x\n")

  test "the units carry the split's confinement":
    let a = AgentUnitsInputs(target: "h1", sources: @["http://10.0.2.2:8080/m"],
      allowedAddresses: @["10.0.2.2"])
    let fetch = agentFetchUnit("/repro/store/x/bin/repro", a)
    let apply = agentApplyUnit("/repro/store/x/bin/repro")
    for line in ["DynamicUser=yes", "CapabilityBoundingSet=\n",
                 "ProtectSystem=strict", "InaccessiblePaths=-/var/lib/repro",
                 "OnSuccess=" & AgentApplyUnit]:
      checkpoint line
      check line in fetch
    # Unconditional: agent-fetch-unrestricted-egress and
    # agent-apply-has-network each turn this test red.
    check "IPAddressDeny=any" in fetch
    check "IPAddressAllow=10.0.2.2" in fetch
    check "PrivateNetwork=yes" in apply
    check "IPAddressDeny=any" in apply
    check "MemorySwapMax=0" in apply
    # Bounded memory that fits a small host (spec §9.1; 1 GB rpi2).
    check ("MemoryMax=" & AgentApplyMemoryMax & "\n") in apply
    check "LimitMEMLOCK=infinity" in apply
    check "CAP_NET_ADMIN" notin apply
    # The two broad capabilities it keeps are bounded (A8 review, low):
    # mount namespaces only, and no ptrace-class system calls.
    check "RestrictNamespaces=mnt" in apply
    check "@debug" in apply and "SystemCallFilter=~" in apply
    # Neither unit resolves names through the resolver's sockets (H2).
    for u in [fetch, apply]:
      check "/run/systemd/resolve" in u
    check "/run/dbus" in fetch   # red under agent-dns-via-resolved
    # Inline-safe: the canonical text cannot carry quotes or braces.
    assertInlineSafe("fetch", fetch)
    assertInlineSafe("apply", apply)

  test "generation 0 has the agent's objects only when a target is given":
    let base = Gen0Inputs(reproExe: "/repro/store/x/bin/repro")
    for o in generation0Objects(base):
      check o.path notin [AgentConfPath, unitPath(AgentFetchUnit)]
    var withAgent = base
    withAgent.agent = AgentUnitsInputs(target: "h1",
      sources: @["http://example.invalid/m"], allowedAddresses: @["192.0.2.1"],
      hosts: @[(address: "192.0.2.1", name: "example.invalid")])
    var paths: seq[string]
    for o in generation0Objects(withAgent): paths.add(o.path)
    for p in [AgentConfPath, AgentHostsPath, unitPath(AgentFetchUnit),
              unitPath(AgentFetchTimer), unitPath(AgentApplyUnit)]:
      check p in paths

suite "agent split: the apply unit's refusals":
  # Each test states the spec's behaviour (§7.5, §4.5, §9.1; threat model
  # G27) unconditionally. A falsifying build (-d:reproAddonMutation=...,
  # scripts/run_addon_unit_mutation.sh) must turn the test it names red:
  #   agent-allows-management-path            every test below but the
  #                                           prefix-widening one
  #   agent-management-path-names-only        the Id/Names and Alias= tests
  #   agent-management-path-ignores-unit-names  the Id/Names test
  #   agent-management-path-ignores-install-alias  the Alias= test
  #   agent-management-path-ignores-templates the template-instance test
  #   agent-apply-skips-recheck               the prefix-widening test
  let noNames: UnitNamesResolver = proc(u: string): seq[string] {.gcsafe.} = @[]

  test "sshd drop-ins and their managed prefix are refused; other files are not":
    let p = parseSystemProfile("fs.systemFile {\n  path = \"/etc/ssh/sshd_config.d/x.conf\"\n" &
      "  content = \"PermitRootLogin no\"\n}\n" &
      "addOn { managedEtcPrefixes = [\"/etc/ssh/sshd_config.d/\"] }\n")
    check "management path" in managementPathRefusal(p, noNames)
    let ok = parseSystemProfile("fs.systemFile {\n  path = \"/etc/app/x.conf\"\n" &
      "  content = \"a\"\n}\naddOn { managedEtcPrefixes = [\"/etc/app/\"] }\n")
    check managementPathRefusal(ok, noNames) == ""

  test "every file of the management path is refused":
    for path in ["/etc/ssh/sshd_config", "/etc/nologin",
                 "/etc/ssh/ssh_host_ed25519_key", "/etc/ssh/authorized_keys/root",
                 "/etc/firewalld/zones/public.xml", "/etc/systemd/networkd.conf",
                 "/etc/systemd/networkd.conf.d/x.conf", "/etc/hosts.deny",
                 "/etc/iptables/rules.v4", "/etc/systemd/network/10-a.link"]:
      checkpoint path
      let p = SystemProfile(resources: @[SystemResource(kind: srkFsSystemFile,
        address: "systemFile:" & path, sfPath: path)])
      check managementPathRefusal(p, noNames).len > 0

  test "the PAM stacks of sshd and login, and what they include, are refused":
    # /etc/pam.d/sshd and /etc/pam.d/login on Debian 12/13 and Ubuntu
    # 24.04/26.04 @include the common-* files; their modules read the
    # /etc/security files and /etc/securetty below (spec §9.1).
    for path in ["/etc/pam.d/sshd", "/etc/pam.d/login", "/etc/pam.d/other",
                 "/etc/pam.conf", "/etc/pam.d/common-auth",
                 "/etc/pam.d/common-account", "/etc/pam.d/common-session",
                 "/etc/pam.d/common-session-noninteractive",
                 "/etc/pam.d/common-password",
                 "/etc/security/access.conf", "/etc/security/limits.conf",
                 "/etc/security/limits.d/90-nproc.conf",
                 "/etc/security/time.conf", "/etc/security/namespace.conf",
                 "/etc/security/namespace.d/x.conf",
                 "/etc/security/faillock.conf", "/etc/securetty"]:
      checkpoint path
      let p = SystemProfile(resources: @[SystemResource(kind: srkFsSystemFile,
        address: "systemFile:" & path, sfPath: path)])
      check managementPathRefusal(p, noNames).len > 0
    # A dpkg diversion of one is the same write.
    let diversion = SystemProfile(resources: @[SystemResource(
      kind: srkLinuxDpkgDiversion, address: "diversion:ca",
      ddPath: "/etc/pam.d/common-auth")])
    check managementPathRefusal(diversion, noNames).len > 0
    # The PAM stack of a service that is not a login path is not refused.
    for path in ["/etc/pam.d/cron", "/etc/pam.d/app-x"]:
      checkpoint path
      let p = SystemProfile(resources: @[SystemResource(kind: srkFsSystemFile,
        address: "systemFile:" & path, sfPath: path)])
      check managementPathRefusal(p, noNames) == ""

  test "a unit is matched by every name systemd knows it under (Id, Names)":
    let aliased: UnitNamesResolver = proc(u: string): seq[string] {.gcsafe.} =
      if u == "my-login.service": @["my-login.service", "sshd.service"] else: @[]
    let dropIn = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemDropIn, address: "dropIn:my-login",
      diUnit: "my-login.service", diName: "10-x.conf")])
    check "sshd.service" in managementPathRefusal(dropIn, aliased)
    check managementPathRefusal(dropIn, noNames) == ""

  test "a unit is matched by the Alias= its own [Install] would create":
    let installAlias = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemUnit, address: "unit:fw", suName: "fw.service",
      suContent: "[Service]\nExecStart=/bin/true\n[Install]\nAlias=nftables.service\n")])
    check "nftables.service" in managementPathRefusal(installAlias, noNames)
    let plain = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemUnit, address: "unit:app", suName: "app.service",
      suContent: "[Service]\nExecStart=/bin/true\n[Install]\nAlias=app2.service\n")])
    check managementPathRefusal(plain, noNames) == ""

  test "a template instance is matched by its template":
    let instance = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemDropIn, address: "dropIn:ssh@", diUnit: "ssh@x.service",
      diName: "10-x.conf")])
    check "ssh@x.service" in managementPathRefusal(instance, noNames)
    let other = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemDropIn, address: "dropIn:app@", diUnit: "app@x.service",
      diName: "10-x.conf")])
    check managementPathRefusal(other, noNames) == ""

  test "a compiled profile may not widen the managed prefixes":
    let current = parseSystemProfile(
      "addOn { managedEtcPrefixes = [\"/etc/app/\"] }\n")
    let same = parseSystemProfile(
      "addOn { managedEtcPrefixes = [\"/etc/app/\"] }\n")
    let wider = parseSystemProfile(
      "addOn { managedEtcPrefixes = [\"/etc/app/\", \"/etc/shadow\"] }\n")
    check agentPrefixRefusal(same, current) == ""
    check "/etc/shadow" in agentPrefixRefusal(wider, current)

suite "agent split: the staging hand-off":
  let kp = peerAuth.generateKeypair()
  let anchors = anchorsFromKeypairs([kp.publicKey])

  test "the fetch stages the selected envelope byte for byte":
    let src = root / "src"
    createDir(src)
    let bytes = signed(kp, 5, "")
    var s = newString(bytes.len)
    for i, b in bytes: s[i] = char(b)
    writeFile(src / "m.rdm", s)
    let staging = root / "staging"
    let r = runAgentFetch(AgentConf(target: "h1", sources: @[src / "m.rdm"]),
                          anchors, staging, AgentDeps())
    check r.kind == "staged"
    let latest = readFile(staging / StagingLatestName).strip()
    check readFile(staging / latest / StagedManifestName) == s
    let copy = root / "copy"
    check copyLatestStaging(staging, copy) == latest
    check readFile(copy / StagedManifestName) == s

  test "no manifest stages the fetch's own outcome":
    let staging = root / "staging-empty"
    let r = runAgentFetch(AgentConf(target: "h1",
      sources: @[root / "absent.rdm"]), anchors, staging, AgentDeps())
    check r.kind == "aoWaiting"
    let copy = root / "copy-empty"
    discard copyLatestStaging(staging, copy)
    check readFile(copy / StagingResultName).startsWith("aoWaiting")

  test "a symbolic link anywhere in the staging area is refused":
    let staging = root / "staging-link"
    createDir(staging / "s1" / "outputs")
    writeFile(staging / "s1" / StagedManifestName, "x")
    writeFile(staging / StagingLatestName, "s1\n")
    createSymlink("/etc/passwd", staging / "s1" / "outputs" / "leak")
    expect EAgentStaging:
      discard copyLatestStaging(staging, root / "copy-link")
    # A link as the latest pointer, and a link as the staging directory.
    removeFile(staging / "s1" / "outputs" / "leak")
    removeFile(staging / StagingLatestName)
    writeFile(root / "elsewhere", "s1\n")
    createSymlink(root / "elsewhere", staging / StagingLatestName)
    expect EAgentStaging:
      discard copyLatestStaging(staging, root / "copy-link2")
    removeFile(staging / StagingLatestName)
    writeFile(staging / StagingLatestName, "s2\n")
    createSymlink(staging / "s1", staging / "s2")
    expect EAgentStaging:
      discard copyLatestStaging(staging, root / "copy-link3")
    # A malformed pointer.
    writeFile(staging / StagingLatestName, "../s1\n")
    expect EAgentStaging:
      discard copyLatestStaging(staging, root / "copy-link4")

  test "the copy is private and independent of the staging area":
    let staging = root / "staging-swap"
    createDir(staging / "s1")
    writeFile(staging / "s1" / StagedManifestName, "verified")
    writeFile(staging / StagingLatestName, "s1\n")
    let copy = root / "copy-swap"
    discard copyLatestStaging(staging, copy)
    writeFile(staging / "s1" / StagedManifestName, "swapped")
    check readFile(copy / StagedManifestName) == "verified"
    check getFilePermissions(copy) == {fpUserRead, fpUserWrite, fpUserExec}

removeDir(root)

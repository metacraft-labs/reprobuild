## M83 Phase A smoke tests for the `repro_profile` macro library.
## Covers the types, the JSON round-trip, the resource constructors,
## the predicate combinators, and the string helpers (`unindent`,
## `interpolate`). The integration test under `tests/e2e/m83/`
## exercises the full profile-shape macros against real `home.nim`
## fixtures compiled via `nim c -r`.

import std/[tables, unittest]
from std/strutils as su import nil

import repro_profile
from repro_profile/strings as profileStrings import nil

# ---------------------------------------------------------------------
# JSON encode / decode round-trip.
# ---------------------------------------------------------------------

suite "ProfileIntent JSON round-trip":

  test "empty profile round-trips":
    var p: ProfileIntent
    p.name = "empty"
    let js = emitProfileIntentJson(p)
    let p2 = parseProfileIntentJson(js)
    check p2.name == "empty"
    check p2.activities.len == 0
    check p2.configOverrides.len == 0
    check p2.hosts.len == 0
    check p2.resources.len == 0

  test "profile with activities + packages round-trips":
    var p: ProfileIntent
    p.name = "with-acts"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "neovim"),
      ActivityElement(kind: aekPackageRef, pkgName: "tmux"),
    ])
    let js = emitProfileIntentJson(p)
    let p2 = parseProfileIntentJson(js)
    check p2.name == "with-acts"
    check p2.activities.len == 1
    check p2.activities[0].name == "default"
    check p2.activities[0].body.len == 2
    check p2.activities[0].body[0].kind == aekPackageRef
    check p2.activities[0].body[0].pkgName == "neovim"

  test "when-guard activity element round-trips":
    var p: ProfileIntent
    p.name = "guarded"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekWhenGuard,
        predicate: PredicateExpr(expr: "windows"),
        guardedBody: @[ActivityElement(kind: aekPackageRef,
          pkgName: "windows-terminal")])
    ])
    let js = emitProfileIntentJson(p)
    let p2 = parseProfileIntentJson(js)
    check p2.activities[0].body[0].kind == aekWhenGuard
    check p2.activities[0].body[0].predicate.expr == "windows"
    check p2.activities[0].body[0].guardedBody.len == 1
    check p2.activities[0].body[0].guardedBody[0].pkgName ==
      "windows-terminal"

  test "config overrides of all four kinds round-trip":
    var p: ProfileIntent
    p.name = "cfg"
    p.configOverrides.add ConfigOverride(pkg: "git", key: "userName",
      value: strValue("Zahary"))
    p.configOverrides.add ConfigOverride(pkg: "git", key: "depth",
      value: intValue(50))
    p.configOverrides.add ConfigOverride(pkg: "tmux", key: "mouse",
      value: boolValue(true))
    p.configOverrides.add ConfigOverride(pkg: "neovim", key: "theme",
      value: exprValue("if windows: \"dark\" else: \"light\""))
    let js = emitProfileIntentJson(p)
    let p2 = parseProfileIntentJson(js)
    check p2.configOverrides.len == 4
    check p2.configOverrides[0].value.kind == cvkString
    check p2.configOverrides[0].value.s == "Zahary"
    check p2.configOverrides[1].value.kind == cvkInt
    check p2.configOverrides[1].value.i == 50
    check p2.configOverrides[2].value.kind == cvkBool
    check p2.configOverrides[2].value.b == true
    check p2.configOverrides[3].value.kind == cvkExpr

  test "hosts table round-trips with sorted key order":
    var p: ProfileIntent
    p.name = "hh"
    p.hosts["zeta"] = @["develop"]
    p.hosts["alpha"] = @["default", "develop"]
    let js = emitProfileIntentJson(p)
    # encoder sorts host keys lexicographically
    check su.find(js, "\"alpha\"") < su.find(js, "\"zeta\"")
    let p2 = parseProfileIntentJson(js)
    check p2.hosts["alpha"] == @["default", "develop"]
    check p2.hosts["zeta"] == @["develop"]

  test "resources with mixed field kinds round-trip":
    var p: ProfileIntent
    p.name = "res"
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField("PATH")
    fields["contribute"] = listField(@["/usr/local/bin", "/opt/bin"])
    fields["isPathList"] = boolField(true)
    fields["priority"] = intField(10)
    fields["fallback"] = exprField("if windows: \".\" else: \"\"")
    p.resources.add ResourceIntent(kind: "env.systemVariable",
      address: "env.systemVariable:PATH",
      fields: fields,
      dependsOn: @[ResourceAddress(kind: "fs.userFile",
        name: "~/.profile")])
    let js = emitProfileIntentJson(p)
    let p2 = parseProfileIntentJson(js)
    check p2.resources.len == 1
    check p2.resources[0].kind == "env.systemVariable"
    check p2.resources[0].address == "env.systemVariable:PATH"
    check p2.resources[0].fields["name"].s == "PATH"
    check p2.resources[0].fields["contribute"].items.len == 2
    check p2.resources[0].fields["isPathList"].b == true
    check p2.resources[0].fields["priority"].i == 10
    check p2.resources[0].fields["fallback"].kind == fvkExpr
    check p2.resources[0].dependsOn.len == 1
    check p2.resources[0].dependsOn[0].kind == "fs.userFile"
    check p2.resources[0].dependsOn[0].name == "~/.profile"

  test "json output is deterministic across runs":
    var p: ProfileIntent
    p.name = "det"
    p.hosts["b"] = @["x"]
    p.hosts["a"] = @["y"]
    let j1 = emitProfileIntentJson(p)
    let j2 = emitProfileIntentJson(p)
    check j1 == j2

  test "json escapes special characters":
    var p: ProfileIntent
    p.name = "esc\"\\\nname"
    let js = emitProfileIntentJson(p)
    let p2 = parseProfileIntentJson(js)
    check p2.name == "esc\"\\\nname"

# ---------------------------------------------------------------------
# Resource constructor templates.
# ---------------------------------------------------------------------

suite "Resource constructors":

  test "envUserPath produces env.userPath kind + fields":
    var target: seq[ResourceIntent] = @[]
    envUserPath(target, entries = "/opt/bin")
    check target.len == 1
    check target[0].kind == "env.userPath"
    check target[0].fields["entries"].s == "/opt/bin"
    check target[0].address == "env.userPath:/opt/bin"

  test "envUserVariable with auto-address":
    var target: seq[ResourceIntent] = @[]
    envUserVariable(target, name = "EDITOR", value = "nvim")
    check target.len == 1
    check target[0].kind == "env.userVariable"
    check target[0].address == "env.userVariable:EDITOR"
    check target[0].fields["name"].s == "EDITOR"
    check target[0].fields["value"].s == "nvim"
    check target[0].fields["valueKind"].s == "string"

  test "fsManagedBlock with explicit address overrides auto-address":
    var target: seq[ResourceIntent] = @[]
    fsManagedBlock(target,
      hostFile = "~/.bashrc", blockId = "repro-managed",
      content = "export FOO=bar",
      address = "fs.managedBlock:bashrc-foo")
    check target.len == 1
    check target[0].address == "fs.managedBlock:bashrc-foo"
    check target[0].fields["blockId"].s == "repro-managed"

  test "shellIntegration":
    var target: seq[ResourceIntent] = @[]
    shellIntegration(target,
      hostFile = "~/.zshrc", blockId = "starship",
      content = "eval $(starship init zsh)")
    check target[0].kind == "shell.integration"

  test "windowsRegistryValueHKCU records kind symbol":
    var target: seq[ResourceIntent] = @[]
    windowsRegistryValueHKCU(target,
      key = "Software\\MyApp",
      name = "Foo",
      kind = dword,
      value = "1")
    check target[0].kind == "windows.registryValueHKCU"
    check target[0].fields["kind"].s == "dword"
    check target[0].fields["value"].s == "1"

  test "windowsStartup":
    var target: seq[ResourceIntent] = @[]
    windowsStartup(target, name = "myapp", command = "C:\\app.exe")
    check target[0].kind == "windows.startup"
    check target[0].fields["command"].s == "C:\\app.exe"

  test "fsUserFile with executable default false":
    var target: seq[ResourceIntent] = @[]
    fsUserFile(target, hostFile = "~/bin/run.sh", content = "echo hi")
    check target[0].kind == "fs.userFile"
    check target[0].fields["mode"].s == "0644"
    check target[0].fields["executable"].b == false

  test "fsUserFile with executable = true":
    var target: seq[ResourceIntent] = @[]
    fsUserFile(target, hostFile = "~/bin/run.sh", content = "echo hi",
      mode = "0755", executable = true)
    check target[0].fields["executable"].b == true
    check target[0].fields["mode"].s == "0755"

  test "windowsOptionalFeature":
    var target: seq[ResourceIntent] = @[]
    windowsOptionalFeature(target, name = "Microsoft-Hyper-V")
    check target[0].kind == "windows.optionalFeature"
    check target[0].fields["enabled"].b == true

  test "windowsCapability":
    var target: seq[ResourceIntent] = @[]
    windowsCapability(target, name = "OpenSSH.Server~~~~0.0.1.0")
    check target[0].kind == "windows.capability"
    check target[0].fields["installed"].b == true

  test "windowsService records start type + state symbols":
    var target: seq[ResourceIntent] = @[]
    windowsService(target, name = "OpenSSHd",
      startType = Automatic, state = Running)
    check target[0].kind == "windows.service"
    check target[0].fields["startType"].s == "Automatic"
    check target[0].fields["state"].s == "Running"

  test "windowsFirewallRule records firewall rule fields":
    var target: seq[ResourceIntent] = @[]
    windowsFirewallRule(target,
      name = "OpenSSH-Server-In-TCP",
      protocol = "TCP",
      direction = "Inbound",
      action = "Allow",
      displayName = "OpenSSH Server (sshd)",
      localPort = "22",
      enabled = true,
      address = "opensshFirewallRule")
    check target.len == 1
    check target[0].kind == "windows.firewallRule"
    check target[0].address == "opensshFirewallRule"
    check target[0].fields["name"].s == "OpenSSH-Server-In-TCP"
    check target[0].fields["displayName"].s == "OpenSSH Server (sshd)"
    check target[0].fields["protocol"].s == "TCP"
    check target[0].fields["direction"].s == "Inbound"
    check target[0].fields["action"].s == "Allow"
    check target[0].fields["localPort"].s == "22"
    check target[0].fields["enabled"].b == true

  test "windowsFirewallRule defaults displayName / localPort / enabled":
    var target: seq[ResourceIntent] = @[]
    windowsFirewallRule(target,
      name = "Bare-Rule",
      protocol = "UDP",
      direction = "Outbound",
      action = "Block")
    check target.len == 1
    check target[0].fields["displayName"].s == ""
    check target[0].fields["localPort"].s == "Any"
    check target[0].fields["enabled"].b == true

  test "windowsAcl records ACL fields":
    var target: seq[ResourceIntent] = @[]
    windowsAcl(target,
      path = "C:\\Users\\Zahary\\.ssh",
      accessControlEntries = @[
        "BUILTIN\\Administrators:(OI)(CI)(F)",
        "NT AUTHORITY\\SYSTEM:(OI)(CI)(F)",
        "Zahary:(OI)(CI)(F)"],
      owner = "BUILTIN\\Administrators",
      inheritanceMode = "disabled-replace",
      address = "userSshDirectoryAcl")
    check target.len == 1
    check target[0].kind == "windows.acl"
    check target[0].address == "userSshDirectoryAcl"
    check target[0].fields["path"].s == "C:\\Users\\Zahary\\.ssh"
    check target[0].fields["owner"].s == "BUILTIN\\Administrators"
    check target[0].fields["inheritanceMode"].s == "disabled-replace"
    check target[0].fields["accessControlEntries"].items.len == 3
    check target[0].fields["accessControlEntries"].items[2] ==
      "Zahary:(OI)(CI)(F)"

  test "windowsAcl defaults owner / inheritanceMode":
    var target: seq[ResourceIntent] = @[]
    windowsAcl(target,
      path = "C:\\foo",
      accessControlEntries = @["Users:(F)"])
    check target.len == 1
    check target[0].fields["owner"].s == ""
    check target[0].fields["inheritanceMode"].s == "enabled"

  test "osTimezone records the IANA tz under the tz field":
    var target: seq[ResourceIntent] = @[]
    osTimezone(target,
      tz = "Europe/Sofia",
      address = "userTimezone")
    check target.len == 1
    check target[0].kind == "os.timezone"
    check target[0].address == "userTimezone"
    check target[0].fields["tz"].s == "Europe/Sofia"

  test "osTimezone auto-addresses from the tz value when address is empty":
    var target: seq[ResourceIntent] = @[]
    osTimezone(target, tz = "America/Los_Angeles")
    check target.len == 1
    check target[0].address == "os.timezone:America/Los_Angeles"

  test "osHostname records the hostname under the hostname field":
    var target: seq[ResourceIntent] = @[]
    osHostname(target,
      hostname = "MyDevBox",
      address = "userHostname")
    check target.len == 1
    check target[0].kind == "os.hostname"
    check target[0].address == "userHostname"
    check target[0].fields["hostname"].s == "MyDevBox"

  test "osHostname auto-addresses from the hostname value when address is empty":
    var target: seq[ResourceIntent] = @[]
    osHostname(target, hostname = "MyDevBox")
    check target.len == 1
    check target[0].address == "os.hostname:MyDevBox"

  test "vscodeExtension records the extensions list and removeUnknown flag":
    var target: seq[ResourceIntent] = @[]
    vscodeExtension(target,
      extensions = @["vscodevim.vim", "ms-python.python"],
      removeUnknown = false,
      address = "vscodeExtensions")
    check target.len == 1
    check target[0].kind == "vscode.extension"
    check target[0].address == "vscodeExtensions"
    check target[0].fields["extensions"].items == @[
      "vscodevim.vim", "ms-python.python"]
    check target[0].fields["removeUnknown"].b == false

  test "vscodeExtension defaults removeUnknown to false":
    var target: seq[ResourceIntent] = @[]
    vscodeExtension(target,
      extensions = @["vscodevim.vim"])
    check target.len == 1
    check target[0].fields["removeUnknown"].b == false

  test "linuxSysctl records key / value / filename":
    var target: seq[ResourceIntent] = @[]
    linuxSysctl(target,
      key = "kernel.perf_event_paranoid",
      value = "1",
      filename = "10-perf.conf",
      address = "tune-perf")
    check target.len == 1
    check target[0].kind == "linux.sysctl"
    check target[0].address == "tune-perf"
    check target[0].fields["key"].s == "kernel.perf_event_paranoid"
    check target[0].fields["value"].s == "1"
    check target[0].fields["filename"].s == "10-perf.conf"

  test "linuxSysctl auto-addresses from the key when address is empty":
    var target: seq[ResourceIntent] = @[]
    linuxSysctl(target,
      key = "kernel.perf_event_paranoid",
      value = "1")
    check target.len == 1
    check target[0].address == "linux.sysctl:kernel.perf_event_paranoid"
    check target[0].fields["filename"].s == ""

  test "linuxUdevRule records name / content":
    var target: seq[ResourceIntent] = @[]
    linuxUdevRule(target,
      name = "99-my.rules",
      content = "KERNEL==\"event*\", MODE=\"0666\"\n",
      address = "my-udev-rule")
    check target.len == 1
    check target[0].kind == "linux.udevRule"
    check target[0].address == "my-udev-rule"
    check target[0].fields["name"].s == "99-my.rules"
    check target[0].fields["content"].s ==
      "KERNEL==\"event*\", MODE=\"0666\"\n"

  test "linuxUdevRule auto-addresses from the name when address is empty":
    var target: seq[ResourceIntent] = @[]
    linuxUdevRule(target,
      name = "99-my.rules",
      content = "x")
    check target.len == 1
    check target[0].address == "linux.udevRule:99-my.rules"

  test "linuxPolkitRule records name / content":
    var target: seq[ResourceIntent] = @[]
    linuxPolkitRule(target,
      name = "50-wheel.rules",
      content = "polkit.addRule(function() { return null; });\n",
      address = "wheel-admin")
    check target.len == 1
    check target[0].kind == "linux.polkitRule"
    check target[0].address == "wheel-admin"
    check target[0].fields["name"].s == "50-wheel.rules"
    check target[0].fields["content"].s ==
      "polkit.addRule(function() { return null; });\n"

  test "linuxPolkitRule auto-addresses from the name when address is empty":
    var target: seq[ResourceIntent] = @[]
    linuxPolkitRule(target,
      name = "50-my.rules",
      content = "x")
    check target.len == 1
    check target[0].address == "linux.polkitRule:50-my.rules"

  test "linuxTmpfilesRule records name / content / applyNow":
    var target: seq[ResourceIntent] = @[]
    linuxTmpfilesRule(target,
      name = "repro-cache.conf",
      content = "d /var/cache/repro 0755 root root - -\n",
      applyNow = false,
      address = "repro-cache")
    check target.len == 1
    check target[0].kind == "linux.tmpfilesRule"
    check target[0].address == "repro-cache"
    check target[0].fields["name"].s == "repro-cache.conf"
    check target[0].fields["content"].s ==
      "d /var/cache/repro 0755 root root - -\n"
    check target[0].fields["applyNow"].b == false

  test "linuxTmpfilesRule defaults applyNow to true and auto-addresses":
    var target: seq[ResourceIntent] = @[]
    linuxTmpfilesRule(target,
      name = "x.conf",
      content = "d /run/x 0755 root root - -")
    check target.len == 1
    check target[0].fields["applyNow"].b == true
    check target[0].address == "linux.tmpfilesRule:x.conf"

  test "linuxSudoersRule records name / content":
    var target: seq[ResourceIntent] = @[]
    linuxSudoersRule(target,
      name = "wheel-extra",
      content = "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n",
      address = "wheel-extra")
    check target.len == 1
    check target[0].kind == "linux.sudoersRule"
    check target[0].address == "wheel-extra"
    check target[0].fields["name"].s == "wheel-extra"
    check target[0].fields["content"].s ==
      "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n"

  test "linuxSudoersRule auto-addresses from the name when address is empty":
    var target: seq[ResourceIntent] = @[]
    linuxSudoersRule(target,
      name = "wheel-extra",
      content = "x")
    check target.len == 1
    check target[0].address == "linux.sudoersRule:wheel-extra"

  test "passwdGroup records name / gid / members":
    var target: seq[ResourceIntent] = @[]
    passwdGroup(target,
      name = "docker",
      gid = "998",
      members = @["alice", "bob"],
      address = "docker")
    check target.len == 1
    check target[0].kind == "passwd.group"
    check target[0].address == "docker"
    check target[0].fields["name"].s == "docker"
    check target[0].fields["gid"].s == "998"
    check target[0].fields["members"].items == @["alice", "bob"]

  test "passwdGroup auto-addresses from the name when address is empty":
    var target: seq[ResourceIntent] = @[]
    passwdGroup(target,
      name = "developers")
    check target.len == 1
    check target[0].address == "passwd.group:developers"
    # The optional `gid` / `members` fields are omitted entirely when
    # the caller left them at the defaults, keeping the intent minimal.
    check "gid" notin target[0].fields
    check "members" notin target[0].fields

  test "linuxNixDaemonSetting records key / value / filename":
    var target: seq[ResourceIntent] = @[]
    linuxNixDaemonSetting(target,
      key = "experimental-features",
      value = "nix-command flakes",
      filename = "10-flakes.conf",
      address = "ef")
    check target.len == 1
    check target[0].kind == "linux.nixDaemonSetting"
    check target[0].address == "ef"
    check target[0].fields["key"].s == "experimental-features"
    check target[0].fields["value"].s == "nix-command flakes"
    check target[0].fields["filename"].s == "10-flakes.conf"

  test "linuxNixDaemonSetting auto-addresses from the key when address empty":
    var target: seq[ResourceIntent] = @[]
    linuxNixDaemonSetting(target,
      key = "experimental-features",
      value = "nix-command")
    check target.len == 1
    check target[0].address ==
      "linux.nixDaemonSetting:experimental-features"

  test "systemdSystemTimer records name / content / enabled / state":
    var target: seq[ResourceIntent] = @[]
    systemdSystemTimer(target,
      name = "zfs-scrub.timer",
      content = "[Unit]\n[Timer]\nOnCalendar=weekly\n",
      enabled = true,
      state = "Running",
      address = "zfs-scrub.timer")
    check target.len == 1
    check target[0].kind == "systemd.systemTimer"
    check target[0].address == "zfs-scrub.timer"
    check target[0].fields["name"].s == "zfs-scrub.timer"
    check target[0].fields["enabled"].b == true
    check target[0].fields["state"].s == "Running"

  test "systemdSystemTimer auto-addresses from the name when address empty":
    var target: seq[ResourceIntent] = @[]
    systemdSystemTimer(target,
      name = "zfs-scrub.timer",
      content = "x")
    check target.len == 1
    check target[0].address == "systemd.systemTimer:zfs-scrub.timer"

  test "linuxFirewallRule records chain / name / protocol / port / action":
    var target: seq[ResourceIntent] = @[]
    linuxFirewallRule(target,
      chain = "inet filter input",
      name = "openssh",
      protocol = "tcp",
      action = "accept",
      direction = "inbound",
      localPort = "22",
      address = "openssh")
    check target.len == 1
    check target[0].kind == "linux.firewallRule"
    check target[0].address == "openssh"
    check target[0].fields["chain"].s == "inet filter input"
    check target[0].fields["name"].s == "openssh"
    check target[0].fields["protocol"].s == "tcp"
    check target[0].fields["direction"].s == "inbound"
    check target[0].fields["localPort"].s == "22"
    check target[0].fields["action"].s == "accept"

  test "linuxFirewallRule auto-addresses from the name when address empty":
    var target: seq[ResourceIntent] = @[]
    linuxFirewallRule(target,
      chain = "inet filter input",
      name = "openssh",
      protocol = "tcp",
      action = "accept",
      localPort = "22")
    check target.len == 1
    check target[0].address == "linux.firewallRule:openssh"

  test "windowsRegistryValueHKLM":
    var target: seq[ResourceIntent] = @[]
    windowsRegistryValueHKLM(target,
      key = "SYSTEM\\CurrentControlSet",
      name = "Foo",
      kind = string,
      value = "bar")
    check target[0].kind == "windows.registryValueHKLM"

  test "windowsVsInstaller":
    var target: seq[ResourceIntent] = @[]
    windowsVsInstaller(target,
      workloads = @["Microsoft.VisualStudio.Workload.NativeDesktop"],
      version = "17")
    check target[0].kind == "windows.vsInstaller"
    check target[0].fields["workloads"].items.len == 1

  test "macosSystemDefault":
    var target: seq[ResourceIntent] = @[]
    macosSystemDefault(target,
      domain = "NSGlobalDomain",
      key = "ApplePressAndHoldEnabled",
      value = "false",
      kind = bool)
    check target[0].kind == "macos.systemDefault"
    check target[0].fields["kind"].s == "bool"

  test "systemdSystemUnit":
    var target: seq[ResourceIntent] = @[]
    systemdSystemUnit(target, name = "myunit.service",
      content = "[Unit]\nDescription=test",
      enabled = true)
    check target[0].kind == "systemd.systemUnit"
    check target[0].fields["enabled"].b == true

  test "launchdSystemDaemon":
    var target: seq[ResourceIntent] = @[]
    launchdSystemDaemon(target, label = "com.example.myd",
      programArgs = @["/usr/local/bin/myd", "--foreground"])
    check target[0].kind == "launchd.systemDaemon"
    check target[0].fields["programArgs"].items.len == 2

  test "M83 step 4b: systemdUserUnit records every field":
    var target: seq[ResourceIntent] = @[]
    systemdUserUnit(target,
      name = "gpg-agent.service",
      content = "[Unit]\nDescription=gpg-agent\n[Service]\nExecStart=/usr/bin/gpg-agent --daemon\n",
      enabled = true,
      state = "Running")
    check target.len == 1
    check target[0].kind == "systemd.userUnit"
    check target[0].address == "systemd.userUnit:gpg-agent.service"
    check target[0].fields["name"].s == "gpg-agent.service"
    check target[0].fields["enabled"].b == true
    check target[0].fields["state"].s == "Running"

  test "M83 step 4b: systemdUserUnit defaults state=Running, enabled=true":
    var target: seq[ResourceIntent] = @[]
    systemdUserUnit(target, name = "x.service", content = "[Unit]\n")
    check target[0].fields["enabled"].b == true
    check target[0].fields["state"].s == "Running"

  test "M83 step 4b: systemdUserUnit honours explicit address":
    var target: seq[ResourceIntent] = @[]
    systemdUserUnit(target,
      name = "x.service",
      content = "",
      address = "gpg-agent-user-service")
    check target[0].address == "gpg-agent-user-service"

  test "M83 step 4b: launchdUserAgent records every field":
    var target: seq[ResourceIntent] = @[]
    launchdUserAgent(target,
      label = "org.hammerspoon.Hammerspoon",
      programArgs = @["/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon"],
      runAtLoad = true,
      keepAlive = true)
    check target.len == 1
    check target[0].kind == "launchd.userAgent"
    check target[0].address ==
      "launchd.userAgent:org.hammerspoon.Hammerspoon"
    check target[0].fields["label"].s == "org.hammerspoon.Hammerspoon"
    check target[0].fields["programArgs"].items.len == 1
    check target[0].fields["runAtLoad"].b == true
    check target[0].fields["keepAlive"].b == true

  test "M83 step 4b: launchdUserAgent defaults runAtLoad=true, keepAlive=false":
    var target: seq[ResourceIntent] = @[]
    launchdUserAgent(target,
      label = "com.example.transient",
      programArgs = @["/bin/true"])
    check target[0].fields["runAtLoad"].b == true
    check target[0].fields["keepAlive"].b == false

  test "M83 step 4b: launchdUserAgent dependsOn parses into ResourceAddress":
    var target: seq[ResourceIntent] = @[]
    launchdUserAgent(target,
      label = "com.example.x",
      programArgs = @["/bin/true"],
      dependsOn = @["fs.userFile:~/.config/foo"])
    check target[0].dependsOn.len == 1
    check target[0].dependsOn[0].kind == "fs.userFile"
    check target[0].dependsOn[0].name == "~/.config/foo"

  test "M83 step 7: linuxDconfKey records key + value":
    var target: seq[ResourceIntent] = @[]
    linuxDconfKey(target,
      key = "/org/gnome/desktop/interface/color-scheme",
      value = "'prefer-dark'")
    check target.len == 1
    check target[0].kind == "linux.dconfKey"
    check target[0].address ==
      "linux.dconfKey:/org/gnome/desktop/interface/color-scheme"
    check target[0].fields["key"].s ==
      "/org/gnome/desktop/interface/color-scheme"
    check target[0].fields["value"].s == "'prefer-dark'"

  test "M83 step 7: linuxDconfKey honours explicit address":
    var target: seq[ResourceIntent] = @[]
    linuxDconfKey(target,
      key = "/org/gnome/desktop/interface/color-scheme",
      value = "'prefer-dark'",
      address = "gnome-color-scheme")
    check target[0].address == "gnome-color-scheme"

  test "M83 step 7: linuxDconfKey dependsOn parses into ResourceAddress":
    var target: seq[ResourceIntent] = @[]
    linuxDconfKey(target,
      key = "/org/gnome/desktop/interface/color-scheme",
      value = "'prefer-dark'",
      dependsOn = @["env.userVariable:GTK_THEME"])
    check target[0].dependsOn.len == 1
    check target[0].dependsOn[0].kind == "env.userVariable"
    check target[0].dependsOn[0].name == "GTK_THEME"

  test "M83 step 7: linuxKdeConfigKey records every field":
    var target: seq[ResourceIntent] = @[]
    linuxKdeConfigKey(target,
      file = "kdeglobals",
      group = "General",
      key = "ColorScheme",
      value = "BreezeDark")
    check target.len == 1
    check target[0].kind == "linux.kdeConfigKey"
    check target[0].address ==
      "linux.kdeConfigKey:kdeglobals:General:ColorScheme"
    check target[0].fields["file"].s == "kdeglobals"
    check target[0].fields["group"].s == "General"
    check target[0].fields["key"].s == "ColorScheme"
    check target[0].fields["value"].s == "BreezeDark"
    check target[0].fields["kdeVersion"].i == 6

  test "M83 step 7: linuxKdeConfigKey defaults kdeVersion=6":
    var target: seq[ResourceIntent] = @[]
    linuxKdeConfigKey(target,
      file = "kdeglobals", group = "General",
      key = "K", value = "v")
    check target[0].fields["kdeVersion"].i == 6

  test "M83 step 7: linuxKdeConfigKey honours kdeVersion=5":
    var target: seq[ResourceIntent] = @[]
    linuxKdeConfigKey(target,
      file = "kdeglobals", group = "General",
      key = "K", value = "v",
      kdeVersion = 5)
    check target[0].fields["kdeVersion"].i == 5

  test "M83 step 7: linuxKdeConfigKey honours explicit address":
    var target: seq[ResourceIntent] = @[]
    linuxKdeConfigKey(target,
      file = "kdeglobals", group = "General",
      key = "K", value = "v",
      address = "kde-color-scheme")
    check target[0].address == "kde-color-scheme"

  test "M83 step 7: linuxKdeConfigKey dependsOn parses into ResourceAddress":
    var target: seq[ResourceIntent] = @[]
    linuxKdeConfigKey(target,
      file = "kdeglobals", group = "General",
      key = "K", value = "v",
      dependsOn = @["linux.dconfKey:/org/gnome/x"])
    check target[0].dependsOn.len == 1
    check target[0].dependsOn[0].kind == "linux.dconfKey"
    check target[0].dependsOn[0].name == "/org/gnome/x"

  test "fsSystemFile":
    var target: seq[ResourceIntent] = @[]
    fsSystemFile(target, path = "/etc/hosts.d/local",
      content = "127.0.0.1 dev")
    check target[0].kind == "fs.systemFile"
    check target[0].fields["mode"].s == "0644"

  test "envSystemVariable with isPathList":
    var target: seq[ResourceIntent] = @[]
    envSystemVariable(target, name = "PATH",
      contribute = @["/usr/local/bin", "/opt/bin"],
      isPathList = true)
    check target[0].kind == "env.systemVariable"
    check target[0].fields["isPathList"].b == true
    check target[0].fields["contribute"].items.len == 2

  test "passwdUser with extras":
    var target: seq[ResourceIntent] = @[]
    passwdUser(target, name = "zahary", shell = "/usr/bin/zsh",
      extraGroups = @["wheel", "docker"])
    check target[0].kind == "passwd.user"
    check target[0].fields["shell"].s == "/usr/bin/zsh"
    check target[0].fields["extraGroups"].items == @["wheel", "docker"]

  test "dependsOn entries parse into ResourceAddress":
    var target: seq[ResourceIntent] = @[]
    fsUserFile(target,
      hostFile = "~/.gitconfig", content = "x",
      dependsOn = @["fs.userFile:~/.git-credentials",
        "env.userVariable:GIT_EDITOR"])
    check target[0].dependsOn.len == 2
    check target[0].dependsOn[0].kind == "fs.userFile"
    check target[0].dependsOn[0].name == "~/.git-credentials"
    check target[0].dependsOn[1].kind == "env.userVariable"
    check target[0].dependsOn[1].name == "GIT_EDITOR"

# ---------------------------------------------------------------------
# Predicates.
# ---------------------------------------------------------------------

suite "Predicate combinators":

  test "single ident":
    check windows().expr == "windows"
    check macos().expr == "macos"
    check linux().expr == "linux"
    check arm64().expr == "arm64"

  test "and is commutative-canonical":
    check (windows() and arm64()).expr == "arm64 and windows"
    check (arm64() and windows()).expr == "arm64 and windows"

  test "or is commutative-canonical":
    let p1 = windows() or macos()
    let p2 = macos() or windows()
    check p1.expr == p2.expr
    check p1.expr == "macos or windows"

  test "not wraps composite in parens":
    let p = `not`(windows() or macos())
    check p.expr == "not (macos or windows)"

  test "not on a bare ident does not wrap":
    let p = `not`(windows())
    check p.expr == "not windows"

  test "and chain flattens + sorts":
    let p = (linux() and arm64()) and x86_64()
    check p.expr == "arm64 and linux and x86_64"

  test "host equality":
    let p = host() == "dev-laptop"
    check p.expr == "host == \"dev-laptop\""

  test "host inequality":
    let p = host() != "ci"
    check p.expr == "host != \"ci\""

  test "host in list":
    let p = host() in @["a", "b"]
    check p.expr == "host in [\"a\", \"b\"]"

  test "raw predicate escape hatch":
    let p = predicate("user-defined-pred")
    check p.expr == "user-defined-pred"

# ---------------------------------------------------------------------
# unindent + interpolate.
# ---------------------------------------------------------------------

suite "string helpers":

  test "unindent single-line no-op":
    check profileStrings.unindent("hello") == "hello"

  test "unindent strips common 4-space indent":
    let src = "    line a\n    line b\n    line c"
    check profileStrings.unindent(src) == "line a\nline b\nline c"

  test "unindent uses minimum non-blank indent":
    let src = "    a\n  b\n      c"
    check profileStrings.unindent(src) == "  a\nb\n    c"

  test "unindent drops leading + trailing blank lines":
    let src = "\n\n    foo\n    bar\n\n"
    check profileStrings.unindent(src) == "foo\nbar"

  test "unindent: blank lines inside content become empty lines":
    let src = "    line a\n\n    line b"
    check profileStrings.unindent(src) == "line a\n\nline b"

  test "interpolate replaces ${var}":
    var vars = initTable[string, string]()
    vars["name"] = "world"
    check interpolate("hello ${name}!", vars) == "hello world!"

  test "interpolate handles multiple markers":
    var vars = initTable[string, string]()
    vars["a"] = "foo"
    vars["b"] = "bar"
    check interpolate("${a}-${b}-${a}", vars) == "foo-bar-foo"

  test "interpolate missing var raises KeyError":
    var vars = initTable[string, string]()
    expect KeyError:
      discard interpolate("hello ${missing}", vars)

  test "interpolate no markers passes through":
    var vars = initTable[string, string]()
    check interpolate("plain text", vars) == "plain text"

  test "interpolate $$ literal escape":
    var vars = initTable[string, string]()
    check interpolate("cost: $$5", vars) == "cost: $5"

# ---------------------------------------------------------------------
# parseResourceAddress.
# ---------------------------------------------------------------------

suite "ResourceAddress parsing":

  test "kind:name":
    let a = parseResourceAddress("fs.userFile:~/.gitconfig")
    check a.kind == "fs.userFile"
    check a.name == "~/.gitconfig"

  test "kind only":
    let a = parseResourceAddress("windows.optionalFeature")
    check a.kind == "windows.optionalFeature"
    check a.name == ""

  test "empty":
    let a = parseResourceAddress("")
    check a.kind == ""
    check a.name == ""

  test "stringify round-trips":
    let a = ResourceAddress(kind: "k", name: "n")
    check $a == "k:n"
    let a2 = ResourceAddress(kind: "k", name: "")
    check $a2 == "k"

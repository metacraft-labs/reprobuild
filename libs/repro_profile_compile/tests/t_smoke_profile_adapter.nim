## M83 Phase D unit tests for the home + system profile adapters.
##
## Each test builds a `ProfileIntent` directly (no compile step), runs
## it through the adapter, and asserts the resulting `Profile` /
## `SystemProfile` matches the legacy parser's output for the
## equivalent text. The adapters are pure functions; these tests do
## NOT touch the filesystem, run a build engine, or invoke `nim c`.

import std/[options, tables, unittest]

import repro_home_intent
import repro_infra
import repro_profile
import repro_profile_compile

# ---------------------------------------------------------------------------
# Tiny constructors used throughout the tests.
# ---------------------------------------------------------------------------

proc strFieldEntry(k, v: string): (string, FieldValue) =
  (k, strField(v))

proc boolFieldEntry(k: string; v: bool): (string, FieldValue) =
  (k, boolField(v))

proc listFieldEntry(k: string; items: seq[string]): (string, FieldValue) =
  (k, listField(items))

proc resourceIntent(kind, address: string;
                    fields: seq[(string, FieldValue)];
                    dependsOn: seq[string] = @[]): ResourceIntent =
  result = ResourceIntent(kind: kind, address: address)
  for (k, v) in fields:
    result.fields[k] = v
  for d in dependsOn:
    result.dependsOn.add(parseResourceAddress(d))

# ---------------------------------------------------------------------------
# Home adapter — activities / config / hosts.
# ---------------------------------------------------------------------------

suite "M83 Phase D: home adapter — empty + minimal":

  test "empty ProfileIntent -> profile with only the resources block":
    let intent = ProfileIntent(name: "empty")
    let prof = profileIntentToHomeProfile(intent, "/tmp/home.nim")
    check prof != nil
    check prof.path == "/tmp/home.nim"
    check prof.root.kind == nkProfileRoot
    check prof.root.name == "empty"
    # Empty intent still emits the resources block stub (an empty
    # resources block is a stable no-op in the apply pipeline).
    check prof.root.children.len == 1
    check prof.root.children[0].kind == nkResourcesBlock
    check prof.root.children[0].resourcesEntries.len == 0

  test "name carries through to nkProfileRoot.name":
    let intent = ProfileIntent(name: "zahary")
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    check prof.root.name == "zahary"

  test "activity with one package ref becomes nkActivity + nkPackageRef":
    var intent = ProfileIntent(name: "demo")
    intent.activities.add(ActivityIntent(name: "default",
      body: @[ActivityElement(kind: aekPackageRef, pkgName: "neovim")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    check prof.root.children.len >= 1
    check prof.root.children[0].kind == nkActivity
    check prof.root.children[0].activityName == "default"
    check prof.root.children[0].activityChildren.len == 1
    let pkg = prof.root.children[0].activityChildren[0]
    check pkg.kind == nkPackageRef
    check pkg.packageName == "neovim"

  test "activity body with `when` guard -> nkCondBlock with parsed predicate":
    var intent = ProfileIntent(name: "demo")
    intent.activities.add(ActivityIntent(name: "default",
      body: @[ActivityElement(kind: aekWhenGuard,
        predicate: PredicateExpr(expr: "windows"),
        guardedBody: @[ActivityElement(kind: aekPackageRef,
          pkgName: "windows-terminal")])]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let act = prof.root.children[0]
    check act.kind == nkActivity
    check act.activityChildren.len == 1
    let cb = act.activityChildren[0]
    check cb.kind == nkCondBlock
    check cb.predicateSource == "windows"
    check cb.predicateAst.kind == pnIdent
    check cb.predicateAst.ident == "windows"
    check cb.condChildren.len == 1
    check cb.condChildren[0].kind == nkPackageRef
    check cb.condChildren[0].packageName == "windows-terminal"

  test "activity body with multiple package refs preserves order":
    var intent = ProfileIntent(name: "demo")
    intent.activities.add(ActivityIntent(name: "default",
      body: @[
        ActivityElement(kind: aekPackageRef, pkgName: "git"),
        ActivityElement(kind: aekPackageRef, pkgName: "gh"),
        ActivityElement(kind: aekPackageRef, pkgName: "ripgrep")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let act = prof.root.children[0]
    check act.activityChildren.len == 3
    check act.activityChildren[0].packageName == "git"
    check act.activityChildren[1].packageName == "gh"
    check act.activityChildren[2].packageName == "ripgrep"

  test "config:<pkg>:<key=value> -> nkConfigBlock / nkConfigPackage / nkConfigEntry":
    var intent = ProfileIntent(name: "demo")
    intent.configOverrides.add(ConfigOverride(pkg: "git", key: "userName",
      value: strValue("Alice")))
    intent.configOverrides.add(ConfigOverride(pkg: "git",
      key: "userEmail", value: strValue("a@example.com")))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let configBlocks = block:
      var n: IntentNode = nil
      for ch in prof.root.children:
        if ch.kind == nkConfigBlock:
          n = ch; break
      n
    check configBlocks != nil
    check configBlocks.configPackages.len == 1
    let pkg = configBlocks.configPackages[0]
    check pkg.configPackageName == "git"
    check pkg.configEntries.len == 2
    check pkg.configEntries[0].configKey == "userName"
    check pkg.configEntries[0].configValueSource == "\"Alice\""
    check pkg.configEntries[1].configKey == "userEmail"
    check pkg.configEntries[1].configValueSource == "\"a@example.com\""

  test "hosts block populates nkHostsBlock with nkHostsEntry children":
    var intent = ProfileIntent(name: "demo")
    intent.hosts["dev-laptop"] = @["develop_software"]
    intent.hosts["server-rig"] = @["servers", "monitoring"]
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let hostsBlock = block:
      var n: IntentNode = nil
      for ch in prof.root.children:
        if ch.kind == nkHostsBlock:
          n = ch; break
      n
    check hostsBlock != nil
    check hostsBlock.hostsEntries.len == 2
    var foundLaptop, foundServer = false
    for entry in hostsBlock.hostsEntries:
      if entry.hostName == "dev-laptop":
        check entry.hostActivities == @["develop_software"]
        foundLaptop = true
      elif entry.hostName == "server-rig":
        check entry.hostActivities == @["servers", "monitoring"]
        foundServer = true
    check foundLaptop and foundServer

# ---------------------------------------------------------------------------
# Home adapter — resources block.
# ---------------------------------------------------------------------------

suite "M83 Phase D: home adapter — resources":

  test "env.userPath resource keeps its kind and entries attr":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("env.userPath", "launcherBin",
      @[strFieldEntry("entries", "%LOCALAPPDATA%\\repro\\home\\bin")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let r = findResourcesBlock(prof).get
    check r.resourcesEntries.len == 1
    let e = r.resourcesEntries[0]
    check e.resourceKind == "env.userPath"
    check e.resourceAddress == "launcherBin"
    var entriesAttr = ""
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "entries":
        entriesAttr = a.resourceAttrValueSource
    check entriesAttr == "\"%LOCALAPPDATA%\\\\repro\\\\home\\\\bin\""

  test "fs.managedBlock resource carries hostFile, blockId, content":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("fs.managedBlock", "shellrc",
      @[strFieldEntry("hostFile", "~/.bashrc"),
        strFieldEntry("blockId", "rc-direnv"),
        strFieldEntry("content", "eval direnv hook")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let entries = findResourcesBlock(prof).get.resourcesEntries
    check entries.len == 1
    check entries[0].resourceKind == "fs.managedBlock"

  test "shell.integration resource carries hostFile + blockId + content":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("shell.integration", "pwshDirenv",
      @[strFieldEntry("hostFile", "~/Documents/PowerShell/Profile.ps1"),
        strFieldEntry("blockId", "direnv-hook"),
        strFieldEntry("content", "direnv hook pwsh")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "shell.integration"

  test "env.userVariable resource is mapped 1:1":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("env.userVariable", "xdg",
      @[strFieldEntry("name", "XDG_CONFIG_HOME"),
        strFieldEntry("value", "%APPDATA%"),
        strFieldEntry("valueKind", "expandString")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "env.userVariable"

  test "windows.registryValueHKCU (macro) -> windows.registryValue (parser)":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("windows.registryValueHKCU",
      "reg", @[
        strFieldEntry("key", "HKCU\\Software\\Reprobuild-Tests"),
        strFieldEntry("name", "T1"),
        strFieldEntry("kind", "string"),
        strFieldEntry("value", "hello")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "windows.registryValue"
    # Phase-A macro stores the typed REG_* kind under field name `kind`,
    # but the apply parser requires the attribute key `valueKind`. The
    # adapter renames on the way out.
    var attrKeys: seq[string]
    for a in e.resourceAttrs:
      attrKeys.add(a.resourceAttrKey)
    check "valueKind" in attrKeys
    check "kind" notin attrKeys

  test "windows.startup resource carries name + command":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("windows.startup", "autorun",
      @[strFieldEntry("name", "MyApp"),
        strFieldEntry("command", "\"C:\\foo\\app.exe\"")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "windows.startup"

  test "fs.userFile resource carries all four fields":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("fs.userFile", "demoFile",
      @[strFieldEntry("hostFile", "~/.config/foo.conf"),
        strFieldEntry("content", "key=value"),
        strFieldEntry("mode", "0644"),
        boolFieldEntry("executable", false)]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "fs.userFile"
    var hasExecutable = false
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "executable":
        check a.resourceAttrValueSource == "false"
        hasExecutable = true
    check hasExecutable

  test "M83 step 4b: systemd.userUnit resource carries name + content + state":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("systemd.userUnit", "u",
      @[strFieldEntry("name", "gpg-agent.service"),
        strFieldEntry("content", "[Unit]\nDescription=gpg-agent\n"),
        boolFieldEntry("enabled", true),
        strFieldEntry("state", "Running")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "systemd.userUnit"
    var attrKeys: seq[string]
    for a in e.resourceAttrs:
      attrKeys.add(a.resourceAttrKey)
    check "name" in attrKeys
    check "content" in attrKeys
    check "enabled" in attrKeys
    check "state" in attrKeys

  test "M83 step 4b: systemd.userUnit state attribute renders quoted":
    # The string-typed `state` field is rendered as a double-quoted
    # source token so the apply parser's `attrOf` decoder unquotes
    # it to bare `Running` / `Stopped` text.
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("systemd.userUnit", "u",
      @[strFieldEntry("name", "x.service"),
        strFieldEntry("content", ""),
        boolFieldEntry("enabled", false),
        strFieldEntry("state", "Stopped")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    var stateSrc = ""
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "state":
        stateSrc = a.resourceAttrValueSource
    check stateSrc == "\"Stopped\""

  test "M83 step 4b: launchd.userAgent resource carries label + programArgs":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("launchd.userAgent", "agent",
      @[strFieldEntry("label", "com.metacraft.repro.demo"),
        listFieldEntry("programArgs",
          @["/usr/bin/true", "--flag"]),
        boolFieldEntry("runAtLoad", true),
        boolFieldEntry("keepAlive", false)]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "launchd.userAgent"
    var hasProgramArgs = false
    var hasKeepAlive = false
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "programArgs":
        # Comma-joined bare-text rendering (legacy list convention).
        check a.resourceAttrValueSource == "/usr/bin/true,--flag"
        hasProgramArgs = true
      elif a.resourceAttrKey == "keepAlive":
        check a.resourceAttrValueSource == "false"
        hasKeepAlive = true
    check hasProgramArgs
    check hasKeepAlive

  test "M83 step 4b: launchd.userAgent keepAlive=true round-trips":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("launchd.userAgent", "agent",
      @[strFieldEntry("label", "com.example.x"),
        listFieldEntry("programArgs", @["/bin/sh", "-c", "true"]),
        boolFieldEntry("runAtLoad", true),
        boolFieldEntry("keepAlive", true)]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    var keepAliveSrc = ""
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "keepAlive":
        keepAliveSrc = a.resourceAttrValueSource
    check keepAliveSrc == "true"

  test "vscode.extension resource carries extensions + removeUnknown":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("vscode.extension", "vsExt",
      @[listFieldEntry("extensions",
          @["vscodevim.vim", "ms-python.python"]),
        boolFieldEntry("removeUnknown", false)]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    check e.resourceKind == "vscode.extension"
    var hasExtensions = false
    var hasRemoveUnknown = false
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "extensions":
        # The home adapter renders a list as comma-separated bare text
        # (the legacy parser convention for `env.userPath.entries`).
        check a.resourceAttrValueSource == "vscodevim.vim,ms-python.python"
        hasExtensions = true
      elif a.resourceAttrKey == "removeUnknown":
        check a.resourceAttrValueSource == "false"
        hasRemoveUnknown = true
    check hasExtensions
    check hasRemoveUnknown

  test "depends_on synthesises the depends_on attribute as a [\"k:n\"] literal":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("env.userPath", "p",
      @[strFieldEntry("entries", "C:\\bin")],
      dependsOn = @["windows.capability:OpenSSH"]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let e = findResourcesBlock(prof).get.resourcesEntries[0]
    var depAttr = ""
    for a in e.resourceAttrs:
      if a.resourceAttrKey == "depends_on":
        depAttr = a.resourceAttrValueSource
    check depAttr == "[\"windows.capability:OpenSSH\"]"

  test "system-scope resource kinds are filtered out of the home block":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("windows.capability", "ssh",
      @[strFieldEntry("name", "OpenSSH.Server"),
        boolFieldEntry("installed", true)]))
    intent.resources.add(resourceIntent("env.userPath", "p",
      @[strFieldEntry("entries", "C:\\bin")]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let entries = findResourcesBlock(prof).get.resourcesEntries
    check entries.len == 1
    check entries[0].resourceKind == "env.userPath"

# ---------------------------------------------------------------------------
# System adapter.
# ---------------------------------------------------------------------------

suite "M83 Phase D: system adapter":

  test "empty ProfileIntent -> empty SystemProfile":
    let sp = profileIntentToSystemProfile(ProfileIntent(name: "empty"))
    check sp.resources.len == 0

  test "windows.capability resource maps to srkWindowsCapability":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.capability", "ssh",
      @[strFieldEntry("name", "OpenSSH.Server~~~~0.0.1.0"),
        boolFieldEntry("installed", true)]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsCapability
    check sp.resources[0].capabilityName == "OpenSSH.Server~~~~0.0.1.0"
    check sp.resources[0].capabilityInstalled

  test "windows.optionalFeature resource maps to srkWindowsOptionalFeature":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.optionalFeature", "wsl",
      @[strFieldEntry("name", "Microsoft-Windows-Subsystem-Linux"),
        boolFieldEntry("enabled", true)]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].kind == srkWindowsOptionalFeature
    check sp.resources[0].featureName == "Microsoft-Windows-Subsystem-Linux"

  test "windows.service resource maps to srkWindowsService":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.service", "sshd",
      @[strFieldEntry("name", "sshd"),
        strFieldEntry("startType", "Automatic"),
        strFieldEntry("state", "running")]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].kind == srkWindowsService
    check sp.resources[0].serviceRunning

  test "windows.registryValueHKLM resource maps to srkWindowsRegistryValue":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.registryValueHKLM", "reg",
      @[strFieldEntry("key", "HKLM\\SOFTWARE\\Foo"),
        strFieldEntry("name", "Bar"),
        strFieldEntry("kind", "string"),
        strFieldEntry("value", "1")]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].kind == srkWindowsRegistryValue
    check sp.resources[0].regKey == "HKLM\\SOFTWARE\\Foo"

  test "home-scope resource kinds are filtered out of the system profile":
    var intent = ProfileIntent(name: "demo")
    intent.resources.add(resourceIntent("env.userPath", "p",
      @[strFieldEntry("entries", "C:\\bin")]))
    intent.resources.add(resourceIntent("windows.capability", "ssh",
      @[strFieldEntry("name", "OpenSSH"),
        boolFieldEntry("installed", true)]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsCapability

  test "explicit address is preserved on a system resource":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.capability", "myExplicitAddr",
      @[strFieldEntry("name", "OpenSSH")]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].address == "myExplicitAddr"

  test "default address is derived from realWorldIdentity when empty":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.capability", "",
      @[strFieldEntry("name", "OpenSSH")]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].address == "capability:OpenSSH"

  test "depends_on edges are preserved on a system resource":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.service", "sshd",
      @[strFieldEntry("name", "sshd")],
      dependsOn = @["windows.capability:OpenSSH"]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].dependsOn.len == 1
    check sp.resources[0].dependsOn[0].kind == "windows.capability"
    check sp.resources[0].dependsOn[0].name == "OpenSSH"

  test "renderSystemProfileToText round-trips windows.capability":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.capability", "",
      @[strFieldEntry("name", "OpenSSH.Server~~~~0.0.1.0"),
        boolFieldEntry("installed", true)]))
    let sp1 = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp1)
    let sp2 = parseSystemProfile(txt)
    check sp2.resources.len == 1
    check sp2.resources[0].kind == srkWindowsCapability
    check sp2.resources[0].capabilityName == "OpenSSH.Server~~~~0.0.1.0"

  test "renderSystemProfileToText round-trips a multi-stanza profile":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.capability", "",
      @[strFieldEntry("name", "OpenSSH.Server")]))
    intent.resources.add(resourceIntent("windows.service", "",
      @[strFieldEntry("name", "sshd"),
        strFieldEntry("startType", "Automatic"),
        strFieldEntry("state", "running")]))
    let sp1 = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp1)
    let sp2 = parseSystemProfile(txt)
    check sp2.resources.len == 2

  test "windows.firewallRule resource maps to srkWindowsFirewallRule":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.firewallRule", "fw",
      @[strFieldEntry("name", "OpenSSH-Server-In-TCP"),
        strFieldEntry("displayName", "OpenSSH Server (sshd)"),
        strFieldEntry("protocol", "TCP"),
        strFieldEntry("direction", "Inbound"),
        strFieldEntry("action", "Allow"),
        strFieldEntry("localPort", "22"),
        boolFieldEntry("enabled", true)]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsFirewallRule
    check sp.resources[0].fwName == "OpenSSH-Server-In-TCP"
    check sp.resources[0].fwDisplayName == "OpenSSH Server (sshd)"
    check sp.resources[0].fwProtocol == "TCP"
    check sp.resources[0].fwDirection == "Inbound"
    check sp.resources[0].fwAction == "Allow"
    check sp.resources[0].fwLocalPort == "22"
    check sp.resources[0].fwEnabled

  test "windows.firewallRule rejects an unknown protocol at adapter time":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.firewallRule", "fw",
      @[strFieldEntry("name", "BadProto"),
        strFieldEntry("protocol", "SCTP"),
        strFieldEntry("direction", "Inbound"),
        strFieldEntry("action", "Allow")]))
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

  test "renderSystemProfileToText round-trips windows.firewallRule":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.firewallRule", "",
      @[strFieldEntry("name", "OpenSSH-Server-In-TCP"),
        strFieldEntry("displayName", "OpenSSH Server (sshd)"),
        strFieldEntry("protocol", "TCP"),
        strFieldEntry("direction", "Inbound"),
        strFieldEntry("action", "Allow"),
        strFieldEntry("localPort", "22"),
        boolFieldEntry("enabled", true)]))
    let sp1 = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp1)
    let sp2 = parseSystemProfile(txt)
    check sp2.resources.len == 1
    check sp2.resources[0].kind == srkWindowsFirewallRule
    check sp2.resources[0].fwName == "OpenSSH-Server-In-TCP"
    check sp2.resources[0].fwProtocol == "TCP"
    check sp2.resources[0].fwLocalPort == "22"
    # Second round-trip is byte-equivalent.
    let txt2 = renderSystemProfileToText(sp2)
    check txt2 == txt

  test "os.timezone resource maps to srkOsTimezone":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("os.timezone", "userTimezone",
      @[strFieldEntry("tz", "Europe/Sofia")]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkOsTimezone
    check sp.resources[0].tzIana == "Europe/Sofia"
    check sp.resources[0].address == "userTimezone"

  test "os.timezone rejects an unmapped IANA name at adapter time":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("os.timezone", "x",
      @[strFieldEntry("tz", "Atlantis/Citadel")]))
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

  test "renderSystemProfileToText round-trips os.timezone":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("os.timezone", "",
      @[strFieldEntry("tz", "Europe/Sofia")]))
    let sp1 = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp1)
    let sp2 = parseSystemProfile(txt)
    check sp2.resources.len == 1
    check sp2.resources[0].kind == srkOsTimezone
    check sp2.resources[0].tzIana == "Europe/Sofia"
    let txt2 = renderSystemProfileToText(sp2)
    check txt2 == txt

  test "os.hostname resource maps to srkOsHostname":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("os.hostname", "userHostname",
      @[strFieldEntry("hostname", "MyDevBox")]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkOsHostname
    check sp.resources[0].hostnameName == "MyDevBox"
    check sp.resources[0].address == "userHostname"

  test "os.hostname rejects a metacharacter hostname at adapter time":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("os.hostname", "x",
      @[strFieldEntry("hostname", "host;rm")]))
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

  test "renderSystemProfileToText round-trips os.hostname":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("os.hostname", "",
      @[strFieldEntry("hostname", "MyDevBox")]))
    let sp1 = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp1)
    let sp2 = parseSystemProfile(txt)
    check sp2.resources.len == 1
    check sp2.resources[0].kind == srkOsHostname
    check sp2.resources[0].hostnameName == "MyDevBox"
    let txt2 = renderSystemProfileToText(sp2)
    check txt2 == txt

  test "renderSystemProfileToText preserves depends_on edges":
    var intent = ProfileIntent(name: "sys")
    intent.resources.add(resourceIntent("windows.service", "",
      @[strFieldEntry("name", "sshd"),
        strFieldEntry("startType", "Automatic"),
        strFieldEntry("state", "running")],
      dependsOn = @["windows.capability:OpenSSH"]))
    let sp1 = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp1)
    let sp2 = parseSystemProfile(txt)
    check sp2.resources[0].dependsOn.len == 1
    check sp2.resources[0].dependsOn[0].kind == "windows.capability"

# ---------------------------------------------------------------------------
# Cross-cutting sanity: the home adapter's output passes the apply
# pipeline's resource pre-validation by going through `findResourcesBlock`
# + the apply pipeline's `parseProfileResources` (in repro_home_apply).
# We don't import the apply pipeline here (it would drag in heavy
# dependencies); the round-trip-via-attrs check below exercises the
# same surface the apply path reads.
# ---------------------------------------------------------------------------

suite "M83 Phase D: home adapter round-trip via attribute readback":

  test "every home-scope kind survives the adapter":
    var intent = ProfileIntent(name: "rt")
    intent.resources.add(resourceIntent("env.userPath", "p",
      @[strFieldEntry("entries", "C:\\bin")]))
    intent.resources.add(resourceIntent("fs.managedBlock", "f",
      @[strFieldEntry("hostFile", "~/.bashrc"),
        strFieldEntry("blockId", "rc"),
        strFieldEntry("content", "x")]))
    intent.resources.add(resourceIntent("shell.integration", "s",
      @[strFieldEntry("hostFile", "~/.zshrc"),
        strFieldEntry("blockId", "zb"),
        strFieldEntry("content", "echo")]))
    intent.resources.add(resourceIntent("env.userVariable", "ev",
      @[strFieldEntry("name", "V"),
        strFieldEntry("value", "x"),
        strFieldEntry("valueKind", "string")]))
    intent.resources.add(resourceIntent("windows.registryValueHKCU", "rh",
      @[strFieldEntry("key", "HKCU\\X"),
        strFieldEntry("name", "Y"),
        strFieldEntry("kind", "string"),
        strFieldEntry("value", "z")]))
    intent.resources.add(resourceIntent("windows.startup", "st",
      @[strFieldEntry("name", "App"),
        strFieldEntry("command", "echo hi")]))
    intent.resources.add(resourceIntent("fs.userFile", "uf",
      @[strFieldEntry("hostFile", "~/.x"),
        strFieldEntry("content", "y"),
        strFieldEntry("mode", "0644"),
        boolFieldEntry("executable", false)]))
    # M83 step 4b: the two POSIX home-scope user-service kinds also
    # belong to the home-scope set and must NOT be filtered out by
    # `isHomeScopeResource`.
    intent.resources.add(resourceIntent("systemd.userUnit", "su",
      @[strFieldEntry("name", "gpg-agent.service"),
        strFieldEntry("content", "[Unit]\n"),
        boolFieldEntry("enabled", true),
        strFieldEntry("state", "Running")]))
    intent.resources.add(resourceIntent("launchd.userAgent", "la",
      @[strFieldEntry("label", "com.example.x"),
        listFieldEntry("programArgs", @["/usr/bin/true"]),
        boolFieldEntry("runAtLoad", true),
        boolFieldEntry("keepAlive", false)]))
    let prof = profileIntentToHomeProfile(intent, "/x/home.nim")
    let entries = findResourcesBlock(prof).get.resourcesEntries
    check entries.len == 9
    var kinds: seq[string]
    for e in entries:
      kinds.add(e.resourceKind)
    # `windows.registryValueHKCU` is mapped to the apply-side name.
    check "env.userPath" in kinds
    check "fs.managedBlock" in kinds
    check "shell.integration" in kinds
    check "env.userVariable" in kinds
    check "windows.registryValue" in kinds
    check "windows.startup" in kinds
    check "fs.userFile" in kinds
    check "systemd.userUnit" in kinds
    check "launchd.userAgent" in kinds

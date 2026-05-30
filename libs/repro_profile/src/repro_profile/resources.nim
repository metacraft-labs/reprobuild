## Resource constructors for the M83 Phase A profile macro library.
##
## Each template emits a `ResourceIntent` and appends it to a target
## seq. The target seq is passed via the FIRST positional parameter
## `targetResources`, which the macros in `./macros.nim` splice in
## implicitly: the user writes `fsUserFile(hostFile = "...", content =
## "...")` inside a `resources:` block and the macro rewrites the
## call to `fsUserFile(profileIntentBuilder.resources, hostFile =
## "...", content = "...")`.
##
## Phase A note: named arguments referencing `var` fields of struct
## values (e.g. `targetResources = profileIntentBuilder.resources`)
## currently trip Nim 2.2's identifier-expected check on the dotted
## RHS, so we keep `targetResources` positional.
##
## Address handling: every constructor accepts an `address` parameter
## (default `""`). When empty, an auto-address is synthesised from the
## resource's key field(s) so two resources of the same kind targeting
## the same object collapse to one address.
##
## `dependsOn` is a `seq[string]` of `"kind:name"` references; each
## entry is parsed into a `ResourceAddress` at append time.

import std/tables

import ./types

# ---------------------------------------------------------------------
# Internal helper: build a ResourceIntent + push it onto the target.
# ---------------------------------------------------------------------

proc pushResource*(target: var seq[ResourceIntent];
                   kind, address: string;
                   fields: Table[string, FieldValue];
                   dependsOn: seq[string]) =
  ## Library-private helper used by every resource constructor.
  ## Exposed so the templates compile cleanly without crossing
  ## generic-symbol scoping rules.
  var deps: seq[ResourceAddress] = @[]
  for d in dependsOn:
    deps.add parseResourceAddress(d)
  target.add ResourceIntent(kind: kind, address: address,
    fields: fields, dependsOn: deps)

proc autoAddress*(kind: string; parts: varargs[string]): string =
  ## Synthesise a stable address from key fields when the user did not
  ## declare one. Format: `<kind>:<part1>:<part2>:...`.
  result = kind
  for p in parts:
    result.add ":"
    result.add p

# ---------------------------------------------------------------------
# Home-scope (M68) constructors.
# ---------------------------------------------------------------------

template package*(name: string): ActivityElement =
  ## A package reference. Mostly used inside an `activity` body
  ## directly as a bare identifier (handled by the activity-body
  ## parser); this template is the explicit fallback when the user
  ## wants to spell it out (e.g. a package name with non-identifier
  ## characters).
  ActivityElement(kind: aekPackageRef, pkgName: name)

template envUserPath*(targetResources: var seq[ResourceIntent];
                      entries: string;
                      address: string = "";
                      dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["entries"] = strField(entries)
    let addr0 = if address.len > 0: address
                else: autoAddress("env.userPath", entries)
    pushResource(targetResources, "env.userPath", addr0, fields, dependsOn)

template envUserVariable*(targetResources: var seq[ResourceIntent];
                          name: string;
                          value: string;
                          valueKind: string = "string";
                          address: string = "";
                          dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["value"] = strField(value)
    fields["valueKind"] = strField(valueKind)
    let addr0 = if address.len > 0: address
                else: autoAddress("env.userVariable", name)
    pushResource(targetResources, "env.userVariable", addr0, fields,
      dependsOn)

template fsManagedBlock*(targetResources: var seq[ResourceIntent];
                         hostFile: string;
                         blockId: string;
                         content: string;
                         address: string = "";
                         dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["hostFile"] = strField(hostFile)
    fields["blockId"] = strField(blockId)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("fs.managedBlock", hostFile, blockId)
    pushResource(targetResources, "fs.managedBlock", addr0, fields,
      dependsOn)

template shellIntegration*(targetResources: var seq[ResourceIntent];
                           hostFile: string;
                           blockId: string;
                           content: string;
                           address: string = "";
                           dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["hostFile"] = strField(hostFile)
    fields["blockId"] = strField(blockId)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("shell.integration", hostFile, blockId)
    pushResource(targetResources, "shell.integration", addr0, fields,
      dependsOn)

template windowsRegistryValueHKCU*(targetResources: var seq[ResourceIntent];
                                   key: string;
                                   name: string;
                                   kind: untyped;
                                   value: string;
                                   address: string = "";
                                   dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["key"] = strField(key)
    fields["name"] = strField(name)
    fields["kind"] = strField(astToStr(kind))
    fields["value"] = strField(value)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.registryValueHKCU", key, name)
    pushResource(targetResources, "windows.registryValueHKCU", addr0,
      fields, dependsOn)

template windowsStartup*(targetResources: var seq[ResourceIntent];
                         name: string;
                         command: string;
                         address: string = "";
                         dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["command"] = strField(command)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.startup", name)
    pushResource(targetResources, "windows.startup", addr0, fields,
      dependsOn)

template fsUserFile*(targetResources: var seq[ResourceIntent];
                     hostFile: string;
                     content: string;
                     mode: string = "0644";
                     executable: bool = false;
                     address: string = "";
                     dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["hostFile"] = strField(hostFile)
    fields["content"] = strField(content)
    fields["mode"] = strField(mode)
    fields["executable"] = boolField(executable)
    let addr0 = if address.len > 0: address
                else: autoAddress("fs.userFile", hostFile)
    pushResource(targetResources, "fs.userFile", addr0, fields,
      dependsOn)

template systemdUserUnit*(targetResources: var seq[ResourceIntent];
                          name: string;
                          content: string;
                          enabled: bool = true;
                          state: string = "Running";
                          address: string = "";
                          dependsOn: seq[string] = @[]) =
  ## M83 step 4b — Linux home-scope user-service.
  ##
  ## Wraps `systemctl --user enable/disable/start/stop`. The `state`
  ## attribute is the runtime state — `"Running"` or `"Stopped"`. A
  ## bare `state` string is used (not an untyped enum literal) so
  ## the macro compiles without leaking a Phase-A-side enum into the
  ## resource model; the apply pipeline maps the string to the typed
  ## `SystemdUnitState` enum via `systemdUnitStateFromString` and
  ## rejects anything other than `"Running"` / `"Stopped"`.
  ##
  ## Address default: `systemd.userUnit:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    fields["enabled"] = boolField(enabled)
    fields["state"] = strField(state)
    let addr0 = if address.len > 0: address
                else: autoAddress("systemd.userUnit", name)
    pushResource(targetResources, "systemd.userUnit", addr0, fields,
      dependsOn)

template launchdUserAgent*(targetResources: var seq[ResourceIntent];
                           label: string;
                           programArgs: seq[string];
                           runAtLoad: bool = true;
                           keepAlive: bool = false;
                           address: string = "";
                           dependsOn: seq[string] = @[]) =
  ## M83 step 4b — macOS home-scope user-service.
  ##
  ## Wraps `launchctl bootstrap gui/<uid>` + the plist file under
  ## `~/Library/LaunchAgents/<label>.plist`. The plist XML is
  ## DERIVED from the typed fields by `launchAgentPlistFor` at
  ## apply time; the macro never carries plist bytes directly so a
  ## change to e.g. `keepAlive` re-converges the file on the next
  ## apply.
  ##
  ## Address default: `launchd.userAgent:<label>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["label"] = strField(label)
    fields["programArgs"] = listField(programArgs)
    fields["runAtLoad"] = boolField(runAtLoad)
    fields["keepAlive"] = boolField(keepAlive)
    let addr0 = if address.len > 0: address
                else: autoAddress("launchd.userAgent", label)
    pushResource(targetResources, "launchd.userAgent", addr0, fields,
      dependsOn)

template vscodeExtension*(targetResources: var seq[ResourceIntent];
                          extensions: seq[string];
                          removeUnknown: bool = false;
                          address: string = "";
                          dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["extensions"] = listField(extensions)
    fields["removeUnknown"] = boolField(removeUnknown)
    let addr0 = if address.len > 0: address
                else: autoAddress("vscode.extension", "vscode-extensions")
    pushResource(targetResources, "vscode.extension", addr0, fields,
      dependsOn)

# ---------------------------------------------------------------------
# System-scope (M69) constructors.
# ---------------------------------------------------------------------

template windowsOptionalFeature*(targetResources: var seq[ResourceIntent];
                                 name: string;
                                 enabled: bool = true;
                                 address: string = "";
                                 dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["enabled"] = boolField(enabled)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.optionalFeature", name)
    pushResource(targetResources, "windows.optionalFeature", addr0,
      fields, dependsOn)

template windowsCapability*(targetResources: var seq[ResourceIntent];
                            name: string;
                            installed: bool = true;
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["installed"] = boolField(installed)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.capability", name)
    pushResource(targetResources, "windows.capability", addr0, fields,
      dependsOn)

template windowsService*(targetResources: var seq[ResourceIntent];
                         name: string;
                         startType: untyped;
                         state: untyped;
                         address: string = "";
                         dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["startType"] = strField(astToStr(startType))
    fields["state"] = strField(astToStr(state))
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.service", name)
    pushResource(targetResources, "windows.service", addr0, fields,
      dependsOn)

template windowsRegistryValueHKLM*(targetResources: var seq[ResourceIntent];
                                   key: string;
                                   name: string;
                                   kind: untyped;
                                   value: string;
                                   address: string = "";
                                   dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["key"] = strField(key)
    fields["name"] = strField(name)
    fields["kind"] = strField(astToStr(kind))
    fields["value"] = strField(value)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.registryValueHKLM", key, name)
    pushResource(targetResources, "windows.registryValueHKLM", addr0,
      fields, dependsOn)

template windowsVsInstaller*(targetResources: var seq[ResourceIntent];
                             workloads: seq[string];
                             version: string = "";
                             address: string = "";
                             dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["workloads"] = listField(workloads)
    fields["version"] = strField(version)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.vsInstaller", version)
    pushResource(targetResources, "windows.vsInstaller", addr0, fields,
      dependsOn)

template windowsFirewallRule*(targetResources: var seq[ResourceIntent];
                              name: string;
                              protocol: string;
                              direction: string;
                              action: string;
                              displayName: string = "";
                              localPort: string = "Any";
                              enabled: bool = true;
                              address: string = "";
                              dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["displayName"] = strField(displayName)
    fields["protocol"] = strField(protocol)
    fields["direction"] = strField(direction)
    fields["action"] = strField(action)
    fields["localPort"] = strField(localPort)
    fields["enabled"] = boolField(enabled)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.firewallRule", name)
    pushResource(targetResources, "windows.firewallRule", addr0, fields,
      dependsOn)

template macosSystemDefault*(targetResources: var seq[ResourceIntent];
                             domain: string;
                             key: string;
                             value: string;
                             kind: untyped;
                             address: string = "";
                             dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["domain"] = strField(domain)
    fields["key"] = strField(key)
    fields["value"] = strField(value)
    fields["kind"] = strField(astToStr(kind))
    let addr0 = if address.len > 0: address
                else: autoAddress("macos.systemDefault", domain, key)
    pushResource(targetResources, "macos.systemDefault", addr0, fields,
      dependsOn)

template systemdSystemUnit*(targetResources: var seq[ResourceIntent];
                            name: string;
                            content: string;
                            enabled: bool = true;
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    fields["enabled"] = boolField(enabled)
    let addr0 = if address.len > 0: address
                else: autoAddress("systemd.systemUnit", name)
    pushResource(targetResources, "systemd.systemUnit", addr0, fields,
      dependsOn)

template launchdSystemDaemon*(targetResources: var seq[ResourceIntent];
                              label: string;
                              programArgs: seq[string];
                              address: string = "";
                              dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["label"] = strField(label)
    fields["programArgs"] = listField(programArgs)
    let addr0 = if address.len > 0: address
                else: autoAddress("launchd.systemDaemon", label)
    pushResource(targetResources, "launchd.systemDaemon", addr0, fields,
      dependsOn)

template fsSystemFile*(targetResources: var seq[ResourceIntent];
                       path: string;
                       content: string;
                       mode: string = "0644";
                       address: string = "";
                       dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["path"] = strField(path)
    fields["content"] = strField(content)
    fields["mode"] = strField(mode)
    let addr0 = if address.len > 0: address
                else: autoAddress("fs.systemFile", path)
    pushResource(targetResources, "fs.systemFile", addr0, fields,
      dependsOn)

template envSystemVariable*(targetResources: var seq[ResourceIntent];
                            name: string;
                            contribute: seq[string];
                            isPathList: bool = false;
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["contribute"] = listField(contribute)
    fields["isPathList"] = boolField(isPathList)
    let addr0 = if address.len > 0: address
                else: autoAddress("env.systemVariable", name)
    pushResource(targetResources, "env.systemVariable", addr0, fields,
      dependsOn)

template passwdUser*(targetResources: var seq[ResourceIntent];
                     name: string;
                     shell: string = "";
                     extraGroups: seq[string] = @[];
                     address: string = "";
                     dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["shell"] = strField(shell)
    fields["extraGroups"] = listField(extraGroups)
    let addr0 = if address.len > 0: address
                else: autoAddress("passwd.user", name)
    pushResource(targetResources, "passwd.user", addr0, fields,
      dependsOn)

template osTimezone*(targetResources: var seq[ResourceIntent];
                     tz: string;
                     address: string = "";
                     dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["tz"] = strField(tz)
    let addr0 = if address.len > 0: address
                else: autoAddress("os.timezone", tz)
    pushResource(targetResources, "os.timezone", addr0, fields,
      dependsOn)

template osHostname*(targetResources: var seq[ResourceIntent];
                     hostname: string;
                     address: string = "";
                     dependsOn: seq[string] = @[]) =
  block:
    var fields = initTable[string, FieldValue]()
    fields["hostname"] = strField(hostname)
    let addr0 = if address.len > 0: address
                else: autoAddress("os.hostname", hostname)
    pushResource(targetResources, "os.hostname", addr0, fields,
      dependsOn)

template linuxSysctl*(targetResources: var seq[ResourceIntent];
                      key: string;
                      value: string;
                      filename: string = "";
                      address: string = "";
                      dependsOn: seq[string] = @[]) =
  ## M83 step 5 — Linux system-scope sysctl drop-in. Wraps a write to
  ## `/etc/sysctl.d/<filename>` (auto-derived to
  ## `99-reprobuild-<address-or-key>.conf` when `filename` is empty)
  ## plus a `sysctl -p <path>` reload.
  ##
  ## Address default: `linux.sysctl:<key>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["key"] = strField(key)
    fields["value"] = strField(value)
    fields["filename"] = strField(filename)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.sysctl", key)
    pushResource(targetResources, "linux.sysctl", addr0, fields,
      dependsOn)

template linuxUdevRule*(targetResources: var seq[ResourceIntent];
                        name: string;
                        content: string;
                        address: string = "";
                        dependsOn: seq[string] = @[]) =
  ## M83 step 5 — Linux system-scope udev rule drop-in. Wraps a write
  ## to `/etc/udev/rules.d/<name>` (`name` must end `.rules`) plus a
  ## `udevadm control --reload-rules` reload. No device-trigger.
  ##
  ## Address default: `linux.udevRule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.udevRule", name)
    pushResource(targetResources, "linux.udevRule", addr0, fields,
      dependsOn)

template linuxPolkitRule*(targetResources: var seq[ResourceIntent];
                          name: string;
                          content: string;
                          address: string = "";
                          dependsOn: seq[string] = @[]) =
  ## M83 step 5 — Linux system-scope polkit rule drop-in. Wraps a
  ## write to `/etc/polkit-1/rules.d/<name>` (`name` must end
  ## `.rules`). Polkit auto-reloads via inotify; no explicit reload.
  ##
  ## Address default: `linux.polkitRule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.polkitRule", name)
    pushResource(targetResources, "linux.polkitRule", addr0, fields,
      dependsOn)

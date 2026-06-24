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

import std/[options, tables]

import ./types

# Profile authors invoke `windowsScheduledTask(...,
# runWithHighestPrivileges = some(false), ...)` to override the
# principal-dependent default. Re-export `std/options` so they don't
# have to `import std/options` separately.
export options

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

template package*(name: string; binaries: openArray[string]): ActivityElement =
  ## A package reference whose installed binaries do not share the
  ## package name. Path-based catalog adapters (the Linux fallback)
  ## probe each binary on PATH instead of probing the package name.
  ##
  ## Example: nixpkgs `ripgrep` ships the `rg` binary; without the
  ## hint reprobuild's Linux adapter searches PATH for `ripgrep` and
  ## returns "missing" even when `ripgrep` is fully installed. With
  ## `package("ripgrep", binaries = @["rg"])` the adapter probes
  ## `rg` and returns a cache-hit. The same shape works for
  ## multi-binary packages (e.g. `package("inetutils",
  ## binaries = @["telnet", "ftp"])`).
  ActivityElement(kind: aekPackageRef, pkgName: name,
                  pkgBinaries: @binaries)

template package*(name, version: string;
                  binaries: openArray[string]): ActivityElement =
  ## Version-pinned package reference with explicit binaries metadata.
  ActivityElement(kind: aekPackageRef, pkgName: name,
                  pkgVersion: version, pkgBinaries: @binaries)

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
                     content: string = "";
                     contentFromCommand: seq[string] = @[];
                     mode: string = "0644";
                     executable: bool = false;
                     cacheKey: string = "";
                     address: string = "";
                     dependsOn: seq[string] = @[]) =
  ## M68 home-scope whole-file constructor.
  ##
  ## Either `content` (literal bytes) OR `contentFromCommand` (argv
  ## list whose stdout becomes the file body at apply time) must be
  ## set — the apply-pipeline parser enforces the mutex. Use the
  ## former for static config + the latter for at-rest-encrypted
  ## secrets (e.g. `@["age", "-d", "-i", id, src]`).
  ##
  ## `cacheKey` is consulted ONLY when `contentFromCommand` is set:
  ## the empty default means "always re-run the command on every
  ## apply" (idempotent but slow); a non-empty value opts in to the
  ## driver's cache-hit short-circuit. See the driver docstring for
  ## the full contract.
  block:
    var fields = initTable[string, FieldValue]()
    fields["hostFile"] = strField(hostFile)
    if contentFromCommand.len > 0:
      fields["contentFromCommand"] = listField(contentFromCommand)
      if content.len > 0:
        # The pipeline parser rejects both-set; we still emit
        # `content` so the error path reports the operator's actual
        # input rather than a silent drop.
        fields["content"] = strField(content)
    else:
      fields["content"] = strField(content)
    fields["mode"] = strField(mode)
    fields["executable"] = boolField(executable)
    if cacheKey.len > 0:
      fields["cacheKey"] = strField(cacheKey)
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

template linuxDconfKey*(targetResources: var seq[ResourceIntent];
                        key: string;
                        value: string;
                        address: string = "";
                        dependsOn: seq[string] = @[]) =
  ## M83 step 7 Driver A — Linux GNOME-stack settings via the `dconf`
  ## CLI (`~/.config/dconf/user`).
  ##
  ## `key` is a slash-prefixed dconf key path
  ## (`/org/gnome/desktop/interface/color-scheme`); `value` is a
  ## GVariant textual literal — the operator is responsible for
  ## the GVariant shape (`'prefer-dark'` for strings, `true`/`false`
  ## for bools, bare decimals for ints, `['a', 'b']` for arrays).
  ## The driver writes the literal verbatim via `dconf write`.
  ##
  ## Address default: `linux.dconfKey:<key>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["key"] = strField(key)
    fields["value"] = strField(value)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.dconfKey", key)
    pushResource(targetResources, "linux.dconfKey", addr0, fields,
      dependsOn)

template linuxKdeConfigKey*(targetResources: var seq[ResourceIntent];
                            file: string;
                            group: string;
                            key: string;
                            value: string;
                            kdeVersion: int = 6;
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  ## M83 step 7 Driver B — Linux KDE Plasma settings via the
  ## `kwriteconfig5` / `kwriteconfig6` CLI.
  ##
  ## Writes `value` to `<key>` under `[<group>]` in `~/.config/<file>`
  ## (e.g. `kdeglobals`, `kwinrc`). `kdeVersion` selects the major
  ## binary; the default `6` matches modern Plasma 6. A profile
  ## targeting Plasma 5 passes `kdeVersion = 5`.
  ##
  ## Address default: `linux.kdeConfigKey:<file>:<group>:<key>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["file"] = strField(file)
    fields["group"] = strField(group)
    fields["key"] = strField(key)
    fields["value"] = strField(value)
    fields["kdeVersion"] = intField(kdeVersion)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.kdeConfigKey", file, group, key)
    pushResource(targetResources, "linux.kdeConfigKey", addr0,
      fields, dependsOn)

template homebrewFormula*(targetResources: var seq[ResourceIntent];
                          name: string;
                          version: string = "";
                          args: seq[string] = @[];
                          address: string = "";
                          dependsOn: seq[string] = @[]) =
  ## M83 step 9 Driver A — macOS Homebrew CLI formula. Wraps
  ## `brew install <name>` / `brew list --formula --versions <name>`
  ## / `brew uninstall <name>`.
  ##
  ## `name` is a Homebrew formula identifier (e.g. `ripgrep`, `tmux`,
  ## `node@18`). A versioned-formula tap (`<name>@<major>`) is
  ## accepted; the `@` is in the safe charset.
  ##
  ## `version` is an OPTIONAL version pin. Empty means "track the
  ## tap's latest" (cache-hits on ANY installed version of the
  ## formula). A non-empty value triggers `brew upgrade <name>`
  ## when the installed version mismatches. NOTE: Homebrew's
  ## version model does NOT support pinning to an arbitrary
  ## version against a non-versioned tap; for hard version pins
  ## use a versioned-formula tap (`node@18`, `python@3.11`).
  ##
  ## `args` is an OPTIONAL list of extra args passed to
  ## `brew install` BEFORE the formula name
  ## (e.g. `--build-from-source`, `--HEAD`). Each entry must be
  ## a safe brew flag (no shell metacharacters or whitespace).
  ##
  ## Address default: `pkg.homebrewFormula:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    if version.len > 0:
      fields["version"] = strField(version)
    if args.len > 0:
      fields["args"] = listField(args)
    let addr0 = if address.len > 0: address
                else: autoAddress("pkg.homebrewFormula", name)
    pushResource(targetResources, "pkg.homebrewFormula", addr0,
      fields, dependsOn)

template homebrewCask*(targetResources: var seq[ResourceIntent];
                       name: string;
                       version: string = "";
                       args: seq[string] = @[];
                       address: string = "";
                       dependsOn: seq[string] = @[]) =
  ## M83 step 9 Driver B — macOS Homebrew Cask (GUI/binary apps).
  ## Wraps `brew install --cask <name>` / `brew list --cask
  ## --versions <name>` / `brew uninstall --cask <name>`.
  ##
  ## `name` is a Homebrew cask identifier (e.g. `iterm2`,
  ## `firefox`, `visual-studio-code`, `docker`). Casks deliver
  ## GUI applications under `/Applications/`.
  ##
  ## `version` is an OPTIONAL version pin. Casks typically track
  ## LATEST only (Homebrew's cask DSL ships one version per cask
  ## in the tap), so the version field is rarely useful — leave
  ## it empty unless the tap genuinely has multi-version support.
  ## A non-empty value that mismatches the installed version
  ## triggers `brew upgrade --cask <name>`.
  ##
  ## `args` is an OPTIONAL list of extra args passed to
  ## `brew install --cask` BEFORE the cask name (e.g.
  ## `--no-quarantine`, `--appdir=...`). Each entry must be a safe
  ## brew flag (no shell metacharacters or whitespace).
  ##
  ## Address default: `pkg.homebrewCask:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    if version.len > 0:
      fields["version"] = strField(version)
    if args.len > 0:
      fields["args"] = listField(args)
    let addr0 = if address.len > 0: address
                else: autoAddress("pkg.homebrewCask", name)
    pushResource(targetResources, "pkg.homebrewCask", addr0,
      fields, dependsOn)

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
                         displayName: string = "";
                         binPath: string = "";
                         recoveryActions: seq[WindowsServiceRecovery] = @[];
                         recoveryResetSeconds: int = 0;
                         address: string = "";
                         dependsOn: seq[string] = @[]) =
  ## Manage an existing Windows service's start-type, runtime state,
  ## and (Windows-System-Resources Phase B) optional descriptor metadata
  ## + recovery policy.
  ##
  ## `displayName`: empty (default) keeps the service's current
  ## `DISPLAY_NAME` — no reconfigure issued. A non-empty value drives
  ## `sc.exe config <name> DisplayName= "<value>"`.
  ##
  ## `binPath`: empty (default) leaves the SCM's current `BINARY_PATH_
  ## NAME` untouched. A non-empty value drives `sc.exe config <name>
  ## binPath= "<value>"`.
  ##
  ## `recoveryActions`: empty (default) leaves the SCM's failure policy
  ## untouched. A non-empty seq drives `sc.exe failure <name> actions= `
  ## with up to three `<action>/<delayMs>` slots; the action enum's
  ## canonical lower-case token (`restart` / `runcommand` / `reboot` /
  ## `none`) is the wire form.
  ##
  ## `recoveryResetSeconds`: `0` (default) means no `reset= ` value is
  ## issued. A positive value drives `sc.exe failure <name> reset= `
  ## (the failure-count reset window the SCM uses).
  ##
  ## Identity remains the service name; the four new fields are
  ## independent and additive — a profile that doesn't set them
  ## applies byte-identically to today.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["startType"] = strField(astToStr(startType))
    fields["state"] = strField(astToStr(state))
    # Phase B: emit the four new fields ONLY when set so a profile that
    # omits them round-trips byte-identically through the codec and the
    # canonical-text renderer.
    if displayName.len > 0:
      fields["displayName"] = strField(displayName)
    if binPath.len > 0:
      fields["binPath"] = strField(binPath)
    if recoveryActions.len > 0:
      fields["recoveryActions"] =
        listField(encodeWindowsServiceRecoveryList(recoveryActions))
    if recoveryResetSeconds != 0:
      fields["recoveryResetSeconds"] = intField(recoveryResetSeconds)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.service", name)
    pushResource(targetResources, "windows.service", addr0, fields,
      dependsOn)

template windowsScheduledTask*(targetResources: var seq[ResourceIntent];
                               taskName: string;
                               executable: string;
                               schedule: ScheduleSpec;
                               arguments: seq[string] = @[];
                               workingDirectory: string = "";
                               runAsUser: string = "SYSTEM";
                               runWithHighestPrivileges: Option[bool] =
                                 none(bool);
                               enabled: bool = true;
                               address: string = "";
                               dependsOn: seq[string] = @[]) =
  ## Manage a Windows Task Scheduler entry. Live state (per
  ## Windows-System-Resources spec §1.3): the schedule, principal,
  ## executable + arguments, and `enabled` flag are observable via
  ## `Get-ScheduledTask`; the driver re-observes on every apply and
  ## skips when the observed digest matches desired.
  ##
  ## `taskName` is the fully-qualified Task Scheduler path
  ## (e.g. `\Reprobuild\WindowsRunner-Env`). Defence-in-depth: an empty
  ## `taskName` is a compile-time error here and a validator reject
  ## downstream (text parser + adapter).
  ##
  ## `executable` is the program the action invokes; `arguments` is the
  ## argv (empty seq omits the field). `workingDirectory` is the CWD
  ## for the action; empty means "let Task Scheduler default".
  ##
  ## `runAsUser` defaults to the special principal `SYSTEM`. Other
  ## accepted values: `LOCAL_SERVICE`, `NETWORK_SERVICE`, a domain user
  ## (`DOMAIN\user`), or a SID literal.
  ##
  ## `runWithHighestPrivileges` is an `Option[bool]` — leave it unset
  ## (the parameter default `none(bool)`) to take the spec's principal-
  ## dependent default. If unset, the text parser and the adapter both
  ## apply that default (`true` for the SYSTEM principal, `false`
  ## otherwise). Pass `some(true)` or `some(false)` to override the
  ## principal default; the explicit value is captured verbatim in the
  ## emitted `ResourceIntent`, round-trips through the codec, and
  ## reaches the apply layer unchanged.
  ##
  ## `schedule` is the discriminated `ScheduleSpec` union — exactly one
  ## of `onBoot`, `onLogon`, `once`, `daily`, `interval`. The encoder
  ## REJECTS malformed values (negative delay, non-positive interval,
  ## empty required-time fields, malformed `HH:MM` / ISO-8601 strings)
  ## at compile time so a hand-authored profile fails closed at the
  ## template surface AND at the validator + adapter downstream.
  ##
  ## `enabled` defaults to `true` (the most common case — a created
  ## task is active).
  ##
  ## Address default: `windows.scheduledTask:<taskName>`.
  block:
    if taskName.len == 0:
      raise newException(ValueError,
        "windows.scheduledTask requires a non-empty taskName")
    if executable.len == 0:
      raise newException(ValueError,
        "windows.scheduledTask '" & taskName &
        "' requires a non-empty executable")
    var fields = initTable[string, FieldValue]()
    fields["taskName"] = strField(taskName)
    fields["executable"] = strField(executable)
    if arguments.len > 0:
      fields["arguments"] = listField(arguments)
    if workingDirectory.len > 0:
      fields["workingDirectory"] = strField(workingDirectory)
    fields["runAsUser"] = strField(runAsUser)
    # Spec rule: default highest-privileges is true for SYSTEM, false
    # otherwise. The template parameter is `Option[bool]` so we can
    # distinguish "operator left it at the parameter default" (none —
    # apply the principal-dependent default downstream) from "operator
    # explicitly set it" (some — capture the operator's choice
    # verbatim). The text parser and the adapter independently re-apply
    # the principal-dependent default when the field is absent.
    if runWithHighestPrivileges.isSome:
      fields["runWithHighestPrivileges"] = boolField(
        runWithHighestPrivileges.get)
    fields["schedule"] = listField(@[encodeScheduleSpec(schedule)])
    fields["enabled"] = boolField(enabled)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.scheduledTask", taskName)
    pushResource(targetResources, "windows.scheduledTask", addr0,
      fields, dependsOn)

# ---------------------------------------------------------------------
# ScheduleSpec constructors (Windows-System-Resources Phase C).
#
# Sugar so profile authors don't have to spell `ScheduleSpec(kind: ..)`
# out by hand. Each variant maps 1:1 to a typed Nim helper and runs the
# same canonical-text validation `encodeScheduleSpec` does — a
# compile-time `static:` guard against malformed literals reaches the
# operator at the template call site.
# ---------------------------------------------------------------------

proc scheduleOnBoot*(delaySeconds: int = 0): ScheduleSpec =
  if delaySeconds < 0:
    raise newException(ValueError,
      "scheduleOnBoot delaySeconds '" & $delaySeconds &
      "' is negative (must be >= 0)")
  ScheduleSpec(kind: sskOnBoot, delaySeconds: delaySeconds)

proc scheduleOnLogon*(forUser: string = ""): ScheduleSpec =
  ScheduleSpec(kind: sskOnLogon, forUser: forUser)

proc scheduleOnce*(runAt: string): ScheduleSpec =
  if not isValidScheduleIso8601(runAt):
    raise newException(ValueError,
      "scheduleOnce runAt '" & runAt &
      "' is not a valid ISO-8601 timestamp")
  ScheduleSpec(kind: sskOnce, runAt: runAt)

proc scheduleDaily*(timeOfDay: string): ScheduleSpec =
  if not isValidScheduleTimeOfDay(timeOfDay):
    raise newException(ValueError,
      "scheduleDaily timeOfDay '" & timeOfDay &
      "' is not a valid HH:MM 24-hour time")
  ScheduleSpec(kind: sskDaily, timeOfDay: timeOfDay)

proc scheduleInterval*(everyMinutes: int;
                      startAt: string = ""): ScheduleSpec =
  if everyMinutes <= 0:
    raise newException(ValueError,
      "scheduleInterval everyMinutes '" & $everyMinutes &
      "' must be > 0")
  if startAt.len > 0 and not isValidScheduleIso8601(startAt):
    raise newException(ValueError,
      "scheduleInterval startAt '" & startAt &
      "' is not a valid ISO-8601 timestamp")
  ScheduleSpec(kind: sskInterval, everyMinutes: everyMinutes,
    startAt: startAt)

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

template windowsAcl*(targetResources: var seq[ResourceIntent];
                     path: string;
                     accessControlEntries: seq[string];
                     owner: string = "";
                     inheritanceMode: string = "enabled";
                     address: string = "";
                     dependsOn: seq[string] = @[]) =
  ## Manage the NTFS DACL on a file or directory via `icacls`.
  ##
  ## `path` is an absolute Windows path (the closed-set validator
  ## rejects `..` segments and shell metacharacters).
  ##
  ## `accessControlEntries` is the list of canonical
  ## `<principal>:<perms>` ACE specs in `icacls /grant` form
  ## (e.g. `"BUILTIN\\Administrators:(OI)(CI)(F)"`,
  ## `"NT AUTHORITY\\SYSTEM:(OI)(CI)(F)"`, `"Zahary:(R,W)"`).
  ##
  ## `owner` is an OPTIONAL NTAccount-form principal or SID; empty
  ## leaves ownership unchanged.
  ##
  ## `inheritanceMode` is one of `enabled` (default) /
  ## `disabled-replace` (disable + remove inherited entries) /
  ## `disabled-convert` (disable + convert inherited to explicit).
  ##
  ## Address default: `windows.acl:<path>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["path"] = strField(path)
    fields["accessControlEntries"] = listField(accessControlEntries)
    fields["owner"] = strField(owner)
    fields["inheritanceMode"] = strField(inheritanceMode)
    let addr0 = if address.len > 0: address
                else: autoAddress("windows.acl", path)
    pushResource(targetResources, "windows.acl", addr0, fields,
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
    # Field is named "type" so it lines up with the adapter
    # (adapter_system.nim's macos.systemDefault arm reads "type") and
    # the text-format emitter (which emits `type = "<value>"`). The
    # constructor's `kind` parameter is kept to preserve the
    # user-facing constructor surface; only the internal field name
    # was misaligned.
    fields["type"] = strField(astToStr(kind))
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
                       content: string = "";
                       sourceUrl: string = "";
                       sha256: string = "";
                       sourceLocal: string = "";
                       mode: string = "0644";
                       address: string = "";
                       dependsOn: seq[string] = @[]) =
  ## A managed system-scope file. The file's content is supplied by
  ## EXACTLY ONE of three mutually-exclusive sources:
  ##
  ##   * `content`     — inline string baked into the plan (the
  ##                     existing behaviour; the historical default).
  ##   * `sourceUrl`   — URL fetched at apply time; the controller
  ##                     downloads the bytes, verifies them against
  ##                     `sha256` (lowercase 64-char hex BLAKE3
  ##                     digest), and only then asks the broker to
  ##                     write. `sha256` MUST also be set.
  ##   * `sourceLocal` — path on the controller side; re-read on every
  ##                     apply so a between-step edit lands. The file
  ##                     is opened by the unprivileged controller
  ##                     before the broker dispatch — the broker
  ##                     receives the bytes, not the path.
  ##
  ## A profile that supplies two or more of these (e.g. both `content`
  ## and `sourceUrl`) is a compile-time error here AND a validator
  ## reject downstream (defence in depth). All three absent means the
  ## resource declares an empty file — equivalent to `content = ""`.
  block:
    # Defence in depth #1: at-most-one-source mutual exclusion. The
    # downstream validator (`profile.parseSystemProfile` and the
    # adapter) re-checks; both layers raise so a bypass at either
    # surface still fails closed.
    let nonEmptySources = (if content.len > 0: 1 else: 0) +
                          (if sourceUrl.len > 0: 1 else: 0) +
                          (if sourceLocal.len > 0: 1 else: 0)
    if nonEmptySources > 1:
      raise newException(ValueError,
        "fs.systemFile '" & path &
        "' declares more than one content source — at most one of " &
        "`content`, `sourceUrl`, `sourceLocal` may be non-empty")
    # Defence in depth #2: `sourceUrl` requires `sha256` (and vice
    # versa — a profile that pins a digest without a URL has no
    # bytes to verify against).
    if sourceUrl.len > 0 and sha256.len == 0:
      raise newException(ValueError,
        "fs.systemFile '" & path &
        "' sets `sourceUrl` but no `sha256` — the URL fetch requires " &
        "a lowercase 64-char BLAKE3 hex digest to verify against")
    if sha256.len > 0 and sourceUrl.len == 0:
      raise newException(ValueError,
        "fs.systemFile '" & path &
        "' sets `sha256` but no `sourceUrl` — the digest is only " &
        "meaningful when paired with a URL fetch")
    var fields = initTable[string, FieldValue]()
    fields["path"] = strField(path)
    fields["content"] = strField(content)
    fields["mode"] = strField(mode)
    if sourceUrl.len > 0:
      fields["sourceUrl"] = strField(sourceUrl)
    if sha256.len > 0:
      fields["sha256"] = strField(sha256)
    if sourceLocal.len > 0:
      fields["sourceLocal"] = strField(sourceLocal)
    let addr0 = if address.len > 0: address
                else: autoAddress("fs.systemFile", path)
    pushResource(targetResources, "fs.systemFile", addr0, fields,
      dependsOn)

# ---------------------------------------------------------------------
# fs.systemDirectory + inline NTFS ACL builder.
#
# `fsSystemDirectory` mirrors `fsSystemFile` minus `content` / `mode`,
# plus an OPTIONAL `acl` parameter that bundles the directory's NTFS
# DACL specification atomically with the directory declaration. The
# corresponding driver creates the directory and (when `acl` is set)
# stamps the declared ACL via `icacls` in one observe / apply cycle, so
# operators no longer need to declare a `windows.acl` companion stanza
# alongside every protected directory.
#
# The ACL is built from `ntfsAcl(owner, entries, inheritance)` with each
# entry produced by `aclEntry(principal, rights, type)`. The builders
# emit canonical ACE strings in the same `icacls /grant`-compatible form
# `windowsAcl` already accepts (e.g. `"BUILTIN\\Administrators:(F)"`),
# so the driver can re-use the existing icacls path without an extra
# layer of translation.
# ---------------------------------------------------------------------

type
  AclRight* = enum
    ## The NTFS access right shorthand exposed by `aclEntry`. Maps to
    ## an `icacls` permission code (the parenthesised letter group):
    ##
    ##   `FullControl`     -> `(F)`   — full control (read, write,
    ##                                  delete, change permissions,
    ##                                  take ownership).
    ##   `ReadAndExecute`  -> `(RX)`  — read + execute.
    ##   `Modify`          -> `(M)`   — read, write, execute, delete.
    ##   `Read`            -> `(R)`   — read.
    ##   `Write`           -> `(W)`   — write.
    ##
    ## The icacls flag set is much larger; this enum surfaces only the
    ## five rights production profiles actually need today. Adding a
    ## new right is a typed change at this enum + the `$` mapping
    ## below; the driver path stays unchanged because the entry
    ## reaches it as a canonical `icacls` ACE string.
    FullControl
    ReadAndExecute
    Modify
    Read
    Write

  AclEntryType* = enum
    ## The ACE direction. `Allow` produces the standard
    ## `<principal>:(<rights>)` ACE the icacls `/grant` verb consumes.
    ## `Deny` produces a `<principal>:(D,<rights>)` form whose leading
    ## `D` code instructs icacls to set a deny ACE rather than an
    ## allow ACE. The driver branches on the leading `D` flag at apply
    ## time.
    Allow
    Deny

  AclInheritance* = enum
    ## Inheritance behaviour the directory's DACL inherits from its
    ## parent. Mapped to one of the string vocabulary
    ## `windowsAcl.inheritanceMode` already understands, plus a new
    ## `protected-clear-inherited` value for the actions-runner case:
    ## disable inheritance AND clear every previously-inherited ACE so
    ## only the explicit declared ACEs remain. The existing
    ## `disabled-replace` is the closest sibling; the new value's
    ## stricter semantics are the production profile's request.
    Enabled
    DisabledReplace
    DisabledConvert
    ProtectedClearInherited

  NtfsAclSpec* = object
    ## A packed declaration of the NTFS DACL the directory should
    ## carry. `present == false` means "the directory's ACL is
    ## unmanaged — let the OS / parent inheritance decide"; the driver
    ## skips every icacls call in that mode and only creates / removes
    ## the directory. When `present == true` the driver:
    ##
    ##   1. (optional) takes ownership via `takeown` + `icacls /setowner`;
    ##   2. applies the inheritance mode (skipped for `enabled`);
    ##   3. issues an `icacls /grant` per entry.
    present*: bool
    owner*: string
    entries*: seq[string]
    inheritance*: string
      ## Serialized form fed straight to the driver — one of `enabled`,
      ## `disabled-replace`, `disabled-convert`,
      ## `protected-clear-inherited`. Stored as a string (not an enum
      ## value) so the `pushResource` field table can carry it
      ## verbatim through the existing string-keyed transport.

proc aclEntry*(principal: string; rights: AclRight;
               `type`: AclEntryType = Allow): string =
  ## Build a canonical `<principal>:(<rights>)` ACE string. The
  ## principal must be NTAccount-form (`BUILTIN\\Administrators`,
  ## `NT AUTHORITY\\SYSTEM`) or a bare local name; the rights enum maps
  ## to one of the five icacls permission codes documented above. An
  ## `Allow` entry produces `"<principal>:(<flag>)"`; a `Deny` entry
  ## produces `"<principal>:(D,<flag>)"` — the leading `D` is the
  ## icacls `/deny`-style marker the driver pivots on at apply time.
  ##
  ## The principal is the operator's responsibility — Nim's string
  ## literal already represents the backslash in `BUILTIN\\Administrators`
  ## as a single `\` byte, which is the form `icacls` expects.
  let flag =
    case rights
    of FullControl: "F"
    of ReadAndExecute: "RX"
    of Modify: "M"
    of Read: "R"
    of Write: "W"
  case `type`
  of Allow:
    principal & ":(" & flag & ")"
  of Deny:
    principal & ":(D," & flag & ")"

proc ntfsAcl*(owner: string = ""; entries: openArray[string];
              inheritance: AclInheritance = Enabled): NtfsAclSpec =
  ## Pack a complete NTFS DACL declaration. `owner` is an OPTIONAL
  ## NTAccount-form principal (empty = leave ownership unchanged);
  ## `entries` is the ACE list produced by `aclEntry`; `inheritance`
  ## selects how the directory inherits from its parent. The result is
  ## consumed by `fsSystemDirectory` via the `acl` parameter.
  let inhStr =
    case inheritance
    of Enabled: "enabled"
    of DisabledReplace: "disabled-replace"
    of DisabledConvert: "disabled-convert"
    of ProtectedClearInherited: "protected-clear-inherited"
  NtfsAclSpec(present: true, owner: owner, entries: @entries,
              inheritance: inhStr)

template fsSystemDirectory*(targetResources: var seq[ResourceIntent];
                            path: string;
                            acl: NtfsAclSpec = NtfsAclSpec(present: false);
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  ## A managed system-scope directory under a recognized system root.
  ## The driver creates the directory at apply time (recursively
  ## auto-creating parents); when `acl` is set, the declared NTFS DACL
  ## is stamped via `icacls` in the same observe / apply cycle so a
  ## profile can declare a protected directory atomically rather than
  ## as a `fs.systemDirectory` + a companion `windows.acl` stanza.
  ##
  ## `path` follows the same allowlist as `fsSystemFile` (`/etc/`,
  ## `/usr/local/etc/`, `${PROGRAMDATA}`) WITH an additional carve-out
  ## for top-level Windows install-root paths like
  ## `C:\\actions-runner` — see `systemDirectoryScopeError` for the
  ## rationale.
  ##
  ## Address default: `fs.systemDirectory:<path>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["path"] = strField(path)
    if acl.present:
      fields["aclOwner"] = strField(acl.owner)
      fields["aclEntries"] = listField(acl.entries)
      fields["aclInheritance"] = strField(acl.inheritance)
    let addr0 = if address.len > 0: address
                else: autoAddress("fs.systemDirectory", path)
    pushResource(targetResources, "fs.systemDirectory", addr0, fields,
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

template linuxTmpfilesRule*(targetResources: var seq[ResourceIntent];
                            name: string;
                            content: string;
                            applyNow: bool = true;
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  ## M83 step 5 — Linux system-scope tmpfiles.d drop-in. Wraps a
  ## write to `/etc/tmpfiles.d/<name>` (`name` must end `.conf`) plus,
  ## when `applyNow == true`, a `systemd-tmpfiles --create <path>`
  ## call so the rule takes effect immediately rather than at next
  ## boot.
  ##
  ## Address default: `linux.tmpfilesRule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    fields["applyNow"] = boolField(applyNow)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.tmpfilesRule", name)
    pushResource(targetResources, "linux.tmpfilesRule", addr0, fields,
      dependsOn)

template linuxSudoersRule*(targetResources: var seq[ResourceIntent];
                           name: string;
                           content: string;
                           address: string = "";
                           dependsOn: seq[string] = @[]) =
  ## M83 step 5 — Linux system-scope sudoers rule drop-in. Wraps a
  ## write to `/etc/sudoers.d/<name>` (`name` must NOT contain `.` —
  ## sudo silently skips dotted files; 0440 mode). The driver
  ## validates the staged content with `visudo -c -f <tmp>` and only
  ## atomically renames into place on success.
  ##
  ## Address default: `linux.sudoersRule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.sudoersRule", name)
    pushResource(targetResources, "linux.sudoersRule", addr0, fields,
      dependsOn)

template passwdGroup*(targetResources: var seq[ResourceIntent];
                      name: string;
                      gid: string = "";
                      members: seq[string] = @[];
                      address: string = "";
                      dependsOn: seq[string] = @[]) =
  ## M83 step 6 — Linux passwd.group companion to `passwd.user`.
  ## Manages an `/etc/group` entry via `groupadd` / `groupmod` /
  ## `usermod -aG`. An empty `gid` leaves the gid unpinned (the
  ## system picks one on create); `members` is the additive
  ## supplementary-membership set the resource declares (a user
  ## already in the group but not declared is NOT removed —
  ## additive-only by default).
  ##
  ## Address default: `passwd.group:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    if gid.len > 0:
      fields["gid"] = strField(gid)
    if members.len > 0:
      fields["members"] = listField(members)
    let addr0 = if address.len > 0: address
                else: autoAddress("passwd.group", name)
    pushResource(targetResources, "passwd.group", addr0, fields,
      dependsOn)

template linuxNixDaemonSetting*(targetResources: var seq[ResourceIntent];
                                key: string;
                                value: string;
                                filename: string = "";
                                address: string = "";
                                dependsOn: seq[string] = @[]) =
  ## M83 step 6 — Linux Nix-daemon configuration drop-in. Writes
  ## `<key> = <value>` to `/etc/nix/nix.conf.d/<filename>`
  ## (auto-derived to `99-reprobuild-<addressOrKey>.conf` when
  ## `filename` is empty). No daemon reload is performed; Nix
  ## re-reads on each invocation.
  ##
  ## Address default: `linux.nixDaemonSetting:<key>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["key"] = strField(key)
    fields["value"] = strField(value)
    fields["filename"] = strField(filename)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.nixDaemonSetting", key)
    pushResource(targetResources, "linux.nixDaemonSetting", addr0,
      fields, dependsOn)

template systemdSystemTimer*(targetResources: var seq[ResourceIntent];
                             name: string;
                             content: string;
                             enabled: bool = true;
                             state: string = "Running";
                             address: string = "";
                             dependsOn: seq[string] = @[]) =
  ## M83 step 6 — systemd system-scope timer companion of
  ## `systemd.systemUnit`. Writes a `.timer` unit file under
  ## `/etc/systemd/system/` (`name` must end `.timer`), runs
  ## `daemon-reload`, and reconciles `enabled` (across-reboot) and
  ## `state` (current `Running` / `Stopped`) independently.
  ##
  ## Address default: `systemd.systemTimer:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    fields["enabled"] = boolField(enabled)
    fields["state"] = strField(state)
    let addr0 = if address.len > 0: address
                else: autoAddress("systemd.systemTimer", name)
    pushResource(targetResources, "systemd.systemTimer", addr0,
      fields, dependsOn)

template linuxFirewallRule*(targetResources: var seq[ResourceIntent];
                            chain: string;
                            name: string;
                            protocol: string;
                            action: string;
                            direction: string = "inbound";
                            localPort: string = "";
                            address: string = "";
                            dependsOn: seq[string] = @[]) =
  ## M83 step 6 — Linux nftables companion of
  ## `windows.firewallRule`. Adds an `nft add rule <chain> <body>`
  ## with a `comment "repro-fw-<name>"` marker for idempotent
  ## observe / destroy. The chain triple is the `<family> <table>
  ## <chain>` form (e.g. `inet filter input`). For `tcp` / `udp`
  ## protocols a non-empty `localPort` is required; for
  ## `icmp` / `icmpv6` it is ignored.
  ##
  ## Address default: `linux.firewallRule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["chain"] = strField(chain)
    fields["name"] = strField(name)
    fields["protocol"] = strField(protocol)
    fields["direction"] = strField(direction)
    if localPort.len > 0:
      fields["localPort"] = strField(localPort)
    fields["action"] = strField(action)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.firewallRule", name)
    pushResource(targetResources, "linux.firewallRule", addr0,
      fields, dependsOn)

template linuxNixosSystemModule*(targetResources: var seq[ResourceIntent];
                                  name: string;
                                  content: string;
                                  address: string = "";
                                  dependsOn: seq[string] = @[]) =
  ## Dotfiles-Migration-Completion M2 — typed NixOS module fragment.
  ## Writes `content` (a verbatim Nix expression — typically a single
  ## attribute set `{ services.pipewire.enable = true; }` or the
  ## module-function form `{ ... }: { ... }`) to
  ## `/etc/nixos/reprobuild-managed/<name>` (`name` must be a
  ## single-segment basename ending `.nix`).
  ##
  ## REPROBUILD DOES NOT RUN `nixos-rebuild switch` — the operator
  ## triggers the rebuild separately. The driver only converges the
  ## file's bytes; the broker's drift gate covers a hand-edited
  ## fragment. The constraint mirrors `linux.nixDaemonSetting`'s "Nix
  ## re-reads on each invocation" model: the file is the source of
  ## truth; the realization step is downstream.
  ##
  ## TEXT-FORMAT CONSTRAINT: the M69 system-profile text round-tripper
  ## quotes each field with simple `"..."` literals and the parser's
  ## `unquote` strips ONE surrounding pair without escapes; the
  ## `content` value therefore MUST NOT contain a double-quote
  ## character. Use Nix's `''...''` URL-string form (which the Nix
  ## parser treats verbatim, no `"` needed) or pre-bind quoted
  ## strings to `let` variables in an upstream module.
  ##
  ## Address default: `linux.nixosSystemModule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.nixosSystemModule", name)
    pushResource(targetResources, "linux.nixosSystemModule", addr0,
      fields, dependsOn)

template macosDarwinSystemModule*(targetResources: var seq[ResourceIntent];
                                   name: string;
                                   content: string;
                                   address: string = "";
                                   dependsOn: seq[string] = @[]) =
  ## Dotfiles-Migration-Completion M2 — typed nix-darwin module
  ## fragment. macOS counterpart of `linuxNixosSystemModule`. Writes
  ## `content` to `/etc/nix-darwin/reprobuild-managed/<name>` (`name`
  ## must be a single-segment basename ending `.nix`). The operator
  ## runs `darwin-rebuild switch` separately to realise it.
  ##
  ## Same text-format quote constraint as `linuxNixosSystemModule`.
  ##
  ## Address default: `macos.darwinSystemModule:<name>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["name"] = strField(name)
    fields["content"] = strField(content)
    let addr0 = if address.len > 0: address
                else: autoAddress("macos.darwinSystemModule", name)
    pushResource(targetResources, "macos.darwinSystemModule", addr0,
      fields, dependsOn)

template fhsSandbox*(targetResources: var seq[ResourceIntent];
                    binPath: string;
                    fhsTrees: openArray[string];
                    argv: openArray[string] = [];
                    address: string = "";
                    dependsOn: seq[string] = @[]) =
  ## Linux-Third-Party-Sandbox-MVP M1 — wrap `binPath` under
  ## bubblewrap with a per-process FHS view composed from the realized
  ## package prefixes in `fhsTrees`. The driver applies the M0-locked
  ## transparency posture: only `/usr / /lib / /lib64 / /bin / /sbin
  ## / /etc` come from a composed realized prefix; `/home / /tmp /
  ## /dev / /sys / /run / /var / /proc` bind-pass to the host; NO
  ## `--unshare-*`, NO `--cap-drop`, NO `--seccomp` flags.
  ##
  ## M1 takes the FIRST `fhsTrees` entry as the single composed
  ## prefix; M2+ adds multi-package overlay / sequential-bind
  ## composition. Both `binPath` and every `fhsTrees` entry MUST be
  ## absolute paths (leading `/`); the parser refuses anything else.
  ## `argv` is the additional argv passed to the wrapped binary; it
  ## passes through `execve` (NOT a shell), so shell-metacharacter
  ## filtering is unnecessary — the parser refuses only NUL bytes.
  ##
  ## Address default: `linux.fhsSandbox:<binPath>`.
  block:
    var fields = initTable[string, FieldValue]()
    fields["binPath"] = strField(binPath)
    fields["fhsTrees"] = listField(@fhsTrees)
    fields["argv"] = listField(@argv)
    let addr0 = if address.len > 0: address
                else: autoAddress("linux.fhsSandbox", binPath)
    pushResource(targetResources, "linux.fhsSandbox", addr0, fields,
      dependsOn)

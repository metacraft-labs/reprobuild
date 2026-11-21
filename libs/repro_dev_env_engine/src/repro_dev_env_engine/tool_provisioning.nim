## repro_dev_env_engine/tool_provisioning.nim
##
## THE resolver of the provisioning mode each ``uses:`` entry is realized
## under. It is the one implementation of that precedence: ``repro build`` /
## ``test`` / ``graph``, the activation surfaces (``exec``, ``shell``,
## ``run``, ``dev-env``) and ``repro tool realize`` all call it, so a tool
## overridden in CI is the same prefix in a build and in an activated shell.
## Keep it the only one: two spellings of the invocation-wide precedence are
## exactly what this module replaced, and they let an activation realize
## tools under one mode while reporting another.
##
## For each ``uses:`` entry the effective mode is the first of:
##
## 1. a ``--tool-provisioning-for=<package>=<mode>`` flag naming its package;
## 2. a ``REPRO_TOOL_PROVISIONING_OVERRIDES`` entry naming it;
## 3. a ``[tool-provisioning.overrides]`` configuration entry naming it, the
##    more specific layer winning: ``repro-workspace.local.toml``, then the
##    committed ``repro-workspace.toml``, then the user configuration;
## 4. the invocation-wide mode: ``--tool-provisioning``, then
##    ``REPRO_TOOL_PROVISIONING``, then the recipe's
##    ``defaultToolProvisioning`` (``effectiveToolProvisioning``).
##
## A recipe never carries an override, not even as a hint: every source
## above is outside the recipe, so a recipe names a tool and never the
## source it is realized from.

import std/[algorithm, options, os, strutils, tables]

import repro_hash
import repro_interface_artifacts
import repro_tool_profiles
import repro_workspace_manifests/[types, reader, settings,
  tool_provisioning_config]

export repro_tool_profiles.ToolModeSelection,
  repro_tool_profiles.ToolModeSelections,
  repro_tool_profiles.ToolProvisioningNoArm,
  repro_tool_profiles.provisioningModeName

const
  ToolProvisioningEnvVar* = "REPRO_TOOL_PROVISIONING"
    ## The invocation-wide mode's variable (level 4 above).
  ToolProvisioningOverridesEnvVar* = "REPRO_TOOL_PROVISIONING_OVERRIDES"
    ## ``<package>=<mode>[,<package>=<mode>...]`` (level 2 above).
  ToolProvisioningForFlag* = "--tool-provisioning-for"
    ## The per-tool flag (level 1 above).

type
  ToolOverrideSource* = enum
    ## Where an override was written, in DEcreasing precedence.
    tosFlag            ## ``--tool-provisioning-for``
    tosEnv             ## ``REPRO_TOOL_PROVISIONING_OVERRIDES``
    tosWorkspaceLocal  ## ``repro-workspace.local.toml``
    tosWorkspace       ## the committed ``repro-workspace.toml``
    tosUser            ## the user configuration (``reprobuild.config.v1``)

  ToolProvisioningOverride* = object
    ## One override, as written in one source.
    packageSelector*: string
    mode*: ToolProvisioningMode
    source*: ToolOverrideSource
    path*: string
      ## The configuration file, for the three configuration sources.
    line*: int
      ## Its line in ``path``, or 0 when unknown.

  ToolProvisioningOverrides* = object
    ## Every override that applies to one invocation, from every source. Two
    ## entries may name the same package from DIFFERENT sources (the higher
    ## one wins); never twice from the same flag or variable, which
    ## ``parseToolProvisioningOverrideList`` refuses.
    entries*: seq[ToolProvisioningOverride]

  ToolProvisioningOverrideError* = object of ValueError
    ## A usage error in an override: an unknown mode, a malformed
    ## ``<package>=<mode>``, one package named twice at one level, or a flag
    ## naming a package no selected ``uses:`` entry references.

proc parseToolProvisioning*(value: string): ToolProvisioningMode =
  ## The provisioning-mode vocabulary of every surface: the flags, both
  ## variables, the configuration and the recipe's
  ## ``defaultToolProvisioning``. ``from-source`` is also spelt
  ## ``fromSource`` (the DSL's name) and ``source``.
  case value.strip()
  of "path":
    tpmPathOnly
  of "nix":
    tpmNix
  of "tarball":
    tpmTarball
  of "scoop":
    tpmScoop
  of "from-source", "fromSource", "source":
    # M9.Q: principled from-source provisioning. Maps each ``uses:
    # <name>`` selector onto a sibling recipe at
    # ``recipes/packages/source/<name>/``.
    tpmFromSource
  else:
    raise newException(ValueError, "unsupported --tool-provisioning=" & value)

proc requestedToolProvisioning*(requested: ToolProvisioningMode):
    ToolProvisioningMode =
  ## The invocation-wide mode the CALLER requested: ``requested`` (the
  ## ``--tool-provisioning`` flag) when it names one, else
  ## ``REPRO_TOOL_PROVISIONING``, else ``tpmUnspecified``. The recipe's
  ## default is applied once the recipe has been read
  ## (``effectiveToolProvisioning``).
  if requested != tpmUnspecified:
    return requested
  let raw = getEnv(ToolProvisioningEnvVar).strip()
  if raw.len == 0:
    return tpmUnspecified
  parseToolProvisioning(raw)

proc effectiveToolProvisioning*(requested: ToolProvisioningMode;
                                artifact: ProjectInterfaceArtifact;
                                consultEnv = true):
    ToolProvisioningMode =
  ## The invocation-wide mode an invocation over ``artifact`` runs under
  ## (level 4 above): an explicitly requested mode, then
  ## ``REPRO_TOOL_PROVISIONING``, then the recipe's own
  ## ``defaultToolProvisioning``. Taking a bare mode rather than a whole
  ## configuration is what lets every surface resolve the SAME mode the
  ## dev-env edge ran under -- two spellings of this precedence is exactly how
  ## an activation ends up realizing tools under one mode and reporting
  ## another.
  ##
  ## ``consultEnv = false`` is for the graph-inspection commands (``graph``,
  ## ``why``, ``stats``), which declare no ``REPRO_TOOL_PROVISIONING`` and
  ## read only their flag and the recipe's default (CLI/graph.md).
  let explicit =
    if consultEnv: requestedToolProvisioning(requested)
    else: requested
  if explicit != tpmUnspecified:
    return explicit
  let defaultMode = artifact.projectInterface.defaultToolProvisioning.strip()
  if defaultMode.len > 0:
    return parseToolProvisioning(defaultMode)
  tpmUnspecified

proc overriddenBy*(entry: ToolProvisioningOverride): string =
  ## The ``overriddenBy`` the identity, the inspection and ``tool realize``
  ## record for ``entry``: ``flag``, ``env`` or ``config:<path>``.
  case entry.source
  of tosFlag: "flag"
  of tosEnv: "env"
  of tosWorkspaceLocal, tosWorkspace, tosUser: "config:" & entry.path

proc location*(entry: ToolProvisioningOverride): string =
  ## Where ``entry`` is written, as a diagnostic names it: the flag as
  ## spelled, the variable's entry, or the configuration file and line.
  let spelled = entry.packageSelector & "=" & provisioningModeName(entry.mode)
  case entry.source
  of tosFlag: ToolProvisioningForFlag & "=" & spelled
  of tosEnv: ToolProvisioningOverridesEnvVar & " entry " & spelled
  of tosWorkspaceLocal, tosWorkspace, tosUser:
    "`" & entry.packageSelector & " = \"" & provisioningModeName(entry.mode) &
      "\"` in " & entry.path & (if entry.line > 0: ":" & $entry.line else: "")

proc overrideError(msg: string): ref ToolProvisioningOverrideError =
  newException(ToolProvisioningOverrideError, msg)

proc parseOverrideEntry(text, origin: string): tuple[package: string;
    mode: ToolProvisioningMode] =
  let eq = text.rfind('=')
  if eq <= 0 or eq == text.high:
    raise overrideError(origin & ": `" & text & "` is not " &
      "`<package>=<mode>`")
  result.package = text[0 ..< eq].strip()
  let modeText = text[eq + 1 .. ^1].strip()
  if result.package.len == 0:
    raise overrideError(origin & ": `" & text & "` names no package")
  try:
    result.mode = parseToolProvisioning(modeText)
  except ValueError:
    raise overrideError(origin & ": `" & modeText & "` is not a " &
      "provisioning mode (path, nix, tarball, scoop or from-source)")

proc parseToolProvisioningOverrideList*(values: openArray[string];
                                        source: ToolOverrideSource):
    seq[ToolProvisioningOverride] =
  ## The overrides of one level that is spelt ``<package>=<mode>``: the
  ## flag's values (``source = tosFlag``, one entry per occurrence) or the
  ## variable's comma-separated list (``tosEnv``, one value). Empty items of
  ## the list are skipped. One package named twice at this level is a usage
  ## error, not last-one-wins.
  let origin =
    if source == tosFlag: ToolProvisioningForFlag
    else: ToolProvisioningOverridesEnvVar
  var seen = initTable[string, string]()
  for value in values:
    let items = if source == tosEnv: value.split(',') else: @[value]
    for raw in items:
      let item = raw.strip()
      if item.len == 0:
        if source == tosFlag:
          raise overrideError(origin & " needs `<package>=<mode>`")
        continue
      let parsed = parseOverrideEntry(item, origin)
      if seen.hasKey(parsed.package):
        raise overrideError(origin & " names `" & parsed.package &
          "` twice (`" & seen[parsed.package] & "` and `" & item &
          "`); give each package one mode")
      seen[parsed.package] = item
      result.add(ToolProvisioningOverride(packageSelector: parsed.package,
        mode: parsed.mode, source: source))

proc configOverrides(entries: openArray[ToolProvisioningConfigEntry];
                     source: ToolOverrideSource):
    seq[ToolProvisioningOverride] =
  for entry in entries:
    var mode: ToolProvisioningMode
    try:
      mode = parseToolProvisioning(entry.mode)
    except ValueError:
      raise overrideError(entry.path &
        (if entry.line > 0: ":" & $entry.line else: "") &
        ": [tool-provisioning.overrides] `" & entry.package & "` names `" &
        entry.mode & "`, which is not a provisioning mode (path, nix, " &
        "tarball, scoop or from-source)")
    result.add(ToolProvisioningOverride(packageSelector: entry.package,
      mode: mode, source: source, path: entry.path, line: entry.line))

proc userConfigToolProvisioningOverrides*(path: string):
    seq[ToolProvisioningConfigEntry] =
  ## The user scope's ``[tool-provisioning.overrides]``, or none when there
  ## is no file at ``path``. The whole file is decoded as the
  ## ``reprobuild.config.v1`` it is first, so an override never makes a
  ## malformed configuration file readable.
  if path.len == 0 or not fileExists(path):
    return
  discard readReprobuildConfig(path)
  toolProvisioningOverridesFromContent(path, readFile(path),
    schemaReprobuildConfigV1)

proc loadToolProvisioningOverrides*(flagValues: openArray[string];
                                    projectRoot: string;
                                    userConfigPath: string):
    ToolProvisioningOverrides =
  ## Every override that applies to an invocation over the project at
  ## ``projectRoot``: the flag's values, ``REPRO_TOOL_PROVISIONING_OVERRIDES``,
  ## the workspace settings found from ``projectRoot`` (the local file and the
  ## committed one) and the user configuration at ``userConfigPath``. Each
  ## source is parsed and checked here, so a bad override fails the
  ## invocation before anything runs. The precedence between them is
  ## ``resolveToolUseProvisioning``'s.
  result.entries.add(parseToolProvisioningOverrideList(flagValues, tosFlag))
  let envValue = getEnv(ToolProvisioningOverridesEnvVar)
  if envValue.strip().len > 0:
    result.entries.add(parseToolProvisioningOverrideList([envValue], tosEnv))
  if projectRoot.len > 0:
    let settingsPath = findWorkspaceSettingsPath(projectRoot)
    if settingsPath.len > 0:
      let workspaceSettings = readWorkspaceSettings(settingsPath)
      result.entries.add(configOverrides(
        workspaceSettings.localToolProvisioningOverrides, tosWorkspaceLocal))
      result.entries.add(configOverrides(
        workspaceSettings.toolProvisioningOverrides, tosWorkspace))
    else:
      let lone = readLoneLocalSettings(projectRoot)
      if lone.isSome:
        result.entries.add(configOverrides(
          lone.get().localToolProvisioningOverrides, tosWorkspaceLocal))
  result.entries.add(configOverrides(
    userConfigToolProvisioningOverrides(userConfigPath), tosUser))

proc winningOverride*(overrides: ToolProvisioningOverrides;
                      packageSelector: string):
    tuple[found: bool; entry: ToolProvisioningOverride] =
  ## The override that decides ``packageSelector``'s mode: the one from the
  ## highest-precedence source (levels 1-3 above).
  if packageSelector.len == 0:
    return
  for entry in overrides.entries:
    if entry.packageSelector != packageSelector:
      continue
    if not result.found or entry.source < result.entry.source:
      result = (found: true, entry: entry)

proc resolveToolUseProvisioning*(requested: ToolProvisioningMode;
                                 overrides: ToolProvisioningOverrides;
                                 artifact: ProjectInterfaceArtifact;
                                 useDef: InterfaceToolUse;
                                 consultEnv = true): ToolModeSelection =
  ## THE per-tool resolver: the mode ``useDef`` is realized under, and
  ## the override that chose it (``overriddenBy`` empty when none did). A
  ## per-tool override beats an explicit invocation-wide flag: that is the
  ## point of it.
  let won = winningOverride(overrides, useDef.packageSelector)
  if won.found:
    return ToolModeSelection(mode: won.entry.mode,
      overriddenBy: won.entry.overriddenBy, location: won.entry.location)
  ToolModeSelection(mode: effectiveToolProvisioning(requested, artifact,
    consultEnv))

proc toolModeSelections*(mode: ToolProvisioningMode;
                         overrides: ToolProvisioningOverrides;
                         uses: openArray[InterfaceToolUse]):
    ToolModeSelections =
  ## The per-tool selections ``repro_tool_profiles.toolBuildIdentity`` takes,
  ## for an invocation already resolved to ``mode``: one entry per use an
  ## override decides, through ``resolveToolUseProvisioning``. A use no
  ## override names is absent, and so realized under ``mode``.
  let invocation = ProjectInterfaceArtifact()
  for useDef in uses:
    if not winningOverride(overrides, useDef.packageSelector).found:
      continue
    result[useDef.packageSelector] =
      resolveToolUseProvisioning(mode, overrides, invocation, useDef)

proc overrideSetDigest*(selections: ToolModeSelections): string =
  ## A digest of the sorted override set that decides an invocation's tools
  ## (it keys the identity files): every overridden package with its mode and
  ## ``overriddenBy``, in package order. "" when nothing is overridden, so
  ## an invocation without overrides keys exactly as before them. The source
  ## is bound because the identity records it (``overriddenBy``): an
  ## identity resolved under a flag must not be served as one resolved under
  ## the configuration.
  if selections.len == 0:
    return ""
  var packages: seq[string] = @[]
  for package in selections.keys:
    packages.add(package)
  packages.sort()
  var payload = "reprobuild.toolProvisioningOverrides.v1\n"
  for package in packages:
    let selection = selections[package]
    for field in [package, provisioningModeName(selection.mode),
                  selection.overriddenBy]:
      payload.add($field.len & ":" & field & "\n")
  var bytes = newSeq[byte](payload.len)
  for i, ch in payload:
    bytes[i] = byte(ord(ch))
  toHex(blake3DomainDigest(bytes, hdMetadataEnvelope).bytes).toLowerAscii()

proc unmatchedOverrides*(overrides: ToolProvisioningOverrides;
                         uses: openArray[InterfaceToolUse]):
    seq[ToolProvisioningOverride] =
  ## The overrides that name a package no entry of ``uses`` references.
  for entry in overrides.entries:
    var matched = false
    for useDef in uses:
      if useDef.packageSelector == entry.packageSelector:
        matched = true
        break
    if not matched:
      result.add(entry)

proc checkOverridesMatch*(overrides: ToolProvisioningOverrides;
                          uses: openArray[InterfaceToolUse];
                          notes: var seq[string]) =
  ## An override naming a package no selected ``uses:`` entry
  ## references is an error when it came from the flag (the caller named it
  ## for this invocation) and a one-line note when it came from the
  ## environment or configuration (both are shared across invocations and
  ## projects). The notes are returned for the caller to print.
  for entry in unmatchedOverrides(overrides, uses):
    if entry.source == tosFlag:
      raise overrideError(entry.location & " names a package no `uses:` " &
        "entry of the selected targets references")
    notes.add("repro: note: tool provisioning override " & entry.location &
      " names a package no `uses:` entry of this invocation references; " &
      "it has no effect here")

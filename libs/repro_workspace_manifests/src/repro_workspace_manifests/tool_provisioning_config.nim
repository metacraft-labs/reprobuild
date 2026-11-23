## repro_workspace_manifests/tool_provisioning_config.nim
##
## The `[tool-provisioning.overrides]` table of reprobuild's configuration
## files: one entry
## per package, naming the provisioning mode that package's `uses:` entries
## are realized under instead of the invocation's mode.
##
##   [tool-provisioning.overrides]
##   ruby-recorder-sdk = "tarball"
##   coreutils = "nix"
##
##   [tool-provisioning.overrides.windows]          # one OS
##   zstd-dev = "tarball"
##
##   [tool-provisioning.overrides.x86_64-linux]     # one <cpu>-<os> pair
##   zstd-dev = "nix"
##
## A platform sub-table holds the overrides for that platform only; within
## one file the `<cpu>-<os>` table beats the `<os>` table, which beats the
## unqualified one (Per-Tool-Provisioning-Overrides.md §4.1). Choosing the
## host's entries is the resolver's: this module returns every platform's.
##
## The table may appear in four files, which the CLI composes: the
## user configuration (`reprobuild.config.v1`), the committed workspace
## settings file (`repro-workspace.toml`), a project's committed
## `repro-tool-provisioning.toml` (read here, by
## ``readProjectToolProvisioningOverrides``) and the workspace-local layer
## (`repro-workspace.local.toml`). This module only reads and shape-checks
## the table; it does not know the mode vocabulary, which belongs to the
## resolver (`repro_dev_env_engine`), and it does not compose the layers.
##
## Read from the generic TOML tree, like the settings files: the pinned
## toml-serialization drops a dotted sub-table header of a typed record, so a
## typed field cannot see `[tool-provisioning.overrides]`. Each entry also
## records the line it is written on, because the refusal of an override
## names "the configuration file and line". TOML reference:
## https://toml.io/en/v1.0.0.

import std/[algorithm, os, strutils]

import types
import diagnostics
import reader

const
  ToolProvisioningTableKey* = "tool-provisioning"
    ## The top-level table that holds the overrides.
  ToolProvisioningOverridesKey* = "overrides"
    ## Its one sub-table.
  ToolProvisioningPlatformOses* = ["linux", "macos", "windows"]
    ## The `<os>` a platform sub-table may name: the OS taxonomy the arm
    ## selection matches the host against (M63 `PlatformOs`).
  ToolProvisioningPlatformCpus* = ["x86_64", "aarch64"]
    ## The `<cpu>` of a `<cpu>-<os>` platform sub-table (M63 `PlatformCpu`).
  ProjectToolProvisioningFileName* = "repro-tool-provisioning.toml"
    ## A project's committed override file, read from the project root
    ## (``readProjectToolProvisioningOverrides``).

proc isTable(n: TomlValueRef): bool =
  not n.isNil and n.kind in {TomlKind.Table, TomlKind.InlineTable}

proc bareKey(line: string): string =
  ## The key of a `key = value` line (bare or quoted), or "" when the line is
  ## not one.
  let stripped = line.strip()
  if stripped.len == 0 or stripped[0] in {'#', '['}:
    return ""
  let eq = stripped.find('=')
  if eq <= 0:
    return ""
  result = stripped[0 ..< eq].strip()
  if result.len >= 2 and result[0] in {'"', '\''} and
      result[^1] == result[0]:
    result = result[1 .. ^2]

proc platformHeader(platform: string): string =
  ## The table header an entry for ``platform`` is written under.
  result = ToolProvisioningTableKey & "." & ToolProvisioningOverridesKey
  if platform.len > 0:
    result.add("." & platform)

proc entryLine(content, package, platform: string): int =
  ## The 1-based line `package` is written on inside the overrides table for
  ## `platform` ("" for the unqualified table), or 0 when it cannot be
  ## located (an inline-table spelling on a line of its own is still found by
  ## the second pass). Advisory: it serves the diagnostics only, so a line it
  ## cannot find costs precision, not correctness.
  let lines = content.splitLines()
  let wanted = platformHeader(platform)
  var inSection = false
  for i, line in lines:
    let stripped = line.strip()
    if stripped.startsWith("["):
      let header = stripped.strip(chars = {'[', ']', ' '})
      inSection = header == wanted
      continue
    if inSection and bareKey(line) == package:
      return i + 1
  # The inline and dotted-key spellings: the first line naming the package
  # as a key after the table's name (and the platform's, when it has one).
  var seenTable = false
  for i, line in lines:
    if ToolProvisioningTableKey in line or ToolProvisioningOverridesKey in line:
      seenTable = platform.len == 0 or platform in line
    if seenTable and (package & " =" in line or package & "=" in line or
        "\"" & package & "\"" in line):
      return i + 1
  0

proc isToolProvisioningPlatform*(key: string): bool =
  ## Whether ``key`` names a platform a `[tool-provisioning.overrides.<key>]`
  ## sub-table may be written for: an `<os>` of
  ## ``ToolProvisioningPlatformOses`` or a `<cpu>-<os>` pair with a cpu of
  ## ``ToolProvisioningPlatformCpus``, spelt as the arm selection names the
  ## host (`repro_tool_profiles.hostPlatformName`).
  if key in ToolProvisioningPlatformOses:
    return true
  let dash = key.find('-')
  dash > 0 and key[0 ..< dash] in ToolProvisioningPlatformCpus and
    key[dash + 1 .. ^1] in ToolProvisioningPlatformOses

proc platformNames(): string =
  var names: seq[string] = @[]
  for os in ToolProvisioningPlatformOses:
    names.add(os)
  for cpu in ToolProvisioningPlatformCpus:
    for os in ToolProvisioningPlatformOses:
      names.add(cpu & "-" & os)
  names.join(", ")

proc readOverrideTable(path, content, schema, keyPath, platform: string;
                       table: TomlValueRef;
                       result: var seq[ToolProvisioningConfigEntry]) =
  ## The `<package> = "<mode>"` entries of one overrides table, in package
  ## order (TOML tables are unordered), for ``platform``. In the unqualified
  ## table (``platform == ""``) a table-valued key is a platform sub-table and
  ## is read recursively; inside a platform table it is an error.
  var packages: seq[string] = @[]
  for package, _ in table.tableVal[]:
    packages.add(package)
  packages.sort()
  for package in packages:
    let value = table.tableVal[package]
    if package.strip().len == 0:
      raiseManifestError(path, keyPath, schema, schema,
        "an override's package name must not be empty")
    if isTable(value):
      if platform.len > 0:
        raiseManifestError(path, keyPath & "." & package, schema, schema,
          "`" & keyPath & "` is the table for " & platform & "; it holds " &
            "`<package> = \"<mode>\"` entries only, not another table")
      if not isToolProvisioningPlatform(package):
        raiseManifestError(path, keyPath & "." & package, schema, schema,
          "`" & package & "` is not a platform a per-tool override can be " &
            "written for (" & platformNames() & "); an override is " &
            "`<package> = \"<mode>\"`")
      readOverrideTable(path, content, schema, keyPath & "." & package,
        package, value, result)
      continue
    if value.isNil or value.kind != TomlKind.String or
        value.stringVal.strip().len == 0:
      raiseManifestError(path, keyPath & "." & package, schema, schema,
        "`" & package & "` must name a provisioning mode as a string " &
          "(`path`, `nix`, `tarball`, `scoop` or `from-source`), or be a " &
          "platform table (" & platformNames() & ")")
    result.add(ToolProvisioningConfigEntry(package: package,
      mode: value.stringVal.strip(), path: path,
      line: entryLine(content, package, platform), platform: platform))

proc toolProvisioningOverridesFromTree*(path, content, schema: string;
                                        tree: TomlValueRef):
    seq[ToolProvisioningConfigEntry] =
  ## The overrides of one configuration file, given its decoded tree: the
  ## unqualified table's entries in package-name order, then each platform
  ## table's in platform order. Entries for every platform are returned (each
  ## records its ``platform``); choosing the host's is the resolver's, so a
  ## bad entry for another platform is still refused on this one. Empty when
  ## the file has no `tool-provisioning` table. A malformed table raises a
  ## `WorkspaceManifestParseError` naming the file and key path: a
  ## `tool-provisioning` that is not a table, a key other than `overrides`
  ## under it, an `overrides` that is not a table, a sub-table that names no
  ## known platform or nests another table, or a value that is not a
  ## non-empty string.
  if not isTable(tree) or ToolProvisioningTableKey notin tree.tableVal:
    return
  let section = tree.tableVal[ToolProvisioningTableKey]
  if not isTable(section):
    raiseManifestError(path, ToolProvisioningTableKey, schema, schema,
      "`" & ToolProvisioningTableKey & "` must be a table")
  for key, _ in section.tableVal[]:
    if key != ToolProvisioningOverridesKey:
      raiseManifestError(path, ToolProvisioningTableKey & "." & key, schema,
        schema, "`" & ToolProvisioningTableKey & "` carries only `" &
          ToolProvisioningOverridesKey & "`; `" & key &
          "` is not part of it")
  if ToolProvisioningOverridesKey notin section.tableVal:
    return
  let overrides = section.tableVal[ToolProvisioningOverridesKey]
  let keyPath = ToolProvisioningTableKey & "." & ToolProvisioningOverridesKey
  if not isTable(overrides):
    raiseManifestError(path, keyPath, schema, schema,
      "`" & keyPath & "` must be a table of `<package> = \"<mode>\"`")
  readOverrideTable(path, content, schema, keyPath, "", overrides, result)

proc toolProvisioningOverridesFromContent*(path, content, schema: string):
    seq[ToolProvisioningConfigEntry] =
  ## ``toolProvisioningOverridesFromTree`` over the file's text.
  toolProvisioningOverridesFromTree(path, content, schema,
    decodeTree(path, content, schema))

proc readProjectToolProvisioningOverrides*(projectRoot: string):
    seq[ToolProvisioningConfigEntry] =
  ## The overrides a project commits in ``ProjectToolProvisioningFileName`` at
  ## ``projectRoot``, or none when it has no such file
  ## (Per-Tool-Provisioning-Overrides.md §4.1). The file is how a product
  ## repository that is built both standalone and inside a workspace commits
  ## an override every checkout of it needs: unlike `repro-workspace.toml` it
  ## is not a workspace-root marker (``findWorkspaceSettingsPath`` never looks
  ## for it), so it cannot shadow the real root's settings. It carries
  ## `schema` and `[tool-provisioning.overrides]` (with its platform tables)
  ## and nothing else; any other key, or another schema, is refused naming
  ## the file.
  if projectRoot.len == 0:
    return
  let path = absolutePath(projectRoot) / ProjectToolProvisioningFileName
  if not fileExists(path):
    return
  let schema = schemaProjectToolProvisioningV1
  let content = readFile(path)
  let tree = decodeTree(path, content, schema)
  let declared =
    if isTable(tree) and "schema" in tree.tableVal: tree.tableVal["schema"]
    else: nil
  if declared.isNil or declared.kind != TomlKind.String or
      declared.stringVal.strip().len == 0:
    raiseManifestError(path, "schema", schema, "",
      "top-level `schema` key is missing or empty")
  if declared.stringVal != schema:
    raiseManifestError(path, "schema", schema, declared.stringVal,
      "schema version mismatch")
  for key, _ in tree.tableVal[]:
    if key notin ["schema", ToolProvisioningTableKey]:
      raiseManifestError(path, key, schema, schema,
        "`" & key & "` cannot be declared in " &
          ProjectToolProvisioningFileName & ": it carries " &
          "`[tool-provisioning.overrides]` only. Workspace policy belongs in " &
          "repro-workspace.toml at the workspace root")
  toolProvisioningOverridesFromTree(path, content, schema, tree)

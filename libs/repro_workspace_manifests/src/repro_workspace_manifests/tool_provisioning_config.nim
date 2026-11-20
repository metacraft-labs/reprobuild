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
## The table may appear in three files, which the CLI composes: the
## user configuration (`reprobuild.config.v1`), the committed workspace
## settings file (`repro-workspace.toml`) and the workspace-local layer
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

import std/[algorithm, strutils]

import types
import diagnostics
import reader

const
  ToolProvisioningTableKey* = "tool-provisioning"
    ## The top-level table that holds the overrides.
  ToolProvisioningOverridesKey* = "overrides"
    ## Its one sub-table.

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

proc entryLine(content, package: string): int =
  ## The 1-based line `package` is written on inside the overrides table, or
  ## 0 when it cannot be located (an inline-table spelling on a line of its
  ## own is still found by the second pass). Advisory: it serves the
  ## diagnostics only, so a line it cannot find costs precision, not
  ## correctness.
  let lines = content.splitLines()
  var inSection = false
  for i, line in lines:
    let stripped = line.strip()
    if stripped.startsWith("["):
      let header = stripped.strip(chars = {'[', ']', ' '})
      inSection = header == ToolProvisioningTableKey & "." &
        ToolProvisioningOverridesKey
      continue
    if inSection and bareKey(line) == package:
      return i + 1
  # The inline and dotted-key spellings: the first line naming the package
  # as a key after the table's name.
  var seenTable = false
  for i, line in lines:
    if ToolProvisioningTableKey in line or ToolProvisioningOverridesKey in line:
      seenTable = true
    if seenTable and (package & " =" in line or package & "=" in line or
        "\"" & package & "\"" in line):
      return i + 1
  0

proc toolProvisioningOverridesFromTree*(path, content, schema: string;
                                        tree: TomlValueRef):
    seq[ToolProvisioningConfigEntry] =
  ## The overrides of one configuration file, given its decoded tree, in
  ## package-name order (TOML tables are unordered). Empty when the file has
  ## no `tool-provisioning` table. A malformed table raises a
  ## `WorkspaceManifestParseError` naming the file and key path: a
  ## `tool-provisioning` that is not a table, a key other than `overrides`
  ## under it, an `overrides` that is not a table, or a value that is not a
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
  var packages: seq[string] = @[]
  for package, _ in overrides.tableVal[]:
    packages.add(package)
  packages.sort()
  for package in packages:
    let value = overrides.tableVal[package]
    if package.strip().len == 0:
      raiseManifestError(path, keyPath, schema, schema,
        "an override's package name must not be empty")
    if value.isNil or value.kind != TomlKind.String or
        value.stringVal.strip().len == 0:
      raiseManifestError(path, keyPath & "." & package, schema, schema,
        "`" & package & "` must name a provisioning mode as a string " &
          "(`path`, `nix`, `tarball`, `scoop` or `from-source`)")
    result.add(ToolProvisioningConfigEntry(package: package,
      mode: value.stringVal.strip(), path: path,
      line: entryLine(content, package)))

proc toolProvisioningOverridesFromContent*(path, content, schema: string):
    seq[ToolProvisioningConfigEntry] =
  ## ``toolProvisioningOverridesFromTree`` over the file's text.
  toolProvisioningOverridesFromTree(path, content, schema,
    decodeTree(path, content, schema))

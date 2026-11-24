## Reads the ``[workspace]`` table of a Cargo manifest as TOML.
##
## The Rust convention's ``cargo metadata`` emit cache must know the glob
## patterns of a workspace's ``members`` before it decides whether to run
## cargo (Rust.md §"The ``cargo metadata`` emit cache"), and the cached
## output does not report them. This module reads them with the vendored
## ``toml_serialization``, so multi-line arrays, comments, and basic and
## literal strings read as Cargo reads them (Cargo reference, "Workspaces",
## "The ``members`` and ``exclude`` fields":
## https://doc.rust-lang.org/cargo/reference/workspaces.html#the-members-and-exclude-fields).
##
## It is its own module because ``toml_serialization`` re-exports
## ``faststreams``, whose ``fileInput`` and others would collide with the
## emit-cache helpers of the same names wherever it is imported. Only the
## plain result type below leaves this module.

import std/tables

import toml_serialization
import toml_serialization/types as toml_types

import repro_core

type
  CargoWorkspaceMembers* = object
    ok*: bool
      ## false when the manifest cannot be read or is not TOML a reader
      ## here accepts, or ``members`` is not an array of strings (which
      ## Cargo refuses as well). A caller must then treat the members as
      ## unknown.
    hasWorkspace*: bool
      ## the manifest has a ``[workspace]`` table (only meaningful when
      ## ``ok``)
    patterns*: seq[string]
      ## the ``members`` strings, in manifest order, as written (paths or
      ## glob patterns relative to the manifest's directory)

proc readCargoManifestToml(manifestPath: string):
    tuple[ok: bool; root: TomlValueRef] =
  ## Parse ``manifestPath`` as TOML. ``ok`` is false when the file cannot
  ## be read or is not a TOML table.
  try:
    let parsed = Toml.decode(readFile(extendedPath(manifestPath)),
      TomlValueRef)
    if parsed.isNil or
        parsed.kind notin {TomlKind.Table, TomlKind.InlineTable} or
        parsed.tableVal.isNil:
      return (false, nil)
    (true, parsed)
  except CatchableError:
    (false, nil)

proc tomlTableField(table: TomlValueRef; key: string): TomlValueRef =
  ## ``table[key]``, or nil when ``table`` is no table or lacks ``key``.
  if table.isNil or table.kind notin {TomlKind.Table, TomlKind.InlineTable} or
      table.tableVal.isNil or not table.tableVal[].hasKey(key):
    return nil
  table.tableVal[][key]

proc readCargoWorkspaceMembers*(manifestPath: string): CargoWorkspaceMembers =
  ## The ``members`` of the ``[workspace]`` table of ``manifestPath``, and
  ## whether it has such a table. A manifest with a ``[workspace]`` table
  ## and no ``members`` key reads as ``ok`` with no patterns.
  let (parsed, root) = readCargoManifestToml(manifestPath)
  if not parsed:
    return CargoWorkspaceMembers(ok: false)
  let workspace = tomlTableField(root, "workspace")
  if workspace.isNil:
    return CargoWorkspaceMembers(ok: true, hasWorkspace: false)
  if workspace.kind notin {TomlKind.Table, TomlKind.InlineTable}:
    # ``workspace = "..."`` at the top level is no table Cargo accepts.
    return CargoWorkspaceMembers(ok: false, hasWorkspace: true)
  result = CargoWorkspaceMembers(ok: true, hasWorkspace: true)
  let members = tomlTableField(workspace, "members")
  if members.isNil:
    return
  if members.kind != TomlKind.Array:
    return CargoWorkspaceMembers(ok: false, hasWorkspace: true)
  for member in members.arrayVal:
    if member.isNil or member.kind != TomlKind.String:
      return CargoWorkspaceMembers(ok: false, hasWorkspace: true)
    result.patterns.add(member.stringVal)

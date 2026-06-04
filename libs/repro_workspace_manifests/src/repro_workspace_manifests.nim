# repro_workspace_manifests.nim — public surface of the M5 manifest reader.
#
# Wraps `nim-toml-serialization` (status-im) in strict mode and exposes one
# `read*` proc per workspace schema documented in
# `reprobuild-specs/Workspace-Manifests.md`. The vendored upstream is pinned
# at b5b387e6fb2a7cc75d54a269b07cc6218361bd46 (v0.2.18) — see
# `repro_workspace_manifests/reader.nim` for the comment carrying the SHA.

import repro_workspace_manifests/[types, diagnostics, reader, resolver,
  compose, sync_planner, manifest_refresh, lock_writer, workspace_branch,
  develop_overrides]

export types
export diagnostics
export reader
export resolver
export compose
export sync_planner
export manifest_refresh
export lock_writer
export workspace_branch
export develop_overrides

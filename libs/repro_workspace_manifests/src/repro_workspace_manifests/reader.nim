# repro_workspace_manifests/reader.nim
#
# nim-toml-serialization pinned at status-im/nim-toml-serialization
# b5b387e6fb2a7cc75d54a269b07cc6218361bd46 (v0.2.18).
#
# Public `read*` procs for every schema in Workspace-Manifests.md. The
# pattern is identical across schemas:
#
#   1. Slurp the file (turn IO errors into structured diagnostics).
#   2. Run a permissive probe that extracts the top-level `schema` string
#      (with `TomlUnknownFields` set so the probe never trips on the
#      schema's body shape). Compare against the expected version.
#   3. Strict-decode the typed record via `Toml.decode`. Convert any
#      strict-mode parser error into `WorkspaceManifestParseError`, lifting
#      the offending key into `keyPath`.
#   4. Enforce required-key invariants the strict reader cannot enforce on
#      its own (status-im/nim-toml-serialization silently default-initialises
#      missing scalar fields).

import std/[options, os, strutils]
import toml_serialization
import toml_serialization/types as toml_types
import types
import diagnostics

# ---- helpers --------------------------------------------------------------

proc slurpManifest(path, expectedSchema: string): string =
  ## Read the file at `path`. Raise a `WorkspaceManifestParseError` with an
  ## empty `keyPath` / empty `observedSchema` if the file is missing or
  ## unreadable; that empty `observedSchema` is the documented shape for
  ## file-level failures.
  if not fileExists(path):
    raiseManifestError(path, "", expectedSchema, "",
      "manifest file does not exist")
  try:
    result = readFile(path)
  except IOError as e:
    raiseManifestError(path, "", expectedSchema, "", e.msg)
  except OSError as e:
    raiseManifestError(path, "", expectedSchema, "", e.msg)

proc validateSchema(path, content, expectedSchema: string) =
  ## Permissive probe: extracts the top-level `schema` value via
  ## `Toml.decode(..., string, "schema")`, which navigates to just that
  ## key and ignores the rest of the file. Raises
  ## `WorkspaceManifestParseError` on schema-version mismatch, on a missing
  ## `schema` key (observed = ""), or on a probe-level TOML parse failure.
  ##
  ## When the top-level `schema` key itself is missing, the toml-serialization
  ## parser raises `TomlError` with the canonical message
  ## "key not found: 'schema'". The wrapper translates that into a structured
  ## diagnostic with `keyPath = "schema"` and `observedSchema = ""` so the
  ## downstream caller can tell schema-missing apart from schema-mismatch.
  var observed: string
  try:
    observed = Toml.decode(content, string, "schema")
  except TomlError as e:
    let lowered = e.msg.toLowerAscii()
    if "key not found" in lowered and "'schema'" in lowered:
      raiseManifestError(path, "schema", expectedSchema, "",
        "top-level `schema` key is missing")
    raiseManifestError(path, "", expectedSchema, "", e.msg)
  except CatchableError as e:
    raiseManifestError(path, "", expectedSchema, "", e.msg)

  if observed.len == 0:
    raiseManifestError(path, "schema", expectedSchema, "",
      "top-level `schema` key is missing or empty")

  if observed != expectedSchema:
    raiseManifestError(path, "schema", expectedSchema, observed,
      "schema version mismatch")

proc fallbackTomlMessage(): string =
  ## Synthetic diagnostic for the case where status-im/nim-toml-serialization
  ## raises a ``TomlError`` whose ``msg`` is the empty string. The empty-msg
  ## arm is rare on Linux but reproducibly hit on Windows fixtures that
  ## interpolate raw Windows paths into TOML basic strings: ``"C:\Users\..."``
  ## is parsed as the invalid escape ``\U`` (TOML basic strings reserve
  ## ``\u`` / ``\U`` for 4- / 8-hex-digit Unicode escapes). Without the
  ## fallback the wrapped ``WorkspaceManifestParseError`` ends up with an
  ## empty ``innerMessage`` and the diagnostic reads ``schema expected=X
  ## observed=X:`` with no explanation. The fallback names the most likely
  ## culprit so the next failure is actionable rather than opaque.
  "TOML parser raised with no message; common cause: unescaped backslash " &
    "in a basic string (\"...\") — TOML reads \\U / \\u / \\b / \\f / " &
    "\\n / \\r / \\t / \\\" / \\\\ as escape sequences. If the value is a " &
    "filesystem path or file:// URL, escape backslashes (\\\\) or switch to " &
    "forward slashes / TOML literal strings ('...')."

proc decodeStrict[T](path, content, expectedSchema: string;
                     RecordType: typedesc[T]): T =
  ## Strict-mode decode of the typed record. The `TomlUnknownFields` flag is
  ## deliberately NOT set: any unknown top-level key (or unknown key under
  ## one of the declared sub-tables) raises a `TomlError` whose message we
  ## scrape for the offending key path.
  try:
    result = Toml.decode(content, RecordType)
  except TomlError as e:
    let inner = if e.msg.len > 0: e.msg else: fallbackTomlMessage()
    let keyPath = extractStrictModeKeyPath(e.msg)
    raiseManifestError(path, keyPath, expectedSchema, expectedSchema, inner)
  except CatchableError as e:
    let inner = if e.msg.len > 0: e.msg else: fallbackTomlMessage()
    raiseManifestError(path, "", expectedSchema, expectedSchema, inner)

template requireNonEmpty(path, expectedSchema, keyPath, value: untyped) =
  ## status-im/nim-toml-serialization silently fills a missing scalar with
  ## that scalar's zero value. The schema spec marks specific keys
  ## load-bearing; this guard turns "missing required key" into a structured
  ## diagnostic rather than a misleading downstream failure.
  if value.len == 0:
    raiseManifestError(path, keyPath, expectedSchema, expectedSchema,
      "required key `" & keyPath & "` is missing or empty")

# ---- repos/<repo>.toml -----------------------------------------------------

proc readRepoFragment*(path: string): RepoFragment =
  let content = slurpManifest(path, schemaRepoFragmentV1)
  validateSchema(path, content, schemaRepoFragmentV1)
  result = decodeStrict(path, content, schemaRepoFragmentV1, RepoFragment)
  requireNonEmpty(path, schemaRepoFragmentV1, "repo.name", result.repo.name)
  requireNonEmpty(path, schemaRepoFragmentV1, "repo.path", result.repo.path)

# ---- projects/<project>.toml ----------------------------------------------

proc readProjectManifest*(path: string): ProjectManifest =
  let content = slurpManifest(path, schemaProjectManifestV1)
  validateSchema(path, content, schemaProjectManifestV1)
  result = decodeStrict(path, content, schemaProjectManifestV1,
                        ProjectManifest)
  requireNonEmpty(path, schemaProjectManifestV1, "project.name",
                  result.project.name)
  for i, r in result.remote:
    if r.name.len == 0:
      raiseManifestError(path, "remote[" & $i & "].name",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "required key `remote[].name` is missing or empty")
    if r.fetch.len == 0:
      raiseManifestError(path, "remote[" & $i & "].fetch",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "required key `remote[].fetch` is missing or empty")

# ---- variants/<...>.toml ---------------------------------------------------

proc readVariantManifest*(path: string): VariantManifest =
  let content = slurpManifest(path, schemaVariantManifestV1)
  validateSchema(path, content, schemaVariantManifestV1)
  result = decodeStrict(path, content, schemaVariantManifestV1,
                        VariantManifest)
  requireNonEmpty(path, schemaVariantManifestV1, "variant.name",
                  result.variant.name)
  requireNonEmpty(path, schemaVariantManifestV1, "variant.base",
                  result.variant.base)
  for i, o in result.`override`:
    if o.fragment.len == 0:
      raiseManifestError(path, "override[" & $i & "].fragment",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "required key `override[].fragment` is missing or empty")

# ---- locks/<project>/<sha>.toml --------------------------------------------

proc readLock*(path: string): Lock =
  let content = slurpManifest(path, schemaLockV1)
  validateSchema(path, content, schemaLockV1)
  result = decodeStrict(path, content, schemaLockV1, Lock)
  requireNonEmpty(path, schemaLockV1, "lock.project", result.lock.project)
  requireNonEmpty(path, schemaLockV1, "lock.created_at", result.lock.created_at)
  for i, r in result.repo:
    if r.name.len == 0:
      raiseManifestError(path, "repo[" & $i & "].name",
        schemaLockV1, schemaLockV1,
        "required key `repo[].name` is missing or empty")
    if r.path.len == 0:
      raiseManifestError(path, "repo[" & $i & "].path",
        schemaLockV1, schemaLockV1,
        "required key `repo[].path` is missing or empty")
    if r.remote.len == 0:
      raiseManifestError(path, "repo[" & $i & "].remote",
        schemaLockV1, schemaLockV1,
        "required key `repo[].remote` is missing or empty")
    if r.revision.len == 0:
      raiseManifestError(path, "repo[" & $i & "].revision",
        schemaLockV1, schemaLockV1,
        "required key `repo[].revision` is missing or empty")

# ---- locks/<project>/index.toml --------------------------------------------

proc readLockIndex*(path: string): LockIndex =
  let content = slurpManifest(path, schemaLockIndexV1)
  validateSchema(path, content, schemaLockIndexV1)
  result = decodeStrict(path, content, schemaLockIndexV1, LockIndex)
  for i, e in result.entry:
    if e.trigger_repo.len == 0:
      raiseManifestError(path, "entry[" & $i & "].trigger_repo",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].trigger_repo` is missing or empty")
    if e.trigger_sha.len == 0:
      raiseManifestError(path, "entry[" & $i & "].trigger_sha",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].trigger_sha` is missing or empty")
    if e.lock_file.len == 0:
      raiseManifestError(path, "entry[" & $i & "].lock_file",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].lock_file` is missing or empty")
    if e.created_at.len == 0:
      raiseManifestError(path, "entry[" & $i & "].created_at",
        schemaLockIndexV1, schemaLockIndexV1,
        "required key `entry[].created_at` is missing or empty")

# ---- snapshots/<name>.toml -------------------------------------------------

proc readSnapshot*(path: string): Snapshot =
  let content = slurpManifest(path, schemaSnapshotV1)
  validateSchema(path, content, schemaSnapshotV1)
  result = decodeStrict(path, content, schemaSnapshotV1, Snapshot)
  requireNonEmpty(path, schemaSnapshotV1, "snapshot.name", result.snapshot.name)
  requireNonEmpty(path, schemaSnapshotV1, "snapshot.project",
                  result.snapshot.project)
  requireNonEmpty(path, schemaSnapshotV1, "snapshot.created_at",
                  result.snapshot.created_at)
  for i, r in result.repo:
    if r.name.len == 0:
      raiseManifestError(path, "repo[" & $i & "].name",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].name` is missing or empty")
    if r.path.len == 0:
      raiseManifestError(path, "repo[" & $i & "].path",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].path` is missing or empty")
    if r.remote.len == 0:
      raiseManifestError(path, "repo[" & $i & "].remote",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].remote` is missing or empty")
    if r.revision.len == 0:
      raiseManifestError(path, "repo[" & $i & "].revision",
        schemaSnapshotV1, schemaSnapshotV1,
        "required key `repo[].revision` is missing or empty")

# ---- .repro/workspace.toml -------------------------------------------------

proc readWorkspaceLocal*(path: string): WorkspaceLocal =
  let content = slurpManifest(path, schemaWorkspaceLocalV1)
  validateSchema(path, content, schemaWorkspaceLocalV1)
  result = decodeStrict(path, content, schemaWorkspaceLocalV1, WorkspaceLocal)
  requireNonEmpty(path, schemaWorkspaceLocalV1, "workspace.project",
                  result.workspace.project)
  for i, m in result.manifest:
    let hasUrl = m.url.isSome and m.url.get().len > 0
    let hasLocal = m.local_path.isSome and m.local_path.get().len > 0
    if not hasUrl and not hasLocal:
      raiseManifestError(path,
        "manifest[" & $i & "].url|local_path",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "manifest layer needs either `url` or `local_path`")
    if m.visibility.len == 0:
      raiseManifestError(path,
        "manifest[" & $i & "].visibility",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "required key `manifest[].visibility` is missing or empty")

# ---- .repro/develop-overrides.toml -----------------------------------------

proc readDevelopOverrides*(path: string): DevelopOverrides =
  let content = slurpManifest(path, schemaDevelopOverridesV1)
  validateSchema(path, content, schemaDevelopOverridesV1)
  result = decodeStrict(path, content, schemaDevelopOverridesV1,
                        DevelopOverrides)
  for i, o in result.`override`:
    if o.package.len == 0:
      raiseManifestError(path, "override[" & $i & "].package",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].package` is missing or empty")
    if o.local_path.len == 0:
      raiseManifestError(path, "override[" & $i & "].local_path",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].local_path` is missing or empty")
    if o.state.len == 0:
      raiseManifestError(path, "override[" & $i & "].state",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].state` is missing or empty")
    if o.created_at.len == 0:
      raiseManifestError(path, "override[" & $i & "].created_at",
        schemaDevelopOverridesV1, schemaDevelopOverridesV1,
        "required key `override[].created_at` is missing or empty")

# ---- <host-repo>/.repro-workspace.toml (RA-8 host bootstrap config) ---------

const
  bootstrapConfigFileName* = ".repro-workspace.toml"
    ## Canonical file name of the committed host bootstrap config.
  bootstrapPrivateConfigFileName* = ".repro-workspace-private.toml"
    ## Sibling file carrying credentialed/SSH manifest URLs.

proc readWorkspaceBootstrapPrivate*(path: string): WorkspaceBootstrapPrivate =
  ## Read the private companion config (`.repro-workspace-private.toml`). The
  ## only load-bearing key is `[manifest] private_url`.
  let content = slurpManifest(path, schemaWorkspaceBootstrapV1)
  validateSchema(path, content, schemaWorkspaceBootstrapV1)
  result = decodeStrict(path, content, schemaWorkspaceBootstrapV1,
                        WorkspaceBootstrapPrivate)
  requireNonEmpty(path, schemaWorkspaceBootstrapV1, "manifest.private_url",
                  result.manifest.private_url)

proc readWorkspaceBootstrap*(path: string): WorkspaceBootstrap =
  ## Read a host bootstrap config (`.repro-workspace.toml`). The only
  ## load-bearing required key is `[manifest] url` — without a manifest URL the
  ## config does not configure anything and the caller must fail loud rather
  ## than fall back to a baked-in org default.
  ##
  ## When a sibling `.repro-workspace-private.toml` exists next to `path` and
  ## the public config did not already set `[manifest] private_url`, the
  ## private companion's `[manifest] private_url` is folded into the returned
  ## record so credentialed URLs never have to live in the committed file.
  let content = slurpManifest(path, schemaWorkspaceBootstrapV1)
  validateSchema(path, content, schemaWorkspaceBootstrapV1)
  result = decodeStrict(path, content, schemaWorkspaceBootstrapV1,
                        WorkspaceBootstrap)
  requireNonEmpty(path, schemaWorkspaceBootstrapV1, "manifest.url",
                  result.manifest.url)

  let privatePath = path.parentDir / bootstrapPrivateConfigFileName
  if (result.manifest.private_url.isNone or
      result.manifest.private_url.get().len == 0) and
      fileExists(privatePath):
    let priv = readWorkspaceBootstrapPrivate(privatePath)
    if priv.manifest.private_url.len > 0:
      result.manifest.private_url = some(priv.manifest.private_url)

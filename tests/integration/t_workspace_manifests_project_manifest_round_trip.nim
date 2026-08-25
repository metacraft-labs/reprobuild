## M5 — `projects/<project>.toml` round-trip through the workspace manifest
## reader. See `t_workspace_manifests_repo_fragment_round_trip.nim` for the
## five-case template; this file is the project-schema analogue.
##
## The last two cases pin the UNKNOWN-FIELD diagnostic specifically. Strict
## decoding still rejects the key — that is deliberate and unchanged — but the
## message now names the usual cause (a `repro` older than the manifests it is
## reading) instead of only the parser mechanism, and names the remedy. The
## companion case checks that a plain type error is NOT dressed up that way.
##
## No mocks: every case writes a real `.toml` under a real temp directory and
## runs the production reader over it.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const happyToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "reprobuild"
default_revision = "main"
trunk = "main"

[[remote]]
name = "metacraft-labs"
fetch = "https://github.com/metacraft-labs"

[[remote]]
name = "github"
fetch = "https://github.com"

includes = [
  "repos/reprobuild.toml",
  "repos/runquota.toml",
]
"""

const unknownKeyToml = """
schema = "reprobuild.workspace.project.v1"
mystery_field = 42

[project]
name = "x"
"""

const wrongSchemaToml = """
schema = "reprobuild.workspace.project.v2"

[project]
name = "x"
"""

const missingProjectNameToml = """
schema = "reprobuild.workspace.project.v1"

[project]
default_revision = "main"
"""

# A manifest written against a NEWER schema than this build knows. The real
# instance was `member_sets`, which shipped after `repro 0.1.3` and made every
# stale binary reject the workspace's own manifests; this build knows that key
# now, so the fixture stands in for whichever key comes next.
const newerThanToolToml = """
schema = "reprobuild.workspace.project.v1"
future_key_from_a_newer_repro = ["core", "docs"]

[project]
name = "x"
"""

# Right key, wrong value type — `includes` is a list of paths, not a string.
# The manifest really is at fault here, so this one must keep the parser's own
# diagnostic and must NOT be recast as version skew.
const wrongValueTypeToml = """
schema = "reprobuild.workspace.project.v1"
includes = "repos/x.toml"

[project]
name = "x"
"""

const extensionsToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "x"

[extensions]
shells = "future"
"""

proc writeFixture(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

suite "M5 — ProjectManifest round-trip":
  let dir = createTempDir("reprobuild-m5-project-", "")

  test "happy path populates remotes and includes":
    let path = writeFixture(dir, "project-happy.toml", happyToml)
    let p = readProjectManifest(path)
    check p.schema == "reprobuild.workspace.project.v1"
    check p.project.name == "reprobuild"
    check p.project.default_revision.isSome
    check p.project.default_revision.get() == "main"
    check p.project.trunk.isSome
    check p.project.trunk.get() == "main"
    check p.remote.len == 2
    check p.remote[0].name == "metacraft-labs"
    check p.remote[0].fetch == "https://github.com/metacraft-labs"
    check p.remote[1].name == "github"
    check p.remote[1].fetch == "https://github.com"
    check p.includes.len == 2
    check p.includes[0] == "repos/reprobuild.toml"
    check p.includes[1] == "repos/runquota.toml"

  test "unknown top-level key is rejected":
    let path = writeFixture(dir, "project-unknown.toml", unknownKeyToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == path
      check e.keyPath == "mystery_field"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
    check raised

  test "schema-version mismatch reports observed v2":
    let path = writeFixture(dir, "project-wrong-schema.toml", wrongSchemaToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "schema"
      check e.expectedSchema == "reprobuild.workspace.project.v1"
      check e.observedSchema == "reprobuild.workspace.project.v2"
    check raised

  test "missing project.name is reported":
    let path = writeFixture(dir, "project-missing-name.toml",
                            missingProjectNameToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.keyPath == "project.name"
    check raised

  test "[extensions] passes through strict mode":
    let path = writeFixture(dir, "project-extensions.toml", extensionsToml)
    let p = readProjectManifest(path)
    check p.project.name == "x"
    check p.extensions.isPresent

  test "unknown field reads as tool/manifest version skew":
    let path = writeFixture(dir, "project-newer-than-tool.toml",
                            newerThanToolToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      # Strict mode still rejects the key — that part must not change.
      check e.keyPath == "future_key_from_a_newer_repro"
      # The cause, stated plainly, and the explicit disclaimer that the
      # manifest is fine. Without this the message reads as "your push is
      # broken" rather than "your `repro` is behind the manifests".
      check "older than the workspace manifests" in e.innerMessage
      check "is not malformed" in e.innerMessage
      # The offending field, the record, and the file that carries it.
      check "future_key_from_a_newer_repro" in e.innerMessage
      check "ProjectManifest" in e.innerMessage
      check path in e.innerMessage
      # The remedy, concretely enough to act on.
      check "direnv reload" in e.innerMessage
      check "nix develop" in e.innerMessage
      # The binary actually running, which is what makes the skew obvious
      # when a stale copy sits earlier on PATH than the pinned build.
      check getAppFilename() in e.innerMessage
      # The structured framing still carries file and key.
      check path in e.msg
      check "future_key_from_a_newer_repro" in e.msg
    check raised

  test "a wrong value type keeps the parser's own diagnostic":
    let path = writeFixture(dir, "project-wrong-value-type.toml",
                            wrongValueTypeToml)
    var raised = false
    try:
      discard readProjectManifest(path)
    except WorkspaceManifestParseError as e:
      raised = true
      # Not an unknown field, so no skew story: the manifest is the problem.
      check e.keyPath.len == 0
      check "older than the workspace manifests" notin e.innerMessage
      check "direnv reload" notin e.innerMessage
      check e.innerMessage.len > 0
    check raised

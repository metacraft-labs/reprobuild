## `repro-workspace.local.toml` may carry manifest layers and nothing else.
##
## Workspace-Settings-Files.md §4: the local settings file is one person's —
## their own extra manifest layers and the urls of shared layers that need
## credentials. Profiles, custom roles, project defaults, the record store,
## verification, develop/locking/foreign-env policy and the root repo's roles
## are SHARED policy: a local override of any of them would make the same
## command mean different things on two machines in one workspace (§4 gives
## `repro sync --unstable` reconciling with different branches as the
## example). So each such table in the local file is refused, naming the
## local file and the table. A local file carrying only `[[manifest]]`
## entries reads cleanly — the positive control that the refusal is about
## the table, not about the file existing.
##
## Workspace-Settings-Files.md §9 names this test
## `local_file_cannot_declare_policy`.
##
## No mocks: real files in a temporary directory, the real reader.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const sharedSettings = """schema = "reprobuild.workspace.settings.v1"

[[manifest]]
name = "partner"
visibility = "team"
"""

suite "the local settings file cannot declare policy":

  test "t_local_file_cannot_declare_policy":
    let dir = createTempDir("repro-local-policy-", "")
    defer: removeDir(dir)
    let shared = dir / "repro-workspace.toml"
    writeFile(shared, sharedSettings)
    let local = dir / "repro-workspace.local.toml"
    let header = "schema = \"reprobuild.workspace.settings-local.v1\"\n\n"

    # Positive control: layers only.
    writeFile(local, header & "[[manifest]]\nname = \"partner\"\n" &
      "url = \"https://git.example.invalid/partner\"\n\n" &
      "[[manifest]]\nlocal_path = \"../mine\"\nvisibility = \"personal\"\n")
    let ok = readWorkspaceSettings(shared)
    check ok.localPath == local
    check ok.localLayers.len == 2

    for (table, body) in [
        ("profiles", "[profiles.x]\nmainline = \"dev\"\n"),
        ("branch-roles", "[branch-roles.beta]\nfallback = \"stable\"\n"),
        ("workspace", "[workspace]\nmainline = \"dev\"\n"),
        ("projects", "[projects]\ndefault = [\"a\"]\n"),
        ("records", "[records]\nurl = \"https://git.example.invalid/r\"\n"),
        ("verify", "[verify]\nrequire_signature = false\n"),
        ("develop", "[develop]\norg_urls = []\n"),
        ("locking", "[locking]\nroute = []\n"),
        ("foreign_env", "[foreign_env]\nauto_load_flake = true\n"),
        ("extensions", "[extensions]\nanything = 1\n")]:
      writeFile(local, header & body)
      var raised = false
      try:
        discard readWorkspaceSettings(shared)
      except WorkspaceManifestParseError as e:
        raised = true
        check e.path == local
        check e.keyPath == table
        check "repro-workspace.local.toml" in e.innerMessage
        check "[[manifest]]" in e.innerMessage
      if not raised:
        checkpoint("the local file was allowed to declare `" & table & "`")
      check raised

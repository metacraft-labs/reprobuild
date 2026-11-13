## A local settings entry naming a layer the shared file does not declare is
## an error naming both files.
##
## Workspace-Settings-Files.md §4 "Layer resolution": a
## `repro-workspace.local.toml` entry with a `name` supplies the url (and may
## set the branch) of the SHARED layer of that name and adds no layer of its
## own. If no shared layer has that name, the entry supplies a url to
## nothing — almost always a typo, or a shared layer that was renamed or
## removed — and silently ignoring it would leave the person wondering why
## their credentials never take effect. So it is an error, and because the
## fix lives in one of two files, the diagnostic names both: the local file
## (where the entry is, in `path`) and the shared file (which names the
## layers that do exist).
##
## Positive control: the same entry with the right name reads cleanly.
##
## Workspace-Settings-Files.md §9 names this test
## `local_name_without_shared_layer_is_an_error`.
##
## No mocks: real files in a temporary directory, the real reader.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

suite "a local layer name must match a shared layer":

  test "t_local_name_without_shared_layer_is_an_error":
    let dir = createTempDir("repro-local-name-", "")
    defer: removeDir(dir)
    let shared = dir / "repro-workspace.toml"
    writeFile(shared, "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
      "[[manifest]]\nname = \"partner\"\nvisibility = \"team\"\n")
    let local = dir / "repro-workspace.local.toml"
    let header = "schema = \"reprobuild.workspace.settings-local.v1\"\n\n"

    # Positive control.
    writeFile(local, header & "[[manifest]]\nname = \"partner\"\n" &
      "url = \"https://git.example.invalid/partner\"\n")
    check readWorkspaceSettings(shared).localLayers.len == 1

    writeFile(local, header & "[[manifest]]\nname = \"partnr\"\n" &
      "url = \"https://git.example.invalid/partner\"\n")
    var raised = false
    try:
      discard readWorkspaceSettings(shared)
    except WorkspaceManifestParseError as e:
      raised = true
      check e.path == local
      check e.keyPath == "manifest[0].name"
      check "partnr" in e.innerMessage
      check shared in e.innerMessage
      check "partner" in e.innerMessage
    check raised

    # A shared file with no named layer at all: same refusal.
    writeFile(shared, "schema = \"reprobuild.workspace.settings.v1\"\n")
    expect WorkspaceManifestParseError:
      discard readWorkspaceSettings(shared)

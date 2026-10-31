## M13 — Workspace metadata for the active branch.
##
## Round-trip test for the new ``workspace_branch`` module: the
## ``writeWorkspaceBranch`` helper records the active workspace branch
## into the state file ``<workspaceRoot>/.repro/workspace-state.toml`` under
## ``[workspace].branch``, and ``readWorkspaceBranch`` reads it back
## through the M5 strict reader. Three checkpoints:
##
##   1. Writing a fresh state file in single-project
##      mode (no manifest layers) and reading the branch back yields
##      the value that was written.
##   2. Reading a state file that has no ``[workspace].branch``
##      yields ``none`` (NOT an error). This is the on-disk shape M9
##      init produced before M13 landed.
##   3. Re-writing the same branch value is idempotent — the file
##      bytes round-trip identically and the strict reader keeps
##      accepting the file. Updating to a different branch replaces
##      the value in place without disturbing the project name.
##
## A fourth check exercises composer-mode workspaces: a checkout whose
## state still sits in the RETIRED state file (``.repro/workspace.toml``,
## ``local.v1``), which also kept the ``[[manifest]]`` layer list, must keep
## those layers across a branch write — the writer must never silently drop
## manifest layers it doesn't understand. The state file now carries no
## layers (Workspace-Settings-Files.md §5) and the writer no longer reads the
## retired file: it REFUSES it, changing nothing, and ``repro health --fix``
## (``migrateWorkspaceStateFile``, §8 step 2) moves the state to the current
## file and the layers to ``repro-workspace.local.toml``, after which the
## branch write succeeds and the layers still compose. A layer that cannot
## live in the local file (a ``local_path`` under ``.repro/``, §4) makes the
## migration refuse and change nothing rather than drop it.
##
## This is a pure-library round-trip; no ``git`` and no compiled
## ``repro`` binary are involved.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

suite "M13 — workspace branch round-trips through reader":

  test "test_m13_round_trip_writes_and_reads_branch":
    let workspaceRoot = createTempDir("repro-m13-round-trip-", "")
    defer: removeDir(workspaceRoot)

    # Pre-condition: no state file on disk → readWorkspaceBranch
    # returns ``none`` cleanly (not an error).
    check readWorkspaceBranch(workspaceRoot).isNone

    # Single-project-mode write: creates a metadata-only state file
    # carrying just the project + branch keys.
    writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

    let tomlPath = workspaceTomlPath(workspaceRoot)
    check fileExists(tomlPath)

    let recorded = readWorkspaceBranch(workspaceRoot)
    check recorded.isSome
    check recorded.get() == "main"

    # The file must round-trip through the strict M5 reader without
    # raising — that's the contract M13 relies on for status to read
    # the branch back.
    let parsed = readWorkspaceLocal(tomlPath)
    check parsed.workspace.project == "lib-a"
    check parsed.workspace.branch.isSome
    check parsed.workspace.branch.get() == "main"
    # Metadata-only file: no manifest layers, which is what tells the
    # dispatch helpers to route the workspace through single-project
    # mode rather than the M8 composer.
    check parsed.manifest.len == 0
    check isCompositionalWorkspaceToml(workspaceRoot) == false

  test "test_m13_missing_branch_field_reads_as_none":
    let workspaceRoot = createTempDir("repro-m13-no-branch-", "")
    defer: removeDir(workspaceRoot)

    # Hand-roll a state file that has ``[workspace] project`` but
    # NO ``branch`` key — the shape M9 init wrote before M13 landed.
    createDir(workspaceRoot / ".repro")
    let tomlPath = workspaceRoot / ".repro" / "workspace-state.toml"
    writeFile(tomlPath,
      "schema = \"reprobuild.workspace.state.v1\"\n\n" &
      "[workspace]\n" &
      "project = \"legacy-project\"\n")

    # readWorkspaceBranch must NOT raise — it must return ``none`` so
    # the status command's fallback heuristic (M12) takes over.
    let recorded = readWorkspaceBranch(workspaceRoot)
    check recorded.isNone

    # The file is still valid TOML by M5's strict reader.
    let parsed = readWorkspaceLocal(tomlPath)
    check parsed.workspace.project == "legacy-project"
    check parsed.workspace.branch.isNone

  test "test_m13_rewrite_same_branch_is_idempotent":
    let workspaceRoot = createTempDir("repro-m13-idempotent-", "")
    defer: removeDir(workspaceRoot)

    writeWorkspaceBranch(workspaceRoot,
      project = "lib-a", branch = "main")
    let firstBytes = readFile(workspaceTomlPath(workspaceRoot))

    # Re-running with the same arguments must produce byte-identical
    # output (the serializer is deterministic). This is the property
    # that lets hooks call writeWorkspaceBranch on every relevant
    # event without churn.
    writeWorkspaceBranch(workspaceRoot,
      project = "lib-a", branch = "main")
    let secondBytes = readFile(workspaceTomlPath(workspaceRoot))
    check firstBytes == secondBytes

    # Updating to a different branch must replace the value in place
    # and keep the project name intact.
    writeWorkspaceBranch(workspaceRoot,
      project = "lib-a", branch = "feature/cool-thing")
    let parsed = readWorkspaceLocal(workspaceTomlPath(workspaceRoot))
    check parsed.workspace.project == "lib-a"
    check parsed.workspace.branch.isSome
    check parsed.workspace.branch.get() == "feature/cool-thing"

  test "test_m13_writer_preserves_composer_mode_manifest_layers":
    let workspaceRoot = createTempDir("repro-m13-composer-", "")
    defer: removeDir(workspaceRoot)

    # Hand-roll a composer-mode RETIRED state file with two manifest
    # layers. They must survive the branch update — otherwise re-running
    # init on a composed workspace would silently drop the user's manifest
    # configuration.
    createDir(workspaceRoot / ".repro")
    let tomlPath = retiredWorkspaceStatePath(workspaceRoot)
    writeFile(tomlPath,
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "[workspace]\n" &
      "project = \"reprobuild\"\n" &
      "branch = \"main\"\n\n" &
      "[[manifest]]\n" &
      "url = \"https://github.com/metacraft-labs/metacraft-manifests\"\n" &
      "visibility = \"public\"\n" &
      "branch = \"main\"\n\n" &
      "[[manifest]]\n" &
      "local_path = \"manifests-personal\"\n" &
      "visibility = \"personal\"\n")
    let oldBytes = readFile(tomlPath)
    check readStateFileForMigration(tomlPath).manifest.len == 2

    # The writer refuses the retired file rather than reading it as "no
    # state" (which would forget the project) or dropping its layers, and
    # changes nothing.
    expect WorkspaceManifestParseError:
      writeWorkspaceBranch(workspaceRoot,
        project = "reprobuild", branch = "develop")
    check readFile(tomlPath) == oldBytes
    check not fileExists(workspaceStatePath(workspaceRoot))
    check not fileExists(workspaceRoot / "repro-workspace.local.toml")

    # `repro health --fix`'s migration moves the state and the layers.
    check migrateWorkspaceStateFile(workspaceRoot).len > 0
    check not fileExists(tomlPath)

    # Update the branch field; the manifest layers must survive.
    writeWorkspaceBranch(workspaceRoot,
      project = "reprobuild", branch = "develop")

    # The write lands in the state file's NEW name, without the layers,
    # which are now in the local settings file.
    check workspaceTomlPath(workspaceRoot) == workspaceStatePath(workspaceRoot)
    let parsed = readWorkspaceLocal(workspaceTomlPath(workspaceRoot))
    check parsed.workspace.project == "reprobuild"
    check parsed.workspace.branch.isSome
    check parsed.workspace.branch.get() == "develop"
    check parsed.manifest.len == 0
    let local = readLoneLocalSettings(workspaceRoot)
    require local.isSome
    let layers = local.get().localLayers
    check layers.len == 2
    check layers[0].url ==
      some("https://github.com/metacraft-labs/metacraft-manifests")
    check layers[0].visibility == some("public")
    check layers[0].branch == some("main")
    check layers[1].local_path == some("manifests-personal")
    check layers[1].visibility == some("personal")
    check isCompositionalWorkspaceToml(workspaceRoot) == true

  test "test_m13_writer_refuses_a_layer_it_cannot_move":
    let workspaceRoot = createTempDir("repro-m13-unmovable-", "")
    defer: removeDir(workspaceRoot)
    createDir(workspaceRoot / ".repro")
    let tomlPath = retiredWorkspaceStatePath(workspaceRoot)
    writeFile(tomlPath,
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "[workspace]\nproject = \"reprobuild\"\nbranch = \"main\"\n\n" &
      "[[manifest]]\nlocal_path = \".repro/manifests-personal\"\n" &
      "visibility = \"personal\"\n")
    let oldBytes = readFile(tomlPath)
    # The writer refuses the retired file outright ...
    expect WorkspaceManifestParseError:
      writeWorkspaceBranch(workspaceRoot,
        project = "reprobuild", branch = "develop")
    check readFile(tomlPath) == oldBytes
    # ... and the migration that would move its layers refuses the one it
    # cannot move, writing nothing.
    expect StateMigrationError:
      discard migrateWorkspaceStateFile(workspaceRoot)
    check readFile(tomlPath) == oldBytes
    check not fileExists(workspaceStatePath(workspaceRoot))
    check not fileExists(workspaceRoot / "repro-workspace.local.toml")

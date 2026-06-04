## M13 — Workspace metadata for the active branch.
##
## Round-trip test for the new ``workspace_branch`` module: the
## ``writeWorkspaceBranch`` helper records the active workspace branch
## into ``<workspaceRoot>/.repo/workspace.toml`` under
## ``[workspace].branch``, and ``readWorkspaceBranch`` reads it back
## through the M5 strict reader. Three checkpoints:
##
##   1. Writing a fresh ``.repo/workspace.toml`` in single-project
##      mode (no manifest layers) and reading the branch back yields
##      the value that was written.
##   2. Reading a workspace.toml that has no ``[workspace].branch``
##      yields ``none`` (NOT an error). This is the on-disk shape M9
##      init produced before M13 landed.
##   3. Re-writing the same branch value is idempotent — the file
##      bytes round-trip identically and the strict reader keeps
##      accepting the file. Updating to a different branch replaces
##      the value in place without disturbing the project name.
##
## A fourth check exercises composer-mode workspaces: a workspace.toml
## that already declares ``[[manifest]]`` layers must keep them when
## the writer updates the branch field — single-source-of-truth
## semantics require that the writer never silently drops manifest
## layers it doesn't understand.
##
## This is a pure-library round-trip; no ``git`` and no compiled
## ``repro`` binary are involved.

import std/[options, os, tempfiles, unittest]

import repro_workspace_manifests

suite "M13 — workspace branch round-trips through reader":

  test "test_m13_round_trip_writes_and_reads_branch":
    let workspaceRoot = createTempDir("repro-m13-round-trip-", "")
    defer: removeDir(workspaceRoot)

    # Pre-condition: no workspace.toml on disk → readWorkspaceBranch
    # returns ``none`` cleanly (not an error).
    check readWorkspaceBranch(workspaceRoot).isNone

    # Single-project-mode write: creates a metadata-only workspace.toml
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

    # Hand-roll a workspace.toml that has ``[workspace] project`` but
    # NO ``branch`` key — the shape M9 init wrote before M13 landed.
    createDir(workspaceRoot / ".repo")
    let tomlPath = workspaceRoot / ".repo" / "workspace.toml"
    writeFile(tomlPath,
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
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

    # Hand-roll a composer-mode workspace.toml with two manifest
    # layers. M13's writer must keep them intact when it updates the
    # branch field — otherwise re-running init on a composed workspace
    # would silently drop the user's manifest configuration.
    createDir(workspaceRoot / ".repo")
    let tomlPath = workspaceRoot / ".repo" / "workspace.toml"
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
      "local_path = \".repo/manifests-personal\"\n" &
      "visibility = \"personal\"\n")

    check isCompositionalWorkspaceToml(workspaceRoot) == true

    # Update the branch field; the manifest layers must survive.
    writeWorkspaceBranch(workspaceRoot,
      project = "reprobuild", branch = "develop")

    let parsed = readWorkspaceLocal(tomlPath)
    check parsed.workspace.project == "reprobuild"
    check parsed.workspace.branch.isSome
    check parsed.workspace.branch.get() == "develop"
    check parsed.manifest.len == 2
    check parsed.manifest[0].url.isSome
    check parsed.manifest[0].url.get() ==
      "https://github.com/metacraft-labs/metacraft-manifests"
    check parsed.manifest[0].visibility == "public"
    check parsed.manifest[0].branch.isSome
    check parsed.manifest[0].branch.get() == "main"
    check parsed.manifest[1].local_path.isSome
    check parsed.manifest[1].local_path.get() == ".repo/manifests-personal"
    check parsed.manifest[1].visibility == "personal"
    check isCompositionalWorkspaceToml(workspaceRoot) == true

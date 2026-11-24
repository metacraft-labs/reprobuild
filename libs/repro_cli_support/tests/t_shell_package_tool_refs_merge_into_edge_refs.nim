## The CLI merges a `shell(...)` edge's package-derived tool references
## (`BuildActionDef.packageToolIdentityRefs`) into the edge's own
## `toolIdentityRefs` the way Hermetic-Builds-And-Path-Independence.md
## §"Shell edges declare their package's tools" says
## (`withPackageToolIdentityRefs`):
##
## * after the edge's own refs, deduplicated;
## * each with its platform role: a `nativeBuildDeps:` entry stays a
##   BUILD-platform ref even when the edge names refs of its own and no
##   roles (the engine reads an empty role list as "all host-platform", so
##   appending roles to it without spelling that default out first would
##   either drop the native role or misalign every role after it);
## * minus every selector a develop override declares as a cross-repo
##   producer, which only an edge that names it admits
##   (Cross-Repo-Source-Consumption.md §4.2b.3).
##
## No mocks: plain values of the production payload type, the production
## merge, and a real `.repro/develop-overrides.toml` written by the
## production writer into a temporary directory.

import std/[os, tempfiles, unittest]

import repro_cli_support
import repro_project_dsl
import repro_workspace_manifests

proc shellPayload(ownRefs: seq[string];
                  ownKinds: seq[ToolIdentityRefKind];
                  packageRefs: seq[string];
                  packageKinds: seq[ToolIdentityRefKind]): BuildActionDef =
  BuildActionDef(
    id: "pkg.run",
    call: inlineExecCall(@["sh", "-c", "make"]),
    toolIdentityRefs: ownRefs,
    toolIdentityRefKinds: ownKinds,
    packageToolIdentityRefs: packageRefs,
    packageToolIdentityRefKinds: packageKinds)

suite "shell package tool refs merge into the edge's refs":
  test "own refs without roles: package roles survive the merge":
    let root = createTempDir("repro-shell-refs", "")
    defer: removeDir(root)
    let merged = withPackageToolIdentityRefs(shellPayload(
      @["mkdir"], @[],
      @["pkg-config", "make", "mkdir"], @[tirkNative, tirkBuild, tirkBuild]),
      root)
    check merged.toolIdentityRefs == @["mkdir", "pkg-config", "make"]
    check merged.toolIdentityRefKinds == @[tirkBuild, tirkNative, tirkBuild]
    check merged.packageToolIdentityRefs.len == 0
    check merged.packageToolIdentityRefKinds.len == 0

  test "no own refs: the package refs and roles become the edge's":
    let root = createTempDir("repro-shell-refs", "")
    defer: removeDir(root)
    let merged = withPackageToolIdentityRefs(shellPayload(
      @[], @[], @["pkg-config", "gcc"], @[tirkNative, tirkBuild]), root)
    check merged.toolIdentityRefs == @["pkg-config", "gcc"]
    check merged.toolIdentityRefKinds == @[tirkNative, tirkBuild]

  test "a merge that adds nothing leaves the edge's refs and roles alone":
    let root = createTempDir("repro-shell-refs", "")
    defer: removeDir(root)
    let merged = withPackageToolIdentityRefs(shellPayload(
      @["sh"], @[], @["sh"], @[tirkBuild]), root)
    check merged.toolIdentityRefs == @["sh"]
    check merged.toolIdentityRefKinds.len == 0

  test "a develop-override producer is not taken from the package list":
    let root = createTempDir("repro-shell-refs", "")
    defer: removeDir(root)
    let sibling = root / "prod-checkout"
    createDir(sibling)
    writeDevelopOverridesFile(root, newDevelopOverrides().addOverride(
      DevelopOverrideEntry(package: "prod", local_path: sibling,
        state: "editable", created_at: "2026-11-23T00:00:00Z")))
    let payload = shellPayload(@[], @[], @["make", "prod"],
      @[tirkBuild, tirkBuild])
    let merged = withPackageToolIdentityRefs(payload, root)
    check merged.toolIdentityRefs == @["make"]
    check merged.toolIdentityRefKinds == @[tirkBuild]
    # Control: without the override the same selector is an ordinary tool.
    removeFile(developOverridesPath(root))
    check withPackageToolIdentityRefs(payload, root).toolIdentityRefs ==
      @["make", "prod"]

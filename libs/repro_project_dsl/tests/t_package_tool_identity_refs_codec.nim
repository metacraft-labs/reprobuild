## The tool references a `shell(...)` edge takes from its package's
## declaration survive registration and the build-action payload codec, and
## stay apart from the edge's own `toolIdentityRefs`.
##
## They must stay apart until the CLI lowers the edge: the CLI merges them
## into the edge's refs minus every selector that is a cross-repo producer
## (Cross-Repo-Source-Consumption.md §4.2b.3 -- a producer is admitted by
## the refs an edge names, "not from `uses:`"), and only the CLI knows which
## selectors those are. A codec that folded them into `toolIdentityRefs`, or
## dropped their platform roles, would undo that.
##
## No mocks: the real registry and the real v39 codec.

import std/unittest

import repro_project_dsl

suite "package-derived tool identity refs":
  setup:
    resetBuildActionRegistry()
    resetDslPortPackageDepsState()

  test "a dependency that names a workspace sibling project is not a tool":
    # `isonim` is a library-only sibling of the recipe's repository: its
    # root reaches `repro.paths`, it has no executable, and taking it as a
    # tool made path-mode tool resolution refuse every consumer that runs a
    # `shell(...)` edge. Runtime-only deps and generated deps stay out too.
    registerPackageDep("app", "build", "sh")
    registerPackageDep("app", "build", "isonim >=1.0")
    registerPackageDep("app", "native", "pkg-config")
    registerPackageDep("app", "runtime", "libfoo")
    registerGeneratedToolDep("app", "native", "patchelf")
    registerWorkspaceSiblingDep("app", "isonim")
    let refs = packageShellToolRefs("app")
    check refs.native == @["pkg-config"]
    check refs.build == @["sh"]

  test "registration records refs and roles apart from the edge's own refs":
    discard buildAction(
      id = "shell-run",
      call = inlineExecCall(@["sh", "-c", "make"]),
      toolIdentityRefs = @["sh"])
    setRegisteredActionPackageToolIdentityRefs("shell-run",
      ["pkg-config", "make", "gcc"], [tirkNative, tirkBuild, tirkBuild])
    let action = registeredBuildActions()[0]
    check action.toolIdentityRefs == @["sh"]
    check action.packageToolIdentityRefs == @["pkg-config", "make", "gcc"]
    check action.packageToolIdentityRefKinds ==
      @[tirkNative, tirkBuild, tirkBuild]

  test "a second registration replaces rather than appends":
    discard buildAction(
      id = "shell-run",
      call = inlineExecCall(@["sh", "-c", "make"]))
    setRegisteredActionPackageToolIdentityRefs("shell-run",
      ["make"], [tirkBuild])
    setRegisteredActionPackageToolIdentityRefs("shell-run",
      ["make"], [tirkBuild])
    check registeredBuildActions()[0].packageToolIdentityRefs == @["make"]

  test "refs and roles of different lengths are refused":
    discard buildAction(
      id = "shell-run",
      call = inlineExecCall(@["sh", "-c", "make"]))
    expect ValueError:
      setRegisteredActionPackageToolIdentityRefs("shell-run",
        ["make", "gcc"], [tirkBuild])

  test "the payload round-trips them; a v38 payload carries none":
    let action = BuildActionDef(
      id: "shell-run",
      call: inlineExecCall(@["sh", "-c", "make"]),
      toolIdentityRefs: @["sh"],
      packageToolIdentityRefs: @["pkg-config", "make"],
      packageToolIdentityRefKinds: @[tirkNative, tirkBuild])
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.toolIdentityRefs == @["sh"]
    check decoded.packageToolIdentityRefs == @["pkg-config", "make"]
    check decoded.packageToolIdentityRefKinds == @[tirkNative, tirkBuild]
    let v38 = decodeBuildActionPayload(
      encodeBuildActionPayloadAtVersion(action, 38'u16))
    check v38.toolIdentityRefs == @["sh"]
    check v38.packageToolIdentityRefs.len == 0
    check v38.packageToolIdentityRefKinds.len == 0

  test "a corrupted role byte is refused":
    let action = BuildActionDef(
      id: "shell-run",
      call: inlineExecCall(@["sh", "-c", "make"]),
      packageToolIdentityRefs: @["make"],
      packageToolIdentityRefKinds: @[tirkBuild])
    var bytes = encodeBuildActionPayload(action)
    # The role byte is the payload's last byte: v39 appends the refs and
    # their roles after every earlier field.
    bytes[^1] = 0xff'u8
    expect CatchableError:
      discard decodeBuildActionPayload(bytes)

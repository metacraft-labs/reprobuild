## M9.R.79 Phase G verification — the two post-emit registry mutators
## (``setRegisteredActionDeclaredOutputs`` +
## ``setRegisteredActionReadOnlyRoots``) mutate the registry entry in
## place and are safely no-op for missing ids.
##
## The meson_package / autotools_package / cmake_package constructors
## use these mutators to declare write scope + read-only source scope
## on typed-tool edges that route through ``recordToolInvocation``.
## This test pins the mutator surface so a future refactor cannot
## silently break the R6/R7 enforcement threading.
##
## Spec cite: reprobuild-specs Filesystem-Policy-And-Observed-Inputs.md
## §"Double Writes" (R7) + §"Source Rewrites" (R6).

import std/[unittest]

import repro_project_dsl

suite "t_m9r79_registry_mutators":

  test "setRegisteredActionDeclaredOutputs updates registry entry":
    ## Register an action via ``buildAction``, mutate its
    ## ``declaredOutputs`` via the post-emit setter, verify the change
    ## is visible via ``registeredBuildActions()`` (which returns the
    ## same seq the engine consumes at graph-emit time).
    resetBuildActionRegistry()
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    discard buildAction(
      id = "m9r79-setter-check",
      call = call)
    setRegisteredActionDeclaredOutputs("m9r79-setter-check",
      @["/tmp/build/foo", "/tmp/build/bar"])
    var found = false
    for a in registeredBuildActions():
      if a.id == "m9r79-setter-check":
        found = true
        check a.declaredOutputs == @["/tmp/build/foo", "/tmp/build/bar"]
        break
    check found

  test "setRegisteredActionReadOnlyRoots updates registry entry":
    resetBuildActionRegistry()
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    discard buildAction(
      id = "m9r79-ro-check",
      call = call)
    setRegisteredActionReadOnlyRoots("m9r79-ro-check",
      @["/tmp/src/upstream"])
    var found = false
    for a in registeredBuildActions():
      if a.id == "m9r79-ro-check":
        found = true
        check a.readOnlyRoots == @["/tmp/src/upstream"]
        break
    check found

  test "setRegisteredActionDeclaredOutputs overwrites previous value":
    ## Semantics are SET, not APPEND — a second call replaces the
    ## previous seq entirely so the constructor's single-shot edge
    ## declaration is authoritative.
    resetBuildActionRegistry()
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    discard buildAction(
      id = "m9r79-overwrite",
      call = call,
      declaredOutputs = @["/tmp/old"])
    setRegisteredActionDeclaredOutputs("m9r79-overwrite",
      @["/tmp/new"])
    var found = false
    for a in registeredBuildActions():
      if a.id == "m9r79-overwrite":
        found = true
        check a.declaredOutputs == @["/tmp/new"]
        break
    check found

  test "setter is no-op for missing action id":
    ## Defensive: the constructor calls the mutator right after the
    ## typed-tool wrapper returns; if the wrapper's action id changed
    ## shape (unusual but possible) the mutator must not raise.
    resetBuildActionRegistry()
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    discard buildAction(
      id = "m9r79-real-id",
      call = call)
    # No exception must fire; the registered action's fields stay
    # empty (defaults).
    setRegisteredActionDeclaredOutputs("m9r79-nonexistent-id",
      @["/tmp/x"])
    setRegisteredActionReadOnlyRoots("m9r79-nonexistent-id",
      @["/tmp/y"])
    for a in registeredBuildActions():
      if a.id == "m9r79-real-id":
        check a.declaredOutputs.len == 0
        check a.readOnlyRoots.len == 0
        break

  test "both mutators independent on the same action":
    ## The two mutators write to different fields; calling one must
    ## not clobber the other's previous write.
    resetBuildActionRegistry()
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    discard buildAction(
      id = "m9r79-both",
      call = call)
    setRegisteredActionDeclaredOutputs("m9r79-both", @["/tmp/build"])
    setRegisteredActionReadOnlyRoots("m9r79-both", @["/tmp/src"])
    var found = false
    for a in registeredBuildActions():
      if a.id == "m9r79-both":
        found = true
        check a.declaredOutputs == @["/tmp/build"]
        check a.readOnlyRoots == @["/tmp/src"]
        break
    check found

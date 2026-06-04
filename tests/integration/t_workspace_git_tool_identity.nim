## Workspace VCS — git tool identity tests (M1).
##
## These tests cover the two contracts the Phase-1 milestone spells out
## for ``resolveGitTool``:
##
##   1. The identity digest is deterministic across two PATH variants
##      that resolve to the same git binary. This is the property the
##      action cache leans on so a workspace built against git 2.40 is
##      not confused with a workspace built against git 2.45.
##   2. When no git is reachable on the resolved tool surface (empty
##      PATH under ``tpmPathOnly``), the helper raises
##      ``EGitToolUnresolved`` with a message naming the active mode.
##
## The first test skips when no ambient ``git`` is present on PATH;
## that is the one documented skip the milestone permits. The second
## test uses a contrived empty PATH and never relies on ambient
## tooling.

import std/[os, strutils, tempfiles, unittest]

import git_tool

proc whichGit(): string =
  ## Return the absolute path to the ambient ``git`` on PATH, or the
  ## empty string when none is found. Mirrors the resolver's own
  ## search semantics by deferring to ``findExe``.
  findExe("git")

suite "Workspace VCS — git tool identity (M1)":

  test "test_m1_identity_deterministic_across_path_variants":
    let ambient = whichGit()
    if ambient.len == 0:
      skip()
    else:
      let gitDir = ambient.parentDir
      let scratch = createTempDir("repro-m1-git-identity-", "")
      defer: removeDir(scratch)

      let firstPath = gitDir
      let secondPath = gitDir & PathSep & scratch

      let identityA = resolveGitTool(tpmPathOnly, firstPath)
      let identityB = resolveGitTool(tpmPathOnly, secondPath)

      check identityA.binaryPath == ambient
      check identityB.binaryPath == ambient
      check identityA.version.len > 0
      check identityA.version == identityB.version
      check identityA.platformOs == identityB.platformOs
      check identityA.platformCpu == identityB.platformCpu
      check identityA.installMethod == "path"
      check identityA.digestHex() == identityB.digestHex()

      # The synthetic scratch entry on PATH must not bleed into the
      # digest: the identity is anchored to the resolved binary, not
      # the raw PATH string.
      check identityA.digestHex().len == 64

      # ``ensureGitToolResolvable`` is the M2+ entry point; it must
      # return an identity equal to the low-level resolver's so call
      # sites can interchange the two. Folded into this test rather
      # than carried as a separate case so the documented "no ambient
      # git on PATH" skip at the top of this test is the only skip in
      # the file.
      let identityEnsure = ensureGitToolResolvable(tpmPathOnly, firstPath)
      check identityEnsure.digestHex() == identityA.digestHex()

  test "test_m1_identity_fails_when_no_git":
    let scratch = createTempDir("repro-m1-git-empty-", "")
    defer: removeDir(scratch)

    # Construct a PATH that points only at an empty scratch directory
    # so the resolver cannot locate any ``git`` binary regardless of
    # the ambient environment.
    let emptyPath = scratch

    var raised = false
    var message = ""
    try:
      discard resolveGitTool(tpmPathOnly, emptyPath)
    except EGitToolUnresolved as exc:
      raised = true
      message = exc.msg
    check raised
    check message.contains("--tool-provisioning=path")

  test "test_m1_unsupported_modes_raise":
    # M1 wires only the PATH backend. The remaining provisioning
    # modes must surface a clear ``EGitToolUnresolved`` so M2+ can
    # rely on a single failure shape until the Nix / tarball / Scoop
    # paths are extended.
    for mode in [tpmNix, tpmTarball, tpmScoop, tpmUnspecified]:
      var raised = false
      try:
        discard resolveGitTool(mode, getEnv("PATH"))
      except EGitToolUnresolved:
        raised = true
      check raised

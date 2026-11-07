## A relative ``stateDir`` (and ``workDir``, ``repoRoot``) handed to the
## profile compile means relative to the CALLER's working directory, not to
## the working directory the compile's edges run in (the reprobuild source
## tree, a store path in an installed engine). Before the fix,
## ``repro deploy-agent compile-profile --state-dir st`` failed with
## "cannot create directory: /nix/store/<...>-source/st/profile-cache/...".
##
## The whole compile is exercised with a relative ``--state-dir`` by the
## engine's ``compile-profile`` in the add-on gates; this pins the rule the
## compile applies first. *Mocking.* None.

import std/[os, unittest]

import repro_profile_compile/edge

suite "the profile compile anchors relative directories at its caller":
  test "relative directories become absolute against the current directory":
    let here = getCurrentDir()
    let o = anchoredCompileOptions(ProfileCompileOptions(stateDir: "st",
      workDir: "w/x", repoRoot: "r", publicCliPath: "/bin/repro"))
    check o.stateDir == here / "st"
    check o.workDir == here / "w" / "x"
    check o.repoRoot == here / "r"
    check o.publicCliPath == "/bin/repro"

  test "absolute and empty directories are kept":
    let o = anchoredCompileOptions(ProfileCompileOptions(stateDir: "/s",
      workDir: "", repoRoot: ""))
    check o.stateDir == "/s"
    check o.workDir == ""
    check o.repoRoot == ""

## The stdlib provisions ``zsh`` by its own name on Linux and macOS.
##
## The defect this guards
## (reprobuild-pm/issues/2026-11-08-the-stdlib-has-no-zsh-package-so-a-recipe-cannot-provision-zsh.md):
## the stdlib had ``bash`` and ``sh`` but no ``zsh`` package, so a recipe's
## ``uses: "zsh"`` resolved only through the PATH probe. The shell recorders'
## zsh suites run ``zsh`` as a child process; on a host whose PATH holds no
## zsh their tool resolution failed with ``zsh requested by uses "zsh" was not
## found in PATH``, and in the flake dev shell the zsh came from the caller's
## PATH, outside the action's tool identity. Asserted:
##
##   * a bare ``uses:`` line reaches ``zsh`` (``BundledStdlibSelectors``) and
##     the engine links its definition, so a home profile resolves it too;
##   * on x86_64-linux, aarch64-linux and aarch64-macos the default policy
##     selects a nixPackage of ``nixpkgs#zsh`` at the canonical nixpkgs pin,
##     whose ``executablePath`` is ``bin/zsh`` -- the name a path-mode
##     ``uses:`` probes for, so the realisation and the probe agree;
##   * on x86_64-windows the definition is known but declares no
##     realisation: there is no native zsh, and a Windows ``uses: "zsh"``
##     keeps resolving from PATH, as before.
##
## Nothing is realised and nothing is mocked: the linked definitions and the
## real selector run against synthetic targets (``realizationTargetFor``), so
## the suite behaves the same on any host.

import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/package_registry
import repro_dsl_stdlib/nixpkgs_pin
import repro_tool_profiles
import repro_home_apply/package_catalog

suite "zsh resolves by its own name":

  test "a bare uses: line and a profile reference both reach it":
    check "zsh" in BundledStdlibSelectors
    check isLinkedPackage("zsh")

  test "Linux and macOS select nixpkgs' zsh at the canonical pin":
    for target in [realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1),
        realizationTargetFor(pcAArch64, poLinux),
        realizationTargetFor(pcAArch64, poMacos)]:
      checkpoint describeTarget(target)
      let r = resolveProfilePackage("zsh", target, DefaultSelectionPolicy)
      check r.selection.kind == rkNix
      check r.selection.nix.selector == "nixpkgs#zsh"
      check r.selection.nix.executablePath == "bin/zsh"
      check r.selection.nix.nixpkgsRev == CanonicalNixpkgsRev

  test "Windows knows the package and declares no realisation for it":
    # Before the fix this raised too, but for an UNKNOWN package
    # (``definitionKnown`` false); now the definition is in scope and simply
    # has no Windows arm.
    try:
      discard resolveProfilePackage("zsh",
        realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1),
        DefaultSelectionPolicy)
      checkpoint "a Windows realisation was selected"
      fail()
    except EMissingRealization as e:
      check e.definitionKnown

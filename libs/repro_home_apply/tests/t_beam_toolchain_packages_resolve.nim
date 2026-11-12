## The stdlib provisions every executable of the BEAM toolchain — ``erl``,
## ``erlc``, ``escript``, ``elixir``, ``mix``, ``iex`` and ``rebar3`` — by
## its own name, on every platform the toolchain's recipes build on.
##
## The defect this guards
## (reprobuild-pm/issues/2026-11-07-the-stdlib-beam-packages-cannot-provision-erl-mix-or-rebar3.md):
## ``erlang`` had only the Windows OTP installer, ``elixir`` was the only
## Elixir executable with a package, and nothing defined ``erl``, ``erlc``,
## ``escript``, ``mix``, ``iex`` or ``rebar3``. On Linux and macOS a
## ``uses: "erlang"`` fell through to a PATH probe for an executable named
## ``erlang`` — the selector — which OTP does not ship. So a recipe running
## the BEAM tools left them out of ``uses:`` and took them from the ambient
## PATH, outside its actions' tool identity.
##
## The fix follows the stdlib's one-package-per-executable convention (npm and
## npx share node's distribution): each executable is its own package,
## realised from the shared distribution. Asserted, per executable:
##
##   * a bare ``uses:`` line reaches it (``BundledStdlibSelectors``) and the
##     engine links its definition, so a home profile resolves it too;
##   * on x86_64-linux and aarch64-macos the default policy selects a
##     nixPackage at the expected nixpkgs attribute, whose ``executablePath``
##     basename IS the package name — the name a path-mode ``uses:`` probes
##     for, so the realisation and the probe agree;
##   * on x86_64-windows every executable but ``rebar3`` (upstream ships only
##     an escript there) selects a tarball whose executable is ``<name>.exe``
##     or ``<name>.bat``;
##   * ``erlang``, the OTP distribution, still resolves, to ``bin/erl``.
##
## Nothing is realised and nothing is mocked: the linked definitions and the
## real selector run against synthetic targets (``realizationTargetFor``), so
## the suite behaves the same on any host.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/package_registry
import repro_tool_profiles
import repro_home_apply/package_catalog

const BeamExecutables = [
  ("erl", "nixpkgs#erlang"),
  ("erlc", "nixpkgs#erlang"),
  ("escript", "nixpkgs#erlang"),
  ("elixir", "nixpkgs#elixir"),
  ("mix", "nixpkgs#elixir"),
  ("iex", "nixpkgs#elixir"),
  ("rebar3", "nixpkgs#rebar3"),
]
  ## Each executable and the nixpkgs attribute whose ``bin/`` ships it, as
  ## measured at ``CanonicalNixpkgsRev``.

proc linuxX64(): RealizationTarget =
  realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)

proc macosArm(): RealizationTarget =
  realizationTargetFor(pcAArch64, poMacos)

proc windowsX64(): RealizationTarget =
  realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

proc pathBasename(path: string): string =
  ## The last component of ``path`` under either separator: the Windows arms
  ## spell theirs with ``\\`` and the nix arms with ``/``, and this test runs
  ## on every host.
  let parts = path.split({'\\', '/'})
  parts[^1]

suite "BEAM toolchain executables resolve by their own names":

  test "a bare uses: line and a profile reference both reach each one":
    for (name, _) in BeamExecutables:
      checkpoint name
      check name in BundledStdlibSelectors
      check isLinkedPackage(name)

  test "Linux and macOS select the nixpkgs realisation of the named binary":
    for target in [linuxX64(), macosArm()]:
      for (name, attribute) in BeamExecutables:
        checkpoint name & " on " & describeTarget(target)
        let r = resolveProfilePackage(name, target, DefaultSelectionPolicy)
        check r.selection.kind == rkNix
        check r.selection.nix.selector == attribute
        check r.selection.nix.executablePath == "bin/" & name
        check pathBasename(r.selection.nix.executablePath) == name

  test "Windows selects the upstream archive's own launcher":
    for (name, _) in BeamExecutables:
      if name == "rebar3":
        continue
      checkpoint name
      let r = resolveProfilePackage(name, windowsX64(),
        DefaultSelectionPolicy)
      check r.selection.kind == rkTarball
      check r.selection.tarball.os == "windows"
      check pathBasename(r.selection.tarball.executablePath) in
        [name & ".exe", name & ".bat"]

  test "erlang, the OTP distribution, resolves to erl on Linux":
    let r = resolveProfilePackage("erlang", linuxX64(), DefaultSelectionPolicy)
    check r.selection.kind == rkNix
    check r.selection.nix.selector == "nixpkgs#erlang"
    check r.selection.nix.executablePath == "bin/erl"

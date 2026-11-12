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
##   * the name a path-mode ``uses:`` probes PATH for (the projected use's
##     ``executableName``) is the executable itself — for ``erlang`` too,
##     whose ``executable erlang: name: "erl"`` clause points the probe at
##     ``erl`` — and a path-mode ``uses: "erlang"`` resolves a real ``erl``
##     dropped on a scratch PATH;
##   * ``erlang``, the OTP distribution, still resolves, to ``bin/erl``.
##
## Nothing is realised and nothing is mocked: the linked definitions and the
## real selector run against synthetic targets (``realizationTargetFor``),
## and the PATH case runs the real path-mode resolver over a scratch
## directory holding a stub ``erl`` script, the only host fact used. The
## suite behaves the same on any host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath
from repro_test_support import testCaseScratchSlug

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

let ScratchRoot = "build/test-tmp/t-beam-toolchain-" & testCaseScratchSlug()

proc stubOnScratchPath(name: string): tuple[dir, exe: string] =
  ## A runnable stub named ``name`` in a fresh scratch directory, which is
  ## then the WHOLE search list handed to the resolver, so nothing on the
  ## host's own PATH (a dev shell's real ``erl``) can satisfy the probe.
  result.dir = absolutePath(ScratchRoot / "stub-bin")
  if dirExists(extendedPath(result.dir)):
    removeDir(extendedPath(result.dir))
  createDir(extendedPath(result.dir))
  result.exe =
    when defined(windows): result.dir / (name & ".cmd")
    else: result.dir / name
  writeFile(extendedPath(result.exe),
    when defined(windows): "@echo stub\n" else: "#!/bin/sh\necho stub\n")
  when not defined(windows):
    setFilePermissions(result.exe, {fpUserRead, fpUserWrite, fpUserExec})

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

  test "a path-mode uses: probes for the executable itself":
    for (name, _) in BeamExecutables:
      checkpoint name
      check profileToolUse(name).useDef.executableName == name
    # OTP ships no ``erlang``; the package's ``executable`` clause renames
    # the probe to the binary its arms realise.
    check profileToolUse("erlang").useDef.executableName == "erl"

  test "a path-mode uses: \"erlang\" resolves erl from PATH":
    let stub = stubOnScratchPath("erl")
    let profile = resolvePathOnlyTool(profileToolUse("erlang").useDef,
      pathValue = stub.dir)
    check profile.executableName == "erl"
    check profile.resolvedExecutablePath == stub.exe

  test "erlang, the OTP distribution, resolves to erl on Linux":
    let r = resolveProfilePackage("erlang", linuxX64(), DefaultSelectionPolicy)
    check r.selection.kind == rkNix
    check r.selection.nix.selector == "nixpkgs#erlang"
    check r.selection.nix.executablePath == "bin/erl"

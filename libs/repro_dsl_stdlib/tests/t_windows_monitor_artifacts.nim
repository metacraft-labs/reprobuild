## The four Windows monitor artefacts are located by CONVENTION, so nothing
## reports a rename.
##
## `findShimLibrary` resolves the 64-bit shim at `<appDir>/../lib`, and
## nim-stackable-hooks' injector then derives the other three from it:
## `wow64ShimPathFor` appends `32` to the stem, `wow64ProbePathFor` and
## `inject64HelperPathFor` take fixed names in the same directory. No manifest
## is consulted anywhere in that chain.
##
## That is what makes a rename dangerous rather than merely wrong. If
## reprobuild's recipe stages `librepro_monitor_shim_32.dll` and the injector
## asks for `librepro_monitor_shim32.dll`, nothing errors: the injector meets
## a 32-bit child, finds no shim, refuses, and the child's whole subtree runs
## unmonitored. An unmonitored subtree is an unknown-scope evidence loss,
## which makes the owning action uncacheable -- and it looks exactly like a
## process that genuinely had no dependencies.
##
## These assertions therefore straddle the seam: the names reprobuild's
## `repro.nim` stages on one side, the injector's own convention procs on the
## other. A rename on either side breaks this test instead of breaking
## injection.

import std/[os, unittest]

import repro_dsl_stdlib/monitor_shim_artifacts

when defined(windows):
  import stackable_hooks/windows_injector

suite "the Windows monitor artefacts are staged where injection looks":

  test "all four artefacts are named":
    let names = windowsMonitorArtifactNames()
    check names.len == 4
    check names == @[
      "librepro_monitor_shim.dll",
      "librepro_monitor_shim32.dll",
      "stackable_hooks_wow64_probe32.exe",
      "stackable_hooks_inject64.exe"]

  test "the cross-bitness subset is the three the graph can skip":
    # These are exactly the artefacts that need an i686 toolchain (the
    # inject helper is 64-bit, but its only caller is the 32-bit shim, so
    # there is nothing to delegate to without one). When they are absent the
    # build must still succeed -- and must say so.
    check windowsCrossBitnessArtifactNames() == @[
      MonitorShim32Name, Wow64Probe32Name, Inject64HelperName]
    check MonitorShim64Name notin windowsCrossBitnessArtifactNames()

  test "they are staged in build/lib, where findShimLibrary looks":
    # `findShimLibrary` resolves `<appDir>/../lib`, i.e. `build/lib` next to
    # `build/bin/repro.exe`. Staging them anywhere else makes all four
    # invisible at once.
    check MonitorArtifactLibDir == "build/lib"
    for name in windowsMonitorArtifactNames():
      # Forward slash, not `os./`: a declared output is part of the action
      # key, so changing the separator re-keys the edge even though it names
      # the same file. The 64-bit shim edge predates this module with the
      # forward-slash spelling and must keep it.
      check monitorArtifactPath(name) == "build/lib/" & name

  test "every artefact has a distinct name":
    var seen: seq[string] = @[]
    for name in windowsMonitorArtifactNames():
      check name notin seen
      seen.add(name)

  when defined(windows):
    test "the 32-bit shim name is what wow64ShimPathFor derives":
      let staged = monitorArtifactPath(MonitorShim64Name)
      check wow64ShimPathFor(staged) ==
        staged.parentDir / MonitorShim32Name

    test "the probe name is what wow64ProbePathFor derives":
      let staged = monitorArtifactPath(MonitorShim64Name)
      check wow64ProbePathFor(staged) == staged.parentDir / Wow64Probe32Name
      check Wow64ProbeExeName == Wow64Probe32Name

    test "the helper name is what inject64HelperPathFor derives":
      let staged = monitorArtifactPath(MonitorShim64Name)
      check inject64HelperPathFor(staged) ==
        staged.parentDir / Inject64HelperName
      check Inject64HelperExeName == Inject64HelperName

    test "the helper resolves from EITHER bitness of shim":
      # A 32-bit shim delegates 64-bit injection to the helper, so it looks
      # for it beside ITSELF. Both shims are staged in the same directory,
      # which is the property that makes that work.
      let shim64 = monitorArtifactPath(MonitorShim64Name)
      let shim32 = monitorArtifactPath(MonitorShim32Name)
      check shim64.parentDir == shim32.parentDir
      check inject64HelperPathFor(shim32) == inject64HelperPathFor(shim64)

    test "shim64PathFor inverts the 32-bit naming convention":
      # Compared on the basename: the injector's helpers round-trip through
      # `splitFile`, which normalises `/` to `\` on Windows, and the
      # separator is not the property under test here.
      let shim64 = monitorArtifactPath(MonitorShim64Name)
      check shim64PathFor(wow64ShimPathFor(shim64)).extractFilename ==
        MonitorShim64Name

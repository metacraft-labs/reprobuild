## The §5 runtime-wrapper / RPATH / env-default contract is encoded
## ONCE and applied identically to every format.
##
## Distribution-And-Packaging.md §5 is the milestone's "hard
## constraint", and its closing sentence is the requirement under test:
## "This contract is encoded **once** in the DSL packaging layer (§6)
## and reused by every format producer, so it is not re-hand-written per
## package."
##
## "Encoded once" is not directly observable — you cannot assert the
## absence of a second copy. What IS observable, and is what these cases
## check, is the consequence: two producers over one ``Distribution``
## put the SAME wrapper text and the SAME RPATH into their trees, and
## neither producer had any opportunity to differ, because a producer's
## input is a ``StagedTree`` whose files already exist as edge outputs.
##
## The Windows arm is checked in the same file rather than a separate
## one on purpose. §5 states ONE requirement with three mechanisms
## (RPATH on Linux, ``@loader_path`` on Darwin, PATH-adjacent DLL
## placement on Windows), and the interesting assertion is that the
## layer picks the right MECHANISM per target while producing the same
## GUARANTEE — which only reads as one assertion if both are here.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

suite "packaging: the §5 contract is applied by staging, not by producers":

  test "two producers over one Distribution stage identical wrappers":
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux)
    discard stageInstallTree(dist, "deb")
    let debWrapper = writtenText("bin-hello.wrapper")
    resetBuildActionRegistry()
    discard stageInstallTree(dist, "tar")
    let tarWrapper = writtenText("bin-hello.wrapper")
    check debWrapper.len > 0
    check debWrapper == tarWrapper

  test "the wrapper implements --set-default, not --set":
    # The flake's own comment is the specification: "--set-default
    # preserves explicit development/source overrides while making an
    # ordinary installed package independent of sibling checkouts and
    # the build-time dev shell." A wrapper that assigned
    # unconditionally would break every developer override, and would
    # look identical in a directory listing.
    let dist = sampleDistribution(toLinux)
    let text = posixWrapperText(dist, "hello.real", "bin")
    check text.contains("if [ -z \"${SAMPLETOOL_MODE:-}\" ]; then")
    check text.contains("export SAMPLETOOL_MODE")

  test "@PREFIX@ resolves at run time so one tree serves every format":
    let dist = sampleDistribution(toLinux)
    let text = posixWrapperText(dist, "hello.real", "bin")
    # The literal token must not survive into the shipped wrapper, and
    # the value must be built from the RUN-TIME-resolved prefix rather
    # than from a build-time constant — otherwise the tarball producer's
    # "relocatable" promise (§6) is simply false.
    check not text.contains(PrefixToken)
    check text.contains("__repro_prefix=$(cd -- \"$__repro_bin/..\" && pwd)")
    check text.contains("\"$__repro_prefix\"'/share/sampletool'")

  test "the wrapper execs the real binary from its own directory":
    let dist = sampleDistribution(toLinux)
    let text = posixWrapperText(dist, "hello.real", "bin")
    # Not an absolute path: the same wrapper ships in the fixed-prefix
    # deb and in the relocatable tarball.
    check text.contains("exec \"$__repro_bin/hello.real\" \"$@\"")

  test "Linux staging patches an $ORIGIN-relative RPATH on every ELF":
    # §5: zstd and clingo are dlopen'd BY LEAF NAME, so the loader
    # search path is the only thing that can find them. An absolute
    # RPATH would work for the deb and silently break the tarball.
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux)
    discard stageInstallTree(dist, "deb")
    let patchEdges = edgesInvoking("patchelf")
    check patchEdges.len == 2
    for edge in patchEdges:
      let argv = argvOf(edge)
      check "--force-rpath" in argv
      check "$ORIGIN/../lib/sampletool" in argv

  test "Windows staging uses no RPATH and no POSIX mode tool":
    # The same guarantee, a different mechanism. A layer that reached
    # for patchelf or for `install -m` here would be applying a Unix
    # answer to a platform that has neither concept.
    resetBuildActionRegistry()
    let dist = sampleDistribution(toWindows)
    discard stageInstallTree(dist, "msi")
    check edgesInvoking("patchelf").len == 0
    check edgesInvoking("install-file").len == 0

  test "Windows places the runtime library beside the executables":
    # ``prefix_layout.runtimeLibDir`` already encodes the rule that the
    # loadable image lives in bin/ on Windows. The packaging layer must
    # consume that rather than inventing a private libdir the Windows
    # loader would never look in.
    var win = sampleDistribution(toWindows)
    win.components.add(runtimeLibraryComponent("build/bin/sample.dll"))
    check installRelPath(win, win.components[^1]) == "bin/sample.dll"
    var linux = sampleDistribution(toLinux)
    linux.components.add(runtimeLibraryComponent("build/lib/libsample.so"))
    check installRelPath(linux, linux.components[^1]) ==
      "lib/sampletool/libsample.so"

  test "the Windows wrapper takes the .exe name so PATH still finds it":
    # A wrapper called ``hello.exe.cmd`` is not reachable by typing
    # ``hello``: it would exist, be correct, and never run.
    let win = sampleDistribution(toWindows)
    check wrapperFileName(win, "hello.exe") == "hello.cmd"
    check realFileName(win, "hello.exe") == "hello-real.exe"
    let posix = sampleDistribution(toLinux)
    check wrapperFileName(posix, "hello") == "hello"
    check realFileName(posix, "hello") == "hello.real"

  test "the Windows wrapper sets defaults conditionally and normalises paths":
    let win = sampleDistribution(toWindows)
    let text = windowsWrapperText(win, "hello-real.exe", "bin")
    check text.contains("if not defined SAMPLETOOL_MODE set")
    # A value carrying the prefix token is by construction a path, and
    # the recipe wrote it once for every target; leaving forward slashes
    # in a cmd.exe variable is how a package ships a value that "works"
    # until something concatenates it with a backslash.
    check text.contains("%REPRO_PACKAGE_PREFIX%\\share\\sampletool")
    check not text.contains("%REPRO_PACKAGE_PREFIX%/share")

  test "no staging edge rewrites a file another staging edge produced":
    # The install tree is meant to be a DAG of pure edges: that is what
    # makes a rebuild a cache HIT rather than a re-run that happens to
    # produce the same bytes. One in-place edge anywhere would make the
    # tree's contents depend on execution order.
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux)
    discard debPackage(dist)
    var seen: seq[string] = @[]
    for act in registeredBuildActions():
      for output in act.outputs:
        check output notin seen
        seen.add(output)

  test "an unwrapped distribution still gets its RPATH":
    # ``wrapExecutables = false`` is the right setting for a
    # distribution with no environment defaults. It must not also turn
    # off the library-path half of §5, which is a separate requirement
    # that applies to every Linux package.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.wrapExecutables = false
    let tree = stageInstallTree(dist, "deb")
    check edgesInvoking("patchelf").len == 2
    check "usr/bin/hello" in stagedRelPaths(tree)
    check "usr/bin/hello.real" notin stagedRelPaths(tree)

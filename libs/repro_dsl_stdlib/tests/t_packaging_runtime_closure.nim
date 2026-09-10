## §5's first bullet — the VENDORED runtime-library closure — and the ELF
## interpreter that has to travel with it.
##
## Distribution-And-Packaging.md §5 asks for "vendored runtime libraries
## bundled into the package under a private libdir, with
## RPATH/``@loader_path``/``$ORIGIN`` … so ``dlopen``-by-leaf-name
## resolves", and calls the section "the hard constraint" because a
## package that gets it wrong installs perfectly and then does not run.
##
## That is exactly how M0 first failed on a stock Debian image: the
## layer wrote ``DT_RPATH = $ORIGIN/../lib/sampletool`` onto every
## payload and shipped no such directory, so the payload came out
## STRICTLY worse than unpatched — ``--set-rpath`` REPLACES what the
## linker wrote, so the binary lost the paths it was linked against and
## gained an empty one. Both invocations exited 127.
##
## ## What a unit suite can and cannot say about this
##
## It cannot run a loader. Whether the vendored set is SUFFICIENT is an
## end-to-end fact and is settled by installing the .deb on a stock
## image and running the binary — which is the gate's own wording and is
## where this was found in the first place.
##
## What it CAN say is everything upstream of that, and each of those is
## a way the fix could be quietly wrong:
##
## * the system/private RULE — vendoring the C library breaks on the
##   target, failing to vendor a private library is the original bug,
##   and both directions have to be pinned or the rule drifts;
## * that the walk starts from the AS-BUILT binaries rather than from
##   the patched copies, which no longer know where anything lives;
## * that the private libdir the walk fills is the SAME directory the
##   RPATH names — the two are computed once, and this is what stops
##   them from drifting apart again;
## * that the interpreter is rewritten on executables and not on
##   libraries;
## * that ``dlopenLeafNames`` is a checked post-condition rather than a
##   comment.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc closureEdges(): seq[BuildActionDef] =
  ## Every runtime-closure edge in the current registry, found by its id
  ## suffix rather than by position: a test that indexed into the
  ## registry would pass for the wrong edge the moment staging grew one.
  for act in registeredBuildActions():
    if act.id.endsWith("runtime-closure"): result.add(act)

proc closureScriptOf(act: BuildActionDef): string =
  for arg in act.call.arguments:
    if arg.name == "command": return arg.encodedValue
  ""

suite "packaging: the vendored runtime-library closure":

  test "the C library and the loader are the target's, never the package's":
    # Vendoring any of these is not a matter of taste. glibc is a SET
    # whose members are version-matched to each other and to the loader
    # at build time, so dropping one next to a target's ld.so gives
    # "version `GLIBC_2.xx' not found" at best and two allocators in one
    # address space at worst; and it is self-defeating, because
    # getaddrinfo and iconv_open dlopen NSS and gconv modules the TARGET
    # names and built against the TARGET's glibc.
    for leaf in ["libc.so.6", "libm.so.6", "libpthread.so.0",
                 "libdl.so.2", "librt.so.1", "libutil.so.1",
                 "libresolv.so.2", "libnsl.so.1", "libanl.so.1",
                 "libmvec.so.1", "libthread_db.so.1",
                 "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
                 "ld-linux.so.2", "ld64.so.2", "linux-vdso.so.1",
                 "libnss_files.so.2"]:
      check isSystemLibraryLeafName(leaf)

  test "everything else is the package's to ship":
    # The direction the original defect points. None of these exists on
    # a stock Debian image, so a package that ships none of them is a
    # package that cannot start.
    for leaf in ["libblake3.so.0", "libxxhash.so.0", "libzstd.so.1",
                 "libclingo.so.4", "libsqlite3.so.0", "libssl.so.3",
                 "libcrypto.so.3", "libtbb.so.12"]:
      check not isSystemLibraryLeafName(leaf)

  test "libgcc_s and libstdc++ are private, deliberately":
    # They are the GCC runtime, not the platform ABI. A manylinux wheel
    # may treat them as system because it pins a minimum distro; a
    # native package has no such pin. Both are upward-compatible, so
    # vendoring a newer copy is safe, while NOT vendoring one fails at
    # run time on any target older than the builder. Vendored is the
    # fail-safe direction and system is not.
    check not isSystemLibraryLeafName("libgcc_s.so.1")
    check not isSystemLibraryLeafName("libstdc++.so.6")
    # Same reasoning, one name further out: on a modern distribution
    # libcrypt comes from libxcrypt, a package a minimal image need not
    # carry.
    check not isSystemLibraryLeafName("libcrypt.so.1")

  test "the rule ignores the soversion, and only the soversion":
    # ``libfoo.so.0`` and ``libfoo.so.1.2.3`` are the same LIBRARY and
    # must classify the same way; ``libcx.so.1`` and ``libc.so.6`` are
    # not the same library and must not.
    check libraryStem("libxxhash.so.0.8.3") == "libxxhash"
    check libraryStem("ld-linux-x86-64.so.2") == "ld-linux-x86-64"
    check isSystemLibraryLeafName("libc.so.6")
    check not isSystemLibraryLeafName("libcx.so.1")
    check not isSystemLibraryLeafName("libcurl.so.4")

  test "a recipe can ADD to the system set but not remove from it":
    check isSystemLibraryLeafName("libselinux.so.1", ["libselinux.so.1"])
    check isSystemLibraryLeafName("libselinux.so.1", ["libselinux"])
    check not isSystemLibraryLeafName("libselinux.so.1")
    # There is no subtractive form: every built-in name is a member of
    # the C library's own version-locked group, so removing one is a
    # target crash rather than a preference.
    check isSystemLibraryLeafName("libc.so.6", ["something-else"])

  test "Linux staging emits exactly one closure edge per tree":
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    check closureEdges().len == 1

  test "the walk starts from the AS-BUILT binaries, not the patched copies":
    # The whole point. ``stageInstallTree`` replaces each payload's
    # RPATH with an $ORIGIN one, which destroys the only record of where
    # its libraries live; a walk seeded with the patched copy would find
    # nothing and would report an empty closure as success.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let script = closureScriptOf(closureEdges()[0])
    check script.contains("seed 'build/bin/hello'")
    check script.contains("seed 'build/bin/adder'")
    check not script.contains(".patched")

  test "the directory the walk fills is the one the RPATH names":
    # These drifting apart IS the M0 defect, so they are computed once
    # and asserted against each other here.
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux)
    let tree = stageInstallTree(dist, "deb")
    let edge = closureEdges()[0]
    check rpathFor(dist, "bin") == "$ORIGIN/../lib/sampletool"
    check edge.declaredOutputs == @[tree.root & "/usr/lib/sampletool"]
    check closureScriptOf(edge).contains(
      "LIBDIR='" & tree.root & "/usr/lib/sampletool'")

  test "the closure edge declares a write ROOT, not a file list":
    # The vendored set is discovered at build time, so there are no
    # per-file outputs to declare. This is the shape cmake_package's
    # install edge uses for a DESTDIR, and the same M9.R.75 pairwise
    # check grades it.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let edge = closureEdges()[0]
    check edge.declaredOutputs.len == 1
    check edge.outputs.len == 1
    check edge.outputs[0].endsWith("deb-runtime-closure.manifest")

  test "the closure edge names sh, patchelf and coreutils":
    # An action's PATH holds only the tools its own edge named. The walk
    # runs patchelf, and reaches cp/mkdir/touch/ls/sort through the
    # package that provides ``install`` -- the same lesson as the tar
    # edge's undeclared gzip, one tool further out.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let edge = closureEdges()[0]
    var refs: seq[string] = @[]
    for act in registeredBuildActions():
      if act.id == edge.id: refs = act.toolIdentityRefs
    check ShSelector in refs
    check PatchelfSelector in refs
    check InstallSelector in refs

  test "the walk runs after every payload has been staged":
    # It owns a DIRECTORY and prunes what it does not recognise, so an
    # ordering that let it run before an install edge that stages a
    # declared crRuntimeLibrary would have it delete another edge's
    # output.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(runtimeLibraryComponent("build/lib/libsample.so"))
    let tree = stageInstallTree(dist, "deb")
    let edge = closureEdges()[0]
    for staged in tree.files:
      check staged.edge.id in edge.deps
    # ... and the declared library is on the keep list, so the prune
    # cannot remove it.
    check closureScriptOf(edge).contains("keep=$keep'libsample.so'")

  test "each vendored library gets an $ORIGIN RPATH of its own":
    # Not belt and braces. glibc consults the RPATH CHAIN of an object's
    # loaders only when the object itself carries no DT_RUNPATH, and a
    # nixpkgs build always carries one pointing into the store -- so a
    # vendored libblake3 that kept its own RUNPATH would be found
    # through the executable's RPATH and would then fail to find libtbb
    # sitting right next to it.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    check closureScriptOf(closureEdges()[0]).contains(
      "patchelf --force-rpath --set-rpath '$ORIGIN' \"$LIBDIR/$1\"")

  test "the shell applies the same system rule the Nim predicate states":
    # Two spellings of one rule is how a rule rots. The shell's `case`
    # is generated from ``SystemLibraryStems``, and this reads it back.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let script = closureScriptOf(closureEdges()[0])
    for stem in SystemLibraryStems:
      check script.contains(stem & "|") or script.contains("|" & stem & ")")
    check script.contains("ld-linux*|ld|ld64*|linux-vdso*|linux-gate*|libnss_*")

  test "an extra system name reaches the generated shell":
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.extraSystemLibraryLeafNames = @["libselinux.so.1"]
    discard stageInstallTree(dist, "deb")
    check closureScriptOf(closureEdges()[0]).contains("libselinux.so.1|libselinux)")

  test "dlopen leaf names become a checked post-condition":
    # DT_NEEDED cannot see a dlopen, so the walk cannot DISCOVER these.
    # What it can do is refuse to finish unless each one resolves into
    # the private libdir -- which is what makes the field load-bearing
    # rather than documentation.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.dlopenLeafNames = @["libzstd.so.1", "libclingo.so.4"]
    discard stageInstallTree(dist, "deb")
    let script = closureScriptOf(closureEdges()[0])
    check script.contains("require_dlopen 'libzstd.so.1'")
    check script.contains("require_dlopen 'libclingo.so.4'")
    check script.contains("runtime.dlopenLeafNames")

  test "an empty dlopen list asserts nothing, and says so by emitting nothing":
    # The fixture's list is empty and that is a true statement about it
    # (two Nim programs importing std/os), not an unexamined default.
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux)
    check dist.runtime.dlopenLeafNames.len == 0
    discard stageInstallTree(dist, "deb")
    check not closureScriptOf(closureEdges()[0]).contains("require_dlopen '")

  test "an extra search dir is how an unreferenced dlopen name is found":
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.extraLibrarySearchDirs = @["/opt/vendor/lib"]
    discard stageInstallTree(dist, "deb")
    check closureScriptOf(closureEdges()[0]).contains(
      "add_search '/opt/vendor/lib'")

  test "two producers over one Distribution get two independent closures":
    # Same reason the trees are separate: the deb tree is rooted at /
    # and the tarball's at the prefix, so the private libdir is at a
    # different path in each, and one edge filling both would put the
    # libraries in the wrong place for one of them.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    let tar = tarballPackage(sampleDistribution(toLinux))
    let edges = closureEdges()
    check edges.len == 2
    check edges[0].id != edges[1].id
    check edges[0].declaredOutputs != edges[1].declaredOutputs
    check deb.tree.root & "/usr/lib/sampletool" in edges[0].declaredOutputs
    check tar.tree.root & "/lib/sampletool" in edges[1].declaredOutputs

  test "the artifact edge depends on the closure manifest":
    # The vendored libraries are written by an ACTION rather than being
    # per-file edge outputs, so there is no staged path for the producer
    # to name. Without the manifest a changed closure would not re-run
    # dpkg-deb, and the .deb would be content-addressed over a tree it
    # no longer matches.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    var found = false
    for input in deb.edge.inputs:
      if input.endsWith("deb-runtime-closure.manifest"): found = true
    check found
    resetBuildActionRegistry()
    let tar = tarballPackage(sampleDistribution(toLinux))
    found = false
    for input in tar.edge.inputs:
      if input.endsWith("tar-runtime-closure.manifest"): found = true
    check found

  test "turning the walk off removes the edge and nothing else":
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.vendorRuntimeClosure = false
    discard stageInstallTree(dist, "deb")
    check closureEdges().len == 0
    # The RPATH is still written: it is a separate half of §5 and a
    # distribution with no vendored libraries still needs it for any
    # library a later component adds.
    check edgesInvoking("patchelf").len == 2

  test "Windows stages no closure edge and claims no shell":
    # §5 names three mechanisms for one requirement. On Windows the
    # loadable image sits beside the executable and there is no RPATH,
    # so a closure walk here would be a Unix answer applied to a
    # platform that has neither concept.
    resetBuildActionRegistry()
    let msi = msiPackage(sampleDistribution(toWindows))
    check closureEdges().len == 0
    check ShSelector notin msi.toolSelectors
    check PatchelfSelector notin msi.toolSelectors

suite "packaging: the ELF interpreter travels with the closure":

  test "executables get the target's loader, libraries get none":
    # A shared library has no PT_INTERP and patchelf refuses
    # --set-interpreter on one, so asking would turn every vendored
    # library into a build failure.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(runtimeLibraryComponent("build/lib/libsample.so"))
    discard stageInstallTree(dist, "deb")
    var withInterp = 0
    var withoutInterp = 0
    for act in edgesInvoking("patchelf"):
      let argv = argvOf(act)
      if "--set-interpreter" in argv:
        inc withInterp
        check "/lib64/ld-linux-x86-64.so.2" in argv
      else:
        inc withoutInterp
    check withInterp == 2
    check withoutInterp == 1

  test "the loader path is the architecture's, not the builder's":
    # These are the paths the per-architecture ABI supplements fix; they
    # are not a Debian convention.
    check defaultInterpreterPath("x86_64") == "/lib64/ld-linux-x86-64.so.2"
    check defaultInterpreterPath("aarch64") == "/lib/ld-linux-aarch64.so.1"
    check defaultInterpreterPath("i686") == "/lib/ld-linux.so.2"
    check defaultInterpreterPath("riscv64") ==
      "/lib/ld-linux-riscv64-lp64d.so.1"
    check defaultInterpreterPath("ppc64le") == "/lib64/ld64.so.2"
    check defaultInterpreterPath("s390x") == "/lib/ld64.so.1"

  test "a recipe can override the loader path":
    # The escape hatch a musl target, or a non-standard prefix, needs.
    var dist = sampleDistribution(toLinux)
    dist.runtime.interpreterPath = "/lib/ld-musl-x86_64.so.1"
    check interpreterPathFor(dist) == "/lib/ld-musl-x86_64.so.1"

  test "an architecture with no known loader is REFUSED, not skipped":
    # Skipping would leave the staged executables naming the BUILDER's
    # interpreter, and the package would install cleanly and fail to
    # start with "not found" for a file that is plainly there. That is
    # precisely the failure this milestone is closing, so the layer must
    # not be able to reintroduce it by falling through.
    var dist = sampleDistribution(toLinux)
    dist.architecture = "sparc64"
    var raised = false
    try:
      dist.validate()
    except ValueError as err:
      raised = true
      check err.msg.contains("no known ELF interpreter")
      check err.msg.contains("runtime.interpreterPath")
    check raised

  test "the refusal does not fire for a target that has no interpreter":
    # Windows has no ELF interpreter and no closure walk, so an unknown
    # architecture there is not this error.
    var win = sampleDistribution(toWindows)
    win.architecture = "sparc64"
    win.validate()

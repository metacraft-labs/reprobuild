## Whether a published install mirror survives being restored somewhere else.
##
## NO MOCKS. Every ELF this file reads is either a real binary on the host
## (``patchelf``, the host's dynamic loader) or one written by ``patchelf``
## itself in a temp directory. The classifier is pure path arithmetic and is
## exercised directly.
##
## The two fields under test fail in ways that look nothing alike — a stale
## ``PT_INTERP`` is ``exit 127`` on a file that is plainly there, a stale
## ``DT_RUNPATH`` is a library that goes missing halfway through a program —
## so each is asserted on its own, in both directions.

import std/[os, osproc, streams, strutils, tempfiles, unittest]
import repro_project_dsl/install_mirror_relocation

const
  ProducerRoot = "/home/somebody/checkout-a/packages/source"
  ConsumerRoot = "/home/somebody-else/checkout-b/packages/source"
  ForeignMirrorLib =
    ProducerRoot & "/zlib/.repro/output/install/usr/lib"
  LocalMirrorLib =
    ConsumerRoot & "/zlib/.repro/output/install/usr/lib"

suite "install mirror path relocatability":
  test "a sibling mirror under a foreign checkout is remappable, and the remap names this checkout":
    check classifyInstallMirrorPath(ForeignMirrorLib, ConsumerRoot,
      ConsumerRoot & "/python3/.repro/output/install") == rvRemappable
    check remapInstallMirrorPath(ForeignMirrorLib, ConsumerRoot) ==
      LocalMirrorLib

  test "the same path under THIS checkout is already portable":
    check classifyInstallMirrorPath(LocalMirrorLib, ConsumerRoot,
      ConsumerRoot & "/python3/.repro/output/install") == rvPortable

  test "a cached loader path from another checkout is remappable and names gcc":
    # The SHAPE here is the one a cached ``make`` really carries: a producer
    # checkout whose directory name is neither the package's nor this
    # checkout's, a ``.repro/output/install`` segment, and the loader under
    # ``usr/lib``. That shape is the whole of what makes the value
    # rewritable, so it is what the case pins.
    const observed = "/srv/builder-7/" &
      "packages-checkout-b7deec3/packages/source/gcc/" &
      ".repro/output/install/usr/lib/ld-linux-x86-64.so.2"
    let split = splitMirrorPath(observed)
    check split.matched
    check split.depName == "gcc"
    check split.rest == "usr/lib/ld-linux-x86-64.so.2"
    check classifyInstallMirrorPath(observed, ConsumerRoot,
      ConsumerRoot & "/make/.repro/output/install") == rvRemappable
    check remapInstallMirrorPath(observed, ConsumerRoot) ==
      ConsumerRoot & "/gcc/.repro/output/install/usr/lib/ld-linux-x86-64.so.2"

  test "content-addressed store paths are portable and are NOT rewritten":
    for storeRoot in ImmutableStoreRoots:
      let path = storeRoot & "abc123-glibc-2.40/lib/ld-linux-x86-64.so.2"
      check classifyInstallMirrorPath(path, ConsumerRoot, "") == rvPortable
      # A store path has no package segment to rewrite, and inventing one
      # would move a correct path to a directory that does not exist.
      check remapInstallMirrorPath(path, ConsumerRoot).len == 0

  test "an $ORIGIN entry is portable and a non-mirror absolute path is foreign":
    check classifyInstallMirrorPath(OriginToken & "/../lib", ConsumerRoot,
      "") == rvPortable
    # A path into the TARGET ROOTFS carries no package mirror segment, so
    # there is nothing to rewrite it onto. It is reported rather than
    # quietly passed, and deliberately not refused — see the work-tree
    # suite below for the line between the two.
    check classifyInstallMirrorPath("/usr/lib/systemd", ConsumerRoot, "") ==
      rvForeign

  test "a traversal component is not a package name and nothing is rewritten onto it":
    # ``<root>/a/b/../.repro/output/install/...`` ends in the mirror shape, and
    # the segment before it is ``..``. Reading that as a package name would
    # build a remap that climbs OUT of the recipes root — a rewrite to a
    # directory outside the checkout doing the rewriting. Refuse the split
    # instead, and let the value be reported as foreign.
    const traversal = "/opt/a/b/../.repro/output/install/usr/lib"
    check not splitMirrorPath(traversal).matched
    check remapInstallMirrorPath(traversal, ConsumerRoot).len == 0
    check classifyInstallMirrorPath(traversal, ConsumerRoot, "") == rvForeign
    const selfRef = "/opt/a/./.repro/output/install/usr/lib"
    check not splitMirrorPath(selfRef).matched
    check classifyInstallMirrorPath(selfRef, ConsumerRoot, "") == rvForeign

  test "a path inside the mirror being audited moves with it":
    let mirror = ConsumerRoot & "/python3/.repro/output/install"
    check classifyInstallMirrorPath(mirror & "/usr/lib", ConsumerRoot,
      mirror) == rvOwnMirror

  test "a mirror root reads back as its recipes root and package name":
    let roots = installMirrorCheckoutRoots(
      ConsumerRoot & "/python3/.repro/output/install")
    check roots.matched
    check roots.recipesRoot == ConsumerRoot
    check roots.packageName == "python3"
    check not installMirrorCheckoutRoots(ConsumerRoot & "/python3").matched

  test "the diagnostic names the package, the field, the object and the path":
    # The object path deliberately does NOT contain the package name, and the
    # package is pinned by POSITION rather than by ``in``: a message that
    # dropped the package would still contain it as a substring of the path
    # it prints, so the obvious assertion cannot fail.
    let finding = MirrorPathFinding(
      objectPath: "/tmp/mirror/usr/bin/sample",
      field: rpfInterpreter,
      value: ForeignMirrorLib & "/ld-linux-x86-64.so.2",
      verdict: rvRemappable,
      remapped: LocalMirrorLib & "/ld-linux-x86-64.so.2")
    let text = describeMirrorPathFinding("make", finding)
    # ``exit 127`` names none of these four. That is the whole point of the
    # message, so each is asserted separately rather than as one blob.
    check text.startsWith("install mirror: make: PT_INTERP of ")
    check "/tmp/mirror/usr/bin/sample" in text
    check ForeignMirrorLib & "/ld-linux-x86-64.so.2" in text
    check LocalMirrorLib & "/ld-linux-x86-64.so.2" in text
    # And the field really is read from the finding rather than printed as a
    # constant: the other field produces the other name.
    var runPathFinding = finding
    runPathFinding.field = rpfRunPath
    check describeMirrorPathFinding("make", runPathFinding).startsWith(
      "install mirror: make: DT_RUNPATH of ")

## The paths below are TRANSCRIBED from published install mirrors on a real
## host — every one of them is a run path some build baked into an object it
## then published. They are literals here rather than a walk over whatever
## mirrors happen to be built on the machine running this suite, because a
## rule whose only input is "the artifacts this host has" has no input at
## all on a clean checkout.
const
  WorkTreePaths = [
    # The out-of-tree build directory's DESTDIR staging child. By far the
    # commonest shape.
    "/home/builder/packages-checkout/packages/source/qt6-base/build/out/usr/lib",
    # The same, with the library directory spelled the other way.
    "/home/builder/packages-checkout/packages/source/pam/build/out/lib64",
    # libtool's staging directory, nested well below the build root.
    "/home/builder/packages-checkout/packages/source/sudo/build/lib/util/.libs",
    # The same, directly under it.
    "/home/builder/packages-checkout/packages/source/util-linux/build/.libs",
    # The build root ITSELF, with nothing after it.
    "/home/builder/packages-checkout/packages/source/glibc/build",
    # The engine's own per-recipe scratch, which is not under ``build/``.
    "/home/builder/packages-checkout/packages/source/gcc/.repro/build/" &
      "from-source-custom/gccSource/lib",
    # An outputs tree, which is neither of the two above.
    "/home/builder/packages-checkout/packages/source/perl/outputs/out/lib",
  ]

  TargetRootfsPaths = [
    # Every one of these was observed too, and NONE of them is a defect of
    # this kind: each is correct once the mirror has been staged into the
    # image it was built for. They are the negative control, and without
    # them a rule that refused every unrewritable path would pass the
    # cases above.
    "/usr/lib",
    "/usr/lib/systemd",
    "/usr/libexec/sudo",
    "/usr/lib/perl5/5.40.0/x86_64-linux/CORE",
    "/lib64/ld-linux-x86-64.so.2",
  ]

suite "a recipe work tree is a place no consumer can look":
  test "every observed work-tree shape is refused BY SHAPE":
    for path in WorkTreePaths:
      checkpoint path
      check classifyInstallMirrorPath(path, ConsumerRoot, "") ==
        rvRecipeWorkTree

  test "and no target-rootfs path is, so the rule discriminates":
    # The half that stops this being a blanket refusal. Each of these is
    # unrewritable too — the verdict that separates them is the claim.
    for path in TargetRootfsPaths:
      checkpoint path
      check classifyInstallMirrorPath(path, ConsumerRoot, "") == rvForeign

  test "the recipe and the work tree are READ OFF the path, not constants":
    # Two different inputs must give two different answers, or a splitter
    # returning fixed strings would satisfy the cases above.
    let qt = splitRecipeWorkTreePath(WorkTreePaths[0])
    check qt.matched
    check qt.recipeName == "qt6-base"
    check qt.workTree == "build"
    check qt.rest == "out/usr/lib"
    let gcc = splitRecipeWorkTreePath(WorkTreePaths[5])
    check gcc.matched
    check gcc.recipeName == "gcc"
    check gcc.workTree == ".repro/build"
    check gcc.rest == "from-source-custom/gccSource/lib"
    let perl = splitRecipeWorkTreePath(WorkTreePaths[6])
    check perl.matched
    check perl.recipeName == "perl"
    check perl.workTree == "outputs/out"
    check perl.rest == "lib"
    # The build root with nothing after it: matched, with an empty rest
    # rather than no match.
    let glibc = splitRecipeWorkTreePath(WorkTreePaths[4])
    check glibc.matched
    check glibc.recipeName == "glibc"
    check glibc.workTree == "build"
    check glibc.rest.len == 0

  test "THE PUBLISH SIDE: a work tree under the auditing checkout is refused too":
    # This is the case the rule exists for, and the one that is easiest to
    # lose. On the machine that BAKES the path in, the directory is sitting
    # right there under that machine's own recipes root — so a classifier
    # that asked "is this under the checkout I am auditing from?" first
    # would call it portable, publish it, and leave the defect to be
    # discovered by a consumer who has no way to repair it.
    let own = ConsumerRoot & "/qt6-base/build/out/usr/lib"
    check own.startsWith(ConsumerRoot)
    check classifyInstallMirrorPath(own, ConsumerRoot,
      ConsumerRoot & "/qt6-base/.repro/output/install") == rvRecipeWorkTree

  test "a directory called build INSIDE a published mirror is not a work tree":
    # A mirror may ship a ``build`` directory of its own, and it travels
    # with the package. Refusing it would be refusing the artifact for
    # carrying its own contents.
    let insideSibling =
      ProducerRoot & "/cmake/.repro/output/install/usr/share/foo/build/out/lib"
    check not splitRecipeWorkTreePath(insideSibling).matched
    check classifyInstallMirrorPath(insideSibling, ConsumerRoot, "") ==
      rvRemappable
    let ownMirror = ConsumerRoot & "/cmake/.repro/output/install"
    check classifyInstallMirrorPath(ownMirror & "/usr/share/foo/build/out/lib",
      ConsumerRoot, ownMirror) == rvOwnMirror

  test "a work-tree directory with no recipe root in front of it is not one":
    # ``/build/out/lib`` names no recipe. It is somebody's root filesystem,
    # and the rule must not read the leading separator as a recipe name.
    check not splitRecipeWorkTreePath("/build/out/lib").matched
    check classifyInstallMirrorPath("/build/out/lib", ConsumerRoot, "") ==
      rvForeign
    # Nor a traversal component, for the same reason ``splitMirrorPath``
    # refuses one: the "recipe" it named would be outside the tree.
    check not splitRecipeWorkTreePath("/opt/a/../build/out/lib").matched
    # And a relative entry is the loader's business, not this rule's.
    check not splitRecipeWorkTreePath("../build/out/lib").matched

  test "the diagnostic names the recipe and the work tree it came from":
    let finding = MirrorPathFinding(
      objectPath: "/tmp/mirror/usr/bin/sample",
      field: rpfRunPath,
      value: WorkTreePaths[0],
      verdict: rvRecipeWorkTree)
    let text = describeMirrorPathFinding("sudo", finding)
    checkpoint text
    check "qt6-base" in text
    check "\"build\"" in text
    check "exists on no other machine" in text
    # Read off the finding, not printed as a constant.
    var other = finding
    other.value = WorkTreePaths[6]
    let otherText = describeMirrorPathFinding("sudo", other)
    check "perl" in otherText
    check "\"outputs/out\"" in otherText
    check "qt6-base" notin otherText

when defined(linux) or defined(macosx):
  proc run(command: string; args: openArray[string]):
      tuple[output: string, exitCode: int] =
    let child = startProcess(command, args = args,
      options = {poUsePath, poStdErrToStdOut})
    defer: child.close()
    child.inputStream.close()
    result.output = child.outputStream.readAll()
    result.exitCode = child.waitForExit()

  suite "install mirror ELF reading":
    test "a real dynamic executable reports its interpreter, NEEDED and RUNPATH":
      let patchelf = findExe("patchelf")
      require patchelf.len > 0
      let facts = readElfRuntimeFacts(patchelf)
      require facts.isElf
      require facts.parsed
      # Cross-check every field against patchelf's own reading of the same
      # file rather than against this reader's expectations of it.
      let interpreter = run(patchelf, @["--print-interpreter", patchelf])
      require interpreter.exitCode == 0
      check facts.interpreter == interpreter.output.strip()
      let needed = run(patchelf, @["--print-needed", patchelf])
      require needed.exitCode == 0
      var expectedNeeded: seq[string]
      for line in needed.output.splitLines():
        if line.strip().len > 0: expectedNeeded.add(line.strip())
      check facts.needed == expectedNeeded
      let rpath = run(patchelf, @["--print-rpath", patchelf])
      require rpath.exitCode == 0
      var expectedRunPaths: seq[string]
      for part in rpath.output.strip().split(':'):
        if part.len > 0 and part notin expectedRunPaths:
          expectedRunPaths.add(part)
      check facts.runPaths == expectedRunPaths

    test "a repeated run-path entry is recorded ONCE":
      # The reader folds ``DT_RPATH`` and ``DT_RUNPATH`` into one deduplicated
      # list, and the audit counts entries off that list. The cross-check case
      # above cannot see the rule: it rebuilds its expectation with the SAME
      # dedup, and this host's ``patchelf`` carries no repeated entry anyway,
      # so removing the rule was green. ``patchelf`` DOES preserve a duplicate
      # it is handed, which is the reachable input the rule never had.
      let patchelf = findExe("patchelf")
      require patchelf.len > 0
      let scratch = createTempDir("repro-mirror-dedup-", "")
      defer: removeDir(scratch)
      let sample = scratch / "sample"
      copyFileWithPermissions(patchelf, sample)
      setFilePermissions(sample, getFilePermissions(sample) + {fpUserWrite})
      const repeated = "/opt/one:/opt/one:/opt/two"
      require run(patchelf, @["--set-rpath", repeated, sample]).exitCode == 0
      # The duplicate really did survive into the file, so the assertion below
      # is about the reader rather than about what patchelf chose to write.
      let written = run(patchelf, @["--print-rpath", sample])
      require written.exitCode == 0
      check written.output.strip() == repeated
      check readElfRuntimeFacts(sample).runPaths == @["/opt/one", "/opt/two"]

    test "a non-ELF file is not an ELF, and an unreadable one is not silently clean":
      let scratch = createTempDir("repro-mirror-elf-", "")
      defer: removeDir(scratch)
      let text = scratch / "not-an-elf"
      writeFile(text, "#!/bin/sh\nexit 0\n")
      check not readElfRuntimeFacts(text).isElf
      # A file that starts like an ELF but cannot be decoded must report
      # ``parsed == false``. An empty-facts object would read exactly like a
      # clean binary, which is how an unchecked object becomes a checked one.
      let truncated = scratch / "truncated-elf"
      var header = newString(64)
      for i in 0 ..< header.len: header[i] = '\0'
      header[0] = '\x7F'; header[1] = 'E'; header[2] = 'L'; header[3] = 'F'
      header[4] = '\x02'   # ELFCLASS64
      header[5] = '\x01'   # ELFDATA2LSB
      header[6] = '\x01'   # EV_CURRENT
      header[0x20] = '\x00'; header[0x21] = '\x10'  # e_phoff = 0x1000
      header[0x36] = '\x38'                          # e_phentsize = 56
      header[0x38] = '\x01'                          # e_phnum = 1
      writeFile(truncated, header)
      let facts = readElfRuntimeFacts(truncated)
      check facts.isElf
      check not facts.parsed
      check facts.unsupported.len > 0

    test "the audit walks NESTED objects, not just the directories binaries live in":
      # The object that first exposed this in a real mirror was a CPython
      # extension module three levels below ``usr/lib``.
      let patchelf = findExe("patchelf")
      require patchelf.len > 0
      let scratch = createTempDir("repro-mirror-audit-", "")
      defer: removeDir(scratch)
      let recipesRoot = scratch / "packages" / "source"
      let mirror = recipesRoot / "python3" / ".repro" / "output" / "install"
      let nested = mirror / "usr" / "lib" / "python3.13" / "lib-dynload"
      createDir(nested)
      let elfObject = nested / "binascii.so"
      copyFileWithPermissions(patchelf, elfObject)
      setFilePermissions(elfObject, getFilePermissions(elfObject) + {fpUserWrite})
      const foreignLib =
        "/elsewhere/packages/source/zlib/.repro/output/install/usr/lib"
      require run(patchelf, @["--set-rpath", foreignLib, elfObject]).exitCode == 0
      let audit = auditInstallMirrorRelocatability(mirror, recipesRoot)
      check audit.elfCount == 1
      check audit.unreadable.len == 0
      var seen = 0
      for finding in audit.findings:
        if finding.field == rpfRunPath and finding.value == foreignLib:
          check finding.verdict == rvRemappable
          check finding.remapped ==
            recipesRoot & "/zlib/.repro/output/install/usr/lib"
          inc seen
      check seen == 1

    test "an ELF the reader cannot decode is REPORTED, not counted as clean":
      # ``unreadable`` is the honest-absence arm: an object that could not be
      # read has not been checked, and saying nothing about it would be
      # indistinguishable from clearing it.
      let scratch = createTempDir("repro-mirror-unreadable-", "")
      defer: removeDir(scratch)
      let recipesRoot = scratch / "packages" / "source"
      let mirror = recipesRoot / "make" / ".repro" / "output" / "install"
      createDir(mirror / "usr" / "bin")
      let broken = mirror / "usr" / "bin" / "undecodable"
      var header = newString(64)
      for i in 0 ..< header.len: header[i] = '\0'
      header[0] = '\x7F'; header[1] = 'E'; header[2] = 'L'; header[3] = 'F'
      header[4] = '\x02'; header[5] = '\x01'; header[6] = '\x01'
      header[0x20] = '\x00'; header[0x21] = '\x10'
      header[0x36] = '\x38'
      header[0x38] = '\x01'
      writeFile(broken, header)
      let audit = auditInstallMirrorRelocatability(mirror, recipesRoot)
      check audit.elfCount == 1
      check audit.unreadable == @[broken]
      check audit.findings.len == 0
      let reported = relocateRestoredInstallMirror(mirror, findExe("patchelf"),
        proc (executable: string; args: seq[string]):
            tuple[output: string, exitCode: int] =
          run(executable, args))
      check "undecodable" in reported.message
      check "has not been checked" in reported.message

  proc realPatchelfRunner(executable: string; args: seq[string]):
      tuple[output: string, exitCode: int] =
    run(executable, args)

  suite "restoring a mirror under this checkout":
    proc stageMirror(scratch, package: string): tuple[recipesRoot,
        mirror, elfObject: string] =
      ## A real ``patchelf`` binary, laid out the way a restored cache entry
      ## is, carrying a RUNPATH that names a DIFFERENT checkout.
      let patchelf = findExe("patchelf")
      doAssert patchelf.len > 0
      let recipesRoot = scratch / "packages" / "source"
      let mirror = recipesRoot / package / ".repro" / "output" / "install"
      let binDir = mirror / "usr" / "bin"
      createDir(binDir)
      let elfObject = binDir / "sample"
      copyFileWithPermissions(patchelf, elfObject)
      setFilePermissions(elfObject, getFilePermissions(elfObject) +
        {fpUserWrite})
      (recipesRoot, mirror, elfObject)

    const ElsewhereLib =
      "/elsewhere/packages/source/zlib/.repro/output/install/usr/lib"

    test "a restored mirror is relocated and the message names the package":
      let scratch = createTempDir("repro-restore-ok-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "python3")
      require run(findExe("patchelf"),
        @["--set-rpath", ElsewhereLib, staged.elfObject]).exitCode == 0
      let outcome = relocateRestoredInstallMirror(staged.mirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      check outcome.ok
      check "python3" in outcome.message
      check "relocated 1 ELF object" in outcome.message
      check readElfRuntimeFacts(staged.elfObject).runPaths ==
        @[staged.recipesRoot & "/zlib/.repro/output/install/usr/lib"]

    test "a path that is not a mirror root is left alone":
      # A restored prefix that is not an install mirror has no recipes root
      # to be relocated onto, and must not be touched or reported.
      #
      # The prefix EXISTS and really holds an ELF carrying a foreign path.
      # Pointing this case at a directory that was never created made it pass
      # for the wrong reason: the "prefix does not exist" return answered it,
      # so deleting the mirror-shape return entirely stayed green. Measured.
      # With the prefix populated, an empty message can only come from the
      # shape check, because an audit of this tree would name that path.
      let scratch = createTempDir("repro-restore-nonmirror-", "")
      defer: removeDir(scratch)
      let notAMirror = scratch / "outputs" / "out"
      createDir(notAMirror / "usr" / "lib")
      let stranded = notAMirror / "usr" / "lib" / "sample"
      copyFileWithPermissions(findExe("patchelf"), stranded)
      setFilePermissions(stranded, getFilePermissions(stranded) +
        {fpUserWrite})
      require run(findExe("patchelf"),
        @["--set-rpath", ElsewhereLib, stranded]).exitCode == 0
      let outcome = relocateRestoredInstallMirror(notAMirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      check outcome.ok
      check outcome.message.len == 0
      # Untouched, not merely unreported.
      check readElfRuntimeFacts(stranded).runPaths == @[ElsewhereLib]

    test "relocation REFUSES rather than half-repairing when patchelf is absent":
      let scratch = createTempDir("repro-restore-nopatchelf-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "make")
      require run(findExe("patchelf"),
        @["--set-rpath", ElsewhereLib, staged.elfObject]).exitCode == 0
      let outcome = relocateRestoredInstallMirror(staged.mirror, "",
        realPatchelfRunner)
      checkpoint outcome.message
      check not outcome.ok
      check "make" in outcome.message
      check ElsewhereLib in outcome.message
      # Pinned by its OWN wording. Without this line the case is satisfied by
      # a DIFFERENT refusal — handing an empty executable to the runner also
      # fails, also sets ``ok = false``, and also names the package and the
      # path — so deleting the guard that checks for the tool up front stayed
      # green. Measured, not supposed.
      check "was not available" in outcome.message
      check "patchelf failed on " notin outcome.message

    test "a remappable PT_INTERP is rewritten, not only the RUNPATH":
      # The unit fixture copies a host binary whose interpreter already lives
      # in the store, so nothing in the cases above reaches the interpreter
      # arm of the repair at all. Give it one that does.
      let scratch = createTempDir("repro-restore-interp-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "make")
      const foreignLoader = "/elsewhere/packages/source/gcc" &
        "/.repro/output/install/usr/lib/ld-linux-x86-64.so.2"
      require run(findExe("patchelf"),
        @["--set-interpreter", foreignLoader, staged.elfObject]).exitCode == 0
      require readElfRuntimeFacts(staged.elfObject).interpreter ==
        foreignLoader
      let outcome = relocateRestoredInstallMirror(staged.mirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      check outcome.ok
      check readElfRuntimeFacts(staged.elfObject).interpreter ==
        staged.recipesRoot &
          "/gcc/.repro/output/install/usr/lib/ld-linux-x86-64.so.2"

    test "unrepairable paths are named up to the bound and COUNTED past it":
      ## Exercised AT the bound and ABOVE it in the same mirror. A case that
      ## only ever stays under the bound proves the list, not the bound.
      let scratch = createTempDir("repro-restore-bounded-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "qt6base")
      # The bound is pinned by a LITERAL on both sides. Sizing the fixture
      # from ``MaxReportedMirrorPaths`` and then asserting against
      # ``MaxReportedMirrorPaths`` puts the same constant on both sides of
      # every comparison, and the case passes for ANY value of it — measured:
      # changing 5 to 4 left this green before the literals went in.
      check MaxReportedMirrorPaths == 5
      # Producer work trees: absolute, outside every store, and carrying no
      # package-mirror segment, so they are unrepairable whatever else is
      # decided about them.
      var foreign: seq[string]
      for i in 0 ..< 7:
        foreign.add("/elsewhere/packages/source/dep" & $i & "/build/out/lib")
      require run(findExe("patchelf"),
        @["--set-rpath", foreign.join(":"), staged.elfObject]).exitCode == 0
      let outcome = relocateRestoredInstallMirror(staged.mirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      var named = 0
      for entry in foreign:
        if entry in outcome.message: inc named
      check named == 5
      check "and 2 further distinct path(s) not shown" in outcome.message
      # The refusal COUNTS the offending entries rather than announcing a
      # fixed one. Seven here against the one in the case below: a message
      # that printed a constant would satisfy exactly one of the two.
      check not outcome.ok
      check "7 run-path entries" in outcome.message
      # The FIRST path past the bound is withheld, not the whole tail: the
      # bound counts distinct values, so exactly two are missing.
      check foreign[5] notin outcome.message
      check foreign[4] in outcome.message

    test "a patchelf that reports success without rewriting anything is REFUSED":
      ## The dangerous state is not a failed repair, it is a PARTIAL one: a
      ## mirror that runs far enough to look like it works. The re-audit is
      ## what rules it out, so a tool that lies about succeeding must not be
      ## believed.
      let scratch = createTempDir("repro-restore-liar-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "gcc")
      require run(findExe("patchelf"),
        @["--set-rpath", ElsewhereLib, staged.elfObject]).exitCode == 0
      let liar = scratch / "lying-patchelf"
      writeFile(liar, "#!/bin/sh\nexit 0\n")
      setFilePermissions(liar, {fpUserRead, fpUserWrite, fpUserExec})
      let outcome = relocateRestoredInstallMirror(staged.mirror, liar,
        realPatchelfRunner)
      checkpoint outcome.message
      check not outcome.ok
      check "gcc" in outcome.message
      check "after relocation" in outcome.message
      # And the object really is unchanged, so the refusal is about the
      # mirror rather than about the exit code it was handed.
      check readElfRuntimeFacts(staged.elfObject).runPaths == @[ElsewhereLib]

    test "a mirror naming the producer's work tree is REFUSED, and nothing is rewritten first":
      ## The repairable entry beside it is the point. A mirror that cannot
      ## be made whole must not be left half-rewritten on the way to being
      ## discarded: the caller withdraws it, and a rewrite performed first
      ## is work done to an artifact nobody will read, on a tree that in
      ## the restore path is the live one.
      let scratch = createTempDir("repro-restore-worktree-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "sudo")
      const workTree =
        "/elsewhere/packages/source/sudo/build/out/usr/libexec/sudo"
      let before = @[workTree, ElsewhereLib]
      require run(findExe("patchelf"),
        @["--set-rpath", before.join(":"), staged.elfObject]).exitCode == 0
      let outcome = relocateRestoredInstallMirror(staged.mirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      check not outcome.ok
      check "sudo" in outcome.message
      check workTree in outcome.message
      # Pinned by the refusal's OWN wording, because three other refusals
      # in this suite also set ``ok = false`` and also name the package.
      check "cannot be made self-contained" in outcome.message
      check "1 run-path entry" in outcome.message
      # NOT half-repaired: the sibling-mirror entry was rewritable and was
      # deliberately left alone.
      check readElfRuntimeFacts(staged.elfObject).runPaths == before

    test "a target-rootfs run path is reported and the mirror is ACCEPTED":
      ## The discriminator. This path is just as unrewritable as the one
      ## above and just as unresolvable where the mirror stands — the only
      ## difference is that it comes right once the mirror has been staged
      ## into the image it was built for. A refusal that could not tell the
      ## two apart would withdraw a mirror for being correct.
      let scratch = createTempDir("repro-restore-rootfs-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "sudo")
      const rootfsPath = "/usr/libexec/sudo"
      require run(findExe("patchelf"),
        @["--set-rpath", rootfsPath, staged.elfObject]).exitCode == 0
      let outcome = relocateRestoredInstallMirror(staged.mirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      check outcome.ok
      check rootfsPath in outcome.message
      check "cannot be made self-contained" notin outcome.message
      check readElfRuntimeFacts(staged.elfObject).runPaths == @[rootfsPath]

    test "THE CASE: a mirror that SHIPS its library and still cannot reach it":
      ## Reproduces, as a fixture, the shape a real published mirror was
      ## found in. Eleven objects named a library that was not missing at
      ## all — it sat in the very directory they sat in — and they could
      ## not reach it, because the only two places their run paths named
      ## were the target rootfs and the build tree of the machine that
      ## produced them. Neither exists where the mirror was restored.
      ##
      ## So the mirror is complete and unusable at the same time, and the
      ## audit that looks for a missing file finds nothing wrong with it.
      ## What is wrong is decidable from the run paths alone.
      let scratch = createTempDir("repro-restore-ships-", "")
      defer: removeDir(scratch)
      let staged = stageMirror(scratch, "sudo")
      let libDir = staged.mirror / "usr" / "libexec" / "sudo"
      createDir(libDir)
      let consumer = libDir / "sudoers.so"
      let provider = libDir / "libsudo_util.so.0"
      copyFileWithPermissions(findExe("patchelf"), consumer)
      copyFileWithPermissions(findExe("patchelf"), provider)
      for path in [consumer, provider]:
        setFilePermissions(path, getFilePermissions(path) + {fpUserWrite})
      const observedRunPaths = [
        "/usr/libexec/sudo",
        "/elsewhere/packages/source/sudo/build/out/usr/libexec/sudo",
      ]
      require run(findExe("patchelf"), @["--set-rpath",
        observedRunPaths.join(":"), consumer]).exitCode == 0
      require run(findExe("patchelf"),
        @["--add-needed", "libsudo_util.so.0", consumer]).exitCode == 0

      # 1. The library really is shipped, in the consumer's own directory.
      check fileExists(provider)
      check parentDir(provider) == parentDir(consumer)
      # 2. And the consumer really does need it.
      check "libsudo_util.so.0" in readElfRuntimeFacts(consumer).needed
      # 3. And still cannot reach it: resolved against the object's own run
      #    paths — the only directories a loader will look in here — there
      #    is no candidate. Decided against the fixture rather than quoted.
      var reachable = 0
      for entry in readElfRuntimeFacts(consumer).runPaths:
        if fileExists(entry / "libsudo_util.so.0"): inc reachable
      check reachable == 0
      # 4. Which is what the refusal is for.
      let outcome = relocateRestoredInstallMirror(staged.mirror,
        findExe("patchelf"), realPatchelfRunner)
      checkpoint outcome.message
      check not outcome.ok
      check observedRunPaths[1] in outcome.message
      check "cannot be made self-contained" in outcome.message
      # 5. The target-rootfs entry beside it is NOT what decided this: it
      #    is reported, and on its own it would have been accepted — the
      #    case above proves that half separately.
      check observedRunPaths[0] in outcome.message

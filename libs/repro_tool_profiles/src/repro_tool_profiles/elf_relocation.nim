## Relocating a dynamically linked toolchain archive onto the loader and C
## library realized with it.
##
## Dependency-Provisioning-In-Build-Graph.md §4.2, "Relocating a dynamically
## linked archive", and Caching-Architecture.md §"Design for XPC-AREQ1" D3.
##
## A prebuilt glibc toolchain asks the kernel for the host's loader
## (``PT_INTERP`` = ``/lib64/ld-linux-x86-64.so.2``) and the host's C library.
## NixOS has neither, and a toolchain that ran against the host's would read
## files outside every logical root of the portable identity. The archive
## carries its own glibc in its sysroot, so realization points each of its
## host programs at THAT loader and adds THAT library directory to each ELF
## file's ``DT_RPATH``, using the absolute paths the prefix will have in the
## store. The rewrite is a step of the realization: it runs on the staging
## copy before the prefix is sealed, it is a pure function of the archive,
## the declaration and the prefix path (all three in the prefix's key), and
## it is done by the stdlib ``patchelf`` package, which a provisioning edge
## realizes and hands to the realizer like an extractor
## (https://github.com/NixOS/patchelf).
##
## ``DT_RPATH`` rather than ``DT_RUNPATH`` on purpose: the loader consults a
## program's ``DT_RPATH`` for the dependencies of every object it loads,
## including an ``LD_PRELOAD``ed monitor shim that carries no search path of
## its own; ``DT_RUNPATH`` applies only to the object's direct dependencies
## (ld.so(8), "Rpath token expansion" and the search order under
## "DESCRIPTION": https://man7.org/linux/man-pages/man8/ld.so.8.html).

import std/[algorithm, os, sets, strutils]

from repro_project_dsl import TarballArchiveDetail
import repro_project_dsl/install_mirror_relocation

type
  ElfRelocationError* = object of OSError
    ## A declared relocation that cannot be carried out: a declared path
    ## missing from the archive, an ELF file the reader cannot decode, or
    ## ``patchelf`` failing. The realization fails; nothing is sealed.

proc relocationFail(message: string) {.noreturn.} =
  raise newException(ElfRelocationError,
    "tool-resolution failed: ELF relocation: " & message)

type
  ElfToolRunner* = proc(argv: seq[string]): tuple[output: string;
      exitCode: int] {.closure.}
    ## Runs ``argv`` (``argv[0]`` an absolute path: the provisioned
    ## ``patchelf`` from its receipt, or the staged driver) and returns its
    ## merged output and exit code. Supplied by the caller, as
    ## ``install_mirror_relocation`` takes its ``MirrorPatchRunner``: this
    ## module decides WHAT runs, the realizer owns HOW a process is started
    ## (``repro_tool_profiles`` uses ``execCmdExCloseOnce``, whose child
    ## release is safe on the engine's scheduler thread).

proc absoluteInPrefix(prefix, relative: string): string =
  os.normalizedPath(prefix / relative)

proc relocationTargets*(detail: TarballArchiveDetail; finalPrefix: string):
    tuple[interpreter: string; runpath: seq[string]] =
  ## The ``PT_INTERP`` and the ``DT_RPATH`` entries a relocated file is
  ## given: the declared paths, absolute in the prefix as it will be sealed.
  if detail.elfInterpreter.len > 0:
    result.interpreter = absoluteInPrefix(finalPrefix, detail.elfInterpreter)
  for entry in detail.elfRunpath:
    let dir = absoluteInPrefix(finalPrefix, entry)
    if dir notin result.runpath:
      result.runpath.add(dir)

proc relocatedRunpath*(existing, added: openArray[string]): seq[string] =
  ## The file's own entries first (its ``$ORIGIN/../lib`` finds the
  ## toolchain's private ``libgmp`` / ``libmpfr``), then ``added``. An
  ## entry already in ``added`` is not repeated, so applying the rewrite
  ## twice (a file reached through two hard links) changes nothing.
  for entry in existing:
    if entry notin added and entry notin result:
      result.add(entry)
  for entry in added:
    if entry notin result:
      result.add(entry)

proc relocateElfTree*(detail: TarballArchiveDetail;
                      stagingPrefix, finalPrefix, patchelf: string;
                      runTool: ElfToolRunner): int =
  ## Rewrite every dynamically linked ELF file under ``detail.elfPatchDirs``
  ## of ``stagingPrefix``: ``PT_INTERP`` (programs that have one) to the
  ## declared loader, ``DT_RPATH`` to the file's own entries plus the
  ## declared run path, both as absolute paths under ``finalPrefix``.
  ## Returns how many files were rewritten.
  ##
  ## Only regular files are visited; symbolic links are left alone (their
  ## targets are visited where they live) and a file reached through two
  ## hard links is rewritten once. Statically linked files and relocatable
  ## objects (``.o``, no dynamic section) are not touched. Directories are
  ## walked in sorted order so a failure names the same file on every host.
  let declares = detail.elfInterpreter.len > 0 or detail.elfRunpath.len > 0
  if not declares:
    return 0
  if detail.elfPatchDirs.len == 0:
    relocationFail("elfInterpreter / elfRunpath are declared but no " &
      "elfPatchDir says which directories to rewrite")
  if patchelf.len == 0 or not fileExists(patchelf):
    relocationFail("no patchelf was provisioned for this realization " &
      "(the archive declares an ELF relocation, which needs the " &
      "patchelf dependency edge)")
  let targets = relocationTargets(detail, finalPrefix)
  if detail.elfInterpreter.len > 0 and
      not fileExists(stagingPrefix / detail.elfInterpreter):
    relocationFail("elfInterpreter " & detail.elfInterpreter &
      " is not a file in the archive")
  for entry in detail.elfRunpath:
    if not dirExists(stagingPrefix / entry):
      relocationFail("elfRunpath " & entry &
        " is not a directory in the archive")
  var seen = initHashSet[(uint64, uint64)]()
  for dirEntry in detail.elfPatchDirs:
    let root = stagingPrefix / dirEntry
    if not dirExists(root):
      relocationFail("elfPatchDir " & dirEntry &
        " is not a directory in the archive")
    var files: seq[string]
    for path in walkDirRec(root, yieldFilter = {pcFile},
        followFilter = {pcDir}):
      files.add(path)
    files.sort()
    for path in files:
      let info = getFileInfo(path, followSymlink = false)
      let identity = (uint64(info.id.device), uint64(info.id.file))
      if identity in seen:
        continue
      seen.incl(identity)
      let facts = readElfRuntimeFacts(path)
      if not facts.isElf:
        continue
      if not facts.parsed:
        relocationFail("cannot read the ELF file " &
          relativePath(path, stagingPrefix) & ": " & facts.unsupported)
      # Dynamically linked: it asks for a loader or names a library. A
      # static program, an object file and a loader itself have neither.
      if facts.interpreter.len == 0 and facts.needed.len == 0:
        continue
      var argv = @[patchelf]
      if facts.interpreter.len > 0 and targets.interpreter.len > 0 and
          facts.interpreter != targets.interpreter:
        argv.add(["--set-interpreter", targets.interpreter])
      let runpath = relocatedRunpath(facts.runPaths, targets.runpath)
      if targets.runpath.len > 0 and runpath != facts.runPaths:
        argv.add(["--force-rpath", "--set-rpath", runpath.join(":")])
      if argv.len == 1:
        continue
      argv.add(path)
      # Archives ship programs read-only (r-x); patchelf rewrites in place.
      let mode = getFilePermissions(path)
      setFilePermissions(path, mode + {fpUserWrite, fpUserRead})
      let outcome = runTool(argv)
      setFilePermissions(path, mode)
      if outcome.exitCode != 0:
        relocationFail("patchelf failed on " &
          relativePath(path, stagingPrefix) & " (exit " & $outcome.exitCode &
          "): " & outcome.output.strip())
      inc result

proc appendToSpec(lines: var seq[string]; name, text: string) =
  ## Append `text` to the value of spec `name` in `lines` (a ``-dumpspecs``
  ## dump: a ``*name:`` line, then the value on the next line, which is
  ## empty for an empty spec). A spec the dump does not have fails the
  ## realization: appending to a spec the driver never reads would drop the
  ## declared defaults without a word.
  for i, line in lines:
    if line.strip() == "*" & name & ":":
      if i + 1 >= lines.len:
        break
      lines[i + 1] =
        if lines[i + 1].strip().len == 0: text.strip()
        else: lines[i + 1] & " " & text.strip()
      return
  relocationFail("the driver's -dumpspecs output has no *" & name &
    ": spec")

proc parseSpecDefault*(entry: string): tuple[name, text: string] =
  ## Split a ``gccSpecDefault`` entry, ``<spec>:<text>``.
  let at = entry.find(':')
  if at <= 0 or entry[0 ..< at].strip().len == 0:
    relocationFail("gccSpecDefault " & entry.escape() &
      " is not `<spec>:<text>`")
  (entry[0 ..< at].strip(), entry[at + 1 .. ^1])

proc gccLinkSpecsText*(dumped, interpreter: string;
                       runpath: openArray[string];
                       specDefaults: openArray[string] = []): string =
  ## ``dumped`` (the output of ``gcc -dumpspecs``) with the ``*link:`` spec
  ## extended so a dynamically linked executable asks for ``interpreter`` and
  ## searches ``runpath``. Appended after the driver's own link spec, whose
  ## ``-dynamic-linker`` it overrides (ld takes the last one); a
  ## ``-Wl,--dynamic-linker`` or ``-Wl,-rpath`` the user passes comes later
  ## on the link line still and wins. ``-shared``, ``-static`` and
  ## ``-static-pie`` links are left as the driver makes them.
  ##
  ## Then each ``specDefaults`` entry (``<spec>:<text>``, the arm's
  ## ``gccSpecDefaults``), in declaration order, is appended to its spec:
  ## the defaults a vendor's driver wrapper would have added.
  ## https://gcc.gnu.org/onlinedocs/gcc/Spec-Files.html
  var lines = dumped.splitLines()
  var extra = ""
  if interpreter.len > 0:
    extra.add(" %{!shared:%{!static:%{!static-pie:-dynamic-linker " &
      interpreter & "}}}")
  if runpath.len > 0:
    var rpaths = ""
    for dir in runpath:
      rpaths.add(" -rpath " & dir)
    extra.add(" %{!static:%{!static-pie:" & rpaths.strip() & "}}")
  var hasLink = false
  for i, line in lines:
    if line.strip() == "*link:" and i + 1 < lines.len:
      hasLink = true
      break
  if not hasLink:
    relocationFail("the driver's -dumpspecs output has no *link: spec")
  if extra.len > 0:
    appendToSpec(lines, "link", extra)
  for entry in specDefaults:
    let parsed = parseSpecDefault(entry)
    appendToSpec(lines, parsed.name, parsed.text)
  result = lines.join("\n")
  if not result.endsWith("\n"):
    result.add("\n")

proc writeGccLinkSpecs*(detail: TarballArchiveDetail;
                        declaredExecutablePath, stagingPrefix,
                        finalPrefix: string; runTool: ElfToolRunner) =
  ## Write ``detail.gccLinkSpecs``: the realized driver's own specs with the
  ## link defaults of ``gccLinkSpecsText`` and the declared
  ## ``gccSpecDefaults``. The driver finds a ``specs`` file
  ## in its ``lib/gcc/<triple>/<version>`` directory and reads it INSTEAD of
  ## its built-in specs, which is why the whole dump is written and not just
  ## the changed spec.
  ##
  ## The driver runs from the staging prefix, where its rewritten
  ## ``PT_INTERP`` (the sealed prefix's loader) does not exist yet, so it is
  ## started through the staged loader with the staged run path. Its output
  ## depends on the driver binary only.
  if detail.gccLinkSpecs.len == 0:
    if detail.gccSpecDefaults.len > 0:
      relocationFail("gccSpecDefault needs gccLinkSpecs: the defaults are " &
        "written into that specs file")
    return
  if detail.elfInterpreter.len == 0:
    relocationFail("gccLinkSpecs needs elfInterpreter: the specs name the " &
      "loader linked executables ask for")
  let target = stagingPrefix / detail.gccLinkSpecs
  if fileExists(target):
    relocationFail("gccLinkSpecs " & detail.gccLinkSpecs &
      " already exists in the archive; it is not overwritten")
  let loader = stagingPrefix / detail.elfInterpreter
  var libraryPath: seq[string]
  for entry in detail.elfRunpath:
    libraryPath.add(stagingPrefix / entry)
  let outcome = runTool(@[loader, "--library-path", libraryPath.join(":"),
    stagingPrefix / declaredExecutablePath, "-dumpspecs"])
  if outcome.exitCode != 0:
    relocationFail(declaredExecutablePath & " -dumpspecs failed (exit " &
      $outcome.exitCode & "): " & outcome.output.strip())
  let targets = relocationTargets(detail, finalPrefix)
  createDir(target.parentDir)
  writeFile(target, gccLinkSpecsText(outcome.output, targets.interpreter,
    targets.runpath, detail.gccSpecDefaults))

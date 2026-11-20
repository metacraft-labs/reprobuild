## Where a Layer-1 constructor writes a shared library, and under which
## SONAME -- one rule for every constructor that produces one
## (``c_library``, ``nim_library``).
##
## A consumer's ``DT_NEEDED`` is the library's SONAME, and the dynamic loader
## opens a file of exactly that name. So on an ELF target the library is
## written as ``lib/<SONAME>`` (``sharedLibrarySoname``: ``lib<soname>.so``
## plus ``.<sover>``), carries that string as its SONAME, and, when the
## SONAME is versioned, ``lib/lib<soname>.so`` is a link-time symlink to it
## (C-Cpp.md §"Mode A — Fine-grained build graph (primary)";
## From-Source-Build-Recipes.md, the ``api:`` block's ``sover`` field). A
## Mach-O or PE target has no SONAME: the file is the link-time name.
##
## The file goes under ``lib/`` so a target build keys the DIRECTORY
## (``lib@<triple>/``, ``targetKeyedPath``) and the file keeps the name its
## SONAME gives it.

import std/os

import repro_project_dsl

import ../types/library
import ../active_context
import ../adapters/native_cross_target

type
  SharedLibraryLayout* = object
    linkTimeFile*: string
      ## ``lib<base>.so``: the name ``-l<base>`` finds at link time.
    soname*: string
      ## The full SONAME to bake in, or ``""`` on a non-ELF target.
    target*: string
      ## The file the link writes, relative and not yet target-keyed:
      ## ``lib/<soname>``, or ``lib/<linkTimeFile>`` without a SONAME.

proc targetIsElf*(): bool =
  ## Whether the library being linked is an ELF object, the only format
  ## with a ``DT_SONAME``: the active target's format (the host's for a
  ## native build). Read with ``peekActiveCrossTarget`` so asking does not
  ## lift a constructor's fail-closed guard for an unthreaded target.
  var ct = peekActiveCrossTarget()
  if ct == nil:
    ct = nativeCrossTarget()
  ct.binaryFormat == bfELF

proc targetTakesPic*(): bool =
  ## Whether the active target's objects are compiled with ``-fPIC``: every
  ## target but PE. PE has no position-independent code model, and clang
  ## refuses the flag for an MSVC target ("unsupported option '-fPIC' for
  ## target 'x86_64-pc-windows-msvc'"). Read as ``targetIsElf`` reads it.
  var ct = peekActiveCrossTarget()
  if ct == nil:
    ct = nativeCrossTarget()
  ct.binaryFormat != bfPE

proc sharedLibraryLayout*(api: LibraryApi; into: string): SharedLibraryLayout =
  ## The layout of the shared library declared as ``library <into>:`` with
  ## ``api``. The base name is ``api.soname``, else ``into``.
  let baseName = if api.soname.len > 0: api.soname else: into
  result.linkTimeFile = "lib" & baseName & ".so"
  result.soname =
    if targetIsElf(): sharedLibrarySoname(baseName, api.sover) else: ""
  result.target =
    if result.soname.len > 0: "lib" / result.soname
    else: "lib" / result.linkTimeFile

proc actionIdPart*(value: string): string =
  ## ``value`` reduced to the characters an action id may carry.
  for ch in value:
    result.add(if ch in {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}: ch
               else: '_')

proc linkTimeNameAction*(idPrefix, pkg: string;
                         layout: SharedLibraryLayout;
                         libEdge: BuildActionDef;
                         libPath: string): BuildActionDef =
  ## The edge that writes ``lib<base>.so`` beside ``libPath`` (the file
  ## ``libEdge`` writes, named by the SONAME) as a relative symlink to it,
  ## so ``-l<base>`` still resolves. Default (empty ``id``) when there is no
  ## second name to write: no SONAME, or the SONAME already is the
  ## link-time name.
  if layout.soname.len == 0 or layout.soname == layout.linkTimeFile or
      libPath.len == 0:
    return
  let libDir = libPath.parentDir
  let linkPath =
    if libDir.len > 0: libDir / layout.linkTimeFile else: layout.linkTimeFile
  buildAction(
    id = idPrefix & actionIdPart(pkg) & "-" & actionIdPart(linkPath),
    # Relative target: the symlink resolves inside its own directory,
    # wherever the tree is mirrored or installed.
    call = inlineExecCall(@["ln", "-sfn", layout.soname, linkPath]),
    deps = [libEdge.id],
    inputs = [libPath],
    outputs = [linkPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    publishToBinaryCache = true,
    toolIdentityRefs = ["ln"])

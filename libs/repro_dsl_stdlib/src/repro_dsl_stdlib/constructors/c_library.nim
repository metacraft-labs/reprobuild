## DSL-port M9.R.2b — Layer-1 ``c_library`` constructor.
##
## High-level constructor for a C / C++ library. Drives Layer-2
## ``compile`` (one per source) + ``link(kind = lkShared)`` and
## returns a typed ``Library`` value.
##
## Auto-lift: the constructor takes an explicit ``into = "<n>"``
## parameter naming the surrounding ``library <name>:`` declaration so
## the constructor can read the ``api:`` block via
## ``registeredLibraryApi``. The v2 macro refinement will hoist the
## name implicitly from the assignment LHS; v1 keeps it explicit for
## simplicity (see the milestone body for the rationale).
##
## Convention:
##
## .. code-block:: nim
##   library libfoo:
##     api:
##       soname "foo"
##       sover "1.0"
##       linkKind shared
##
##   build:
##     let libfoo = c_library(into = "libfoo",
##                            sources = @["src/foo.c"])
##
## On an ELF target that writes ``lib/libfoo.so.1.0``, whose
## ``DT_SONAME`` is ``libfoo.so.1.0``, and the link-time symlink
## ``lib/libfoo.so -> libfoo.so.1.0`` (C-Cpp.md §"Mode A — Fine-grained
## build graph (primary)"). A consumer linked with ``-lfoo`` records
## ``DT_NEEDED libfoo.so.1.0`` -- a file that exists.

import std/os

import repro_project_dsl

import ../types/library
import ../types/options
import ../operations/compile
import ../operations/link
import ../active_context
import ../adapters/native_cross_target

proc activePackageName(): string {.inline.} =
  ## v1 helper — return the active ``package`` block's name, or ``""``
  ## when called outside any active build block. The empty fallback
  ## keeps the constructor usable under unit-test harnesses that
  ## haven't pushed a build frame.
  let st = tryCurrentBuildState()
  if st == nil: "" else: st.packageName

proc targetIsElf(): bool =
  ## Whether the library being linked is an ELF object, the only format
  ## with a ``DT_SONAME``: the active target's format (the host's for a
  ## native build). Read with ``peekActiveCrossTarget`` so asking does not
  ## lift ``link``'s fail-closed guard for an unthreaded target.
  var ct = peekActiveCrossTarget()
  if ct == nil:
    ct = nativeCrossTarget()
  ct.binaryFormat == bfELF

proc actionIdPart(value: string): string =
  ## ``value`` reduced to the characters an action id may carry.
  for ch in value:
    result.add(if ch in {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}: ch
               else: '_')

proc c_library*(into: string;
                sources: seq[string];
                deps: seq[Library] = @[];
                extraDefines: seq[string] = @[];
                standard = "c11"): Library =
  ## Build a C library from ``sources``. The constructor:
  ##
  ##   1. Reads ``registeredLibraryApi(activePkg, into)`` to recover
  ##      the surrounding ``library <into>: api: ...`` declaration's
  ##      typed metadata (``soname`` / ``sover`` / ``linkKind`` /
  ##      ``headers`` / ``links`` / ``defines`` / ``compileOptions``).
  ##   2. Emits one ``compile(...)`` call per source, threading the
  ##      input library APIs from ``deps`` through ``inputs`` so each
  ##      compile sees the right ``-I`` / ``-D`` contributions.
  ##   3. Emits one ``link(...)`` call combining the resulting object
  ##      list with the link-time deps + auto-lifted ``soname``.
  ##
  ## The ``into`` parameter is the artifact name the surrounding
  ## ``library`` declaration uses; the v1 explicit form is documented
  ## in the milestone body — a follow-up will infer it from the
  ## assignment LHS via a wrapper macro.
  let pkg = activePackageName()
  let api = registeredLibraryApi(pkg, into)

  var objects: seq[BuildActionDef] = @[]
  for src in sources:
    let target = src & ".o"
    let inputs =
      block:
        var seq2: seq[LibraryApi] = @[]
        for d in deps:
          if d.api.declared: seq2.add(d.api)
        # Carry this library's own PRIVATE / PUBLIC header set into
        # the compile so the source can ``#include`` its own headers
        # via the same search paths consumers see.
        if api.declared: seq2.add(api)
        seq2
    objects.add(compile(
      source = src,
      target = target,
      inputs = inputs,
      defines = extraDefines,
      standard = standard))

  let linkKind =
    case api.linkKind
    of llkStatic: lokStatic
    of llkShared, llkBoth, llkUnset: lokShared
  # One name drives the file, ``-Wl,-soname,`` and the declared output,
  # so they cannot disagree: a consumer's ``DT_NEEDED`` is the SONAME,
  # and the loader opens a file of exactly that name.
  let baseName = if api.soname.len > 0: api.soname else: into
  let linkTimeFile = "lib" & baseName & ".so"
  let soname =
    if linkKind == lokShared and targetIsElf():
      sharedLibrarySoname(baseName, api.sover)
    else: ""
  # Under ``lib/``: a target build keys the FIRST path component
  # (``targetKeyedPath``), so the directory becomes ``lib@<triple>/``
  # and the file keeps the name the SONAME gives it.
  let targetName =
    if linkKind == lokStatic: "lib" / ("lib" & baseName & ".a")
    elif soname.len > 0: "lib" / soname
    else: "lib" / linkTimeFile
  let linkEdge = link(LinkOptions(
    objects: objects,
    deps: deps,
    kind: linkKind,
    target: targetName,
    soname: soname))

  result = newLibrary(install = linkEdge, api = api,
                      installPrefix = "usr/lib")

  # A versioned SONAME is not the name ``-l<base>`` looks for, so write
  # ``lib<base>.so`` beside it as a symlink to it, as the link-time name
  # (C-Cpp.md §"Mode A"). Both are declared outputs.
  if soname.len > 0 and soname != linkTimeFile and
      linkEdge.outputs.len > 0:
    let libDir = linkEdge.outputs[0].parentDir
    let linkPath = if libDir.len > 0: libDir / linkTimeFile else: linkTimeFile
    result.linkTimeName = buildAction(
      id = "c-library-link-time-name-" & actionIdPart(pkg) & "-" &
        actionIdPart(linkPath),
      # Relative target: the symlink resolves inside its own directory,
      # wherever the tree is mirrored or installed.
      call = inlineExecCall(@["ln", "-sfn", soname, linkPath]),
      deps = [linkEdge.id],
      inputs = [linkEdge.outputs[0]],
      outputs = [linkPath],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      publishToBinaryCache = true,
      toolIdentityRefs = ["ln"])

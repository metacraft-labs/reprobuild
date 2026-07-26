## Typed-Extension-Interfaces M4a — the ENGINE side of the C-ABI library
## transport (§6): ``dlopen`` a provider ``.so``, bind the fixed cdecl
## entry-point symbols (``library_abi.nim``), and drive the resource-reconcile
## leaf ops (``digest`` / ``observe`` / ``apply``) as direct in-process calls —
## NO process spawn, NO socket, NO framing.
##
## The bound library is exposed as a ``LoadedResourceProviderLibrary`` handle
## whose ``=destroy`` closes the provider handle and unloads the ``.so`` (RAII,
## §6.4). Each op encodes its inputs with ``protocol.nim``'s ``encode*``
## helpers (the SAME non-SSZ codec the registry uses), passes the buffer across
## as a raw ``(ptr,len)``, and decodes the OWNED result buffer the callee
## returns — releasing it through the callee-EXPORTED ``repro_buffer_free``,
## never the engine's own ``free`` (§6.2).

import std/[options, dynlib]

from repro_home_generations/pointer import Digest256
from repro_home_resources/types import ObservedState, ResourceActionKind
import repro_resources/instance
import repro_resources/library_abi
import repro_resources/protocol

type
  # Bound cdecl signatures — must match the ``{.exportc, cdecl.}`` producers
  # in ``library_abi.nim`` exactly.
  OpenFn = proc (abiVersion: uint32;
                 outHandle: ptr ReproProviderHandle): ReproStatus {.cdecl.}
  CloseFn = proc (handle: ReproProviderHandle) {.cdecl.}
  BufferFreeFn = proc (buf: ptr ReproBuffer) {.cdecl.}
  DigestFn = proc (handle: ReproProviderHandle;
                   instData: pointer; instLen: csize_t;
                   outBuf: ptr ReproBuffer): ReproStatus {.cdecl.}
  ObserveFn = proc (handle: ReproProviderHandle;
                    instData: pointer; instLen: csize_t;
                    priorData: pointer; priorLen: csize_t;
                    outBuf: ptr ReproBuffer): ReproStatus {.cdecl.}
  ApplyFn = proc (handle: ReproProviderHandle;
                  instData: pointer; instLen: csize_t;
                  observedData: pointer; observedLen: csize_t;
                  actionKind: uint32;
                  outBuf: ptr ReproBuffer): ReproStatus {.cdecl.}
  CallCountFn = proc (handle: ReproProviderHandle): cint {.cdecl.}
  MarshalCountFn = proc (handle: ReproProviderHandle): cint {.cdecl.}
  LastErrorFn = proc (handle: ReproProviderHandle): cstring {.cdecl.}

  # M4c — the nimRtl direct (no-marshal) signatures. These pass LIVE Nim typed
  # values, so they are sound ONLY when host + library share one nimRtl runtime
  # (§4.4). Bound only when ``SymRtlProbe`` is present (a nimRtl-shared build).
  RtlProbeFn = proc (): cint {.cdecl.}
  RtlDigestFn = proc (handle: ReproProviderHandle;
                      inst: ResourceInstance): Digest256 {.cdecl.}
  RtlObserveFn = proc (handle: ReproProviderHandle;
                       inst: ResourceInstance;
                       prior: Option[ResourceBinding]): ObservedState {.cdecl.}
  RtlApplyFn = proc (handle: ReproProviderHandle;
                     inst: ResourceInstance;
                     action: ResourceActionKind;
                     observed: ObservedState): ResourceBinding {.cdecl.}

  ResourceProviderLibraryObj = object
    lib: LibHandle
    handle: ReproProviderHandle
    openFn: OpenFn
    closeFn: CloseFn
    bufferFree: BufferFreeFn
    digestFn: DigestFn
    observeFn: ObserveFn
    applyFn: ApplyFn
    callCountFn: CallCountFn
    marshalCountFn: MarshalCountFn
    lastErrorFn: LastErrorFn
    # nimRtl fast-path binding — non-nil ⇔ the library is a nimRtl-shared build
    # (``SymRtlProbe`` present) AND this host is nimRtl-shared too.
    rtlShared: bool
    rtlDigestFn: RtlDigestFn
    rtlObserveFn: RtlObserveFn
    rtlApplyFn: RtlApplyFn

  LoadedResourceProviderLibrary* = ref ResourceProviderLibraryObj
    ## Scope-bound handle over a loaded provider ``.so``. ``=destroy`` closes
    ## the provider handle (callee-exported close) and unloads the library, so
    ## a leaked ``dlopen`` / provider handle is hard to write (§6.4).

proc `=destroy`*(o: var ResourceProviderLibraryObj) =
  if o.handle != nil and o.closeFn != nil:
    o.closeFn(o.handle)
    o.handle = nil
  if o.lib != nil:
    unloadLib(o.lib)
    o.lib = nil

proc bindSym[T](lib: LibHandle; name: string): T =
  let p = symAddr(lib, name)
  if p == nil:
    raise newException(LibraryError,
      "provider library missing required C-ABI symbol '" & name & "'")
  cast[T](p)

proc loadResourceProviderLibrary*(path: string): LoadedResourceProviderLibrary =
  ## ``dlopen`` a provider library, bind the fixed cdecl entry points, and open
  ## a provider handle over the ABI. A missing symbol or an ABI-version /
  ## open failure is a hard, diagnosable error (never a silent fallthrough).
  let lib = loadLib(path)
  if lib == nil:
    raise newException(LibraryError,
      "could not dlopen provider library: " & path)
  result = LoadedResourceProviderLibrary(lib: lib)
  result.openFn = bindSym[OpenFn](lib, SymOpen)
  result.closeFn = bindSym[CloseFn](lib, SymClose)
  result.bufferFree = bindSym[BufferFreeFn](lib, SymBufferFree)
  result.digestFn = bindSym[DigestFn](lib, SymDigest)
  result.observeFn = bindSym[ObserveFn](lib, SymObserve)
  result.applyFn = bindSym[ApplyFn](lib, SymApply)
  # The witness accessor is optional (only real providers must ship it in
  # M4a's test; keep the binding tolerant so a minimal provider still loads).
  let cc = symAddr(lib, SymCallCount)
  if cc != nil:
    result.callCountFn = cast[CallCountFn](cc)
  let mc = symAddr(lib, SymRtlMarshalCount)
  if mc != nil:
    result.marshalCountFn = cast[MarshalCountFn](mc)
  let le = symAddr(lib, SymLastError)
  if le != nil:
    result.lastErrorFn = cast[LastErrorFn](le)
  # M4c — bind the nimRtl direct fast path ONLY when BOTH sides are
  # nimRtl-shared: the library advertises the mode via ``SymRtlProbe`` (only a
  # ``-d:reproNimRtlShared`` build exports it) AND this host was itself compiled
  # ``-d:reproNimRtlShared`` (so it shares the one nimRtl runtime, §4.4). If
  # either side is standalone, the direct symbols stay unbound and every op
  # falls back to the C-ABI buffer path — the two are distinct build artifacts
  # with distinct action keys.
  when defined(reproNimRtlShared):
    let probe = symAddr(lib, SymRtlProbe)
    if probe != nil and cast[RtlProbeFn](probe)() == 1:
      result.rtlShared = true
      result.rtlDigestFn = bindSym[RtlDigestFn](lib, SymRtlDigest)
      result.rtlObserveFn = bindSym[RtlObserveFn](lib, SymRtlObserve)
      result.rtlApplyFn = bindSym[RtlApplyFn](lib, SymRtlApply)
  var h: ReproProviderHandle
  let st = result.openFn(ReproAbiVersion, addr h)
  if st != reproOk:
    raise newException(LibraryError,
      "provider library open failed with status " & $st)
  result.handle = h

proc callCount*(lib: LoadedResourceProviderLibrary): int =
  ## The provider's in-process op counter (the no-spawn witness). ``-1`` when
  ## the library does not expose the accessor.
  if lib.callCountFn == nil: -1
  else: int(lib.callCountFn(lib.handle))

proc marshalCount*(lib: LoadedResourceProviderLibrary): int =
  ## The provider's C-ABI ``encode*``/``decode*`` marshal counter (M4c
  ## no-marshal witness). A direct nimRtl op leaves this UNCHANGED while
  ## ``callCount`` increments. ``-1`` when the accessor is absent.
  if lib.marshalCountFn == nil: -1
  else: int(lib.marshalCountFn(lib.handle))

proc usesNimRtl*(lib: LoadedResourceProviderLibrary): bool =
  ## True when this loaded library takes the nimRtl direct (no-marshal) path:
  ## both the library and this host were built ``-d:reproNimRtlShared`` against
  ## one shared ``nimrtl`` (§4.4). False ⇒ the portable C-ABI buffer path.
  lib.rtlShared

proc bufPtr(b: seq[byte]): pointer =
  if b.len == 0: nil else: unsafeAddr b[0]

proc takeBuffer(lib: LoadedResourceProviderLibrary;
                buf: var ReproBuffer): seq[byte] =
  ## Copy an OWNED result buffer into a Nim ``seq`` and release the original
  ## through the callee-exported free (§6.2) — the copy is engine-heap-owned.
  let n = int(buf.len)
  result = newSeq[byte](n)
  if n > 0 and buf.data != nil:
    copyMem(addr result[0], buf.data, n)
  lib.bufferFree(addr buf)

proc raiseStatus(lib: LoadedResourceProviderLibrary; op: string;
                 st: ReproStatus) =
  var detail = ""
  if lib.lastErrorFn != nil:
    let c = lib.lastErrorFn(lib.handle)
    if c != nil: detail = $c
  raise newException(ValueError,
    "resource op '" & op & "' failed over the C-ABI library transport: " & $st &
    (if detail.len > 0: " (" & detail & ")" else: ""))

# --------------------------------------------------------------------------
# M4c — the nimRtl DIRECT (no-marshal) ops. Call the ``*_direct`` cdecl entries
# with LIVE Nim typed values: NO ``encode*``, NO ``(ptr,len)`` buffer, NO
# ``repro_buffer_free`` — the shared nimRtl GC owns every value. Reached only
# when ``lib.usesNimRtl`` (both sides ``-d:reproNimRtlShared`` against one
# ``nimrtl``). The ``*ViaLibrary`` ops below prefer this path when available and
# transparently fall back to the C-ABI buffer path otherwise.
# --------------------------------------------------------------------------

proc digestViaLibraryDirect*(lib: LoadedResourceProviderLibrary;
                             inst: ResourceInstance): Digest256 =
  lib.rtlDigestFn(lib.handle, inst)

proc observeViaLibraryDirect*(lib: LoadedResourceProviderLibrary;
                              inst: ResourceInstance;
                              prior: Option[ResourceBinding]): ObservedState =
  lib.rtlObserveFn(lib.handle, inst, prior)

proc applyViaLibraryDirect*(lib: LoadedResourceProviderLibrary;
                            inst: ResourceInstance;
                            action: ResourceActionKind;
                            observed: ObservedState): ResourceBinding =
  lib.rtlApplyFn(lib.handle, inst, action, observed)

proc digestViaLibrary*(lib: LoadedResourceProviderLibrary;
                       inst: ResourceInstance): Digest256 =
  ## Run ``<typeId>.digest`` over the library ABI. Prefers the nimRtl direct
  ## (no-marshal) path when both sides are nimRtl-shared, else the C-ABI buffer.
  if lib.rtlShared:
    return digestViaLibraryDirect(lib, inst)
  let instBytes = encodeResourceInstance(inst)
  var outBuf: ReproBuffer
  let st = lib.digestFn(lib.handle, bufPtr(instBytes), csize_t(instBytes.len),
    addr outBuf)
  if st != reproOk: raiseStatus(lib, "digest", st)
  decodeObservedState(takeBuffer(lib, outBuf)).digest

proc observeViaLibrary*(lib: LoadedResourceProviderLibrary;
                        inst: ResourceInstance;
                        prior: Option[ResourceBinding]): ObservedState =
  ## Run ``<typeId>.observe`` over the library ABI (nimRtl direct when shared).
  if lib.rtlShared:
    return observeViaLibraryDirect(lib, inst, prior)
  let instBytes = encodeResourceInstance(inst)
  var priorBytes: seq[byte] = @[]
  if prior.isSome:
    priorBytes = encodeResourceBinding(prior.get)
  var outBuf: ReproBuffer
  let st = lib.observeFn(lib.handle, bufPtr(instBytes), csize_t(instBytes.len),
    bufPtr(priorBytes), csize_t(priorBytes.len), addr outBuf)
  if st != reproOk: raiseStatus(lib, "observe", st)
  decodeObservedState(takeBuffer(lib, outBuf))

proc applyViaLibrary*(lib: LoadedResourceProviderLibrary;
                      inst: ResourceInstance;
                      action: ResourceActionKind;
                      observed: ObservedState): ResourceBinding =
  ## Run ``<typeId>.apply`` over the library ABI (nimRtl direct when shared).
  if lib.rtlShared:
    return applyViaLibraryDirect(lib, inst, action, observed)
  let instBytes = encodeResourceInstance(inst)
  let obsBytes = encodeObservedState(observed)
  var outBuf: ReproBuffer
  let st = lib.applyFn(lib.handle, bufPtr(instBytes), csize_t(instBytes.len),
    bufPtr(obsBytes), csize_t(obsBytes.len), uint32(ord(action)), addr outBuf)
  if st != reproOk: raiseStatus(lib, "apply", st)
  decodeResourceBinding(takeBuffer(lib, outBuf))

# --------------------------------------------------------------------------
# Install the C-ABI library leaf dispatchers into ``protocol.nim`` so
# ``reconcileResourcesViaSession(..., library = resolver)`` routes an op over a
# dlopened provider ``.so``. The opaque ``pointer`` a ``ResourceLibraryResolver``
# returns is a live ``LoadedResourceProviderLibrary`` (ref); cast it back here.
# --------------------------------------------------------------------------

proc libDigestHook(lib: pointer; inst: ResourceInstance): Digest256 {.nimcall.} =
  digestViaLibrary(cast[LoadedResourceProviderLibrary](lib), inst)

proc libObserveHook(lib: pointer; inst: ResourceInstance;
                    prior: Option[ResourceBinding]): ObservedState {.nimcall.} =
  observeViaLibrary(cast[LoadedResourceProviderLibrary](lib), inst, prior)

proc libApplyHook(lib: pointer; inst: ResourceInstance;
                  action: ResourceActionKind;
                  observed: ObservedState): ResourceBinding {.nimcall.} =
  applyViaLibrary(cast[LoadedResourceProviderLibrary](lib), inst, action, observed)

setResourceLibraryLeafHooks(libDigestHook, libObserveHook, libApplyHook)

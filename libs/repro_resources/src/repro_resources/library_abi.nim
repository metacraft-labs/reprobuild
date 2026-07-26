## Typed-Extension-Interfaces M4a — the **C-ABI library transport** for the
## resource-reconcile leaf ops (``digest`` / ``observe`` / ``apply``).
##
## This is a THIRD transport for a resource type's driver ops, beside the
## in-process (``reconcileResources``) and session
## (``reconcileResourcesViaSession``) transports. Where the session transport
## renders the abstract contract (Low-Level-Provider-Protocol.md §1) as SSZ-ish
## ``BoxedValue`` payloads over framed stdio to a spawned provider BINARY, the
## library transport renders the SAME abstract contract (§6) as **regular
## cdecl functions on C-typed params + opaque handles** against a provider
## compiled as a linkable **library** the engine ``dlopen``s — NO process
## spawn, NO socket, NO framing.
##
## The two sides live in one module, split by ``reproProviderMode``:
##
##   * PROVIDER side (``when defined(reproProviderMode)``): a set of
##     ``{.exportc, cdecl, dynlib.}`` entry points — ``repro_provider_open`` /
##     ``repro_resource_{digest,observe,apply}`` / ``repro_*_free`` /
##     ``repro_provider_close`` — that a provider ``.so`` (built ``--app:lib``)
##     exposes. They unbox the C-representation of the op inputs, run the
##     registered ``ResourceProviderDriver.*``, and hand back an OWNED result
##     buffer released ONLY through the callee-EXPORTED ``repro_*_free`` (§6.2:
##     alloc + free stay on one side of the allocator boundary — the Nim GC/ORC
##     heap here, a distinct CRT per DLL on Windows).
##
##   * ENGINE side (always compiled): ``loadResourceProviderLibrary`` ``dlopen``s
##     such a ``.so``, binds the cdecl symbols, and ``digestViaLibrary`` /
##     ``observeViaLibrary`` / ``applyViaLibrary`` call the ops directly.
##     ``protocol.nim`` picks library-vs-session per linkability, extending the
##     existing in-process / session choice.
##
## VALUE ENCODING at the boundary is a length-prefixed ``(ptr,len)`` byte
## buffer produced by ``protocol.nim``'s ``encode*`` helpers — the SAME
## non-SSZ codec the in-process registry uses, crossing as a raw C ``(ptr,len)``
## rather than a framed BoxedValue. This is the §6.1 "values cross as
## (ptr,len)" rendering (an attrs box the host cannot type still crosses intact
## inside the instance buffer, the analog of the session's BoxedValue). It is
## deliberately NOT SSZ and NOT on a pipe. (The M4b/M4c nimRtl fast path passes
## live typed Nim values with no encoding at all; that is layered ABOVE this
## boundary and is out of scope for M4a.)

# ---------------------------------------------------------------------------
# Shared C-ABI vocabulary (both sides).
# ---------------------------------------------------------------------------

const
  ReproAbiVersion* = 1'u32
    ## The C-ABI transport version. A provider library and the engine MUST
    ## agree exactly (the library-transport analog of ``ProviderProtocolVersion``
    ## for the session). Bumped when the entry-point set / buffer encoding
    ## changes.

type
  ReproStatus* = distinct cint
    ## C-ABI status code. ``0`` == ok; negative == an error class. NO Nim
    ## exception / panic crosses the boundary — every entry point catches at
    ## the ABI and converts to a status (§6.2).

  ReproProviderHandle* = pointer
    ## Opaque handle to an open provider (``typedef struct
    ## repro_provider_session* ...`` in C). Carries the provider-session state;
    ## the type-erasure seam the helper libraries re-type (§6.1).

  ReproBuffer* = object
    ## A callee-allocated ``(ptr,len)`` result. Released ONLY via the matching
    ## exported ``repro_buffer_free`` — never the caller's own ``free`` (§6.2).
    data*: ptr UncheckedArray[byte]
    len*: csize_t

const
  reproOk* = ReproStatus(0)
  reproErrUnknownType* = ReproStatus(-1)     ## no driver registered for typeId
  reproErrDecode* = ReproStatus(-2)          ## malformed input buffer
  reproErrDriver* = ReproStatus(-3)          ## the driver op raised
  reproErrBadHandle* = ReproStatus(-4)       ## nil / wrong provider handle
  reproErrAbiVersion* = ReproStatus(-5)      ## engine/library ABI mismatch
  reproErrInternal* = ReproStatus(-6)        ## unexpected boundary failure

proc `==`*(a, b: ReproStatus): bool {.borrow.}
proc `$`*(s: ReproStatus): string = "ReproStatus(" & $int(cint(s)) & ")"

# The fixed cdecl entry-point symbol names (a Reprobuild standard — statically
# known from the lifted interface, NO runtime discovery, §6.1). Both the
# provider ``.exportc`` and the engine ``dynlib`` binding use these.
const
  SymOpen* = "repro_provider_open"
  SymClose* = "repro_provider_close"
  SymDigest* = "repro_resource_digest"
  SymObserve* = "repro_resource_observe"
  SymApply* = "repro_resource_apply"
  SymBufferFree* = "repro_buffer_free"
  SymLastError* = "repro_last_error"
  SymCallCount* = "repro_provider_call_count"   ## no-spawn witness (test seam)

# ===========================================================================
# PROVIDER SIDE — exported cdecl entry points (only in a provider library).
# ===========================================================================

when defined(reproProviderMode):
  import std/options
  from repro_home_resources/types import ObservedState, ResourceActionKind
  import repro_resources/instance
  import repro_resources/protocol

  type
    ProviderState = object
      ## The concrete object an opaque ``ReproProviderHandle`` points at.
      abiVersion: uint32
      calls: int          ## witness: number of in-process ABI ops served
      lastError: string   ## detail of the last op failure (borrowed via
                          ## ``repro_last_error``, §6.2 stable-until-next-call)

  # A leaked-on-close-by-design registry is overkill; a provider library holds
  # exactly the state it allocates and frees it in ``repro_provider_close``.

  proc allocBuffer(bytes: openArray[byte]): ReproBuffer =
    ## Allocate an owned result buffer on the Nim heap. Freed ONLY by
    ## ``repro_buffer_free`` below (same allocator, §6.2).
    result.len = csize_t(bytes.len)
    if bytes.len == 0:
      result.data = nil
    else:
      result.data = cast[ptr UncheckedArray[byte]](alloc(bytes.len))
      for i in 0 ..< bytes.len:
        result.data[i] = bytes[i]

  proc borrowedBytes(data: pointer; len: csize_t): seq[byte] =
    ## Copy a BORROWED caller-owned input ``(ptr,len)`` into a Nim ``seq`` for
    ## decode. The caller retains ownership and frees it with its own allocator
    ## after the call returns (§6.2 borrow rule).
    let n = int(len)
    result = newSeq[byte](n)
    if n > 0 and data != nil:
      copyMem(addr result[0], data, n)

  proc repro_provider_open(abiVersion: uint32;
                           outHandle: ptr ReproProviderHandle): ReproStatus
                          {.exportc: "repro_provider_open", cdecl, dynlib.} =
    ## Open a provider session over the C ABI. Registers the protocol-core
    ## codecs (so the ``encode*`` buffer codec is available) and hands back an
    ## opaque handle. No process is spawned — the driver runs in THIS module,
    ## in the engine's own address space, reached by a direct cdecl call.
    if outHandle == nil:
      return reproErrBadHandle
    if abiVersion != ReproAbiVersion:
      outHandle[] = nil
      return reproErrAbiVersion
    try:
      registerResourceProtocolCodecs()
      let st = cast[ptr ProviderState](alloc0(sizeof(ProviderState)))
      st.abiVersion = abiVersion
      st.calls = 0
      outHandle[] = cast[ReproProviderHandle](st)
      reproOk
    except CatchableError, Defect:
      outHandle[] = nil
      reproErrInternal

  proc repro_provider_close(handle: ReproProviderHandle)
                           {.exportc: "repro_provider_close", cdecl, dynlib.} =
    ## Release a provider handle allocated by ``repro_provider_open`` (the
    ## callee-exported close, §6.2). Idempotent on ``nil``.
    if handle != nil:
      dealloc(cast[pointer](handle))

  proc repro_buffer_free(buf: ptr ReproBuffer)
                        {.exportc: "repro_buffer_free", cdecl, dynlib.} =
    ## Release a result buffer that an op returned. The caller MUST call THIS
    ## rather than its own ``free`` — the buffer was allocated on the provider
    ## library's heap (§6.2). Idempotent / defined on a nil / empty buffer.
    if buf != nil and buf.data != nil:
      dealloc(cast[pointer](buf.data))
      buf.data = nil
      buf.len = 0

  proc repro_provider_call_count(handle: ReproProviderHandle): cint
                                {.exportc: "repro_provider_call_count", cdecl,
                                  dynlib.} =
    ## Witness accessor (test seam): how many ABI ops this handle served
    ## in-process. A non-zero value with NO session pipe opened proves the
    ## op ran over the library transport, not the session (the no-spawn
    ## assertion in ``t_provider_library_c_abi_reconcile``).
    if handle == nil: return -1
    cint(cast[ptr ProviderState](handle).calls)

  proc repro_last_error(handle: ReproProviderHandle): cstring
                       {.exportc: "repro_last_error", cdecl, dynlib.} =
    ## Borrowed, stable-until-next-call error detail for the last failed op on
    ## this handle (§6.2). Empty string when there is none.
    if handle == nil: return cstring""
    cstring(cast[ptr ProviderState](handle).lastError)

  template withState(handle: ReproProviderHandle; body: untyped): ReproStatus =
    ## Bind ``st`` to the handle's ProviderState or fail with a bad-handle
    ## status; run ``body`` under a boundary-wide try so no exception escapes.
    if handle == nil:
      reproErrBadHandle
    else:
      let st {.inject.} = cast[ptr ProviderState](handle)
      try:
        body
      except CatchableError as e:
        st.lastError = e.msg
        reproErrDriver
      except Defect as e:
        st.lastError = "defect: " & e.msg
        reproErrDriver

  proc repro_resource_digest(handle: ReproProviderHandle;
                             instData: pointer; instLen: csize_t;
                             outBuf: ptr ReproBuffer): ReproStatus
                            {.exportc: "repro_resource_digest", cdecl, dynlib.} =
    ## ``digest(inst)`` over the ABI. Input: the encoded ``ResourceInstance``
    ## buffer (borrowed). Output: an OWNED buffer = encoded ``ObservedState``
    ## whose ``digest`` field is the desired-state digest.
    if outBuf == nil: return reproErrBadHandle
    outBuf.data = nil; outBuf.len = 0
    withState(handle):
      let inst = decodeResourceInstance(borrowedBytes(instData, instLen))
      let def = lookupResourceProvider(inst.typeId)
      var obs: ObservedState
      obs.present = true
      obs.digest = def.driver.digest(inst)
      outBuf[] = allocBuffer(encodeObservedState(obs))
      inc st.calls
      reproOk

  proc repro_resource_observe(handle: ReproProviderHandle;
                              instData: pointer; instLen: csize_t;
                              priorData: pointer; priorLen: csize_t;
                              outBuf: ptr ReproBuffer): ReproStatus
                             {.exportc: "repro_resource_observe", cdecl,
                               dynlib.} =
    ## ``observe(inst, prior)`` over the ABI. ``prior`` is nullable: a nil /
    ## zero-length ``priorData`` means ``none(ResourceBinding)``. Output: an
    ## OWNED encoded ``ObservedState``.
    if outBuf == nil: return reproErrBadHandle
    outBuf.data = nil; outBuf.len = 0
    withState(handle):
      let inst = decodeResourceInstance(borrowedBytes(instData, instLen))
      var prior = none(ResourceBinding)
      if priorData != nil and priorLen > 0:
        prior = some(decodeResourceBinding(borrowedBytes(priorData, priorLen)))
      let def = lookupResourceProvider(inst.typeId)
      let obs = def.driver.observe(inst, prior)
      outBuf[] = allocBuffer(encodeObservedState(obs))
      inc st.calls
      reproOk

  proc repro_resource_apply(handle: ReproProviderHandle;
                            instData: pointer; instLen: csize_t;
                            observedData: pointer; observedLen: csize_t;
                            actionKind: uint32;
                            outBuf: ptr ReproBuffer): ReproStatus
                           {.exportc: "repro_resource_apply", cdecl, dynlib.} =
    ## ``apply(inst, action, observed)`` over the ABI. ``action`` crosses as a
    ## plain ``uint32`` ordinal (the C rendering of the session's tiny action
    ## box). Output: an OWNED encoded ``ResourceBinding``.
    if outBuf == nil: return reproErrBadHandle
    outBuf.data = nil; outBuf.len = 0
    withState(handle):
      let inst = decodeResourceInstance(borrowedBytes(instData, instLen))
      var observed: ObservedState
      if observedData != nil and observedLen > 0:
        observed = decodeObservedState(borrowedBytes(observedData, observedLen))
      let action = ResourceActionKind(actionKind)
      let def = lookupResourceProvider(inst.typeId)
      let binding = def.driver.apply(inst, action, observed)
      outBuf[] = allocBuffer(encodeResourceBinding(binding))
      inc st.calls
      reproOk

/*
 * repro_provider_abi.h — the Reprobuild C-ABI provider-library transport.
 *
 * Typed-Extension-Interfaces M4 / Low-Level-Provider-Protocol.md §6.
 *
 * This is the language-agnostic blueprint an EXTERNAL-language provider or
 * consumer compiles against. It is the C rendering of the ONE abstract
 * provider contract (§1); the session transport renders the same contract as
 * framed SSZ over stdio, this renders it as regular `cdecl` functions on
 * C-typed `(ptr,len)` parameters + opaque handles — NO process spawn, NO
 * socket, NO framing (§6.1). A provider ships as a shared library exporting
 * these symbols; the engine `dlopen`s it and calls the ops directly.
 *
 * ---------------------------------------------------------------------------
 * SOURCE OF TRUTH / KEPT IN SYNC
 * ---------------------------------------------------------------------------
 * The authoritative definition is the Nim module
 *   libs/repro_resources/src/repro_resources/library_abi.nim
 * whose `{.exportc, cdecl, dynlib.}` producers emit these exact symbols, and
 * whose engine-side `library_transport.nim` binds them. This header is a
 * hand-maintained mirror of that module — the two MUST stay in lock-step:
 *   - REPRO_ABI_VERSION          <->  ReproAbiVersion
 *   - the repro_status_t enumerators (values)  <->  the reproErr* consts
 *   - the ReproBuffer struct layout (ptr,len)  <->  ReproBuffer
 *   - the function prototypes / symbol names    <->  the SymXxx consts +
 *                                                    exportc signatures
 * The M4a reconcile + ownership tests bind the Nim signatures directly, so a
 * drift between library_abi.nim and a real provider is caught at the Nim
 * boundary; this header carries the SAME shape for non-Nim authors. When you
 * change library_abi.nim, update this file in the same commit.
 *
 * ---------------------------------------------------------------------------
 * MEMORY-OWNERSHIP CONTRACT (§6.2 — the load-bearing part)
 * ---------------------------------------------------------------------------
 * - Allocation and deallocation stay on the SAME side of the boundary. A
 *   value the provider library allocates (a `ReproBuffer` filled by an op, an
 *   open handle) is released ONLY by calling the provider's matching EXPORTED
 *   release function — `repro_buffer_free` / `repro_provider_close`. The
 *   caller MUST NOT free library-allocated memory with its own free()/delete:
 *   across a module boundary the two sides may use different allocators/heaps
 *   (a Nim provider allocates on the Nim GC/ORC heap; on Windows each DLL can
 *   link its own C runtime), and a cross-heap free is undefined behavior.
 * - Inputs are BORROWED: a `(ptr,len)` input is valid only for the duration
 *   of the call; the caller retains ownership and frees it with its own
 *   allocator after the call returns. The callee copies what it needs.
 * - Callee outputs are OWNED BY THE CALLER but RELEASED THROUGH the callee's
 *   exported free, per the rule above. A returned pointer is valid until its
 *   explicit free — never merely "until the next call".
 * - NO exception / panic crosses the ABI. Every fallible entry point returns a
 *   `repro_status_t` (0 == ok, negative == an error class). On error the `out`
 *   parameter is left in a DEFINED EMPTY state (a nil handle / a {NULL,0}
 *   buffer) and MUST NOT be freed. Error detail is retrieved with
 *   `repro_last_error`, which returns a borrowed, stable-until-next-call
 *   string.
 * - Handles are single-threaded per session (default); not thread-shared
 *   unless a capability says so.
 *
 * The recommended consumer pattern is a scope-bound RAII wrapper that calls
 * the exported free on scope exit (see repro_provider_abi.hpp for the C++
 * reference). Nim authors use library_helpers.nim.
 */
#ifndef REPRO_PROVIDER_ABI_H
#define REPRO_PROVIDER_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The C-ABI transport version. A provider library and the engine MUST agree
 * exactly (the library analog of the session's ProviderProtocolVersion).
 * Bumped when the entry-point set or the buffer encoding changes.
 * Mirrors `ReproAbiVersion` in library_abi.nim.
 */
#define REPRO_ABI_VERSION 1u

/*
 * C-ABI status code. 0 == ok; negative == an error class. No Nim exception /
 * panic ever crosses the boundary — every entry point catches at the ABI and
 * converts to one of these (§6.2). Values mirror the reproErr* consts.
 */
typedef enum repro_status {
  REPRO_OK               =  0,  /* success                                   */
  REPRO_ERR_UNKNOWN_TYPE = -1,  /* no driver registered for the typeId       */
  REPRO_ERR_DECODE       = -2,  /* malformed input buffer                    */
  REPRO_ERR_DRIVER       = -3,  /* the driver op raised                      */
  REPRO_ERR_BAD_HANDLE   = -4,  /* nil / wrong provider handle or out-param   */
  REPRO_ERR_ABI_VERSION  = -5,  /* engine/library ABI-version mismatch       */
  REPRO_ERR_INTERNAL     = -6   /* unexpected boundary failure               */
} repro_status_t;

/*
 * Opaque handle to an open provider session. Carries the provider-session
 * state; the type-erasure seam the helper libraries re-type (§6.1). Obtained
 * from repro_provider_open, released with repro_provider_close.
 */
typedef struct repro_provider_session *repro_provider_handle_t;

/*
 * A callee-allocated (ptr,len) result. `data` may be NULL when `len` is 0.
 * Released ONLY via the matching exported `repro_buffer_free` — never the
 * caller's own free (§6.2). Layout mirrors `ReproBuffer` in library_abi.nim:
 * a data pointer followed by a size_t length.
 */
typedef struct repro_buffer {
  uint8_t *data;
  size_t   len;
} repro_buffer_t;

/* ----------------------------- lifecycle -------------------------------- */

/*
 * Open a provider session over the C ABI. `abi_version` MUST equal
 * REPRO_ABI_VERSION or the call fails with REPRO_ERR_ABI_VERSION. On success
 * *out_handle receives an owned handle (release with repro_provider_close);
 * on any error *out_handle is set to NULL (defined empty) — do not close it.
 * `out_handle` is a borrowed pointer to caller storage; must be non-NULL.
 */
repro_status_t repro_provider_open(uint32_t abi_version,
                                   repro_provider_handle_t *out_handle);

/*
 * Release a provider handle from repro_provider_open (the callee-exported
 * close, §6.2). Idempotent on NULL.
 */
void repro_provider_close(repro_provider_handle_t handle);

/* ------------------------------ resource ops ---------------------------- */

/*
 * digest(inst). Input: the encoded ResourceInstance buffer (BORROWED —
 * `inst_data`/`inst_len`). Output: *out_buf receives an OWNED buffer = the
 * encoded ObservedState whose `digest` field is the desired-state digest.
 * Release *out_buf with repro_buffer_free. On error *out_buf is {NULL,0}.
 */
repro_status_t repro_resource_digest(repro_provider_handle_t handle,
                                     const void *inst_data, size_t inst_len,
                                     repro_buffer_t *out_buf);

/*
 * observe(inst, prior). `inst_data`/`inst_len` (BORROWED) is the encoded
 * ResourceInstance. `prior_data`/`prior_len` is nullable: a NULL / zero-length
 * prior means none(ResourceBinding). Output: *out_buf = an OWNED encoded
 * ObservedState; release with repro_buffer_free. On error *out_buf is {NULL,0}.
 */
repro_status_t repro_resource_observe(repro_provider_handle_t handle,
                                      const void *inst_data, size_t inst_len,
                                      const void *prior_data, size_t prior_len,
                                      repro_buffer_t *out_buf);

/*
 * apply(inst, action, observed). `inst_data` (BORROWED) is the encoded
 * ResourceInstance; `observed_data`/`observed_len` (BORROWED, nullable) is the
 * encoded ObservedState from observe; `action_kind` crosses as a plain uint32
 * ordinal (the C rendering of the session's tiny action box). Output:
 * *out_buf = an OWNED encoded ResourceBinding; release with repro_buffer_free.
 * On error *out_buf is {NULL,0}.
 */
repro_status_t repro_resource_apply(repro_provider_handle_t handle,
                                    const void *inst_data, size_t inst_len,
                                    const void *observed_data,
                                    size_t observed_len,
                                    uint32_t action_kind,
                                    repro_buffer_t *out_buf);

/* --------------------------- release + diagnostics ---------------------- */

/*
 * Release a result buffer an op returned. The caller MUST call THIS rather
 * than its own free — the buffer was allocated on the provider library's heap
 * (§6.2). Idempotent / defined on a NULL pointer or an already-empty buffer;
 * resets the buffer to {NULL,0} so a double-free is a no-op.
 */
void repro_buffer_free(repro_buffer_t *buf);

/*
 * Borrowed, stable-until-next-call error detail for the last failed op on this
 * handle (§6.2). Returns an empty string (never NULL) when there is none. The
 * returned pointer is owned by the library; do NOT free it, and treat it as
 * invalidated by the next call on this handle.
 */
const char *repro_last_error(repro_provider_handle_t handle);

/*
 * Witness accessor (test seam): how many ABI ops this handle has served
 * in-process. A non-zero value with NO session pipe opened proves the op ran
 * over the library transport, not the session. Returns -1 on a NULL handle.
 * Optional: a minimal provider may omit this symbol.
 */
int repro_provider_call_count(repro_provider_handle_t handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* REPRO_PROVIDER_ABI_H */

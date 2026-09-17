#ifndef REPRO_HCR_AGENT_H
#define REPRO_HCR_AGENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "repro_hcr_dispatch_table.h"

#if defined(_WIN32) && defined(REPRO_HCR_AGENT_BUILD_DLL)
#define REPRO_HCR_AGENT_API __declspec(dllexport)
#else
#define REPRO_HCR_AGENT_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* The capability a host advertises when it can apply a `sourceChanged`
 * (GDScript-Hot-Reload-Multi-Version-Sources design §4.4). Kept in sync with
 * `HcrSourceReloadCapability` in
 * `libs/repro_hcr_agent/src/repro_hcr_agent/protocol.nim`. */
#define REPRO_HCR_AGENT_CAPABILITY_SOURCE_RELOAD "source-reload"

/* The first generation a `sourceChanged` may carry. Generation 1 is the
 * content the process STARTED with, so a notification never legitimately
 * carries it — design §4.3 chose the numbering precisely so that the
 * `symbolGeneration: 1` hardcode is a protocol error on this wire rather than
 * a plausible value. */
#define REPRO_HCR_AGENT_FIRST_RELOAD_GENERATION 2u

/*
 * Support profile ids carried on the agent wire.
 *
 * `macos-arm64-direct-hcr-in-codetracer-v1` is the pre-existing Mach-O/arm64
 * profile (M26-M28). `linux-x86_64-elf-direct-hcr-v1` is the ELF/x86_64 profile
 * introduced by HLX-M0; the two are not interchangeable and the coordinator
 * rejects a mismatch during negotiation.
 */
#define REPRO_HCR_AGENT_SUPPORT_PROFILE_MACOS_ARM64 \
  "macos-arm64-direct-hcr-in-codetracer-v1"
#define REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64 \
  "linux-x86_64-elf-direct-hcr-v1"
#define REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64 \
  "windows-x86_64-msvc-pe-direct-hcr-v1"

typedef struct repro_hcr_agent_symbol {
  const char *name;
  void *address;
} repro_hcr_agent_symbol;

REPRO_HCR_AGENT_API int repro_hcr_agent_start_from_env(
    const char *support_profile, const repro_hcr_agent_symbol *symbols,
    size_t symbol_count);
REPRO_HCR_AGENT_API int repro_hcr_agent_start_polling_from_env(
    const char *support_profile, const repro_hcr_agent_symbol *symbols,
    size_t symbol_count);
/*
 * Service the polled session.
 *
 * GDH-M4 replaced the one-shot behaviour this used to have (`poll_done = 1`
 * after the FIRST frame, `repro_hcr_agent.c:1620-1627` as it then stood) with a
 * drain-and-return poll:
 *
 *   * the FIRST call connects, sends `hello`, reads `helloAck` and then BLOCKS
 *     for the first coordinator frame — deliberately identical to the old
 *     behaviour, because HLX-M0's target calls `poll()` exactly once and its
 *     gate asserts the patch landed by the time it returned;
 *   * every call, including the first, then drains whatever further frames are
 *     already readable and returns without blocking;
 *   * the session ends only when the peer closes or errors, at which point
 *     `repro_hcr_agent_poll_session_open()` answers 0 and further polls are
 *     cheap no-ops.
 *
 * The return value is 0 on success and unchanged from before, so an existing
 * caller that records it keeps recording the same number.
 */
REPRO_HCR_AGENT_API int repro_hcr_agent_poll(void);

/*
 * The same drain, with NO blocking anywhere — including the handshake.
 *
 * `repro_hcr_agent_poll` blocks for the first coordinator frame, which an
 * engine main loop cannot afford: its first safe point would freeze the frame
 * loop until a coordinator chose to send something, and a driver that waits
 * for the program to reach a given point before reloading would deadlock
 * against a program stopped at its first frame. Use this from a frame loop and
 * `repro_hcr_agent_poll` from a one-shot caller.
 */
REPRO_HCR_AGENT_API int repro_hcr_agent_poll_nonblocking(void);

/* 1 while the polled session is connected and the peer has not closed it.
 * Answers 0 before the first `repro_hcr_agent_poll()` and after the session
 * ends, so a host loop is `poll(); while (session_open()) poll();`. */
REPRO_HCR_AGENT_API int repro_hcr_agent_poll_session_open(void);

/* How many coordinator frames this process has dispatched. A gate that wants
 * to prove a SECOND message was read, rather than infer it from a reply, reads
 * this. */
REPRO_HCR_AGENT_API int repro_hcr_agent_poll_messages_handled(void);

/*
 * GDH design §4.3 — one changed file inside a `sourceChanged` notification.
 *
 * `content` is the DECODED bytes, present exactly when `content_encoding` is
 * "inline". The notification carries the content rather than a path handle
 * because a handle races the next edit, which would put v3's text in v2's slot
 * — the misattribution the whole design exists to prevent.
 */
typedef struct repro_hcr_source_changed_file {
  const char *source_path;
  unsigned int generation;
  const char *snapshot_digest;   /* "<alg>:<hex>", e.g. "sha256:…" */
  const char *line_table_digest;
  unsigned int line_count;
  const char *content_encoding;  /* "inline" | "path" */
  const unsigned char *content;
  size_t content_length;
} repro_hcr_source_changed_file;

/* Named refusal reasons, §5.5. Spelled here so the host and the coordinator
 * cannot drift into two spellings of one reason. */
#define REPRO_HCR_RELOAD_REASON_CAPABILITY "capability-not-negotiated"
#define REPRO_HCR_RELOAD_REASON_DIGEST_MISMATCH "digest-mismatch"
#define REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM "digest-algorithm-unsupported"
#define REPRO_HCR_RELOAD_REASON_LINE_COUNT "line-count-mismatch"
#define REPRO_HCR_RELOAD_REASON_LINE_TABLE "line-table-mismatch"
#define REPRO_HCR_RELOAD_REASON_PARSE_ERROR "parse-error"
#define REPRO_HCR_RELOAD_REASON_WRITER_REFUSED "writer-refused"
/*
 * `writer-refused` MEANS THE TRACE WRITER REFUSED, and nothing else.
 *
 * It did not. Before GDH-M8 the GDScript host answered `writer-refused` for six
 * unrelated conditions — a failed disk open, a path the engine had never
 * loaded, a reentrant safe point, an occupied queue, an unavailable emit lock,
 * and a deferral timeout — none of which is a writer refusal, so a gate
 * asserting `reason == "writer-refused"` was satisfied by any of them. The
 * three names below split those causes apart. They are additive: no existing
 * reason changes meaning, and a host that never had the ambiguity keeps
 * spelling its refusals exactly as it did.
 */
#define REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_LOADED "script-not-loaded"
#define REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT "script-not-gdscript"
#define REPRO_HCR_RELOAD_REASON_HOST_BUSY "host-busy"
#define REPRO_HCR_RELOAD_REASON_NO_SAFE_POINT "no-safe-point"
/*
 * The one refusal that is NOT a clean one. Design §8.1: a failure at steps 4-6
 * — after the trace has committed to the new version and before or during the
 * engine swap — "is not recoverable by continuing", so the recorder closes the
 * trace with a recorded reason and the engine continues UNRELOADED. A
 * coordinator seeing this must expect a degraded session with a coherent
 * recording, which is a different thing from the clean refusals above: those
 * leave the session untouched.  The failing STAGE is named in `detail`; the
 * reason names the consequence, because the consequence is what a coordinator
 * has to act on and it is the same for all three stages.
 */
#define REPRO_HCR_RELOAD_REASON_TRACE_CLOSED "trace-closed"
/*
 * GDH-M8b. THE SECOND DOOR INTO THE SAME DEFECT.
 *
 * `parse-error` covers the content a host can refuse BEFORE it installs
 * anything, because `GDScriptParser::parse` and `GDScriptAnalyzer::analyze` can
 * both be run on a stack-local parser. `GDScriptCompiler` cannot: it compiles
 * INTO a `GDScript`, and the only `GDScript` at the host's disposal is the live
 * one. A v2 that parses and analyzes and then fails the compiler
 * (`ERR_COMPILATION_FAILED`, gdscript.cpp:862) is therefore only detectable
 * AFTER the swap, and until GDH-M8b it was minted, marked, written, swapped,
 * left `valid == false`, and acknowledged `applied` — the same invariant
 * violation GDH-M8 closed for `parse-error`, reached through a door the
 * pre-check cannot stand in front of.
 *
 * It is its OWN reason and not `parse-error` because the two have different
 * consequences and different fixes. `parse-error` is a CLEAN refusal: nothing
 * was touched. `compile-error` is not: the trace had already committed to the
 * new version, so the recorder closes it (exactly as for `trace-closed`), and
 * the engine has already taken the broken script and has to be put back. What
 * the host managed to put back is stated in `detail` — never implied.
 */
#define REPRO_HCR_RELOAD_REASON_COMPILE_ERROR "compile-error"
#define REPRO_HCR_RELOAD_REASON_ENCODING "unsupported-content-encoding"
#define REPRO_HCR_RELOAD_REASON_MULTIPLE_FILES "multiple-changed-files-unsupported"

#define REPRO_HCR_AGENT_MAX_UNPRESERVED 8

/*
 * What the host did, filled in by the handler.
 *
 * `applied_digest` is the digest the HOST recomputed over the bytes it
 * actually applied — not an echo of `snapshot_digest`. The distinction is the
 * difference between this acknowledgement and a chain of `success: true`: a
 * host that echoed the request would report a byte-perfect apply for content it
 * never looked at.
 *
 * `unpreserved` names the state the reload did NOT keep (design §5.3 — static
 * variables lost, `@export` metadata not refreshed, pending coroutines
 * cancelled). It is reported, never silently absorbed.
 */
typedef struct repro_hcr_source_reload_outcome {
  int applied;                 /* 1 = applied, 0 = refused */
  const char *reason;          /* named, non-empty when !applied */
  const char *detail;
  unsigned long long path_index;
  unsigned long long step_index;
  const char *applied_digest;  /* "<alg>:<hex>" over the bytes applied */
  unsigned int applied_line_count;
  const char *unpreserved[REPRO_HCR_AGENT_MAX_UNPRESERVED];
  int unpreserved_count;
} repro_hcr_source_reload_outcome;

typedef int (*repro_hcr_source_reload_handler)(
    void *ctx, const char *reload_id, const char *language,
    const repro_hcr_source_changed_file *file,
    repro_hcr_source_reload_outcome *out);

/*
 * Register the host's reload handler AND, by the same act, make the agent
 * advertise `source-reload` in its hello.
 *
 * They are one call because the alternative — advertising a capability the
 * host has nothing to serve it with — is the failure design §4.4 calls worse
 * than no session at all. Must be called BEFORE
 * `repro_hcr_agent_start_from_env` / `_start_polling_from_env`, because the
 * hello is built at connect time. Returns 0 on success, -1 for a NULL handler.
 */
REPRO_HCR_AGENT_API int repro_hcr_agent_set_source_reload_handler(
    repro_hcr_source_reload_handler handler, void *ctx);

/* 1 when a source-reload handler is registered, i.e. when this agent
 * advertises `source-reload`. */
REPRO_HCR_AGENT_API int repro_hcr_agent_advertises_source_reload(void);

/* SHA-256 over `data`, written to `out` as 64 lowercase hex digits plus a NUL
 * (so `out_cap` must be at least 65). Returns 0 on success, -1 when the
 * digest's own FIPS self-test fails or the buffer is too small — a digest that
 * cannot be shown to be one is never reported as one. */
REPRO_HCR_AGENT_API int repro_hcr_agent_sha256_hex(
    const void *data, size_t len, char *out, size_t out_cap);

/* The compiled-in support profile for this build, or "" when the platform has
 * no direct-patch arm. */
REPRO_HCR_AGENT_API const char *repro_hcr_agent_default_support_profile(void);

/* Host capability probe results (see design §5.2 and §4.4). Both are evaluated
 * at agent start and are stable for the life of the process. */
REPRO_HCR_AGENT_API int repro_hcr_agent_host_supports_direct_patch(void);
REPRO_HCR_AGENT_API int repro_hcr_agent_host_membarrier_sync_core(void);

/* HLX-M4: the real-time signal number the tier-2 quiescence handshake uses
 * (design §6.2 step 1), or 0 when this platform has no quiescence arm. An
 * embedding application needs it so it does not install its own disposition on
 * the same signal, and a gate needs it to prove the handler is installed rather
 * than assumed. */
REPRO_HCR_AGENT_API int repro_hcr_agent_host_quiescence_signal(void);

/* HLX-M4: how the LAST publication this agent made was performed.
 * 1 = tier 1 (no quiescence; only taken when the process had exactly one
 * thread), 2 = tier 2 (every thread parked across the store). Exposed so a gate
 * can prove the agent actually took the tier its thread count demands, rather
 * than trusting that the branch exists. Returns 0 before any publication. */
REPRO_HCR_AGENT_API int repro_hcr_agent_last_publication_tier(void);

/* HLX-M4 §6.2 step 5: how many parked threads had the last patched function on
 * their stack. -1 means NOT DETERMINED — a tier-1 publication has no parked PCs
 * to read, and a symbol with no `st_size` has no extent to test against. It is
 * deliberately distinct from 0. */
REPRO_HCR_AGENT_API int repro_hcr_agent_last_on_stack_threads(void);

/* HLX-M5 / HLX-OQ-4: which `__register_frame` calling convention this process's
 * unwinder was MEASURED to want — "single-fde", "whole-section", or
 * "undetermined" before the first registration. libgcc accepts both; LLVM
 * libunwind accepts only a single FDE and rejects a section start with "FDE is
 * really a CIE". Exposed because guessing wrong corrupts every backtrace
 * silently, and a gate that can only see "registration succeeded" cannot
 * distinguish a correct choice from a lucky one.
 *
 * `probe_attempts` counts registrations that ran the verification;
 * `fallback_attempts` counts the ones where the first convention did not
 * answer and the other was tried. Linux x86_64 only: the macOS and Windows
 * arms have no `__register_frame` ABI question to answer. */
REPRO_HCR_AGENT_API const char *repro_hcr_agent_register_frame_convention(void);
REPRO_HCR_AGENT_API unsigned long long
repro_hcr_agent_register_frame_probe_attempts(void);
REPRO_HCR_AGENT_API unsigned long long
repro_hcr_agent_register_frame_fallback_attempts(void);

/* HX-D-3: Registration and unregistration of dynamic unwind metadata and JIT debug objects
 * (design §1.2, §5.4, §5.6). */
typedef struct repro_hcr_jit_registration_evidence {
  uint64_t descriptor_address;
  uint32_t descriptor_version;
  uint32_t action_flag;
  uint64_t relevant_entry_address;
  uint64_t first_entry_address;
  uint64_t entry_address;
  uint64_t entry_next_address;
  uint64_t entry_prev_address;
  uint64_t symfile_address;
  uint64_t symfile_size;
  uint64_t retained_debug_object_address;
  uint64_t retained_debug_object_size;
  uint64_t register_hook_call_count;
  uint32_t rebased_section_ordinal;
  uint64_t rebased_section_address;
  uint64_t rebased_symbol_value;
  int32_t applied_relocations;
  uint32_t success;
} repro_hcr_jit_registration_evidence;

typedef struct repro_hcr_unwind_registration_evidence {
  uint64_t payload_address;
  uint64_t payload_size;
  uint64_t code_address;
  uint64_t code_size;
  uint32_t api;
  uint32_t called;
  int64_t patched_pc_relative;
  uint64_t patched_range;
} repro_hcr_unwind_registration_evidence;

REPRO_HCR_AGENT_API int repro_hcr_register_jit_debug_object(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    const char *symbol_name,
    repro_hcr_jit_registration_evidence *out);

REPRO_HCR_AGENT_API int repro_hcr_register_dynamic_eh_frame(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    uint64_t code_size,
    repro_hcr_unwind_registration_evidence *out);

REPRO_HCR_AGENT_API int repro_hcr_unregister_dynamic_eh_frame(uint64_t payload_address);
REPRO_HCR_AGENT_API int repro_hcr_unregister_jit_debug_object(uint64_t entry_address);

/*
 * ===========================================================================
 * Application Runtime API: rb_hcr_*
 * Specified in reprobuild-specs/HCR/HCR-Overview.md § 13.
 * Bound by IsoNim (isonim/src/isonim/native/hcr.nim).
 *
 * NOTE (HX-S-0 / NH-M5):
 * These declarations are the canonical C API for embedding applications, and
 * the canonical library and header names are `librepro_hcr_agent` and
 * `repro_hcr_agent.h` — reconciled by CodeTracer NH-M5 on 2026-09-14, which is
 * what IsoNim's `{.passL: "-lrepro_hcr_agent".}` and its ten
 * `header: "repro_hcr_agent.h"` importc declarations now name.
 *
 * UPDATED 2026-09-18 (HLX-M8). This block used to say the implementations were
 * "baseline" with "safe default behavior (wants_reload = false,
 * file_changed = false, type_changed = false)". They are not baseline any more:
 * repro_hcr_agent.c implements the full lifecycle of
 * reprobuild-specs/HCR/Patch-Loading-Lifecycle.md §3.1 — prepare, Phase E
 * before-reload, Phase F load, Phase G trampolines, Phase H after-reload — plus
 * §3.3 step 38, §3.4 synchronized mode, HCR-Overview §7.4's layout-change
 * acceptance rule, and `rb_hcr_file_changed` answering over the most recent
 * APPLIED reload. The Phase F / Phase G boundary is exposed on Linux x86_64
 * only; the macOS and Windows arms still publish through a single call and
 * cannot distinguish a step-38 late load failure from a Phase G failure.
 * ===========================================================================
 */

typedef struct RbHcrTypeChange {
  const char *type_name;
  uint32_t old_size;
  uint32_t new_size;
} RbHcrTypeChange;

typedef struct RbHcrReloadInfo {
  const char *const *changed_files;
  uint32_t changed_files_count;
  const RbHcrTypeChange *changed_types;
  uint32_t changed_types_count;
} RbHcrReloadInfo;

typedef void (*RbHcrReloadCallback)(const RbHcrReloadInfo *info,
                                    void *user_data);

/* 13.1 Agent Lifecycle */
REPRO_HCR_AGENT_API bool rb_hcr_wants_reload(void);
REPRO_HCR_AGENT_API void rb_hcr_apply_reload(void);

/* 13.2 Managed Type Registration */
REPRO_HCR_AGENT_API void rb_hcr_register_managed_type(const char *type_name);
REPRO_HCR_AGENT_API void rb_hcr_unregister_managed_type(const char *type_name);

/* 13.3 Reload Callbacks */
REPRO_HCR_AGENT_API void rb_hcr_before_reload(RbHcrReloadCallback callback,
                                              void *user_data);
REPRO_HCR_AGENT_API void rb_hcr_after_reload(RbHcrReloadCallback callback,
                                             void *user_data);
REPRO_HCR_AGENT_API void rb_hcr_remove_before_reload(RbHcrReloadCallback callback,
                                                     void *user_data);
REPRO_HCR_AGENT_API void rb_hcr_remove_after_reload(RbHcrReloadCallback callback,
                                                    void *user_data);

/* 13.4 Module Introspection */
REPRO_HCR_AGENT_API bool rb_hcr_file_changed(const char *file_path);
REPRO_HCR_AGENT_API bool rb_hcr_type_changed(const char *type_name);

/*
 * HLX-M8 — synchronized mode (Patch-Loading-Lifecycle.md § 3.4).
 *
 * Automatic is the default: the agent runs the whole lifecycle itself as soon
 * as a patch arrives, and `rb_hcr_wants_reload()` never answers true. In
 * synchronized mode the agent parks the patch, `rb_hcr_wants_reload()` answers
 * true, and every phase — including both callback sets — runs on the thread
 * that calls `rb_hcr_apply_reload()`. An application with a frame loop wants
 * synchronized mode: its callbacks destroy and recreate live objects and must
 * not run on the agent's thread mid-frame.
 *
 * § 3.4 step 43 makes it mandatory for any patch carrying layout changes; such
 * a patch is refused in automatic mode with a diagnostic saying so.
 *
 * Also settable with `REPRO_HCR_SYNCHRONIZED=1` in the environment, for
 * targets that are not recompiled to call this.
 */
REPRO_HCR_AGENT_API void repro_hcr_agent_set_synchronized_mode(int enabled);
REPRO_HCR_AGENT_API int repro_hcr_agent_synchronized_mode(void);

/*
 * HLX-M8 — evidence surface for the reload lifecycle.
 *
 * Every function below reads state the production lifecycle already recorded;
 * none of them is a lever and nothing in the agent branches on them. The
 * lifecycle trace uses the same vocabulary as IsoNim's stub agent
 * (`isonim/tests/helpers/hcr_stub.nim`) so both repos' gates assert the same
 * words: "prepare", "latch", "before", "load", "trampolines", "after", plus
 * "reject", "load-failed" and "commit-failed".
 *
 * The trace is what makes the phase ORDER checkable rather than merely
 * intended — "before" landing on the wrong side of "trampolines" is the exact
 * defect that made the first version of the IsoNim stub wrong, and a gate that
 * only counts callbacks cannot see it.
 */
REPRO_HCR_AGENT_API const char *repro_hcr_rb_lifecycle_trace(void);
REPRO_HCR_AGENT_API int repro_hcr_rb_last_before_callbacks_fired(void);
REPRO_HCR_AGENT_API int repro_hcr_rb_last_after_callbacks_fired(void);
REPRO_HCR_AGENT_API int repro_hcr_rb_last_code_swapped(void);
REPRO_HCR_AGENT_API const char *repro_hcr_rb_last_rejection(void);
REPRO_HCR_AGENT_API const char *repro_hcr_rb_last_unmanaged_types(void);
REPRO_HCR_AGENT_API unsigned long repro_hcr_rb_apply_reload_calls(void);

#ifdef __cplusplus
}
#endif

#endif

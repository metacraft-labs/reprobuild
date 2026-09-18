## Nim bindings for the `rb_hcr_*` application ABI of
## `reprobuild-specs/HCR/HCR-Overview.md` §13, plus the `repro_hcr_rb_*`
## evidence surface of `reprobuild-specs/HCR/Patch-Loading-Lifecycle.md` §3.1.
##
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8.
##
## WHY THIS MODULE EXISTS, which is the thing worth reading.
##
## HLX-M8's four verification gates all live under `tests/e2e/hcr-linux-rbhcr/`
## and all open with `when defined(linux) and defined(amd64)`. Most of what they
## assert is genuinely Linux-shaped — ELF relocatable objects, `endbr64`, an
## `E9 rel32` in a naturally aligned 8-byte window. But a large part is not: the
## §3.1 phase order, §7.4's layout-change acceptance rule, §3.3 step 38's
## after-reload obligation, and every one of §13.2/§13.3's registration rules
## are specification semantics with no platform in them, and the implementation
## agrees — `rb_hcr_run_lifecycle` and all ten `rb_hcr_*` functions in
## `repro_hcr_agent.c` carry no platform guard whatsoever.
##
## They were Linux-only because the VEHICLE was: a target built by `gcc` with
## `-fpatchable-function-entry`, patch bytes cut out of an ELF `.o`, and
## assertions on x86_64 instruction encodings. This module is a second vehicle
## with none of that in it. It compiles the PRODUCTION agent translation unit
## into the calling Nim binary and binds the ABI directly, so a gate can drive
## the real registries and the real lifecycle with no compiler flags, no object
## parsing and no architecture-specific bytes anywhere.
##
## NOTHING HERE IS A MOCK. `{.compile:.}` builds `libs/repro_hcr_agent/c/
## repro_hcr_agent.c` — the same file the Linux gates link into their target and
## the same file `build_lib.sh` ships as `librepro_hcr_agent` — and every proc
## below is an `importc` of a symbol that file exports. There is no second
## implementation to drift.
##
## WINDOWS. `ReproHcrApplicationAbiAvailable` is false there, and the C is not
## compiled, because `repro_hcr_agent.c` cannot build for Windows at all: it
## includes `<pthread.h>`, `<sys/socket.h>`, `<sys/un.h>`, `<sys/mman.h>` and
## `<poll.h>` unconditionally, outside every `#if`. The Windows agent is a
## different translation unit, `repro_hcr_agent_windows.c`, and that file
## defines NO `rb_hcr_*` symbol at all — the application ABI does not exist on
## that host yet. Callers must treat the false as a LOUD failure with that
## remedy, never as a reason to skip: see `ReproHcrApplicationAbiUnavailable`.

import std/[os, strutils]

const
  ReproHcrAgentCDir* =
    (currentSourcePath().parentDir() / "../../c").replace('\\', '/')

  ReproHcrApplicationAbiAvailable* = not defined(windows)
    ## False only where the production agent translation unit cannot be built.

  ReproHcrApplicationAbiUnavailable* =
    "the rb_hcr_* application ABI is not implemented on this host: " &
    "libs/repro_hcr_agent/c/repro_hcr_agent.c includes <pthread.h>, " &
    "<sys/socket.h>, <sys/un.h> and <poll.h> unconditionally so it cannot " &
    "compile for Windows, and libs/repro_hcr_agent/c/repro_hcr_agent_windows.c " &
    "— the translation unit Windows does build — defines none of the ten " &
    "rb_hcr_* functions of HCR-Overview.md §13. REMEDY: implement the §13 " &
    "surface and the §3.1 lifecycle in repro_hcr_agent_windows.c (today " &
    "repro_hcr_agent.c:4413-4419 also refuses every patch frame with " &
    "\"unsupported-host: patching-not-implemented\" before rb_hcr_run_lifecycle " &
    "is reached), then delete this gate's unavailable arm."

when ReproHcrApplicationAbiAvailable:
  {.passC: "-I" & ReproHcrAgentCDir.}
  {.compile: ReproHcrAgentCDir & "/repro_hcr_agent.c".}
  {.passL: "-lpthread".}

  const ReproHcrAgentHeader = "repro_hcr_agent.h"
    ## Declared with `header:` as well as `compile:` so Nim uses the shipped
    ## prototypes rather than emitting its own. Without it the generated C
    ## re-declares `rb_hcr_file_changed(char*)` next to the header's
    ## `rb_hcr_file_changed(const char*)` and the two conflict — which is a
    ## useful accident: it means these bindings are checked against
    ## `repro_hcr_agent.h` by the C compiler on every build.

  type
    RbHcrTypeChange* {.importc: "RbHcrTypeChange",
                       header: ReproHcrAgentHeader, bycopy.} = object
      type_name*: cstring
      old_size*: uint32
      new_size*: uint32

    RbHcrReloadInfo* {.importc: "const RbHcrReloadInfo",
                       header: ReproHcrAgentHeader, bycopy.} = object
      ## Imported WITH the `const`, because `RbHcrReloadCallback` is
      ## `void (*)(const RbHcrReloadInfo *, void *)` and Nim has no const
      ## pointers: without it every `{.cdecl.}` callback written in Nim has a
      ## signature the C compiler refuses to pass to `rb_hcr_before_reload`.
      ## §13.3 says the agent owns this storage and the application must not
      ## retain or modify it, so importing it read-only is also the honest
      ## shape.
      changed_files*: ptr UncheckedArray[cstring]
      changed_files_count*: uint32
      changed_types*: ptr UncheckedArray[RbHcrTypeChange]
      changed_types_count*: uint32

    RbHcrReloadCallback* {.importc: "RbHcrReloadCallback",
                           header: ReproHcrAgentHeader.} =
      proc (info: ptr RbHcrReloadInfo; userData: pointer) {.cdecl.}

    ReproHcrAgentSymbol* {.importc: "repro_hcr_agent_symbol",
                           header: ReproHcrAgentHeader, bycopy.} = object
      name*: cstring
      address*: pointer

  # ---- §13.1 agent lifecycle -------------------------------------------
  proc rbHcrWantsReload*(): bool
    {.importc: "rb_hcr_wants_reload", header: ReproHcrAgentHeader, cdecl.}
  proc rbHcrApplyReload*()
    {.importc: "rb_hcr_apply_reload", header: ReproHcrAgentHeader, cdecl.}

  # ---- §13.2 managed type registration ---------------------------------
  proc rbHcrRegisterManagedType*(typeName: cstring)
    {.importc: "rb_hcr_register_managed_type", header: ReproHcrAgentHeader, cdecl.}
  proc rbHcrUnregisterManagedType*(typeName: cstring)
    {.importc: "rb_hcr_unregister_managed_type", header: ReproHcrAgentHeader, cdecl.}

  # ---- §13.3 reload callbacks ------------------------------------------
  proc rbHcrBeforeReload*(callback: RbHcrReloadCallback; userData: pointer)
    {.importc: "rb_hcr_before_reload", header: ReproHcrAgentHeader, cdecl.}
  proc rbHcrAfterReload*(callback: RbHcrReloadCallback; userData: pointer)
    {.importc: "rb_hcr_after_reload", header: ReproHcrAgentHeader, cdecl.}
  proc rbHcrRemoveBeforeReload*(callback: RbHcrReloadCallback;
                                userData: pointer)
    {.importc: "rb_hcr_remove_before_reload", header: ReproHcrAgentHeader, cdecl.}
  proc rbHcrRemoveAfterReload*(callback: RbHcrReloadCallback;
                               userData: pointer)
    {.importc: "rb_hcr_remove_after_reload", header: ReproHcrAgentHeader, cdecl.}

  # ---- §13.4 module introspection --------------------------------------
  proc rbHcrFileChanged*(filePath: cstring): bool
    {.importc: "rb_hcr_file_changed", header: ReproHcrAgentHeader, cdecl.}
  proc rbHcrTypeChanged*(typeName: cstring): bool
    {.importc: "rb_hcr_type_changed", header: ReproHcrAgentHeader, cdecl.}

  # ---- §3.4 synchronized mode ------------------------------------------
  proc reproHcrAgentSetSynchronizedMode*(enabled: cint)
    {.importc: "repro_hcr_agent_set_synchronized_mode", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrAgentSynchronizedMode*(): cint
    {.importc: "repro_hcr_agent_synchronized_mode", header: ReproHcrAgentHeader, cdecl.}

  # ---- lifecycle evidence ----------------------------------------------
  proc reproHcrRbLifecycleTrace*(): cstring
    {.importc: "repro_hcr_rb_lifecycle_trace", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbLastBeforeCallbacksFired*(): cint
    {.importc: "repro_hcr_rb_last_before_callbacks_fired", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbLastAfterCallbacksFired*(): cint
    {.importc: "repro_hcr_rb_last_after_callbacks_fired", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbLastCodeSwapped*(): cint
    {.importc: "repro_hcr_rb_last_code_swapped", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbLastRejection*(): cstring
    {.importc: "repro_hcr_rb_last_rejection", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbLastUnmanagedTypes*(): cstring
    {.importc: "repro_hcr_rb_last_unmanaged_types", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbApplyReloadCalls*(): culong
    {.importc: "repro_hcr_rb_apply_reload_calls", header: ReproHcrAgentHeader, cdecl.}

  # ---- registry evidence -----------------------------------------------
  proc reproHcrRbBeforeCallbackCount*(): csize_t
    {.importc: "repro_hcr_rb_before_callback_count", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbAfterCallbackCount*(): csize_t
    {.importc: "repro_hcr_rb_after_callback_count", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbBeforeCallbackAt*(index: csize_t): RbHcrReloadCallback
    {.importc: "repro_hcr_rb_before_callback_at", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbBeforeUserDataAt*(index: csize_t): pointer
    {.importc: "repro_hcr_rb_before_user_data_at", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbAfterCallbackAt*(index: csize_t): RbHcrReloadCallback
    {.importc: "repro_hcr_rb_after_callback_at", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbAfterUserDataAt*(index: csize_t): pointer
    {.importc: "repro_hcr_rb_after_user_data_at", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbManagedTypeCount*(): csize_t
    {.importc: "repro_hcr_rb_managed_type_count", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrRbManagedTypeAt*(index: csize_t): cstring
    {.importc: "repro_hcr_rb_managed_type_at", header: ReproHcrAgentHeader, cdecl.}

  # ---- agent session ---------------------------------------------------
  proc reproHcrAgentStartPollingFromEnv*(supportProfile: cstring;
                                         symbols: ptr ReproHcrAgentSymbol;
                                         symbolCount: csize_t): cint
    {.importc: "repro_hcr_agent_start_polling_from_env", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrAgentPollNonblocking*(): cint
    {.importc: "repro_hcr_agent_poll_nonblocking", header: ReproHcrAgentHeader, cdecl.}
  proc reproHcrAgentDefaultSupportProfile*(): cstring
    {.importc: "repro_hcr_agent_default_support_profile", header: ReproHcrAgentHeader, cdecl.}

  const
    RbHcrMaxCallbacks* = 64
      ## `RB_HCR_MAX_CALLBACKS` in repro_hcr_agent.c. Past it the registration
      ## is dropped and the caller is not told — §13.3 names no capacity, and
      ## the IsoNim stub records this one as pinned by the shipped agent.
    RbHcrMaxManagedTypes* = 128
      ## `RB_HCR_MAX_MANAGED_TYPES`, same contract.

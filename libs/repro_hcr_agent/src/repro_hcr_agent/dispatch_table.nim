import std/[os]

const
  dispatchTableSourceDir = currentSourcePath().parentDir()
  dispatchTableCSource = dispatchTableSourceDir / "../../c/repro_hcr_dispatch_table.c"
  dispatchTableCHeaderDir = dispatchTableSourceDir / "../../c"

{.passC: "-I" & dispatchTableCHeaderDir.}
{.compile: dispatchTableCSource.}

type
  DispatchKind* {.size: sizeof(cint).} = enum
    dkMachoLazySymbolPtr = 1
    dkElfGotPlt = 2
    dkCppVtable = 3
    dkPeIat = 4

  DispatchRollbackEntry* = object
    txId*: uint64
    kind*: DispatchKind
    slotAddr*: pointer
    originalTarget*: pointer
    patchedTarget*: pointer
    symbolName*: string
    slotIndex*: int

# C API declarations
proc c_begin_transaction(): uint64 {.
  importc: "repro_hcr_dispatch_begin_transaction".}
proc c_active_transaction(): uint64 {.
  importc: "repro_hcr_dispatch_active_transaction".}
proc c_set_active_transaction(txId: uint64) {.
  importc: "repro_hcr_dispatch_set_active_transaction".}
proc c_record_entry(txId: uint64, kind: cint, slotAddr: ptr pointer,
                    originalTarget: pointer, patchedTarget: pointer,
                    symbolName: cstring, slotIndex: cint): cint {.
  importc: "repro_hcr_dispatch_record_entry".}
proc c_rollback_transaction(txId: uint64): cint {.
  importc: "repro_hcr_dispatch_rollback_transaction".}
proc c_rollback_all(): cint {.
  importc: "repro_hcr_dispatch_rollback_all".}
proc c_commit_transaction(txId: uint64): cint {.
  importc: "repro_hcr_dispatch_commit_transaction".}
proc c_rollback_log_count(): csize_t {.
  importc: "repro_hcr_dispatch_rollback_log_count".}
proc c_clear_rollback_log() {.
  importc: "repro_hcr_dispatch_clear_rollback_log".}

proc c_patch_macho_lazy_symbol(imageFilter: cstring, symbolName: cstring,
                               newTarget: pointer, outOldTarget: ptr pointer): cint {.
  importc: "repro_hcr_patch_macho_lazy_symbol".}
proc c_patch_macho_lazy_symbol_tx(txId: uint64, imageFilter: cstring, symbolName: cstring,
                                  newTarget: pointer, outOldTarget: ptr pointer): cint {.
  importc: "repro_hcr_patch_macho_lazy_symbol_tx".}

proc c_patch_elf_got_plt(imageFilter: cstring, symbolName: cstring,
                         newTarget: pointer, outOldTarget: ptr pointer): cint {.
  importc: "repro_hcr_patch_elf_got_plt".}
proc c_patch_elf_got_plt_tx(txId: uint64, imageFilter: cstring, symbolName: cstring,
                            newTarget: pointer, outOldTarget: ptr pointer): cint {.
  importc: "repro_hcr_patch_elf_got_plt_tx".}

proc c_patch_pe_iat(moduleFilter: cstring, symbolName: cstring,
                    newTarget: pointer, outOldTarget: ptr pointer): cint {.
  importc: "repro_hcr_patch_pe_iat".}
proc c_patch_pe_iat_tx(txId: uint64, moduleFilter: cstring, symbolName: cstring,
                       newTarget: pointer, outOldTarget: ptr pointer): cint {.
  importc: "repro_hcr_patch_pe_iat_tx".}

proc c_discover_vtable_from_instance(classInstance: pointer): ptr UncheckedArray[pointer] {.
  importc: "repro_hcr_discover_vtable_from_instance".}
proc c_find_vtable_by_symbol(mangledSymbol: cstring): ptr UncheckedArray[pointer] {.
  importc: "repro_hcr_find_vtable_by_symbol".}
proc c_patch_vtable_slot(vptr: ptr UncheckedArray[pointer], slotIndex: cint,
                         newMethod: pointer, outOldMethod: ptr pointer): cint {.
  importc: "repro_hcr_patch_vtable_slot".}
proc c_patch_vtable_slot_tx(txId: uint64, vptr: ptr UncheckedArray[pointer], slotIndex: cint,
                            newMethod: pointer, outOldMethod: ptr pointer): cint {.
  importc: "repro_hcr_patch_vtable_slot_tx".}
proc c_patch_vtable_method(vptr: ptr UncheckedArray[pointer], maxSlots: csize_t,
                           oldMethod: pointer, newMethod: pointer,
                           outSlotIndex: ptr cint): cint {.
  importc: "repro_hcr_patch_vtable_method".}
proc c_patch_vtable_method_tx(txId: uint64, vptr: ptr UncheckedArray[pointer], maxSlots: csize_t,
                              oldMethod: pointer, newMethod: pointer,
                              outSlotIndex: ptr cint): cint {.
  importc: "repro_hcr_patch_vtable_method_tx".}

# Safe Nim API

proc beginTransaction*(): uint64 =
  ## Begins a new dispatch redirection transaction.
  c_begin_transaction()

proc activeTransaction*(): uint64 =
  ## Returns the currently active transaction ID, or 0 if none.
  c_active_transaction()

proc setActiveTransaction*(txId: uint64) =
  ## Explicitly sets the active transaction ID.
  c_set_active_transaction(txId)

proc recordEntry*(txId: uint64, kind: DispatchKind, slotAddr: ptr pointer,
                  originalTarget: pointer, patchedTarget: pointer,
                  symbolName = "", slotIndex = -1): bool =
  ## Manually records a redirection entry in the rollback log.
  let sym = if symbolName.len > 0: symbolName.cstring else: nil
  c_record_entry(txId, cint(ord(kind)), slotAddr, originalTarget, patchedTarget,
                 sym, cint(slotIndex)) == 0

proc rollbackTransaction*(txId: uint64): int =
  ## Rolls back all redirections recorded under txId in reverse order.
  int(c_rollback_transaction(txId))

proc rollbackAll*(): int =
  ## Rolls back all dispatch table redirections currently recorded in the log.
  int(c_rollback_all())

proc commitTransaction*(txId: uint64): bool =
  ## Commits the transaction txId, purging its rollback entries from the log.
  c_commit_transaction(txId) == 0

proc rollbackLogCount*(): int =
  ## Returns the current count of active rollback log entries.
  int(c_rollback_log_count())

proc clearRollbackLog*() =
  ## Clears the rollback log without rolling back changes.
  c_clear_rollback_log()

proc patchMachoLazySymbol*(imageFilter: string, symbolName: string,
                           newTarget: pointer, outOldTarget: var pointer): bool =
  ## Rewrites a Mach-O __la_symbol_ptr lazy symbol pointer slot in matching image.
  let filter = if imageFilter.len > 0: imageFilter.cstring else: nil
  c_patch_macho_lazy_symbol(filter, symbolName.cstring, newTarget, addr outOldTarget) == 0

proc patchMachoLazySymbol*(imageFilter: string, symbolName: string,
                           newTarget: pointer): bool =
  ## Rewrites a Mach-O __la_symbol_ptr lazy symbol pointer slot without saving old target.
  var oldTarget: pointer = nil
  patchMachoLazySymbol(imageFilter, symbolName, newTarget, oldTarget)

proc patchMachoLazySymbol*(symbolName: string, newTarget: pointer): bool =
  ## Rewrites a Mach-O __la_symbol_ptr lazy symbol pointer slot across all images.
  var oldTarget: pointer = nil
  patchMachoLazySymbol("", symbolName, newTarget, oldTarget)

proc patchMachoLazySymbolTx*(txId: uint64, imageFilter: string, symbolName: string,
                             newTarget: pointer, outOldTarget: var pointer): bool =
  ## Rewrites a Mach-O __la_symbol_ptr lazy symbol pointer slot under an explicit transaction.
  let filter = if imageFilter.len > 0: imageFilter.cstring else: nil
  c_patch_macho_lazy_symbol_tx(txId, filter, symbolName.cstring, newTarget, addr outOldTarget) == 0

proc patchElfGotPlt*(imageFilter: string, symbolName: string,
                     newTarget: pointer, outOldTarget: var pointer): bool =
  ## Rewrites an ELF .got.plt slot matching symbolName under Linux.
  let filter = if imageFilter.len > 0: imageFilter.cstring else: nil
  c_patch_elf_got_plt(filter, symbolName.cstring, newTarget, addr outOldTarget) == 0

proc patchElfGotPlt*(symbolName: string, newTarget: pointer): bool =
  ## Rewrites an ELF .got.plt slot matching symbolName across all shared objects.
  var oldTarget: pointer = nil
  patchElfGotPlt("", symbolName, newTarget, oldTarget)

proc patchElfGotPltTx*(txId: uint64, imageFilter: string, symbolName: string,
                       newTarget: pointer, outOldTarget: var pointer): bool =
  ## Rewrites an ELF .got.plt slot under an explicit transaction.
  let filter = if imageFilter.len > 0: imageFilter.cstring else: nil
  c_patch_elf_got_plt_tx(txId, filter, symbolName.cstring, newTarget, addr outOldTarget) == 0

proc patchPeIat*(moduleFilter: string, symbolName: string,
                 newTarget: pointer, outOldTarget: var pointer): bool =
  ## Rewrites a Windows PE IAT slot matching symbolName.
  let filter = if moduleFilter.len > 0: moduleFilter.cstring else: nil
  c_patch_pe_iat(filter, symbolName.cstring, newTarget, addr outOldTarget) == 0

proc patchPeIat*(symbolName: string, newTarget: pointer): bool =
  ## Rewrites a Windows PE IAT slot matching symbolName across all modules.
  var oldTarget: pointer = nil
  patchPeIat("", symbolName, newTarget, oldTarget)

proc patchPeIatTx*(txId: uint64, moduleFilter: string, symbolName: string,
                   newTarget: pointer, outOldTarget: var pointer): bool =
  ## Rewrites a Windows PE IAT slot under an explicit transaction.
  let filter = if moduleFilter.len > 0: moduleFilter.cstring else: nil
  c_patch_pe_iat_tx(txId, filter, symbolName.cstring, newTarget, addr outOldTarget) == 0

proc discoverVtableFromInstance*(classInstance: pointer): ptr UncheckedArray[pointer] =
  ## Discovers the C++ vtable pointer from an instance object (offset 0 in Itanium/MSVC ABI).
  c_discover_vtable_from_instance(classInstance)

proc findVtableBySymbol*(mangledSymbol: string): ptr UncheckedArray[pointer] =
  ## Resolves the vtable pointer by mangled vtable symbol (e.g. "_ZTV5Shape").
  ## Automatically applies the 2 * sizeof(void*) offset for Itanium C++ ABI.
  c_find_vtable_by_symbol(mangledSymbol.cstring)

proc patchVtableSlot*(vptr: ptr UncheckedArray[pointer], slotIndex: int,
                      newMethod: pointer, outOldMethod: var pointer): bool =
  ## Atomically patches slotIndex in the vtable to point to newMethod, saving old method.
  c_patch_vtable_slot(vptr, cint(slotIndex), newMethod, addr outOldMethod) == 0

proc patchVtableSlot*(vptr: ptr UncheckedArray[pointer], slotIndex: int,
                      newMethod: pointer): bool =
  ## Atomically patches slotIndex in the vtable to point to newMethod.
  var dummy: pointer = nil
  patchVtableSlot(vptr, slotIndex, newMethod, dummy)

proc patchVtableSlotTx*(txId: uint64, vptr: ptr UncheckedArray[pointer], slotIndex: int,
                        newMethod: pointer, outOldMethod: var pointer): bool =
  ## Atomically patches slotIndex under an explicit transaction ID.
  c_patch_vtable_slot_tx(txId, vptr, cint(slotIndex), newMethod, addr outOldMethod) == 0

proc patchVtableMethod*(vptr: ptr UncheckedArray[pointer], maxSlots: int,
                        oldMethod: pointer, newMethod: pointer,
                        outSlotIndex: var int): bool =
  ## Scans vptr for oldMethod up to maxSlots and atomically patches it to newMethod.
  var idx: cint = -1
  let ok = c_patch_vtable_method(vptr, csize_t(maxSlots), oldMethod, newMethod, addr idx) == 0
  if ok:
    outSlotIndex = int(idx)
  ok

proc patchVtableMethod*(vptr: ptr UncheckedArray[pointer], maxSlots: int,
                        oldMethod: pointer, newMethod: pointer): bool =
  var dummy: int = -1
  patchVtableMethod(vptr, maxSlots, oldMethod, newMethod, dummy)

proc patchVtableMethodTx*(txId: uint64, vptr: ptr UncheckedArray[pointer], maxSlots: int,
                          oldMethod: pointer, newMethod: pointer,
                          outSlotIndex: var int): bool =
  var idx: cint = -1
  let ok = c_patch_vtable_method_tx(txId, vptr, csize_t(maxSlots), oldMethod, newMethod, addr idx) == 0
  if ok:
    outSlotIndex = int(idx)
  ok
